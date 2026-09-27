//
//  ShopMember.swift
//  DetailCRM
//
//  Staff membership rows, the signed-in user's profile, and the joined
//  membership + shop value AppState works with.
//

import Foundation
import DetailCore

// table: shop_members
struct ShopMember: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var userID: UUID
    var role: ShopRole
    var displayName: String
    var phone: String?
    var calendarColor: String?
    var active: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case userID = "user_id"
        case role
        case displayName = "display_name"
        case phone
        case calendarColor = "calendar_color"
        case active
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "user_id", "role", "display_name", "phone",
        "calendar_color", "active", "created_at", "updated_at",
    ].joined(separator: ",")
}

// table: profiles
struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var fullName: String?
    var phone: String?
    var avatarPath: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case phone
        case avatarPath = "avatar_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// rpc: public_get_invite
struct InvitePreview: Codable, Hashable, Sendable {
    var shopName: String
    var shopSlug: String
    var role: ShopRole
    var email: String
    var expiresAt: Date
    /// `pending` | `accepted` | `revoked` | `expired`
    var status: String

    enum CodingKeys: String, CodingKey {
        case shopName = "shop_name"
        case shopSlug = "shop_slug"
        case role
        case email
        case expiresAt = "expires_at"
        case status
    }

    var isPending: Bool { status == "pending" }

    var statusMessage: String {
        switch status {
        case "pending": return "Ready to accept."
        case "accepted": return "This invite has already been used."
        case "revoked": return "This invite was revoked. Ask for a new one."
        case "expired": return "This invite has expired. Ask for a new one."
        default: return "This invite can't be used."
        }
    }
}

/// A shop the signed-in user belongs to, with their membership in it.
struct ShopMembership: Identifiable, Hashable, Sendable {
    var member: ShopMember
    var shop: Shop

    /// Identified by shop — a user has at most one membership per shop.
    var id: UUID { shop.id }
    var role: ShopRole { member.role }
}
