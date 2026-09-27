//
//  Invoice.swift
//  DetailCRM
//
//  Invoices and their line items (SPEC §4.5). Every amount — totals,
//  amount paid, balance, tips — is maintained by the server
//  (`invoices_compute`); the app only displays them.
//

import Foundation
import DetailCore

// table: invoices
struct Invoice: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var number: Int
    var jobID: UUID?
    var customerID: UUID
    var status: InvoiceStatus
    var issuedAt: Date?
    var dueAt: Date?
    var sentAt: Date?
    var paidAt: Date?
    var voidedAt: Date?
    var voidReason: String?
    var notes: String?
    var terms: String?
    var internalNotes: String?
    var discountKind: MoneyDiscountKind
    var discountValue: Int
    var taxRateBps: Int
    var subtotalCents: Int
    var discountCents: Int
    var taxCents: Int
    var totalCents: Int
    var amountPaidCents: Int
    /// total − paid (tips never count; negative = customer credit).
    var balanceCents: Int
    var tipCents: Int
    var publicToken: UUID
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case number
        case jobID = "job_id"
        case customerID = "customer_id"
        case status
        case issuedAt = "issued_at"
        case dueAt = "due_at"
        case sentAt = "sent_at"
        case paidAt = "paid_at"
        case voidedAt = "voided_at"
        case voidReason = "void_reason"
        case notes
        case terms
        case internalNotes = "internal_notes"
        case discountKind = "discount_kind"
        case discountValue = "discount_value"
        case taxRateBps = "tax_rate_bps"
        case subtotalCents = "subtotal_cents"
        case discountCents = "discount_cents"
        case taxCents = "tax_cents"
        case totalCents = "total_cents"
        case amountPaidCents = "amount_paid_cents"
        case balanceCents = "balance_cents"
        case tipCents = "tip_cents"
        case publicToken = "public_token"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "number", "job_id", "customer_id", "status", "issued_at", "due_at",
        "sent_at", "paid_at", "voided_at", "void_reason", "notes", "terms", "internal_notes",
        "discount_kind", "discount_value", "tax_rate_bps", "subtotal_cents", "discount_cents",
        "tax_cents", "total_cents", "amount_paid_cents", "balance_cents", "tip_cents",
        "public_token", "created_at", "updated_at",
    ].joined(separator: ",")

    /// "Invoice #1042"
    var title: String { "Invoice #\(number)" }

    /// Open or partially paid, with a due date that has passed.
    func isOverdue(now: Date = Date()) -> Bool {
        guard status.acceptsPayment, balanceCents > 0, let dueAt else { return false }
        return dueAt < now
    }

    /// Money can still be collected (issued, not void, balance left).
    var canCollect: Bool { status.acceptsPayment && balanceCents > 0 }

    /// Display status, with "Overdue" layered over open / partially paid.
    func badge(now: Date = Date()) -> (text: String, tone: StatusTone) {
        if isOverdue(now: now) { return ("Overdue", .danger) }
        return (status.displayName, status.tone)
    }
}

// table: invoice_line_items
struct InvoiceLineItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var invoiceID: UUID
    var serviceID: UUID?
    var vehicleID: UUID?
    var name: String
    var lineDescription: String?
    /// `numeric(10,2)`.
    var quantity: Decimal
    var unitPriceCents: Int
    var discountCents: Int
    var taxable: Bool
    var sort: Int
    /// Generated column: round(quantity × unit price) − discount.
    var totalCents: Int?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case invoiceID = "invoice_id"
        case serviceID = "service_id"
        case vehicleID = "vehicle_id"
        case name
        case lineDescription = "description"
        case quantity
        case unitPriceCents = "unit_price_cents"
        case discountCents = "discount_cents"
        case taxable
        case sort
        case totalCents = "total_cents"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "invoice_id", "service_id", "vehicle_id", "name", "description",
        "quantity", "unit_price_cents", "discount_cents", "taxable", "sort", "total_cents",
        "created_at", "updated_at",
    ].joined(separator: ",")
}

/// Invoice list filters (server-side where possible).
enum InvoiceListFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case unpaid
    case overdue
    case draft
    case paid
    case void

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .unpaid: return "Unpaid"
        case .overdue: return "Overdue"
        case .draft: return "Drafts"
        case .paid: return "Paid"
        case .void: return "Void"
        }
    }
}

/// Quantity text for line items: "1", "1.5", "2.25".
enum MoneyQuantityFormat {
    static func text(_ quantity: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: quantity)) ?? "\(quantity)"
    }

    /// Parses a typed quantity (> 0, at most 2 decimals, ≤ 99,999,999.99).
    static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let separator = locale.decimalSeparator ?? "."
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: ".")
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              cleaned.filter({ $0 == "." }).count <= 1 else { return nil }
        if let dot = cleaned.firstIndex(of: ".") {
            let fraction = cleaned[cleaned.index(after: dot)...]
            guard fraction.count <= 2 else { return nil }
        }
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value < 100_000_000 else { return nil }
        return value
    }
}
