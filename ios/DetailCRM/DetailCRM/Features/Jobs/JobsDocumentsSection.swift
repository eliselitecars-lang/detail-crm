//
//  JobsDocumentsSection.swift
//  DetailCRM
//
//  Files on the job (P-25): PDFs, Word / Excel files, text and images up to
//  25 MB, picked from Files. Tap one to open it in Quick Look. Managers
//  choose which files the customer sees (job report, booking page, client
//  portal); staff on the job add files and remove their own uploads.
//

import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import DetailCore

struct JobsDocumentsSection: View {
    let model: JobDetailModel
    let permissions: JobDetailPermissions

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var showingImporter = false
    @State private var isUploading = false
    @State private var opening: UUID?
    @State private var previewURL: URL?
    @State private var confirmation: ConfirmationRequest?

    /// File types offered by the picker (the documents bucket's list).
    static let importableTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .commaSeparatedText, .jpeg, .png, .heic]
        for ext in ["doc", "docx", "xls", "xlsx", "webp"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        JobSectionCard("Documents") {
            JobSectionStateView(model.documents, loadingLabel: "Loading documents…", retry: { await model.loadDocuments() }) { items in
                list(items)
            }
            if permissions.canWork {
                Button {
                    showingImporter = true
                } label: {
                    Label(isUploading ? "Uploading…" : "Add a file", systemImage: "paperclip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
                .disabled(isUploading)
                .accessibilityHint("PDF, Word, Excel, text or image, up to 25 MB")
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
    }

    @ViewBuilder
    private func list(_ items: [JobsDocument]) -> some View {
        if items.isEmpty {
            JobEmptyLine(text: "No files on this job.", systemImage: "doc")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { document in
                    row(document)
                    if document.id != items.last?.id {
                        JobDivider()
                    }
                }
            }
        }
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
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(document.detailText)
                            if document.customerVisible {
                                Label("Customer can see", systemImage: "eye")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
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
            if canDelete(document) || permissions.canManageDocumentVisibility {
                Menu {
                    if permissions.canManageDocumentVisibility {
                        Button(document.customerVisible ? "Hide from customer" : "Show to customer",
                               systemImage: document.customerVisible ? "eye.slash" : "eye") {
                            Task { await setVisible(document, !document.customerVisible) }
                        }
                    }
                    if canDelete(document) {
                        Button("Remove", systemImage: "trash", role: .destructive) { confirmDelete(document) }
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

    private func canDelete(_ document: JobsDocument) -> Bool {
        permissions.role.isManagerOrAbove || (document.uploadedBy != nil && document.uploadedBy == appState.userID && permissions.canWork)
    }

    // MARK: - Actions

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
            isUploading = true
            Task {
                defer { isUploading = false }
                do {
                    try await model.uploadDocument(data: data, fileName: name, customerVisible: false)
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
            try await model.setDocumentVisible(document, visible: visible)
            toasts.show(visible ? "The customer can now see this file" : "Hidden from the customer")
        } catch {
            toasts.showError(error)
        }
    }

    private func confirmDelete(_ document: JobsDocument) {
        confirmation = ConfirmationRequest(
            title: "Remove this file?",
            message: document.fileName,
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                try await model.deleteDocument(document)
                toasts.show("File removed")
            } catch {
                toasts.showError(error)
            }
        }
    }
}
