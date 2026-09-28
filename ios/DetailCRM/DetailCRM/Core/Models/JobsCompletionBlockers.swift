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
