//
//  AsyncButton.swift
//  DetailCRM
//
//  A button that runs async work, disables itself and shows a spinner
//  while running, and ignores repeat taps. Errors are the caller's job
//  (catch and show a toast / inline message).
//

import SwiftUI

struct AsyncButton<Label: View>: View {
    private let role: ButtonRole?
    private let style: ThemeButtonStyle
    private let action: () async -> Void
    private let label: Label

    @State private var isRunning = false

    init(
        role: ButtonRole? = nil,
        style: ThemeButtonStyle = .themePrimary,
        action: @escaping () async -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.style = style
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role) {
            guard !isRunning else { return }
            isRunning = true
            Task { @MainActor in
                await action()
                isRunning = false
            }
        } label: {
            ZStack {
                label.opacity(isRunning ? 0 : 1)
                ProgressView()
                    .tint(spinnerTint)
                    .opacity(isRunning ? 1 : 0)
            }
        }
        .buttonStyle(style)
        .disabled(isRunning)
        .accessibilityAddTraits(isRunning ? .updatesFrequently : [])
    }

    private var spinnerTint: Color {
        switch style.variant {
        case .primary, .destructive: return Theme.onAccent
        case .money: return Theme.onAmber
        case .secondary, .plain: return Theme.glacier
        }
    }
}

extension AsyncButton where Label == Text {
    init(
        _ title: String,
        role: ButtonRole? = nil,
        style: ThemeButtonStyle = .themePrimary,
        action: @escaping () async -> Void
    ) {
        self.init(role: role, style: style, action: action) {
            Text(title)
        }
    }
}
