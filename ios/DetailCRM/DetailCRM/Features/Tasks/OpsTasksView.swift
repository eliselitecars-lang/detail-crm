//
//  OpsTasksView.swift
//  DetailCRM
//
//  Staff tasks and reminders (P-32), from More › Tasks and from task
//  notifications. Everyone sees the tasks assigned to them and the ones
//  they created; owners, admins and managers can switch to every task in
//  the shop. Open tasks are grouped Overdue / Today / Upcoming / No due
//  date (shop time zone); Done lists recently completed ones. The list
//  updates live when someone adds, assigns or completes a task (Realtime).
//
//  The server enforces who may do what (see OpsTask); the screen only
//  offers what the role allows.
//

import SwiftUI
import DetailCore

struct OpsTasksView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsRealtimeHub.self) private var realtime

    @State private var status: OpsTask.Status = .open
    @State private var scope: OpsTask.Scope = .mine
    @State private var state: LoadState<[OpsTask]> = .idle
    @State private var references = OpsTask.References()
    @State private var editor: OpsTaskEditorSheet.Mode?
    @State private var confirmation: ConfirmationRequest?
    @State private var savingIDs: Set<UUID> = []

    private var isManager: Bool { appState.role?.isManagerOrAbove ?? false }

    /// Reload key: the filters (and the shop).
    private var filterKey: String {
        "\(appState.shop?.id.uuidString ?? "-")|\(status.rawValue)|\(scope.rawValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            LoadStateView(state, loadingLabel: "Loading tasks…", retry: { await load() }) { tasks in
                content(tasks)
            }
            .frame(maxHeight: .infinity)
        }
        .screenBackground()
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .create
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
            }
        }
        .task(id: filterKey) { await load() }
        .refreshable { await load() }
        .onChange(of: realtime.revision(.tasks)) { _, _ in
            Task { await load(quietly: true) }
        }
        .sheet(item: $editor) { mode in
            OpsTaskEditorSheet(mode: mode, members: references.members) { change in
                applied(change)
            }
        }
        .confirmation($confirmation)
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Picker("Show", selection: $status) {
                ForEach(OpsTask.Status.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if isManager {
                Picker("Whose tasks", selection: $scope) {
                    ForEach(OpsTask.Scope.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ tasks: [OpsTask]) -> some View {
        if tasks.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: status == .open ? "checklist" : "checkmark.circle",
                    title: status == .open ? "Nothing to do" : "Nothing done yet",
                    message: emptyMessage,
                    actionTitle: status == .open ? "New task" : nil,
                    action: status == .open ? startNew : nil
                )
                .padding(.top, Theme.Spacing.xxl)
            }
        } else {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                list(tasks, now: context.date)
            }
        }
    }

    private var emptyMessage: String {
        switch (status, scope) {
        case (.open, .mine):
            return "Tasks assigned to you, and the ones you add for yourself, show up here."
        case (.open, .everyone):
            return "No open tasks in the shop."
        case (.done, _):
            return "Completed tasks show up here."
        }
    }

    private func startNew() {
        editor = .create
    }

    private func list(_ tasks: [OpsTask], now: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if status == .open {
                    let calendar = appState.clock.calendar
                    ForEach(OpsTask.Group.allCases) { group in
                        let members = tasks.filter { $0.group(now: now, calendar: calendar) == group }
                        if !members.isEmpty {
                            section(group.title, count: members.count, tasks: members, now: now)
                        }
                    }
                } else {
                    section("Recently done", count: tasks.count, tasks: tasks, now: now)
                    if tasks.count >= OpsTaskService.doneLimit {
                        Text("Showing the \(OpsTaskService.doneLimit) most recent.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String, count: Int, tasks: [OpsTask], now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "\(title) · \(count)")
            ForEach(tasks) { task in
                OpsTaskRow(
                    task: task,
                    references: references,
                    clock: appState.clock,
                    now: now,
                    isSaving: savingIDs.contains(task.id),
                    canDelete: canDelete(task),
                    toggleDone: { Task { await toggle(task) } },
                    edit: { editor = .edit(task) },
                    delete: { confirmDelete(task) }
                )
            }
        }
    }

    private func canDelete(_ task: OpsTask) -> Bool {
        isManager || (task.createdBy != nil && task.createdBy == appState.userID)
    }

    // MARK: - Loading

    /// `quietly`: a live refresh keeps the list on screen and never shows
    /// an error toast.
    private func load(quietly: Bool = false) async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        let currentStatus = status
        let currentScope = isManager ? scope : .mine
        let memberID = appState.member?.id
        let userID = appState.userID
        let key = filterKey
        if !quietly { state.beginLoading() }
        let result = await LoadState<[OpsTask]>.result {
            try await OpsTaskService.list(
                shopID: shopID,
                status: currentStatus,
                scope: currentScope,
                memberID: memberID,
                userID: userID
            )
        }
        guard key == filterKey else { return }
        if let message = result.errorMessage, state.value != nil, !quietly {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        if let tasks = result.value {
            references = await OpsTaskService.references(shopID: shopID, tasks: tasks, current: references)
        }
    }

    // MARK: - Actions

    private func toggle(_ task: OpsTask) async {
        guard !savingIDs.contains(task.id) else { return }
        savingIDs.insert(task.id)
        defer { savingIDs.remove(task.id) }
        do {
            let shopID = try appState.requireShopID()
            let updated = try await OpsTaskService.setDone(shopID: shopID, taskID: task.id, done: !task.isDone)
            // It moves to the other list.
            remove(updated.id)
            toasts.show(updated.isDone ? "Task done" : "Task reopened")
        } catch {
            toasts.showError(error)
        }
    }

    private func confirmDelete(_ task: OpsTask) {
        confirmation = ConfirmationRequest(
            title: "Delete this task?",
            message: task.title,
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await OpsTaskService.delete(shopID: shopID, taskID: task.id)
                remove(task.id)
                toasts.show("Task deleted")
            } catch {
                toasts.showError(error)
            }
        }
    }

    /// A save or delete from the editor, applied to the list at once (the
    /// realtime refresh follows).
    private func applied(_ change: OpsTaskEditorSheet.Change) {
        switch change {
        case .saved(let task):
            guard var tasks = state.value else { return }
            tasks.removeAll { $0.id == task.id }
            if belongsInList(task) {
                tasks.append(task)
            }
            if status == .open {
                tasks.sort(by: OpsTask.openOrder)
            } else {
                tasks.sort { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
            }
            state = .loaded(tasks)
            Task {
                if let shopID = appState.shop?.id {
                    references = await OpsTaskService.references(shopID: shopID, tasks: [task], current: references)
                }
            }
        case .deleted(let id):
            remove(id)
        }
    }

    private func belongsInList(_ task: OpsTask) -> Bool {
        guard task.isDone == (status == .done) else { return false }
        if isManager && scope == .everyone { return true }
        if let memberID = appState.member?.id, task.assigneeMemberID == memberID { return true }
        return task.assigneeMemberID == nil && task.createdBy != nil && task.createdBy == appState.userID
    }

    private func remove(_ id: UUID) {
        guard let tasks = state.value else { return }
        state = .loaded(tasks.filter { $0.id != id })
    }
}
