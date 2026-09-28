//
//  AccountService.swift
//  DetailCRM
//
//  The signed-in person's own account. Deleting it (App Store guideline
//  5.1.1(v)) goes through the `account` edge function (`delete_account`),
//  which first asks the database whether the caller still owns a shop
//  (`account_deletion_blockers`): a shop can't be left without an owner,
//  so the owner first makes another team member the owner
//  (`transfer_ownership`, Team) or deletes the shop (`payments` →
//  `delete_shop`). Both can be done in the app (AccountDeletionView), so an
//  account made entirely on the iPhone can also be deleted there. What the
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
            throw AccountDeletionBlocked(owned: ownedShops(in: error.details))
        }
    }

    /// The shops the signed-in person owns (`account_deletion_blockers`),
    /// ordered by name: each must get a new owner or be deleted before the
    /// account can be.
    static func ownedShops() async throws -> [AccountOwnedShop] {
        let reply: AccountDeletionBlockersReply = try await Supa.client
            .rpc("account_deletion_blockers")
            .execute()
            .value
        return reply.ownedShops
    }

    /// The shops in the 409 `owns_shops` details (`details.shops`, each
    /// `{shop_id, name}`).
    static func ownedShops(in details: [String: AnyJSON]?) -> [AccountOwnedShop] {
        let shops = details?["shops"]?.asArray ?? []
        return shops.compactMap { entry in
            guard let object = entry.asObject,
                  let name = object["name"]?.asString?.trimmedNonEmpty,
                  let rawID = object["shop_id"]?.asString,
                  let id = UUID(uuidString: rawID) else { return nil }
            return AccountOwnedShop(shopID: id, name: name)
        }
    }
}

/// A shop the signed-in person owns (`account_deletion_blockers`).
struct AccountOwnedShop: Decodable, Hashable, Identifiable, Sendable {
    var shopID: UUID
    var name: String

    var id: UUID { shopID }

    private enum Keys: String, CodingKey {
        case shopID = "shop_id"
        case name
    }

    init(shopID: UUID, name: String) {
        self.shopID = shopID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        shopID = try c.decode(UUID.self, forKey: .shopID)
        name = try c.decode(String.self, forKey: .name)
    }
}

/// `account_deletion_blockers()` → `{"owned_shops": [{shop_id, name}]}`.
private struct AccountDeletionBlockersReply: Decodable {
    var ownedShops: [AccountOwnedShop]

    private enum Keys: String, CodingKey {
        case ownedShops = "owned_shops"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ownedShops = try c.decodeIfPresent([AccountOwnedShop].self, forKey: .ownedShops) ?? []
    }
}

/// The account can't be deleted while the person owns a shop.
struct AccountDeletionBlocked: LocalizedError, Equatable {
    let owned: [AccountOwnedShop]

    var shops: [String] { owned.map(\.name) }

    var errorDescription: String? {
        let names: String
        switch shops.count {
        case 0:
            names = "a shop"
        case 1:
            names = shops[0]
        default:
            names = shops.dropLast().joined(separator: ", ") + " and " + (shops.last ?? "")
        }
        let noun = shops.count > 1 ? "each shop" : "the shop"
        return "You own \(names). Make another team member the owner of \(noun), or delete it, then delete your account."
    }
}

/// `account` / `delete_account` (the function's schema is strict: no other keys).
private struct AccountDeletionBody: Encodable {
    var action = "delete_account"
}

private struct AccountDeletionReply: Decodable {
    let deleted: Bool
}
