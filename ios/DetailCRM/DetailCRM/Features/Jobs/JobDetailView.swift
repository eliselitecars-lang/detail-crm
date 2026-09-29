//
//  JobDetailView.swift
//  DetailCRM
//
//  The job screen: status + stepper, any requirement overrides (who moved
//  it past required checklist items / photos, when and why), customer &
//  vehicle, schedule and crew (with the repeat rule of a recurring visit),
//  job details (custom fields), services with server totals, the money
//  picture, checklist, photos and videos, the customer job report,
//  inspections, documents, forms, customer texts, notes and activity. Realtime changes to the job
//  refresh it; payment changes refresh the money picture (a payment never
//  touches the jobs row, so the jobs counter alone would leave it stale).
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
    /// The server refused to start / complete: what is missing (P-11).
    case completionBlockers(JobStatus, String)
    /// Publish / send the customer job report (P-8).
    case report

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
        case .completionBlockers(let status, _): return "blockers-" + status.rawValue
        case .report: return "report"
        }
    }
}

struct JobDetailView: View {
    let jobID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(JobsRealtimeHub.self) private var realtime
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
        .onChange(of: model.jobRemoved) { _, removed in
            // A series edit replaced or removed this visit.
            if removed { dismiss() }
        }
        // Someone else changed a job (Realtime): refresh this one quietly.
        .onChange(of: realtime.revision(.jobs)) { _, _ in
            guard model.detail.value != nil, sheet == nil else { return }
            Task {
                await model.loadDetail()
                // A status change elsewhere may have been an override.
                await model.loadGateOverrides()
            }
        }
        // A payment landed or changed (a texted deposit / pay link paid, the
        // webhook settled a card, someone collected elsewhere). Payments
        // never touch the jobs row, so the jobs counter doesn't move: re-read
        // the money picture (deposit due, balance, the collect actions).
        // Harmless while a sheet is open: it only refreshes the summary.
        .onChange(of: realtime.revision(.payments)) { _, _ in
            guard model.detail.value != nil else { return }
            Task { await model.loadPayment() }
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
                    gateOverridesSection
                    partiesSection(snapshot)
                    scheduleSection(snapshot)
                    customDataSection
                    servicesSection(snapshot)
                    moneySection(snapshot)
                    checklistSection
                    photosSection
                    reportSection
                    inspectionsSection(snapshot)
                    documentsSection
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

    /// Who moved the job past its required checklist / photos, and why.
    private var gateOverridesSection: AnyView {
        AnyView(JobsGateOverridesNotice(model: model, clock: appState.clock))
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
                onEditAssignees: { sheet = .assignees },
                series: model.series,
                onEndSeries: permissions.canEditJob && snapshot.job.isSeriesOccurrence ? confirmEndSeries : nil
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
                onCreateInvoice: { await createInvoice() },
                showsDepositFollowups: permissions.role.isManagerOrAbove
            )
        )
    }

    private var customDataSection: AnyView {
        AnyView(JobsCustomDataSection(model: model, canEdit: permissions.canEditJob))
    }

    private var documentsSection: AnyView {
        AnyView(JobsDocumentsSection(model: model, permissions: permissions))
    }

    /// The customer job report (P-8): status and "Send report".
    private var reportSection: AnyView {
        guard permissions.canShareReport else { return AnyView(EmptyView()) }
        let report = model.report.value ?? nil
        return AnyView(
            JobSectionCard("Customer report") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if let report {
                        Label(
                            report.firstViewedAt != nil ? "Shared · opened by the customer" : "Shared · not opened yet",
                            systemImage: report.firstViewedAt != nil ? "eye" : "paperplane"
                        )
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("Share before/after photos, inspections and files with the customer on one page.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        sheet = .report
                    } label: {
                        Label(report == nil ? "Send report" : "Update or resend", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                }
            }
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
        case .completionBlockers(let target, let message):
            return AnyView(JobsCompletionBlockersView(model: model, target: target, serverMessage: message))
        case .report:
            return AnyView(JobsReportShareSheet(model: model))
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
            let recorded = try await model.changeStatus(to: target)
            if recorded > 0 {
                toasts.show(
                    "Job is now \(target.displayName.lowercased()). " + JobDetailView.recordedPaymentsText(recorded),
                    style: .info,
                    duration: .seconds(6)
                )
            } else {
                toasts.show("Job is now \(target.displayName.lowercased()).")
            }
        } catch {
            await handleStatusError(error, target: target)
        }
    }

    /// A completion-gate refusal opens the list of what's missing (with the
    /// manager override); anything else is a toast.
    private func handleStatusError(_ error: Error, target: JobStatus) async {
        guard JobDetailModel.isCompletionGateError(error), JobsCompletionBlockers.isGated(target) else {
            toasts.showError(error)
            return
        }
        let message = ErrorText.message(for: error)
        if let blockers = try? await model.completionBlockers(), !blockers.blocks(target) {
            // Something else refused the change; say what the server said.
            toasts.show(message, style: .error, duration: .seconds(6))
            return
        }
        sheet = .completionBlockers(target, message)
    }

    private func confirmEndSeries() {
        confirmation = ConfirmationRequest(
            title: "End the series after this visit?",
            message: "Later visits that are still only scheduled are removed. Confirmed, paid or invoiced visits stay on the calendar.",
            confirmTitle: "End series",
            isDestructive: true
        ) {
            do {
                let outcome = try await model.endSeriesAfterThis(clock: appState.clock)
                toasts.show("Series ended. " + outcome.text(verb: "removed"), style: .info, duration: .seconds(6))
            } catch {
                toasts.showError(error)
            }
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

extension JobDetailView {
    /// Said after cancelling / no-show when releasing the job's card
    /// payments found money that had already gone through.
    static func recordedPaymentsText(_ count: Int) -> String {
        count == 1
            ? "A card payment for this job had already gone through; it's recorded on the job."
            : "\(count) card payments for this job had already gone through; they're recorded on the job."
    }
}
