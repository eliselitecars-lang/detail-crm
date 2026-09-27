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
    static let smsLimit = 1600

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
        if channel == .sms && trimmed.count > smsLimit {
            return "Texts are limited to \(smsLimit) characters."
        }
        return nil
    }

    // MARK: - Local template preview

    /// Placeholders the app can fill for a customer-level preview (the
    /// same values the server uses when no job is attached).
    static func customerValues(customer: Customer, shop: Shop?) -> [String: String] {
        var values: [String: String] = [:]
        let first = customer.firstName?.trimmedNonEmpty
            ?? customer.company?.trimmedNonEmpty
            ?? customer.lastName?.trimmedNonEmpty
            ?? "there"
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
