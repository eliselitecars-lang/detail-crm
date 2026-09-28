//
//  JobDetailsEditorSheet.swift
//  DetailCRM
//
//  Manager+: when (shop time zone), where (shop or mobile address), bay /
//  van, customer-visible notes and the deposit requirement. Also the crew
//  picker (`JobAssigneesSheet`).
//

import SwiftUI
import DetailCore

struct JobDetailsEditorSheet: View {
    let model: JobDetailModel
    /// Set when opened to schedule an unscheduled job: a time is required
    /// and saving also moves the job to this status (one row write, so
    /// `jobs_schedule_required` is satisfied).
    let targetStatus: JobStatus?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var isScheduled = true
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var locationType: JobLocationType = .shop
    @State private var line1 = ""
    @State private var line2 = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""
    @State private var resourceID: UUID?
    @State private var notes = ""
    @State private var depositText = ""
    @State private var errorMessage: String?
    @State private var didPrefill = false
    /// A recurring visit: the edit waits for "this visit / following".
    @State private var pendingSeriesPatch: JobDetailsPatch?
    @State private var asksSeriesScope = false
    /// Why the pending edit can only be saved on this visit (a new date or
    /// deposit), or nil when "this and following" is offered too.
    @State private var seriesFollowingLimit: String?

    init(model: JobDetailModel, targetStatus: JobStatus? = nil) {
        self.model = model
        self.targetStatus = targetStatus
    }

    private var job: Job? { model.job }

    /// The database requires a time unless the job is requested or cancelled.
    private var canUnschedule: Bool {
        guard targetStatus == nil, let status = job?.status else { return false }
        return !JobDetailModel.statusNeedsTime(status)
    }

