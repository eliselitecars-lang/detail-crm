//
//  RootView.swift
//  DetailCRM
//
//  Switches between the session phases owned by AppState. The main tabs
//  are keyed by shop id, so switching shops rebuilds every screen and no
//  state from the previous shop can leak into the next.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .animation(Theme.Motion.quick, value: phaseKey)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.phase {
        case .launching:
            LaunchView()
                .transition(.opacity)
        case .signedOut:
            AuthFlowView()
                .transition(.opacity)
        case .needsShop:
            ShopPickerView()
                .transition(.opacity)
        case .ready:
            MainTabView()
                .id(appState.shop?.id)
                .transition(.opacity)
        case .failed(let message):
            BootstrapErrorView(message: message)
                .transition(.opacity)
        }
    }

    /// Animation key for phase changes (the failure message is ignored).
    private var phaseKey: Int {
        switch appState.phase {
        case .launching: return 0
        case .signedOut: return 1
        case .needsShop: return 2
        case .ready: return 3
        case .failed: return 4
        }
    }
}

/// Brand splash while the stored session and memberships load.
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            BrandMark(size: 72)
            Text("Detail CRM")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
            ProgressView()
                .tint(Theme.glacier)
                .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detail CRM is loading")
    }
}

/// Signed in, but the first load failed (usually offline at launch).
private struct BootstrapErrorView: View {
    @Environment(AppState.self) private var appState
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ErrorStateView(message: message) {
                await appState.retry()
            }
            Button("Sign out") {
                Task { await appState.signOut() }
            }
            .buttonStyle(.themePlain)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
