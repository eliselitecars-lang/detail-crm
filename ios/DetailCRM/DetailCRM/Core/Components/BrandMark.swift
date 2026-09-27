//
//  BrandMark.swift
//  DetailCRM
//
//  The Detail CRM mark: a droplet with a sparkle on a Glacier gradient
//  tile — the same design as the app icon, drawn with SF Symbols.
//

import SwiftUI

struct BrandMark: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Theme.brandGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "drop.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Theme.onAccent.opacity(0.95))
                    .padding(size * 0.14)
            }
            .accessibilityHidden(true)
    }
}
