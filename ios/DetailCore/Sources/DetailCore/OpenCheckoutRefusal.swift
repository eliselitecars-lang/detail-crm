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
//  time the page closes) is shown. Those writes are checked against the
//  balance again on the retry, so a card payment that landed while the
//  pages were released can't be overpaid by it.
//
//  0118: a job edit that lowers the job's total or deposit (line edits and
//  removals, the discount, the deposit) is refused the same way while a
//  deposit page of the job can still be paid. Nothing re-checks such a cut
//  against what was paid, so it is never retried blindly: staff are asked
//  first (releasing closes the page the customer may be paying on), and
//  after the release the edit is saved again only when no payment went
//  through or is still processing (`releaseThenSaveAgain`). Otherwise the
//  edit stops and `releaseSummary` says what happened, as the web does.
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
    /// open, runs `release` and `write` once more. Only for writes the
    /// server checks against the balance again (0109 manual payments,
    /// redemptions) — never for a price or deposit cut (0118), which uses
    /// `releaseThenSaveAgain` after asking. A failed release
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

    /// After staff chose to cancel a job's open payments on a refused price
    /// or deposit cut (0118): runs `release`, then saves the edit again only
    /// when nothing landed. A payment that went through while the pages
    /// were closed (`succeeded`), or one the bank is still processing
    /// (`inProgress`), stops the edit: the job's money changed under it, so
    /// staff look again before cutting the price. A failed release, or a
    /// second refusal, is thrown.
    public static func releaseThenSaveAgain<T>(
        release: () async throws -> OpenPaymentsRelease,
        write: () async throws -> T
    ) async throws -> OpenCheckoutEditOutcome<T> {
        let released = try await release()
        if released.paymentLanded {
            return .notSaved(released)
        }
        return .saved(try await write())
    }

    /// What the release did, when the edit was not saved (mirrors the web's
    /// `cancelOpenPaymentsSummary`, plus why the change was held back).
    public static func releaseSummary(_ release: OpenPaymentsRelease) -> (title: String, message: String) {
        var notes: [String] = []
        if release.succeeded > 0 {
            notes.append(release.succeeded == 1
                ? "1 payment had already gone through and was recorded."
                : "\(release.succeeded) payments had already gone through and were recorded.")
        }
        if release.inProgress > 0 {
            notes.append(release.inProgress == 1
                ? "1 payment is still being processed by the bank and can't be cancelled; the job updates when it finishes."
                : "\(release.inProgress) payments are still being processed by the bank and can't be cancelled; the job updates when they finish.")
        }
        if release.sessionsExpired > 0 {
            notes.append(release.sessionsExpired == 1
                ? "1 open pay link was expired."
                : "\(release.sessionsExpired) open pay links were expired.")
        }
        notes.append("Your change was not saved. Check the job's payments, then make the change again if it's still right.")
        let title: String
        if release.succeeded > 0 {
            title = release.succeeded == 1 ? "A payment came in" : "Payments came in"
        } else {
            title = "A payment is still processing"
        }
        return (title, notes.joined(separator: " "))
    }
}

/// What the payments edge `cancel_open_payments` reported.
public struct OpenPaymentsRelease: Equatable, Sendable {
    public var cancelled: Int
    /// Attempts that turned out to have taken the money (now recorded).
    public var succeeded: Int
    /// Card payments the bank is still processing (never cancelled).
    public var inProgress: Int
    public var sessionsExpired: Int

    public init(cancelled: Int = 0, succeeded: Int = 0, inProgress: Int = 0, sessionsExpired: Int = 0) {
        self.cancelled = cancelled
        self.succeeded = succeeded
        self.inProgress = inProgress
        self.sessionsExpired = sessionsExpired
    }

    /// Money reached the job during the release, or still may.
    public var paymentLanded: Bool { succeeded > 0 || inProgress > 0 }
}

/// How a refused price / deposit cut ended after its payments were released.
public enum OpenCheckoutEditOutcome<T> {
    /// Nothing was paid meanwhile; the edit is saved.
    case saved(T)
    /// A payment went through or is processing; the edit was not saved.
    case notSaved(OpenPaymentsRelease)
}
