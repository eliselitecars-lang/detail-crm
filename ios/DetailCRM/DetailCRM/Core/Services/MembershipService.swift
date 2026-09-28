//
//  MembershipService.swift
//  DetailCRM
//
//  Membership plans (manager+ edit basic fields; changing billing terms
//  detaches the Stripe price server-side so existing subscribers keep
//  theirs) and customer memberships: `create_membership` makes an
//  incomplete membership, the payments edge function mints the Stripe
//  Checkout link (`membership_checkout`) and cancels (`membership_cancel`).
//

import Foundation
import Supabase
import DetailCore

enum MembershipService {

    // MARK: - Plans

    /// Plans that are not archived, in display order.
    static func plans(shopID: UUID) async throws -> [MembershipPlan] {
        try await Supa.client
            .from("membership_plans")
            .select(MembershipPlan.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Editable plan fields. Price is the shop's own price for the plan.
    struct PlanDraft: Hashable, Sendable {
        var planID: UUID?
        var name: String = ""
        var planDescription: String = ""
        var priceCents: Int = 0
        var interval: MembershipPlanInterval = .month
        var intervalCount: Int = 1
        var discountBps: Int = 0
        var active: Bool = true
        /// Offered on the shop's public join page.
        var onlineJoinable: Bool = false
        /// Included visits per billing period; nil = unlimited.
        var includedUsesPerPeriod: Int?
        var terms: String = ""

        init() {}

        init(plan: MembershipPlan) {
            planID = plan.id
            name = plan.name
            planDescription = plan.planDescription ?? ""
            priceCents = plan.priceCents
            interval = plan.interval
            intervalCount = plan.intervalCount
            discountBps = plan.discountBps
            active = plan.active
            onlineJoinable = plan.onlineJoinable
            includedUsesPerPeriod = plan.includedUsesPerPeriod
            terms = plan.terms ?? ""
        }
    }

    /// Longest plan terms the server accepts.
    static let maxTermsLength = 5_000

    /// Creates or updates a plan; returns its id.
    @discardableResult
    static func savePlan(shopID: UUID, draft: PlanDraft) async throws -> UUID {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidInput("Enter a plan name.") }
        guard draft.priceCents > 0 else { throw AppError.invalidInput("Enter the plan price.") }
        let range = draft.interval.planCountRange
        let count = min(max(draft.intervalCount, range.lowerBound), range.upperBound)
        if let uses = draft.includedUsesPerPeriod, !(1...MembershipPlan.maxUsesPerPeriod).contains(uses) {
            throw AppError.invalidInput("Included visits must be from 1 to \(MembershipPlan.maxUsesPerPeriod) per period.")
        }
        let terms = draft.terms.trimmedNonEmpty
        if let terms, terms.count > maxTermsLength {
            throw AppError.invalidInput("Keep the plan terms under 5,000 characters.")
        }
        let fields = MembershipPlanPayload(
            name: name,
            planDescription: draft.planDescription.trimmedNonEmpty,
            priceCents: draft.priceCents,
            interval: draft.interval.rawValue,
            intervalCount: count,
            discountBps: min(max(draft.discountBps, 0), 10_000),
            active: draft.active,
            onlineJoinable: draft.onlineJoinable,
            includedUsesPerPeriod: draft.includedUsesPerPeriod,
            terms: terms
        )
        if let planID = draft.planID {
            try await Supa.client
                .from("membership_plans")
                .update(fields, returning: .minimal)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: planID.uuidString)
                .execute()
            return planID
        }
        let created: MembershipPlan = try await Supa.client
            .from("membership_plans")
            .insert(MembershipPlanInsertPayload(shopID: shopID, fields: fields), returning: .representation)
            .select(MembershipPlan.selectColumns)
            .single()
            .execute()
            .value
        return created.id
    }

    // MARK: - Memberships

    struct ListData: Sendable {
        var memberships: [Membership]
        var plans: [UUID: MembershipPlan]
        var customers: [UUID: QuoteCustomerRef]
        var vehicles: [UUID: QuoteVehicleRef]
    }

