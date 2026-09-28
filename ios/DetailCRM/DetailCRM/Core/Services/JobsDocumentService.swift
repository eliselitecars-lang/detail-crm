//
//  JobsDocumentService.swift
//  DetailCRM
//
//  Documents on jobs and customers (P-25). The file goes to the private
//  `documents` bucket first, then the row is inserted (the server checks
//  the object exists and sits in the right folder); a failed insert removes
//  the file again. Deleting a row queues the file for removal server-side
//  (storage purge queue), so the app never deletes objects itself.
//
//  Shared service (jobs agent): the customer screens (ops) call it for the
//  `.customer` owner.
//

import Foundation
import Supabase

enum JobsDocumentService {

    static let bucket = "documents"
    /// Signed links are short-lived: they are only used to open the file.
    static let signedURLSeconds = 600

    /// A job's documents, or a customer's (for a customer this includes the
    /// files of their jobs, which the server files under the customer too).
    static func list(shopID: UUID, owner: JobsDocument.Owner) async throws -> [JobsDocument] {
        let base = Supa.client
            .from("documents")
            .select(JobsDocument.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        let filtered: PostgrestFilterBuilder
        switch owner {
        case .job(let jobID):
            filtered = base.eq("job_id", value: jobID.uuidString)
        case .customer(let customerID):
            filtered = base.eq("customer_id", value: customerID.uuidString)
        }
        return try await filtered
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Uploads `data` as `fileName` and records it. `customerVisible` is
    /// honoured for managers only (the server forces a technician's upload
    /// to private). Throws a readable error for a type or size the bucket
    /// does not accept.
    static func upload(
        shopID: UUID,
        owner: JobsDocument.Owner,
        data: Data,
        fileName: String,
        customerVisible: Bool = false
    ) async throws -> JobsDocument {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidInput("The file needs a name.") }
        guard let contentType = JobsDocument.contentType(forFileName: name) else {
            throw AppError.invalidInput("That file type can't be attached. Use a PDF, Word, Excel, text or image file.")
        }
        guard !data.isEmpty else { throw AppError.invalidInput("That file is empty.") }
        guard data.count <= JobsDocument.maxSizeBytes else {
            throw AppError.invalidInput("That file is larger than 25 MB.")
        }
        let path = [
            shopID.uuidString.lowercased(),
            owner.folderName,
            owner.recordID.uuidString.lowercased(),
            JobsDocument.objectFileName(for: name),
        ].joined(separator: "/")
        try await Supa.client.storage
            .from(bucket)
            .upload(path, data: data, options: FileOptions(contentType: contentType))

        var row: [String: AnyJSON] = [
            "shop_id": .string(shopID.uuidString),
            "storage_path": .string(path),
            "file_name": .string(String(name.prefix(255))),
            "content_type": .string(contentType),
            "size_bytes": .integer(data.count),
            "customer_visible": .bool(customerVisible),
        ]
        switch owner {
        case .job(let jobID): row["job_id"] = .string(jobID.uuidString)
        case .customer(let customerID): row["customer_id"] = .string(customerID.uuidString)
        }
        do {
            return try await Supa.client
                .from("documents")
                .insert(row)
                .select(JobsDocument.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            _ = try? await Supa.client.storage.from(bucket).remove(paths: [path])
            throw error
        }
    }

    /// Shows or hides a document on the customer's report / portal
    /// (managers+).
    static func setCustomerVisible(shopID: UUID, documentID: UUID, visible: Bool) async throws -> JobsDocument {
        try await Supa.client
            .from("documents")
            .update(["customer_visible": AnyJSON.bool(visible)])
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: documentID.uuidString)
            .select(JobsDocument.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Renames a document (managers+). The stored file keeps its key.
    static func rename(shopID: UUID, documentID: UUID, fileName: String) async throws -> JobsDocument {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(name.count) else {
            throw AppError.invalidInput("Enter a name of up to 255 characters.")
        }
        return try await Supa.client
            .from("documents")
            .update(["file_name": AnyJSON.string(name)])
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: documentID.uuidString)
            .select(JobsDocument.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Removes a document (managers+, or the uploader on a job they work).
    /// The server queues the stored file for removal.
    static func delete(_ document: JobsDocument) async throws {
        try await Supa.client
            .from("documents")
            .delete(returning: .minimal)
            .eq("shop_id", value: document.shopID.uuidString)
            .eq("id", value: document.id.uuidString)
            .execute()
    }

    /// A short-lived link to the stored file.
    static func signedURL(for document: JobsDocument) async throws -> URL {
        try await Supa.client.storage
            .from(bucket)
            .createSignedURL(path: document.storagePath, expiresIn: signedURLSeconds)
    }

    /// Downloads the file into a private temporary folder under its display
    /// name (for Quick Look / sharing) and returns the local URL.
    static func downloadForPreview(_ document: JobsDocument) async throws -> URL {
        let data = try await Supa.client.storage
            .from(bucket)
            .download(path: document.storagePath)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = document.fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(safeName.isEmpty ? "document" : safeName)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }
}
