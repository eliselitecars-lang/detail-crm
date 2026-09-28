//
//  OpsCustomerCustomDataSection.swift
//  DetailCRM
//
//  The shop's customer fields (P-9) on the customer screen: answers from
//  lead forms and anything staff fill in ("Gate code", "Preferred
//  contact"). Everyone who can open the customer reads them; managers and
//  up edit them. The server validates every value against its field and
//  keeps the answer of a field archived later (shown read-only here). The
//  fields themselves are defined in the web app.
//
//  Uses the shared custom-field model and service (jobs agent) read-only.
//

import SwiftUI
import Supabase
import DetailCore

struct OpsCustomerCustomDataSection: View {
    let customer: Customer
    /// Every customer field of the shop, archived ones included (to label
    /// answers a customer still has for them); loaded with the customer.
    let fields: LoadState<[JobsCustomField]>
    let canEdit: Bool
    let retry: () async -> Void
    let onSaved: (Customer) -> Void

    @State private var editing = false

    var body: some View {
        Group {
            switch fields {
            case .idle, .loading:
                EmptyView()
            case .failed(let message):
                CustomersSectionCard("Details") {
                    CustomersSectionStatusRow(kind: .failed(message), retry: retry)
                }
            case .loaded(let all):
                let shown = all.filter { !$0.isArchived || $0.value(in: customer.customData) != nil }
                if !shown.isEmpty {
                    CustomersSectionCard(
                        "Details",
                        actionTitle: canEdit && all.contains(where: { !$0.isArchived }) ? "Edit" : nil,
                        action: canEdit ? startEditing : nil
                    ) {
                        rows(shown)
                    }
                    .sheet(isPresented: $editing) {
                        OpsCustomerCustomDataSection.Editor(
                            customer: customer,
                            fields: all.filter { !$0.isArchived },
                            onSaved: onSaved
                        )
                    }
                }
            }
        }
    }

    private func startEditing() {
        editing = true
    }

    private func rows(_ shown: [JobsCustomField]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(shown) { field in
                let value = field.value(in: customer.customData)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(field.isArchived ? "\(field.label) (no longer asked)" : field.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(value?.displayText ?? "—")
                        .font(Theme.Typography.body)
                        .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.xxs)
                .accessibilityElement(children: .combine)
            }
        }
    }

}

extension OpsCustomerCustomDataSection {
    /// Manager editor: one input per live field, by type.
    struct Editor: View {
        let customer: Customer
        let fields: [JobsCustomField]
        let onSaved: (Customer) -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(AppState.self) private var appState
        @Environment(ToastCenter.self) private var toasts
        @State private var values: [String: JobsCustomValue] = [:]
        @State private var numberText: [String: String] = [:]
        @State private var errorMessage: String?
        @State private var didPrefill = false

        var body: some View {
            NavigationStack {
                FormScreen {
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    ForEach(fields) { field in
                        FormRow(field.label, hint: field.helpText) {
                            input(for: field)
                        }
                    }
                }
                .navigationTitle("Customer details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        AsyncButton("Save", style: .themePrimaryCompact) { await save() }
                    }
                }
                .onAppear(perform: prefill)
            }
        }

        @ViewBuilder
        private func input(for field: JobsCustomField) -> some View {
            switch field.type {
            case .text:
                TextField(field.label, text: textBinding(field.key))
                    .inputFieldStyle()
            case .textarea:
                TextField(field.label, text: textBinding(field.key), axis: .vertical)
                    .lineLimit(3...8)
                    .inputFieldStyle()
            case .number:
                TextField("0", text: numberBinding(field.key))
                    .keyboardType(.decimalPad)
                    .inputFieldStyle()
            case .select:
                Picker(field.label, selection: selectBinding(field.key)) {
                    Text("Not set").tag("")
                    ForEach(field.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.glacier)
            case .multiselect:
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(field.options, id: \.self) { option in
                        Toggle(option, isOn: multiBinding(field.key, option: option))
                            .tint(Theme.glacier)
                    }
                }
            case .checkbox:
                Picker(field.label, selection: checkboxBinding(field.key)) {
                    Text("Not set").tag(0)
                    Text("Yes").tag(1)
                    Text("No").tag(2)
                }
                .pickerStyle(.segmented)
            case .date:
                dateInput(field.key)
            }
        }

