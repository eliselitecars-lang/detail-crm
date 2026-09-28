//
//  JobsCalendarEventSheet.swift
//  DetailCRM
//
//  Create / edit a calendar event (P-17, managers+): shop closed, a team
//  member's time off, a meeting, a customer consultation, a reminder or
//  another event — all day or timed, optionally repeating, and whether it
//  takes booking capacity. Stored in `blocked_times`; the server validates
//  the combination (time off needs a member, closed is shop-wide, only
//  consultations and reminders name a customer). Editing a repeating event
//  changes every repeat; deleting removes them all.
//

import SwiftUI
import Supabase
import DetailCore

struct JobsCalendarEventSheet: View {

    /// What the sheet opens on.
    enum Target: Identifiable, Hashable {
        case new(start: Date)
        case edit(UUID)

        var id: String {
            switch self {
            case .new(let start): return "new-\(start.timeIntervalSince1970)"
            case .edit(let id): return "edit-" + id.uuidString
            }
        }
    }

    let target: Target
    /// Called after a save or delete so the calendar reloads.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var loadState: LoadState<Bool> = .idle
    @State private var kind: JobsCalendarEvent.Kind = .meeting
    @State private var title = ""
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3_600)
    @State private var memberID: UUID?
    /// The event's customer, kept by id: the loaded customer only labels
    /// the field, so a failed lookup never unlinks it on save.
    @State private var customerLink = LinkedRecord<JobCustomer>()
    @State private var customerQuery = ""
    @State private var customerResults: [JobCustomer] = []
    @State private var affectsCapacity = false
    @State private var capacityEdited = false
    @State private var notes = ""
    @State private var repeats = false
    @State private var recurrence = JobsBlockedTimeRecurrence(frequency: .week)
    @State private var repeatEnd = 0
    @State private var untilDay = Date()
    @State private var repeatCount = 10
    @State private var team: [CalendarTeamMember] = []
    @State private var errorMessage: String?
    @State private var confirmation: ConfirmationRequest?

    private var clock: ShopClock { appState.clock }
    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            LoadStateView(loadState, loadingLabel: "Loading event…", retry: { await load() }) { _ in
                form
            }
            .navigationTitle(isEditing ? "Edit event" : "New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton("Save", style: .themePrimaryCompact) { await save() }
                        .disabled(loadState.value == nil)
                }
            }
            .confirmation($confirmation)
        }
        .task { await load() }
    }

    // MARK: - Form

    private var form: some View {
        FormScreen {
            if let errorMessage {
                InlineMessage(text: errorMessage, kind: .error)
            }
            FormRow("Type") {
                Picker("Type", selection: kindBinding) {
                    ForEach(JobsCalendarEvent.Kind.allCases) { item in
                        Label(item.displayName, systemImage: item.systemImage).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.glacier)
            }
            ThemedTextField(
                label: "Title",
                placeholder: kind.displayName,
                text: $title,
                hint: "Shown on the calendar. Technicians see the titles of shop-wide events and their own."
            )
            timeFields
            if !kind.forbidsMember {
                memberField
            }
            if kind.allowsCustomer {
                customerField
            }
            FormRow("Booking", hint: capacityHint) {
                Toggle("Takes booking capacity", isOn: capacityBinding)
                    .tint(Theme.glacier)
                    .disabled(kind == .closed)
            }
            repeatFields
            FormRow("Notes", hint: "Up to 500 characters.") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .inputFieldStyle()
            }
            if isEditing {
                Button("Delete event", role: .destructive) { confirmDelete() }
                    .buttonStyle(.themeDestructive)
            }
        }
    }

    private var capacityHint: String {
        switch kind {
        case .closed:
            return "Closed times always block online booking."
        case .timeOff:
            return "When on, online booking counts this member as away (if the shop counts technicians)."
        default:
            return memberID == nil
                ? "When on, this event uses one booking slot while it lasts."
                : "When on, this member counts as busy for online booking."
        }
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Toggle("All day", isOn: $allDay)
                .tint(Theme.glacier)
            if allDay {
                DatePicker("From", selection: startDayBinding, displayedComponents: [.date])
                DatePicker("Through", selection: endDayBinding, in: start..., displayedComponents: [.date])
            } else {
                DatePicker("Starts", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Ends", selection: $end, in: start.addingTimeInterval(300)..., displayedComponents: [.date, .hourAndMinute])
            }
            Text("Shop time (\(clock.timeZone.identifier)).")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .environment(\.timeZone, clock.timeZone)
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.textPrimary)
        .onChange(of: allDay) { _, isAllDay in
            if isAllDay {
                let days = dayCount
                start = clock.startOfDay(start)
                end = clock.addingDays(days, to: start)
            } else if end.timeIntervalSince(start) >= 86_400 {
                start = clock.date(on: start, timeString: "09:00") ?? start
                end = start.addingTimeInterval(3_600)
            }
        }
    }

    private var memberField: some View {
        FormRow(kind.requiresMember ? "Team member" : "Team member (optional)") {
            Picker("Team member", selection: $memberID) {
                if !kind.requiresMember {
                    Text("Whole shop").tag(UUID?.none)
                } else if memberID == nil {
                    Text("Choose…").tag(UUID?.none)
                }
                ForEach(team) { member in
                    Text(member.displayName).tag(UUID?.some(member.memberID))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.glacier)
        }
    }

    @ViewBuilder
    private var customerField: some View {
        FormRow("Customer (optional)", hint: "Only managers see which customer an event is for.") {
            switch customerLink.display {
            case .record(let customer):
                linkedCustomerRow {
                    Label(customer.displayName, systemImage: "person")
                        .foregroundStyle(Theme.textPrimary)
                }
            case .loading:
                linkedCustomerRow {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView()
                        Text("Loading customer…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            case .failed:
                linkedCustomerRow {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Label("Couldn't load the customer", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.textPrimary)
                        Text("It stays linked to this event.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Try again") {
                            Task { await loadLinkedCustomer() }
                        }
                        .font(Theme.Typography.footnote.weight(.semibold))
                    }
                }
            case .unavailable:
                linkedCustomerRow {
                    Label("A customer you can't see", systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(Theme.textSecondary)
                }
            case .none:
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    SearchBar(text: $customerQuery, prompt: "Search customers")
                    ForEach(customerResults.prefix(6)) { result in
                        Button {
                            customerLink.pick(result)
                            customerQuery = ""
                            customerResults = []
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(result.displayName)
                                    .foregroundStyle(Theme.textPrimary)
                                if let line = result.secondaryLine {
                                    Text(line)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Spacing.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .task(id: customerQuery) { await searchCustomers() }
            }
        }
    }

    @ViewBuilder
    private var repeatFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Toggle("Repeat", isOn: $repeats)
                .tint(Theme.glacier)
            if repeats {
                Picker("Repeats", selection: $recurrence.frequency) {
                    Text("Daily").tag(JobsBlockedTimeRecurrence.Frequency.day)
                    Text("Weekly").tag(JobsBlockedTimeRecurrence.Frequency.week)
                    Text("Monthly").tag(JobsBlockedTimeRecurrence.Frequency.month)
                }
                .pickerStyle(.segmented)
                Stepper(value: $recurrence.interval, in: 1...12) {
                    Text(recurrence.interval == 1
                         ? "Every \(recurrence.frequency.unitName)"
                         : "Every \(recurrence.interval) \(recurrence.frequency.unitName)s")
                }
                if recurrence.frequency == .week {
                    weekdayChips
                }
                Picker("Ends", selection: $repeatEnd) {
                    Text("Never").tag(0)
                    Text("On a date").tag(1)
                    Text("After").tag(2)
                }
                .pickerStyle(.segmented)
                if repeatEnd == 1 {
                    DatePicker("Last repeat on", selection: $untilDay, in: start..., displayedComponents: [.date])
                        .environment(\.timeZone, clock.timeZone)
                } else if repeatEnd == 2 {
                    Stepper(value: $repeatCount, in: 1...500) {
                        Text(repeatCount == 1 ? "Once" : "\(repeatCount) times")
                    }
                }
                if isEditing {
                    Text("Changes apply to every repeat of this event.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.textPrimary)
    }

    private var weekdayChips: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<7, id: \.self) { day in
                let isOn = recurrence.weekdays.contains(day)
                Button {
                    if isOn {
                        recurrence.weekdays.removeAll { $0 == day }
                    } else {
                        recurrence.weekdays.append(day)
                    }
                } label: {
                    Text(String(JobsSeriesDraft.Rule.weekdayNames[day].prefix(2)))
                        .font(Theme.Typography.captionEmphasis)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.compactControlHeight)
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.textPrimary)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(isOn ? Theme.glacier : Theme.surfaceMuted))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(JobsSeriesDraft.Rule.weekdayLongNames[day])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<JobsCalendarEvent.Kind> {
        Binding(
            get: { kind },
            set: { newKind in
                kind = newKind
                if !capacityEdited { affectsCapacity = newKind.defaultAffectsCapacity }
                if newKind == .closed { memberID = nil; affectsCapacity = true }
                if !newKind.allowsCustomer { customerLink.remove() }
            }
        )
    }

    private var capacityBinding: Binding<Bool> {
        Binding(
            get: { kind == .closed ? true : affectsCapacity },
            set: { value in
                affectsCapacity = value
                capacityEdited = true
            }
        )
    }

    /// Moving the start keeps the event's length.
    private var startBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { newValue in
                let length = max(end.timeIntervalSince(start), 300)
                start = newValue
                end = newValue.addingTimeInterval(length)
            }
        )
    }

    private var startDayBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { day in
                let days = max(0, dayCount - 1)
                start = clock.startOfDay(day)
                end = clock.addingDays(days + 1, to: start)
            }
        )
    }

    /// The last day of an all-day event (its end is the next midnight).
    private var endDayBinding: Binding<Date> {
        Binding(
            get: { clock.startOfDay(end.addingTimeInterval(-1)) },
            set: { day in end = clock.addingDays(1, to: clock.startOfDay(day)) }
        )
    }

    private var dayCount: Int {
        max(1, clock.days(from: start, to: end).count)
    }

    // MARK: - Data

    private func load() async {
        guard let shopID = appState.shop?.id else {
            loadState = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        loadState.beginLoading()
        team = (try? await CalendarService.team(shopID: shopID)) ?? []
        switch target {
        case .new(let suggested):
            start = suggested
            end = suggested.addingTimeInterval(3_600)
            affectsCapacity = kind.defaultAffectsCapacity
            untilDay = clock.addingDays(30, to: suggested)
            recurrence.weekdays = [clock.calendar.component(.weekday, from: suggested) - 1]
            loadState = .loaded(true)
        case .edit(let id):
            let result = await LoadState<JobsCalendarEvent>.result {
                try await CalendarService.calendarEvent(shopID: shopID, id: id)
            }
            switch result {
            case .loaded(let event):
                await prefill(event, shopID: shopID)
                loadState = .loaded(true)
            case .failed(let message):
                loadState = .failed(message)
            case .idle, .loading:
                break
            }
        }
    }

    private func prefill(_ event: JobsCalendarEvent, shopID: UUID) async {
        kind = event.kind
        title = event.title ?? ""
        start = event.startsAt
        end = event.endsAt
        allDay = clock.startOfDay(event.startsAt) == event.startsAt && clock.startOfDay(event.endsAt) == event.endsAt
        memberID = event.memberID
        affectsCapacity = event.affectsCapacity
        capacityEdited = true
        notes = event.reason ?? ""
        if let rule = event.recurrence {
            repeats = true
            recurrence = rule
            if rule.weekdays.isEmpty {
                recurrence.weekdays = [clock.calendar.component(.weekday, from: event.startsAt) - 1]
            }
            if let until = rule.untilDate, let day = clock.date(fromDateString: until) {
                repeatEnd = 1
                untilDay = day
            } else if let count = rule.count {
                repeatEnd = 2
                repeatCount = count
            }
        } else {
            untilDay = clock.addingDays(30, to: event.startsAt)
            recurrence.weekdays = [clock.calendar.component(.weekday, from: event.startsAt) - 1]
        }
        customerLink = LinkedRecord(id: event.customerID)
        await loadLinkedCustomer(shopID: shopID)
    }

    /// Labels the linked customer. A failure keeps the link (the field
    /// offers a retry) instead of looking like "no customer".
    private func loadLinkedCustomer(shopID: UUID? = nil) async {
        guard let customerID = customerLink.id, customerLink.record == nil,
              let shopID = shopID ?? appState.shop?.id else { return }
        customerLink.retryingLookup()
        do {
            let found = try await JobService.customer(shopID: shopID, customerID: customerID)
            customerLink.lookupFinished(found, for: customerID)
        } catch {
            customerLink.lookupFailed(for: customerID)
        }
    }

    /// A linked customer's row with its Remove button.
    private func linkedCustomerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
            Spacer()
            Button("Remove") { customerLink.remove() }
                .font(Theme.Typography.footnote.weight(.semibold))
        }
    }

    private func searchCustomers() async {
        guard let shopID = appState.shop?.id, customerQuery.trimmedNonEmpty != nil else {
            customerResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        customerResults = (try? await JobService.searchCustomers(shopID: shopID, term: customerQuery)) ?? []
    }

    private func save() async {
        errorMessage = nil
        guard let shopID = appState.shop?.id else { return }
        if kind.requiresMember && memberID == nil {
            errorMessage = "Choose whose time off this is."
            return
        }
        guard end > start else {
            errorMessage = "The end must be after the start."
            return
        }
        if notes.count > 500 {
            errorMessage = "Notes are limited to 500 characters."
            return
        }
        if title.count > 120 {
            errorMessage = "Titles are limited to 120 characters."
            return
        }
        var fields: [String: AnyJSON] = [
            "kind": .string(kind.rawValue),
            "title": title.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null,
            "starts_at": .string(Supa.iso(start)),
            "ends_at": .string(Supa.iso(end)),
            "member_id": kind.forbidsMember ? .null : (memberID.map { AnyJSON.string($0.uuidString) } ?? .null),
            "customer_id": kind.allowsCustomer ? (customerLink.id.map { AnyJSON.string($0.uuidString) } ?? .null) : .null,
            "affects_capacity": .bool(kind == .closed ? true : affectsCapacity),
            "reason": notes.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null,
        ]
        if repeats {
            if recurrence.frequency == .week && recurrence.weekdays.isEmpty {
                errorMessage = "Pick at least one day of the week to repeat on."
                return
            }
            var rule = recurrence
            rule.untilDate = repeatEnd == 1 ? clock.dateString(untilDay) : nil
            rule.count = repeatEnd == 2 ? repeatCount : nil
            fields["recurrence"] = rule.json
        } else {
            fields["recurrence"] = .null
        }
        let id: UUID?
        if case .edit(let existing) = target { id = existing } else { id = nil }
        do {
            try await CalendarService.saveCalendarEvent(shopID: shopID, id: id, fields: fields)
            toasts.show(isEditing ? "Event updated" : "Event added")
            onChange()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func confirmDelete() {
        guard case .edit(let id) = target, let shopID = appState.shop?.id else { return }
        confirmation = ConfirmationRequest(
            title: repeats ? "Delete every repeat of this event?" : "Delete this event?",
            message: nil,
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                try await CalendarService.deleteCalendarEvent(shopID: shopID, id: id)
                toasts.show("Event deleted")
                onChange()
                dismiss()
            } catch {
                toasts.showError(error)
            }
        }
    }
}
