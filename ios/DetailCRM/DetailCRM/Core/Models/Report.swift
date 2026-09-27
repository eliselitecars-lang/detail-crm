//
//  Report.swift
//  DetailCRM
//
//  Results of the report RPCs (0047/0048, SPEC §4.8) and the shop-timezone
//  date range the Reports screen asks for. Every amount is integer cents
//  computed by the server; the app only displays them.
//
//  Access (server-enforced): revenue / payments / outstanding / sales by
//  service / customers are owner/admin/manager only (technicians get
//  42501); report_team returns every member for managers+ (pay columns
//  null for managers) and only the caller's own row for technicians.
//

import Foundation
import DetailCore

// MARK: - Date range

/// Quick ranges, computed in the SHOP time zone.
enum ReportRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case thisWeek
    case thisMonth
    case lastMonth
    case last30Days
    case thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last30Days: return "Last 30 days"
        case .thisYear: return "This year"
        }
    }

    /// The inclusive shop-local day range for this preset at `now`.
    func range(clock: ShopClock, now: Date = Date()) -> ReportDateRange {
        let today = clock.startOfDay(now)
        switch self {
        case .today:
            return ReportDateRange(firstDay: today, lastDay: today)
        case .thisWeek:
            let week = clock.weekInterval(containing: today)
            return ReportDateRange(firstDay: week.start, lastDay: clock.addingDays(-1, to: week.end))
        case .thisMonth:
            let month = clock.monthInterval(containing: today)
            return ReportDateRange(firstDay: month.start, lastDay: clock.addingDays(-1, to: month.end))
        case .lastMonth:
            let current = clock.monthInterval(containing: today)
            let previous = clock.monthInterval(containing: clock.addingDays(-1, to: current.start))
            return ReportDateRange(firstDay: previous.start, lastDay: clock.addingDays(-1, to: previous.end))
        case .last30Days:
            return ReportDateRange(firstDay: clock.addingDays(-29, to: today), lastDay: today)
        case .thisYear:
            var components = clock.calendar.dateComponents([.year], from: today)
            components.month = 1
            components.day = 1
            let start = clock.calendar.date(from: components).map { clock.startOfDay($0) } ?? today
            var endComponents = DateComponents()
            endComponents.year = 1
            let nextYear = clock.calendar.date(byAdding: endComponents, to: start) ?? clock.addingDays(365, to: start)
            return ReportDateRange(firstDay: start, lastDay: clock.addingDays(-1, to: nextYear))
        }
    }
}

/// Inclusive range of shop-local days (both are shop-local midnights).
struct ReportDateRange: Equatable, Sendable {
    var firstDay: Date
    var lastDay: Date

    /// `yyyy-MM-dd` values for the RPCs' `date` parameters.
    func fromString(_ clock: ShopClock) -> String { clock.dateString(firstDay) }
    func toString(_ clock: ShopClock) -> String { clock.dateString(lastDay) }

    /// Number of days in the range (at least 1).
    func dayCount(_ clock: ShopClock) -> Int {
        max(1, clock.days(from: firstDay, to: clock.addingDays(1, to: lastDay)).count)
    }

    /// Chart bucket the revenue report uses for this range length.
    func bucket(_ clock: ShopClock) -> ReportBucket {
        let days = dayCount(clock)
        if days <= 31 { return .day }
        if days <= 190 { return .week }
        return .month
    }

    /// "Sep 1 – Sep 30" style label in the shop time zone.
    func label(_ clock: ShopClock) -> String {
        if clock.isSameDay(firstDay, lastDay) {
            return clock.shortDayText(firstDay)
        }
        return "\(clock.shortDayText(firstDay)) – \(clock.shortDayText(lastDay))"
    }
}

/// `p_bucket` of report_revenue.
enum ReportBucket: String, Sendable {
    case day
    case week
    case month
}

// MARK: - Lenient date parsing for jsonb / date values

