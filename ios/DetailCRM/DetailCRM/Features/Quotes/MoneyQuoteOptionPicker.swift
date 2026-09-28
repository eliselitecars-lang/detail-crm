//
//  MoneyQuoteOptionPicker.swift
//  DetailCRM
//
//  Chooses one proposal option of a quote (P-15): in the builder it picks
//  which lines are being edited (the shared lines or one option's), when
//  recording an approval it picks the option the customer chose.
//

import SwiftUI
import DetailCore

struct MoneyQuoteOptionPicker: View {
    /// One selectable option.
    struct Choice: Hashable {
        let id: UUID
        let name: String
    }

    let choices: [Choice]
    /// nil = the shared lines (only when `sharedTitle` is given).
    @Binding var selection: UUID?
    /// Title of the "shared by every option" segment; nil hides it.
    var sharedTitle: String? = nil
    var accessibilityTitle: String = "Option"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                if let sharedTitle {
                    MoneyFilterChip(title: sharedTitle, isSelected: selection == nil) {
                        selection = nil
                    }
                    .accessibilityLabel("\(accessibilityTitle): \(sharedTitle)")
                }
                ForEach(choices, id: \.id) { choice in
                    MoneyFilterChip(title: displayName(choice), isSelected: selection == choice.id) {
                        selection = choice.id
                    }
                    .accessibilityLabel("\(accessibilityTitle): \(displayName(choice))")
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    private func displayName(_ choice: Choice) -> String {
        choice.name.trimmedNonEmpty ?? "Untitled option"
    }
}

extension MoneyQuoteOptionPicker.Choice {
    init(option: MoneyQuoteOption) {
        self.init(id: option.id, name: option.name)
    }

    init(draft: MoneyQuoteOption.Draft) {
        self.init(id: draft.localID, name: draft.name)
    }
}
