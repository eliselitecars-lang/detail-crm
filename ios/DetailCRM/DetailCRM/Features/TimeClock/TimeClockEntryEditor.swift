//
//  TimeClockEntryEditor.swift
//  DetailCRM
//
//  Manager sheet to add a manual shift entry or correct an entry's times
//  and notes. Times are picked in the SHOP time zone. The server rejects
//  overlaps / a second open entry; the message is shown inline.
//

import SwiftUI
import DetailCore

enum TimeClockEditorMode: Identifiable {
    case add(memberID: UUID)
    case edit(TimeEntry)

    var id: String {
        switch self {
        case .add(let memberID): return "add-\(memberID.uuidString)"
        case .edit(let entry): return "edit-\(entry.id.uuidString)"
        }
    }
}

struct TimeClockEntryEditor: View {
    let mode: TimeClockEditorMode
    let memberName: String
    let clock: ShopClock
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var clockIn: Date
    @State private var clockOut: Date
    @State private var isOpen: Bool
    @State private var notes: String
    @State private var errorMessage: String?

    init(mode: TimeClockEditorMode, memberName: String, clock: ShopClock, onSaved: @escaping () async -> Void) {
        self.mode = mode
        self.memberName = memberName
        self.clock = clock
        self.onSaved = onSaved
        switch mode {
        case .add:
            let now = Date()
            let start = clock.date(on: now, timeString: "09:00") ?? now
            let end = clock.date(on: now, timeString: "17:00") ?? now
            _clockIn = State(initialValue: min(start, now))
            _clockOut = State(initialValue: min(max(end, start), max(now, start)))
            _isOpen = State(initialValue: false)
            _notes = State(initialValue: "")
        case .edit(let entry):
            _clockIn = State(initialValue: entry.clockIn)
            _clockOut = State(initialValue: entry.clockOut ?? max(Date(), entry.clockIn))
            _isOpen = State(initialValue: entry.clockOut == nil)
            _notes = State(initialValue: entry.notes ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(label: "Team member", value: memberName)
                    InfoRow(label: "Type", value: kindText)
                } footer: {
                    Text(isAdd ? "Manual entries are shifts. Job time is recorded from the job timer." : "Times are in the shop's time zone (\(clock.timeZone.identifier)).")
                }
                Section("Times") {
                    DatePicker("Clock in", selection: $clockIn, displayedComponents: [.date, .hourAndMinute])
                    Toggle("Still clocked in", isOn: $isOpen)
                    DatePicker("Clock out", selection: $clockOut, in: clockIn..., displayedComponents: [.date, .hourAndMinute])
                        .disabled(isOpen)
                        .opacity(isOpen ? 0.45 : 1)
                    HStack {
                        Text("Duration")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(durationText)
                            .font(Theme.Typography.bodyEmphasis.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .environment(\.timeZone, clock.timeZone)
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    AsyncButton(isAdd ? "Add entry" : "Save changes", style: .themePrimary) {
                        await save()
                    }
                    .disabled(validationProblem != nil)
                    if let validationProblem {
                        InlineMessage(text: validationProblem, kind: .info)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .screenBackground()
            .navigationTitle(isAdd ? "Add time" : "Edit time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var kindText: String {
        switch mode {
        case .add: return TimeEntryKind.shift.displayName
        case .edit(let entry): return entry.kind.displayName
        }
    }

    private var durationText: String {
        if isOpen { return "Running" }
        return TimeEntry.durationText(seconds: max(0, Int(clockOut.timeIntervalSince(clockIn))))
    }

    private var validationProblem: String? {
        if clockIn > Date().addingTimeInterval(60) { return "Clock-in can't be in the future." }
        if !isOpen && clockOut < clockIn { return "Clock-out must be after clock-in." }
        if notes.count > 2000 { return "Notes are limited to 2,000 characters." }
        return nil
    }

    private func save() async {
        errorMessage = nil
        guard validationProblem == nil else { return }
        let trimmedNotes = notes.trimmedNonEmpty
        do {
            let shopID = try appState.requireShopID()
            switch mode {
            case .add(let memberID):
                let draft = TimeEntryDraft(
                    shopID: shopID,
                    memberID: memberID,
                    kind: .shift,
                    jobID: nil,
                    clockIn: clockIn,
                    clockOut: isOpen ? nil : clockOut,
                    notes: trimmedNotes
                )
                _ = try await TimeClockService.addEntry(draft)
                toasts.show("Entry added.")
            case .edit(let entry):
                let edit = TimeEntryEdit(clockIn: clockIn, clockOut: isOpen ? nil : clockOut, notes: trimmedNotes)
                _ = try await TimeClockService.updateEntry(shopID: shopID, entryID: entry.id, edit: edit)
                toasts.show("Entry updated.")
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
