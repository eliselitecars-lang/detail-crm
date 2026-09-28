//
//  MoneyGiftCard.swift
//  DetailCRM
//
//  Gift cards and store credit as tender (P-13): redeeming one pays an
//  invoice with a `gift_card` payment. The code is never stored — only its
//  hash — so a card is found by typing its code (`lookup_gift_card`,
//  rate-limited). Store credit (kind `credit`, e.g. referral rewards) is
//  owned by a customer and applied to that customer's invoices without a
//  code.
//

import Foundation

/// A card found by its code (`lookup_gift_card`).
// rpc: lookup_gift_card
struct MoneyGiftCard: Codable, Hashable, Sendable {
    var giftCardID: UUID
    /// gift | credit
    var kind: String
    var last4: String
    var balanceCents: Int
    /// active | depleted | void | expired
    var status: String
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case giftCardID = "gift_card_id"
        case kind
        case last4
        case balanceCents = "balance_cents"
        case status
        case expiresAt = "expires_at"
    }

    /// Store credit rather than a gift card.
    var isStoreCredit: Bool { kind == "credit" }

    /// Can pay an invoice now.
    var isRedeemable: Bool { status == "active" && balanceCents > 0 }

    /// "Gift card …7K2Q" / "Store credit …7K2Q".
    var label: String {
        "\(isStoreCredit ? "Store credit" : "Gift card") …\(last4)"
    }

    /// Why it can't be used, for people; nil when it can.
    var problem: String? {
        switch status {
        case "void": return "This gift card has been voided."
        case "expired": return "This gift card has expired."
        case "depleted": return "This gift card has no balance left."
        default: return balanceCents > 0 ? nil : "This gift card has no balance left."
        }
    }

    /// Codes are 16 letters and digits (shown as XXXX-XXXX-XXXX-XXXX); the
    /// server ignores spaces, dashes and case.
    static func normalizedCode(_ text: String) -> String {
        text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Long enough to be worth checking (a full code has 16 characters).
    static func isPlausibleCode(_ text: String) -> Bool {
        let code = normalizedCode(text)
        return code.count >= 8 && code.count <= 32
    }

    /// Columns of `Credit` (the code hash is not readable by the app).
    static let creditSelectColumns = "id,kind,code_last4,balance_cents,status,owner_customer_id,issued_via,expires_at,created_at"

    /// Store credit owned by a customer (`gift_cards`, kind credit; the code
    /// hash column is not readable by the app).
    // table: gift_cards
    struct Credit: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var kind: String
        var codeLast4: String
        var balanceCents: Int
        var status: String
        var ownerCustomerID: UUID?
        var issuedVia: String
        var expiresAt: Date?
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case kind
            case codeLast4 = "code_last4"
            case balanceCents = "balance_cents"
            case status
            case ownerCustomerID = "owner_customer_id"
            case issuedVia = "issued_via"
            case expiresAt = "expires_at"
            case createdAt = "created_at"
        }

        static let selectColumns = MoneyGiftCard.creditSelectColumns

        /// Where it came from: "Referral reward", "Refund", …
        var sourceText: String {
            switch issuedVia {
            case "referral": return "Referral reward"
            case "refund": return "Refund"
            case "online": return "Bought online"
            default: return "Issued by the shop"
            }
        }

        /// Usable at `now` (active, balance left, not expired).
        func isUsable(now: Date = Date()) -> Bool {
            guard status == "active", balanceCents > 0 else { return false }
            if let expiresAt, expiresAt <= now { return false }
            return true
        }
    }

    /// What `redeem_gift_card` / `redeem_customer_credit` returned: the new
    /// payment, or (for an unknown code) nothing.
    // rpc: redeem_gift_card
    struct Redemption: Codable, Hashable, Sendable {
        var id: UUID?
        var amountCents: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case amountCents = "amount_cents"
        }
    }
}
