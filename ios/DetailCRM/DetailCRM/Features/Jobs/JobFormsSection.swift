//
//  JobFormsSection.swift
//  DetailCRM
//
//  Forms attached to the job (waivers, authorizations). Staff on the job
//  collect a signature on this device; managers attach more templates.
//  A form is void once the job is cancelled or a no-show.
//

import SwiftUI
import DetailCore

struct JobFormsSection: View {
    let model: JobDetailModel
    let canManage: Bool
    let clock: ShopClock
    let onOpen: (UUID) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var templates: [JobFormTemplateRef] = []
    @State private var templatesError: String?

    var body: some View {
        JobSectionCard("Forms") {
            JobSectionStateView(model.forms, loadingLabel: "Loading forms…", retry: { await model.loadForms() }) { forms in
                list(forms)
            }
            if canManage, let templatesError {
                JobReferenceLoadError(text: templatesError) {
                    await loadTemplates()
                }
            }
            if canManage && !attachable.isEmpty {
                attachMenu
            }
        }
        .task {
            await loadTemplates()
        }
    }

    @ViewBuilder
    private func list(_ forms: [FormSubmission]) -> some View {
        if forms.isEmpty {
            JobEmptyLine(text: "No forms on this job.", systemImage: "doc.text")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(forms) { form in
                    Button {
                        onOpen(form.id)
                    } label: {
                        JobFormRow(form: form, isVoid: isVoid, clock: clock)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var isVoid: Bool {
        guard let status = model.job?.status else { return false }
        return status == .cancelled || status == .noShow
    }

    /// Active templates not already on the job.
    private var attachable: [JobFormTemplateRef] {
        let attached = Set((model.forms.value ?? []).compactMap(\.formTemplateID))
        return templates.filter { !attached.contains($0.id) }
    }

    private var attachMenu: some View {
        Menu {
            ForEach(attachable) { template in
                Button(template.name) {
                    Task { await attach(template) }
                }
            }
        } label: {
            Label("Attach a form", systemImage: "doc.badge.plus")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.glacier)
        }
    }

    private func loadTemplates() async {
        guard canManage, let shopID = try? appState.requireShopID() else { return }
        do {
            templates = try await JobOpsService.formTemplates(shopID: shopID)
            templatesError = nil
        } catch {
            templatesError = "Form templates couldn't be loaded. " + ErrorText.message(for: error)
        }
    }

    private func attach(_ template: JobFormTemplateRef) async {
        do {
            try await model.attachForm(template.id)
            toasts.show("\(template.name) attached")
        } catch {
            toasts.showError(error)
        }
    }
}

struct JobFormRow: View {
    let form: FormSubmission
    let isVoid: Bool
    let clock: ShopClock

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: form.isSigned ? "checkmark.seal.fill" : "doc.text")
                .foregroundStyle(form.isSigned ? Theme.successInk : Theme.glacier)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(form.title)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            StatusBadge(text: badgeText, tone: badgeTone)
        }
        .frame(minHeight: Theme.Size.controlHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let signedAt = form.signedAt {
            return "Signed by \(form.signerName ?? "customer") · \(clock.dateTimeText(signedAt))"
        }
        return form.requiresSignature ? "Signature required" : "Acknowledgement"
    }

    private var badgeText: String {
        if form.isSigned { return "Signed" }
        return isVoid ? "Void" : "Unsigned"
    }

    private var badgeTone: StatusTone {
        if form.isSigned { return .success }
        return isVoid ? .neutral : .warning
    }
}

/// Reads the form and signs it on this device.
struct JobFormSheet: View {
    let model: JobDetailModel
    let submissionID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var signerName = ""
    @State private var drawing = SignatureDrawing()
    @State private var agreed = false
    @State private var errorMessage: String?

    private var form: FormSubmission? {
        model.forms.value?.first { $0.id == submissionID }
    }

    private var isVoid: Bool {
        guard let status = model.job?.status else { return false }
        return status == .cancelled || status == .noShow
    }

    var body: some View {
        NavigationStack {
            content
                .screenBackground()
                .navigationTitle(form?.title ?? "Form")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear {
                    if signerName.isEmpty {
                        signerName = model.snapshot?.customer?.displayName ?? ""
                    }
                }
        }
    }

    private var content: AnyView {
        guard let form else {
            return AnyView(EmptyStateView(systemImage: "doc.text", title: "Form not found", message: "It may have been removed."))
        }
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    Text(form.bodySnapshot)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .cardStyle()
                    signingArea(form)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.lg)
            }
        )
    }

    @ViewBuilder
    private func signingArea(_ form: FormSubmission) -> some View {
        if form.isSigned {
            JobSignedBlock(
                signerName: form.signerName,
                signedAt: form.signedAt,
                signaturePath: form.signaturePath,
                clock: appState.clock
            )
            .cardStyle()
        } else if isVoid {
            InlineMessage(text: "This form is void because the appointment was cancelled.", kind: .info)
        } else if model.permissions.canWork {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                ThemedTextField(label: "Signer name", placeholder: "Full name", text: $signerName, kind: .name)
                if form.requiresSignature {
                    SignaturePadView(drawing: $drawing, prompt: "Sign above")
                } else {
                    Toggle(isOn: $agreed) {
                        Text("The customer has read and accepts this form.")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.glacier)
                }
                AsyncButton(form.requiresSignature ? "Sign form" : "Record acceptance", style: .themePrimary) {
                    await sign(form)
                }
                .disabled(!canSubmit(form))
            }
            .cardStyle()
        } else {
            JobEmptyLine(text: "Not signed yet.", systemImage: "signature")
        }
    }

    private func canSubmit(_ form: FormSubmission) -> Bool {
        guard signerName.trimmedNonEmpty != nil else { return false }
        return form.requiresSignature ? !drawing.isEmpty : agreed
    }

    private func sign(_ form: FormSubmission) async {
        errorMessage = nil
        var png: Data?
        if form.requiresSignature {
            guard let data = drawing.pngData() else {
                errorMessage = "Sign in the box first."
                return
            }
            png = data
        }
        do {
            try await model.signForm(form.id, signerName: signerName, signaturePNG: png)
            toasts.show("Form signed")
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
