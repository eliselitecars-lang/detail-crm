//
//  JobDetailView.swift
//  DetailCRM
//
//  The job screen: status + stepper, customer & vehicle, schedule and
//  crew, services with server totals, the money picture, checklist,
//  photos, inspections, forms, customer texts, notes and activity.
//
//  Every section is its own view behind an AnyView seam (deep generic view
//  types on big screens overflow the stack at runtime). Sheets are driven
//  by one `JobDetailSheet` item.
//

import SwiftUI
import DetailCore

/// Sheets presented from the job screen.
enum JobDetailSheet: Identifiable, Hashable {
    case editDetails
    /// Pick a time and move an unscheduled job to this status in one save.
    case schedule(JobStatus)
    case assignees
    case lineItems
    case cancel
    case message(JobMessageTemplateKey)
    case internalNotes
    case inspection(UUID)
    case form(UUID)

    var id: String {
        switch self {
        case .editDetails: return "details"
        case .schedule(let status): return "schedule-" + status.rawValue
        case .assignees: return "assignees"
        case .lineItems: return "lines"
        case .cancel: return "cancel"
        case .message(let key): return "message-" + key.rawValue
        case .internalNotes: return "notes"
        case .inspection(let id): return "inspection-" + id.uuidString
        case .form(let id): return "form-" + id.uuidString
        }
    }
}

struct JobDetailView: View {
    let jobID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var model: JobDetailModel
    @State private var sheet: JobDetailSheet?
    @State private var confirmation: ConfirmationRequest?
    @State private var openedInvoiceID: UUID?

    init(jobID: UUID) {
        self.jobID = jobID
        _model = State(initialValue: JobDetailModel(jobID: jobID))
    }