        @ViewBuilder
        private func dateInput(_ key: String) -> some View {
            let calendar = appState.clock.calendar
            if case .date(let text) = values[key], let day = JobsCustomValue.date(fromDay: text, calendar: calendar) {
                HStack {
                    DatePicker("Date", selection: dateBinding(key, fallback: day), displayedComponents: [.date])
                        .labelsHidden()
                        .environment(\.timeZone, appState.clock.timeZone)
                    Spacer()
                    Button("Clear") { values[key] = nil }
                        .font(Theme.Typography.footnote.weight(.semibold))
                }
            } else {
                Button("Set a date") {
                    values[key] = .date(JobsCustomValue.dayString(from: Date(), calendar: calendar))
                }
                .buttonStyle(.themeSecondaryCompact)
            }
        }

        // MARK: - Bindings

        private func textBinding(_ key: String) -> Binding<String> {
            Binding(
                get: {
                    if case .text(let text) = values[key] { return text }
                    return ""
                },
                set: { values[key] = .text($0) }
            )
        }

        private func numberBinding(_ key: String) -> Binding<String> {
            Binding(
                get: { numberText[key] ?? "" },
                set: { numberText[key] = $0 }
            )
        }

        private func selectBinding(_ key: String) -> Binding<String> {
            Binding(
                get: {
                    if case .text(let text) = values[key] { return text }
                    return ""
                },
                set: { values[key] = $0.isEmpty ? nil : .text($0) }
            )
        }

        private func multiBinding(_ key: String, option: String) -> Binding<Bool> {
            Binding(
                get: {
                    if case .list(let items) = values[key] { return items.contains(option) }
                    return false
                },
                set: { on in
                    var items: [String] = []
                    if case .list(let current) = values[key] { items = current }
                    items.removeAll { $0 == option }
                    if on { items.append(option) }
                    values[key] = .list(items)
                }
            )
        }

        private func checkboxBinding(_ key: String) -> Binding<Int> {
            Binding(
                get: {
                    if case .bool(let flag) = values[key] { return flag ? 1 : 2 }
                    return 0
                },
                set: { choice in
                    values[key] = choice == 0 ? nil : .bool(choice == 1)
                }
            )
        }

        private func dateBinding(_ key: String, fallback: Date) -> Binding<Date> {
            let calendar = appState.clock.calendar
            return Binding(
                get: {
                    if case .date(let text) = values[key], let day = JobsCustomValue.date(fromDay: text, calendar: calendar) {
                        return day
                    }
                    return fallback
                },
                set: { values[key] = .date(JobsCustomValue.dayString(from: $0, calendar: calendar)) }
            )
        }

        // MARK: - Save

        private func prefill() {
            guard !didPrefill else { return }
            didPrefill = true
            for field in fields {
                guard let value = field.value(in: customer.customData) else { continue }
                values[field.key] = value
                if case .number(let number) = value {
                    numberText[field.key] = Int(exactly: number).map(String.init) ?? String(number)
                }
            }
        }

        private func save() async {
            errorMessage = nil
            var edited = values
            for field in fields where field.type == .number {
                let text = (numberText[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    edited[field.key] = nil
                } else if let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite {
                    edited[field.key] = .number(number)
                } else {
                    errorMessage = "\(field.label) must be a number."
                    return
                }
            }
            for field in fields {
                if let maxLength = field.type.maxLength, case .text(let text) = edited[field.key], text.count > maxLength {
                    errorMessage = "\(field.label) is limited to \(maxLength) characters."
                    return
                }
            }
            let data = JobsCustomFieldService.mergedData(
                original: customer.customData,
                edited: edited,
                editableKeys: Set(fields.map(\.key))
            )
            do {
                let shopID = try appState.requireShopID()
                let updated = try await CustomerService.updateCustomData(shopID: shopID, customerID: customer.id, data: data)
                onSaved(updated)
                toasts.show("Details saved")
                dismiss()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}
