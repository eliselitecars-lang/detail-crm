//
//  MoneyQuoteOption.swift
//  DetailCRM
//
//  Proposal options on a quote (P-15, `public.quote_options`): up to four
//  alternatives ("good / better / best") the customer chooses between when
//  approving. A line with `option_id` belongs to one option; a line without
//  is shared by every option. Each option's totals (shared lines + its own,
//  the quote's discount and tax) are maintained by the server; the quote
//  itself counts the customer's choice, else the first option.
//

import Foundation

// table: quote_options
struct MoneyQuoteOption: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var quoteID: UUID
    var name: String
    var optionDescription: String?
    var sort: Int
    var subtotalCents: Int
    var discountCents: Int
    var taxCents: Int
    var totalCents: Int
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case quoteID = "quote_id"
        case name
        case optionDescription = "description"
        case sort
        case subtotalCents = "subtotal_cents"
        case discountCents = "discount_cents"
        case taxCents = "tax_cents"
        case totalCents = "total_cents"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "quote_id", "name", "description", "sort", "subtotal_cents",
        "discount_cents", "tax_cents", "total_cents", "created_at", "updated_at",
    ].joined(separator: ",")

    /// A quote has at most this many options (server trigger).
    static let maxPerQuote = 4

    /// Longest option name the server accepts.
    static let maxNameLength = 80

    /// Options in the server's order (sort, then creation, then id).
    static func ordered(_ options: [MoneyQuoteOption]) -> [MoneyQuoteOption] {
        options.sorted { lhs, rhs in
            if lhs.sort != rhs.sort { return lhs.sort < rhs.sort }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// One option while the quote is being edited. `id` is the saved row's
    /// id (nil for new options); `localID` keeps lines attached to it before
    /// it exists on the server.
    /// Use `ForEach(options, id: \.localID)`.
    struct Draft: Hashable, Sendable {
        var localID = UUID()
        var id: UUID?
        var name: String
        var optionDescription: String = ""

        init(name: String) {
            self.name = name
        }

        init(option: MoneyQuoteOption) {
            self.id = option.id
            self.name = option.name
            self.optionDescription = option.optionDescription ?? ""
        }

        /// Trimmed name, or nil when it is empty or too long for the server.
        var validName: String? {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= MoneyQuoteOption.maxNameLength else { return nil }
            return trimmed
        }

        /// A neutral name for the next new option: "Option 1", "Option 2", …
        /// (the first number not already used).
        static func nextName(existing: [Draft]) -> String {
            let used = Set(existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            var number = existing.count + 1
            while used.contains("option \(number)") { number += 1 }
            return "Option \(number)"
        }
    }
}
