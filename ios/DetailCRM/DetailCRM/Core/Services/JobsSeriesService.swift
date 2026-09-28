//
//  JobsSeriesService.swift
//  DetailCRM
//
//  Recurring appointments (P-1). Every call is manager+ (42501 otherwise);
//  unknown ids are P0002 and bad input 22023 with readable wording.
//

import Foundation
import Supabase

enum JobsSeriesService {

    /// Reply of `create_job_series`.
    // rpc: create_job_series
    struct Created: Decodable, Hashable, Sendable {
        var seriesID: UUID
        var jobsCreated: Int
        var firstJobID: UUID?

        enum CodingKeys: String, CodingKey {
            case seriesID = "series_id"
            case jobsCreated = "jobs_created"
            case firstJobID = "first_job_id"
        }
    }

    /// Reply of `update_job_series` / `end_job_series` / `delete_job_series`:
    /// how many future visits were replaced / removed and how many were kept
    /// (confirmed, paid, invoiced or moved by hand).
    // rpc: update_job_series
    struct Outcome: Decodable, Hashable, Sendable {
        var deleted: Int
        var created: Int?
        var kept: Int

        enum CodingKeys: String, CodingKey {
            case deleted
            case created
            case kept
        }

        /// "3 visits updated. 1 kept as it was (confirmed, paid or moved by hand)."
        func text(verb: String) -> String {
            let changed = created ?? deleted
            var parts: [String] = []
            parts.append(changed == 1 ? "1 visit \(verb)." : "\(changed) visits \(verb).")
            if kept > 0 {
                parts.append(kept == 1
                             ? "1 kept as it was (confirmed, paid, invoiced or moved by hand)."
                             : "\(kept) kept as they were (confirmed, paid, invoiced or moved by hand).")
            }
            return parts.joined(separator: " ")
        }
    }

    /// The series row (managers+).
    static func series(shopID: UUID, seriesID: UUID) async throws -> JobsSeries? {
        let rows: [JobsSeries] = try await Supa.client
            .from("job_series")
            .select(JobsSeries.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: seriesID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The next `count` visits a series would have (nothing is saved).
    static func preview(shopID: UUID, series: [String: AnyJSON], count: Int = 8) async throws -> [JobsSeriesOccurrence] {
        let params: [String: AnyJSON] = [
            "p_shop_id": .string(shopID.uuidString),
            "p_series": .object(series),
            "p_count": .integer(max(1, min(100, count))),
        ]
        return try await Supa.client
            .rpc("job_series_preview", params: params)
            .execute()
            .value
    }

    /// Creates the series and its first visits (atomically).
    static func create(shopID: UUID, series: [String: AnyJSON]) async throws -> Created {
        let params: [String: AnyJSON] = [
            "p_shop_id": .string(shopID.uuidString),
            "p_series": .object(series),
        ]
        return try await Supa.client
            .rpc("create_job_series", params: params)
            .execute()
            .value
    }

    /// "This and following": applies `patch` from `fromJobID` on (every
    /// future visit when nil).
    static func update(seriesID: UUID, patch: [String: AnyJSON], fromJobID: UUID?) async throws -> Outcome {
        let params: [String: AnyJSON] = [
            "p_series_id": .string(seriesID.uuidString),
            "p_patch": .object(patch),
            "p_from_job_id": fromJobID.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        return try await Supa.client
            .rpc("update_job_series", params: params)
            .execute()
            .value
    }

    /// Ends the series after `afterDay` (shop-local `YYYY-MM-DD`): later
    /// eligible visits are removed.
    static func end(seriesID: UUID, afterDay: String) async throws -> Outcome {
        let params: [String: AnyJSON] = [
            "p_series_id": .string(seriesID.uuidString),
            "p_after_date": .string(afterDay),
        ]
        return try await Supa.client
            .rpc("end_job_series", params: params)
            .execute()
            .value
    }

    /// Deletes the series: eligible visits are removed, the others become
    /// ordinary jobs.
    static func delete(seriesID: UUID) async throws -> Outcome {
        try await Supa.client
            .rpc("delete_job_series", params: ["p_series_id": seriesID.uuidString])
            .execute()
            .value
    }
}
