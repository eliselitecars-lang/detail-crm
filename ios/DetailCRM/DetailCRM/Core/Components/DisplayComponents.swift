//
//  DisplayComponents.swift
//  DetailCRM
//
//  Small read-only building blocks: money, status badges, avatars and
//  section headers.
//

import SwiftUI
import DetailCore

// MARK: - Money

/// Formats integer cents in the shop currency. Amber is used only when the
/// amount needs attention (`emphasis: .attention`, e.g. a balance due).
struct MoneyText: View {
    enum Size {
        case small
        case regular
        case large
    }

    enum Emphasis {
        case normal
        case secondary
        case attention
    }

    let cents: Int
    var currencyCode: String = "usd"
    var size: Size = .regular
    var emphasis: Emphasis = .normal

    var body: some View {
        Text(Money.format(cents: cents, currencyCode: currencyCode))
            .font(amountFont)
            .foregroundStyle(amountColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(Money.format(cents: cents, currencyCode: currencyCode))
    }

    private var amountFont: Font {
        switch size {
        case .small: return Theme.Typography.moneySmall
        case .regular: return Theme.Typography.money
        case .large: return Theme.Typography.moneyLarge
        }
    }

    private var amountColor: Color {
        switch emphasis {
        case .normal: return Theme.textPrimary
        case .secondary: return Theme.textSecondary
        case .attention: return Theme.amber
        }
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        Text(text)
            .font(Theme.Typography.captionEmphasis)
            .foregroundStyle(Theme.color(for: tone))
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs + 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.fill(for: tone))
            )
            .accessibilityLabel("Status: \(text)")
    }
}

extension StatusBadge {
    init(_ status: JobStatus) {
        self.init(text: status.displayName, tone: status.tone)
    }

    init(_ status: QuoteStatus) {
        self.init(text: status.displayName, tone: status.tone)
    }

    init(_ status: InvoiceStatus) {
        self.init(text: status.displayName, tone: status.tone)
    }

    init(_ status: PaymentStatus) {
        self.init(text: status.displayName, tone: status.tone)
    }

    init(_ status: MembershipStatus) {
        self.init(text: status.displayName, tone: status.tone)
    }

    init(_ role: ShopRole) {
        self.init(text: role.displayName, tone: role.isAdminOrAbove ? .info : .neutral)
    }
}

// MARK: - Avatar

/// Initials in a tinted circle (optionally a member's calendar color).
struct AvatarView: View {
    let name: String
    var size: CGFloat = Theme.Size.avatarMedium
    /// `#RRGGBB`, e.g. `shop_members.calendar_color`.
    var colorHex: String? = nil

    var body: some View {
        let avatarColor = colorHex.flatMap { Color(hexString: $0) } ?? Theme.glacier
        Text(Self.initials(from: name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(avatarColor)
            .frame(width: size, height: size)
            .background(Circle().fill(avatarColor.opacity(0.16)))
            .overlay(Circle().strokeBorder(avatarColor.opacity(0.35), lineWidth: Theme.Size.hairline))
            .accessibilityHidden(true)
    }

    /// Up to two initials from the first and last words ("Ana María Ruiz"
    /// -> "AR"); "?" when there is nothing usable.
    static func initials(from name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        guard let first = words.first?.first else { return "?" }
        if words.count > 1, let last = words.last?.first {
            return String(first).uppercased() + String(last).uppercased()
        }
        return String(first).uppercased()
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Theme.Typography.eyebrow)
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.glacier)
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

// MARK: - Key/value row

/// Label on the left, value on the right; used in detail cards.
struct InfoRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.md)
            Text(value)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
