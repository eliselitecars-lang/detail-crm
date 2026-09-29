//
//  CreateShopView.swift
//  DetailCRM
//
//  Three-step wizard for a new shop: (1) name + booking address (slug),
//  (2) time zone + where the work happens, (3) contact phone. Calls
//  `create_shop`; the caller becomes the owner and the new shop becomes
//  active. Every rule is re-checked server-side.
//

import SwiftUI
import DetailCore

/// Form state shared by the wizard steps.
struct CreateShopDraft: Equatable {
    var name = ""
    var slug = ""
    /// True once the owner edits the slug by hand; stops auto-suggesting.
    var slugEdited = false
    var timezone = TimeZone.current.identifier
    var businessType: BusinessType = .fixed
    var phone = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var nameProblem: String? {
        if trimmedName.isEmpty { return "Enter your shop's name." }
        if trimmedName.count > 120 { return "Keep the name under 120 characters." }
        return nil
    }

    var slugProblem: String? {
        Validation.slugProblem(slug).map(\.message)
    }

    var phoneProblem: String? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return PhoneNumber.isValid(trimmed) ? nil : "Enter a valid phone number, e.g. (205) 555-0100."
    }

    var normalizedPhone: String? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : PhoneNumber.normalize(trimmed)
    }
}

enum CreateShopStep: Int, CaseIterable {
    case basics
    case location
    case contact

    var title: String {
        switch self {
        case .basics: return "Name your shop"
        case .location: return "Where you work"
        case .contact: return "How customers reach you"
        }
    }
}

struct CreateShopView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CreateShopDraft()
    @State private var step: CreateShopStep = .basics
    @State private var showErrors = false
    @State private var errorMessage: String?

    var body: some View {
        FormScreen {
            StepProgress(current: step.rawValue, total: CreateShopStep.allCases.count)
            Text(step.title)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.textPrimary)
            stepContent
            if let errorMessage {
                InlineMessage(text: errorMessage, kind: .error)
            }
            navigationButtons
        }
        .navigationTitle("New shop")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft.name) { _, newName in
            if !draft.slugEdited {
                draft.slug = Validation.suggestedSlug(from: newName)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .basics:
            ShopBasicsStep(draft: $draft, showErrors: showErrors)
        case .location:
            ShopLocationStep(draft: $draft)
        case .contact:
            ShopContactStep(draft: $draft, showErrors: showErrors)
        }
    }

    private var navigationButtons: some View {
        VStack(spacing: Theme.Spacing.md) {
            if step == .contact {
                AsyncButton("Create shop") {
                    await create()
                }
            } else {
                Button("Continue") {
                    advance()
                }
                .buttonStyle(.themePrimary)
            }
            if step != .basics {
                Button("Back") {
                    showErrors = false
                    errorMessage = nil
                    if let previous = CreateShopStep(rawValue: step.rawValue - 1) {
                        step = previous
                    }
                }
                .buttonStyle(.themePlain)
            }
        }
    }

    private func advance() {
        showErrors = true
        errorMessage = nil
        switch step {
        case .basics:
            guard draft.nameProblem == nil, draft.slugProblem == nil else { return }
        case .location:
            guard TimeZone(identifier: draft.timezone) != nil else {
                errorMessage = "Choose a time zone."
                return
            }
        case .contact:
            return
        }
        showErrors = false
        if let next = CreateShopStep(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    private func create() async {
        showErrors = true
        errorMessage = nil
        guard draft.phoneProblem == nil else { return }
        guard draft.nameProblem == nil, draft.slugProblem == nil else {
            step = .basics
            return
        }
        let shop: Shop
        do {
            shop = try await ShopService.createShop(ShopService.NewShop(
                name: draft.trimmedName,
                slug: draft.slug,
                timezone: draft.timezone,
                businessType: draft.businessType,
                phone: draft.normalizedPhone,
                email: nil
            ))
        } catch {
            let message = ErrorText.message(for: error)
            errorMessage = message
            // Slug problems (taken/reserved) are fixed on the first step.
            if message.lowercased().contains("slug") {
                step = .basics
            }
            return
        }
        do {
            // Activating the new shop swaps the root to the main tabs.
            try await appState.activateShop(shop.id)
            toasts.show("\(shop.name) is ready.")
        } catch {
            // The shop exists; only opening it failed. Go back to the list
            // (pull to refresh shows it) instead of offering to create it again.
            toasts.show("\(shop.name) was created. Pull down to refresh your shops and open it.",
                        style: .info, duration: .seconds(6))
            dismiss()
        }
    }
}

// MARK: - Steps

private struct ShopBasicsStep: View {
    @Binding var draft: CreateShopDraft
    let showErrors: Bool

    private var bookingHint: String {
        let path = draft.slug.isEmpty ? "your-shop" : draft.slug
        return "Lowercase letters, numbers and hyphens. Customers book online at /book/" + path + "."
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ThemedTextField(
                label: "Shop name",
                placeholder: "e.g. Summit Auto Spa",
                text: $draft.name,
                kind: .plain,
                error: showErrors ? draft.nameProblem : nil
            )
            FormRow(
                "Booking page address",
                hint: bookingHint,
                error: showErrors ? draft.slugProblem : nil
            ) {
                TextField("your-shop", text: Binding(
                    get: { draft.slug },
                    set: { newValue in
                        draft.slug = newValue.lowercased()
                        draft.slugEdited = true
                    }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .inputFieldStyle()
            }
        }
    }
}

private struct ShopLocationStep: View {
    @Binding var draft: CreateShopDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            FormRow("Time zone", hint: "Your calendar, reminders and reports use this time zone.") {
                NavigationLink {
                    TimeZonePickerView(selection: $draft.timezone)
                } label: {
                    HStack {
                        Text(TimeZonePickerView.displayName(for: draft.timezone))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .inputFieldStyle()
                }
                .buttonStyle(.plain)
            }
            FormRow("Where do you do the work?") {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(BusinessType.allCases) { type in
                        BusinessTypeOption(type: type, isSelected: draft.businessType == type) {
                            draft.businessType = type
                        }
                    }
                }
            }
        }
    }
}

private struct BusinessTypeOption: View {
    let type: BusinessType
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: type.systemImage)
                    .frame(width: Theme.Size.rowIcon)
                    .foregroundStyle(isSelected ? Theme.glacierInk : Theme.textSecondary)
                Text(type.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.glacierInk : Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.glacier.opacity(0.08) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? Theme.glacier : Theme.border, lineWidth: Theme.Size.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ShopContactStep: View {
    @Binding var draft: CreateShopDraft
    let showErrors: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ThemedTextField(
                label: "Shop phone (optional)",
                placeholder: "(205) 555-0100",
                text: $draft.phone,
                kind: .phone,
                hint: "Shown on your booking page, quotes and invoices.",
                error: showErrors ? draft.phoneProblem : nil
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InfoRow(label: "Name", value: draft.trimmedName)
                InfoRow(label: "Booking address", value: draft.slug)
                InfoRow(label: "Time zone", value: TimeZonePickerView.displayName(for: draft.timezone))
                InfoRow(label: "Work location", value: draft.businessType.displayName)
            }
            .cardStyle()
            Text("You can add your address, logo, taxes, services and hours next in Settings.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Step 2 of 3" with a segmented progress bar.
struct StepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Step \(current + 1) of \(total)")
                .font(Theme.Typography.captionEmphasis)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Theme.glacier : Theme.border)
                        .frame(height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}
