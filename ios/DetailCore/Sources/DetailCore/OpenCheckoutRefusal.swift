//
//  OpenCheckoutRefusal.swift
//  DetailCore
//
//  0109: while a Stripe payment page of an invoice (or of a job it bills)
//  can still be paid, record_manual_payment, redeem_gift_card and
//  redeem_customer_credit refuse with 55000 HINT `checkout_open`, so cash
//  recorded meanwhile cannot overpay the invoice. Staff apps release the
//  pages (payments edge `cancel_open_payments` with the invoice) and try
//  once more; when that still fails the server's message (which names the
//  time the page closes) is shown.
//

import Foundation

public enum OpenCheckoutRefusal {

    public static let sqlState = "55000"
    public static let hint = "checkout_open"

    /// True for the database refusal above (PostgREST `code` / `hint`).
    public static func matches(code: String?, hint: String?) -> Bool {
        code == sqlState && hint == Self.hint
    }

    /// Runs `write`; when it is refused because a payment page is still
    /// open, runs `release` and `write` once more. A failed release
    /// rethrows the original refusal (its message says what to do); any
    /// other error, or a second refusal, propagates unchanged.
    public static func retryingAfterRelease<T>(
        isRefusal: (Error) -> Bool,
        release: () async throws -> Void,
        write: () async throws -> T
    ) async throws -> T {
        do {
            return try await write()
        } catch let refusal where isRefusal(refusal) {
            do {
                try await release()
            } catch {
                throw refusal
            }
            return try await write()
        }
    }
}
