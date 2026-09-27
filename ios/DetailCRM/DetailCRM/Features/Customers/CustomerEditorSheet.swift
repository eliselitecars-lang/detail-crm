//
//  CustomerEditorSheet.swift
//  DetailCRM
//
//  Add / edit a customer (managers and above; RLS enforces). Phone numbers
//  are normalized to E.164 with DetailCore's PhoneNumber, emails checked
//  with the same rule as the database. Staff can record an opt-out but can
//  never clear one — only the customer can (START / resubscribe).
//

import SwiftUI
import DetailCore

struct CustomerEditorSheet: View {
    enum Mode {
        case create
        case edit(Customer)
    }

    let mode: Mode
    let suggestions: [String]
    let onSaved: (Customer) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomerDraft
    /// The draft as the sheet opened (including a prefilled phone), so an
    /// untouched sheet can still be swiped away.
    @State private var initialDraft: CustomerDraft
    @State private var showValidation = false
    @State private var formError: String?

    init(mode: Mode, suggestions: [String], prefillPhone: String? = nil, onSaved: @escaping (Customer) -> Void) {
        self.mode = mode
        self.suggestions = suggestions
        self.onSaved = onSaved
        var initial: CustomerDraft
        switch mode {
        case .create:
            initial = CustomerDraft()
            if let prefillPhone {
                initial.phone = PhoneNumber.format(prefillPhone)
            }
        case .edit(let customer):
            initial = CustomerDraft(customer: customer)
        }
        _draft = State(initialValue: initial)
        _initialDraft = State(initialValue: initial)
    }

    private var existing: Customer? {
        if case .edit(let customer) = mode { return customer }
        return nil
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                AnyView(CustomerEditorNameSection(draft: $draft, showValidation: showValidation))
                AnyView(CustomerEditorContactSection(draft: $draft, showValidation: showValidation))
                AnyView(CustomerEditorAddressSection(draft: $draft))
                AnyView(CustomerEditorTagsSection(draft: $draft, suggestions: suggestions))
                AnyView(CustomerEditorPreferencesSection(draft: $draft, existing: existing, clock: appState.clock))
                AnyView(CustomerEditorNotesSection(draft: $draft))
                VStack(spacing: Theme.Spacing.sm) {
                    if let formError {
                        InlineMessage(text: formError, kind: .error)
                    }
                    AsyncButton(existing == nil ? "Add customer" : "Save changes") {
                        await save()
                    }
                }
            }
            .navigationTitle(existing == nil ? "New customer" : "Edit customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(draft != initialDraft)
    }

    private func save() async {
        showValidation = true
        if let problem = draft.validationError {
            formError = problem
            return
        }
        formError = nil
        do {
            let shopID = try appState.requireShopID()
            let saved: Customer
            if let existing {
                saved = try await CustomerService.update(shopID: shopID, customerID: existing.id, draft: draft)
            } else {
                saved = try await CustomerService.create(shopID: shopID, draft: draft)
            }
            onSaved(saved)
            dismiss()
        } catch {
            formError = ErrorText.message(for: error)
        }
    }
}

// MARK: - Sections

private struct CustomerEditorNameSection: View {
    @Binding var draft: CustomerDraft
    let showValidation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Name")
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ThemedTextField(label: "First name", placeholder: "First", text: $draft.firstName, kind: .name)
                ThemedTextField(label: "Last name", placeholder: "Last", text: $draft.lastName, kind: .name)
            }
            ThemedTextField(
                label: "Company",
                placeholder: "Optional",
                text: $draft.company,
                kind: .name,
                error: showValidation ? draft.nameError : nil
            )
            FormRow("Type") {
                Picker("Type", selection: $draft.lifecycle) {
                    ForEach(Customer.Lifecycle.allCases) { lifecycle in
                        Text(lifecycle.displayName).tag(lifecycle)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct CustomerEditorContactSection: View {
    @Binding var draft: CustomerDraft
    let showValidation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Contact")
            ThemedTextField(
                label: "Mobile phone",
                placeholder: "(205) 555-0123",
                text: $draft.phone,
                kind: .phone,
                hint: "US numbers need no country code; add + for others.",
                error: showValidation ? draft.phoneError : nil
            )
            ThemedTextField(
                label: "Email",
                placeholder: "name@example.com",
                text: $draft.email,
                kind: .email,
                error: showValidation ? draft.emailError : nil
            )
            FormRow("How they found you") {
                Picker("Source", selection: $draft.source) {
                    ForEach(Customer.Source.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.glacier)
            }
        }
    }
}

private struct CustomerEditorAddressSection: View {
    @Binding var draft: CustomerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Address")
            ThemedTextField(label: "Street", placeholder: "123 Main St", text: $draft.addressLine1)
            ThemedTextField(label: "Apt, suite, unit", placeholder: "Optional", text: $draft.addressLine2)
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ThemedTextField(label: "City", placeholder: "City", text: $draft.city, kind: .name)
                ThemedTextField(label: "State", placeholder: "State", text: $draft.region, kind: .name)
                    .frame(maxWidth: 120)
            }
            ThemedTextField(label: "ZIP / postal code", placeholder: "35203", text: $draft.postalCode, kind: .number)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }
}

private struct CustomerEditorTagsSection: View {
    @Binding var draft: CustomerDraft
    let suggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Tags")
            CustomerTagEditor(tags: $draft.tags, suggestions: suggestions)
        }
    }
}

private struct CustomerEditorPreferencesSection: View {
    @Binding var draft: CustomerDraft
    let existing: Customer?
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Messages")
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Toggle("Texts about appointments and offers", isOn: $draft.smsOptIn)
                Toggle("Emails about appointments and offers", isOn: $draft.emailOptIn)
                smsOptOutRow
                emailOptOutRow
            }
            .font(Theme.Typography.subheadline)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.glacier)
            .cardStyle(padding: Theme.Spacing.md)
        }
    }

    @ViewBuilder
    private var smsOptOutRow: some View {
        if let optedOut = existing?.smsOptedOutAt {
            InlineMessage(
                text: "Opted out of texts on \(CustomersFormatting.dayText(optedOut, clock: clock)). Only the customer can turn texts back on by replying START.",
                kind: .info
            )
        } else if existing != nil {
            Toggle("Customer asked us to stop texting", isOn: $draft.recordSmsOptOut)
            if draft.recordSmsOptOut {
                InlineMessage(text: "No texts will be sent to this customer. This can't be undone from the app.", kind: .info)
            }
        }
    }

    @ViewBuilder
    private var emailOptOutRow: some View {
        if let optedOut = existing?.emailOptedOutAt {
            InlineMessage(
                text: "Unsubscribed from email on \(CustomersFormatting.dayText(optedOut, clock: clock)).",
                kind: .info
            )
        } else if existing != nil {
            Toggle("Customer asked us to stop emailing", isOn: $draft.recordEmailOptOut)
        }
    }
}

private struct CustomerEditorNotesSection: View {
    @Binding var draft: CustomerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Notes")
            TextField("Gate code, preferences, anything the team should know", text: $draft.notes, axis: .vertical)
                .lineLimit(3...10)
                .padding(.vertical, Theme.Spacing.sm)
                .inputFieldStyle()
        }
    }
}
