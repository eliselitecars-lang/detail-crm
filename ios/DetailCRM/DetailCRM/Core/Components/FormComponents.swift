//
//  FormComponents.swift
//  DetailCRM
//
//  Input building blocks: search bar, labeled form rows, themed text fields.
//

import SwiftUI
import UIKit

// MARK: - Search bar

struct SearchBar: View {
    @Binding var text: String
    var prompt: String = "Search"
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { onSubmit?() }
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(isFocused ? Theme.glacier : Theme.border, lineWidth: Theme.Size.hairline)
        )
        .animation(Theme.Motion.quick, value: isFocused)
    }
}

// MARK: - Form row

/// A label above arbitrary input content, with optional hint or error.
struct FormRow<Content: View>: View {
    let label: String
    let hint: String?
    let error: String?
    let content: Content

    init(_ label: String, hint: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            Text(label)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content
            if let error {
                InlineMessage(text: error, kind: .error)
            } else if let hint {
                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Themed text field

/// Kinds of text input, each with the right keyboard/content settings.
enum ThemedFieldKind {
    case plain
    case name
    case email
    case phone
    case newPassword
    case password
    case money
    case number
    case url
}

/// A labeled, themed text field. Secure kinds use `SecureField`.
struct ThemedTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var kind: ThemedFieldKind = .plain
    var hint: String? = nil
    var error: String? = nil

    var body: some View {
        FormRow(label, hint: hint, error: error) {
            field
                .inputFieldStyle()
        }
    }

    @ViewBuilder
    private var field: some View {
        switch kind {
        case .password, .newPassword:
            SecureField(placeholder, text: $text)
                .textContentType(kind == .newPassword ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        default:
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled(kind != .plain)
        }
    }

    private var keyboard: UIKeyboardType {
        switch kind {
        case .email: return .emailAddress
        case .phone: return .phonePad
        case .money: return .decimalPad
        case .number: return .numberPad
        case .url: return .URL
        case .plain, .name, .password, .newPassword: return .default
        }
    }

    private var contentType: UITextContentType? {
        switch kind {
        case .name: return .name
        case .email: return .emailAddress
        case .phone: return .telephoneNumber
        case .url: return .URL
        case .password: return .password
        case .newPassword: return .newPassword
        case .plain, .money, .number: return nil
        }
    }

    private var capitalization: TextInputAutocapitalization {
        switch kind {
        case .name: return .words
        case .plain: return .sentences
        case .email, .phone, .password, .newPassword, .money, .number, .url: return .never
        }
    }
}

// MARK: - Form screen

/// Scrolling, width-limited container for form-style screens (auth,
/// onboarding, editors).
struct FormScreen<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                content
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
    }
}
