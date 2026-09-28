//
//  StateViews.swift
//  DetailCRM
//
//  Loading / empty / error building blocks. Every data screen renders one
//  of these whenever it is not showing loaded content.
//

import SwiftUI

struct LoadingStateView: View {
    var label: String = "Loading…"

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.glacier)
            Text(label)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.glacier)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.themePrimaryCompact)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() async -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.dangerInk)
                .accessibilityHidden(true)
            Text("Something went wrong")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await retry()
                }
                .padding(.top, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }
}

/// Small inline validation/error message under a field or form.
struct InlineMessage: View {
    enum Kind {
        case error
        case info
        case success
    }

    let text: String
    var kind: Kind = .error

    var body: some View {
        Label {
            Text(text)
                .font(Theme.Typography.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: iconName)
        }
        .foregroundStyle(toneColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch kind {
        case .error: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var toneColor: Color {
        switch kind {
        case .error: return Theme.dangerInk
        case .info: return Theme.textSecondary
        case .success: return Theme.successInk
        }
    }
}
