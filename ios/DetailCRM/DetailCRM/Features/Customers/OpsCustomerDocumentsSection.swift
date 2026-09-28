//
//  OpsCustomerDocumentsSection.swift
//  DetailCRM
//
//  Files on a customer (P-25): signed waivers, fleet agreements, insurance
//  paperwork — PDFs, Word / Excel files, text and images up to 25 MB,
//  picked from Files. The list also shows the files attached to the
//  customer's jobs (filed under the customer by the server). Tap a file to
//  open it in Quick Look. Managers and up add files, choose which ones the
//  customer sees in the client portal, and remove them.
//
//  Uses the shared document model and service (jobs agent) read-only.
//

import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import DetailCore

struct OpsCustomerDocumentsSection: View {
    let customerID: UUID
    /// Managers and up: upload, visibility, remove.
    let canManage: Bool

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<[JobsDocument]> = .idle
    @State private var showingImporter = false
    @State private var isUploading = false
    @State private var opening: UUID?
    @State private var previewURL: URL?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        CustomersSectionCard(
            "Documents",
            actionTitle: canManage && !isUploading ? "Add" : nil,
            action: canManage ? startImport : nil
        ) {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: { await load() })
            case .loaded(let documents):
                if isUploading {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView().tint(Theme.glacier)
                        Text("Uploading…")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                }
                if documents.isEmpty {
                    CustomersSectionStatusRow(kind: .empty(canManage
                        ? "No files yet. Add waivers, agreements or photos of paperwork (PDF, Word, Excel, text or images up to 25 MB)."
                        : "No files yet."))
                } else {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        if index > 0 { CustomersRowDivider() }
                        row(document)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: JobsDocumentsSection.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            imported(result)
        }
        .quickLookPreview($previewURL)
        .confirmation($confirmation)
        .task(id: customerID) { await load() }
    }

    private func startImport() {
        showingImporter = true
    }

    private func row(_ document: JobsDocument) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                Task { await open(document) }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: document.systemImage)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.glacier)
                        .frame(width: Theme.Size.rowIcon)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(document.fileName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(detail(document))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if opening == document.id {
                        ProgressView().tint(Theme.glacier)
                    }
                }
                .frame(minHeight: Theme.Size.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(opening != nil)
            .accessibilityHint("Opens the file")
            if canManage {
                Menu {
                    Button(document.customerVisible ? "Hide from customer" : "Show to customer",
                           systemImage: document.customerVisible ? "eye.slash" : "eye") {
                        Task { await setVisible(document, !document.customerVisible) }
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        confirmDelete(document)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(document.fileName)")
            }
        }
    }

    private func detail(_ document: JobsDocument) -> String {
        var parts = [document.detailText, appState.clock.shortDayText(document.createdAt)]
        if document.jobID != nil { parts.append("From a job") }
        if document.customerVisible { parts.append("Customer can see") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading & actions

    private func load() async {
        guard let shopID = appState.shop?.id else { return }
        state.beginLoading()
        let id = customerID
        let result = await LoadState<[JobsDocument]>.result {
            try await JobsDocumentService.list(shopID: shopID, owner: .customer(id))
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    private func imported(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            toasts.showError(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                toasts.show("That file couldn't be read.", style: .error)
                return
            }
            let name = url.lastPathComponent
            let id = customerID
            isUploading = true
            Task {
                defer { isUploading = false }
                do {
                    let shopID = try appState.requireShopID()
                    let document = try await JobsDocumentService.upload(
                        shopID: shopID,
                        owner: .customer(id),
                        data: data,
                        fileName: name
                    )
                    var documents = state.value ?? []
                    documents.insert(document, at: 0)
                    state = .loaded(documents)
                    toasts.show("File added")
                } catch {
                    toasts.showError(error)
                }
            }
        }
    }

    private func open(_ document: JobsDocument) async {
        opening = document.id
        defer { opening = nil }
        do {
            previewURL = try await JobsDocumentService.downloadForPreview(document)
        } catch {
            toasts.showError(error)
        }
    }

    private func setVisible(_ document: JobsDocument, _ visible: Bool) async {
        do {
            let shopID = try appState.requireShopID()
            let updated = try await JobsDocumentService.setCustomerVisible(shopID: shopID, documentID: document.id, visible: visible)
            replace(updated)
            toasts.show(visible ? "The customer can now see this file" : "Hidden from the customer")
        } catch {
            toasts.showError(error)
        }
    }

    private func replace(_ document: JobsDocument) {
        guard var documents = state.value, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index] = document
        state = .loaded(documents)
    }

    private func confirmDelete(_ document: JobsDocument) {
        confirmation = ConfirmationRequest(
            title: "Remove this file?",
            message: document.jobID == nil
                ? document.fileName
                : "\(document.fileName)\n\nIt is also removed from the job it was added to.",
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                try await JobsDocumentService.delete(document)
                if let documents = state.value {
                    state = .loaded(documents.filter { $0.id != document.id })
                }
                toasts.show("File removed")
            } catch {
                toasts.showError(error)
            }
        }
    }
}
