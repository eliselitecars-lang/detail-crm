//
//  JobsCustomDataSection.swift
//  DetailCRM
//
//  The shop's job fields and booking questions (P-9) on the job: answers
//  from the online booking and anything staff fill in. Everyone on the job
//  reads them; managers and up edit them. The server validates each value
//  against its field. A field archived after it was answered, or a booking
//  question for the other location type, still shows its answer
//  (read-only). "Required" binds online bookings only, so staff can save
//  with required booking questions left empty.
//

import SwiftUI
import Supabase
import DetailCore

struct JobsCustomDataSection: View {
    let model: JobDetailModel
    let canEdit: Bool

    @State private var editing = false

    var body: some View {
        let fields = model.customFields.value ?? []
        let data = model.job?.customData
        let location = model.job?.locationType
        let editable = fields.filter { $0.isEditable(onJobAt: location) }
        let shown = fields.filter { $0.isEditable(onJobAt: location) || $0.value(in: data) != nil }
        if !shown.isEmpty || model.customFields.errorMessage != nil {
            JobSectionCard(
                "Details",
                actionTitle: canEdit && !editable.isEmpty ? "Edit" : nil,
                action: canEdit ? startEditing : nil
            ) {
                JobSectionStateView(model.customFields, loadingLabel: "Loading details…", retry: { await model.loadCustomFields() }) { _ in
                    rows(shown, data: data)
                }
            }
            .sheet(isPresented: $editing) {
                JobsCustomDataSection.Editor(model: model, fields: editable)
            }
        }
    }

    private func startEditing() {
        editing = true
    }

    private func rows(_ fields: [JobsCustomField], data: [String: AnyJSON]?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(field.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(field.value(in: data)?.displayText ?? "—")
                        .font(Theme.Typography.body)
                        .foregroundStyle(field.value(in: data) == nil ? Theme.textTertiary : Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension JobsCustomDataSection {
    /// Manager editor: one input per live field, by type.
    struct Editor: View {
        let model: JobDetailModel
        let fields: [JobsCustomField]

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
                        FormRow(field.label, hint: hint(for: field)) {
                            input(for: field)
                        }
                    }
                }
                .navigationTitle("Job details")
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

        private func hint(for field: JobsCustomField) -> String? {
            let parts = [field.helpText?.trimmedNonEmpty, field.requiredOnlineHint].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
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
            let data = model.job?.customData
            for field in fields {
                guard let value = field.value(in: data) else { continue }
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
                } else if let number = Double(text.replacingOccurrences(of: ",", with: ".")) {
                    edited[field.key] = .number(number)
                } else {
                    errorMessage = "\(field.label) must be a number."
                    return
                }
            }
            do {
                try await model.saveCustomData(edited)
                toasts.show("Details saved")
                dismiss()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}
