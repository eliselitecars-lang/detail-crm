//
//  TeamService.swift
//  DetailCRM
//
//  Team directory, invites, role / active changes and pay settings.
//  Server rules (SPEC §3): `shop_team` hides contact details from
//  technicians; invites and membership edits are owner/admin only
//  (`invite_member`, `revoke_invite`, `shop_members_client_guard`);
//  `member_compensation` is owner/admin read-write, own row read-only.
//
//  Invites go through the `invites` edge function: `send_invite` creates
//  the invite and emails the link; `resend_invite` re-emails the same link
//  while it is valid (an expired invite is re-issued with a new link). A
//  failed email still returns 200 with `email_sent: false` + `invite_url`,
//  which becomes `.createdWithoutEmail` so the admin can share the link.
//

import Foundation
import Supabase
import DetailCore

enum TeamService {

    // MARK: - Directory

    /// Every member visible to the caller (active first, then by name).
    static func directory(shopID: UUID) async throws -> [TeamDirectoryEntry] {
        struct Params: Encodable {
            let p_shop_id: UUID
        }
        return try await Supa.client
            .rpc("shop_team", params: Params(p_shop_id: shopID))
            .execute()
            .value
    }

    // MARK: - Invites

    /// Invites of the shop, newest first (owners/admins; others get none).
    static func invites(shopID: UUID) async throws -> [TeamInvite] {
        try await Supa.client
            .from("shop_invites")
            .select(TeamInvite.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("created_at", ascending: false)
            .limit(200)
            .execute()
            .value
    }

    /// Open (not accepted / revoked) invites, newest first.
    static func pendingInvites(shopID: UUID) async throws -> [TeamInvite] {
        try await invites(shopID: shopID).filter { $0.isOpen }
    }

    /// Creates an invite and emails the link via the `invites` function.
    /// When the function itself is unavailable (not deployed: HTTP 404
    /// without a JSON error body) the invite is created with the
    /// `invite_member` RPC so the link can be shared by hand.
    static func sendInvite(shopID: UUID, email: String, role: ShopRole) async throws -> TeamInviteOutcome {
        let address = Validation.normalizedEmail(email)
        guard Validation.isValidEmail(address) else {
            throw AppError.invalidInput("Enter a valid email address.")
        }
        guard role != .owner else {
            throw AppError.invalidInput("Invites can't grant the owner role.")
        }
        let body = TeamSendInviteBody(
            shop_id: shopID.uuidString.lowercased(),
            email: address,
            role: role.rawValue
        )
        do {
            let reply: TeamInviteReply = try await Supa.client.functions.invoke(
                "invites",
                options: FunctionInvokeOptions(body: body)
            )
            return TeamInviteOutcome.from(reply, isResend: false)
        } catch let error as FunctionsError {
            let edge = await EdgeFunctions.failure(from: error)
            // A 404 without our envelope: the invites function isn't deployed.
            if edge.status == 404 && !edge.isEnvelope {
                let invite = try await createInviteDirectly(shopID: shopID, email: address, role: role)
                return .createdWithoutEmail(link: invite?.link, newLink: true)
            }
            throw edge
        } catch is DecodingError {
            // 2xx but an unreadable reply: the invite exists; don't claim an email went out.
            throw AppError.message("The invite was saved, but we couldn't confirm the email. Check Pending invites and share the link if needed.")
        }
    }

    /// `invite_member` (owner/admin): creates the invite row only (and
    /// revokes any other pending invite for that email). Returns the row.
    @discardableResult
    static func createInviteDirectly(shopID: UUID, email: String, role: ShopRole) async throws -> TeamInvite? {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_email: String
            let p_role: String
        }
        let response = try await Supa.client
            .rpc("invite_member", params: Params(p_shop_id: shopID, p_email: email, p_role: role.rawValue))
            .execute()
        // The invite exists now; a row that doesn't decode only costs the
        // link (it can still be shared from the pending list).
        return try? PostgrestClient.Configuration.jsonDecoder.decode(TeamInvite.self, from: response.data)
    }

