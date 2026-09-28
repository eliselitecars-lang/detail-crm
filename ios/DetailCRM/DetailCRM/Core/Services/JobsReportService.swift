//
//  JobsReportService.swift
//  DetailCRM
//
//  Customer job reports (P-8): read the job's live report, publish (and
//  optionally text / email the link with the shop's "job report" message)
//  and revoke. Publishing again updates the live report and keeps its
//  link; after a revoke a new publish issues a new link.
//

import Foundation
import Supabase

enum JobsReportService {

    /// Reply of `publish_job_report`: the report, its link (null while the
    /// platform has no app URL — then nothing is sent) and whether a
    /// message was queued (false also when the template is switched off).
    // rpc: publish_job_report
    struct Published: Decodable, Hashable, Sendable {
        var reportID: UUID
        var token: UUID
        var url: String?
        var queued: Bool

        enum CodingKeys: String, CodingKey {
            case reportID = "report_id"
            case token
            case url
            case queued
        }
    }

    /// The job's live report, or nil (also when the caller may not see
    /// report links: technicians unless the shop allows sharing).
    static func liveReport(shopID: UUID, jobID: UUID) async throws -> JobsReport? {
        let rows: [JobsReport] = try await Supa.client
            .from("job_reports")
            .select(JobsReport.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .is("revoked_at", value: nil)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Publishes (or updates) the report. `send` queues the "job report"
    /// message on `channel`, or on every enabled channel when nil.
    static func publish(
        jobID: UUID,
        includeInspections: Bool,
        photoKinds: [JobPhotoKind],
        message: String?,
        send: Bool,
        channel: JobMessageChannel?
    ) async throws -> Published {
        let params: [String: AnyJSON] = [
            "p_job_id": .string(jobID.uuidString),
            "p_include_inspections": .bool(includeInspections),
            "p_photo_kinds": .array(photoKinds.map { AnyJSON.string($0.rawValue) }),
            "p_message": message.map { AnyJSON.string(String($0.prefix(2_000))) } ?? .null,
            "p_send": .bool(send),
            "p_channel": channel.map { AnyJSON.string($0.rawValue) } ?? .null,
        ]
        return try await Supa.client
            .rpc("publish_job_report", params: params)
            .execute()
            .value
    }

    /// Stops the link working (managers+).
    static func revoke(reportID: UUID) async throws {
        try await Supa.client
            .rpc("revoke_job_report", params: ["p_report_id": reportID.uuidString])
            .execute()
    }
}
