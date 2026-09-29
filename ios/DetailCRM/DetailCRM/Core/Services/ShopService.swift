//
//  ShopService.swift
//  DetailCRM
//
//  Shops the signed-in user belongs to, creating a shop, and joining one
//  by invite. All rules (slug format, reserved words, one owner, invite
//  email match, expiry) are enforced by the RPCs in 0002_foundation_tenancy.
//

import Foundation
import Supabase

enum ShopService {

    // MARK: - Memberships

    /// Active memberships of the signed-in user, each joined with its shop,
    /// sorted by shop name. Two plain queries (no embeds) so every column
    /// name is checkable against the schema.
    static func myMemberships() async throws -> [ShopMembership] {
        let userID = try await Supa.currentUserID()
        let members: [ShopMember] = try await Supa.client
            .from("shop_members")
            .select(ShopMember.selectColumns)
            .eq("user_id", value: userID.uuidString)
            .eq("active", value: true)
            .execute()
            .value
        guard !members.isEmpty else { return [] }

        let shops: [Shop] = try await Supa.client
            .from("shops")
            .select(Shop.selectColumns)
            .in("id", values: members.map { $0.shopID.uuidString })
            .execute()
            .value
        let shopsByID = Dictionary(shops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return members
            .compactMap { member in
                shopsByID[member.shopID].map { ShopMembership(member: member, shop: $0) }
            }
            .sorted { $0.shop.name.localizedCaseInsensitiveCompare($1.shop.name) == .orderedAscending }
    }

    /// The signed-in user's profile row (created by trigger at sign-up).
    static func myProfile() async throws -> Profile? {
        let userID = try await Supa.currentUserID()
        let rows: [Profile] = try await Supa.client
            .from("profiles")
            .select("id,full_name,phone,avatar_path,created_at,updated_at")
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Create shop

    struct NewShop: Equatable {
        var name: String
        var slug: String
        var timezone: String
        var businessType: BusinessType
        /// E.164 or nil.
        var phone: String?
        var email: String?
    }

    /// Calls `create_shop`; the caller becomes the owner. Returns the shop.
    static func createShop(_ input: NewShop) async throws -> Shop {
        struct Params: Encodable {
            let p_name: String
            let p_slug: String
            let p_timezone: String
            let p_business_type: String
            let p_phone: String?
            let p_email: String?
        }
        let params = Params(
            p_name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
            p_slug: input.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            p_timezone: input.timezone,
            p_business_type: input.businessType.rawValue,
            p_phone: input.phone,
            p_email: input.email
        )
        return try await Supa.client
            .rpc("create_shop", params: params)
            .execute()
            .value
    }

    // MARK: - Delete shop (owner only)

    /// Deletes a shop the caller owns through `payments` → `delete_shop`:
    /// the server first ends the shop's own subscription, cancels every
    /// membership's Stripe subscription, settles or expires open card
    /// payments and pay links (409 `payment_in_progress` while one is still
    /// processing — nothing is deleted), then deletes the shop and every
    /// record in it. `confirmName` must be the shop's name (422
    /// `name_mismatch`). The shop's Stripe account and payouts are kept.
    /// Afterwards the caller re-reads the memberships.
    @discardableResult
    static func deleteShop(shopID: UUID, confirmName: String) async throws -> ShopDeletionResult {
        do {
            return try await EdgeFunctions.invoke(
                "payments",
                body: ShopDeletionBody(shop_id: shopID.uuidString.lowercased(), confirm_name: confirmName)
            )
        } catch let error as EdgeFunctionError {
            throw ShopDeletionError(error)
        }
    }

    /// Whether `typed` confirms deleting a shop named `name` (the server
    /// compares trimmed and case-insensitive).
    static func deletionNameMatches(_ typed: String, name: String) -> Bool {
        let a = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }

    // MARK: - Leave a shop

    /// Leaves a shop's team (`leave_shop`, 0002): deactivates the caller's
    /// own membership, so they lose access, stop counting as a seat, stop
    /// being assignable and stop getting its notifications. Any role but
    /// the owner (23514 "transfer ownership first"). Other shops are not
    /// affected; coming back needs a new invite.
    static func leaveShop(shopID: UUID) async throws {
        try await Supa.client
            .rpc("leave_shop", params: ["p_shop_id": shopID.uuidString])
            .execute()
    }

    // MARK: - Invites

    /// Extracts an invite token from a pasted link (`…/invite/<uuid>`) or a
    /// bare token.
    static func inviteToken(from input: String) -> UUID? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = UUID(uuidString: trimmed) { return token }
        if let url = URL(string: trimmed) {
            for component in url.pathComponents.reversed() {
                if let token = UUID(uuidString: component) { return token }
            }
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                for item in items {
                    if let value = item.value, let token = UUID(uuidString: value) { return token }
                }
            }
        }
        return nil
    }

    /// Invite details for the confirmation step (`public_get_invite`).
    static func invitePreview(token: UUID) async throws -> InvitePreview? {
        let rows: [InvitePreview] = try await Supa.client
            .rpc("public_get_invite", params: ["p_token": token.uuidString])
            .execute()
            .value
        return rows.first
    }

    /// Joins the invite's shop (`accept_invite`). Returns the membership.
    static func acceptInvite(token: UUID) async throws -> ShopMember {
        try await Supa.client
            .rpc("accept_invite", params: ["p_token": token.uuidString])
            .execute()
            .value
    }
}

/// `payments` / `delete_shop` (strict schema: exactly these keys).
private struct ShopDeletionBody: Encodable {
    var action = "delete_shop"
    let shop_id: String
    let confirm_name: String
}

/// `payments` → `delete_shop`: what deleting the shop closed.
struct ShopDeletionResult: Decodable, Hashable, Sendable {
    var deleted: Bool
    var membershipsCancelled: Int
    var sessionsExpired: Int

    private enum Keys: String, CodingKey {
        case deleted
        case membershipsCancelled = "memberships_cancelled"
        case sessionsExpired = "sessions_expired"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        membershipsCancelled = try c.decodeIfPresent(Int.self, forKey: .membershipsCancelled) ?? 0
        sessionsExpired = try c.decodeIfPresent(Int.self, forKey: .sessionsExpired) ?? 0
    }
}

/// A `delete_shop` refusal in words the owner can act on (same wording as
/// the web's Settings > Delete shop).
struct ShopDeletionError: LocalizedError, Equatable {
    let underlying: EdgeFunctionError

    init(_ underlying: EdgeFunctionError) {
        self.underlying = underlying
    }

    var errorDescription: String? {
        switch underlying.reason {
        case "payment_in_progress":
            return "A card payment for this shop is still being processed. Wait a few minutes for it to finish, then try again. Nothing was deleted."
        case "name_mismatch":
            return "The name you typed doesn't match this shop's name. Nothing was deleted."
        case "platform_subscription_cancel_failed":
            return "We couldn't cancel the shop's subscription, so nothing was deleted. Try again."
        default:
            return underlying.errorDescription
        }
    }
}
