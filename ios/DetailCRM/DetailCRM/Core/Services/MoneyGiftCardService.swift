//
//  MoneyGiftCardService.swift
//  DetailCRM
//
//  Paying an invoice with a gift card or store credit (P-13). The server
//  locks the invoice and the card, bounds the amount by the card balance
//  and the invoice balance (less payments in flight), and writes the
//  `gift_card` payment and the card transaction together. Wrong codes are
//  counted: after 10 misses in an hour the lookups answer "too many
//  attempts" (PT429) for a while.
//
//  Who: gift card codes — anyone who may collect for the invoice (managers,
//  or a technician on an assigned job when the shop allows collecting);
//  listing a customer's store credit — owners, admins and managers (RLS).
//

import Foundation
import Supabase

enum MoneyGiftCardService {

    /// The card with this code, or nil when no card has it (a miss counts
    /// toward the rate limit).
    static func lookup(shopID: UUID, code: String) async throws -> MoneyGiftCard? {
        let normalized = MoneyGiftCard.normalizedCode(code)
        guard MoneyGiftCard.isPlausibleCode(normalized) else {
            throw AppError.invalidInput("Enter the full gift card code.")
        }
        let params: [String: AnyJSON] = [
            "p_shop_id": .string(shopID.uuidString),
            "p_code": .string(normalized),
        ]
        return try await Supa.client
            .rpc("lookup_gift_card", params: params)
            .execute()
            .value
    }

    /// Pays the invoice from the card with this code: `amountCents`, or as
    /// much as the card and the balance allow when nil. Returns the amount
    /// applied. Throws when no card has the code.
    @discardableResult
    static func redeem(invoiceID: UUID, code: String, amountCents: Int?) async throws -> Int {
        let normalized = MoneyGiftCard.normalizedCode(code)
        guard MoneyGiftCard.isPlausibleCode(normalized) else {
            throw AppError.invalidInput("Enter the full gift card code.")
        }
        var params: [String: AnyJSON] = [
            "p_invoice_id": .string(invoiceID.uuidString),
            "p_code": .string(normalized),
        ]
        if let amountCents {
            params["p_amount_cents"] = .integer(amountCents)
        }
        let result: MoneyGiftCard.Redemption? = try await Supa.client
            .rpc("redeem_gift_card", params: params)
            .execute()
            .value
        return try applied(result, notFound: "No gift card has that code. Check it and try again.")
    }

    /// Active store credit owned by the customer, largest balance first
    /// (managers+; technicians get an empty list from RLS).
    static func credits(shopID: UUID, customerID: UUID, now: Date = Date()) async throws -> [MoneyGiftCard.Credit] {
        let rows: [MoneyGiftCard.Credit] = try await Supa.client
            .from("gift_cards")
            .select(MoneyGiftCard.creditSelectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("owner_customer_id", value: customerID.uuidString)
            .eq("kind", value: "credit")
            .eq("status", value: "active")
            .gt("balance_cents", value: 0)
            .order("balance_cents", ascending: false)
            .limit(20)
            .execute()
            .value
        return rows.filter { $0.isUsable(now: now) }
    }

    /// Applies the customer's store credit to the invoice (no code needed):
    /// `amountCents`, or as much as the credit and the balance allow.
    /// Returns the amount applied.
    @discardableResult
    static func redeemCredit(invoiceID: UUID, giftCardID: UUID, amountCents: Int?) async throws -> Int {
        var params: [String: AnyJSON] = [
            "p_invoice_id": .string(invoiceID.uuidString),
            "p_gift_card_id": .string(giftCardID.uuidString),
        ]
        if let amountCents {
            params["p_amount_cents"] = .integer(amountCents)
        }
        let result: MoneyGiftCard.Redemption? = try await Supa.client
            .rpc("redeem_customer_credit", params: params)
            .execute()
            .value
        return try applied(result, notFound: "That store credit is no longer available.")
    }

    /// The amount a redemption applied; a null (or all-null) row means the
    /// card was not found.
    private static func applied(_ result: MoneyGiftCard.Redemption?, notFound: String) throws -> Int {
        guard let result, result.id != nil, let amount = result.amountCents else {
            throw AppError.message(notFound)
        }
        return amount
    }
}
