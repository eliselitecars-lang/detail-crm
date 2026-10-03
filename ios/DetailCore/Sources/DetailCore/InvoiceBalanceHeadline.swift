//
//  InvoiceBalanceHeadline.swift
//  DetailCore
//
//  The heading and big amount on an invoice's balance card. While money is
//  owed the amount is the balance; once the invoice is paid it is the
//  amount received (a "Paid in full" heading over the $0.00 balance read as
//  "$0.00 paid"); a void invoice shows no amount: nothing is owed on it.
//

import Foundation

public struct InvoiceBalanceHeadline: Equatable, Sendable {

    public enum Amount: Equatable, Sendable {
        /// Still to collect: the balance (never below zero).
        case due(cents: Int)
        /// Paid in full: everything received toward the total (tips are
        /// separate and never part of it).
        case paid(cents: Int)
        /// No amount (a void invoice).
        case noAmount
    }

    public let title: String
    public let amount: Amount

    public init(title: String, amount: Amount) {
        self.title = title
        self.amount = amount
    }

    /// `balanceCents` is total − paid (negative = customer credit) and
    /// `amountPaidCents` what has been received, both as the server stores
    /// them on the invoice.
    public static func make(status: InvoiceStatus, balanceCents: Int, amountPaidCents: Int) -> InvoiceBalanceHeadline {
        switch status {
        case .paid:
            return InvoiceBalanceHeadline(title: "Paid in full", amount: .paid(cents: max(amountPaidCents, 0)))
        case .void:
            return InvoiceBalanceHeadline(title: "Void", amount: .noAmount)
        case .draft:
            return InvoiceBalanceHeadline(title: "Balance (not issued yet)", amount: .due(cents: max(balanceCents, 0)))
        case .open, .partiallyPaid:
            return InvoiceBalanceHeadline(title: "Balance due", amount: .due(cents: max(balanceCents, 0)))
        }
    }

    /// Under a void invoice's heading.
    public static let voidNote = "Nothing is owed on this invoice."
}
