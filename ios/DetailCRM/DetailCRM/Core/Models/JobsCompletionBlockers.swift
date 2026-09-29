//
//  JobsCompletionBlockers.swift
//  DetailCRM
//
//  What still stands between a job and "in progress" / "completed" (P-11,
//  `job_completion_blockers`): open required checklist items and the
//  minimum before / after photos its services ask for. Only images count as
//  photos (videos don't). The server enforces the same gates on every
//  status change; managers can override them with a reason.
//

import Foundation
import Supabase
import DetailCore

// rpc: job_completion_blockers
struct JobsCompletionBlockers: Codable, Hashable, Sendable {
    /// (Nested JSON objects: property names are the keys.)
    struct Item: Codable, Hashable, Sendable, Identifiable {
        var id: UUID
        var label: String
    }

    struct PhotoCount: Codable, Hashable, Sendable {
        var required: Int
        var have: Int

        var missing: Int { max(0, required - have) }
    }

    var openRequiredItems: [Item]
    var beforePhotos: PhotoCount
    var afterPhotos: PhotoCount

    enum CodingKeys: String, CodingKey {
        case openRequiredItems = "open_required_items"
        case beforePhotos = "before_photos"
        case afterPhotos = "after_photos"
    }

    /// The gates that apply to a move to `status`: starting needs the
    /// before photos; completing needs the required items and the after
    /// photos. Other moves are never gated.
    func blocks(_ status: JobStatus) -> Bool {
        switch status {
        case .inProgress: return beforePhotos.missing > 0
        case .completed: return !openRequiredItems.isEmpty || afterPhotos.missing > 0
        default: return false
        }
    }

    /// Whether a move to `status` is one the server gates at all.
    static func isGated(_ status: JobStatus) -> Bool {
        status == .inProgress || status == .completed
    }
}

/// A move past the completion gates (P-11): a manager started or completed
/// the job with required checklist items or photo minimums still missing
/// (`set_job_status` with force). Everyone who can work the job reads the
/// trail (RLS `can_work_job`), so a job that skipped its requirements says
/// so on the job screen: who, when, why, and what was missing.
// table: job_gate_overrides
struct JobsGateOverride: Decodable, Identifiable, Hashable, Sendable {
    var id: UUID
    var toStatus: JobStatus
    var reason: String?
    /// The blocking part of the gate state that was waived (only the keys
    /// that blocked are present).
    var blockers: AnyJSON?
    /// Auth user id of the manager (nil once their account is gone).
    var overriddenBy: UUID?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case toStatus = "to_status"
        case reason
        case blockers
        case overriddenBy = "overridden_by"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "to_status", "reason", "blockers", "overridden_by", "created_at",
    ].joined(separator: ",")

    /// The snapshot read leniently: unknown or malformed parts are skipped.
    var waiver: GateWaiver {
        guard let snapshot = blockers?.asObject else { return GateWaiver() }
        let items = (snapshot["open_required_items"]?.asArray ?? []).compactMap { item in
            item.asObject?["label"]?.asString
        }
        return GateWaiver(
            openRequiredItems: items,
            afterPhotos: Self.count(snapshot["after_photos"]),
            beforePhotos: Self.count(snapshot["before_photos"])
        )
    }

    private static func count(_ json: AnyJSON?) -> GateWaiver.PhotoCount? {
        guard let object = json?.asObject,
              let required = object["required"]?.asInt,
              let have = object["have"]?.asInt else { return nil }
        return GateWaiver.PhotoCount(required: required, have: have)
    }
}
