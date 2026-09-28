//
//  Theme.swift
//  DetailCRM
//
//  The ONLY place colors, type, spacing, radii, button styles and card
//  modifiers are defined. Screens use these tokens and never hard-code
//  colors or sizes. Every color adapts to light and dark mode.
//
//  Brand: "Glacier" blue for interaction/selection; "Amber" is reserved for
//  money and primary money actions only.
//

import SwiftUI
import UIKit
import DetailCore

enum Theme {

    // MARK: - Brand palette (fixed)

    // Fill colors: solid button fills, badge/banner tints, bars, dots and
    // calendar blocks. Amber, warning and success are too light to be read
    // as text in light mode (about 2:1 to 3.5:1 on white), so text and
    // icons use the matching `…Ink` token below; `scripts/swift_sanity.py`
    // rejects a fill color passed to `foregroundStyle`/`foregroundColor`.

    /// Glacier — interaction, selection, links, primary non-money actions.
    static let glacier = Color(light: 0x1F6FEB, dark: 0x4C8DF6)
    /// Amber — the primary money action fill (`.themeMoney`) and money tints.
    static let amber = Color(light: 0xE8A23A, dark: 0xF0B252)
    static let success = Color(light: 0x1F9D55, dark: 0x34B871)
    static let warning = Color(light: 0xD98A0B, dark: 0xF0A43A)
    static let danger = Color(light: 0xD93F3F, dark: 0xF06464)

    // MARK: - Tone text ("ink")

    // Readable text/icon versions of the fill colors (the web app's
    // `*-ink` tokens). Each meets WCAG AA 4.5:1 on background, surface,
    // surfaceMuted and on its own 14 % badge fill, in both modes.

    /// Money amounts that need attention (balances due, amounts owed).
    static let moneyInk = Color(light: 0x8A560E, dark: 0xF2BD6B)
    static let successInk = Color(light: 0x157240, dark: 0x5FD394)
    static let warningInk = Color(light: 0x8F5A05, dark: 0xF3BC5E)
    static let dangerInk = Color(light: 0xA82E2E, dark: 0xF28B8B)
    /// Informational tone text (Glacier itself is fine for links and
    /// buttons on surfaces but too light on its own badge fill).
    static let glacierInk = Color(light: 0x1553B8, dark: 0x7FB0FF)

    /// Brand tile gradient (app icon, launch mark) — same in both modes.
    static let brandGradient = LinearGradient(
        colors: [Color(light: 0x3D8BFF, dark: 0x3D8BFF), Color(light: 0x1552B8, dark: 0x1552B8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Text/icon color placed on a solid Glacier/success/danger fill.
    static let onAccent = Color.white
    /// Text/icon color placed on a solid Amber fill (dark ink for contrast).
    static let onAmber = Color(light: 0x0B1220, dark: 0x0B1220)
    /// Dark scrim behind white text over camera / video / photos (both modes).
    static let scrim = Color(light: 0x0B1220, dark: 0x000000)

    // MARK: - Surfaces

    /// Screen background ("canvas" in light, "ink" in dark).
    static let background = Color(light: 0xF6F8FB, dark: 0x0B1220)
    /// Cards and grouped rows.
    static let surface = Color(light: 0xFFFFFF, dark: 0x131C2E)
    /// Sheets, menus and floating banners.
    static let surfaceElevated = Color(light: 0xFFFFFF, dark: 0x1A2438)
    /// Inputs, chips, subtle fills.
    static let surfaceMuted = Color(light: 0xEEF2F7, dark: 0x1C2638)
    /// Hairline borders and dividers.
    static let border = Color(light: 0xE1E7EF, dark: 0x26324A)

    // MARK: - Text

    static let textPrimary = Color(light: 0x0B1220, dark: 0xEEF2F8)
    static let textSecondary = Color(light: 0x52607A, dark: 0x9AA6BD)
    static let textTertiary = Color(light: 0x8491A7, dark: 0x6B7892)

    // MARK: - Status tones

    /// Text/icon color for a status tone (the readable ink).
    static func color(for tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return textSecondary
        case .info: return glacierInk
        case .success: return successInk
        case .warning: return warningInk
        case .danger: return dangerInk
        case .money: return moneyInk
        }
    }

    /// Solid fill color for a status tone (bars, dots, blocks) — not text.
    static func accent(for tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return textSecondary
        case .info: return glacier
        case .success: return success
        case .warning: return warning
        case .danger: return danger
        case .money: return amber
        }
    }

    /// Soft background fill for a status tone (badges, banners), drawn
    /// behind `color(for:)` text.
    static func fill(for tone: StatusTone) -> Color {
        accent(for: tone).opacity(0.14)
    }

    // MARK: - Spacing (4-pt grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Standard horizontal screen gutter.
        static let gutter: CGFloat = 16
    }

