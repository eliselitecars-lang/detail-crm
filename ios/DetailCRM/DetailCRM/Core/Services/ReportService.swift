//
//  ReportService.swift
//  DetailCRM
//
//  Report RPCs (0047/0048). Dates are shop-local `yyyy-MM-dd` values the
//  server interprets in the shop's time zone; every amount is computed by
//  the server. `p_now` is never sent (the server uses its own clock for
//  API callers).
//

import Foundation
import Supabase
import DetailCore

enum ReportService {

    private struct RangeParams: Encodable {
        let p_shop_id: UUID
        let p_from: String
        let p_to: String
    }

    private struct RevenueParams: Encodable {
        let p_shop_id: UUID
        let p_from: String
        let p_to: String
        let p_bucket: String
    }

    private struct CustomersParams: Encodable {
        let p_shop_id: UUID
        let p_from: String
        let p_to: String
        let p_limit: Int
    }

    private struct ShopParams: Encodable {
        let p_shop_id: UUID
    }

    /// Cash revenue per bucket (empty buckets included).
    static func revenue(shopID: UUID, from: String, to: String, bucket: ReportBucket) async throws -> [ReportRevenueRow] {
        try await Supa.client
            .rpc("report_revenue", params: RevenueParams(p_shop_id: shopID, p_from: from, p_to: to, p_bucket: bucket.rawValue))
            .execute()
            .value
    }

    /// Totals for the whole range (`report_revenue_totals`, one row): the
    /// same received-payment rules as the buckets.
    static func revenueTotals(shopID: UUID, from: String, to: String) async throws -> ReportRevenueTotals {
        let rows: [ReportRevenueTotals] = try await Supa.client
            .rpc("report_revenue_totals", params: RangeParams(p_shop_id: shopID, p_from: from, p_to: to))
            .execute()
            .value
        guard let totals = rows.first else {
            throw AppError.message("The revenue totals are unavailable. Try again.")
        }
        return totals
    }

    /// Received payments per method.
    static func payments(shopID: UUID, from: String, to: String) async throws -> [ReportPaymentRow] {
        try await Supa.client
            .rpc("report_payments", params: RangeParams(p_shop_id: shopID, p_from: from, p_to: to))
            .execute()
            .value
    }

    /// Completed-job sales per service / custom line (ordered by net desc).
    static func salesByService(shopID: UUID, from: String, to: String) async throws -> [ReportServiceRow] {
        try await Supa.client
            .rpc("report_sales_by_service", params: RangeParams(p_shop_id: shopID, p_from: from, p_to: to))
            .execute()
            .value
    }

    /// Hours, jobs and attributed revenue per member (technicians: own row).
    static func team(shopID: UUID, from: String, to: String) async throws -> [ReportTeamRow] {
        try await Supa.client
            .rpc("report_team", params: RangeParams(p_shop_id: shopID, p_from: from, p_to: to))
            .execute()
            .value
    }

    /// Open receivables with aging buckets, as of now.
    static func outstanding(shopID: UUID) async throws -> ReportOutstanding {
        try await Supa.client
            .rpc("report_outstanding", params: ShopParams(p_shop_id: shopID))
            .execute()
            .value
    }

    /// New vs returning customers, average ticket, top customers.
    static func customers(shopID: UUID, from: String, to: String, limit: Int = 10) async throws -> ReportCustomers {
        try await Supa.client
            .rpc("report_customers", params: CustomersParams(p_shop_id: shopID, p_from: from, p_to: to, p_limit: limit))
            .execute()
            .value
    }
}
