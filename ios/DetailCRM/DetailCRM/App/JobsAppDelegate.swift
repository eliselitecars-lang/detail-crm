//
//  JobsAppDelegate.swift
//  DetailCRM
//
//  UIKit hooks SwiftUI doesn't expose: the APNs device token and the
//  notification center delegate (banners while the app is open, taps).
//  Everything is handed to the main-actor objects right away.
//

import UIKit
import UserNotifications

final class JobsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by DetailCRMApp so taps can be routed (the app's one AppState).
    @MainActor static weak var appState: AppState?
    /// A tap that arrived before the app's window was up (cold start).
    @MainActor static var launchPayload: JobsPushRouter.NotificationTap?

    /// Called once the window is up: routes a cold-start tap.
    @MainActor
    static func attach(_ appState: AppState) {
        self.appState = appState
        if let payload = launchPayload {
            launchPayload = nil
            JobsPushRouter.open(payload, appState: appState)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            JobsPushRegistrar.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            JobsPushRegistrar.shared.didFailToRegister(AppError.message(message))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// While the app is open: show the banner (the list and badge refresh
    /// through Realtime), but only while someone is signed in.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            if JobsPushRegistrar.shared.shouldPresentNotifications {
                completionHandler([.banner, .list, .sound, .badge])
            } else {
                completionHandler([])
            }
        }
    }

    /// A tap on a notification opens what it is about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = JobsPushRouter.payload(from: response.notification.request.content.userInfo)
        let isTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isTap, let payload {
                if let appState = JobsAppDelegate.appState {
                    JobsPushRouter.open(payload, appState: appState)
                } else {
                    JobsAppDelegate.launchPayload = payload
                }
            }
            completionHandler()
        }
    }
}
