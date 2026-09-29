//
//  CustomerLeadRequest.swift
//  DetailCRM
//
//  What a customer asked for on the shop's lead forms (P-9,
//  `lead_submissions`, written only by `public_submit_lead`): the message,
//  the vehicle they described and their answers to the form's customer
//  fields. A lead form never changes an existing customer's record, so the
//  customer screen is the only place staff see the request (the new-lead
//  notification opens it). Managers and up read them (RLS
//  `is_shop_manager`), as on the web customer page.
//

import Foundation
import Supabase
import DetailCore

// table: lead_submissions
struct CustomerLeadRequestRow: Decodable, Identifiable, Hashable, Sendable {
    var id: UUID
    var leadFormID: UUID?
    var message: String?
    /// The form's answers ({field key: value}); `{}` when none.
    var answers: [String: AnyJSON]?
    /// The vehicle as the visitor described it ({year, make, model}).
    var vehicleInfo: AnyJSON?
    /// The customer already existed (their record was left unchanged).
    var matchedExisting: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case leadFormID = "lead_form_id"
        case message
        case answers
        case vehicleInfo = "vehicle_info"
        case matchedExisting = "matched_existing"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "lead_form_id", "message", "answers", "vehicle_info", "matched_existing", "created_at",
    ].joined(separator: ",")
}

// table: lead_forms
struct CustomerLeadFormName: Decodable, Hashable, Sendable {
    var id: UUID
    var name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    static let selectColumns = "id,name"
}

/// One request as the customer screen shows it.
struct CustomerLeadRequest: Identifiable, Hashable, Sendable {
    var row: CustomerLeadRequestRow
    /// nil when the form was deleted since.
    var formName: String?

    var id: UUID { row.id }
    var createdAt: Date { row.createdAt }
    var matchedExisting: Bool { row.matchedExisting }

    var title: String { formName?.trimmedNonEmpty ?? LeadRequestText.deletedFormName }

    var message: String? { row.message?.trimmedNonEmpty }

    /// "2019 Toyota Tacoma", or nil when no vehicle was described.
    var vehicleText: String? {
        guard let info = row.vehicleInfo?.asObject else { return nil }
        let year = info["year"]?.asInt ?? info["year"]?.asString.flatMap { Int($0) }
        return LeadRequestText.vehicle(year: year, make: info["make"]?.asString, model: info["model"]?.asString)
    }

    /// One answer, labelled by the shop's customer field.
    struct Answer: Hashable, Sendable, Identifiable {
        var key: String
        var label: String
        var value: String

        var id: String { key }
    }

    /// The answers in the fields' order (archived fields too, so an answer
    /// to a field removed later keeps its label), then any answer whose
    /// field is gone, by key. Empty answers are left out.
    func answers(fields: [JobsCustomField]) -> [Answer] {
        let data = row.answers ?? [:]
        guard !data.isEmpty else { return [] }
        var out: [Answer] = []
        var known = Set<String>()
        for field in fields.sorted(by: { $0.sort < $1.sort }) {
            known.insert(field.key)
            guard let value = field.value(in: data), !value.isEmpty else { continue }
            out.append(Answer(key: field.key, label: field.label, value: value.displayText))
        }
        for key in data.keys.sorted() where !known.contains(key) {
            guard let text = Self.plainText(data[key]) else { continue }
            out.append(Answer(key: key, label: key, value: text))
        }
        return out
    }

    /// Text for an answer without a field definition (nil when empty).
    static func plainText(_ json: AnyJSON?) -> String? {
        guard let json else { return nil }
        switch json {
        case .string(let text):
            return text.trimmedNonEmpty
        case .bool(let flag):
            return flag ? "Yes" : "No"
        case .integer, .double:
            guard let number = json.asDouble else { return nil }
            return JobsCustomValue.number(number).displayText
        case .array(let items):
            let parts = items.compactMap { plainText($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }
}

/// The newest requests of a customer and how many exist.
struct CustomerLeadRequests: Hashable, Sendable {
    var requests: [CustomerLeadRequest]
    var total: Int

    var description: String {
        LeadRequestText.description(shown: requests.count, total: total)
    }
}
