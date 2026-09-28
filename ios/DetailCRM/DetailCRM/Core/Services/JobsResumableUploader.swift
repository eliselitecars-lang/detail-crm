//
//  JobsResumableUploader.swift
//  DetailCRM
//
//  Resumable uploads (TUS 1.0.0) to Supabase Storage for job videos
//  (P-30): `<SUPABASE_URL>/storage/v1/upload/resumable`, 6 MB chunks (the
//  size Supabase requires for every chunk but the last), `x-upsert: false`.
//  Each upload's state (the file copied into Application Support, its
//  object name and the server's upload URL) is saved, so an upload cut
//  short by the app going to the background, a lost connection or a quit
//  continues from the last confirmed byte instead of starting over.
//
//  Uploads belong to the account that recorded them: only that user sees
//  and resumes them, a deliberate sign-out deletes every pending upload
//  (and its local copy; the sign-out confirmation names them, since the
//  camera recorder never saves to Photos), and signing in as someone else deletes the
//  previous accounts' ones. An expired session keeps them for when the
//  same user signs back in.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum JobsResumableUploader {

    /// Supabase's resumable endpoint requires 6 MB chunks.
    static let chunkSize = 6 * 1024 * 1024
    private static let storeKey = "detailcrm.resumableUploads"

    /// One upload in progress (persisted in UserDefaults).
    struct Upload: Codable, Hashable, Sendable, Identifiable {
        var id: UUID
        /// The signed-in user who recorded it (nil only for uploads saved
        /// before uploads were tied to an account; those are never resumed).
        var userID: UUID?
        var shopID: UUID
        var jobID: UUID
        var bucket: String
        var objectName: String
        var contentType: String
        /// File name inside the uploads folder (Application Support).
        var localFileName: String
        var size: Int
        /// The server's upload URL once created.
        var uploadURL: URL?
        /// Extra data the caller needs to finish (kept with the upload).
        var metadata: [String: String]
        var createdAt: Date
    }

    enum UploadError: LocalizedError {
        case notConfigured
        case server(Int, String)
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "The app isn't connected to a server."
            case .server(let status, let body):
                if status == 409 { return "That file was already uploaded." }
                if status == 413 { return "The video is too large to upload (the limit is 200 MB)." }
                if status == 401 || status == 403 { return "You can't add videos to this job." }
                let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "The upload failed (\(status)). Try again." : "The upload failed: \(text)"
            case .fileMissing:
                return "The recorded video is no longer on this iPhone. Record it again."
            }
        }
    }

    // MARK: - Persistence

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PendingUploads", isDirectory: true)
    }

    static func localURL(for upload: Upload) -> URL {
        folder.appendingPathComponent(upload.localFileName)
    }

    /// The poster frame kept next to a pending video.
    static func posterURL(for upload: Upload) -> URL {
        folder.appendingPathComponent(upload.id.uuidString.lowercased() + "-poster.jpg")
    }

    /// Every stored upload, of any account.
    private static func all(defaults: UserDefaults = .standard) -> [Upload] {
        guard let data = defaults.data(forKey: storeKey),
              let all = try? JSONDecoder().decode([Upload].self, from: data) else { return [] }
        return all
    }

    /// `userID`'s uploads not finished yet (optionally for one job). Nil
    /// (nobody signed in) lists none.
    static func pending(jobID: UUID? = nil, userID: UUID?, defaults: UserDefaults = .standard) -> [Upload] {
        guard let userID else { return [] }
        return all(defaults: defaults).filter { upload in
            upload.userID == userID && (jobID == nil || upload.jobID == jobID)
        }
    }

    private static func save(_ uploads: [Upload], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(uploads) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private static func store(_ upload: Upload) {
        var uploads = all()
        uploads.removeAll { $0.id == upload.id }
        uploads.append(upload)
        save(uploads)
    }

    /// Forgets an upload and deletes its local copy and poster frame.
    static func discard(_ upload: Upload) {
        save(all().filter { $0.id != upload.id })
        removeFiles(of: upload)
    }

    /// Deletes the pending uploads (and their local files) of every account
    /// but `userID`; nil deletes them all, with the whole uploads folder.
    /// Called on sign-out (nil) and when an account signs in.
    static func discardAll(keepingUserID userID: UUID?, defaults: UserDefaults = .standard) {
        let uploads = all(defaults: defaults)
        let kept = uploads.filter { userID != nil && $0.userID == userID }
        for upload in uploads where !kept.contains(where: { $0.id == upload.id }) {
            removeFiles(of: upload)
        }
        if kept.isEmpty {
            defaults.removeObject(forKey: storeKey)
            if userID == nil {
                try? FileManager.default.removeItem(at: folder)
            }
        } else if kept.count != uploads.count {
            save(kept, defaults: defaults)
        }
    }

    private static func removeFiles(of upload: Upload) {
        try? FileManager.default.removeItem(at: localURL(for: upload))
        try? FileManager.default.removeItem(at: posterURL(for: upload))
    }

    /// Copies a recorded file into the uploads folder and records the
    /// upload (nothing is sent yet).
    static func prepare(
        fileAt source: URL,
        userID: UUID,
        shopID: UUID,
        jobID: UUID,
        bucket: String,
        objectName: String,
        contentType: String,
        metadata: [String: String]
    ) throws -> Upload {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let name = id.uuidString.lowercased() + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        let reader = try FileHandle(forReadingFrom: destination)
        let size = Int(try reader.seekToEnd())
        try reader.close()
        let upload = Upload(
            id: id,
            userID: userID,
            shopID: shopID,
            jobID: jobID,
            bucket: bucket,
            objectName: objectName,
            contentType: contentType,
            localFileName: name,
            size: size,
            uploadURL: nil,
            metadata: metadata,
            createdAt: Date()
        )
        store(upload)
        return upload
    }

    // MARK: - Upload

    /// Sends the file (resuming when the server already has part of it).
    /// `progress` gets 0…1. Returns once the whole file is stored; the
    /// caller then records the row and calls `discard`.
    static func run(
        _ upload: Upload,
        accessToken: String,
        progress: @escaping @Sendable (Double) -> Void,
        session: URLSession = .shared
    ) async throws {
        guard let base = AppConfig.supabaseURL, AppConfig.isConfigured else { throw UploadError.notConfigured }
        let fileURL = localURL(for: upload)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw UploadError.fileMissing }
        var current = upload
        var offset = 0
        if let existing = current.uploadURL, let known = try? await remoteOffset(existing, token: accessToken, session: session) {
            offset = known
        } else {
            do {
                current.uploadURL = try await create(current, base: base, token: accessToken, session: session)
            } catch UploadError.server(409, _) where current.uploadURL != nil {
                // The earlier run finished the file (the server forgets a
                // completed upload): the object is already stored.
                progress(1)
                return
            }
            store(current)
        }
        guard let uploadURL = current.uploadURL else { throw UploadError.server(0, "") }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        progress(Double(offset) / Double(max(current.size, 1)))
        while offset < current.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let length = min(chunkSize, current.size - offset)
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { throw UploadError.fileMissing }
            offset = try await patch(uploadURL, offset: offset, data: chunk, token: accessToken, session: session)
            progress(Double(offset) / Double(max(current.size, 1)))
        }
    }

    // MARK: - TUS requests

    private static func baseRequest(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        return request
    }

    /// POST: creates the upload; returns its URL (the Location header).
    private static func create(_ upload: Upload, base: URL, token: String, session: URLSession) async throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let prefix = components?.path.hasSuffix("/") == true ? String(components?.path.dropLast() ?? "") : (components?.path ?? "")
        components?.path = prefix + "/storage/v1/upload/resumable"
        guard let endpoint = components?.url else { throw UploadError.notConfigured }
        var request = baseRequest(endpoint, method: "POST", token: token)
        request.setValue(String(upload.size), forHTTPHeaderField: "Upload-Length")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let metadata = [
            ("bucketName", upload.bucket),
            ("objectName", upload.objectName),
            ("contentType", upload.contentType),
            ("cacheControl", "3600"),
        ].map { key, value in key + " " + Data(value.utf8).base64EncodedString() }.joined(separator: ",")
        request.setValue(metadata, forHTTPHeaderField: "Upload-Metadata")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.server(0, "") }
        guard http.statusCode == 201, let location = http.value(forHTTPHeaderField: "Location") else {
            throw UploadError.server(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let url = URL(string: location, relativeTo: endpoint)?.absoluteURL else {
            throw UploadError.server(http.statusCode, "The server returned an invalid upload address.")
        }
        return url
    }

    /// HEAD: how many bytes the server already has.
    private static func remoteOffset(_ url: URL, token: String, session: URLSession) async throws -> Int {
        let request = baseRequest(url, method: "HEAD", token: token)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = http.value(forHTTPHeaderField: "Upload-Offset"), let offset = Int(value) else {
            throw UploadError.server((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        return offset
    }

    /// PATCH: sends one chunk; returns the new offset.
    private static func patch(_ url: URL, offset: Int, data: Data, token: String, session: URLSession) async throws -> Int {
        var request = baseRequest(url, method: "PATCH", token: token)
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw UploadError.server(0, "") }
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw UploadError.server(http.statusCode, String(decoding: body, as: UTF8.self))
        }
        if let value = http.value(forHTTPHeaderField: "Upload-Offset"), let next = Int(value) {
            return next
        }
        return offset + data.count
    }
}
