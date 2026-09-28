//
//  MoneyFollowupStatus.swift
//  DetailCRM
//
//  Automatic follow-ups of one quote or invoice (P-3): unanswered quotes,
//  invoice reminders before the due date and overdue notices after it.
//  The shop turns each kind on (followup settings + an enabled template,
//  on the web); staff can pause them per document. Everything here is the
//  server's (`document_followup_status` / `set_document_followups_paused`).
//

import Foundation

// rpc: document_followup_status
struct MoneyFollowupStatus: Codable, Hashable, Sendable {
    /// The document kind asked for: quote | deposit | invoice.
    var kind: String
    /// Which follow-up applies now: quote | deposit | invoice |
    /// invoice_overdue (an invoice past its due date gets overdue notices).
    var stage: String?
    /// The shop's setting is on AND a template for it is enabled.
    var enabled: Bool
    var paused: Bool
    var attemptsSent: Int
    var maxAttempts: Int
    var lastSentAt: Date?
    /// When the next one goes out; nil when none is due (paused, no
    /// attempts left, or the document no longer qualifies).
    var nextAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind
        case stage
        case enabled
        case paused
        case attemptsSent = "attempts_sent"
        case maxAttempts = "max_attempts"
        case lastSentAt = "last_sent_at"
        case nextAt = "next_at"
    }

    /// Documents the follow-up RPCs take (`p_kind`).
    enum DocumentKind: String, Hashable, Sendable {
        case quote
        case invoice
    }

    /// Overdue notices (as opposed to reminders before the due date).
    var isOverdueStage: Bool { stage == "invoice_overdue" }

    /// "Quote follow-ups", "Invoice reminders", "Overdue notices".
    var title: String {
        switch stage {
        case "invoice_overdue": return "Overdue notices"
        case "invoice": return "Invoice reminders"
        case "deposit": return "Deposit reminders"
        default: return "Quote follow-ups"
        }
    }

    /// No more will be sent for this document (all attempts used).
    var isFinished: Bool { maxAttempts > 0 && attemptsSent >= maxAttempts }
}
