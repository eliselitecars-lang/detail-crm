//
//  JobDetailModel.swift
//  DetailCRM
//
//  State and actions for the job screen. The first pass loads the job,
//  customer, vehicle, lines, assignments and team; checklist, photos,
//  inspections, forms and the money picture load per section so one slow
//  or forbidden section never blanks the screen.
//
//  Money is never computed here: after any line/discount edit the job row
//  (server totals) and the payment summary are re-fetched.
//

import Foundation
import Observation
import Supabase
import DetailCore

/// What the signed-in member may do on this job (SPEC §3). UI gating only —
/// RLS, triggers and RPCs enforce the same rules.
struct JobDetailPermissions: Equatable {
    var role: ShopRole
    var policy: ShopPolicy
    var isAssigned: Bool
    var userID: UUID?

    /// Manager+: schedule, lines, assignments, customer-visible notes.
    var canEditJob: Bool { role.can(.editJobs, policy: policy) }
    /// Publish / send the customer job report (P-8): managers, or staff
    /// on the job when the shop lets technicians share reports.
    var canShareReport: Bool {
        role.isManagerOrAbove || (isAssigned && role.can(.shareJobReports, policy: policy))
    }
    /// Show files / photos to the customer (managers+ for documents).
    var canManageDocumentVisibility: Bool { role.isManagerOrAbove }
    /// "Staff on the job": checklist, photos, inspections, forms.
    var canWork: Bool { role.isManagerOrAbove || isAssigned }
    var canEditInternalNotes: Bool { canWork }
    /// Invoice / deposit / balance (collectors only).
    var canViewMoney: Bool {
        role.can(.manageInvoices, policy: policy)
            || (isAssigned && role.can(.collectPaymentOnAssignedJob, policy: policy))
    }
    var canOpenCustomer: Bool { role.can(.viewAllCustomers, policy: policy) }
    var canMessageCustomer: Bool {
        role.can(.sendJobTemplateMessages, policy: policy) && canWork
    }
    /// `price_services` is manager+ only.
    var canPrice: Bool { role.isManagerOrAbove }

    func statusTargets(from status: JobStatus) -> [JobStatus] {
        status.allowedTargets(role: role, isAssigned: isAssigned)
    }

    func canDelete(_ photo: JobPhoto) -> Bool {
        role.isManagerOrAbove || (photo.uploadedBy != nil && photo.uploadedBy == userID)
    }
}

@Observable
@MainActor
final class JobDetailModel {

    let jobID: UUID
    private(set) var shopID: UUID?
    private(set) var role: ShopRole = .technician
    private(set) var policy = ShopPolicy()
    private(set) var memberID: UUID?
    private(set) var userID: UUID?

    var detail: LoadState<JobDetailSnapshot> = .idle
    var payment: LoadState<JobPaymentSummary?> = .idle
    /// Bumped per money-picture read so an older read that answers late
    /// (screen reappeared and a Realtime payment change at once) can't
    /// put a stale "deposit due" back over a newer one.
    @ObservationIgnored private var paymentReadGeneration = 0
    var checklist: LoadState<[JobChecklistItem]> = .idle
    var photos: LoadState<[JobPhotoItem]> = .idle
    var inspections: LoadState<[JobInspectionBundle]> = .idle
    var forms: LoadState<[FormSubmission]> = .idle
    /// Moves past the completion gates (P-11): who skipped required
    /// checklist items or photos, when and why. Everyone on the job sees it.
    var gateOverrides: LoadState<[JobsGateOverride]> = .idle
    /// The job's live customer report (nil = none, or not visible to this
    /// member).
    var report: LoadState<JobsReport?> = .idle
    var documents: LoadState<[JobsDocument]> = .idle
    /// The shop's job fields (archived ones too, to label stored values).
    var customFields: LoadState<[JobsCustomField]> = .idle
    /// Video uploads of this job still in progress / paused (P-30).
    private(set) var pendingUploads: [JobsResumableUploader.Upload] = []
    /// Upload progress (0…1) per pending upload id.
    private(set) var uploadProgress: [UUID: Double] = [:]
    private(set) var resources: [JobResource] = []
    /// Bays/vans failed to load (the schedule card says so instead of
    /// guessing a name).
    private(set) var resourcesFailed = false
    /// Checklist items with a toggle in flight.
    private(set) var pendingChecklist: Set<UUID> = []
    /// The recurring series of this visit (managers+; nil otherwise).
    private(set) var series: JobsSeries?
    /// This visit was replaced or removed by a series edit ("this and
    /// following", end series): the screen goes back.
    private(set) var jobRemoved = false
    /// A line/discount write succeeded but re-reading the job's lines and
    /// totals failed. Shown with a Refresh button; the write is NOT retried
    /// (that would duplicate lines).
    private(set) var linesRefreshProblem: String?

