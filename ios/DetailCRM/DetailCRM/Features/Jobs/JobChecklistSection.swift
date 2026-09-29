//
//  JobChecklistSection.swift
//  DetailCRM
//
//  The job's checklist. Staff on the job tick items (optimistic, rolled
//  back if the server refuses); managers add one-off items, remove items,
//  flag items as required and apply checklist templates. Required items
//  must be done before the job can be completed (P-11, enforced by the
//  server; a manager can override from the status control).
//

import SwiftUI
import DetailCore

struct JobChecklistSection: View {
    let model: JobDetailModel
    let canWork: Bool
    let canManage: Bool

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var newItem = ""
    @State private var templates: [JobChecklistTemplateRef] = []
    @State private var templatesError: String?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        JobSectionCard("Checklist") {
            JobSectionStateView(model.checklist, loadingLabel: "Loading checklist…", retry: { await model.loadChecklist() }) { items in
                itemsView(items)
            }
            if canManage && model.checklist.value != nil {
                managerControls
            }
        }
        .task {
            await loadTemplates()
        }
        .confirmation($confirmation)
    }

    // MARK: - Items

    @ViewBuilder
    private func itemsView(_ items: [JobChecklistItem]) -> some View {
        if items.isEmpty {
            JobEmptyLine(text: "No checklist on this job.", systemImage: "checklist")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                progressLine(items)
                ForEach(items) { item in
                    JobChecklistRow(
                        item: item,
                        isPending: model.pendingChecklist.contains(item.id),
                        canToggle: canWork,
                        onToggle: { toggle(item) },
                        onToggleRequired: canManage ? { toggleRequired(item) } : nil,
                        onDelete: canManage ? { confirmDelete(item) } : nil
                    )
                }
            }
        }
    }

    private func progressLine(_ items: [JobChecklistItem]) -> some View {
        let done = items.filter(\.isDone).count
        let openRequired = items.filter { $0.isRequired && !$0.isDone }.count
        return HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("\(done) of \(items.count) done")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(done == items.count ? Theme.successInk : Theme.textSecondary)
                if openRequired > 0 {
                    Text(openRequired == 1
                         ? "1 required item left before completing"
                         : "\(openRequired) required items left before completing")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.warningInk)
                }
            }
            Spacer()
            ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                .tint(done == items.count ? Theme.success : Theme.glacier)
                .frame(width: 96)
                .accessibilityHidden(true)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - Manager controls

    private var managerControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Add an item", text: $newItem)
                    .submitLabel(.done)
                    .onSubmit { Task { await addItem() } }
                    .inputFieldStyle()
                AsyncButton(style: .themePrimaryCompact) {
                    await addItem()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add checklist item")
                .disabled(newItem.trimmedNonEmpty == nil)
            }
            if let templatesError {
                JobReferenceLoadError(text: templatesError) {
                    await loadTemplates()
                }
            }
            if !templates.isEmpty {
                Menu {
                    ForEach(templates) { template in
                        Button(template.name) {
                            Task { await apply(template) }
                        }
                    }
                } label: {
                    Label("Apply a checklist template", systemImage: "list.bullet.clipboard")
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.glacier)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadTemplates() async {
        guard canManage, let shopID = try? appState.requireShopID() else { return }
        do {
            templates = try await JobOpsService.checklistTemplates(shopID: shopID)
            templatesError = nil
        } catch {
            templatesError = "Checklist templates couldn't be loaded. " + ErrorText.message(for: error)
        }
    }

    private func toggle(_ item: JobChecklistItem) {
        Task {
            do {
                try await model.toggleChecklistItem(item)
            } catch {
                toasts.showError(error)
            }
        }
    }

    private func toggleRequired(_ item: JobChecklistItem) {
        Task {
            do {
                try await model.setChecklistItemRequired(item, required: !item.isRequired)
            } catch {
                toasts.showError(error)
            }
        }
    }

    private func addItem() async {
        guard let label = newItem.trimmedNonEmpty else { return }
        do {
            try await model.addChecklistItem(label)
            newItem = ""
        } catch {
            toasts.showError(error)
        }
    }

    private func apply(_ template: JobChecklistTemplateRef) async {
        do {
            try await model.applyChecklistTemplate(template.id)
            toasts.show("Added \(template.name)")
        } catch {
            toasts.showError(error)
        }
    }

    private func confirmDelete(_ item: JobChecklistItem) {
        confirmation = ConfirmationRequest(
            title: "Remove this item?",
            message: item.label,
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                try await model.deleteChecklistItem(item.id)
            } catch {
                toasts.showError(error)
            }
        }
    }
}

struct JobChecklistRow: View {
    let item: JobChecklistItem
    let isPending: Bool
    let canToggle: Bool
    let onToggle: () -> Void
    var onToggleRequired: (() -> Void)? = nil
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onToggle) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(Theme.Typography.title.weight(.regular))
                        .foregroundStyle(item.isDone ? Theme.successInk : Theme.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(item.label)
                            .font(Theme.Typography.body)
                            .foregroundStyle(item.isDone ? Theme.textSecondary : Theme.textPrimary)
                            .strikethrough(item.isDone, color: Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.isRequired {
                            Text("Required")
                                .font(Theme.Typography.captionEmphasis)
                                .foregroundStyle(item.isDone ? Theme.textTertiary : Theme.warningInk)
                                .padding(.horizontal, Theme.Spacing.xs)
                                .padding(.vertical, Theme.Spacing.xxs)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.badge)
                                        .fill(Theme.fill(for: item.isDone ? .neutral : .warning))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Theme.Size.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggle || isPending)
            .accessibilityLabel(item.isRequired ? "\(item.label), required" : item.label)
            .accessibilityValue(item.isDone ? "Done" : "Not done")
            .accessibilityAddTraits(.isButton)
            if let onDelete {
                Menu {
                    if let onToggleRequired {
                        Button(item.isRequired ? "Don't require" : "Require before completing",
                               systemImage: item.isRequired ? "exclamationmark.circle" : "exclamationmark.circle.fill",
                               action: onToggleRequired)
                    }
                    Button("Remove", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.textTertiary)
                        .iconTapTarget()
                }
                .accessibilityLabel("More for \(item.label)")
            }
        }
        .opacity(isPending ? 0.6 : 1)
    }
}