enum ReportDateParsing {

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses Postgres timestamptz text as found in jsonb
    /// (`2026-09-27T10:00:00.123456+00:00`, `…Z`, with or without a
    /// fraction). Fractions longer than milliseconds are trimmed first.
    static func timestamp(_ text: String?) -> Date? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let dot = normalized.firstIndex(of: ".") {
            let afterDot = normalized.index(after: dot)
            var end = afterDot
            while end < normalized.endIndex, normalized[end].isNumber {
                end = normalized.index(after: end)
            }
            let digits = normalized[afterDot..<end]
            if digits.count > 3 {
                let kept = String(digits.prefix(3))
                normalized.replaceSubrange(afterDot..<end, with: kept)
            }
        }
        if let date = withFraction.date(from: normalized) { return date }
        if let date = withoutFraction.date(from: normalized) { return date }
        return nil
    }
}

// MARK: - report_revenue

// rpc: report_revenue
struct ReportRevenueRow: Codable, Identifiable, Hashable, Sendable {
    /// `yyyy-MM-dd` — natural start of the bucket (can precede the range).
    var bucketStart: String
    var grossCents: Int
    var refundsCents: Int
    var netCents: Int
    var tipsCents: Int
    var paymentsCount: Int

    var id: String { bucketStart }

    enum CodingKeys: String, CodingKey {
        case bucketStart = "bucket_start"
        case grossCents = "gross_cents"
        case refundsCents = "refunds_cents"
        case netCents = "net_cents"
        case tipsCents = "tips_cents"
        case paymentsCount = "payments_count"
    }
}

// MARK: - report_payments

// rpc: report_payments
struct ReportPaymentRow: Codable, Identifiable, Hashable, Sendable {
    var method: String
    var paymentsCount: Int
    var grossCents: Int
    var refundsCents: Int
    var netCents: Int
    var tipsCents: Int
    var tipRefundsCents: Int
    var collectedCents: Int
    var depositsCents: Int
    var membershipsCents: Int

    var id: String { method }

    enum CodingKeys: String, CodingKey {
        case method
        case paymentsCount = "payments_count"
        case grossCents = "gross_cents"
        case refundsCents = "refunds_cents"
        case netCents = "net_cents"
        case tipsCents = "tips_cents"
        case tipRefundsCents = "tip_refunds_cents"
        case collectedCents = "collected_cents"
        case depositsCents = "deposits_cents"
        case membershipsCents = "memberships_cents"
    }

    var methodName: String {
        PaymentMethod(rawValue: method)?.displayName ?? method.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - report_sales_by_service

// rpc: report_sales_by_service
struct ReportServiceRow: Codable, Identifiable, Hashable, Sendable {
    var serviceID: UUID?
    var serviceName: String
    var serviceKind: String?
    var categoryID: UUID?
    var categoryName: String?
    var quantity: Double
    var jobsCount: Int
    var grossCents: Int
    var discountCents: Int
    var netCents: Int

    /// Catalog services by id; custom lines (no service) by name.
    var id: String { serviceID?.uuidString ?? "custom:\(serviceName)" }

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case serviceName = "service_name"
        case serviceKind = "service_kind"
        case categoryID = "category_id"
        case categoryName = "category_name"
        case quantity
        case jobsCount = "jobs_count"
        case grossCents = "gross_cents"
        case discountCents = "discount_cents"
        case netCents = "net_cents"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceID = try container.decodeIfPresent(UUID.self, forKey: .serviceID)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName) ?? "Custom item"
        serviceKind = try container.decodeIfPresent(String.self, forKey: .serviceKind)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        quantity = try container.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        jobsCount = try container.decodeIfPresent(Int.self, forKey: .jobsCount) ?? 0
        grossCents = try container.decodeIfPresent(Int.self, forKey: .grossCents) ?? 0
        discountCents = try container.decodeIfPresent(Int.self, forKey: .discountCents) ?? 0
        netCents = try container.decodeIfPresent(Int.self, forKey: .netCents) ?? 0
    }

    /// "3" / "2.5" — quantity without trailing zeros.
    var quantityText: String {
        if quantity.rounded() == quantity, abs(quantity) < 1e12 {
            return String(Int(quantity))
        }
        return String(format: "%.2f", quantity)
    }
}

// MARK: - report_team

