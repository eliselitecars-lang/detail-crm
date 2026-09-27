//
//  CustomerService.swift
//  DetailCRM
//
//  Customers (SPEC §4.2) and the read-only history shown on a customer:
//  jobs, quotes, invoices, memberships and the saved-card count. RLS
//  decides what each role sees (technicians only get customers on jobs
//  assigned to them, and no money rows); every query is also scoped to the
//  active shop.
//

import Foundation
import Supabase

enum CustomerService {

    /// Page size for the customer list.
    static let pageSize = 50

    enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case name
        case newest

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .name: return "Name"
            case .newest: return "Newest"
            }
        }
    }

    /// Filters for the customer list.
    struct ListQuery: Hashable, Sendable {
        var search: String = ""
        var lifecycle: Customer.Lifecycle?
        var tag: String?
        var sort: SortOrder = .name
        var includeArchived: Bool = false
    }

    // MARK: - Search helpers

    /// Escapes LIKE wildcards (`%`, `_`) and the escape character so user
    /// input matches literally (same rule as SQL `public.like_escape`), and
    /// drops `*`, which PostgREST treats as a wildcard too.
    static func likeEscaped(_ term: String) -> String {
        var result = ""
        for character in term where character != "*" {
            switch character {
            case "\\": result += "\\\\"
            case "%": result += "\\%"
            case "_": result += "\\_"
            default: result.append(character)
            }
        }
        return result
    }

    /// ILIKE patterns for a search: one `%word%` per word (all must match
    /// the customer's lower-cased search text). Input that is only a phone
    /// number (digits and phone punctuation) becomes one digits-only
    /// pattern, because phones are stored as E.164.
    static func searchPatterns(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let phoneCharacters: Set<Character> = [" ", "(", ")", "-", ".", "+", "/"]
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if digits.count >= 3, trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || phoneCharacters.contains($0) }) {
            return ["%" + digits + "%"]
        }
        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .prefix(6)
        return words
            .map { likeEscaped($0) }
            .filter { !$0.isEmpty }
            .map { "%" + $0 + "%" }
    }

    // MARK: - List / fetch

    /// One page of customers matching `query`, starting at `offset`.
    static func list(shopID: UUID, query: ListQuery, offset: Int = 0, limit: Int = pageSize) async throws -> [Customer] {
        var request = Supa.client
            .from("customers")
            .select(Customer.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        if !query.includeArchived {
            request = request.is("archived_at", value: nil)
        }
        if let lifecycle = query.lifecycle {
            request = request.eq("lifecycle", value: lifecycle.rawValue)
        }
        if let tag = query.tag?.trimmedNonEmpty {
            request = request.contains("tags", value: [tag])
        }
        for pattern in searchPatterns(for: query.search) {
            request = request.ilike("search_text", pattern: pattern)
        }
        let ordered: PostgrestTransformBuilder
        switch query.sort {
        case .name:
            // sort_name: last name, else company, else first name (lower
            // case, then the first name) — generated and indexed server-side.
            ordered = request
                .order("sort_name", ascending: true)
                .order("id", ascending: true)
        case .newest:
            ordered = request
                .order("created_at", ascending: false)
                .order("id", ascending: true)
        }
        let rows: [Customer] = try await ordered
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
        return rows
    }

    /// One customer, or `AppError.notFound` when missing / not visible.
    static func fetch(shopID: UUID, customerID: UUID) async throws -> Customer {
        let rows: [Customer] = try await Supa.client
            .from("customers")
            .select(Customer.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: customerID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let customer = rows.first else { throw AppError.notFound("That customer") }
        return customer
    }

    /// Customers by id (unknown / invisible ids are simply missing).
    static func fetch(shopID: UUID, ids: [UUID]) async throws -> [Customer] {
        guard !ids.isEmpty else { return [] }
        var result: [Customer] = []
        // Chunk so the query string stays short.
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let rows: [Customer] = try await Supa.client
                .from("customers")
                .select(Customer.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: chunk.map { $0.uuidString })
                .execute()
                .value
            result.append(contentsOf: rows)
            start += 100
        }
        return result
    }

    /// Distinct tags in use across the shop's active customers, sorted.
    static func allTags(shopID: UUID) async throws -> [String] {
        let rows: [CustomerTagsRow] = try await Supa.client
            .from("customers")
            .select("tags")
            .eq("shop_id", value: shopID.uuidString)
            .is("archived_at", value: nil)
            .neq("tags", value: "{}")
            .limit(2000)
            .execute()
            .value
        var seen = Set<String>()
        var tags: [String] = []
        for row in rows {
            for tag in row.tags where seen.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Writes (manager+; RLS enforces)

    static func create(shopID: UUID, draft: CustomerDraft) async throws -> Customer {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = shopID
        payload.recordSmsOptOut = false
        payload.recordEmailOptOut = false
        let created: Customer = try await Supa.client
            .from("customers")
            .insert(payload, returning: .representation)
            .select(Customer.selectColumns)
            .single()
            .execute()
            .value
        return created
    }

    static func update(shopID: UUID, customerID: UUID, draft: CustomerDraft) async throws -> Customer {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = nil
        let rows: [Customer] = try await Supa.client
            .from("customers")
            .update(payload, returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: customerID.uuidString)
            .select(Customer.selectColumns)
            .execute()
            .value
        guard let updated = rows.first else {
            throw AppError.message("You don't have permission to edit this customer.")
        }
        return updated
    }

    /// Archives (hides from lists) or restores a customer.
    static func setArchived(shopID: UUID, customerID: UUID, archived: Bool) async throws -> Customer {
        let payload = CustomerArchivePatch(archivedAt: archived ? Supa.iso(Date()) : nil)
        let rows: [Customer] = try await Supa.client
            .from("customers")
            .update(payload, returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: customerID.uuidString)
            .select(Customer.selectColumns)
            .execute()
            .value
        guard let updated = rows.first else {
            throw AppError.message("You don't have permission to change this customer.")
        }
        return updated
    }

    // MARK: - History

    /// The customer's jobs, most recent first (technicians: only assigned).
    static func jobs(shopID: UUID, customerID: UUID, limit: Int = 50) async throws -> [CustomerJobSummary] {
        try await Supa.client
            .from("jobs")
            .select(CustomerJobSummary.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .order("scheduled_start", ascending: false, nullsFirst: true)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    static func quotes(shopID: UUID, customerID: UUID, limit: Int = 50) async throws -> [CustomerQuoteSummary] {
        try await Supa.client
            .from("quotes")
            .select(CustomerQuoteSummary.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    static func invoices(shopID: UUID, customerID: UUID, limit: Int = 50) async throws -> [CustomerInvoiceSummary] {
        try await Supa.client
            .from("invoices")
            .select(CustomerInvoiceSummary.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Memberships (with their own billed price/cadence) plus the plan name.
    static func memberships(shopID: UUID, customerID: UUID) async throws -> [CustomerMembershipItem] {
        let memberships: [CustomerMembershipSummary] = try await Supa.client
            .from("memberships")
            .select(CustomerMembershipSummary.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
        guard !memberships.isEmpty else { return [] }
        var planIDs: [String] = []
        for membership in memberships where !planIDs.contains(membership.planID.uuidString) {
            planIDs.append(membership.planID.uuidString)
        }
        let plans: [CustomerMembershipPlanRef] = try await Supa.client
            .from("membership_plans")
            .select(CustomerMembershipPlanRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: planIDs)
            .execute()
            .value
        let plansByID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return memberships.map { CustomerMembershipItem(membership: $0, plan: plansByID[$0.planID]) }
    }

    /// Saved cards (manager+ can read; card details stay in Stripe — only
    /// brand, last 4 and expiry are stored).
    static func savedCards(shopID: UUID, customerID: UUID) async throws -> [SavedCard] {
        try await InvoiceService.savedCards(shopID: shopID, customerID: customerID)
    }

    /// The customer's overview (`customer_summary`, manager+): lifetime
    /// paid, open / overdue balance, visits, upcoming jobs.
    static func summary(customerID: UUID) async throws -> CustomerSummary {
        let rows: [CustomerSummary] = try await Supa.client
            .rpc("customer_summary", params: CustomerSummaryParams(p_customer_id: customerID))
            .execute()
            .value
        guard let summary = rows.first else { throw AppError.notFound("That customer") }
        return summary
    }
}

// MARK: - Private row types (file scope: never nest types in generic functions)

private struct CustomerSummaryParams: Encodable {
    let p_customer_id: UUID
}

// table: customers
private struct CustomerTagsRow: Decodable {
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case tags
    }
}

// table: customers
private struct CustomerArchivePatch: Encodable {
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case archivedAt = "archived_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(archivedAt, forKey: .archivedAt)
    }
}
