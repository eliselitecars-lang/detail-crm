//
//  OpsLeadSourceRow.swift
//  DetailCRM
//
//  Lead-source report (P-33, `report_lead_sources`, ops 0078): per customer
//  source, the customers added in the range, how many are still open leads,
//  how many converted (lifecycle `customer`, or a completed job by the end
//  of the range), the pre-tax value of their first completed job and what
//  they paid by the end of the range (net of refunds, tips excluded; this
//  includes deposits on jobs that are not completed yet). Merged duplicates
//  are left out by the server.
//  Owners / admins / managers only.
//

import Foundation

// rpc: report_lead_sources
struct OpsLeadSourceRow: Codable, Identifiable, Hashable, Sendable {
    /// `customer_source` value (staff, online_booking, referral, …).
    var source: String
    var customersCount: Int
    /// Still open leads: lifecycle `lead` with no completed job by the end
    /// of the range.
    var leadsCount: Int
    /// Lifecycle `customer` (staff-added customers usually are), or a
    /// completed job by the end of the range.
    var convertedCount: Int
    /// Subtotal minus discount of each customer's first completed job.
    var firstJobRevenueCents: Int
    /// Net payments (refunds taken off, tips excluded) by these customers
    /// up to the end of the range, whether or not the job is completed.
    var revenueCents: Int

    var id: String { source }

    enum CodingKeys: String, CodingKey {
        case source
        case customersCount = "customers_count"
        case leadsCount = "leads_count"
        case convertedCount = "converted_count"
        case firstJobRevenueCents = "first_job_revenue_cents"
        case revenueCents = "revenue_cents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        customersCount = try c.decodeIfPresent(Int.self, forKey: .customersCount) ?? 0
        leadsCount = try c.decodeIfPresent(Int.self, forKey: .leadsCount) ?? 0
        convertedCount = try c.decodeIfPresent(Int.self, forKey: .convertedCount) ?? 0
        firstJobRevenueCents = try c.decodeIfPresent(Int.self, forKey: .firstJobRevenueCents) ?? 0
        revenueCents = try c.decodeIfPresent(Int.self, forKey: .revenueCents) ?? 0
    }

    /// "Online booking", "Walk-in", … (the raw value for anything new).
    var sourceName: String {
        Customer.Source(rawValue: source)?.displayName
            ?? source.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Share of this source's new customers counted as converted (see
    /// `convertedCount`), in basis points; nil when the source added nobody.
    var conversionBps: Int? {
        guard customersCount > 0 else { return nil }
        return Int((Double(convertedCount) * 10_000 / Double(customersCount)).rounded())
    }

    /// Sources that added anyone or brought revenue in the range, busiest
    /// first (ties keep the server's order).
    static func active(_ rows: [OpsLeadSourceRow]) -> [OpsLeadSourceRow] {
        let indexed = rows.enumerated().filter { $0.element.customersCount > 0 || $0.element.revenueCents > 0 }
        return indexed
            .sorted { lhs, rhs in
                if lhs.element.customersCount != rhs.element.customersCount {
                    return lhs.element.customersCount > rhs.element.customersCount
                }
                if lhs.element.revenueCents != rhs.element.revenueCents {
                    return lhs.element.revenueCents > rhs.element.revenueCents
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