// rpc: report_team
struct ReportTeamRow: Codable, Identifiable, Hashable, Sendable {
    var memberID: UUID
    var displayName: String
    var role: ShopRole
    var active: Bool
    var workedSeconds: Int
    var hours: Double
    var jobsCompleted: Int
    var revenueCents: Int
    var preTaxRevenueCents: Int
    /// Pay columns: null for managers (owner/admin only) — shown only when returned.
    var hourlyRateCents: Int?
    var commissionBps: Int?
    var commissionCents: Int?
    var laborCostCents: Int?

    var id: UUID { memberID }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case displayName = "display_name"
        case role
        case active
        case workedSeconds = "worked_seconds"
        case hours
        case jobsCompleted = "jobs_completed"
        case revenueCents = "revenue_cents"
        case preTaxRevenueCents = "pre_tax_revenue_cents"
        case hourlyRateCents = "hourly_rate_cents"
        case commissionBps = "commission_bps"
        case commissionCents = "commission_cents"
        case laborCostCents = "labor_cost_cents"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try container.decode(UUID.self, forKey: .memberID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Team member"
        role = try container.decode(ShopRole.self, forKey: .role)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        workedSeconds = try container.decodeIfPresent(Int.self, forKey: .workedSeconds) ?? 0
        hours = try container.decodeIfPresent(Double.self, forKey: .hours) ?? 0
        jobsCompleted = try container.decodeIfPresent(Int.self, forKey: .jobsCompleted) ?? 0
        revenueCents = try container.decodeIfPresent(Int.self, forKey: .revenueCents) ?? 0
        preTaxRevenueCents = try container.decodeIfPresent(Int.self, forKey: .preTaxRevenueCents) ?? 0
        hourlyRateCents = try container.decodeIfPresent(Int.self, forKey: .hourlyRateCents)
        commissionBps = try container.decodeIfPresent(Int.self, forKey: .commissionBps)
        commissionCents = try container.decodeIfPresent(Int.self, forKey: .commissionCents)
        laborCostCents = try container.decodeIfPresent(Int.self, forKey: .laborCostCents)
    }

    /// Whether the server returned any compensation column for this row.
    var hasPayColumns: Bool {
        hourlyRateCents != nil || commissionBps != nil || commissionCents != nil || laborCostCents != nil
    }
}

// MARK: - report_outstanding (jsonb)

// rpc: report_outstanding
struct ReportOutstanding: Decodable, Hashable, Sendable {
    var count: Int
    var balanceCents: Int
    var overdueCount: Int
    var overdueBalanceCents: Int
    var buckets: [ReportOutstandingBucket]
    var invoices: [ReportOutstandingInvoice]

    enum CodingKeys: String, CodingKey {
        case count
        case balanceCents = "balance_cents"
        case overdueCount = "overdue_count"
        case overdueBalanceCents = "overdue_balance_cents"
        case buckets
        case invoices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        balanceCents = try container.decodeIfPresent(Int.self, forKey: .balanceCents) ?? 0
        overdueCount = try container.decodeIfPresent(Int.self, forKey: .overdueCount) ?? 0
        overdueBalanceCents = try container.decodeIfPresent(Int.self, forKey: .overdueBalanceCents) ?? 0
        buckets = try container.decodeIfPresent([ReportOutstandingBucket].self, forKey: .buckets) ?? []
        invoices = try container.decodeIfPresent([ReportOutstandingInvoice].self, forKey: .invoices) ?? []
    }
}

/// One aging bucket: `0-30`, `31-60`, `61-90`, `90+` days past due.
// rpc: report_outstanding
struct ReportOutstandingBucket: Decodable, Identifiable, Hashable, Sendable {
    var bucket: String
    var count: Int
    var balanceCents: Int

    var id: String { bucket }

    enum CodingKeys: String, CodingKey {
        case bucket
        case count
        case balanceCents = "balance_cents"
    }

    var title: String { "\(bucket) days" }
}

/// An open invoice in the aging report. Dates arrive as jsonb text.
// rpc: report_outstanding
struct ReportOutstandingInvoice: Decodable, Identifiable, Hashable, Sendable {
    var invoiceID: UUID
    var number: Int?
    var status: String?
    var customerID: UUID?
    var customerName: String?
    var jobID: UUID?
    var issuedAt: Date?
    var dueAt: Date?
    var totalCents: Int
    var amountPaidCents: Int
    var balanceCents: Int
    var daysPastDue: Int
    var overdue: Bool
    var bucket: String?

