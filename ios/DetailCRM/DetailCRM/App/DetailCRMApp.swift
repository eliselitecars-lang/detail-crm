//
//  DetailCRMApp.swift
//  DetailCRM
//
//  Entry point. Shows SetupRequiredView until Config.plist holds real
//  Supabase values; otherwise RootView drives the session phases.
//

import SwiftUI

@main
struct DetailCRMApp: App {
    @State private var appState = AppState()
    @State private var toasts = ToastCenter()

    init() {
        Theme.configureChrome()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if AppConfig.isConfigured {
                    RootView()
                } else {
                    SetupRequiredView()
                }
            }
            .environment(appState)
            .environment(toasts)
            .toastHost(toasts)
            .tint(Theme.glacier)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