    init(jobID: UUID) {
        self.jobID = jobID
    }

    // MARK: - Configuration

    func configure(shopID: UUID, role: ShopRole, policy: ShopPolicy, memberID: UUID?, userID: UUID?) {
        self.shopID = shopID
        self.role = role
        self.policy = policy
        self.memberID = memberID
        self.userID = userID
    }

    var snapshot: JobDetailSnapshot? { detail.value }
    var job: Job? { detail.value?.job }

    /// The job's issued (non-void) invoice from `job_payment_summary`, or nil
    /// when there is none or the money picture isn't loaded / visible.
    var issuedInvoice: JobIssuedInvoiceInfo? {
        guard let loaded = payment.value, let summary = loaded, let invoiceID = summary.invoiceID else { return nil }
        return JobIssuedInvoiceInfo(invoiceID: invoiceID, number: summary.invoiceNumber, totalCents: summary.totalCents)
    }

    var permissions: JobDetailPermissions {
        JobDetailPermissions(
            role: role,
            policy: policy,
            isAssigned: detail.value?.isAssigned(memberID: memberID) ?? false,
            userID: userID
        )
    }

    private func requireShop() throws -> UUID {
        guard let shopID else { throw AppError.noShopSelected }
        return shopID
    }

    // MARK: - Loading

    /// Loads (or refreshes) everything. Returns an error message when a
    /// refresh failed while content was already on screen (for a toast).
    @discardableResult
    func loadAll() async -> String? {
        let detailError = await loadDetail()
        guard detail.value != nil else { return nil }
        async let checklistError = loadChecklist()
        async let photosError = loadPhotos()
        async let inspectionsError = loadInspections()
        async let formsError = loadForms()
        async let paymentError = loadPayment()
        async let resourcesDone: Void = loadResources()
        async let documentsError = loadDocuments()
        async let fieldsDone: Void = loadCustomFields()
        async let reportDone: Void = loadReport()
        async let overridesDone: Void = loadGateOverrides()
        let errors: [String?] = [
            detailError,
            await checklistError,
            await photosError,
            await inspectionsError,
            await formsError,
            await paymentError,
            await documentsError,
        ]
        _ = await resourcesDone
        _ = await fieldsDone
        _ = await reportDone
        _ = await overridesDone
        refreshPendingUploads()
        await loadSeries()
        return errors.compactMap { $0 }.first
    }

    /// The series row behind a recurring visit (managers+ can read it).
    func loadSeries() async {
        guard let shopID, role.isManagerOrAbove, let seriesID = job?.seriesID else {
            series = nil
            return
        }
        series = try? await JobsSeriesService.series(shopID: shopID, seriesID: seriesID)
    }

    // MARK: - Report, documents, custom fields (P-8, P-25, P-9)

    /// The live report, for members who may see report links.
    func loadReport() async {
        guard let shopID, permissions.canShareReport else {
            report = .loaded(nil)
            return
        }
        report.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<JobsReport?>.result {
            try await JobsReportService.liveReport(shopID: shopID, jobID: jobID)
        }
        report.apply(result)
    }

    func publishReport(
        includeInspections: Bool,
        photoKinds: [JobPhotoKind],
        message: String?,
        send: Bool,
        channel: JobMessageChannel?
    ) async throws -> JobsReportService.Published {
        let published = try await JobsReportService.publish(
            jobID: jobID,
            includeInspections: includeInspections,
            photoKinds: photoKinds,
            message: message,
            send: send,
            channel: channel
        )
        await loadReport()
        return published
    }

    func revokeReport(_ report: JobsReport) async throws {
        try await JobsReportService.revoke(reportID: report.id)
        await loadReport()
    }