    var body: some View {
        LoadStateView(model.detail, loadingLabel: "Loading job…", retry: { await reload() }) { snapshot in
            content(snapshot)
        }
        .screenBackground()
        .navigationTitle(model.job?.title ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.shop?.id) { await initialLoad() }
        .onAppear {
            // Back from an invoice / payment screen: refresh the money picture.
            guard model.detail.value != nil else { return }
            Task { await model.loadPayment() }
        }
        .sheet(item: $sheet) { item in
            sheetContent(item)
        }
        .confirmation($confirmation)
        .navigationDestination(item: $openedInvoiceID) { invoiceID in
            InvoiceDetailView(invoiceID: invoiceID)
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        guard configure() else { return }
        await model.loadAll()
    }

    private func reload() async {
        guard configure() else { return }
        if let message = await model.loadAll() {
            toasts.show(message, style: .error)
        }
    }

    /// Hands the active shop + role to the model; false when no shop.
    private func configure() -> Bool {
        guard let current = appState.current else {
            model.detail = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return false
        }
        model.configure(
            shopID: current.shop.id,
            role: current.role,
            policy: current.shop.policy,
            memberID: current.member.id,
            userID: appState.userID
        )
        return true
    }

    // MARK: - Content (AnyView seams at section boundaries)

    private func content(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    headerSection(snapshot)
                    partiesSection(snapshot)
                    scheduleSection(snapshot)
                    servicesSection(snapshot)
                    moneySection(snapshot)
                    checklistSection
                    photosSection
                    inspectionsSection(snapshot)
                    formsSection
                    notesSection(snapshot)
                    activitySection(snapshot)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.lg)
            }
            .refreshable { await reload() }
        )
    }

    private var permissions: JobDetailPermissions { model.permissions }

    private func headerSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobHeaderSection(
                job: snapshot.job,
                customerName: snapshot.customer?.displayName,
                clock: appState.clock,
                permissions: permissions,
                onSelectStatus: { target in requestStatus(target, job: snapshot.job) },
                onMessage: { key in sheet = .message(key) }
            )
        )
    }

    private func partiesSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobPartiesSection(
                job: snapshot.job,
                customer: snapshot.customer,
                vehicle: snapshot.vehicle,
                canOpenCustomer: permissions.canOpenCustomer
            )
        )
    }

    private func scheduleSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobScheduleSection(
                snapshot: snapshot,
                resources: model.resources,
                resourcesFailed: model.resourcesFailed,
                clock: appState.clock,
                canEdit: permissions.canEditJob,
                onEditDetails: { sheet = .editDetails },
                onEditAssignees: { sheet = .assignees }
            )
        )
    }

    private func servicesSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobServicesSection(
                job: snapshot.job,
                lines: snapshot.lineItems,
                currencyCode: appState.currencyCode,
                canEdit: permissions.canEditJob,
                invoice: model.issuedInvoice,
                refreshProblem: model.linesRefreshProblem,
                onRetryRefresh: { await model.refreshJobAndLines() },
                onEdit: { sheet = .lineItems }
            )
        )
    }

    private func moneySection(_ snapshot: JobDetailSnapshot) -> AnyView {
        guard permissions.canViewMoney else { return AnyView(EmptyView()) }
        return AnyView(
            JobMoneySection(
                state: model.payment,
                job: snapshot.job,
                currencyCode: appState.currencyCode,
                retry: { await model.loadPayment() },
                onCreateInvoice: { await createInvoice() }
            )
        )
    }

    private var checklistSection: AnyView {
        AnyView(
            JobChecklistSection(model: model, canWork: permissions.canWork, canManage: permissions.canEditJob)
        )
    }

    private var photosSection: AnyView {
        AnyView(JobPhotosSection(model: model, permissions: permissions))
    }

    private func inspectionsSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobInspectionsSection(
                model: model,
                hasVehicle: snapshot.job.vehicleID != nil,
                canWork: permissions.canWork,
                clock: appState.clock,
                onOpen: { id in sheet = .inspection(id) }
            )
        )
    }

    private var formsSection: AnyView {
        AnyView(
            JobFormsSection(
                model: model,
                canManage: permissions.canEditJob,
                clock: appState.clock,
                onOpen: { id in sheet = .form(id) }
            )
        )
    }

    private func notesSection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(
            JobNotesSection(
                job: snapshot.job,
                canEditInternal: permissions.canEditInternalNotes,
                onEditInternal: { sheet = .internalNotes }
            )
        )
    }

    private func activitySection(_ snapshot: JobDetailSnapshot) -> AnyView {
        AnyView(JobActivitySection(job: snapshot.job, clock: appState.clock))
    }

    // MARK: - Sheets

    private func sheetContent(_ item: JobDetailSheet) -> AnyView {
        switch item {
        case .editDetails:
            return AnyView(JobDetailsEditorSheet(model: model))
        case .schedule(let target):
            return AnyView(JobDetailsEditorSheet(model: model, targetStatus: target))
        case .assignees:
            return AnyView(JobAssigneesSheet(model: model))
        case .lineItems:
            return AnyView(JobLinesEditorSheet(model: model))
        case .cancel:
            return AnyView(JobCancelSheet(model: model))
        case .message(let key):
            return AnyView(JobMessageSheet(model: model, key: key))
        case .internalNotes:
            return AnyView(JobInternalNotesSheet(model: model))
        case .inspection(let id):
            return AnyView(JobInspectionSheet(model: model, inspectionID: id))
        case .form(let id):
            return AnyView(JobFormSheet(model: model, submissionID: id))
        }
    }

    // MARK: - Actions

    /// Confirms and applies a status change (cancel has its own sheet so a
    /// reason can be given).
    private func requestStatus(_ target: JobStatus, job: Job) {
        if target == .cancelled {
            sheet = .cancel
            return
        }
        // A requested / cancelled job without a time can't be scheduled,
        // confirmed (or anything later) until it has one — the database
        // rejects it. Pick the time and move the status in one save.
        if model.needsTimeFirst(for: target) {
            if permissions.canEditJob {
                sheet = .schedule(target)
            } else {
                toasts.show("Ask a manager to set a date and time for this job first.", style: .error)
            }
            return
        }
        let isBackward = job.status.transition(to: target)?.direction == .backward
        let title: String
        let message: String?
        if target == .noShow {
            title = "Mark as no-show?"
            message = "Unsigned forms on this job become void."
        } else {
            title = "Move to \(target.displayName)?"
            message = isBackward ? "This moves the job back and clears the later status times." : nil
        }
        confirmation = ConfirmationRequest(
            title: title,
            message: message,
            confirmTitle: target == .noShow ? "Mark no-show" : "Move",
            isDestructive: target == .noShow
        ) {
            await changeStatus(target)
        }
    }

    private func changeStatus(_ target: JobStatus) async {
        do {
            try await model.changeStatus(to: target)
            toasts.show("Job is now \(target.displayName.lowercased()).")
        } catch {
            toasts.showError(error)
        }
    }

    private func createInvoice() async {
        do {
            let invoiceID = try await model.createInvoice()
            toasts.show("Invoice created")
            openedInvoiceID = invoiceID
        } catch {
            toasts.showError(error)
        }
    }
}
