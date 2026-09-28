//
//  DetailCRMApp.swift
//  DetailCRM
//
//  Entry point. Shows SetupRequiredView until Config.plist holds real
//  Supabase values; otherwise RootView drives the session phases.
//
//  JobsAppDelegate receives the APNs token and notification taps; the
//  Realtime hub and push registrar are shared objects injected into the
//  environment. Coming back to the foreground rejoins Realtime (changes
//  made while suspended are re-read) and refreshes the icon badge.
//

import SwiftUI
import UIKit

@main
struct DetailCRMApp: App {
    @UIApplicationDelegateAdaptor(JobsAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()
    @State private var toasts = ToastCenter()
    @State private var realtime = JobsRealtimeHub.shared
    @State private var push = JobsPushRegistrar.shared

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
            .environment(realtime)
            .environment(push)
            .toastHost(toasts)
            .tint(Theme.glacier)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { JobsAppDelegate.attach(appState) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, appState.phase == .ready else { return }
            Task {
                await realtime.resume()
                await push.refreshAuthorization()
                await push.refreshBadge()
            }
        }
    }
}
