//
//  SettingsHoursView.swift
//  DetailCRM
//
//  Business hours per weekday (wall-clock time in the shop's time zone).
//  A day may have several non-overlapping openings; no opening = closed.
//  Owners/admins add, change and delete openings; each change is saved
//  on its own (the database rejects overlaps).
//

import SwiftUI
import DetailCore

/// Opening being edited (nil `hour` = new opening on `weekday`).
struct SettingsHourEdit: Identifiable {
    let id = UUID()
    let weekday: Int
    let hour: BusinessHour?
}

struct SettingsHoursView: View {
    let canEdit: Bool

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<[BusinessHour]> = .idle
    @State private var editing: SettingsHourEdit?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading hours…", retry: { await load() }) { hours in
            SettingsHoursList(
                hours: hours,
                canEdit: canEdit,
                weekdays: ShopSettingsHours.orderedWeekdays(firstWeekday: appState.clock.firstWeekday),
                add: { weekday in editing = SettingsHourEdit(weekday: weekday, hour: nil) },
                edit: { hour in editing = SettingsHourEdit(weekday: hour.weekday, hour: hour) },
                delete: { hour in confirmDelete(hour) }
            )
        }
        .screenBackground()
        .navigationTitle("Business hours")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { edit in
            SettingsHourEditor(edit: edit, existing: state.value ?? []) {
                await load()
            }
        }
        .confirmation($confirmation)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<[BusinessHour]>.result {
            try await SettingsService.hours(shopID: shopID)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    private func confirmDelete(_ hour: BusinessHour) {
        confirmation = ConfirmationRequest(
            title: "Remove \(hour.rangeText)?",
            message: "\(ShopSettingsHours.weekdayName(hour.weekday)) will no longer include these hours.",
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await SettingsService.deleteHour(shopID: shopID, hourID: hour.id)
                toasts.show("Hours removed.")
            } catch {
                toasts.showError(error)
            }
            await load()
        }
    }
}

private struct SettingsHoursList: View {
    let hours: [BusinessHour]
    let canEdit: Bool
    let weekdays: [Int]
    let add: (Int) -> Void
    let edit: (BusinessHour) -> Void
    let delete: (BusinessHour) -> Void

    var body: some View {
        List {
            ForEach(weekdays, id: \.self) { weekday in
                SettingsHoursDaySection(
                    weekday: weekday,
                    hours: hours.filter { $0.weekday == weekday }.sorted { $0.opensMinutes < $1.opensMinutes },
                    canEdit: canEdit,
                    add: add,
                    edit: edit,
                    delete: delete
                )
            }
            Section {
                InlineMessage(
                    text: canEdit
                        ? "Hours are in the shop's time zone. Online booking only offers times inside these hours."
                        : "Only owners and admins can change business hours.",
                    kind: .info
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SettingsHoursDaySection: View {
    let weekday: Int
    let hours: [BusinessHour]
    let canEdit: Bool
    let add: (Int) -> Void
    let edit: (BusinessHour) -> Void
    let delete: (BusinessHour) -> Void

    var body: some View {
        Section {
            if hours.isEmpty {
                Text("Closed")
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            } else {
                ForEach(hours) { hour in
                    Button {
                        if canEdit { edit(hour) }
                    } label: {
                        HStack {
                            Text(hour.rangeText)
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                            Spacer()
                            if canEdit {
                                Image(systemName: "pencil")
                                    .foregroundStyle(Theme.textTertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .disabled(!canEdit)
                    .accessibilityHint(canEdit ? "Edit these hours" : "")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canEdit {
                            Button(role: .destructive) {
                                delete(hour)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .themedRow()
                }
            }
            if canEdit {
                Button {
                    add(weekday)
                } label: {
                    Label(hours.isEmpty ? "Add hours" : "Add another opening", systemImage: "plus.circle")
                        .foregroundStyle(Theme.glacier)
                }
                .themedRow()
            }
        } header: {
            Text(ShopSettingsHours.weekdayName(weekday))
        }
    }
}

/// Sheet: pick opening and closing time (15-minute steps, plus the
/// opening's exact current times so off-grid hours aren't rounded).
private struct SettingsHourEditor: View {
    let edit: SettingsHourEdit
    let existing: [BusinessHour]
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var opens: Int
    @State private var closes: Int
    @State private var errorMessage: String?

    private let opensOptions: [Int]
    private let closesOptions: [Int]

    init(edit: SettingsHourEdit, existing: [BusinessHour], onSaved: @escaping () async -> Void) {
        self.edit = edit
        self.existing = existing
        self.onSaved = onSaved
        let startOpens = edit.hour?.opensMinutes ?? 9 * 60
        let startCloses = edit.hour?.closesMinutes ?? 17 * 60
        _opens = State(initialValue: startOpens)
        _closes = State(initialValue: startCloses)
        opensOptions = ShopSettingsHours.pickerOptions(including: [startOpens]).filter { $0 < 24 * 60 }
        closesOptions = ShopSettingsHours.pickerOptions(including: [startCloses]).filter { $0 > 0 }
    }

    /// An existing opening whose times weren't touched.
    private var isUnchanged: Bool {
        guard let hour = edit.hour else { return false }
        return opens == hour.opensMinutes && closes == hour.closesMinutes
    }

    private var problem: String? {
        ShopSettingsHours.problem(opens: opens, closes: closes, weekday: edit.weekday, existing: existing, excludingID: edit.hour?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Opens", selection: $opens) {
                        ForEach(opensOptions, id: \.self) { minutes in
                            Text(ShopSettingsHours.label(forMinutes: minutes)).tag(minutes)
                        }
                    }
                    Picker("Closes", selection: $closes) {
                        ForEach(closesOptions, id: \.self) { minutes in
                            Text(ShopSettingsHours.label(forMinutes: minutes)).tag(minutes)
                        }
                    }
                } header: {
                    Text(ShopSettingsHours.weekdayName(edit.weekday))
                } footer: {
                    Text("Times are in the shop's time zone.")
                }
                if let problem {
                    Section {
                        InlineMessage(text: problem, kind: .error)
                    }
                }
                if let errorMessage {
                    Section {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                }
            }
            .screenBackground()
            .navigationTitle(edit.hour == nil ? "Add hours" : "Edit hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    CatalogSaveButton(disabled: problem != nil && !isUnchanged) {
                        await save()
                    }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        if isUnchanged {
            // Nothing to save: never rewrite the stored times.
            dismiss()
            return
        }
        guard problem == nil else { return }
        do {
            let shopID = try appState.requireShopID()
            // A side the user didn't change keeps its exact stored text.
            let opensText: String
            if let hour = edit.hour, opens == hour.opensMinutes {
                opensText = hour.opensAt
            } else {
                opensText = ShopSettingsHours.timeString(fromMinutes: opens)
            }
            let closesText: String
            if let hour = edit.hour, closes == hour.closesMinutes {
                closesText = hour.closesAt
            } else {
                closesText = ShopSettingsHours.timeString(fromMinutes: closes)
            }
            let draft = BusinessHourDraft(
                shopID: shopID,
                weekday: edit.weekday,
                opensAt: opensText,
                closesAt: closesText
            )
            if let hour = edit.hour {
                try await SettingsService.updateHour(shopID: shopID, hourID: hour.id, draft: draft)
            } else {
                try await SettingsService.addHour(draft)
            }
            toasts.show("Hours saved.")
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
