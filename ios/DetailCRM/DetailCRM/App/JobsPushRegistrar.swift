//
//  JobsPushRegistrar.swift
//  DetailCRM
//
//  Push registration (P-2):
//
//  * The first time the main tabs appear on this install, iOS asks for
//    permission (once; remembered in UserDefaults). Later launches only
//    re-register when permission was given, so the server always has the
//    current token (`register_push_token` also bumps its last-seen time).
//  * Sign-out removes this device from the account (`unregister_push_token`);
//    when that call can't be made (the session is already gone) the device
//    stops receiving pushes altogether until someone signs in again.
//  * The app icon badge shows the unread notifications the member may read,
//    across shops — the same number the server puts in each push.
//

import Foundation
import Observation
import UIKit
import UserNotifications
import os

@Observable
@MainActor
final class JobsPushRegistrar {

    static let shared = JobsPushRegistrar()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.detailcrm.app",
        category: "push"
    )
    private static let promptedKey = "detailcrm.push.permissionAsked"

    /// Notification permission as last read from iOS.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// This device's APNs token (hex), once iOS provided it.
    private(set) var deviceToken: String?
    /// The user the token is registered to on the server.
    private(set) var registeredUserID: UUID?
    /// The last registration problem, for the preferences screen.
    private(set) var lastError: String?

    @ObservationIgnored private var signedInUserID: UUID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// APNs environment of this build: development-signed builds talk to the
    /// sandbox, TestFlight / App Store builds to production.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// "1.0 (42)" for the device list.
    static var appVersion: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        if let build = info?["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    // MARK: - Lifecycle

    /// The main tabs are on screen for `userID`: ask once per install, then
    /// (re-)register whenever permission is given.
    func appBecameReady(userID: UUID) async {
        signedInUserID = userID
        await refreshAuthorization()
        if authorization == .notDetermined && !defaults.bool(forKey: Self.promptedKey) {
            defaults.set(true, forKey: Self.promptedKey)
            _ = await requestPermission()
            return
        }
        if isAuthorized {
            UIApplication.shared.registerForRemoteNotifications()
            if let deviceToken, registeredUserID != userID {
                await register(token: deviceToken, userID: userID)
            }
        }
    }

    /// Shows the system prompt (from the preferences screen, or the first
    /// launch). Returns whether notifications are now allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            Self.log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorization()
            return false
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    // MARK: - Tokens (from JobsAppDelegate)

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        let unchanged = token == deviceToken && registeredUserID != nil && registeredUserID == signedInUserID
        deviceToken = token
        lastError = nil
        guard let userID = signedInUserID, !unchanged else { return }
        Task { await register(token: token, userID: userID) }
    }

    func didFailToRegister(_ error: Error) {
        lastError = "This iPhone couldn't register for notifications. \(error.localizedDescription)"
        Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    private func register(token: String, userID: UUID) async {
        do {
            try await JobsPushService.register(
                token: token,
                environment: Self.apnsEnvironment,
                bundleID: Bundle.main.bundleIdentifier ?? "com.detailcrm.app",
                appVersion: Self.appVersion
            )
            registeredUserID = userID
            lastError = nil
        } catch {
            lastError = ErrorText.message(for: error)
            Self.log.error("register_push_token failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Before signing out: remove this device from the account while the
    /// session still works. When it can't be removed (session already
    /// refused, offline), stop receiving pushes on this device instead.
    func detachBeforeSignOut() async {
        signedInUserID = nil
        defer {
            registeredUserID = nil
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        }
        guard let token = deviceToken, registeredUserID != nil else { return }
        // Sign-out never waits long on this: 4 seconds, then the fallback.
        let removed: Bool = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    try await JobsPushService.unregister(token: token)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        if !removed {
            Self.log.error("unregister_push_token did not complete; unregistering this device from APNs")
            UIApplication.shared.unregisterForRemoteNotifications()
            deviceToken = nil
        }
    }

    /// Nobody is signed in any more (also after the session was dropped by
    /// the server): forget the user; pushes shown meanwhile are suppressed.
    func userSignedOut() {
        signedInUserID = nil
        if registeredUserID != nil {
            // Signed out without `detachBeforeSignOut` (the Auth client
            // dropped a session the server refused): the server still lists
            // this device for that account, so leave APNs on this device.
            UIApplication.shared.unregisterForRemoteNotifications()
            deviceToken = nil
            registeredUserID = nil
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        }
    }

    /// Whether a notification arriving now should be shown (only while
    /// someone is signed in on this device).
    var shouldPresentNotifications: Bool { signedInUserID != nil }

    // MARK: - Badge

    /// Sets the app icon badge to the member's unread notifications.
    func refreshBadge() async {
        guard signedInUserID != nil, isAuthorized else { return }
        do {
            let unread = try await JobsPushService.unreadCountAllShops()
            try await UNUserNotificationCenter.current().setBadgeCount(unread)
        } catch {
            // The badge is cosmetic; the next refresh corrects it.
        }
    }
}
