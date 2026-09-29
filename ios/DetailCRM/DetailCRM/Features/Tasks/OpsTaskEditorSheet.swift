//
//  OpsTaskEditorSheet.swift
//  DetailCRM
//
//  Add or edit a task (P-32): title, notes, an optional due time (shop
//  time zone) and who it is for. Owners, admins and managers can assign
//  anyone active and link a customer and one of their jobs; technicians
//  add tasks for themselves (or nobody) and edit the title, notes and due
//  time of their tasks. The assignee gets a notification (and a push when
//  they allow it), and whoever the task is for is reminded when it is due.
//

import SwiftUI
import DetailCore

struct OpsTaskEditorSheet: View {

    /// What the sheet edits.
    enum Mode: Identifiable, Hashable {
        case create
        case edit(OpsTask)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let task): return "edit-" + task.id.uuidString
            }
        }
    }

    /// What happened, for the list.
    enum Change {
        case saved(OpsTask)
        case deleted(UUID)
    }

    let mode: Mode
    /// The shop's team (for the assignee picker; loaded here when empty).
    let members: [TeamDirectoryEntry]
    let onChange: (Change) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OpsTask.Draft()
    @State private var hasDue = false
    @State private var due = Date()
    /// The team read here when the list passed none (it failed to load
    /// there, or is still loading): shown as an error with a retry, never as
    /// a picker that only offers "Nobody in particular".
    @State private var team: LoadState<[TeamDirectoryEntry]> = .idle
    @State private var customerName: String?
    @State private var jobs: LoadState<[CustomerJobSummary]> = .idle
    @State private var showValidation = false
    @State private var errorMessage: String?
    @State private var didPrefill = false
    @State private var confirmation: ConfirmationRequest?
    @State private var pickingCustomer = false

    private var isManager: Bool { appState.role?.isManagerOrAbove ?? false }

    private var existing: OpsTask? {
        if case .edit(let task) = mode { return task }
        return nil
    }

    private var canDelete: Bool {
        guard let existing else { return false }
        return isManager || (existing.createdBy != nil && existing.createdBy == appState.userID)
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                AnyView(basics)
                AnyView(dueSection)
                AnyView(assigneeSection)
                AnyView(linksSection)
                VStack(spacing: Theme.Spacing.sm) {
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    AsyncButton(existing == nil ? "Add task" : "Save task") {
                        await save()
                    }
                    if canDelete {
                        Button(role: .destructive) {
                            confirmDelete()
                        } label: {
                            Label("Delete task", systemImage: "trash")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.dangerInk)
                                .frame(maxWidth: .infinity, minHeight: Theme.Size.controlHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New task" : "Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $pickingCustomer) {
                OpsTaskEditorSheet.CustomerPicker { customer in
                    choose(customer)
                }
            }
        }
        .confirmation($confirmation)
        .onAppear(perform: prefill)
        .task { await loadReferences() }
        .task(id: draft.customerID) { await loadJobs() }
    }

    // MARK: - Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ThemedTextField(
                label: "Task",
                placeholder: "Order more ceramic coating",
                text: $draft.title,
                error: showValidation ? titleError : nil
            )
            FormRow("Notes", hint: "Optional.") {
                TextField("Details, part numbers, who to call…", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...8)
                    .padding(.vertical, Theme.Spacing.sm)
                    .inputFieldStyle()
            }
        }
    }

    private var titleError: String? {
        if draft.trimmedTitle.isEmpty { return "Give the task a title." }
        if draft.trimmedTitle.count > OpsTask.maxTitleLength { return "Use \(OpsTask.maxTitleLength) characters or fewer." }
        return nil
    }

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle(isOn: $hasDue) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Due date")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text("A reminder is sent when it's due.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.glacier)
            if hasDue {
                DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .environment(\.timeZone, appState.clock.timeZone)
                    .environment(\.calendar, appState.clock.calendar)
                Text("Times are in the shop's time zone (\(appState.clock.timeZone.identifier)).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var assigneeSection: some View {
        if isManager {
            FormRow("For", hint: assigneeHint, error: team.errorMessage.map { _ in
                "Couldn't load the team list, so no one can be chosen yet."
            }) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Picker("For", selection: $draft.assigneeMemberID) {
                        Text("Nobody in particular").tag(UUID?.none)
                        ForEach(assignableMembers) { member in
                            Text(member.memberID == appState.member?.id ? "\(member.displayName) (you)" : member.displayName)
                                .tag(UUID?.some(member.memberID))
                        }
                        // The saved assignee stays selectable (and shown)
                        // while the team list is unavailable.
                        if let id = draft.assigneeMemberID, !assignableMembers.contains(where: { $0.memberID == id }) {
                            Text(id == appState.member?.id ? "You" : "Current assignee").tag(UUID?.some(id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                    .disabled(team.isLoading)
                    if team.isLoading {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView()
                            Text("Loading the team…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if team.errorMessage != nil {
                        AsyncButton("Try again", style: .themeSecondaryCompact) {
                            await loadTeam()
                        }
                    }
                }
            }
        } else if existing == nil {
            FormRow("For") {
                Picker("For", selection: $draft.assigneeMemberID) {
                    Text("Me").tag(appState.member.map { UUID?.some($0.id) } ?? UUID?.none)
                    Text("Nobody in particular").tag(UUID?.none)
                }
                .pickerStyle(.segmented)
            }
        } else {
            InfoRow(label: "For", value: assigneeName ?? "Nobody in particular", systemImage: "person")
        }
    }

    /// The team: as passed in, else as loaded here.
    private var directory: [TeamDirectoryEntry] {
        members.isEmpty ? (team.value ?? []) : members
    }

    /// Active members, plus the current assignee if they were deactivated.
    private var assignableMembers: [TeamDirectoryEntry] {
        directory.filter { $0.active || $0.memberID == draft.assigneeMemberID }
    }

    private var assigneeHint: String? {
        if members.isEmpty && team.value == nil { return nil }
        if assignableMembers.isEmpty { return "No one is on the team yet. Invite people from More > Team." }
        return "They get a notification when you assign it."
    }

    private var assigneeName: String? {
        guard let id = draft.assigneeMemberID else { return nil }
        let all = directory
        if id == appState.member?.id { return "You" }
        return all.first { $0.memberID == id }?.displayName ?? "A former team member"
    }

    @ViewBuilder
    private var linksSection: some View {
        if isManager {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                FormRow("Customer", hint: "Optional.") {
                    HStack(spacing: Theme.Spacing.sm) {
                        Button {
                            pickingCustomer = true
                        } label: {
                            HStack {
                                Text(customerName ?? (draft.customerID == nil ? "Choose a customer" : "Customer"))
                                    .foregroundStyle(draft.customerID == nil ? Theme.textTertiary : Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: Theme.Spacing.sm)
                                Image(systemName: "chevron.right")
                                    .font(Theme.Typography.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            .inputFieldStyle()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if draft.customerID != nil {
                            Button {
                                draft.customerID = nil
                                draft.jobID = nil
                                customerName = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.textTertiary)
                                    .iconTapTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove the customer")
                        }
                    }
                }
                if draft.customerID != nil {
                    FormRow("Job", hint: "Optional. One of this customer's jobs.") {
                        jobPicker
                    }
                }
            }
        } else if let existing, existing.customerID != nil || existing.jobID != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if existing.customerID != nil {
                    InfoRow(label: "Customer", value: customerName ?? "Linked", systemImage: "person")
                }
                if let jobID = existing.jobID {
                    InfoRow(label: "Job", value: jobLabel(jobID), systemImage: "wrench.and.screwdriver")
                }
                Text("Only managers can change the customer or job of a task.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var jobPicker: some View {
        switch jobs {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Loading jobs…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await loadJobs()
                }
            }
        case .loaded(let list):
            Picker("Job", selection: $draft.jobID) {
                Text("No job").tag(UUID?.none)
                ForEach(list) { job in
                    Text(jobOptionTitle(job)).tag(UUID?.some(job.id))
                }
                if let jobID = draft.jobID, !list.contains(where: { $0.id == jobID }) {
                    Text(jobLabel(jobID)).tag(UUID?.some(jobID))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.glacier)
        }
    }

    private func jobOptionTitle(_ job: CustomerJobSummary) -> String {
        var title = "Job #\(job.number) · \(job.status.displayName)"
        if let start = job.scheduledStart {
            title += " · \(appState.clock.shortDayText(start))"
        }
        return title
    }

    private func jobLabel(_ jobID: UUID) -> String {
        if let job = jobs.value?.first(where: { $0.id == jobID }) {
            return "Job #\(job.number)"
        }
        return "A job"
    }

    // MARK: - Loading

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let existing {
            draft = OpsTask.Draft(task: existing)
            if let dueAt = existing.dueAt {
                hasDue = true
                due = dueAt
            } else {
                due = defaultDue()
            }
        } else {
            // A technician's new task is theirs by default.
            if !isManager { draft.assigneeMemberID = appState.member?.id }
            due = defaultDue()
        }
    }

    /// Tomorrow at 9:00 in the shop's time zone.
    private func defaultDue() -> Date {
        let clock = appState.clock
        let tomorrow = clock.addingDays(1, to: clock.startOfDay(Date()))
        return clock.calendar.date(byAdding: .hour, value: 9, to: tomorrow) ?? tomorrow
    }

    private func loadReferences() async {
        guard let shopID = appState.shop?.id else { return }
        if members.isEmpty {
            await loadTeam()
        }
        if let customerID = draft.customerID ?? existing?.customerID, customerName == nil,
           let names = try? await OpsTaskService.customerNames(shopID: shopID, ids: [customerID]) {
            customerName = names[customerID]
        }
    }

    /// Reads the team for the "For" picker when the list passed none; a
    /// failure is shown with a retry.
    private func loadTeam() async {
        guard let shopID = appState.shop?.id else { return }
        team = .loading
        let result = await LoadState<[TeamDirectoryEntry]>.result {
            try await TeamService.directory(shopID: shopID)
        }
        // (cancelled: back to idle, so nothing claims the team is empty)
        team = result
    }

    private func loadJobs() async {
        guard isManager, let customerID = draft.customerID, let shopID = appState.shop?.id else {
            jobs = .idle
            return
        }
        jobs = .loading
        let result = await LoadState<[CustomerJobSummary]>.result {
            try await CustomerService.jobs(shopID: shopID, customerID: customerID)
        }
        // A linked job older than the list stays selected (the picker adds it).
        jobs.apply(result)
    }

    private func choose(_ customer: JobCustomer) {
        if draft.customerID != customer.id {
            draft.jobID = nil
        }
        draft.customerID = customer.id
        customerName = customer.displayName
        pickingCustomer = false
    }

    // MARK: - Save / delete

    private func save() async {
        showValidation = true
        errorMessage = nil
        var payload = draft
        payload.dueAt = hasDue ? due : nil
        if let problem = payload.validationError {
            errorMessage = problem
            return
        }
        do {
            let shopID = try appState.requireShopID()
            let saved: OpsTask
            if let existing {
                saved = try await OpsTaskService.update(shopID: shopID, taskID: existing.id, draft: payload)
                toasts.show("Task saved")
            } else {
                saved = try await OpsTaskService.create(shopID: shopID, draft: payload)
                toasts.show("Task added")
            }
            onChange(.saved(saved))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func confirmDelete() {
        guard let existing else { return }
        confirmation = ConfirmationRequest(
            title: "Delete this task?",
            message: existing.title,
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await OpsTaskService.delete(shopID: shopID, taskID: existing.id)
                toasts.show("Task deleted")
                onChange(.deleted(existing.id))
                dismiss()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

extension OpsTaskEditorSheet {
    /// Customer search for linking a task (managers+).
    struct CustomerPicker: View {
        let onPick: (JobCustomer) -> Void

        @Environment(AppState.self) private var appState
        @State private var search = ""
        @State private var results: LoadState<[JobCustomer]> = .idle

        var body: some View {
            VStack(spacing: 0) {
                SearchBar(text: $search, prompt: "Name, phone or email")
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.sm)
                content
                    .frame(maxHeight: .infinity)
            }
            .screenBackground()
            .navigationTitle("Choose customer")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: search) {
                // Debounce typing a little.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await runSearch()
            }
        }

        @ViewBuilder
        private var content: some View {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Find a customer",
                    message: "Type at least two letters of a name, or part of a phone number or email."
                )
            } else {
                switch results {
                case .idle, .loading:
                    LoadingStateView(label: "Searching…")
                case .failed(let message):
                    ErrorStateView(message: message, retry: { await runSearch() })
                case .loaded(let customers):
                    if customers.isEmpty {
                        EmptyStateView(systemImage: "person.crop.circle.badge.questionmark", title: "No matches", message: "Try another name or number.")
                    } else {
                        List(customers) { customer in
                            Button {
                                onPick(customer)
                            } label: {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(customer.displayName)
                                        .font(Theme.Typography.bodyEmphasis)
                                        .foregroundStyle(Theme.textPrimary)
                                    if let detail = detail(customer) {
                                        Text(detail)
                                            .font(Theme.Typography.footnote)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .themedRow()
                        }
                        .listStyle(.plain)
                    }
                }
            }
        }

        private func detail(_ customer: JobCustomer) -> String? {
            let parts = [customer.phone.map { PhoneNumber.format($0) }, customer.email?.trimmedNonEmpty].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private func runSearch() async {
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, let shopID = appState.shop?.id else {
                results = .idle
                return
            }
            results = .loading
            let result = await LoadState<[JobCustomer]>.result {
                try await JobService.searchCustomers(shopID: shopID, term: term)
            }
            guard term == search.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = result
        }
    }
}
