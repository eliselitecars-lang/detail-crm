//
//  Supa.swift
//  DetailCRM
//
//  The single shared Supabase client plus small networking helpers.
//
//  Decoding: every model declares explicit CodingKeys (snake_case <->
//  camelCase), so the client's default JSON coders are used as-is. The
//  PostgREST decoder already handles ISO-8601 timestamps with and without
//  fractional seconds, so `Date` properties map straight to `timestamptz`.
//
//  Tenancy: every query against a tenant table filters by the current
//  shop_id (`.eq("shop_id", value: shopID.uuidString)`); RLS enforces the
//  same boundary server-side.
//

import Foundation
import Supabase
import DetailCore

enum Supa {

    /// The one Supabase client used by every service. With placeholder
    /// configuration the client points at a reserved, unroutable host so
    /// the app can launch into SetupRequiredView without crashing; nothing
    /// issues requests in that state.
    ///
    /// `emitLocalSessionAsInitialSession`: the stored session is emitted as
    /// `.initialSession` right away, even when its access token has expired
    /// (the legacy default first tries a refresh and emits nil when that
    /// fails offline, which would look like a sign-out). AppState then
    /// refreshes it during bootstrap: offline shows Retry, a revoked
    /// session emits `.signedOut`.
    static let client: SupabaseClient = {
        let url = AppConfig.supabaseURL ?? URL(string: "https://placeholder.invalid")!
        let key = AppConfig.isConfigured ? AppConfig.supabaseAnonKey : "placeholder-anon-key"
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
            )
        )
    }()

    /// The signed-in auth user id. Throws when signed out. Reading the session
    /// refreshes an expired access token; when Auth refuses that refresh the
    /// session is over app-wide, so AppState is told (it signs out once).
    static func currentUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            if SessionExpiry.sessionIsGone(after: SessionMonitor.refreshOutcome(of: error)) {
                await SessionMonitor.report(.refreshRefused)
            }
            throw error
        }
    }

    // MARK: - Filter value helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ISO-8601 (UTC, fractional seconds) for timestamptz filters and params.
    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Escapes a user search term for use inside a PostgREST `ilike`
    /// pattern within `.or(...)`: strips characters that are syntax in the
    /// filter grammar and wraps the term in `*` wildcards.
    static func ilikePattern(_ term: String) -> String {
        let forbidden: Set<Character> = [",", "(", ")", "*", "%", "\\", "\"", ":"]
        let cleaned = String(term.filter { !forbidden.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "*\(cleaned)*"
    }
}

// MARK: - App-level errors

/// Error type thrown by services for client-side problems. Server errors
/// pass through and are turned into readable text by `ErrorText`.
enum AppError: LocalizedError, Equatable {
    case notSignedIn
    case noShopSelected
    case notFound(String)
    case invalidInput(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You need to be signed in to do that."
        case .noShopSelected:
            return "Choose a shop first."
        case .notFound(let what):
            return "\(what) could not be found."
        case .invalidInput(let detail), .message(let detail):
            return detail
        }
    }
}

/// Turns any error into a short sentence for people (never raw JSON or
/// stack details). Database errors raised by our RPCs/triggers already
/// carry human wording, so they are passed through with light cleanup.
enum ErrorText {

    static func message(for error: Error) -> String {
        if let appError = error as? AppError {
            return appError.errorDescription ?? "Something went wrong."
        }
        if let edgeError = error as? EdgeFunctionError {
            return edgeError.message
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "The server took too long to respond. Try again."
            case .cancelled:
                return "The request was cancelled."
            default:
                return "Couldn't reach the server. Try again."
            }
        }
        if let postgrest = error as? PostgrestError {
            return message(forDatabaseCode: postgrest.code, text: postgrest.message)
        }
        if error is DecodingError {
            return "The app received data it didn't expect. Update the app or try again."
        }
        let text = error.localizedDescription
        return text.isEmpty ? "Something went wrong." : sentence(text)
    }

    static func message(forDatabaseCode code: String?, text: String) -> String {
        switch code {
        case "42501":
            // Row-level security denials have generic text; RPC guards have
            // specific wording worth showing.
            if text.lowercased().contains("row-level security") || text.lowercased().contains("permission denied") {
                return "You don't have permission to do that."
            }
            return sentence(text)
        case "PGRST116":
            return "That record could not be found."
        case "23505":
            return text.lowercased().hasPrefix("duplicate key") ? "That already exists." : sentence(text)
        case "23503":
            return "That record is still in use or no longer exists."
        default:
            return sentence(text)
        }
    }

    /// Capitalizes the first letter and ensures terminal punctuation.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Something went wrong." }
        var result = first.uppercased() + trimmed.dropFirst()
        if let last = result.last, !".!?".contains(last) {
            result += "."
        }
        return result
    }
}

// MARK: - AnyJSON reading helpers

/// Readers for `jsonb` values using only AnyJSON's stable enum cases.
extension AnyJSON {
    var asString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var asBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var asInt: Int? {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var asDouble: Double? {
        switch self {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var asArray: [AnyJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var asObject: [String: AnyJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
