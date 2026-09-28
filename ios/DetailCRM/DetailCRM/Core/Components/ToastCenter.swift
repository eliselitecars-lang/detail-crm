//
//  ToastCenter.swift
//  DetailCRM
//
//  App-wide transient banners ("Saved", "Couldn't refresh"). One
//  ToastCenter is injected at the root; any screen shows a toast with
//  `toasts.show(...)` / `toasts.showError(error)`.
//
//  The banner view is always in the hierarchy and animates opacity/offset
//  (never inserted with `if`), so there is no insert-at-final-value glitch.
//
//  VoiceOver: every toast is also posted as an accessibility announcement
//  (errors start with "Error:"), queued behind whatever VoiceOver is saying
//  and sent a moment after the toast so a sheet closing at the same time
//  doesn't cut it off. While VoiceOver runs the banner stays longer, so it
//  can still be reached with a swipe (DetailCore `ToastSpeech`).
//

import SwiftUI
import UIKit
import Observation
import DetailCore

struct Toast: Equatable, Identifiable {
    enum Style: Equatable {
        case success
        case info
        case error
    }

    let id = UUID()
    let message: String
    let style: Style
}

@Observable
@MainActor
final class ToastCenter {
    /// The toast on screen, or nil when hidden.
    private(set) var current: Toast?
    /// The last toast shown — kept while the banner fades out.
    private(set) var lastShown: Toast?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .success, duration: Duration = .seconds(3)) {
        let toast = Toast(message: message, style: style)
        lastShown = toast
        current = toast
        let visible = ToastSpeech.visibleDuration(
            requested: duration,
            isError: style == .error,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning
        )
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: visible)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: toast.id)
        }
        announce(toast)
    }

    /// Speaks the toast with VoiceOver (a newer toast replaces one not yet
    /// announced).
    private func announce(_ toast: Toast) {
        announceTask?.cancel()
        let text = ToastSpeech.announcement(message: toast.message, isError: toast.style == .error)
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: ToastSpeech.announcementDelay)
            guard !Task.isCancelled, self?.lastShown?.id == toast.id else { return }
            let announcement = NSAttributedString(
                string: text,
                attributes: [.accessibilitySpeechQueueAnnouncement: true]
            )
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    func showError(_ error: Error) {
        show(ErrorText.message(for: error), style: .error, duration: .seconds(5))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func dismiss(id: UUID) {
        if current?.id == id { current = nil }
    }
}

private struct ToastBanner: View {
    let toast: Toast?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(toneColor)
                .accessibilityHidden(true)
            Text(toast?.message ?? " ")
                .font(Theme.Typography.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surfaceElevated)
                .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(toneColor.opacity(0.45), lineWidth: Theme.Size.hairline)
        )
        .padding(.horizontal, Theme.Spacing.gutter)
    }

    private var icon: String {
        switch toast?.style ?? .info {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private var toneColor: Color {
        switch toast?.style ?? .info {
        case .success: return Theme.successInk
        case .info: return Theme.glacier
        case .error: return Theme.dangerInk
        }
    }
}

private struct ToastHostModifier: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        let visible = center.current != nil
        return content.overlay(alignment: .top) {
            ToastBanner(toast: center.current ?? center.lastShown) {
                center.dismiss()
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -16)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(Theme.Motion.standard, value: center.current?.id)
            .padding(.top, Theme.Spacing.xs)
        }
    }
}

extension View {
    /// Hosts toasts from `center` over this view (applied once at the root).
    func toastHost(_ center: ToastCenter) -> some View {
        modifier(ToastHostModifier(center: center))
    }
}
