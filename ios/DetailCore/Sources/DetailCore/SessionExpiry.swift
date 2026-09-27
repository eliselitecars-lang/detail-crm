import Foundation

/// When the signed-in session is over, and how the app reacts: it signs out
/// once, cleanly, and the sign-in screen says why.
///
/// Two signals:
///  * an edge-function reply the API gateway made instead of the function:
///    HTTP 401 whose body is not our `{error, code, details}` envelope
///    (`{"code":401,"message":"Invalid JWT"}`). A 401 that carries the
///    envelope is the function's own answer and never signs anyone out;
///  * Supabase Auth refusing to refresh the session.
///
/// The gateway's 401 alone is not proof: a device clock that runs slow keeps
/// sending a token the server already considers expired, and a refresh fixes
/// that. So the app refreshes first, and only a refused refresh ends the
/// session. A refresh that could not reach the server says nothing either way.
public enum SessionExpiry {

    /// Shown on the sign-in screen after an expired session signed the user out.
    public static let notice = "Your session has expired. Sign in again to continue."

    /// Supabase Auth `error_code`s of a refresh that mean the session cannot
    /// continue (revoked or reused refresh token, ended session, deleted or
    /// banned user).
    public static let sessionEndingAuthCodes: Set<String> = [
        "session_not_found",
        "session_expired",
        "refresh_token_not_found",
        "refresh_token_already_used",
        "user_not_found",
        "user_banned",
    ]

    /// What a token refresh told us about the session.
    public enum RefreshOutcome: Equatable, Sendable {
        /// Auth issued a new access token: the session is alive.
        case refreshed
        /// No session is stored any more (the Auth client removes it when the
        /// server says it is gone).
        case sessionMissing
        /// Auth answered the refresh with an error: HTTP status and its
        /// `error_code` when it sent one.
        case refused(status: Int, code: String?)
        /// No answer (offline, timed out, cancelled) or not an Auth answer.
        case inconclusive
    }

    /// An edge-function reply that the gateway made because it refused the
    /// access token (not a 401 the function itself answered with).
    public static func isGatewayRejection(status: Int, isEnvelope: Bool) -> Bool {
        status == 401 && !isEnvelope
    }

    /// Whether a refresh with this outcome means the user must sign in again.
    /// Use it only for errors of a refresh (reading the session refreshes an
    /// expired one), never for sign-in or other Auth calls.
    public static func sessionIsGone(after outcome: RefreshOutcome) -> Bool {
        switch outcome {
        case .refreshed, .inconclusive:
            return false
        case .sessionMissing:
            return true
        case .refused(let status, let code):
            if let code, sessionEndingAuthCodes.contains(code) {
                return true
            }
            // Older Auth servers answer a dead refresh token with 400
            // `invalid_grant` and no error code. Rate limits (429) and server
            // trouble (5xx) are not about the session.
            let unspecific = code == nil || code == "unknown" || code == "invalid_grant"
            return unspecific && (status == 400 || status == 401)
        }
    }
}

/// Makes one lost session produce exactly one sign-out and one notice, however
/// many requests notice it at the same time, and ignores reports that arrive
/// after the sign-out (from screens still finishing their requests) or that
/// belong to a check started before it.
public struct SessionExpiryGate: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case idle
        /// A refresh is checking a gateway 401.
        case verifying
        /// A sign-out (the user's own, or an expired session's) is running.
        case signingOut
    }

    public private(set) var state: State = .idle
    /// Bumped by every check and sign-out, so a check that finishes after a
    /// newer one started, or after a sign-out, cannot act.
    public private(set) var generation = 0

    public init() {}

    public var isSigningOut: Bool { state == .signingOut }

    /// A request was refused by the gateway. Returns a ticket when the caller
    /// should check the session (one refresh); nil when nobody is signed in or
    /// a check or sign-out is already running.
    public mutating func beginVerification(signedIn: Bool) -> Int? {
        guard signedIn, state == .idle else { return nil }
        generation += 1
        state = .verifying
        return generation
    }

    /// The check with `ticket` finished. True: the session is gone, sign out
    /// now (the gate is `.signingOut`; call `finishSignOut()` afterwards).
    public mutating func finishVerification(
        ticket: Int,
        outcome: SessionExpiry.RefreshOutcome,
        signedIn: Bool
    ) -> Bool {
        guard state == .verifying, ticket == generation else { return false }
        guard signedIn, SessionExpiry.sessionIsGone(after: outcome) else {
            state = .idle
            return false
        }
        state = .signingOut
        return true
    }

    /// Any sign-out: the user's own, or a definitive signal that the session
    /// is over. True: go ahead (call `finishSignOut()` afterwards); false while
    /// another sign-out is running. A check still in flight is abandoned.
    public mutating func beginSignOut() -> Bool {
        guard state != .signingOut else { return false }
        generation += 1
        state = .signingOut
        return true
    }

    /// The sign-out finished (the user is signed out).
    public mutating func finishSignOut() {
        guard state == .signingOut else { return }
        state = .idle
    }
}
