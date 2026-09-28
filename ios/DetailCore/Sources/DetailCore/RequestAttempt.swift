import Foundation

/// One user attempt at a money action that the server de-duplicates by a
/// client `request_nonce` (refund, saved-card charge, send…).
///
/// The nonce is what tells a retry from a new, deliberate request: a retry
/// of the same attempt (the response was lost) must reuse it so the server
/// hands back what it already did, and a new attempt must send a fresh one so
/// the server does the action again. Without a nonce the server cannot tell
/// them apart and refuses a same-amount repeat (the `payments` refund answers
/// 409 `possible_duplicate_refund` for 10 minutes).
///
/// Rules (the same as the web's per-dialog nonce):
///  * a new attempt starts with a fresh nonce;
///  * after a success, or a definitive refusal (HTTP 4xx: not refundable,
///    amount too high, forbidden…), the next submit is a new attempt;
///  * when the server may have done it without answering (unreachable,
///    status 0, or a 5xx), the nonce is kept, so tapping again is a retry of
///    that attempt and never does the action twice.
public struct RequestAttempt: Equatable, Sendable {

    /// The nonce to send with the next submit.
    public private(set) var nonce: String

    public init(nonce: String = RequestAttempt.newNonce()) {
        self.nonce = nonce
    }

    /// A url-safe nonce: 32 lowercase hex characters (the server accepts
    /// 8-64 of `[A-Za-z0-9_-]`).
    public static func newNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Whether a failed request with this HTTP status was definitively not
    /// done, so a new submit is a new attempt. 0 (no answer) and 5xx (the
    /// server may have acted before failing) are not definitive.
    public static func isDefinitiveFailure(status: Int) -> Bool {
        (400..<500).contains(status)
    }

    /// The server did it: the next submit is a new attempt.
    public mutating func succeeded() {
        nonce = Self.newNonce()
    }

    /// The request failed with `status` (0 when the server could not be
    /// reached). Starts a new attempt only after a definitive refusal.
    public mutating func failed(status: Int) {
        if Self.isDefinitiveFailure(status: status) {
            nonce = Self.newNonce()
        }
    }
}
