//
//  MoneyFollowupService.swift
//  DetailCRM
//
//  Automatic quote / invoice follow-ups (P-3): read their status and pause
//  or resume them for one document. Owners, admins and managers only (the
//  RPCs refuse technicians with 42501).
//

import Foundation
import Supabase

enum MoneyFollowupService {

    /// Follow-up status of one quote or invoice.
    static func status(kind: MoneyFollowupStatus.DocumentKind, documentID: UUID) async throws -> MoneyFollowupStatus {
        let params: [String: AnyJSON] = [
            "p_kind": .string(kind.rawValue),
            "p_id": .string(documentID.uuidString),
        ]
        return try await Supa.client
            .rpc("document_followup_status", params: params)
            .execute()
            .value
    }

    /// Pauses (true) or resumes (false) the document's follow-ups; returns
    /// the new status.
    static func setPaused(
        kind: MoneyFollowupStatus.DocumentKind,
        documentID: UUID,
        paused: Bool
    ) async throws -> MoneyFollowupStatus {
        let params: [String: AnyJSON] = [
            "p_kind": .string(kind.rawValue),
            "p_id": .string(documentID.uuidString),
            "p_paused": .bool(paused),
        ]
        return try await Supa.client
            .rpc("set_document_followups_paused", params: params)
            .execute()
            .value
    }
}
