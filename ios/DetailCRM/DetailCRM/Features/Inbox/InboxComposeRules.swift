//
//  InboxComposeRules.swift
//  DetailCRM
//
//  Pure (UI-free) rules for the message composer: which channels can
//  reach a customer, why sending is blocked, and a local preview of a
//  customer-level template. The server re-checks everything (consent,
//  addresses, SMS setup) when the message is sent.
//

import Foundation
import DetailCore

enum InboxComposeRules {

    /// SMS character limit (database + edge function).
    static let smsLimit = MessageService.smsLimit

    /// SMS length as the server counts it (UTF-16 code units).
    static func smsLength(_ text: String) -> Int {
        MessageService.smsLength(text)
    }

    /// Why `channel` can't be used for `customer`, or nil when it can.
    static func blockReason(channel: Message.Channel, customer: Customer?) -> String? {
        guard let customer else { return "Save this number as a customer to reply." }
        switch channel {
        case .sms:
            if customer.hasSmsOptOut {
                return "This customer opted out of texts (replied STOP). They can text START to opt back in."
            }
            if customer.phone?.trimmedNonEmpty == nil {
                return "No mobile number on file. Add one to text this customer."
            }
        case .email:
            if customer.hasEmailOptOut {
                return "This customer unsubscribed from email."
            }
            if customer.email?.trimmedNonEmpty == nil {
                return "No email address on file. Add one to email this customer."
            }
        }
        return nil
    }

    /// The channel to start with: text when possible, else email.
    static func preferredChannel(for customer: Customer?) -> Message.Channel {
        if blockReason(channel: .sms, customer: customer) == nil { return .sms }
        if blockReason(channel: .email, customer: customer) == nil { return .email }
        return .sms
    }

    /// Problem with the typed message, or nil when it can be sent.
    static func draftProblem(channel: Message.Channel, body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Write a message first." }
        if channel == .sms && smsLength(trimmed) > smsLimit {
            return "Texts are limited to \(smsLimit) characters."
        }
        return nil
    }

    // MARK: - Job templates

    /// Templates about an upcoming appointment: the job to pre-select is
    /// the customer's next one.
    static let upcomingJobTemplateKeys: Set<String> = [
        "booking_confirmed", "appointment_reminder", "on_the_way", "job_started",
    ]

    /// The job a template should start with, or nil to make staff choose.
    /// Only appointment templates get a default: the open, scheduled job
    /// that starts soonest among those not yet over (`scheduledEnd`, or
    /// `scheduledStart` when there is no end, at or after `now`). Anything
    /// else (unscheduled requests, finished or cancelled jobs, receipts,
    /// invoices) is left for staff to pick.
    static func defaultJobID(templateKey: String, jobs: [CustomerJobSummary], now: Date) -> UUID? {
        guard upcomingJobTemplateKeys.contains(templateKey) else { return nil }
        var best: CustomerJobSummary?
        for job in jobs where isOpen(job.status) {
            guard let start = job.scheduledStart else { continue }
            let end = job.scheduledEnd ?? start
            guard end >= now else { continue }
            if let current = best, let currentStart = current.scheduledStart, currentStart <= start {
                continue
            }
            best = job
        }
        return best?.id
    }

    private static func isOpen(_ status: JobStatus) -> Bool {
        switch status {
        case .requested, .scheduled, .confirmed, .enRoute, .inProgress:
            return true
        case .completed, .cancelled, .noShow:
            return false
        }
    }

    // MARK: - Local template preview

    /// Placeholders the app can fill for a customer-level preview (the
    /// same values the server uses when no job is attached).
    static func customerValues(customer: Customer, shop: Shop?) -> [String: String] {
        var values: [String: String] = [:]
        // A typed list, not a long `??` chain (Xcode's type checker times out).
        let firstCandidates: [String?] = [
            customer.firstName?.trimmedNonEmpty,
            customer.company?.trimmedNonEmpty,
            customer.lastName?.trimmedNonEmpty,
        ]
        let first: String = firstCandidates.compactMap { $0 }.first ?? "there"
        values["customer_first_name"] = first
        let fullName = [customer.firstName?.trimmedNonEmpty, customer.lastName?.trimmedNonEmpty]
            .compactMap { $0 }
            .joined(separator: " ")
        values["customer_name"] = fullName.nonEmpty ?? customer.company?.trimmedNonEmpty ?? ""
        if let shop {
            values["shop_name"] = shop.name
            values["shop_phone"] = shop.phone.map { PhoneNumber.format($0) } ?? ""
            values["review_link"] = shop.reviewURL ?? ""
        }
        return values
    }

    /// Renders `template` for a customer. Placeholders only the server can
    /// fill (links, job details) show as "[booking page link]" so the
    /// preview never pretends to know them.
    static func localPreview(_ template: String, customer: Customer, shop: Shop?) -> String {
        var values = customerValues(customer: customer, shop: shop)
        for name in TemplateRenderer.placeholders(in: template) where values[name] == nil {
            values[name] = "[" + name.replacingOccurrences(of: "_", with: " ") + "]"
        }
        return TemplateRenderer.render(template, values: values)
    }
}

/// One compose's idempotency nonce (`request_nonce` of `messaging` send).
/// Sending the same content again after a failure reuses the nonce, so a
/// message the server already queued is returned instead of sent twice;
/// changed content (or a successful send) starts a new one.
struct InboxComposeAttempt: Equatable, Sendable {
    let fingerprint: [String]
    let nonce: String

    static func next(after previous: InboxComposeAttempt?, fingerprint: [String]) -> InboxComposeAttempt {
        if let previous, previous.fingerprint == fingerprint {
            return previous
        }
        return InboxComposeAttempt(fingerprint: fingerprint, nonce: MessageService.newNonce())
    }
}
