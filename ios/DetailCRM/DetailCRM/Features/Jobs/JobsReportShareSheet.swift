//
//  JobsReportShareSheet.swift
//  DetailCRM
//
//  "Send report" (P-8): publish the customer-facing job report — the
//  photos marked visible to the customer (of the chosen kinds), the
//  inspections (the customer can sign an unsigned pre-inspection remotely)
//  and the job's customer-visible documents — then text / email the link
//  with the shop's "job report" message, or share the link yourself.
//  Publishing again keeps the same link; "Stop sharing" revokes it.
//

import SwiftUI
import DetailCore

struct JobsReportShareSheet: View {
    let model: JobDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var includeInspections = true
    @State private var kinds: Set<JobPhotoKind> = [.before, .after]
    @State private var message = ""
    @State private var channel: ChannelChoice = .none
    @State private var errorMessage: String?
    @State private var publishedLink: URL?
    @State private var confirmation: ConfirmationRequest?
    @State private var didPrefill = false

    /// How the link goes out.
    enum ChannelChoice: Hashable {
        case none
        case all
        case sms
        case email
    }

    private var report: JobsReport? { model.report.value ?? nil }
    private var photos: [JobPhotoItem] { model.photos.value ?? [] }

    var body: some View {
        NavigationStack {
            FormScreen {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                statusBlock
                photosBlock
                FormRow("Inspections") {
                    Toggle("Include inspections", isOn: $includeInspections)
                        .tint(Theme.glacier)
                }
                FormRow("Note to the customer (optional)", hint: "Shown at the top of the report. Up to 2,000 characters.") {
                    TextField("Thanks for choosing us!", text: $message, axis: .vertical)
                        .lineLimit(2...6)
                        .inputFieldStyle()
                }
                FormRow("Send the link", hint: "Uses your \"Job report\" message template. Choose \"Don't send\" to share the link yourself.") {
                    Picker("Send", selection: $channel) {
                        Text("Don't send").tag(ChannelChoice.none)
                        Text("Text and email").tag(ChannelChoice.all)
                        Text("Text only").tag(ChannelChoice.sms)
                        Text("Email only").tag(ChannelChoice.email)
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                }
                AsyncButton(report == nil ? "Publish report" : "Update report", style: .themePrimary) {
                    await publish()
                }
                .disabled(kinds.isEmpty && !includeInspections)
                if let link = publishedLink ?? report?.link {
                    ShareLink(item: link) {
                        Label("Share the link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themeSecondary)
                }
                if let report, model.permissions.role.isManagerOrAbove {
                    Button("Stop sharing this report", role: .destructive) { confirmRevoke(report) }
                        .buttonStyle(.themePlain)
                }
            }
            .navigationTitle("Customer report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmation($confirmation)
            .onAppear(perform: prefill)
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private var statusBlock: some View {
        if let report {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Published " + appState.clock.dateTimeText(report.publishedAt), systemImage: "checkmark.seal")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.success)
                Text(report.firstViewedAt != nil ? "The customer has opened it." : "Not opened by the customer yet.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if report.link == nil {
                    Text("Set the web app address in Config.plist to share links from this iPhone.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .cardStyle()
        }
    }

    private var photosBlock: some View {
        let visible = photos.filter { $0.photo.isCustomerVisible && kinds.contains($0.photo.kind) }.count
        let hidden = photos.filter { !$0.photo.isCustomerVisible && kinds.contains($0.photo.kind) }
        return FormRow("Photos and videos", hint: "Only items marked visible to the customer are shown.") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach([JobPhotoKind.before, .after, .inspection, .other]) { kind in
                    Toggle(kind.displayName, isOn: kindBinding(kind))
                        .tint(Theme.glacier)
                }
                Text(visible == 1 ? "1 item will be shown." : "\(visible) items will be shown.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if !hidden.isEmpty {
                    AsyncButton("Show the other \(hidden.count) to the customer", style: .themeSecondaryCompact) {
                        await showAll(hidden.map(\.id))
                    }
                }
            }
        }
    }

    private func kindBinding(_ kind: JobPhotoKind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind) },
            set: { on in
                if on { kinds.insert(kind) } else { kinds.remove(kind) }
            }
        )
    }

    // MARK: - Actions

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let report {
            includeInspections = report.includeInspections
            kinds = Set(report.photoKinds.compactMap(JobPhotoKind.init(rawValue:)))
            message = report.message ?? ""
        }
    }

    private func showAll(_ ids: [UUID]) async {
        do {
            try await model.setPhotosVisible(ids, visible: true)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func publish() async {
        errorMessage = nil
        let ordered = [JobPhotoKind.before, .after, .inspection, .other].filter { kinds.contains($0) }
        let send = channel != .none
        let pick: JobMessageChannel?
        switch channel {
        case .sms: pick = .sms
        case .email: pick = .email
        default: pick = nil
        }
        do {
            let published = try await model.publishReport(
                includeInspections: includeInspections,
                photoKinds: ordered,
                message: message.trimmedNonEmpty,
                send: send,
                channel: pick
            )
            if let text = published.url, let url = URL(string: text) {
                publishedLink = url
            }
            if send && published.queued {
                toasts.show("Report published and sent to the customer")
            } else if send {
                toasts.show(
                    published.url == nil
                        ? "Report published. Links can't be sent until the web app address is set up."
                        : "Report published. Nothing was sent: the \"Job report\" message is off or the customer can't be reached.",
                    style: .info,
                    duration: .seconds(7)
                )
            } else {
                toasts.show("Report published")
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func confirmRevoke(_ report: JobsReport) {
        confirmation = ConfirmationRequest(
            title: "Stop sharing this report?",
            message: "The link stops working. Publishing again creates a new link.",
            confirmTitle: "Stop sharing",
            isDestructive: true
        ) {
            do {
                try await model.revokeReport(report)
                publishedLink = nil
                toasts.show("The report link no longer works")
            } catch {
                toasts.showError(error)
            }
        }
    }
}