    // MARK: - Radii

    enum Radius {
        /// Cards and grouped sections.
        static let card: CGFloat = 12
        /// Buttons, text fields, chips.
        static let control: CGFloat = 8
        /// Small badges.
        static let badge: CGFloat = 6
    }

    // MARK: - Sizes

    enum Size {
        /// Minimum tap target / button height.
        static let controlHeight: CGFloat = 48
        static let compactControlHeight: CGFloat = 36
        static let rowIcon: CGFloat = 28
        static let avatarSmall: CGFloat = 32
        static let avatarMedium: CGFloat = 44
        static let avatarLarge: CGFloat = 64
        static let hairline: CGFloat = 1
        /// Readable max width for forms on large phones.
        static let formMaxWidth: CGFloat = 560
    }

    // MARK: - Typography (SF Pro via system fonts; Dynamic Type aware)

    enum Typography {
        static let largeTitle = Font.system(.largeTitle).weight(.bold)
        static let title = Font.system(.title2).weight(.bold)
        static let sectionTitle = Font.system(.title3).weight(.semibold)
        static let headline = Font.system(.headline)
        static let body = Font.system(.body)
        static let bodyEmphasis = Font.system(.body).weight(.semibold)
        static let callout = Font.system(.callout)
        static let subheadline = Font.system(.subheadline)
        static let footnote = Font.system(.footnote)
        static let caption = Font.system(.caption)
        static let captionEmphasis = Font.system(.caption).weight(.semibold)
        /// Small glyphs inside dense calendar blocks.
        static let caption2 = Font.system(.caption2)
        /// Uppercase eyebrow labels above sections.
        static let eyebrow = Font.system(.caption2).weight(.semibold)
        static let button = Font.system(.body).weight(.semibold)
        static let buttonCompact = Font.system(.subheadline).weight(.semibold)
        /// Money amounts: tabular digits so columns line up.
        static let money = Font.system(.body).weight(.semibold).monospacedDigit()
        static let moneyLarge = Font.system(.title, design: .rounded).weight(.bold).monospacedDigit()
        static let moneySmall = Font.system(.footnote).weight(.medium).monospacedDigit()
    }

    // MARK: - Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: - UIKit chrome

    /// Tab and navigation bar appearance so every bar matches the theme
    /// without per-screen overrides. Called once at launch.
    static func configureChrome() {
        let background = UIColor(Theme.surface)
        let separator = UIColor(Theme.border)
        let secondary = UIColor(Theme.textSecondary)
        let glacier = UIColor(Theme.glacier)
        let primaryText = UIColor(Theme.textPrimary)

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = background
        tabBar.shadowColor = separator
        for item in [tabBar.stackedLayoutAppearance, tabBar.inlineLayoutAppearance, tabBar.compactInlineLayoutAppearance] {
            item.selected.iconColor = glacier
            item.selected.titleTextAttributes = [.foregroundColor: glacier]
            item.normal.iconColor = secondary
            item.normal.titleTextAttributes = [.foregroundColor: secondary]
        }
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = UIColor(Theme.background)
        navBar.shadowColor = .clear
        navBar.titleTextAttributes = [.foregroundColor: primaryText]
        navBar.largeTitleTextAttributes = [.foregroundColor: primaryText]
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
        UINavigationBar.appearance().compactAppearance = navBar
    }
}

// MARK: - Dynamic colors

extension Color {
    /// A color that resolves to `light` or `dark` (24-bit RGB hex) with the
    /// current interface style.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// A fixed color from a `#RRGGBB` string (e.g. a member's
    /// `calendar_color`). Returns nil for anything else.
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(uiColor: UIColor(hex: value))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Card & surface modifiers

private struct CardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
            )
    }
}

