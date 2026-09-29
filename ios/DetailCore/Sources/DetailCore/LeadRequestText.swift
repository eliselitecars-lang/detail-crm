//
//  LeadRequestText.swift
//  DetailCore
//
//  Words for what a customer asked for on the shop's lead forms (P-9,
//  `lead_submissions`): the vehicle they described and the note on top of
//  the list. A lead form never changes an existing customer's record, so
//  the customer screen is the only place staff see the request. Same
//  wording as the web customer page.
//

import Foundation

public enum LeadRequestText {

    /// Most recent requests shown on the customer screen.
    public static let limit = 10

    /// "2019 Toyota Tacoma", or nil when the visitor gave none of them.
    public static func vehicle(year: Int?, make: String?, model: String?) -> String? {
        let parts = [year.map(String.init), make, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The note under the card title.
    public static func description(shown: Int, total: Int) -> String {
        if total > shown {
            return "The latest \(shown) of \(total) requests sent from your lead forms."
        }
        return "Sent from your lead forms. Their details are kept here as they were sent."
    }

    /// Title of a request whose form was deleted since.
    public static let deletedFormName = "A deleted lead form"

    /// Under a matched request that described a vehicle.
    public static let matchedExistingNote =
        "The form matched this customer, so nothing on their record was changed and the vehicle wasn't added."
}
