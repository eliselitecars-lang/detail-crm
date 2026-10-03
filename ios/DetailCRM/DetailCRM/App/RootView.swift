//
//  RootView.swift
//  DetailCRM
//
//  Switches between the session phases owned by AppState. The main tabs
//  are keyed by the signed-in user and the shop, so a sign-in (another
//  member of the same shop included) or a shop switch rebuilds every screen:
//  no navigation path, calendar mode, scroll position or loaded data from
//  the previous session or shop carries over.
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
                .id(MainTabIdentity(userID: appState.userID, shopID: appState.shop?.id))
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

/// Who the main tabs belong to: a new value builds them from scratch.
private struct MainTabIdentity: Hashable {
    let userID: UUID?
    let shopID: UUID?
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

    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ErrorStateView(message: message) {
                await appState.retry()
            }
            // Usually offline, i.e. just when a job video may still be
            // waiting to upload: the confirmation says so before deleting it.
            Button("Sign out") {
                confirmation = .signOut(appState)
            }
            .buttonStyle(.themePlain)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background.ignoresSafeArea())
        .confirmation($confirmation)
    }
}
