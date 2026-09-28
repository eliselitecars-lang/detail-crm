//
//  MoneyQuoteOptionsSection.swift
//  DetailCRM
//
//  The proposal options of a quote on its screen (P-15): each option with
//  its server totals (shared items + its own), which one the customer
//  chose, and which one the quote total counts until they do.
//

import SwiftUI
import DetailCore

struct MoneyQuoteOptionsSection: View {
    let quote: Quote
    let options: [MoneyQuoteOption]
    let currencyCode: String

    var body: some View {
        MoneySectionCard("Options") {
            Text(explanation)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MoneyQuoteOption.ordered(options)) { option in
                MoneyQuoteOptionsSection.Row(
                    option: option,
                    badge: badge(for: option),
                    currencyCode: currencyCode
                )
                if option.id != MoneyQuoteOption.ordered(options).last?.id {
                    Divider().overlay(Theme.border)
                }
            }
        }
    }

    private var customerChose: Bool {
        quote.selectedOptionID != nil && (quote.status == .approved || quote.status == .converted)
    }

    private var explanation: String {
        if customerChose {
            return "The customer chose one option; the quote total is that option."
        }
        return "The customer picks one option when approving. Until then the quote total shows the first option."
    }

    private func badge(for option: MoneyQuoteOption) -> (text: String, tone: StatusTone)? {
        let effective = quote.effectiveOptionID(options: options)
        guard option.id == effective else { return nil }
        if customerChose {
            return ("Chosen", .success)
        }
        if quote.selectedOptionID == option.id {
            return ("Preselected", .info)
        }
        return ("In the total", .neutral)
    }

    /// One option: name, description, total (tax and discount below).
    struct Row: View {
        let option: MoneyQuoteOption
        let badge: (text: String, tone: StatusTone)?
        let currencyCode: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(option.name)
                            .font(Theme.Typography.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let badge {
                            StatusBadge(text: badge.text, tone: badge.tone)
                        }
                    }
                    if let description = option.optionDescription?.trimmedNonEmpty {
                        Text(description)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(breakdown)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: option.totalCents, currencyCode: currencyCode)
            }
            .accessibilityElement(children: .combine)
        }

        private var breakdown: String {
            var parts = ["Subtotal \(Money.format(cents: option.subtotalCents, currencyCode: currencyCode))"]
            if option.discountCents > 0 {
                parts.append("discount −\(Money.format(cents: option.discountCents, currencyCode: currencyCode))")
            }
            parts.append("tax \(Money.format(cents: option.taxCents, currencyCode: currencyCode))")
            return parts.joined(separator: " · ")
        }
    }
}
