//
//  AdaptiveButtonRow.swift
//  DetailCRM
//
//  Side-by-side action buttons that stack at accessibility text sizes.
//

import SwiftUI

/// Lays action buttons out in a row, and in a column at accessibility text
/// sizes (AX1–AX5) so each button keeps the full width for its label
/// instead of truncating it. Use it wherever two or more theme buttons sit
/// next to each other (`scripts/swift_sanity.py` flags a bare `HStack`
/// holding them).
///
/// `AnyLayout` keeps the buttons' identity when the text size changes, so
/// focus and in-flight state survive the switch.
struct AdaptiveButtonRow<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(spacing: CGFloat = Theme.Spacing.sm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout {
            content
        }
    }
}
