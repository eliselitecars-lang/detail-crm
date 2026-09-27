//
//  AccountService.swift
//  DetailCRM
//
//  The signed-in person's own account. Deleting it (App Store guideline
//  5.1.1(v)) goes through the `account` edge function (`delete_account`),
//  which first asks the database whether the caller still owns a shop
//  (`account_deletion_blockers`): a shop can't be left without an owner,
//  so the owner must transfer ownership or delete the shop first. What the
//  person leaves behind is handled by the database (memberships and the
//  profile go; a shop's customers, jobs and payments stay with the shop).
//

import Foundation
import Supabase

enum AccountService {

    /// Permanently deletes the signed-in user's account. Throws
    /// `AccountDeletionBlocked` while they own a shop. The caller signs out
    /// afterwards.
    static func deleteAccount() async throws {
        do {
            let _: AccountDeletionReply = try await EdgeFunctions.invoke(
                "account",
                body: AccountDeletionBody()
            )
        } catch let error as EdgeFunctionError where error.reason == "owns_shops" {
            throw AccountDeletionBlocked(shops: ownedShops(in: error.details))
        }
    }

    /// The shop names in the 409 `owns_shops` details (`details.shops`).
    static func ownedShops(in details: [String: AnyJSON]?) -> [String] {
        let shops = details?["shops"]?.asArray ?? []
        return shops.compactMap { $0.asObject?["name"]?.asString?.trimmedNonEmpty }
    }
}

/// The account can't be deleted while the person owns a shop.
struct AccountDeletionBlocked: LocalizedError, Equatable {
    let shops: [String]

    var errorDescription: String? {
        let owned: String
        switch shops.count {
        case 0:
            owned = "a shop"
        case 1:
            owned = shops[0]
        default:
            owned = shops.dropLast().joined(separator: ", ") + " and " + (shops.last ?? "")
        }
        let noun = shops.count > 1 ? "the shops" : "the shop"
        return "You own \(owned). Transfer ownership or delete \(noun) on the web first."
    }
}

/// `account` / `delete_account` (the function's schema is strict: no other keys).
private struct AccountDeletionBody: Encodable {
    var action = "delete_account"
}

private struct AccountDeletionReply: Decodable {
    let deleted: Bool
}
