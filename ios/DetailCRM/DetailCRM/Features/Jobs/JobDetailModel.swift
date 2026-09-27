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
    var checklist: LoadState<[JobChecklistItem]> = .idle
    var photos: LoadState<[JobPhotoItem]> = .idle
    var inspections: LoadState<[JobInspectionBundle]> = .idle
    var forms: LoadState<[FormSubmission]> = .idle
    private(set) var resources: [JobResource] = []
    /// Checklist items with a toggle in flight.
    private(set) var pendingChecklist: Set<UUID> = []

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
        let errors: [String?] = [
            detailError,
            await checklistError,
            await photosError,
            await inspectionsError,
            await formsError,
            await paymentError,
        ]
        _ = await resourcesDone
        return errors.compactMap { $0 }.first
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
        let jobID = self.jobID
        let result = await LoadState<JobPaymentSummary?>.result {
            try await JobService.paymentSummary(jobID: jobID)
        }
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

    /// Bays/vans (names on the schedule card, choices in the editor).
    /// Failures leave the list empty — the editor then hides the picker.
    func loadResources() async {
        guard let shopID else { return }
        if let rows = try? await JobService.resources(shopID: shopID) {
            resources = rows
        }
    }

    // MARK: - Job row updates

    private func replaceJob(_ job: Job) {
        guard var snapshot = detail.value else { return }
        snapshot.job = job
        detail = .loaded(snapshot)
    }

    func changeStatus(to status: JobStatus, cancelReason: String? = nil) async throws {
        let shopID = try requireShop()
        let updated = try await JobService.updateStatus(
            shopID: shopID,
            jobID: jobID,
            to: status,
            cancelReason: cancelReason
        )
        replaceJob(updated)
        // Forms become void on cancel / no-show; deposits may matter again.
        await loadForms()
        await loadPayment()
    }

    func saveInternalNotes(_ text: String) async throws {
        let shopID = try requireShop()
        let updated = try await JobService.updateInternalNotes(shopID: shopID, jobID: jobID, notes: text)
        replaceJob(updated)
    }

    func saveDetails(_ patch: JobDetailsPatch) async throws {
        let shopID = try requireShop()
        let updated = try await JobService.updateDetails(shopID: shopID, jobID: jobID, patch: patch)
        replaceJob(updated)
        await loadPayment()
    }

    func saveAssignments(_ memberIDs: Set<UUID>) async throws {
        let shopID = try requireShop()
        let current = detail.value?.assignments ?? []
        try await JobService.setAssignments(shopID: shopID, jobID: jobID, current: current, memberIDs: memberIDs)
        let fresh = try await JobService.assignments(shopID: shopID, jobID: jobID)
        if var snapshot = detail.value {
            snapshot.assignments = fresh
            detail = .loaded(snapshot)
        }
    }

    // MARK: - Lines & discount (server totals re-fetched after each write)

    /// Re-reads the job row (server totals) and its lines.
    func refreshJobAndLines() async throws {
        let shopID = try requireShop()
        async let jobTask = JobService.job(shopID: shopID, jobID: jobID)
        async let linesTask = JobService.lineItems(shopID: shopID, jobID: jobID)
        let job = try await jobTask
        let lines = try await linesTask
        if var snapshot = detail.value {
            snapshot.job = job
            snapshot.lineItems = lines
            detail = .loaded(snapshot)
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
        try await refreshJobAndLines()
    }

    func updateLine(_ lineID: UUID, draft: JobLineDraft) async throws {
        let shopID = try requireShop()
        try await JobService.updateLine(shopID: shopID, lineID: lineID, draft: draft)
        try await refreshJobAndLines()
    }

    func deleteLine(_ lineID: UUID) async throws {
        let shopID = try requireShop()
        try await JobService.deleteLine(shopID: shopID, lineID: lineID)
        try await refreshJobAndLines()
    }

    func updateDiscount(kind: JobDiscountKind, value: Int) async throws {
        let shopID = try requireShop()
        let updated = try await JobService.updateDiscount(shopID: shopID, jobID: jobID, kind: kind, value: value)
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

    func sendMessage(_ key: JobMessageTemplateKey, channel: JobMessageChannel) async throws -> JobMessageSendResult {
        let shopID = try requireShop()
        return try await JobService.sendTemplate(shopID: shopID, jobID: jobID, key: key, channel: channel)
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
