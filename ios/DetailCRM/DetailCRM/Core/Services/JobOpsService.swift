//
//  JobOpsService.swift
//  DetailCRM
//
//  Field operations on a job (SPEC §4.6): checklist, photos, inspections
//  with damage marks and customer signature, and forms signed on device.
//
//  Storage paths follow the storage policies exactly:
//    job-photos  <shop_id>/<job_id>/<uuid>.jpg  — policy checks folder 1 is
//                a shop the caller works in and folder 2 a job they can work
//    signatures  <shop_id>/inspections/<inspection_id>/<uuid>.png
//                <shop_id>/job-forms/<submission_id>/<uuid>.png
//                — policy checks folder 1 is the caller's shop
//  Objects are uploaded first and the row written second (the database
//  checks the object exists); a failed row write removes the new object.
//

import Foundation
import Supabase

enum JobOpsService {

    static let photosBucket = "job-photos"
    static let signaturesBucket = "signatures"
    /// Signed URL lifetime for displaying private images.
    static let signedURLSeconds = 3600

    // MARK: - Checklist

    static func checklist(shopID: UUID, jobID: UUID) async throws -> [JobChecklistItem] {
        try await Supa.client
            .from("job_checklist_items")
            .select(JobChecklistItem.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Ticks or clears an item; the server stamps when and by whom.
    static func setChecklistItem(shopID: UUID, itemID: UUID, done: Bool) async throws -> JobChecklistItem {
        try await Supa.client
            .from("job_checklist_items")
            .update(JobChecklistDonePatch(doneAt: done ? Date() : nil))
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: itemID.uuidString)
            .select(JobChecklistItem.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Manager+: a one-off item at the end of the list.
    static func addChecklistItem(shopID: UUID, jobID: UUID, label: String, sort: Int) async throws -> JobChecklistItem {
        guard let trimmed = label.trimmedNonEmpty else {
            throw AppError.invalidInput("Enter what needs to be done.")
        }
        let row = JobChecklistInsert(shop_id: shopID, job_id: jobID, label: String(trimmed.prefix(200)), sort: sort)
        return try await Supa.client
            .from("job_checklist_items")
            .insert(row)
            .select(JobChecklistItem.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Manager+.
    /// Flags an item as required for completion, or not (managers+; the
    /// server refuses technicians).
    static func setChecklistItemRequired(shopID: UUID, itemID: UUID, required: Bool) async throws -> JobChecklistItem {
        try await Supa.client
            .from("job_checklist_items")
            .update(["required": AnyJSON.bool(required)])
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: itemID.uuidString)
            .select(JobChecklistItem.selectColumns)
            .single()
            .execute()
            .value
    }

    static func deleteChecklistItem(shopID: UUID, itemID: UUID) async throws {
        try await Supa.client
            .from("job_checklist_items")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: itemID.uuidString)
            .execute()
    }

    static func checklistTemplates(shopID: UUID) async throws -> [JobChecklistTemplateRef] {
        try await Supa.client
            .from("checklist_templates")
            .select("id,name")
            .eq("shop_id", value: shopID.uuidString)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Manager+: appends a template's items (items already attached from
    /// the same template are skipped by the server).
    static func applyChecklistTemplate(jobID: UUID, templateID: UUID) async throws {
        try await Supa.client
            .rpc("apply_checklist_template", params: JobApplyTemplateParams(p_job_id: jobID, p_template_id: templateID))
            .execute()
    }

    // MARK: - Photos

    static func photos(shopID: UUID, jobID: UUID) async throws -> [JobPhoto] {
        try await Supa.client
            .from("job_photos")
            .select(JobPhoto.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Photos with signed display URLs. A photo whose URL can't be signed
    /// here keeps a nil URL: its tile (JobStorageImage) signs one itself
    /// and shows a failure with Retry if that fails too.
    static func photoItems(shopID: UUID, jobID: UUID) async throws -> [JobPhotoItem] {
        let rows = try await photos(shopID: shopID, jobID: jobID)
        guard !rows.isEmpty else { return [] }
        // Images show themselves; videos show their poster frame (if any).
        let paths: [String?] = rows.map { $0.isVideo ? $0.posterPath : $0.storagePath }
        // Sign concurrently; keep the original order.
        let urls: [Int: URL] = await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, path) in paths.enumerated() {
                guard let path else { continue }
                group.addTask {
                    let url = try? await signedURL(bucket: photosBucket, path: path)
                    return (index, url)
                }
            }
            var collected: [Int: URL] = [:]
            for await (index, url) in group {
                if let url { collected[index] = url }
            }
            return collected
        }
        return rows.enumerated().map { index, photo in
            JobPhotoItem(photo: photo, url: urls[index])
        }
    }

    /// Uploads a prepared JPEG to `<shop_id>/<job_id>/<uuid>.jpg` and
    /// records the photo row.
    static func uploadPhoto(
        shopID: UUID,
        jobID: UUID,
        jpegData: Data,
        kind: JobPhotoKind,
        caption: String? = nil
    ) async throws -> JobPhoto {
        let path = try await uploadJobImage(shopID: shopID, jobID: jobID, jpegData: jpegData)
        let row = JobPhotoInsert(
            shop_id: shopID,
            job_id: jobID,
            storage_path: path,
            kind: kind.rawValue,
            caption: caption?.trimmedNonEmpty
        )
        do {
            return try await Supa.client
                .from("job_photos")
                .insert(row)
                .select(JobPhoto.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            await removeQuietly(bucket: photosBucket, path: path)
            throw error
        }
    }

    /// Deletes the photo row, then its file (own photos, or any as manager+).
    static func deletePhoto(_ photo: JobPhoto) async throws {
        try await Supa.client
            .from("job_photos")
            .delete(returning: .minimal)
            .eq("shop_id", value: photo.shopID.uuidString)
            .eq("id", value: photo.id.uuidString)
            .execute()
        // A video's file and poster are queued for removal by the server.
        if !photo.isVideo {
            await removeQuietly(bucket: photosBucket, path: photo.storagePath)
        }
    }

    // MARK: - Videos (P-30) and customer visibility (P-8)

    static let mediaBucket = "job-media"

    /// Records an uploaded video (the file is already in job-media and the
    /// poster in job-photos; the server checks both exist).
    static func insertVideo(
        shopID: UUID,
        jobID: UUID,
        storagePath: String,
        posterPath: String?,
        durationSeconds: Int,
        kind: JobPhotoKind
    ) async throws -> JobPhoto {
        var row: [String: AnyJSON] = [
            "shop_id": .string(shopID.uuidString),
            "job_id": .string(jobID.uuidString),
            "storage_path": .string(storagePath),
            "kind": .string(kind.rawValue),
            "media_type": .string("video"),
            "bucket": .string(mediaBucket),
            "duration_seconds": .integer(min(600, max(1, durationSeconds))),
        ]
        row["poster_path"] = posterPath.map { AnyJSON.string($0) } ?? .null
        return try await Supa.client
            .from("job_photos")
            .insert(row)
            .select(JobPhoto.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Uploads a video's poster frame next to the job's photos. The name
    /// is fixed per upload, so a retry after the video row failed to save
    /// overwrites the copy it already sent (upsert; the uploader may update
    /// its own object) instead of failing with 409 and losing the poster.
    static func uploadPoster(shopID: UUID, jobID: UUID, name: String, jpegData: Data) async throws -> String {
        let path = "\(shopID.uuidString.lowercased())/\(jobID.uuidString.lowercased())/\(name)"
        try await Supa.client.storage
            .from(photosBucket)
            .upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg", upsert: true))
        return path
    }

    /// A short-lived link to play a video.
    static func videoURL(_ photo: JobPhoto) async throws -> URL {
        try await signedURL(bucket: photo.storageBucket, path: photo.storagePath)
    }

    /// Shows or hides photos on the customer's job report (staff on the
    /// job). Returns how many changed.
    @discardableResult
    static func setPhotoVisibility(photoIDs: [UUID], visible: Bool) async throws -> Int {
        guard !photoIDs.isEmpty else { return 0 }
        let params: [String: AnyJSON] = [
            "p_photo_ids": .array(photoIDs.prefix(200).map { AnyJSON.string($0.uuidString) }),
            "p_visible": .bool(visible),
        ]
        return try await Supa.client
            .rpc("set_job_photo_visibility", params: params)
            .execute()
            .value
    }

    /// Uploads a JPEG into the job's photo folder and returns its path.
    static func uploadJobImage(shopID: UUID, jobID: UUID, jpegData: Data) async throws -> String {
        let path = "\(shopID.uuidString.lowercased())/\(jobID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await Supa.client.storage
            .from(photosBucket)
            .upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    // MARK: - Signed URLs & cleanup

    static func signedURL(bucket: String, path: String) async throws -> URL {
        try await Supa.client.storage
            .from(bucket)
            .createSignedURL(path: path, expiresIn: signedURLSeconds)
    }

    /// Best-effort removal of an object nobody references (e.g. after a
    /// failed row write). Errors are ignored: an orphaned file is harmless.
    static func removeQuietly(bucket: String, path: String) async {
        _ = try? await Supa.client.storage.from(bucket).remove(paths: [path])
    }

    // MARK: - Inspections

    /// The job's inspections with their marks.
    static func inspections(shopID: UUID, jobID: UUID) async throws -> [JobInspectionBundle] {
        let rows: [Inspection] = try await Supa.client
            .from("inspections")
            .select(Inspection.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        guard !rows.isEmpty else { return [] }
        let marks: [InspectionMark] = try await Supa.client
            .from("inspection_marks")
            .select(InspectionMark.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("inspection_id", values: rows.map { $0.id.uuidString })
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map { inspection in
            JobInspectionBundle(inspection: inspection, marks: marks.filter { $0.inspectionID == inspection.id })
        }
    }

    /// Starts a pre/post inspection for the job's vehicle.
    static func createInspection(shopID: UUID, jobID: UUID, vehicleID: UUID?, kind: JobInspectionKind) async throws -> Inspection {
        let row = JobInspectionInsert(shopID: shopID, jobID: jobID, vehicleID: vehicleID, kind: kind)
        return try await Supa.client
            .from("inspections")
            .insert(row)
            .select(Inspection.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Mileage, fuel level (0–100) and notes of an unsigned inspection.
    static func updateInspection(
        shopID: UUID,
        inspectionID: UUID,
        mileage: Int?,
        fuelLevel: Int?,
        notes: String?
    ) async throws -> Inspection {
        let patch = JobInspectionFieldsPatch(mileage: mileage, fuelLevel: fuelLevel, notes: notes?.trimmedNonEmpty)
        return try await Supa.client
            .from("inspections")
            .update(patch)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: inspectionID.uuidString)
            .select(Inspection.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Unsigned inspections only (signed ones are evidence).
    static func deleteInspection(shopID: UUID, inspectionID: UUID) async throws {
        try await Supa.client
            .from("inspections")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: inspectionID.uuidString)
            .execute()
    }

    /// Adds a damage mark; an optional photo is uploaded into the job's
    /// photo folder first.
    static func addMark(
        shopID: UUID,
        jobID: UUID,
        inspectionID: UUID,
        view: JobVehicleView,
        x: Double,
        y: Double,
        damage: JobDamageKind,
        note: String?,
        photoJPEG: Data?
    ) async throws -> InspectionMark {
        var photoPath: String?
        if let photoJPEG {
            photoPath = try await uploadJobImage(shopID: shopID, jobID: jobID, jpegData: photoJPEG)
        }
        let row = JobMarkInsert(
            shop_id: shopID,
            inspection_id: inspectionID,
            view: view.rawValue,
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            damage: damage.rawValue,
            note: note?.trimmedNonEmpty,
            photo_path: photoPath
        )
        do {
            return try await Supa.client
                .from("inspection_marks")
                .insert(row)
                .select(InspectionMark.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            if let photoPath {
                await removeQuietly(bucket: photosBucket, path: photoPath)
            }
            throw error
        }
    }

    static func deleteMark(shopID: UUID, markID: UUID) async throws {
        try await Supa.client
            .from("inspection_marks")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: markID.uuidString)
            .execute()
    }

    /// Uploads the customer's signature and signs (locks) the inspection.
    static func signInspection(
        shopID: UUID,
        inspectionID: UUID,
        signerName: String,
        signaturePNG: Data
    ) async throws -> Inspection {
        guard let name = signerName.trimmedNonEmpty else {
            throw AppError.invalidInput("Enter the name of the person signing.")
        }
        let folder = "inspections/\(inspectionID.uuidString.lowercased())"
        let path = try await uploadSignature(shopID: shopID, folder: folder, pngData: signaturePNG)
        do {
            return try await Supa.client
                .from("inspections")
                .update(JobInspectionSignPatch(customer_signature_path: path, signed_by_name: String(name.prefix(200))))
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: inspectionID.uuidString)
                .select(Inspection.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            await removeQuietly(bucket: signaturesBucket, path: path)
            throw error
        }
    }

    /// Uploads a PNG signature to `<shop_id>/<folder>/<uuid>.png`.
    static func uploadSignature(shopID: UUID, folder: String, pngData: Data) async throws -> String {
        let path = "\(shopID.uuidString.lowercased())/\(folder)/\(UUID().uuidString.lowercased()).png"
        try await Supa.client.storage
            .from(signaturesBucket)
            .upload(path, data: pngData, options: FileOptions(contentType: "image/png"))
        return path
    }

    // MARK: - Forms

    static func forms(shopID: UUID, jobID: UUID) async throws -> [FormSubmission] {
        try await Supa.client
            .from("form_submissions")
            .select(FormSubmission.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    static func formTemplates(shopID: UUID) async throws -> [JobFormTemplateRef] {
        try await Supa.client
            .from("form_templates")
            .select("id,name,requires_signature")
            .eq("shop_id", value: shopID.uuidString)
            .eq("active", value: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Manager+: attaches a template to the job (the server copies its
    /// title, body and signature requirement).
    static func attachForm(shopID: UUID, jobID: UUID, templateID: UUID) async throws -> FormSubmission {
        let row = JobFormAttachInsert(shop_id: shopID, job_id: jobID, form_template_id: templateID)
        return try await Supa.client
            .from("form_submissions")
            .insert(row)
            .select(FormSubmission.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Signs a form on this device: uploads the drawn signature (when
    /// given) and calls `sign_form_submission`.
    static func signForm(
        shopID: UUID,
        submissionID: UUID,
        signerName: String,
        signaturePNG: Data?
    ) async throws -> FormSubmission {
        guard let name = signerName.trimmedNonEmpty else {
            throw AppError.invalidInput("Enter the name of the person signing.")
        }
        var path: String?
        if let signaturePNG {
            let folder = "job-forms/\(submissionID.uuidString.lowercased())"
            path = try await uploadSignature(shopID: shopID, folder: folder, pngData: signaturePNG)
        }
        let params = JobSignFormParams(
            submissionID: submissionID,
            signerName: String(name.prefix(200)),
            signaturePath: path
        )
        do {
            return try await Supa.client
                .rpc("sign_form_submission", params: params)
                .select(FormSubmission.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            if let path {
                await removeQuietly(bucket: signaturesBucket, path: path)
            }
            throw error
        }
    }
}

// MARK: - Private wire types (file scope: never nest types in generic functions)

// table: job_checklist_items
private struct JobChecklistDonePatch: Encodable {
    let doneAt: Date?

    enum CodingKeys: String, CodingKey {
        case doneAt = "done_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(doneAt, forKey: .doneAt)
    }
}

private struct JobChecklistInsert: Encodable {
    let shop_id: UUID
    let job_id: UUID
    let label: String
    let sort: Int
}

private struct JobApplyTemplateParams: Encodable {
    let p_job_id: UUID
    let p_template_id: UUID
}

private struct JobPhotoInsert: Encodable {
    let shop_id: UUID
    let job_id: UUID
    let storage_path: String
    let kind: String
    let caption: String?
}

// table: inspections
private struct JobInspectionInsert: Encodable {
    let shopID: UUID
    let jobID: UUID
    let vehicleID: UUID?
    let kind: JobInspectionKind

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case jobID = "job_id"
        case vehicleID = "vehicle_id"
        case kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(jobID, forKey: .jobID)
        try container.encodeIfPresent(vehicleID, forKey: .vehicleID)
        try container.encode(kind, forKey: .kind)
    }
}

// table: inspections
private struct JobInspectionFieldsPatch: Encodable {
    let mileage: Int?
    let fuelLevel: Int?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case mileage
        case fuelLevel = "fuel_level"
        case notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mileage, forKey: .mileage)
        try container.encode(fuelLevel.map { min(max($0, 0), 100) }, forKey: .fuelLevel)
        try container.encode(notes, forKey: .notes)
    }
}

private struct JobInspectionSignPatch: Encodable {
    let customer_signature_path: String
    let signed_by_name: String
}

private struct JobMarkInsert: Encodable {
    let shop_id: UUID
    let inspection_id: UUID
    let view: String
    let x: Double
    let y: Double
    let damage: String
    let note: String?
    let photo_path: String?
}

private struct JobFormAttachInsert: Encodable {
    let shop_id: UUID
    let job_id: UUID
    let form_template_id: UUID
}

/// All three arguments are sent (the path as an explicit null when there
/// is no signature image).
// rpc: sign_form_submission
private struct JobSignFormParams: Encodable {
    let submissionID: UUID
    let signerName: String
    let signaturePath: String?

    enum CodingKeys: String, CodingKey {
        case submissionID = "p_submission_id"
        case signerName = "p_signer_name"
        case signaturePath = "p_signature_path"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(submissionID, forKey: .submissionID)
        try container.encode(signerName, forKey: .signerName)
        try container.encode(signaturePath, forKey: .signaturePath)
    }
}
