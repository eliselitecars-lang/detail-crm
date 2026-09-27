//
//  ConfirmDialog.swift
//  DetailCRM
//
//  One pattern for "Are you sure?" prompts. A screen keeps
//  `@State var confirmation: ConfirmationRequest?`, sets it from a button,
//  and attaches `.confirmation($confirmation)`.
//

import SwiftUI

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String?
    let confirmTitle: String
    let isDestructive: Bool
    let action: () async -> Void

    init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        isDestructive: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.action = action
    }
}

private struct ConfirmationModifier: ViewModifier {
    @Binding var request: ConfirmationRequest?

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: Binding(
                get: { request != nil },
                set: { presented in
                    if !presented { request = nil }
                }
            ),
            presenting: request
        ) { pending in
            Button(pending.confirmTitle, role: pending.isDestructive ? .destructive : nil) {
                let action = pending.action
                request = nil
                Task { @MainActor in
                    await action()
                }
            }
            Button("Cancel", role: .cancel) {
                request = nil
            }
        } message: { pending in
            if let message = pending.message {
                Text(message)
            }
        }
    }
}

extension View {
    /// Presents `request` as an alert with Confirm / Cancel.
    func confirmation(_ request: Binding<ConfirmationRequest?>) -> some View {
        modifier(ConfirmationModifier(request: request))
    }
}
