//
//  MoneyTapToPayEducationView.swift
//  DetailCRM
//
//  How to take a Tap to Pay on iPhone payment (P-6), shown before the first
//  one on this iPhone and any time from "How Tap to Pay works". On iOS 18
//  and later it also opens Apple's own Tap to Pay guide
//  (ProximityReaderDiscovery), which Apple keeps up to date.
//

import SwiftUI
import UIKit
#if canImport(ProximityReader)
import ProximityReader
#endif

struct MoneyTapToPayEducationView: View {
    /// Called when the person is done reading (also marks it as seen).
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var guideError: String?

    /// Shown before the first Tap to Pay payment on this iPhone.
    static let seenKey = "money.tapToPay.educationSeen.v1"

    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.glacier)
                        .accessibilityHidden(true)
                    Text("Tap to Pay on iPhone")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Take contactless cards, Apple Pay and other digital wallets right on this iPhone — no extra hardware.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Text("\(index + 1)")
                                .font(Theme.Typography.captionEmphasis)
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.glacierSolid))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(step.title)
                                    .font(Theme.Typography.bodyEmphasis)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(step.detail)
                                    .font(Theme.Typography.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .cardStyle()
                if Self.systemGuideAvailable {
                    AsyncButton(style: .themeSecondary) {
                        await showSystemGuide()
                    } label: {
                        Label("Open Apple's Tap to Pay guide", systemImage: "book")
                    }
                }
                if let guideError {
                    InlineMessage(text: guideError, kind: .info)
                }
                Button("Got it") {
                    Self.markSeen()
                    dismiss()
                    onContinue()
                }
                .buttonStyle(.themePrimary)
            }
            .navigationTitle("How Tap to Pay works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    struct Step {
        let title: String
        let detail: String
    }

    static let steps: [Step] = [
        Step(
            title: "Enter the amount, then tap Tap to Pay",
            detail: "Check the amount and tip with the customer first. The payment screen shows the total."
        ),
        Step(
            title: "Hand the iPhone over, or hold it out",
            detail: "The customer holds their card, phone or watch flat against the top of your iPhone, near the camera, until a check mark appears."
        ),
        Step(
            title: "Some cards ask for a PIN",
            detail: "When the screen asks for it, the customer enters their PIN on your iPhone. You won't see it."
        ),
        Step(
            title: "Done",
            detail: "The payment shows on the invoice as soon as Stripe confirms it."
        ),
    ]

    /// Apple's guide exists on iOS 18 and later (where ProximityReader is
    /// available in the SDK).
    static var systemGuideAvailable: Bool {
        #if canImport(ProximityReader)
        if #available(iOS 18.0, *) {
            return true
        }
        #endif
        return false
    }

    private func showSystemGuide() async {
        guideError = nil
        #if canImport(ProximityReader)
        if #available(iOS 18.0, *) {
            guard let presenter = Self.topViewController() else {
                guideError = "Apple's guide couldn't be opened right now."
                return
            }
            do {
                let discovery = ProximityReaderDiscovery()
                let content = try await discovery.content(for: .payment(.howToTap))
                try await discovery.presentContent(content, from: presenter)
            } catch {
                guideError = "Apple's guide isn't available right now. The steps above cover the same."
            }
        }
        #endif
    }

    /// The view controller on top, to present Apple's guide from.
    @MainActor
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
