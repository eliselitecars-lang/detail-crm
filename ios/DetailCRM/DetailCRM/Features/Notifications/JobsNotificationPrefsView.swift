//
//  JobsNotificationPrefsView.swift
//  DetailCRM
//
//  Push notification settings for the signed-in member in this shop (P-2):
//  iPhone permission, which kinds may be pushed, a temporary mute and a
//  test push. The in-app list is never affected — these settings only
//  decide what reaches the lock screen (`set_notification_prefs`, own
//  membership only). Kinds the member's role can't read are not offered
//  (they would never be sent) but a saved choice for them is kept.
//

import SwiftUI
import UIKit
import DetailCore

struct JobsNotificationPrefsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsPushRegistrar.self) private var push
    @Environment(\.openURL) private var openURL

    @State private var state: LoadState<JobsPushService.Prefs?> = .idle
    /// Kinds switched on (raw values), edited locally until Save.
    @State private var enabledKinds: Set<String> = []
    @State private var mutedUntil: Date?
    @State private var isDirty = false
    @State private var isSaving = false

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading notification settings…", retry: { await load() }) { _ in
            form
        }
        .screenBackground()
        .navigationTitle("Push notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                AsyncButton("Save", style: .themePrimaryCompact) { await save() }
                    .disabled(!isDirty || isSaving)
            }
        }
        .task { await load() }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            permissionSection
            muteSection
            Section {
                ForEach(offeredKinds, id: \.self) { kind in
                    Toggle(isOn: binding(for: kind)) {
                        Label(kind.displayName, systemImage: kind.systemImage)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.glacier)
                }
            } header: {
                Text("Send to this iPhone")
            } footer: {
                Text("Turned-off kinds still appear in the Notifications list in the app.")
            }
            Section {
                AsyncButton("Send a test notification", style: .themeSecondaryCompact) { await sendTest() }
                    .disabled(!push.isAuthorized)
            } footer: {
                if let error = push.lastError {
                    Text(error)
                } else {
                    Text("Sends \"Test notification\" to every iPhone you're signed in on.")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            switch push.authorization {
            case .denied:
                InlineMessage(text: "Notifications are turned off for Detail CRM in iPhone Settings.", kind: .error)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .notDetermined:
                InlineMessage(text: "This iPhone hasn't been allowed to show notifications yet.", kind: .info)
                AsyncButton("Allow notifications", style: .themePrimaryCompact) {
                    await push.requestPermission()
                }
            default:
                InlineMessage(text: "This iPhone receives notifications for your account.", kind: .success)
            }
        } header: {
            Text("This iPhone")
        }
    }

    private var muteSection: some View {
        Section {
            if let mutedUntil, mutedUntil > Date() {
                Text("Muted until \(appState.clock.dateTimeText(mutedUntil))")
                    .foregroundStyle(Theme.textPrimary)
                Button("Unmute") { setMute(nil) }
            } else {
                Menu {
                    Button("For 1 hour") { setMute(Date().addingTimeInterval(3_600)) }
                    Button("For 8 hours") { setMute(Date().addingTimeInterval(8 * 3_600)) }
                    Button("Until tomorrow morning") { setMute(tomorrowMorning) }
                    Button("For 1 week") { setMute(Date().addingTimeInterval(7 * 86_400)) }
                } label: {
                    Label("Mute pushes…", systemImage: "bell.slash")
                }
            }
        } header: {
            Text("Mute")
        } footer: {
            Text("While muted nothing is pushed from this shop; the list in the app still fills up.")
        }
    }

    /// 8:00 tomorrow in the shop's time zone.
    private var tomorrowMorning: Date {
        let clock = appState.clock
        let tomorrow = clock.addingDays(1, to: clock.startOfDay(Date()))
        return clock.calendar.date(byAdding: .hour, value: 8, to: tomorrow) ?? tomorrow
    }

    /// Kinds this member's role can receive.
    private var offeredKinds: [AppNotificationKind] {
        guard let role = appState.role else { return [] }
        return AppNotificationKind.allCases.filter { kind in
            switch kind {
            case .smsNumberStatus, .webhookFailing:
                return role.isAdminOrAbove
            default:
                return kind.isForEveryMember || role.isManagerOrAbove
            }
        }
    }

    private func binding(for kind: AppNotificationKind) -> Binding<Bool> {
        Binding(
            get: { enabledKinds.contains(kind.rawValue) },
            set: { on in
                if on { enabledKinds.insert(kind.rawValue) } else { enabledKinds.remove(kind.rawValue) }
                isDirty = true
            }
        )
    }

    private func setMute(_ date: Date?) {
        mutedUntil = date
        isDirty = true
    }

    // MARK: - Data

    private func load() async {
        guard let current = appState.current else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        await push.refreshAuthorization()
        state.beginLoading()
        let result = await LoadState<JobsPushService.Prefs?>.result {
            try await JobsPushService.prefs(shopID: current.shop.id, memberID: current.member.id)
        }
        if case .loaded(let prefs) = result {
            // No saved row yet: every kind is pushed.
            enabledKinds = Set(prefs?.pushKinds ?? AppNotificationKind.allCases.map(\.rawValue))
            mutedUntil = prefs?.mutedUntil
            isDirty = false
        }
        state.apply(result)
    }

    private func save() async {
        guard let shopID = appState.shop?.id else { return }
        isSaving = true
        defer { isSaving = false }
        // Kinds not offered here keep their saved state.
        let offered = Set(offeredKinds.map(\.rawValue))
        let saved = Set(state.value.flatMap { $0?.pushKinds } ?? AppNotificationKind.allCases.map(\.rawValue))
        let kept = saved.subtracting(offered)
        let kinds = Array(kept.union(enabledKinds.intersection(offered))).sorted()
        let mute = mutedUntil.flatMap { $0 > Date() ? $0 : nil }
        do {
            let prefs = try await JobsPushService.savePrefs(shopID: shopID, pushKinds: kinds, mutedUntil: mute)
            state = .loaded(prefs)
            enabledKinds = Set(prefs.pushKinds)
            mutedUntil = prefs.mutedUntil
            isDirty = false
            toasts.show("Notification settings saved")
        } catch {
            toasts.showError(error)
        }
    }

    private func sendTest() async {
        guard let shopID = appState.shop?.id else { return }
        do {
            let reply = try await JobsPushService.sendTest(shopID: shopID)
            toasts.show(reply.sent == 1 ? "Test sent to 1 iPhone" : "Test sent to \(reply.sent) iPhones")
        } catch {
            toasts.showError(error)
        }
    }
}
