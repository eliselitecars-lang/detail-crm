//
//  JobComponents.swift
//  DetailCRM
//
//  Small building blocks shared by the job screens: the section card, a
//  compact per-section load-state renderer, icon buttons and formatting.
//

import SwiftUI
import DetailCore

// MARK: - Section card

/// A titled card used for every section of the job screen.
struct JobSectionCard<Content: View>: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
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
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                content
            }
            .cardStyle()
        }
    }
}

// MARK: - Compact load state

/// Loading / error-with-retry / content for one section of a screen that
/// is already showing other content (the full-screen `LoadStateView`
/// would be too large inside a card).
struct JobSectionStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let loadingLabel: String
    let retry: () async -> Void
    let content: (Value) -> Content

    init(
        _ state: LoadState<Value>,
        loadingLabel: String,
        retry: @escaping () async -> Void,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.loadingLabel = loadingLabel
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .tint(Theme.glacier)
                Text(loadingLabel)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await retry()
                }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

/// One-line empty state inside a section card.
struct JobEmptyLine: View {
    let text: String
    var systemImage: String = "tray"

    var body: some View {
        Label {
            Text(text)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// Round icon button (call, text, email, directions) with a required
/// accessibility label.
struct JobIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.glacier)
                .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
                .background(Circle().fill(Theme.glacier.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A plain row with a label/value pair for money lines inside cards.
struct JobMoneyRow: View {
    let label: String
    let cents: Int
    var currencyCode: String = "usd"
    var emphasis: MoneyText.Emphasis = .normal
    var isTotal: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(isTotal ? Theme.Typography.bodyEmphasis : Theme.Typography.subheadline)
                .foregroundStyle(isTotal ? Theme.textPrimary : Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.md)
            MoneyText(
                cents: cents,
                currencyCode: currencyCode,
                size: isTotal ? .regular : .small,
                emphasis: emphasis
            )
        }
        .accessibilityElement(children: .combine)
    }
}

/// A hairline divider using the theme border color.
struct JobDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: Theme.Size.hairline)
            .accessibilityHidden(true)
    }
}

// MARK: - Formatting

enum JobsFormatting {

    /// "2", "1.5" — quantities without trailing zeros.
    static func quantity(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    /// Parses a quantity typed by a person (> 0, at most 2 decimals).
    static func parseQuantity(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        guard value > 0, value < 100_000_000 else { return nil }
        let parts = cleaned.split(separator: ".")
        if parts.count == 2, parts[1].count > 2 { return nil }
        return value
    }

    /// "12.5%" from basis points.
    static func percent(bps: Int) -> String {
        let whole = bps / 100
        let fraction = bps % 100
        if fraction == 0 { return "\(whole)%" }
        let fractionText = fraction % 10 == 0 ? String(fraction / 10) : String(format: "%02d", fraction)
        return "\(whole).\(fractionText)%"
    }

    /// Parses "12.5" into basis points (0…10000).
    static func parsePercentBps(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let bps = NSDecimalNumber(decimal: rounded).intValue
        guard bps >= 0, bps <= 10_000 else { return nil }
        return bps
    }

    /// "Tue, Mar 10 · 9:00 – 11:30 AM" in the shop's time zone.
    static func scheduleText(start: Date?, end: Date?, clock: ShopClock) -> String {
        guard let start else { return "Not scheduled" }
        guard let end else { return clock.relativeDayText(start) + " · " + clock.timeText(start) }
        if clock.isSameDay(start, end) {
            return clock.relativeDayText(start) + " · " + clock.rangeText(from: start, to: end)
        }
        return clock.rangeText(from: start, to: end)
    }
}
