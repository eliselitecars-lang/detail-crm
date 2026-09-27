//
//  Membership.swift
//  DetailCRM
//
//  Membership plans and customer memberships (SPEC §4.5). Billing lives in
//  Stripe (subscriptions on the shop's connected account); membership
//  status is Stripe-driven and written back by the webhook.
//

import Foundation
import DetailCore

/// `membership_interval`.
enum MembershipPlanInterval: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: return "Monthly"
        case .year: return "Yearly"
        }
    }
}

// table: membership_plans
struct MembershipPlan: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var name: String
    var planDescription: String?
    var priceCents: Int
    var interval: MembershipPlanInterval
    /// 1–12 for monthly plans; always 1 for yearly.
    var intervalCount: Int
    var includedServiceIDs: [UUID]
    /// Discount on other services, in basis points.
    var discountBps: Int
    var active: Bool
    var sort: Int
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case name
        case planDescription = "description"
        case priceCents = "price_cents"
        case interval
        case intervalCount = "interval_count"
        case includedServiceIDs = "included_service_ids"
        case discountBps = "discount_bps"
        case active
        case sort
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "name", "description", "price_cents", "interval", "interval_count",
        "included_service_ids", "discount_bps", "active", "sort", "archived_at",
        "created_at", "updated_at",
    ].joined(separator: ",")

    /// "per month", "every 3 months", "per year".
    var billingText: String {
        switch interval {
        case .year:
            return "per year"
        case .month:
            return intervalCount <= 1 ? "per month" : "every \(intervalCount) months"
        }
    }

    /// "10% off other services", when a discount applies.
    var discountText: String? {
        guard discountBps > 0 else { return nil }
        return "\(MoneyPercentFormat.text(basisPoints: discountBps)) off other services"
    }

    /// Can be used for new memberships.
    var isAvailable: Bool { active && archivedAt == nil }
}

// table: memberships
struct Membership: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var planID: UUID
    var customerID: UUID
    var vehicleID: UUID?
    var status: MembershipStatus
    var currentPeriodEnd: Date?
    var cancelAtPeriodEnd: Bool
    var startedAt: Date?
    var cancelledAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Whether Stripe has a subscription for it (the id itself is not kept
    /// in the app).
    var hasSubscription: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case planID = "plan_id"
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case status
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case startedAt = "started_at"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case stripeSubscriptionID = "stripe_subscription_id"
    }

    static let selectColumns = [
        "id", "shop_id", "plan_id", "customer_id", "vehicle_id", "status", "current_period_end",
        "cancel_at_period_end", "started_at", "cancelled_at", "created_at", "updated_at",
        "stripe_subscription_id",
    ].joined(separator: ",")

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        shopID = try c.decode(UUID.self, forKey: .shopID)
        planID = try c.decode(UUID.self, forKey: .planID)
        customerID = try c.decode(UUID.self, forKey: .customerID)
        vehicleID = try c.decodeIfPresent(UUID.self, forKey: .vehicleID)
        status = try c.decode(MembershipStatus.self, forKey: .status)
        currentPeriodEnd = try c.decodeIfPresent(Date.self, forKey: .currentPeriodEnd)
        cancelAtPeriodEnd = try c.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        let subscription = try c.decodeIfPresent(String.self, forKey: .stripeSubscriptionID)
        hasSubscription = !(subscription ?? "").isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(shopID, forKey: .shopID)
        try c.encode(planID, forKey: .planID)
        try c.encode(customerID, forKey: .customerID)
        try c.encodeIfPresent(vehicleID, forKey: .vehicleID)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(currentPeriodEnd, forKey: .currentPeriodEnd)
        try c.encode(cancelAtPeriodEnd, forKey: .cancelAtPeriodEnd)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(cancelledAt, forKey: .cancelledAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Waiting for the customer to finish Stripe Checkout.
    var needsCheckout: Bool { status == .incomplete && !hasSubscription }

    /// Can still be cancelled (not already cancelled or set to end).
    var canCancel: Bool { status != .cancelled && !cancelAtPeriodEnd }
}

/// Percent text from basis points: 1000 -> "10%", 1250 -> "12.5%".
enum MoneyPercentFormat {
    static func text(basisPoints: Int) -> String {
        let whole = basisPoints / 100
        let fraction = abs(basisPoints % 100)
        if fraction == 0 { return "\(whole)%" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)%" }
        return String(format: "%d.%02d%%", whole, fraction)
    }

    /// Parses "10", "12.5", "7.25" (percent) into basis points (0…10000).
    static func basisPoints(from text: String) -> Int? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeText = parts[0].isEmpty ? "0" : String(parts[0])
        let fractionText = parts.count == 2 ? String(parts[1]) : ""
        guard fractionText.count <= 2, let whole = Int(wholeText), whole <= 100 else { return nil }
        let padded = fractionText.padding(toLength: 2, withPad: "0", startingAt: 0)
        let fraction = Int(padded) ?? 0
        let bps = whole * 100 + fraction
        return bps <= 10_000 ? bps : nil
    }
}
