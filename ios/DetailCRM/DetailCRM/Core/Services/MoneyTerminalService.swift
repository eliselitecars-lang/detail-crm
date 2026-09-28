//
//  MoneyTerminalService.swift
//  DetailCRM
//
//  In-person card payments with Stripe Terminal (P-6): Tap to Pay on
//  iPhone and Bluetooth card readers. The `payments` edge function does
//  everything that needs the shop's Stripe account (connected account,
//  direct charges):
//    * `terminal_location` — the shop's Terminal Location (made from the
//      shop address on first use; 422 `shop_address_required` without one),
//    * `terminal_connection_token` — a single-use token for the SDK,
//    * `terminal_payment_intent` — a `card_present` PaymentIntent for an
//      invoice (same amount rules as the card sheet: 0 < amount ≤ balance
//      less payments in flight, the tip on top), recorded as a pending
//      payment; the webhook settles it.
//  Same callers as PaymentSheet: managers+, or a technician assigned to the
//  invoice's job when the shop lets technicians collect.
//
//  The app only shows these screens when Config.plist turns them on
//  (`AppConfig.tapToPayEnabled` / `.terminalBluetoothEnabled`).
//

import Foundation
import DetailCore

enum MoneyTerminalService {

    /// `terminal_location`.
    struct LocationReply: Decodable, Hashable, Sendable {
        var locationID: String

        private enum Keys: String, CodingKey {
            case locationID = "location_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            locationID = try c.decode(String.self, forKey: .locationID)
        }
    }

    /// `terminal_connection_token`: the SDK secret for the shop's account.
    struct ConnectionToken: Decodable, Hashable, Sendable {
        var secret: String
        var locationID: String
        var stripeAccountID: String

        private enum Keys: String, CodingKey {
            case secret
            case locationID = "location_id"
            case stripeAccountID = "stripe_account_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            secret = try c.decode(String.self, forKey: .secret)
            locationID = try c.decode(String.self, forKey: .locationID)
            stripeAccountID = try c.decode(String.self, forKey: .stripeAccountID)
        }
    }

    /// `terminal_payment_intent`: the in-person PaymentIntent, as the server
    /// created it (amounts are the server's).
    struct PaymentIntentReply: Decodable, Hashable, Sendable {
        var paymentIntentID: String
        var clientSecret: String
        var amountCents: Int
        var tipCents: Int
        var currency: String
        var stripeAccountID: String

        private enum Keys: String, CodingKey {
            case paymentIntentID = "payment_intent_id"
            case clientSecret = "client_secret"
            case amountCents = "amount_cents"
            case tipCents = "tip_cents"
            case currency
            case stripeAccountID = "stripe_account_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            paymentIntentID = try c.decode(String.self, forKey: .paymentIntentID)
            clientSecret = try c.decode(String.self, forKey: .clientSecret)
            amountCents = try c.decode(Int.self, forKey: .amountCents)
            tipCents = try c.decodeIfPresent(Int.self, forKey: .tipCents) ?? 0
            currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
            stripeAccountID = try c.decode(String.self, forKey: .stripeAccountID)
        }

        /// What the card is charged (amount + tip).
        var chargeCents: Int { amountCents + tipCents }
    }

    /// The shop's Terminal Location id (created by the server when needed).
    static func location(shopID: UUID) async throws -> String {
        struct Body: Encodable {
            let action = "terminal_location"
            let shop_id: String
        }
        let reply: LocationReply = try await MoneyEdge.invoke(
            "payments",
            body: Body(shop_id: MoneyEdge.wire(shopID))
        )
        return reply.locationID
    }

    /// A fresh connection token for the Terminal SDK (single use).
    static func connectionToken(shopID: UUID) async throws -> ConnectionToken {
        struct Body: Encodable {
            let action = "terminal_connection_token"
            let shop_id: String
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(shop_id: MoneyEdge.wire(shopID))
        )
    }

    /// A `card_present` PaymentIntent for the invoice balance (or a partial
    /// `amountCents`) plus a tip. A newer attempt replaces older unfinished
    /// ones for the invoice; `nonce` makes a retry of the same tap reuse the
    /// same intent.
    static func paymentIntent(
        shopID: UUID,
        invoiceID: UUID,
        amountCents: Int?,
        tipCents: Int,
        nonce: String
    ) async throws -> PaymentIntentReply {
        struct Body: Encodable {
            let action = "terminal_payment_intent"
            let shop_id: String
            let invoice_id: String
            let amount_cents: Int?
            let tip_cents: Int?
            let request_nonce: String
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(
                shop_id: MoneyEdge.wire(shopID),
                invoice_id: MoneyEdge.wire(invoiceID),
                amount_cents: amountCents,
                tip_cents: tipCents > 0 ? tipCents : nil,
                request_nonce: nonce
            )
        )
    }
}