    var id: UUID { invoiceID }

    enum CodingKeys: String, CodingKey {
        case invoiceID = "invoice_id"
        case number
        case status
        case customerID = "customer_id"
        case customerName = "customer_name"
        case jobID = "job_id"
        case issuedAt = "issued_at"
        case dueAt = "due_at"
        case totalCents = "total_cents"
        case amountPaidCents = "amount_paid_cents"
        case balanceCents = "balance_cents"
        case daysPastDue = "days_past_due"
        case overdue
        case bucket
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invoiceID = try container.decode(UUID.self, forKey: .invoiceID)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        customerID = try container.decodeIfPresent(UUID.self, forKey: .customerID)
        customerName = try container.decodeIfPresent(String.self, forKey: .customerName)
        jobID = try container.decodeIfPresent(UUID.self, forKey: .jobID)
        issuedAt = ReportDateParsing.timestamp(try container.decodeIfPresent(String.self, forKey: .issuedAt))
        dueAt = ReportDateParsing.timestamp(try container.decodeIfPresent(String.self, forKey: .dueAt))
        totalCents = try container.decodeIfPresent(Int.self, forKey: .totalCents) ?? 0
        amountPaidCents = try container.decodeIfPresent(Int.self, forKey: .amountPaidCents) ?? 0
        balanceCents = try container.decodeIfPresent(Int.self, forKey: .balanceCents) ?? 0
        daysPastDue = try container.decodeIfPresent(Int.self, forKey: .daysPastDue) ?? 0
        overdue = try container.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
    }
}

// MARK: - report_customers (jsonb)

// rpc: report_customers
struct ReportCustomers: Decodable, Hashable, Sendable {
    var customersServed: Int
    var newCustomers: Int
    var returningCustomers: Int
    var customersCreated: Int
    var completedJobs: Int
    /// Null when no job was completed in the range.
    var averageTicketCents: Int?
    var topCustomers: [ReportTopCustomer]

    enum CodingKeys: String, CodingKey {
        case customersServed = "customers_served"
        case newCustomers = "new_customers"
        case returningCustomers = "returning_customers"
        case customersCreated = "customers_created"
        case completedJobs = "completed_jobs"
        case averageTicketCents = "average_ticket_cents"
        case topCustomers = "top_customers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customersServed = try container.decodeIfPresent(Int.self, forKey: .customersServed) ?? 0
        newCustomers = try container.decodeIfPresent(Int.self, forKey: .newCustomers) ?? 0
        returningCustomers = try container.decodeIfPresent(Int.self, forKey: .returningCustomers) ?? 0
        customersCreated = try container.decodeIfPresent(Int.self, forKey: .customersCreated) ?? 0
        completedJobs = try container.decodeIfPresent(Int.self, forKey: .completedJobs) ?? 0
        averageTicketCents = try container.decodeIfPresent(Int.self, forKey: .averageTicketCents)
        topCustomers = try container.decodeIfPresent([ReportTopCustomer].self, forKey: .topCustomers) ?? []
    }
}

/// One entry of report_customers.top_customers.
// rpc: report_customers
struct ReportTopCustomer: Decodable, Identifiable, Hashable, Sendable {
    var customerID: UUID
    var name: String
    var lifetimeNetCents: Int
    var completedJobs: Int
    var lastCompletedAt: Date?

    var id: UUID { customerID }

    enum CodingKeys: String, CodingKey {
        case customerID = "customer_id"
        case name
        case lifetimeNetCents = "lifetime_net_cents"
        case completedJobs = "completed_jobs"
        case lastCompletedAt = "last_completed_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customerID = try container.decode(UUID.self, forKey: .customerID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Customer"
        lifetimeNetCents = try container.decodeIfPresent(Int.self, forKey: .lifetimeNetCents) ?? 0
        completedJobs = try container.decodeIfPresent(Int.self, forKey: .completedJobs) ?? 0
        lastCompletedAt = ReportDateParsing.timestamp(try container.decodeIfPresent(String.self, forKey: .lastCompletedAt))
    }
}
