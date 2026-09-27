//
//  Team.swift
//  DetailCRM
//
//  Team directory (`shop_team` RPC), pending invites (`shop_invites`),
//  pay settings (`member_compensation`) and the membership edits owners
//  and admins make. Rules (SPEC §3) are enforced by RLS / triggers /
//  RPCs: technicians see names and colours only; only owners and admins
//  invite, change roles, deactivate or see pay (plus each member's own
//  pay, read-only); nobody becomes owner except via transfer_ownership.
//

import Foundation
import DetailCore

/// One member as `shop_team` returns it. Phone and email are null for
/// technician callers; inactive members are only returned to managers+.
// rpc: shop_team
struct TeamDirectoryEntry: Codable, Identifiable, Hashable, Sendable {
    var memberID: UUID
    var userID: UUID
    var role: ShopRole
    var displayName: String
    var calendarColor: String?
    var active: Bool
    var phone: String?
    var email: String?

    var id: UUID { memberID }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case userID = "user_id"
        case role
        case displayName = "display_name"
        case calendarColor = "calendar_color"
        case active
        case phone
        case email
    }
}

/// An invite row (owners/admins only can read these).
// table: shop_invites
struct TeamInvite: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var email: String
    var role: ShopRole
    var token: UUID
    var expiresAt: Date
    var acceptedAt: Date?
    var revokedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case email
        case role
        case token
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,shop_id,email,role,token,expires_at,accepted_at,revoked_at,created_at"

    /// Not accepted and not revoked (it may still be expired).
    var isOpen: Bool { acceptedAt == nil && revokedAt == nil }

    func isExpired(now: Date = Date()) -> Bool { expiresAt <= now }

    /// The public invite page (`WEB_APP_URL/invite/<token>`), when configured.
    var link: URL? {
        ShopSettingsWebLinks.webURL(path: "/invite/\(token.uuidString.lowercased())")
    }
}

/// Pay settings of one member (no row = nothing set yet).
// table: member_compensation
struct MemberCompensation: Codable, Identifiable, Hashable, Sendable {
    var shopID: UUID
    var memberID: UUID
    var hourlyRateCents: Int
    var commissionBps: Int

    var id: UUID { memberID }

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case memberID = "member_id"
        case hourlyRateCents = "hourly_rate_cents"
        case commissionBps = "commission_bps"
    }

    static let selectColumns = "shop_id,member_id,hourly_rate_cents,commission_bps"
}

/// Owner/admin role change on a membership.
// table: shop_members
struct TeamRoleUpdate: Encodable, Sendable {
    var role: ShopRole

    enum CodingKeys: String, CodingKey {
        case role
    }
}

/// Owner/admin (de)activation of a membership.
// table: shop_members
struct TeamActiveUpdate: Encodable, Sendable {
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case active
    }
}

/// Minimal membership row returned after an update (to confirm the write
/// actually matched a row — RLS turns forbidden updates into no-ops).
// table: shop_members
struct TeamMemberRowRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var role: ShopRole
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case active
    }
}

/// Body of the `invites` edge function's `send_invite` action (edge
/// function JSON, not a table — property names are the wire names).
struct TeamSendInviteBody: Encodable, Sendable {
    var action: String = "send_invite"
    var shop_id: String
    var email: String
    var role: String
}

/// Body of the `invites` edge function's `resend_invite` action: re-emails
/// the same link while the invite is valid; an expired one is re-issued.
struct TeamResendInviteBody: Encodable, Sendable {
    var action: String = "resend_invite"
    var invite_id: String
}

/// Successful reply of `send_invite` / `resend_invite` (only the fields the
/// app uses). A failed email still returns 200 with `email_sent: false`.
struct TeamInviteReply: Decodable, Sendable {
    var invite_url: String?
    var email_sent: Bool
    /// resend_invite only: true when an expired invite was replaced.
    var reissued: Bool?
}

/// Result of sending or re-sending an invite.
enum TeamInviteOutcome: Equatable, Sendable {
    /// The link was emailed. `newLink` is true when a new invite link was
    /// issued (always for a new invite; for a resend only when the old
    /// one had expired) — otherwise the same link was emailed again.
    case emailed(newLink: Bool)
    /// The invite exists but no email went out (email failed, or the
    /// invites function is unavailable): the admin must share `link`
    /// by hand. `link` is nil only when no link could be built.
    case createdWithoutEmail(link: URL?, newLink: Bool)

    /// Builds the outcome from the function's reply.
    static func from(_ reply: TeamInviteReply, isResend: Bool) -> TeamInviteOutcome {
        let newLink = isResend ? (reply.reissued ?? false) : true
        if reply.email_sent {
            return .emailed(newLink: newLink)
        }
        let text = (reply.invite_url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let link: URL? = text.isEmpty ? nil : URL(string: text)
        return .createdWithoutEmail(link: link, newLink: newLink)
    }
}

/// Membership rules the Team screens apply (UI only — the server enforces
/// the same rules in `shop_members_client_guard`, RLS and the RPCs).
enum TeamPermissions {

    /// Roles `actor` may pick when changing `target` (excluding its current role).
    static func assignableRoles(actor: ShopRole, target: ShopRole, isSelf: Bool) -> [ShopRole] {
        guard !isSelf else { return [] }
        return [ShopRole.admin, .manager, .technician].filter { actor.canChangeRole(of: target, to: $0) }
    }

    /// Whether `actor` may deactivate / reactivate `target`.
    static func canToggleActive(actor: ShopRole, target: ShopRole, isSelf: Bool) -> Bool {
        !isSelf && actor.canDeactivate(target)
    }
}
