//
//  InboxTemplatePickerSheet.swift
//  DetailCRM
//
//  Send one of the shop's message templates to a customer. Job templates
//  (reminders, on-my-way, invoice…) need one of the customer's jobs; the
//  preview for a job is rendered by the server (`preview_template_message`),
//  otherwise locally from the customer's details. The server renders and
//  sends the real message through the messaging function.
//

import SwiftUI
import DetailCore

struct InboxTemplatePickerSheet: View {
    let customer: Customer
    let initialChannel: Message.Channel
    let onSent: (InboxSendResult) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var channel: Message.Channel
    @State private var state: LoadState<[InboxTemplate]> = .idle

    init(customer: Customer, initialChannel: Message.Channel, onSent: @escaping (InboxSendResult) -> Void) {
        self.customer = customer
        self.initialChannel = initialChannel
        self.onSent = onSent
        _channel = State(initialValue: initialChannel)
    }

    var body: some View {
        NavigationStack {
            LoadStateView(state, loadingLabel: "Loading templates…", retry: { await load() }) { templates in
                InboxTemplateList(
                    templates: templates.filter { $0.channel == channel },
                    channel: $channel
                )
            }
            .screenBackground()
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: InboxTemplate.self) { template in
                InboxTemplateSendView(template: template, customer: customer) { result in
                    onSent(result)
                    dismiss()
                }
            }
            .task {
                if state.value == nil { await load() }
            }
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let result = await LoadState<[InboxTemplate]>.result {
            try await MessageService.templates(shopID: shopID)
        }
        state.apply(result)
    }
}

private struct InboxTemplateList: View {
    let templates: [InboxTemplate]
    @Binding var channel: Message.Channel

    var body: some View {
        List {
            Section {
                Picker("Channel", selection: $channel) {
                    ForEach(Message.Channel.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if templates.isEmpty {
                Section {
                    Text(channel == .sms
                         ? "No text templates are turned on. Admins can enable them in Settings."
                         : "No email templates are turned on. Admins can enable them in Settings.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                }
            } else {
                Section {
                    ForEach(templates) { template in
                        NavigationLink(value: template) {
                            InboxTemplateRow(template: template)
                        }
                        .themedRow()
                    }
                } footer: {
                    Text("Job templates fill in the appointment, vehicle and links for the job you choose.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct InboxTemplateRow: View {
    let template: InboxTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(template.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                if template.requiresJob {
                    StatusBadge(text: "Needs a job", tone: .neutral)
                }
            }
            Text(template.body)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Send one template

private struct InboxTemplateSendView: View {
    let template: InboxTemplate
    let customer: Customer
    let onSent: (InboxSendResult) -> Void

    @Environment(AppState.self) private var appState

    @State private var jobs: LoadState<[CustomerJobSummary]> = .idle
    @State private var jobID: UUID?
    @State private var serverPreview: LoadState<InboxTemplatePreview?> = .idle
    @State private var sendError: String?

    var body: some View {
        FormScreen {
            AnyView(jobSection)
            AnyView(previewSection)
            VStack(spacing: Theme.Spacing.sm) {
                if let reason = blockReason {
                    InlineMessage(text: reason, kind: .info)
                }
                if let sendError {
                    InlineMessage(text: sendError, kind: .error)
                }
                AsyncButton(template.channel == .sms ? "Send text" : "Send email") {
                    await send()
                }
                .disabled(blockReason != nil)
            }
        }
        .navigationTitle(template.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadJobs()
        }
        .task(id: jobID) {
            await loadPreview()
        }
    }

    // MARK: Sections

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: template.requiresJob ? "Job" : "Job (optional)")
            switch jobs {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message)) { await loadJobs() }
            case .loaded(let list):
                if list.isEmpty {
                    InlineMessage(
                        text: template.requiresJob
                            ? "This template is about a job, and this customer has none yet."
                            : "This customer has no jobs; the message is sent without job details.",
                        kind: .info
                    )
                } else {
                    Picker("Job", selection: $jobID) {
                        if !template.requiresJob {
                            Text("No job").tag(UUID?.none)
                        } else if jobID == nil {
                            Text("Choose a job").tag(UUID?.none)
                        }
                        ForEach(list) { job in
                            Text(jobLabel(job)).tag(UUID?.some(job.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: Theme.Spacing.sm)
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Preview")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if jobID != nil {
                    switch serverPreview {
                    case .idle, .loading:
                        CustomersSectionStatusRow(kind: .loading)
                    case .failed(let message):
                        CustomersSectionStatusRow(kind: .failed(message)) { await loadPreview() }
                    case .loaded(let preview):
                        previewText(subject: preview?.subject, body: preview?.body ?? "")
                        if preview?.enabled == false {
                            InlineMessage(text: "This template is turned off.", kind: .info)
                        }
                    }
                } else {
                    previewText(
                        subject: template.subject.map { InboxComposeRules.localPreview($0, customer: customer, shop: appState.shop) },
                        body: InboxComposeRules.localPreview(template.body, customer: customer, shop: appState.shop)
                    )
                    Text("Parts in [brackets] are filled in when the message is sent.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
    }

    private func previewText(subject: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let subject = subject?.trimmedNonEmpty {
                Text(subject)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(body.isEmpty ? "(empty)" : body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Logic

    private var blockReason: String? {
        if let reason = InboxComposeRules.blockReason(channel: template.channel, customer: customer) {
            return reason
        }
        if template.requiresJob && jobID == nil {
            return "Choose a job for this template."
        }
        return nil
    }

    private func jobLabel(_ job: CustomerJobSummary) -> String {
        var text = CustomersFormatting.jobTitle(job.number)
        if let start = job.scheduledStart {
            text += " · " + appState.clock.shortDayText(start)
        }
        return text + " · " + job.status.displayName
    }

    private func loadJobs() async {
        guard let shopID = try? appState.requireShopID() else { return }
        jobs.beginLoading()
        let customerID = customer.id
        let result = await LoadState<[CustomerJobSummary]>.result {
            try await CustomerService.jobs(shopID: shopID, customerID: customerID, limit: 20)
        }
        jobs.apply(result)
        // Appointment templates pre-select the customer's next upcoming open
        // job; otherwise staff choose (never a cancelled/unscheduled guess).
        if template.requiresJob, jobID == nil, let list = result.value {
            jobID = InboxComposeRules.defaultJobID(templateKey: template.key, jobs: list, now: Date())
        }
    }

    private func loadPreview() async {
        guard let jobID else {
            serverPreview = .idle
            return
        }
        serverPreview = .loading
        let key = template.key
        let channel = template.channel
        serverPreview = await LoadState<InboxTemplatePreview?>.result {
            try await MessageService.previewTemplate(jobID: jobID, key: key, channel: channel)
        }
    }

    private func send() async {
        guard blockReason == nil, let shopID = try? appState.requireShopID() else { return }
        sendError = nil
        do {
            let result = try await MessageService.sendTemplate(
                shopID: shopID,
                customerID: customer.id,
                key: template.key,
                channel: template.channel,
                jobID: jobID
            )
            onSent(result)
        } catch {
            sendError = ErrorText.message(for: error)
        }
    }
}
