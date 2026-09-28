//
//  JobsDocument.swift
//  DetailCRM
//
//  Files on jobs and customers (P-25, `public.documents`, ops 0071/0075):
//  PDFs, Word/Excel files, text and images in the private `documents`
//  bucket at `<shop>/jobs/<job>/<file>` or `<shop>/customers/<customer>/<file>`.
//
//  Access (RLS): managers+ see and manage every document; staff on a job
//  see, add and remove their own uploads on that job. Only managers may
//  rename a file or show it to the customer (`customer_visible`, used by
//  the job report, booking page and client portal). A technician's upload
//  is always private.
//
//  Shared model: the jobs agent owns it; the customer screens (ops) use it
//  read-only through JobsDocumentService.
//

import Foundation

// table: documents
struct JobsDocument: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var customerID: UUID?
    var jobID: UUID?
    var storagePath: String
    var fileName: String
    var contentType: String
    var sizeBytes: Int
    var customerVisible: Bool
    var uploadedBy: UUID?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case customerID = "customer_id"
        case jobID = "job_id"
        case storagePath = "storage_path"
        case fileName = "file_name"
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
        case customerVisible = "customer_visible"
        case uploadedBy = "uploaded_by"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "shop_id", "customer_id", "job_id", "storage_path", "file_name", "content_type",
        "size_bytes", "customer_visible", "uploaded_by", "created_at",
    ].joined(separator: ",")

    /// Which record a document belongs to (also its storage folder).
    enum Owner: Hashable, Sendable {
        case job(UUID)
        case customer(UUID)

        /// The folder kind in the object path (`jobs` / `customers`).
        var folderName: String {
            switch self {
            case .job: return "jobs"
            case .customer: return "customers"
            }
        }

        var recordID: UUID {
            switch self {
            case .job(let id), .customer(let id): return id
            }
        }
    }

    /// The `documents` bucket accepts at most 25 MiB per file.
    static let maxSizeBytes = 26_214_400

    /// MIME types the `documents` bucket accepts (0071), by file extension.
    static let allowedTypes: [String: String] = [
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "txt": "text/plain",
        "csv": "text/csv",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
        "heic": "image/heic",
    ]

    /// The bucket's content type for a file name, or nil when not allowed.
    static func contentType(forFileName name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return allowedTypes[ext]
    }

    /// Object key segment for an uploaded file: a fresh uuid plus a safe
    /// version of the original name (letters, digits, `.`, `-`, `_`).
    static func objectFileName(for original: String, id: UUID = UUID()) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = String(original.map { allowed.contains($0) ? $0 : "-" })
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.suffix(80)) }
        let prefix = id.uuidString.lowercased()
        return cleaned.isEmpty ? prefix : prefix + "-" + cleaned
    }

    /// "PDF · 1.2 MB".
    var detailText: String {
        let kind = (fileName as NSString).pathExtension.uppercased()
        let size = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        return kind.isEmpty ? size : "\(kind) · \(size)"
    }

    /// SF Symbol for the file type.
    var systemImage: String {
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType == "application/pdf" { return "doc.richtext" }
        if contentType.contains("sheet") || contentType.contains("excel") || contentType == "text/csv" {
            return "tablecells"
        }
        return "doc.text"
    }
}