    /// Memberships (newest first) with their plan, customer and vehicle.
    static func memberships(shopID: UUID, status: MembershipStatus?) async throws -> ListData {
        var query = Supa.client
            .from("memberships")
            .select(Membership.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        if let status {
            query = query.eq("status", value: status.rawValue)
        }
        let rows: [Membership] = try await query
            .order("created_at", ascending: false)
            .limit(300)
            .execute()
            .value

        // Plans include archived ones so old memberships still show a name.
        let planRows: [MembershipPlan] = try await Supa.client
            .from("membership_plans")
            .select(MembershipPlan.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .execute()
            .value
        var plans: [UUID: MembershipPlan] = [:]
        for plan in planRows { plans[plan.id] = plan }

        let customers = try await PaymentService.customerRefs(shopID: shopID, ids: rows.map { $0.customerID })
        let vehicleIDs = Array(Set(rows.compactMap { $0.vehicleID }))
        var vehicles: [UUID: QuoteVehicleRef] = [:]
        if !vehicleIDs.isEmpty {
            let vehicleRows: [QuoteVehicleRef] = try await Supa.client
                .from("vehicles")
                .select(QuoteVehicleRef.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: vehicleIDs.map { $0.uuidString })
                .execute()
                .value
            for vehicle in vehicleRows { vehicles[vehicle.id] = vehicle }
        }
        return ListData(memberships: rows, plans: plans, customers: customers, vehicles: vehicles)
    }

    /// New incomplete membership (`create_membership`); billing starts when
    /// the customer completes the Checkout link.
    static func create(planID: UUID, customerID: UUID, vehicleID: UUID?) async throws -> Membership {
        let params: [String: AnyJSON] = [
            "p_plan_id": .string(planID.uuidString),
            "p_customer_id": .string(customerID.uuidString),
            "p_vehicle_id": vehicleID.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        return try await Supa.client
            .rpc("create_membership", params: params)
            .execute()
            .value
    }

    /// Stripe Checkout (subscription) link for an incomplete membership.
    static func checkoutLink(shopID: UUID, membershipID: UUID, nonce: String) async throws -> MoneyCheckoutLink {
        struct Body: Encodable {
            let action = "membership_checkout"
            let shop_id: String
            let membership_id: String
            let request_nonce: String
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(
                shop_id: MoneyEdge.wire(shopID),
                membership_id: MoneyEdge.wire(membershipID),
                request_nonce: nonce
            )
        )
    }

    /// Included visits used in the membership's current billing period
    /// (`membership_usage`, managers+).
    static func usage(membershipID: UUID) async throws -> Membership.Usage {
        try await Supa.client
            .rpc("membership_usage", params: ["p_membership_id": membershipID.uuidString])
            .execute()
            .value
    }

    /// Cancels now, or at the end of the paid period.
    static func cancel(shopID: UUID, membershipID: UUID, atPeriodEnd: Bool) async throws -> MoneyMembershipCancelResult {
        struct Body: Encodable {
            let action = "membership_cancel"
            let shop_id: String
            let membership_id: String
            let at_period_end: Bool
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(
                shop_id: MoneyEdge.wire(shopID),
                membership_id: MoneyEdge.wire(membershipID),
                at_period_end: atPeriodEnd
            )
        )
    }
}

// MARK: - Write payloads

private struct MembershipPlanPayload: Encodable {
    let name: String
    let planDescription: String?
    let priceCents: Int
    let interval: String
    let intervalCount: Int
    let discountBps: Int
    let active: Bool
    let onlineJoinable: Bool
    let includedUsesPerPeriod: Int?
    let terms: String?

    enum PlanKeys: String, CodingKey {
        case name
        case planDescription = "description"
        case priceCents = "price_cents"
        case interval
        case intervalCount = "interval_count"
        case discountBps = "discount_bps"
        case active
        case onlineJoinable = "online_joinable"
        case includedUsesPerPeriod = "included_uses_per_period"
        case terms
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PlanKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(planDescription, forKey: .planDescription)
        try c.encode(priceCents, forKey: .priceCents)
        try c.encode(interval, forKey: .interval)
        try c.encode(intervalCount, forKey: .intervalCount)
        try c.encode(discountBps, forKey: .discountBps)
        try c.encode(active, forKey: .active)
        try c.encode(onlineJoinable, forKey: .onlineJoinable)
        // Explicit nulls: "unlimited" / no terms clear the saved values.
        try c.encode(includedUsesPerPeriod, forKey: .includedUsesPerPeriod)
        try c.encode(terms, forKey: .terms)
    }
}

private struct MembershipPlanInsertPayload: Encodable {
    let shopID: UUID
    let fields: MembershipPlanPayload

    enum InsertKeys: String, CodingKey {
        case shopID = "shop_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: InsertKeys.self)
        try c.encode(shopID, forKey: .shopID)
        try fields.encode(to: encoder)
    }
}
