//
//  CustomersComponents.swift
//  DetailCRM
//
//  Small building blocks shared by the Customers screens: tag chips, the
//  tag editor, a titled section card and round contact action buttons.
//

import SwiftUI
import DetailCore

// MARK: - Tag chip

struct CustomerTagChip: View {
    let text: String
    var isSelected: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(text)
                .font(Theme.Typography.captionEmphasis)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.caption.weight(.bold))
                        .frame(minWidth: 20, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(text)")
            }
        }
        .foregroundStyle(isSelected ? Theme.onAccent : Theme.glacierInk)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(isSelected ? Theme.glacierSolid : Theme.fill(for: .info))
        )
    }
}

/// A horizontally scrolling row of read-only tags.
struct CustomerTagRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(tags, id: \.self) { tag in
                    CustomerTagChip(text: tag)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
    }
}

// MARK: - Tag editor

/// Edits a list of tags: current tags as removable chips, a field to add a
/// new one, and suggestions from tags already used in the shop.
struct CustomerTagEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]

    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if tags.isEmpty {
                Text("No tags yet.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(tags, id: \.self) { tag in
                            CustomerTagChip(text: tag, isSelected: true) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                    }
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Add a tag (e.g. VIP, fleet)", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { add(newTag) }
                    .inputFieldStyle()
                Button {
                    add(newTag)
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 20)
                }
                .buttonStyle(.themeSecondaryCompact)
                .disabled(newTag.trimmedNonEmpty == nil)
                .accessibilityLabel("Add tag")
            }
            if !filteredSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(filteredSuggestions, id: \.self) { tag in
                            Button {
                                add(tag)
                            } label: {
                                CustomerTagChip(text: "+ " + tag)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add tag \(tag)")
                        }
                    }
                }
            }
        }
    }

    private var filteredSuggestions: [String] {
        let existing = Set(tags.map { $0.lowercased() })
        let typed = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions
            .filter { !existing.contains($0.lowercased()) }
            .filter { typed.isEmpty || $0.lowercased().contains(typed) }
            .prefix(12)
            .map { $0 }
    }

    private func add(_ raw: String) {
        guard let tag = raw.trimmedNonEmpty else { return }
        let clipped = String(tag.prefix(40))
        if !tags.contains(where: { $0.lowercased() == clipped.lowercased() }) {
            tags.append(clipped)
        }
        newTag = ""
    }
}

// MARK: - Section card

/// A titled card used for each section of the customer screen.
struct CustomersSectionCard<Content: View>: View {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
    let content: Content

    init(
        _ title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title, actionTitle: actionTitle, action: action)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
    }
}

/// A row inside a section card that stands for "loading", "error" or
/// "nothing here" for one section.
struct CustomersSectionStatusRow: View {
    enum Kind {
        case loading
        case empty(String)
        case failed(String)
    }

    let kind: Kind
    var retry: (() async -> Void)? = nil

    var body: some View {
        switch kind {
        case .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .tint(Theme.glacier)
                Text("Loading…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
        case .empty(let text):
            Text(text)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, Theme.Spacing.xs)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                if let retry {
                    AsyncButton("Try again", style: .themeSecondaryCompact) {
                        await retry()
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }
}

/// Hairline between rows inside a section card.
struct CustomersRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: Theme.Size.hairline)
            .padding(.vertical, Theme.Spacing.xs)
    }
}

// MARK: - Contact action button

/// Round icon + caption button (Call / Text / Email / Directions).
struct CustomerContactButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(Theme.Typography.headline)
                    .frame(width: Theme.Size.avatarMedium, height: Theme.Size.avatarMedium)
                    .background(Circle().fill(Theme.fill(for: .info)))
                Text(title)
                    .font(Theme.Typography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.glacierInk)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

// MARK: - Formatting helpers

enum CustomersFormatting {

    /// "Job #1001".
    static func jobTitle(_ number: Int) -> String { "Job #\(number)" }
    static func quoteTitle(_ number: Int) -> String { "Quote #\(number)" }
    static func invoiceTitle(_ number: Int) -> String { "Invoice #\(number)" }

    /// "Customer since Mar 2024".
    static func sinceText(_ date: Date, clock: ShopClock) -> String {
        let formatter = DateFormatter()
        formatter.locale = clock.locale
        formatter.timeZone = clock.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        return formatter.string(from: date)
    }

    /// "Mar 10, 2026" in the shop's time zone.
    static func dayText(_ date: Date, clock: ShopClock) -> String {
        let formatter = DateFormatter()
        formatter.locale = clock.locale
        formatter.timeZone = clock.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