    private var screenTitle: String {
        switch targetStatus {
        case .none: return "Edit job"
        case .some(.scheduled): return "Schedule job"
        case .some(.confirmed): return "Confirm job"
        case .some(let status): return status.displayName
        }
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                if let targetStatus {
                    InlineMessage(
                        text: "Pick the date and time. Saving moves the job to \(targetStatus.displayName.lowercased()).",
                        kind: .info
                    )
                }
                scheduleFields
                locationFields
                if model.resourcesFailed {
                    JobReferenceLoadError(text: "Bays and vans couldn't be loaded, so the bay / van can't be changed right now.") {
                        await model.loadResources()
                    }
                } else if !model.resources.isEmpty {
                    resourceField
                }
                FormRow("Notes for the customer", hint: "Shown on the customer's booking and documents.") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...8)
                        .inputFieldStyle()
                }
                ThemedTextField(
                    label: "Deposit required",
                    placeholder: Money.format(cents: 0, currencyCode: appState.currencyCode),
                    text: $depositText,
                    kind: .money,
                    hint: "Leave empty for no deposit."
                )
            }
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton(targetStatus == nil ? "Save" : "Save & move", style: .themePrimaryCompact) {
                        await save()
                    }
                }
            }
            .onAppear { prefill() }
            .jobsSeriesScopeDialog(
                isPresented: $asksSeriesScope,
                followingLimit: seriesFollowingLimit,
                onThisVisit: {
                    guard let patch = pendingSeriesPatch else { return }
                    pendingSeriesPatch = nil
                    Task { await apply(patch) }
                },
                onFollowing: {
                    guard let patch = pendingSeriesPatch, seriesFollowingLimit == nil else { return }
                    pendingSeriesPatch = nil
                    Task { await applyFollowing(patch) }
                }
            )
        }
    }

    // MARK: - Fields

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if canUnschedule {
                Toggle("Scheduled", isOn: $isScheduled)
                    .tint(Theme.glacier)
            }
            if isScheduled || !canUnschedule {
                DatePicker("Starts", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, appState.clock.timeZone)
                DatePicker("Ends", selection: $end, in: start.addingTimeInterval(300)..., displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, appState.clock.timeZone)
                Text("Times are in the shop's time zone (\(appState.clock.timeZone.identifier)).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.textPrimary)
    }

    /// Moving the start keeps the job's length (user edits only).
    private var startBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { newValue in
                let length = max(end.timeIntervalSince(start), 900)
                start = newValue
                end = newValue.addingTimeInterval(length)
            }
        )
    }

    private var locationFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            FormRow("Location") {
                Picker("Location", selection: $locationType) {
                    ForEach(JobLocationType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }
            if locationType == .mobile {
                if let customer = model.snapshot?.customer, customer.addressSummary != nil {
                    Button("Use the customer's address") {
                        line1 = customer.addressLine1 ?? ""
                        line2 = customer.addressLine2 ?? ""
                        city = customer.city ?? ""
                        region = customer.region ?? ""
                        postalCode = customer.postalCode ?? ""
                    }
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.glacier)
                }
                ThemedTextField(label: "Street address", placeholder: "123 Main St", text: $line1)
                ThemedTextField(label: "Apt, suite (optional)", placeholder: "", text: $line2)
                HStack(spacing: Theme.Spacing.sm) {
                    ThemedTextField(label: "City", placeholder: "City", text: $city)
                    ThemedTextField(label: "State", placeholder: "State", text: $region)
                }
                ThemedTextField(label: "ZIP / postal code", placeholder: "", text: $postalCode)
            }
        }
    }

    private var resourceField: some View {
        FormRow("Bay / van") {
            Picker("Bay / van", selection: $resourceID) {
                Text("None").tag(UUID?.none)
                ForEach(model.resources) { resource in
                    Text(resource.name).tag(UUID?.some(resource.id))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.glacier)
        }
    }

    // MARK: - Prefill & save

    private func prefill() {
        guard !didPrefill, let job else { return }
        didPrefill = true
        isScheduled = job.scheduledStart != nil || targetStatus != nil
        let clock = appState.clock
        let fallbackStart = clock.date(on: clock.addingDays(1, to: Date()), timeString: "09:00") ?? Date()
        start = job.scheduledStart ?? fallbackStart
        end = job.scheduledEnd ?? start.addingTimeInterval(3600)
        locationType = job.locationType
        line1 = job.serviceAddressLine1 ?? ""
        line2 = job.serviceAddressLine2 ?? ""
        city = job.serviceCity ?? ""
        region = job.serviceRegion ?? ""
        postalCode = job.servicePostalCode ?? ""
        resourceID = job.resourceID
        notes = job.notes ?? ""
        depositText = job.depositRequiredCents > 0
            ? Money.editableString(cents: job.depositRequiredCents, currencyCode: appState.currencyCode)
            : ""
    }

    private func save() async {
        errorMessage = nil
        guard let job else { return }
        let scheduled = isScheduled || !canUnschedule
        if scheduled {
            guard end > start else {
                errorMessage = "The end time must be after the start."
                return
            }
            guard end.timeIntervalSince(start) <= 31 * 86_400 else {
                errorMessage = "A job can't be longer than 31 days."
                return
            }
        }
        var deposit = 0
        if let text = depositText.trimmedNonEmpty {
            guard let cents = Money.parseCents(text, currencyCode: appState.currencyCode) else {
                errorMessage = "Enter the deposit as an amount, like 50 or 49.99."
                return
            }
            deposit = cents
        }
        let isMobile = locationType == .mobile
        let newLine1 = isMobile ? line1.trimmedNonEmpty : nil
        let newLine2 = isMobile ? line2.trimmedNonEmpty : nil
        let newCity = isMobile ? city.trimmedNonEmpty : nil
        let newRegion = isMobile ? region.trimmedNonEmpty : nil
        let newPostal = isMobile ? postalCode.trimmedNonEmpty : nil
        let addressChanged = newLine1 != job.serviceAddressLine1
            || newLine2 != job.serviceAddressLine2
            || newCity != job.serviceCity
            || newRegion != job.serviceRegion
            || newPostal != job.servicePostalCode
        let patch = JobDetailsPatch(
            scheduledStart: scheduled ? start : nil,
            scheduledEnd: scheduled ? end : nil,
            locationType: locationType,
            serviceAddressLine1: newLine1,
            serviceAddressLine2: newLine2,
            serviceCity: newCity,
            serviceRegion: newRegion,
            servicePostalCode: newPostal,
            clearCoordinates: addressChanged,
            resourceID: resourceID,
            notes: notes.trimmedNonEmpty,
            depositRequiredCents: deposit,
            status: targetStatus
        )
        // A recurring visit being edited (not scheduled from a request):
        // ask whether the following visits change too.
        if job.isSeriesOccurrence && targetStatus == nil && scheduled {
            pendingSeriesPatch = patch
            seriesFollowingLimit = JobsSeriesDraft.followingScopeLimit(
                originalStart: job.scheduledStart,
                newStart: patch.scheduledStart,
                originalDepositCents: job.depositRequiredCents,
                newDepositCents: deposit,
                calendar: appState.clock.calendar
            )
            asksSeriesScope = true
            return
        }
        await apply(patch)
    }

    private func apply(_ patch: JobDetailsPatch) async {
        do {
            try await model.saveDetails(patch)
            if let targetStatus {
                toasts.show("Job is now \(targetStatus.displayName.lowercased()).")
            } else {
                toasts.show("Job updated")
            }
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// "This and following": the series from this visit on. Eligible
    /// visits are replaced on their own dates (this one too, and the screen
    /// then goes back); when this visit was kept (confirmed, paid, invoiced
    /// or moved by hand), the edit is applied to it directly as well. Only
    /// offered when the edit keeps the visit's day and deposit
    /// (`JobsSeriesDraft.followingScopeLimit`), since a replaced visit
    /// would lose them.
    private func applyFollowing(_ patch: JobDetailsPatch) async {
        do {
            let outcome = try await model.updateSeriesFollowing(patch, clock: appState.clock)
            if !model.jobRemoved {
                try await model.saveDetails(patch)
            }
            toasts.show(outcome.text(verb: "updated"), style: .info, duration: .seconds(6))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Manager+: choose who works the job (active members).
struct JobAssigneesSheet: View {
    let model: JobDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var selected: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var didPrefill = false

    private var members: [JobTeamMember] {
        (model.snapshot?.team ?? []).filter { $0.active || selected.contains($0.memberID) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        InlineMessage(text: errorMessage, kind: .error)
                            .themedRow()
                    }
                }
                Section {
                    if members.isEmpty {
                        JobEmptyLine(text: "No team members found.", systemImage: "person.3")
                            .themedRow()
                    }
                    ForEach(members) { member in
                        memberRow(member)
                    }
                } footer: {
                    Text("Assigned technicians see this job, its customer and vehicle.")
                }
            }
            .listStyle(.insetGrouped)
            .screenBackground()
            .navigationTitle("Assign team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton("Save", style: .themePrimaryCompact) {
                        await save()
                    }
                }
            }
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                selected = Set((model.snapshot?.assignments ?? []).map(\.memberID))
            }
        }
    }

    private func memberRow(_ member: JobTeamMember) -> some View {
        let isOn = selected.contains(member.memberID)
        return Button {
            if isOn {
                selected.remove(member.memberID)
            } else {
                selected.insert(member.memberID)
            }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                AvatarView(name: member.displayName, size: Theme.Size.avatarSmall, colorHex: member.calendarColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(member.displayName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(member.active ? member.role.displayName : "Inactive")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Typography.title.weight(.regular))
                    .foregroundStyle(isOn ? Theme.glacier : Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
        .accessibilityLabel(member.displayName)
        .accessibilityValue(isOn ? "Assigned" : "Not assigned")
    }

    private func save() async {
        errorMessage = nil
        do {
            let refreshed = try await model.saveAssignments(selected)
            toasts.show(refreshed ? "Team updated" : "Team updated. Pull down on the job to refresh it.")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
