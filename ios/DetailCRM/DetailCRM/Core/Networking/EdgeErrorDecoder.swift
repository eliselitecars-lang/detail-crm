//
//  EdgeErrorDecoder.swift
//  DetailCRM
//
//  One reading of edge-function failures for every service. Our functions
//  answer errors with the envelope `{ "error": "<sentence>", "code":
//  "<stable code>", "details": { "reason": "<why>", … } }`. Other layers
//  answer with their own shapes: the API gateway rejects an expired or
//  invalid JWT with `{ "code": 401, "message": "Invalid JWT" }` (an integer
//  code), GoTrue with `{ "msg": … }`, and a missing function or an
//  overloaded platform may send no JSON at all. Those never reach people as
//  raw text: the HTTP status decides the sentence.
//

import Foundation
import Supabase

/// A refused edge-function request, readable by people (`message`) and by
/// code (`status`, the envelope's `code`, `details.reason`, `details`).
struct EdgeFunctionError: LocalizedError, Equatable {
    /// HTTP status (0 when the server could not be reached).
    let status: Int
    /// The envelope's stable code (`unprocessable`, `conflict`, …).
    let code: String?
    /// `details.reason` (e.g. `template_disabled`, `owns_shops`).
    let reason: String?
    let message: String
    /// The whole `details` object of the envelope (nil otherwise).
    let details: [String: AnyJSON]?
    /// True when the body was our `{error, code, details}` envelope, so
    /// `message` is the function's own wording.
    let isEnvelope: Bool

    var errorDescription: String? { message }

    /// Off-session charge needs the customer (3-D Secure): send a pay link.
    var needsCustomerAuthentication: Bool {
        reason == "authentication_required"
    }

    /// The gateway refused the session (expired / revoked access token).
    var isSessionExpired: Bool {
        status == 401 && !isEnvelope
    }
}

enum EdgeErrorDecoder {

    static let sessionExpiredMessage = "Your session has expired. Sign in again."
    static let forbiddenMessage = "You don't have permission to do that."
    static let notFoundMessage = "That could not be found. It may have been removed."
    static let rateLimitedMessage = "Too many requests right now. Wait a moment and try again."
    static let serverMessage = "The server had a problem. Try again in a moment."
    static let unreachableMessage = "Couldn't reach the server. Try again."

    /// Reads a `FunctionsError` from `Supa.client.functions.invoke`.
    static func error(from error: FunctionsError) -> EdgeFunctionError {
        switch error {
        case .httpError(let status, let data):
            return decode(status: status, data: data)
        case .relayError:
            return EdgeFunctionError(
                status: 0,
                code: "relay_error",
                reason: nil,
                message: unreachableMessage,
                details: nil,
                isEnvelope: false
            )
        }
    }

    /// Reads a non-2xx reply body. Our envelope keeps its own wording; any
    /// other body is mapped from the status (401, 403, 404, 429, 5xx), and
    /// only for other statuses its `message` / `msg` is shown.
    static func decode(status: Int, data: Data) -> EdgeFunctionError {
        let object = (try? JSONDecoder().decode([String: AnyJSON].self, from: data)) ?? [:]
        let details = object["details"]?.asObject
        if let text = object["error"]?.asString?.trimmedNonEmpty {
            return EdgeFunctionError(
                status: status,
                code: object["code"]?.asString,
                reason: details?["reason"]?.asString,
                message: ErrorText.sentence(text),
                details: details,
                isEnvelope: true
            )
        }
        let other = object["message"]?.asString?.trimmedNonEmpty ?? object["msg"]?.asString?.trimmedNonEmpty
        return EdgeFunctionError(
            status: status,
            code: object["code"]?.asString,
            reason: nil,
            message: statusMessage(status) ?? other.map { ErrorText.sentence($0) }
                ?? "The request failed (\(status)). Try again.",
            details: nil,
            isEnvelope: false
        )
    }

    /// The sentence for a status whose body is not our envelope.
    static func statusMessage(_ status: Int) -> String? {
        switch status {
        case 401: return sessionExpiredMessage
        case 403: return forbiddenMessage
        case 404: return notFoundMessage
        case 429: return rateLimitedMessage
        case 500...599: return serverMessage
        default: return nil
        }
    }
}

/// Invokes an edge function with a JSON body and decodes its reply; every
/// non-2xx reply becomes an `EdgeFunctionError`.
enum EdgeFunctions {
    static func invoke<Body: Encodable, Reply: Decodable>(
        _ functionName: String,
        body: Body
    ) async throws -> Reply {
        do {
            let reply: Reply = try await Supa.client.functions.invoke(
                functionName,
                options: FunctionInvokeOptions(body: body)
            )
            return reply
        } catch let error as FunctionsError {
            throw EdgeErrorDecoder.error(from: error)
        }
    }
}