private struct ScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

private struct InputFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
            )
    }
}

extension View {
    /// Standard card: surface fill, 12-pt corners, hairline border.
    func cardStyle(padding: CGFloat = Theme.Spacing.lg) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// Theme background behind a screen (and behind List/Form content).
    func screenBackground() -> some View {
        modifier(ScreenBackgroundModifier())
    }

    /// Standard text-field chrome (muted fill, 8-pt corners, 48-pt height).
    func inputFieldStyle() -> some View {
        modifier(InputFieldModifier())
    }

    /// Row background for List/Form rows so they sit on the theme surface.
    func themedRow() -> some View {
        listRowBackground(Theme.surface)
    }
}

// MARK: - Button styles

/// Visual variants shared by all theme buttons.
enum ThemeButtonVariant {
    case primary
    case money
    case secondary
    case destructive
    case plain
}

/// Solid/outlined pill used by every theme button. Reads `isEnabled` from
/// the environment inside a View (not the style) so disabled state renders
/// reliably.
///
/// Labels stay on one line (shrinking slightly before truncating) at
/// standard text sizes; at accessibility sizes (AX1–AX5) they wrap onto as
/// many lines as they need, so a money or destructive action is never cut
/// off to "Complete an…". Put side-by-side buttons in `AdaptiveButtonRow`.
private struct ThemeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ThemeButtonVariant
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let wraps = dynamicTypeSize.isAccessibilitySize
        configuration.label
            .font(compact ? Theme.Typography.buttonCompact : Theme.Typography.button)
            .lineLimit(wraps ? nil : 1)
            .minimumScaleFactor(wraps ? 1 : 0.8)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, wraps ? Theme.Spacing.sm : 0)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? Theme.Spacing.md : Theme.Spacing.lg)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(minHeight: compact ? Theme.Size.compactControlHeight : Theme.Size.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(stroke, lineWidth: Theme.Size.hairline)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var foreground: Color {
        switch variant {
        case .primary, .destructive: return Theme.onAccent
        case .money: return Theme.onAmber
        case .secondary, .plain: return Theme.glacier
        }
    }

    private var fill: Color {
        switch variant {
        case .primary: return Theme.glacier
        case .money: return Theme.amber
        case .destructive: return Theme.danger
        case .secondary: return Theme.surface
        case .plain: return Color.clear
        }
    }

    private var stroke: Color {
        switch variant {
        case .secondary: return Theme.border
        case .primary, .money, .destructive, .plain: return Color.clear
        }
    }
}

struct ThemeButtonStyle: ButtonStyle {
    let variant: ThemeButtonVariant
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ThemeButtonBody(configuration: configuration, variant: variant, compact: compact)
    }
}

extension ButtonStyle where Self == ThemeButtonStyle {
    /// Glacier fill — primary non-money action.
    static var themePrimary: ThemeButtonStyle { ThemeButtonStyle(variant: .primary) }
    /// Amber fill — primary money action (collect, charge, send invoice).
    static var themeMoney: ThemeButtonStyle { ThemeButtonStyle(variant: .money) }
    /// Outlined — secondary action.
    static var themeSecondary: ThemeButtonStyle { ThemeButtonStyle(variant: .secondary) }
    /// Red fill — destructive confirmation.
    static var themeDestructive: ThemeButtonStyle { ThemeButtonStyle(variant: .destructive) }
    /// Text-only Glacier button.
    static var themePlain: ThemeButtonStyle { ThemeButtonStyle(variant: .plain) }
    /// Compact (hugging) variants for toolbars and inline actions.
    static var themePrimaryCompact: ThemeButtonStyle { ThemeButtonStyle(variant: .primary, compact: true) }
    static var themeSecondaryCompact: ThemeButtonStyle { ThemeButtonStyle(variant: .secondary, compact: true) }
    static var themeMoneyCompact: ThemeButtonStyle { ThemeButtonStyle(variant: .money, compact: true) }
}

/// Full-width tappable row with a pressed highlight (for custom lists).
struct ThemeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.surfaceMuted : Color.clear)
    }
}

extension ButtonStyle where Self == ThemeRowButtonStyle {
    static var themeRow: ThemeRowButtonStyle { ThemeRowButtonStyle() }
}