    /// Re-emails a pending invite (`resend_invite`). The same link is sent
    /// again while it is valid; an expired invite is replaced by a new one.
    /// When the invites function is unavailable, a valid invite's existing
    /// link is offered for sharing and an expired one is re-created.
    static func resendInvite(_ invite: TeamInvite) async throws -> TeamInviteOutcome {
        let body = TeamResendInviteBody(invite_id: invite.id.uuidString.lowercased())
        do {
            let reply: TeamInviteReply = try await Supa.client.functions.invoke(
                "invites",
                options: FunctionInvokeOptions(body: body)
            )
            return TeamInviteOutcome.from(reply, isResend: true)
        } catch let error as FunctionsError {
            let edge = await EdgeFunctions.failure(from: error)
            // A 404 without our envelope: the invites function isn't deployed.
            if edge.status == 404 && !edge.isEnvelope {
                if !invite.isExpired() {
                    return .createdWithoutEmail(link: invite.link, newLink: false)
                }
                let fresh = try await createInviteDirectly(shopID: invite.shopID, email: invite.email, role: invite.role)
                return .createdWithoutEmail(link: fresh?.link, newLink: true)
            }
            throw edge
        } catch is DecodingError {
            // 2xx but an unreadable reply: the invite exists; don't claim an email went out.
            throw AppError.message("The invite was saved, but we couldn't confirm the email. Check Pending invites and share the link if needed.")
        }
    }

    static func revokeInvite(inviteID: UUID) async throws {
        struct Params: Encodable {
            let p_invite_id: UUID
        }
        try await Supa.client
            .rpc("revoke_invite", params: Params(p_invite_id: inviteID))
            .execute()
    }

    // MARK: - Membership edits (owner/admin; server enforces)

    static func changeRole(shopID: UUID, memberID: UUID, to role: ShopRole) async throws {
        let rows: [TeamMemberRowRef] = try await Supa.client
            .from("shop_members")
            .update(TeamRoleUpdate(role: role), returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: memberID.uuidString)
            .select("id,role,active")
            .execute()
            .value
        guard rows.first?.role == role else {
            throw AppError.message("Only owners and admins can change roles.")
        }
    }

    /// Owner only: makes another active member the owner
    /// (`transfer_ownership`); the caller becomes an admin. Then the billing
    /// function's `sync_customer` points the shop's platform billing
    /// customer (receipts, renewal and failed-payment emails) at the new
    /// owner right away.
    static func transferOwnership(shopID: UUID, memberID: UUID) async throws {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_member_id: UUID
        }
        try await Supa.client
            .rpc("transfer_ownership", params: Params(p_shop_id: shopID, p_member_id: memberID))
            .execute()
        await syncBillingCustomer(shopID: shopID)
    }

    /// Best effort, after a transfer (the former owner is an admin by then,
    /// which `sync_customer` allows): a failure never fails the transfer,
    /// and the daily `sync_customers` run readdresses the customer anyway.
    private static func syncBillingCustomer(shopID: UUID) async {
        struct Body: Encodable {
            let action: String
            let shop_id: String
        }
        let body = Body(action: "sync_customer", shop_id: shopID.uuidString.lowercased())
        try? await Supa.client.functions.invoke("billing", options: FunctionInvokeOptions(body: body))
    }

    static func setActive(shopID: UUID, memberID: UUID, active: Bool) async throws {
        let rows: [TeamMemberRowRef] = try await Supa.client
            .from("shop_members")
            .update(TeamActiveUpdate(active: active), returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: memberID.uuidString)
            .select("id,role,active")
            .execute()
            .value
        guard rows.first?.active == active else {
            throw AppError.message("Only owners and admins can change who is active.")
        }
    }

    // MARK: - Compensation

    /// The member's pay settings, or nil when none are set (or not visible).
    static func compensation(shopID: UUID, memberID: UUID) async throws -> MemberCompensation? {
        let rows: [MemberCompensation] = try await Supa.client
            .from("member_compensation")
            .select(MemberCompensation.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("member_id", value: memberID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Creates or updates the member's pay settings (owner/admin).
    static func saveCompensation(_ compensation: MemberCompensation) async throws -> MemberCompensation {
        let rows: [MemberCompensation] = try await Supa.client
            .from("member_compensation")
            .upsert(compensation, onConflict: "member_id", returning: .representation)
            .select(MemberCompensation.selectColumns)
            .execute()
            .value
        guard let row = rows.first else {
            throw AppError.message("Only owners and admins can change pay settings.")
        }
        return row
    }
}
