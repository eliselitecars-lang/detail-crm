//
//  SessionMonitor.swift
//  DetailCRM
//
//  The app-wide signal that the signed-in session may be over. Services are
//  static enums with no access to AppState, so they report here and the one
//  listener (AppState) decides: a gateway 401 is checked with a token refresh
//  first, a refused refresh signs the user out through AppState's normal
//  sign-out path, with a short explanation on the sign-in screen. The rules
//  (and the gate that makes one lost session sign out exactly once) live in
//  DetailCore (`SessionExpiry`, `SessionExpiryGate`).
//

import Foundation
import Supabase
import DetailCore

@MainActor
enum SessionMonitor {

    enum Signal: Equatable {
        /// The API gateway refused an edge-function call's access token
        /// (HTTP 401 without our `{error, code, details}` envelope).
        case gatewayRejected
        /// Supabase Auth refused to refresh the session.
        case refreshRefused
    }

    private static var listener: (@MainActor (Signal) -> Void)?

    /// AppState registers itself once at launch.
    static func setListener(_ listener: @escaping @MainActor (Signal) -> Void) {
        self.listener = listener
    }

    /// Reports a signal. Returns at once: the listener checks the session on
    /// its own task, so the failing request finishes with its own error.
    static func report(_ signal: Signal) {
        listener?(signal)
    }

    /// What an error of a session read / refresh (`Supa.client.auth.session`,
    /// `refreshSession()`) says about the session. Only for those calls: a
    /// failed sign-in also throws `AuthError.api`, and means nothing here.
    nonisolated static func refreshOutcome(of error: Error) -> SessionExpiry.RefreshOutcome {
        guard let authError = error as? AuthError else { return .inconclusive }
        switch authError {
        case .sessionMissing:
            return .sessionMissing
        case .api(_, let errorCode, _, let response):
            return .refused(status: response.statusCode, code: errorCode.rawValue)
        default:
            return .inconclusive
        }
    }
}