    @discardableResult
    func loadDocuments() async -> String? {
        guard let shopID else { return nil }
        let hadContent = documents.value != nil
        documents.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[JobsDocument]>.result {
            try await JobsDocumentService.list(shopID: shopID, owner: .job(jobID))
        }
        documents.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    func uploadDocument(data: Data, fileName: String, customerVisible: Bool) async throws {
        let shopID = try requireShop()
        let saved = try await JobsDocumentService.upload(
            shopID: shopID,
            owner: .job(jobID),
            data: data,
            fileName: fileName,
            customerVisible: customerVisible && permissions.canManageDocumentVisibility
        )
        documents = .loaded([saved] + (documents.value ?? []))
    }

    func setDocumentVisible(_ document: JobsDocument, visible: Bool) async throws {
        let shopID = try requireShop()
        let saved = try await JobsDocumentService.setCustomerVisible(shopID: shopID, documentID: document.id, visible: visible)
        replaceDocument(saved)
    }

    func renameDocument(_ document: JobsDocument, to name: String) async throws {
        let shopID = try requireShop()
        let saved = try await JobsDocumentService.rename(shopID: shopID, documentID: document.id, fileName: name)
        replaceDocument(saved)
    }

    func deleteDocument(_ document: JobsDocument) async throws {
        try await JobsDocumentService.delete(document)
        if let items = documents.value {
            documents = .loaded(items.filter { $0.id != document.id })
        }
    }

    private func replaceDocument(_ document: JobsDocument) {
        guard var items = documents.value, let index = items.firstIndex(where: { $0.id == document.id }) else { return }
        items[index] = document
        documents = .loaded(items)
    }

    func loadCustomFields() async {
        guard let shopID else { return }
        customFields.beginLoading()
        let result = await LoadState<[JobsCustomField]>.result {
            try await JobsCustomFieldService.allFields(shopID: shopID, entity: .job)
        }
        customFields.apply(result)
    }

    /// Saves the job's answers (managers+); the server validates them.
    func saveCustomData(_ edited: [String: JobsCustomValue]) async throws {
        let shopID = try requireShop()
        let fields = customFields.value ?? []
        let location = job?.locationType
        let editable = Set(fields.filter { $0.isEditable(onJobAt: location) }.map(\.key))
        let data = JobsCustomFieldService.mergedData(original: job?.customData, edited: edited, editableKeys: editable)
        let updated = try await JobService.updateCustomData(shopID: shopID, jobID: jobID, data: data)
        replaceJob(updated)
    }

    // MARK: - Customer visibility of photos (P-8)

    func setPhotosVisible(_ photoIDs: [UUID], visible: Bool) async throws {
        try await JobOpsService.setPhotoVisibility(photoIDs: photoIDs, visible: visible)
        guard var items = photos.value else { return }
        let ids = Set(photoIDs)
        for index in items.indices where ids.contains(items[index].id) {
            items[index].photo.customerVisible = visible
        }
        photos = .loaded(items)
    }

    // MARK: - Videos (P-30)

    /// The signed-in user's unfinished uploads for this job (another
    /// account's recordings on this iPhone are never listed or resumed).
    func refreshPendingUploads() {
        pendingUploads = JobsResumableUploader.pending(jobID: jobID, userID: userID)
    }

    /// Queues a recorded video (copied into the app's storage) and uploads
    /// it: the file with the resumable protocol, a poster frame, then the
    /// job_photos row. An interrupted upload stays listed with Resume.
    func uploadVideo(fileURL: URL, durationSeconds: Int, posterJPEG: Data?, kind: JobPhotoKind) async throws {
        let shopID = try requireShop()
        guard let userID else { throw AppError.message("Sign in again to add videos.") }
        let base = "v-" + UUID().uuidString.lowercased()
        let ext = fileURL.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        let objectName = "\(shopID.uuidString.lowercased())/\(jobID.uuidString.lowercased())/\(base).\(ext)"
        var metadata = [
            "duration": String(max(1, durationSeconds)),
            "kind": kind.rawValue,
            "posterName": base + "-poster.jpg",
        ]
        if posterJPEG == nil { metadata["posterName"] = nil }
        let upload = try JobsResumableUploader.prepare(
            fileAt: fileURL,
            userID: userID,
            shopID: shopID,
            jobID: jobID,
            bucket: JobOpsService.mediaBucket,
            objectName: objectName,
            contentType: ext == "mp4" ? "video/mp4" : "video/quicktime",
            metadata: metadata
        )
        if let posterJPEG {
            // Kept next to the video so a resumed upload still has it.
            try? posterJPEG.write(to: JobsResumableUploader.posterURL(for: upload))
        }
        refreshPendingUploads()
        try await finishUpload(upload)
    }

    /// Sends (or resumes) a pending video upload and records it on the job.
    func finishUpload(_ upload: JobsResumableUploader.Upload) async throws {
        let uploadID = upload.id
        // Only the account that recorded it may send it (its uploader
        // gets the row's delete rights).
        guard let userID, upload.userID == userID else {
            throw AppError.message("This video was recorded by another account on this iPhone.")
        }
        // One run per upload at a time (set before the first suspension).
        guard uploadProgress[uploadID] == nil else { return }
        uploadProgress[uploadID] = 0
        defer { uploadProgress[uploadID] = nil }
        let token = try await Supa.client.auth.session.accessToken
        try await JobsResumableUploader.run(upload, accessToken: token) { [weak self] fraction in
            Task { @MainActor [weak self] in self?.uploadProgress[uploadID] = fraction }
        }
        var posterPath: String?
        let posterFile = JobsResumableUploader.posterURL(for: upload)
        if let name = upload.metadata["posterName"], let data = try? Data(contentsOf: posterFile) {
            posterPath = try? await JobOpsService.uploadPoster(shopID: upload.shopID, jobID: upload.jobID, name: name, jpegData: data)
        }
        let kind = JobPhotoKind(rawValue: upload.metadata["kind"] ?? "") ?? .other
        let duration = Int(upload.metadata["duration"] ?? "") ?? 1
        let photo = try await JobOpsService.insertVideo(
            shopID: upload.shopID,
            jobID: upload.jobID,
            storagePath: upload.objectName,
            posterPath: posterPath,
            durationSeconds: duration,
            kind: kind
        )
        JobsResumableUploader.discard(upload)
        refreshPendingUploads()
        var url: URL?
        if let posterPath {
            url = try? await JobOpsService.signedURL(bucket: JobOpsService.photosBucket, path: posterPath)
        }
        photos = .loaded((photos.value ?? []) + [JobPhotoItem(photo: photo, url: url)])
    }

    /// Drops a pending upload that can't or shouldn't finish.
    func discardUpload(_ upload: JobsResumableUploader.Upload) {
        JobsResumableUploader.discard(upload)
        refreshPendingUploads()
    }

    // MARK: - Recurring series (P-1)

    /// "This and following": applies the edited time of day, length,
    /// place, bay / van and notes to this visit and the later ones that are
    /// still plain scheduled visits. Eligible visits (this one included)
    /// are replaced on their own dates; when this visit was replaced the
    /// screen goes back. A new date or deposit would be lost that way, so
    /// such an edit is refused here (the editor offers "this visit only").
    func updateSeriesFollowing(_ patch: JobDetailsPatch, clock: ShopClock) async throws -> JobsSeriesService.Outcome {
        guard let job, let seriesID = job.seriesID else {
            throw AppError.message("This job isn't part of a repeating series.")
        }
        if let limit = JobsSeriesDraft.followingScopeLimit(
            originalStart: job.scheduledStart,
            newStart: patch.scheduledStart,
            originalDepositCents: job.depositRequiredCents,
            newDepositCents: patch.depositRequiredCents,
            calendar: clock.calendar
        ) {
            throw AppError.message(limit)
        }
        var json: [String: AnyJSON] = [
            "location_type": .string(patch.locationType.rawValue),
            "service_address_line1": patch.serviceAddressLine1.map { AnyJSON.string($0) } ?? .null,
            "service_address_line2": patch.serviceAddressLine2.map { AnyJSON.string($0) } ?? .null,
            "service_city": patch.serviceCity.map { AnyJSON.string($0) } ?? .null,
            "service_region": patch.serviceRegion.map { AnyJSON.string($0) } ?? .null,
            "service_postal_code": patch.servicePostalCode.map { AnyJSON.string($0) } ?? .null,
            "resource_id": patch.resourceID.map { AnyJSON.string($0.uuidString) } ?? .null,
            "notes": patch.notes.map { AnyJSON.string($0) } ?? .null,
        ]
        if let start = patch.scheduledStart, let end = patch.scheduledEnd {
            json["local_start"] = .string(JobsSeriesDraft.timeString(start, calendar: clock.calendar))
            json["duration_minutes"] = .integer(max(15, Int(end.timeIntervalSince(start) / 60)))
        }
        let outcome = try await JobsSeriesService.update(seriesID: seriesID, patch: json, fromJobID: job.id)
        await refreshAfterSeriesChange()
        return outcome
    }

    /// Ends the series after this visit (later plain visits are removed).
    func endSeriesAfterThis(clock: ShopClock) async throws -> JobsSeriesService.Outcome {
        guard let job, let seriesID = job.seriesID else {
            throw AppError.message("This job isn't part of a repeating series.")
        }
        let day = JobsSeriesDraft.dayString(job.scheduledStart ?? Date(), calendar: clock.calendar)
        let outcome = try await JobsSeriesService.end(seriesID: seriesID, afterDay: day)
        await refreshAfterSeriesChange()
        return outcome
    }

    /// Re-reads the job after a series change; notes when it's gone.
    private func refreshAfterSeriesChange() async {
        guard let shopID else { return }
        do {
            let fresh = try await JobService.job(shopID: shopID, jobID: jobID)
            replaceJob(fresh)
            await loadSeries()
        } catch let error as AppError where error == .notFound("That job") {
            jobRemoved = true
        } catch {
            // The change is saved; the next pull to refresh shows it.
        }
    }

    @discardableResult
    func loadDetail() async -> String? {
        guard let shopID else { return nil }
        let hadContent = detail.value != nil
        detail.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<JobDetailSnapshot>.result {
            try await JobService.detail(shopID: shopID, jobID: jobID)
        }
        detail.apply(result)
        if result.value != nil {
            linesRefreshProblem = nil
        }
        return hadContent ? result.errorMessage : nil
    }

    @discardableResult
    func loadPayment() async -> String? {
        guard permissions.canViewMoney else {
            payment = .loaded(nil)
            return nil
        }
        let hadContent = payment.value != nil
        payment.beginLoading()
        paymentReadGeneration += 1
        let generation = paymentReadGeneration
        let jobID = self.jobID
        let result = await LoadState<JobPaymentSummary?>.result {
            try await JobService.paymentSummary(jobID: jobID)
        }
        // A newer read started meanwhile: its answer wins.
        guard generation == paymentReadGeneration else { return nil }
        payment.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    @discardableResult
    func loadChecklist() async -> String? {
        guard let shopID else { return nil }
        let hadContent = checklist.value != nil
        checklist.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[JobChecklistItem]>.result {
            try await JobOpsService.checklist(shopID: shopID, jobID: jobID)
        }
        checklist.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    @discardableResult
    func loadPhotos() async -> String? {
        guard let shopID else { return nil }
        let hadContent = photos.value != nil
        photos.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[JobPhotoItem]>.result {
            try await JobOpsService.photoItems(shopID: shopID, jobID: jobID)
        }
        photos.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    @discardableResult
    func loadInspections() async -> String? {
        guard let shopID else { return nil }
        let hadContent = inspections.value != nil
        inspections.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[JobInspectionBundle]>.result {
            try await JobOpsService.inspections(shopID: shopID, jobID: jobID)
        }
        inspections.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    @discardableResult
    func loadForms() async -> String? {
        guard let shopID else { return nil }
        let hadContent = forms.value != nil
        forms.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[FormSubmission]>.result {
            try await JobOpsService.forms(shopID: shopID, jobID: jobID)
        }
        forms.apply(result)
        return hadContent ? result.errorMessage : nil
    }

    /// The job's completion-gate overrides (secondary: a failure shows a
    /// retry line on the notice, never blanks the job).
    func loadGateOverrides() async {
        guard let shopID else { return }
        gateOverrides.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<[JobsGateOverride]>.result {
            try await JobService.gateOverrides(shopID: shopID, jobID: jobID)
        }
        gateOverrides.apply(result)
    }

    /// Bays/vans (names on the schedule card, choices in the editor).
    /// A failure is remembered so the screens can say the list is missing.
    func loadResources() async {
        guard let shopID else { return }
        do {
            resources = try await JobService.resources(shopID: shopID)
            resourcesFailed = false
        } catch {
            resourcesFailed = true
        }
    }

    // MARK: - Job row updates

    private func replaceJob(_ job: Job) {
        guard var snapshot = detail.value else { return }
        snapshot.job = job
        detail = .loaded(snapshot)
    }

    /// Every status except requested / cancelled needs a scheduled time
    /// (`jobs_schedule_required` CHECK on jobs).
    static func statusNeedsTime(_ status: JobStatus) -> Bool {
        status != .requested && status != .cancelled
    }

    /// True when moving to `target` must first set a date and time (the
    /// job has none) — the screen opens the schedule editor instead.
    func needsTimeFirst(for target: JobStatus) -> Bool {
        guard let job else { return false }
        return job.scheduledStart == nil && Self.statusNeedsTime(target)
    }

    /// This member may release the job's card payments before it closes:
    /// the collectors of `cancel_open_payments` (manager+, or an assigned
    /// technician while the shop lets technicians take payments).
    var canReleasePayments: Bool {
        role.can(.collectPaymentOnAssignedJob, policy: policy)
            && (role.isManagerOrAbove || permissions.isAssigned)
    }

    /// A price or deposit cut refused while a deposit payment page is open
    /// (0118 `checkout_open`): release the job's open payments and try once
    /// more (collectors only; see JobService.releasingOpenCheckout).
    private func releasingOpenCheckout<T>(_ write: () async throws -> T) async throws -> T {
        let shopID = try requireShop()
        return try await JobService.releasingOpenCheckout(
            shopID: shopID,
            jobID: jobID,
            canRelease: canReleasePayments,
            write
        )
    }

    /// Moves the job to `status`. Before cancelling or marking a no-show,
    /// the job's open card payments and pay links are released first; a
    /// card payment that is still processing stops the change (thrown).
    /// Returns how many card payments turned out to have gone through while
    /// releasing (now recorded on the job), so the screen can say so.
    ///
    /// Starting and completing are gated by the server (required checklist
    /// items, photo minimums: PostgrestError 23514); `force` is the manager
    /// override, recorded with `overrideReason`.
    @discardableResult
    func changeStatus(
        to status: JobStatus,
        cancelReason: String? = nil,
        force: Bool = false,
        overrideReason: String? = nil
    ) async throws -> Int {
        let shopID = try requireShop()
        if needsTimeFirst(for: status) {
            throw AppError.invalidInput("Set a date and time before moving this job to \(status.displayName.lowercased()).")
        }
        var recordedPayments = 0
        if (status == .cancelled || status == .noShow) && canReleasePayments {
            recordedPayments = try await JobService.releaseOpenPayments(shopID: shopID, jobID: jobID)
        }
        let updated = try await JobService.updateStatus(
            shopID: shopID,
            jobID: jobID,
            to: status,
            cancelReason: cancelReason,
            force: force,
            overrideReason: overrideReason
        )
        replaceJob(updated)
        // Forms become void on cancel / no-show; deposits may matter again.
        await loadForms()
        await loadPayment()
        if force {
            // The override is on record now: show it on the job.
            await loadGateOverrides()
        }
        return recordedPayments
    }

    /// What blocks starting / completing right now (P-11).
    func completionBlockers() async throws -> JobsCompletionBlockers {
        try await JobService.completionBlockers(jobID: jobID)
    }

    /// True for the server's gate refusal (checklist / photo minimums).
    static func isCompletionGateError(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23514"
    }

    func saveInternalNotes(_ text: String) async throws {
        let shopID = try requireShop()
        let updated = try await JobService.updateInternalNotes(shopID: shopID, jobID: jobID, notes: text)
        replaceJob(updated)
    }

    func saveDetails(_ patch: JobDetailsPatch) async throws {
        let shopID = try requireShop()
        let jobID = self.jobID
        let updated = try await releasingOpenCheckout {
            try await JobService.updateDetails(shopID: shopID, jobID: jobID, patch: patch)
        }
        replaceJob(updated)
        if patch.status != nil {
            // A status change can void or revive forms.
            await loadForms()
        }
        await loadPayment()
    }

    /// Saves the crew. The service diffs against the server's current rows
    /// (never this screen's copy), so a retry after any failure is safe.
    /// Returns false when the save worked but the re-read failed (the
    /// caller tells the user to refresh).
    @discardableResult
    func saveAssignments(_ memberIDs: Set<UUID>) async throws -> Bool {
        let shopID = try requireShop()
        try await JobService.setAssignments(shopID: shopID, jobID: jobID, memberIDs: memberIDs)
        do {
            let fresh = try await JobService.assignments(shopID: shopID, jobID: jobID)
            if var snapshot = detail.value {
                snapshot.assignments = fresh
                detail = .loaded(snapshot)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Lines & discount (server totals re-fetched after each write)

    /// Re-reads the job row (server totals) and its lines after a write.
    /// Never throws: the write already succeeded, so a failed re-read is
    /// reported through `linesRefreshProblem` (with a Refresh button)
    /// instead of looking like the write failed — which would invite a
    /// retry that inserts the same lines twice.
    func refreshJobAndLines() async {
        guard let shopID else { return }
        let jobID = self.jobID
        do {
            async let jobTask = JobService.job(shopID: shopID, jobID: jobID)
            async let linesTask = JobService.lineItems(shopID: shopID, jobID: jobID)
            let job = try await jobTask
            let lines = try await linesTask
            if var snapshot = detail.value {
                snapshot.job = job
                snapshot.lineItems = lines
                detail = .loaded(snapshot)
            }
            linesRefreshProblem = nil
        } catch {
            linesRefreshProblem = "Saved, but the services and totals couldn't be refreshed. "
                + ErrorText.message(for: error)
        }
        await loadPayment()
        // Catalog lines can attach checklist templates server-side.
        await loadChecklist()
    }

    /// Next `sort` value after the current lines.
    var nextLineSort: Int {
        (detail.value?.lineItems.map(\.sort).max() ?? 0) + 1
    }

    func addLines(_ lines: [JobLineDraft]) async throws {
        let shopID = try requireShop()
        try await JobService.insertLines(shopID: shopID, jobID: jobID, lines: lines)
        await refreshJobAndLines()
    }

    func updateLine(_ lineID: UUID, draft: JobLineDraft) async throws {
        let shopID = try requireShop()
        try await releasingOpenCheckout {
            try await JobService.updateLine(shopID: shopID, lineID: lineID, draft: draft)
        }
        await refreshJobAndLines()
    }

    func deleteLine(_ lineID: UUID) async throws {
        let shopID = try requireShop()
        try await releasingOpenCheckout {
            try await JobService.deleteLine(shopID: shopID, lineID: lineID)
        }
        await refreshJobAndLines()
    }

    /// Adds a preset fee as a line (priced by the server, P-21).
    /// `requestNonce`: one per tap, reused when that tap is retried (0095).
    func addFee(_ fee: JobsShopFee, requestNonce: String) async throws {
        _ = try requireShop()
        try await JobService.addFeeLine(kind: .job, documentID: jobID, feeID: fee.id, requestNonce: requestNonce)
        await refreshJobAndLines()
    }

    /// The customer's vehicles (per-line vehicle picker, P-7).
    func customerVehicles() async throws -> [JobVehicle] {
        let shopID = try requireShop()
        guard let customerID = job?.customerID else { return [] }
        return try await JobService.vehicles(shopID: shopID, customerID: customerID)
    }

    func updateDiscount(kind: JobDiscountKind, value: Int) async throws {
        let shopID = try requireShop()
        let jobID = self.jobID
        let updated = try await releasingOpenCheckout {
            try await JobService.updateDiscount(shopID: shopID, jobID: jobID, kind: kind, value: value)
        }
        replaceJob(updated)
        await loadPayment()
    }

    // MARK: - Money

    /// Issues the invoice and returns its id (the screen navigates to it).
    func createInvoice() async throws -> UUID {
        let invoice = try await JobService.createInvoice(jobID: jobID)
        await loadPayment()
        return invoice.id
    }

    // MARK: - Messages

    func sendMessage(_ key: JobMessageTemplateKey, channel: JobMessageChannel, nonce: String) async throws -> JobMessageSendResult {
        let shopID = try requireShop()
        return try await JobService.sendTemplate(shopID: shopID, jobID: jobID, key: key, channel: channel, nonce: nonce)
    }

    // MARK: - Checklist

    /// Optimistic toggle: the row flips at once and rolls back on failure.
    func toggleChecklistItem(_ item: JobChecklistItem) async throws {
        let shopID = try requireShop()
        guard !pendingChecklist.contains(item.id), var items = checklist.value,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = items[index]
        let makeDone = !original.isDone
        items[index].doneAt = makeDone ? Date() : nil
        items[index].doneBy = makeDone ? userID : nil
        checklist = .loaded(items)
        pendingChecklist.insert(item.id)
        defer { pendingChecklist.remove(item.id) }
        do {
            let saved = try await JobOpsService.setChecklistItem(shopID: shopID, itemID: item.id, done: makeDone)
            replaceChecklistItem(saved)
        } catch {
            replaceChecklistItem(original)
            throw error
        }
    }

    private func replaceChecklistItem(_ item: JobChecklistItem) {
        guard var items = checklist.value, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        checklist = .loaded(items)
    }

    func setChecklistItemRequired(_ item: JobChecklistItem, required: Bool) async throws {
        let shopID = try requireShop()
        let saved = try await JobOpsService.setChecklistItemRequired(shopID: shopID, itemID: item.id, required: required)
        replaceChecklistItem(saved)
    }

    func addChecklistItem(_ label: String) async throws {
        let shopID = try requireShop()
        let items = checklist.value ?? []
        let sort = (items.map(\.sort).max() ?? 0) + 1
        let saved = try await JobOpsService.addChecklistItem(shopID: shopID, jobID: jobID, label: label, sort: sort)
        checklist = .loaded(items + [saved])
    }

    func deleteChecklistItem(_ itemID: UUID) async throws {
        let shopID = try requireShop()
        try await JobOpsService.deleteChecklistItem(shopID: shopID, itemID: itemID)
        if let items = checklist.value {
            checklist = .loaded(items.filter { $0.id != itemID })
        }
    }

    func applyChecklistTemplate(_ templateID: UUID) async throws {
        try await JobOpsService.applyChecklistTemplate(jobID: jobID, templateID: templateID)
        await loadChecklist()
    }

    // MARK: - Photos

    /// Uploads each image; returns how many failed (the rest are added).
    func uploadPhotos(_ images: [Data], kind: JobPhotoKind) async throws -> Int {
        let shopID = try requireShop()
        var failures = 0
        var firstError: Error?
        var added: [JobPhotoItem] = []
        for data in images {
            do {
                let photo = try await JobOpsService.uploadPhoto(shopID: shopID, jobID: jobID, jpegData: data, kind: kind)
                let url = try? await JobOpsService.signedURL(bucket: JobOpsService.photosBucket, path: photo.storagePath)
                added.append(JobPhotoItem(photo: photo, url: url))
            } catch {
                failures += 1
                if firstError == nil { firstError = error }
            }
        }
        if !added.isEmpty {
            photos = .loaded((photos.value ?? []) + added)
        }
        if added.isEmpty, let firstError {
            throw firstError
        }
        return failures
    }

    func deletePhoto(_ photo: JobPhoto) async throws {
        try await JobOpsService.deletePhoto(photo)
        if let items = photos.value {
            photos = .loaded(items.filter { $0.id != photo.id })
        }
    }

    // MARK: - Inspections

    private func replaceInspection(_ inspection: Inspection) {
        guard var bundles = inspections.value,
              let index = bundles.firstIndex(where: { $0.id == inspection.id }) else { return }
        bundles[index].inspection = inspection
        inspections = .loaded(bundles)
    }

    func createInspection(_ kind: JobInspectionKind) async throws -> UUID {
        let shopID = try requireShop()
        let vehicleID = detail.value?.job.vehicleID
        let created = try await JobOpsService.createInspection(shopID: shopID, jobID: jobID, vehicleID: vehicleID, kind: kind)
        inspections = .loaded((inspections.value ?? []) + [JobInspectionBundle(inspection: created, marks: [])])
        return created.id
    }

    func updateInspection(_ inspectionID: UUID, mileage: Int?, fuelLevel: Int?, notes: String?) async throws {
        let shopID = try requireShop()
        let saved = try await JobOpsService.updateInspection(
            shopID: shopID,
            inspectionID: inspectionID,
            mileage: mileage,
            fuelLevel: fuelLevel,
            notes: notes
        )
        replaceInspection(saved)
    }

    func deleteInspection(_ inspectionID: UUID) async throws {
        let shopID = try requireShop()
        try await JobOpsService.deleteInspection(shopID: shopID, inspectionID: inspectionID)
        if let bundles = inspections.value {
            inspections = .loaded(bundles.filter { $0.id != inspectionID })
        }
    }

    func addMark(
        inspectionID: UUID,
        view: JobVehicleView,
        x: Double,
        y: Double,
        damage: JobDamageKind,
        note: String?,
        photoJPEG: Data?
    ) async throws {
        let shopID = try requireShop()
        let mark = try await JobOpsService.addMark(
            shopID: shopID,
            jobID: jobID,
            inspectionID: inspectionID,
            view: view,
            x: x,
            y: y,
            damage: damage,
            note: note,
            photoJPEG: photoJPEG
        )
        guard var bundles = inspections.value,
              let index = bundles.firstIndex(where: { $0.id == inspectionID }) else { return }
        bundles[index].marks.append(mark)
        inspections = .loaded(bundles)
    }

    func deleteMark(_ mark: InspectionMark) async throws {
        let shopID = try requireShop()
        try await JobOpsService.deleteMark(shopID: shopID, markID: mark.id)
        guard var bundles = inspections.value,
              let index = bundles.firstIndex(where: { $0.id == mark.inspectionID }) else { return }
        bundles[index].marks.removeAll { $0.id == mark.id }
        inspections = .loaded(bundles)
    }

    func signInspection(_ inspectionID: UUID, signerName: String, signaturePNG: Data) async throws {
        let shopID = try requireShop()
        let saved = try await JobOpsService.signInspection(
            shopID: shopID,
            inspectionID: inspectionID,
            signerName: signerName,
            signaturePNG: signaturePNG
        )
        replaceInspection(saved)
    }

    func inspection(_ id: UUID) -> JobInspectionBundle? {
        inspections.value?.first { $0.id == id }
    }

    // MARK: - Forms

    func attachForm(_ templateID: UUID) async throws {
        let shopID = try requireShop()
        let created = try await JobOpsService.attachForm(shopID: shopID, jobID: jobID, templateID: templateID)
        forms = .loaded((forms.value ?? []) + [created])
    }

    func signForm(_ submissionID: UUID, signerName: String, signaturePNG: Data?) async throws {
        let shopID = try requireShop()
        let signed = try await JobOpsService.signForm(
            shopID: shopID,
            submissionID: submissionID,
            signerName: signerName,
            signaturePNG: signaturePNG
        )
        if var items = forms.value, let index = items.firstIndex(where: { $0.id == signed.id }) {
            items[index] = signed
            forms = .loaded(items)
        }
    }
}
