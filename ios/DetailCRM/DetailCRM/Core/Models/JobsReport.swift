//
//  JobsReport.swift
//  DetailCRM
//
//  The customer-facing job report (P-8, `public.job_reports`): a link
//  (`/r/<token>`, its own credential — never the booking token) showing the
//  before/after photos marked visible to the customer, the chosen
//  inspections (with remote sign-off of an unsigned pre-inspection) and the
//  job's customer-visible documents. Managers publish; technicians on the
//  job only when the shop allows it (they can then also read the token).
//

import Foundation

// table: job_reports
struct JobsReport: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var token: UUID
    var includeInspections: Bool
    /// Raw `job_photo_kind` values shown on the report.
    var photoKinds: [String]
    var message: String?
    var publishedAt: Date
    var revokedAt: Date?
    var firstViewedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case token
        case includeInspections = "include_inspections"
        case photoKinds = "photo_kinds"
        case message
        case publishedAt = "published_at"
        case revokedAt = "revoked_at"
        case firstViewedAt = "first_viewed_at"
    }

    static let selectColumns = [
        "id", "shop_id", "job_id", "token", "include_inspections", "photo_kinds", "message",
        "published_at", "revoked_at", "first_viewed_at",
    ].joined(separator: ",")

    var isLive: Bool { revokedAt == nil }

    /// The public link (`<web app>/r/<token>`), when the web app URL is set.
    var link: URL? {
        guard let base = AppConfig.webAppURL else { return nil }
        return base.appendingPathComponent("r").appendingPathComponent(token.uuidString.lowercased())
    }
}
