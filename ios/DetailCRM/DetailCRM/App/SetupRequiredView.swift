//
//  SetupRequiredView.swift
//  DetailCRM
//
//  Shown when Config.plist still has placeholder values, so a fresh clone
//  launches with instructions instead of crashing.
//

import SwiftUI

struct SetupRequiredView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(spacing: Theme.Spacing.md) {
                    BrandMark(size: 48)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Detail CRM")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Setup required")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, Theme.Spacing.xl)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("This build isn't connected to a backend yet.")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add your Supabase project URL and anon key to Config.plist (Supabase dashboard > Project Settings > API), then rebuild.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(AppConfig.missingKeys, id: \.self) { key in
                            Label(key, systemImage: "key")
                                .font(Theme.Typography.footnote.monospaced())
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                .cardStyle()
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
    }
}
