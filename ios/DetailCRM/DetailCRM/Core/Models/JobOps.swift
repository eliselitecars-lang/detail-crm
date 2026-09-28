//
//  JobOps.swift
//  DetailCRM
//
//  Field operations on a job (SPEC §4.6): checklist items, photos,
//  inspections with damage marks, and forms signed on device. Access is
//  the "staff on the job" rule (`can_work_job`): managers and above, or
//  members assigned to the job.
//
//  Storage layout (policies in 0025_field_ops_storage.sql):
//    job-photos  <shop_id>/<job_id>/<uuid>.jpg   (also inspection mark photos)
//    signatures  <shop_id>/...                    (inspection + form signatures)
//

import Foundation

// MARK: - Enums

/// `job_photo_kind`.
enum JobPhotoKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case before
    case after
    case inspection
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .before: return "Before"
        case .after: return "After"
        case .inspection: return "Inspection"
        case .other: return "Other"
        }
    }

    /// Kinds offered when uploading from the photos section.
    static let uploadChoices: [JobPhotoKind] = [.before, .after, .other]
}

/// `inspection_kind`: before (pre) or after (post) the work.
enum JobInspectionKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case pre
    case post

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pre: return "Pre-inspection"
        case .post: return "Post-inspection"
        }
    }
}

/// `vehicle_view`: the diagram a damage mark sits on.
enum JobVehicleView: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case front
    case rear
    case left
    case right
    case top
    case interior

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .front: return "Front"
        case .rear: return "Rear"
        case .left: return "Driver side"
        case .right: return "Passenger side"
        case .top: return "Top"
        case .interior: return "Interior"
        }
    }
}

/// `damage_kind`.
enum JobDamageKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case scratch
    case dent
    case chip
    case crack
    case stain
    case swirl
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scratch: return "Scratch"
        case .dent: return "Dent"
        case .chip: return "Chip"
        case .crack: return "Crack"
        case .stain: return "Stain"
        case .swirl: return "Swirls"
        case .other: return "Other"
        }
    }

    /// One-letter code drawn inside the mark pin.
    var code: String {
        switch self {
        case .scratch: return "S"
        case .dent: return "D"
        case .chip: return "C"
        case .crack: return "K"
        case .stain: return "T"
        case .swirl: return "W"
        case .other: return "O"
        }
    }
}

// MARK: - Checklist

// table: job_checklist_items
struct JobChecklistItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var label: String
    var sort: Int
    var doneAt: Date?
    var doneBy: UUID?
    var templateID: UUID?
    /// Must be done before the job can be completed (P-11; copied from the
    /// template, or flagged by a manager). Only managers change it.
    var required: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case label
        case sort
        case doneAt = "done_at"
        case doneBy = "done_by"
        case templateID = "template_id"
        case required
    }

    static let selectColumns = "id,shop_id,job_id,label,sort,done_at,done_by,template_id,required"

    var isDone: Bool { doneAt != nil }
    var isRequired: Bool { required ?? false }
}

/// A checklist template managers can apply to a job.
// table: checklist_templates
struct JobChecklistTemplateRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}

// MARK: - Photos

// table: job_photos
struct JobPhoto: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var storagePath: String
    var kind: JobPhotoKind
    var caption: String?
    var uploadedBy: UUID?
    var createdAt: Date
    /// Shown on the customer's job report (P-8) when its kind is included.
    var customerVisible: Bool?
    /// `image` (bucket job-photos) or `video` (bucket job-media, P-30).
    var mediaType: String?
    var bucket: String?
    var durationSeconds: Int?
    /// Video poster frame (a JPEG in job-photos).
    var posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case storagePath = "storage_path"
        case kind
        case caption
        case uploadedBy = "uploaded_by"
        case createdAt = "created_at"
        case customerVisible = "customer_visible"
        case mediaType = "media_type"
        case bucket
        case durationSeconds = "duration_seconds"
        case posterPath = "poster_path"
    }

    static let selectColumns = [
        "id", "shop_id", "job_id", "storage_path", "kind", "caption", "uploaded_by", "created_at",
        "customer_visible", "media_type", "bucket", "duration_seconds", "poster_path",
    ].joined(separator: ",")

    var isVideo: Bool { mediaType == "video" }
    var isCustomerVisible: Bool { customerVisible ?? false }
    /// The bucket holding `storage_path`.
    var storageBucket: String { bucket ?? (isVideo ? "job-media" : "job-photos") }

    /// "1:05".
    var durationText: String? {
        guard let durationSeconds else { return nil }
        return String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

/// A photo or video with a short-lived signed URL for display: the image
/// itself, or a video's poster frame (nil when signing failed). A video's
/// own URL is signed when it is played.
struct JobPhotoItem: Identifiable, Hashable, Sendable {
    var photo: JobPhoto
    var url: URL?

    var id: UUID { photo.id }
}

// MARK: - Inspections

// table: inspections
struct Inspection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var vehicleID: UUID?
    var kind: JobInspectionKind
    var mileage: Int?
    /// Fuel gauge reading in percent (0–100).
    var fuelLevel: Int?
    var notes: String?
    var customerSignaturePath: String?
    var signedByName: String?
    var signedAt: Date?
    var createdBy: UUID?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case vehicleID = "vehicle_id"
        case kind
        case mileage
        case fuelLevel = "fuel_level"
        case notes
        case customerSignaturePath = "customer_signature_path"
        case signedByName = "signed_by_name"
        case signedAt = "signed_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "shop_id", "job_id", "vehicle_id", "kind", "mileage", "fuel_level", "notes",
        "customer_signature_path", "signed_by_name", "signed_at", "created_by", "created_at",
    ].joined(separator: ",")

    /// Signed inspections are locked (a manager must remove the signature
    /// before anything changes).
    var isSigned: Bool { signedAt != nil }
}

// table: inspection_marks
struct InspectionMark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var inspectionID: UUID
    var view: JobVehicleView
    /// 0…1 across the diagram.
    var x: Double
    /// 0…1 down the diagram.
    var y: Double
    var damage: JobDamageKind
    var note: String?
    var photoPath: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case inspectionID = "inspection_id"
        case view
        case x
        case y
        case damage
        case note
        case photoPath = "photo_path"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,shop_id,inspection_id,view,x,y,damage,note,photo_path,created_at"
}

/// An inspection with its marks, as shown on the job.
struct JobInspectionBundle: Identifiable, Hashable, Sendable {
    var inspection: Inspection
    var marks: [InspectionMark]

    var id: UUID { inspection.id }

    func marks(on view: JobVehicleView) -> [InspectionMark] {
        marks.filter { $0.view == view }
    }
}

// MARK: - Forms

// table: form_submissions
struct FormSubmission: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var formTemplateID: UUID?
    var jobID: UUID
    var customerID: UUID?
    var title: String
    var bodySnapshot: String
    var requiresSignature: Bool
    var signerName: String?
    var signaturePath: String?
    var signedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case formTemplateID = "form_template_id"
        case jobID = "job_id"
        case customerID = "customer_id"
        case title
        case bodySnapshot = "body_snapshot"
        case requiresSignature = "requires_signature"
        case signerName = "signer_name"
        case signaturePath = "signature_path"
        case signedAt = "signed_at"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "shop_id", "form_template_id", "job_id", "customer_id", "title", "body_snapshot",
        "requires_signature", "signer_name", "signature_path", "signed_at", "created_at",
    ].joined(separator: ",")

    var isSigned: Bool { signedAt != nil }
}

/// An active form template managers can attach to a job.
// table: form_templates
struct JobFormTemplateRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var requiresSignature: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case requiresSignature = "requires_signature"
    }
}
