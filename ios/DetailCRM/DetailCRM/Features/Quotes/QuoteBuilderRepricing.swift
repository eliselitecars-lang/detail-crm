//
//  QuoteBuilderRepricing.swift
//  DetailCRM
//
//  Keeps the quote builder's catalog prices in step with the customer and
//  vehicle. `price_services` prices a service for the vehicle's size class
//  and the customer's active memberships (included services cost 0; a plan
//  discount becomes the suggested document discount). When the customer or
//  vehicle changes, lines that still carry the old catalog price (and a
//  discount that is still the old membership suggestion) are moved to the
//  new context's prices; prices typed in by hand are left alone.
//
//  Pure logic (no SwiftUI) so it can be type-checked and reasoned about on
//  its own; QuoteBuilderView runs the two `price_services` calls.
//

import Foundation
import DetailCore

/// The customer + vehicle a set of catalog prices was computed for.
struct QuoteBuilderPricingContext: Hashable, Sendable {
    var customerID: UUID?
    var vehicleID: UUID?
}

/// What to do with the document discount after re-pricing.
enum QuoteBuilderDiscountChange: Hashable, Sendable {
    case keep
    /// Membership percent discount, in basis points.
    case setPercent(Int)
    /// The old membership discount no longer applies.
    case clear
}

struct QuoteBuilderRepriceOutcome: Hashable, Sendable {
    var lines: [QuoteDraftLine]
    /// Lines whose price or pricing note changed.
    var changedLineCount: Int
    var discount: QuoteBuilderDiscountChange
}

enum QuoteBuilderRepricing {

    /// Note on a catalog line the catalog has no price for (price set to 0).
    static let missingPriceNote = "No catalog price for this vehicle size — tap to set a price."

    /// Unique catalog service ids on the draft, in line order.
    static func serviceIDs(in lines: [QuoteDraftLine]) -> [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for line in lines {
            guard let serviceID = line.serviceID, !seen.contains(serviceID) else { continue }
            seen.insert(serviceID)
            ids.append(serviceID)
        }
        return ids
    }

    /// Moves catalog lines priced for `old` to the `new` pricing.
    ///
    /// A line follows the catalog when its unit price still equals the old
    /// context's price for its service (0 when that was a membership
    /// inclusion or a missing price); those get the new price and note.
    /// Anything else was priced by hand and is kept. The discount follows
    /// the same rule: a percent discount equal to the old membership
    /// suggestion becomes the new suggestion (or is cleared); with no
    /// discount, a new membership suggestion is applied.
    static func reprice(
        lines: [QuoteDraftLine],
        old: QuotePricing?,
        new: QuotePricing,
        discountKind: MoneyDiscountKind,
        discountValue: Int?
    ) -> QuoteBuilderRepriceOutcome {
        let oldByService = byService(old?.lines ?? [])
        let newByService = byService(new.lines)
        var updated = lines
        var changed = 0
        for index in updated.indices {
            guard let serviceID = updated[index].serviceID,
                  let previous = oldByService[serviceID],
                  let fresh = newByService[serviceID] else { continue }
            let line = updated[index]
            if line.unitPriceCents == (previous.unitPriceCents ?? 0) {
                let price = fresh.unitPriceCents ?? 0
                let note = fresh.unitPriceCents == nil ? missingPriceNote : fresh.note
                if price != line.unitPriceCents || note != line.pricingNote {
                    changed += 1
                }
                updated[index].unitPriceCents = price
                updated[index].pricingNote = note
            } else if let note = line.pricingNote, note == previous.note || note == missingPriceNote {
                // Hand-priced: the old pricing note no longer describes it.
                updated[index].pricingNote = nil
                changed += 1
            }
        }
        return QuoteBuilderRepriceOutcome(
            lines: updated,
            changedLineCount: changed,
            discount: discountChange(
                old: percentSuggestion(old),
                new: percentSuggestion(new),
                discountKind: discountKind,
                discountValue: discountValue
            )
        )
    }

    /// Membership percent suggestion (basis points), if any.
    static func percentSuggestion(_ pricing: QuotePricing?) -> Int? {
        guard let pricing,
              pricing.suggestedDiscountKind == .percent,
              let value = pricing.suggestedDiscountValue,
              value > 0 else { return nil }
        return value
    }

    static func discountChange(
        old: Int?,
        new: Int?,
        discountKind: MoneyDiscountKind,
        discountValue: Int?
    ) -> QuoteBuilderDiscountChange {
        switch discountKind {
        case .percent:
            guard let old, discountValue == old else { return .keep }
            if let new {
                return new == old ? .keep : .setPercent(new)
            }
            return .clear
        case .none:
            if let new { return .setPercent(new) }
            return .keep
        case .fixed:
            return .keep
        }
    }

    private static func byService(_ lines: [QuotePricedLine]) -> [UUID: QuotePricedLine] {
        var map: [UUID: QuotePricedLine] = [:]
        for line in lines where map[line.serviceID] == nil {
            map[line.serviceID] = line
        }
        return map
    }
}
