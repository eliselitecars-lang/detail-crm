//
//  JobService.swift
//  DetailCRM
//
//  Jobs (SPEC §4.4): the job row, its customer/vehicle, line items,
//  assignments, status changes, scheduling edits, the job's money picture,
//  invoicing, templated customer messages, and the New Job flow (customer
//  search/create, vehicles, job + lines + assignments inserts).
//
//  Rules the server enforces regardless of the UI:
//    * technicians may change only `status` (technician-allowed edges) and
//      `internal_notes` of jobs assigned to them;
//    * totals are recomputed by triggers from the line items — the app never
//      sends subtotal/tax/total;
//    * `number`, `tax_rate_bps`, `created_by` and the status timestamps are
//      stamped by triggers.
//

import Foundation
import Supabase
import DetailCore

enum JobService {

    // MARK: - Job detail

    /// One job, or `AppError.notFound` when missing / not visible.
    static func job(shopID: UUID, jobID: UUID) async throws -> Job {
        let rows: [Job] = try await Supa.client
            .from("jobs")
            .select(Job.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let job = rows.first else { throw AppError.notFound("That job") }
        return job
    }

    /// The job with its customer, vehicle, lines, assignments and team.
    static func detail(shopID: UUID, jobID: UUID) async throws -> JobDetailSnapshot {
        let job = try await job(shopID: shopID, jobID: jobID)
        async let customerTask = customer(shopID: shopID, customerID: job.customerID)
        async let vehicleTask = vehicle(shopID: shopID, vehicleID: job.vehicleID)
        async let linesTask = lineItems(shopID: shopID, jobID: jobID)
        async let assignmentsTask = assignments(shopID: shopID, jobID: jobID)
        async let teamTask = team(shopID: shopID)
        let customer = try await customerTask
        let vehicle = try await vehicleTask
        let lines = try await linesTask
        let assignments = try await assignmentsTask
        let team = try await teamTask
        return JobDetailSnapshot(
            job: job,
            customer: customer,
            vehicle: vehicle,
            lineItems: lines,
            assignments: assignments,
            team: team
        )
    }

    /// The customer, or nil when the caller can't read it.
    static func customer(shopID: UUID, customerID: UUID) async throws -> JobCustomer? {
        let rows: [JobCustomer] = try await Supa.client
            .from("customers")
            .select(JobCustomer.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: customerID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The vehicle, or nil when none / not readable.
    static func vehicle(shopID: UUID, vehicleID: UUID?) async throws -> JobVehicle? {
        guard let vehicleID else { return nil }
        let rows: [JobVehicle] = try await Supa.client
            .from("vehicles")
            .select(JobVehicle.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: vehicleID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func lineItems(shopID: UUID, jobID: UUID) async throws -> [JobLineItem] {
        try await Supa.client
            .from("job_line_items")
            .select(JobLineItem.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    static func assignments(shopID: UUID, jobID: UUID) async throws -> [JobAssignment] {
        try await Supa.client
            .from("job_assignments")
            .select("id,shop_id,job_id,member_id,created_at")
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Team directory (names/colors for everyone; contact details for
    /// managers and above).
    static func team(shopID: UUID) async throws -> [JobTeamMember] {
        let rows: [JobTeamMember] = try await Supa.client
            .rpc("shop_team", params: JobShopParam(p_shop_id: shopID))
            .execute()
            .value
        return rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Active bays / vans.
    static func resources(shopID: UUID) async throws -> [JobResource] {
        try await Supa.client
            .from("resources")
            .select("id,name,kind,active")
            .eq("shop_id", value: shopID.uuidString)
            .eq("active", value: true)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    // MARK: - Availability (advisory; the server allows overlaps)

    /// Jobs and blocked times overlapping `[from, to)` from the staff
    /// calendar feed (`calendar_events`; cancelled jobs excluded).
    static func busyItems(shopID: UUID, from: Date, to: Date) async throws -> [JobBusyItem] {
        guard to > from else { return [] }
        let params = JobCalendarParams(
            p_shop_id: shopID.uuidString,
            p_from: Supa.iso(from),
            p_to: Supa.iso(to),
            p_include_cancelled: false
        )
        return try await Supa.client
            .rpc("calendar_events", params: params)
            .execute()
            .value
    }

    /// The shop's opening hours (all weekdays).
    static func businessHours(shopID: UUID) async throws -> [JobBusinessHours] {
        try await Supa.client
            .from("business_hours")
            .select(JobBusinessHours.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("weekday", ascending: true)
            .order("opens_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Status & notes

    /// Moves the job to `status` (the status machine validates the edge and
    /// the caller's role; timestamps are stamped by the server). A reason
    /// is stored only when cancelling.
    static func updateStatus(
        shopID: UUID,
        jobID: UUID,
        to status: JobStatus,
        cancelReason: String? = nil,
        force: Bool = false,
        overrideReason: String? = nil
    ) async throws -> Job {
        // `set_job_status` (P-11): the same transition rules as a direct
        // update, plus the completion gates (required checklist items,
        // before/after photo minimums; 23514 when they block) and the
        // manager override (`p_force`, recorded with its reason). For a
        // move to cancelled the reason is stored as the cancel reason.
        // The reason is sent whole: a cancel reason is shown to the customer
        // on their booking page, so it is never cut short. Over the server's
        // limit the save is refused with the same rule the server applies.
        let reason = status == .cancelled ? cancelReason?.trimmedNonEmpty : overrideReason?.trimmedNonEmpty
        if let reason, let problem = Validation.statusReasonProblem(reason) {
            throw AppError.message(problem)
        }
        let params: [String: AnyJSON] = [
            "p_job_id": .string(jobID.uuidString),
            "p_status": .string(status.rawValue),
            "p_force": .bool(force),
            "p_reason": reason.map { AnyJSON.string($0) } ?? .null,
        ]
        return try await Supa.client
            .rpc("set_job_status", params: params)
            .single()
            .execute()
            .value
    }

    /// What still blocks starting / completing the job (staff on the job).
    static func completionBlockers(jobID: UUID) async throws -> JobsCompletionBlockers {
        try await Supa.client
            .rpc("job_completion_blockers", params: ["p_job_id": jobID.uuidString])
            .execute()
            .value
    }

    /// Every move of the job past its completion gates, oldest first: who
    /// overrode the required checklist items / photo minimums, when, why
    /// and what was missing (P-11; staff who can work the job read them).
    static func gateOverrides(shopID: UUID, jobID: UUID) async throws -> [JobsGateOverride] {
        try await Supa.client
            .from("job_gate_overrides")
            .select(JobsGateOverride.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("job_id", value: jobID.uuidString)
            .order("created_at", ascending: true)
            .order("id", ascending: true)
            .execute()
            .value
    }

    /// Internal (staff-only) notes; technicians may edit these on assigned jobs.
    static func updateInternalNotes(shopID: UUID, jobID: UUID, notes: String?) async throws -> Job {
        try await Supa.client
            .from("jobs")
            .update(JobInternalNotesPatch(internalNotes: notes?.trimmedNonEmpty))
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .select(Job.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Manager+: schedule, location, resource, customer-visible notes and
    /// the deposit requirement.
    static func updateDetails(shopID: UUID, jobID: UUID, patch: JobDetailsPatch) async throws -> Job {
        try await Supa.client
            .from("jobs")
            .update(patch)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .select(Job.selectColumns)
            .single()
            .execute()
            .value
    }

    /// Manager+: the job-level discount (percent in basis points, or cents).
    static func updateDiscount(shopID: UUID, jobID: UUID, kind: JobDiscountKind, value: Int) async throws -> Job {
        let patch = JobDiscountPatch(discount_kind: kind.rawValue, discount_value: kind == .none ? 0 : max(0, value))
        return try await Supa.client
            .from("jobs")
            .update(patch)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .select(Job.selectColumns)
            .single()
            .execute()
            .value
    }

    // MARK: - Deposit follow-ups (P-3)

    /// `document_followup_status` / `set_document_followups_paused` for the
    /// job's deposit reminders.
    // rpc: document_followup_status
    struct FollowupStatus: Decodable, Hashable, Sendable {
        var enabled: Bool
        var paused: Bool
        var attemptsSent: Int
        var maxAttempts: Int
        var lastSentAt: Date?
        var nextAt: Date?

        enum CodingKeys: String, CodingKey {
            case enabled
            case paused
            case attemptsSent = "attempts_sent"
            case maxAttempts = "max_attempts"
            case lastSentAt = "last_sent_at"
            case nextAt = "next_at"
        }
    }

    /// The automatic deposit reminders of a job (managers+).
    static func depositFollowupStatus(jobID: UUID) async throws -> FollowupStatus {
        let params: [String: AnyJSON] = [
            "p_kind": .string("deposit"),
            "p_id": .string(jobID.uuidString),
        ]
        return try await Supa.client
            .rpc("document_followup_status", params: params)
            .execute()
            .value
    }

    /// Pauses or resumes the job's deposit reminders (managers+).
    static func setDepositFollowupsPaused(jobID: UUID, paused: Bool) async throws -> FollowupStatus {
        let params: [String: AnyJSON] = [
            "p_kind": .string("deposit"),
            "p_id": .string(jobID.uuidString),
            "p_paused": .bool(paused),
        ]
        return try await Supa.client
            .rpc("set_document_followups_paused", params: params)
            .execute()
            .value
    }

    // MARK: - Custom data (P-9, managers+)

    /// Saves the job's answers to the shop's job fields. The server checks
    /// every value against its field (22023 names the field).
    static func updateCustomData(shopID: UUID, jobID: UUID, data: [String: AnyJSON]) async throws -> Job {
        try await Supa.client
            .from("jobs")
            .update(["custom_data": AnyJSON.object(data)])
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .select(Job.selectColumns)
            .single()
            .execute()
            .value
    }

    // MARK: - Fees (P-21) and line vehicles (P-7)

    /// The shop's preset fees offered for adding (active, not archived).
    static func fees(shopID: UUID) async throws -> [JobsShopFee] {
        try await Supa.client
            .from("shop_fees")
            .select(JobsShopFee.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("active", value: true)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Adds a preset fee as a line (priced by the server; managers+).
    /// `requestNonce` (0095) is one value per user action — make it with
    /// `newFeeRequestNonce()` when the person adds the fee and pass the same
    /// one when that action is retried: the server then returns the line the
    /// first call added instead of adding the fee twice.
    @discardableResult
    static func addFeeLine(
        kind: JobsShopFee.DocumentKind,
        documentID: UUID,
        feeID: UUID,
        requestNonce: String
    ) async throws -> UUID {
        let params: [String: AnyJSON] = [
            "p_doc_kind": .string(kind.rawValue),
            "p_doc_id": .string(documentID.uuidString),
            "p_fee_id": .string(feeID.uuidString),
            "p_request_nonce": .string(requestNonce),
        ]
        return try await Supa.client
            .rpc("add_fee_line", params: params)
            .execute()
            .value
    }

    /// A fresh `add_fee_line` request nonce: a UUID string (36 characters
    /// of `[0-9A-F-]`, inside the server's 8-64 `[A-Za-z0-9_-]` rule).
    static func newFeeRequestNonce() -> String {
        UUID().uuidString
    }

    // MARK: - Route (P-18)

    /// Route order and coordinates of the given jobs (the day map).
    static func routeInfo(shopID: UUID, jobIDs: [UUID]) async throws -> [Job] {
        guard !jobIDs.isEmpty else { return [] }
        return try await Supa.client
            .from("jobs")
            .select(Job.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: jobIDs.map(\.uuidString))
            .execute()
            .value
    }

    /// Saves the stop order of one shop-local day (first = 0). Managers may
    /// order any jobs; technicians only jobs they are all assigned to.
    @discardableResult
    static func setRouteOrder(shopID: UUID, jobIDs: [UUID]) async throws -> Int {
        let params: [String: AnyJSON] = [
            "p_shop_id": .string(shopID.uuidString),
            "p_job_ids": .array(jobIDs.map { AnyJSON.string($0.uuidString) }),
        ]
        return try await Supa.client
            .rpc("set_route_order", params: params)
            .execute()
            .value
    }

    /// Stores coordinates this iPhone found for a job's service address
    /// (managers+, or a technician assigned to the job). `job` is the row the
    /// geocoded address was read from: its address fields go along as
    /// `p_address`, and the server refuses the point (40001) when the job's
    /// address changed after it was read, so a point found for an old
    /// address is never stored on a corrected one.
    static func setJobCoordinates(job: Job, latitude: Double, longitude: Double) async throws {
        let address: [String: AnyJSON] = [
            "service_address_line1": addressValue(job.serviceAddressLine1),
            "service_address_line2": addressValue(job.serviceAddressLine2),
            "service_city": addressValue(job.serviceCity),
            "service_region": addressValue(job.serviceRegion),
            "service_postal_code": addressValue(job.servicePostalCode),
        ]
        let params: [String: AnyJSON] = [
            "p_job_id": .string(job.id.uuidString),
            "p_lat": .double(latitude),
            "p_lng": .double(longitude),
            "p_address": .object(address),
        ]
        try await Supa.client
            .rpc("set_job_coordinates", params: params)
            .execute()
    }

    /// An address field exactly as read (null stays null).
    private static func addressValue(_ value: String?) -> AnyJSON {
        guard let value else { return .null }
        return .string(value)
    }

    // MARK: - Assignments

    /// Manager+: makes the job's assignees exactly `memberIDs` (removes the
    /// others, adds the new ones). Diffs against the rows on the server
    /// right now — never a screen's possibly stale copy — so calling it
    /// again after a partial failure never re-inserts an existing member.
    static func setAssignments(
        shopID: UUID,
        jobID: UUID,
        memberIDs: Set<UUID>
    ) async throws {
        let current = try await assignments(shopID: shopID, jobID: jobID)
        let removed = current.filter { !memberIDs.contains($0.memberID) }
        let existing = Set(current.map(\.memberID))
        let added = memberIDs.subtracting(existing).sorted { $0.uuidString < $1.uuidString }
        if !removed.isEmpty {
            try await Supa.client
                .from("job_assignments")
                .delete()
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: removed.map { $0.id.uuidString })
                .execute()
        }
        try await insertAssignments(shopID: shopID, jobID: jobID, memberIDs: added)
    }

    static func insertAssignments(shopID: UUID, jobID: UUID, memberIDs: [UUID]) async throws {
        guard !memberIDs.isEmpty else { return }
        let rows = memberIDs.map { JobAssignmentInsert(shop_id: shopID, job_id: jobID, member_id: $0) }
        try await Supa.client
            .from("job_assignments")
            .insert(rows, returning: .minimal)
            .execute()
    }

    // MARK: - Line items (manager+)

    /// Inserts lines in one request (all or nothing).
    static func insertLines(shopID: UUID, jobID: UUID, lines: [JobLineDraft]) async throws {
        guard !lines.isEmpty else { return }
        let rows = lines.map { JobLineInsert(shopID: shopID, jobID: jobID, draft: $0) }
        try await Supa.client
            .from("job_line_items")
            .insert(rows, returning: .minimal)
            .execute()
    }

    static func updateLine(shopID: UUID, lineID: UUID, draft: JobLineDraft) async throws {
        try await Supa.client
            .from("job_line_items")
            .update(draft, returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: lineID.uuidString)
            .execute()
    }

    static func deleteLine(shopID: UUID, lineID: UUID) async throws {
        try await Supa.client
            .from("job_line_items")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: lineID.uuidString)
            .execute()
    }

    // MARK: - Money

    /// The job's deposit / paid / balance picture, or nil when the RPC
    /// returns no row. Throws 42501 for callers who can't collect.
    static func paymentSummary(jobID: UUID) async throws -> JobPaymentSummary? {
        let rows: [JobPaymentSummary] = try await Supa.client
            .rpc("job_payment_summary", params: JobIDParam(p_job_id: jobID))
            .execute()
            .value
        return rows.first
    }

    /// Issues the job's invoice (copies lines, attaches earlier deposits).
    static func createInvoice(jobID: UUID) async throws -> JobCreatedInvoice {
        try await Supa.client
            .rpc("create_invoice_from_job", params: JobIDParam(p_job_id: jobID))
            .select("id,number,status")
            .single()
            .execute()
            .value
    }

    // MARK: - Customer messages

    /// What the template would send for this job (nothing is queued).
    static func previewTemplate(jobID: UUID, key: JobMessageTemplateKey, channel: JobMessageChannel) async throws -> JobMessagePreview? {
        let rows: [JobMessagePreview] = try await Supa.client
            .rpc(
                "preview_template_message",
                params: JobTemplatePreviewParams(p_job_id: jobID, p_key: key.rawValue, p_channel: channel.rawValue)
            )
            .execute()
            .value
        return rows.first
    }

    /// Sends a job template through the messaging function (technicians:
    /// on-my-way / started / complete on their assigned jobs only). `nonce`
    /// is one per compose, reused on a retry, so the server never queues
    /// the message twice. Refusals arrive as `EdgeFunctionError`.
    static func sendTemplate(
        shopID: UUID,
        jobID: UUID,
        key: JobMessageTemplateKey,
        channel: JobMessageChannel,
        nonce: String
    ) async throws -> JobMessageSendResult {
        let body = JobMessageSendBody(
            action: "send",
            shop_id: shopID.uuidString.lowercased(),
            job_id: jobID.uuidString.lowercased(),
            channel: channel.rawValue,
            template_key: key.rawValue,
            request_nonce: nonce
        )
        let reply: JobMessageSendReply = try await EdgeFunctions.invoke("messaging", body: body)
        return JobMessageSendResult(
            messageID: reply.message_id.flatMap { UUID(uuidString: $0) },
            status: reply.status ?? "queued",
            error: reply.error
        )
    }

    // MARK: - Releasing card payments

    static let paymentInProgressMessage =
        "A card payment for this job is still processing. Wait for it to finish, then try again."

    /// Before a job is cancelled / marked no-show: releases its open card
    /// payments and pay links (`cancel_open_payments` with `job_id`).
    /// Throws while a card payment is still processing (the status must not
    /// change yet); returns how many attempts turned out to have taken the
    /// money (now recorded on the job's deposit / invoice).
    static func releaseOpenPayments(shopID: UUID, jobID: UUID) async throws -> Int {
        do {
            let release = try await PaymentService.cancelOpenPayments(shopID: shopID, jobID: jobID)
            if release.inProgress > 0 {
                throw AppError.message(paymentInProgressMessage)
            }
            return release.succeeded
        } catch let error as EdgeFunctionError where error.reason == "payment_in_progress" {
            throw AppError.message(paymentInProgressMessage)
        }
    }

    /// True for 0118's refusal of a job edit that lowers the job's total or
    /// deposit (line edits and removals, the discount, the deposit) while a
    /// deposit payment page of the job can still be paid (55000 HINT
    /// `checkout_open`). The screen then asks before releasing the page;
    /// the edit is never retried on its own (see `releaseForEdit`).
    static func isOpenCheckoutRefusal(_ error: Error) -> Bool {
        guard let postgrest = error as? PostgrestError else { return false }
        return OpenCheckoutRefusal.matches(code: postgrest.code, hint: postgrest.hint)
    }

    /// After staff confirmed releasing the job's open payments for a refused
    /// price or deposit cut: `cancel_open_payments` with `job_id`, reported
    /// in full. Unlike `releaseOpenPayments` it does not throw for a payment
    /// still processing: that comes back as `inProgress`, so the edit stops
    /// with a notice (`OpenCheckoutRefusal.releaseThenSaveAgain`) instead of
    /// being saved over money that may still land.
    static func releaseForEdit(shopID: UUID, jobID: UUID) async throws -> OpenPaymentsRelease {
        do {
            let release = try await PaymentService.cancelOpenPayments(shopID: shopID, jobID: jobID)
            return OpenPaymentsRelease(
                cancelled: release.cancelled,
                succeeded: release.succeeded,
                inProgress: release.inProgress,
                sessionsExpired: release.sessionsExpired
            )
        } catch let error as EdgeFunctionError where error.reason == "payment_in_progress" {
            return OpenPaymentsRelease(inProgress: 1)
        }
    }

    // MARK: - New job: customers

    /// Up to 25 customers matching every word of `term` (name, company,
    /// email, phone — via the generated `search_text`). Phone-like input
    /// matches digits only.
    static func searchCustomers(shopID: UUID, term: String) async throws -> [JobCustomer] {
        var request = Supa.client
            .from("customers")
            .select(JobCustomer.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .is("archived_at", value: nil)
        for pattern in searchPatterns(for: term) {
            request = request.ilike("search_text", pattern: pattern)
        }
        return try await request
            .order("updated_at", ascending: false)
            .limit(25)
            .execute()
            .value
    }

    /// ILIKE patterns: one `%word%` per word (LIKE wildcards escaped), or
    /// a digits-only pattern for phone-looking input.
    static func searchPatterns(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let phoneCharacters: Set<Character> = [" ", "(", ")", "-", ".", "+", "/"]
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if digits.count >= 3,
           trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || phoneCharacters.contains($0) }) {
            return ["%" + digits + "%"]
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).prefix(6).map { String($0) }
        return words.map { escapeLike($0) }.filter { !$0.isEmpty }.map { "%" + $0 + "%" }
    }

    private static func escapeLike(_ term: String) -> String {
        var result = ""
        for character in term where character != "*" {
            switch character {
            case "\\": result += "\\\\"
            case "%": result += "\\%"
            case "_": result += "\\_"
            default: result.append(character)
            }
        }
        return result
    }

    /// Manager+: a minimal new customer (at least one name; phone in any
    /// common format is stored as E.164).
    static func createCustomer(
        shopID: UUID,
        firstName: String,
        lastName: String,
        phone: String,
        email: String
    ) async throws -> JobCustomer {
        let first = firstName.trimmedNonEmpty
        let last = lastName.trimmedNonEmpty
        guard first != nil || last != nil else {
            throw AppError.invalidInput("Enter the customer's first or last name.")
        }
        var e164: String?
        if let rawPhone = phone.trimmedNonEmpty {
            guard let normalized = PhoneNumber.normalize(rawPhone) else {
                throw AppError.invalidInput("Enter a valid phone number.")
            }
            e164 = normalized
        }
        var normalizedEmail: String?
        if let rawEmail = email.trimmedNonEmpty {
            guard Validation.isValidEmail(rawEmail) else {
                throw AppError.invalidInput("Enter a valid email address.")
            }
            normalizedEmail = Validation.normalizedEmail(rawEmail)
        }
        let row = JobCustomerInsert(
            shop_id: shopID,
            first_name: first,
            last_name: last,
            phone: e164,
            email: normalizedEmail
        )
        return try await Supa.client
            .from("customers")
            .insert(row)
            .select(JobCustomer.selectColumns)
            .single()
            .execute()
            .value
    }

    // MARK: - New job: vehicles

    static func vehicles(shopID: UUID, customerID: UUID) async throws -> [JobVehicle] {
        try await Supa.client
            .from("vehicles")
            .select(JobVehicle.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .is("archived_at", value: nil)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    static func vehicleCategories(shopID: UUID) async throws -> [JobVehicleCategory] {
        try await Supa.client
            .from("vehicle_categories")
            .select("id,name,sort")
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Manager+: adds a vehicle to a customer.
    static func createVehicle(shopID: UUID, customerID: UUID, draft: JobVehicleDraft) async throws -> JobVehicle {
        let row = JobVehicleInsert(shopID: shopID, customerID: customerID, draft: draft)
        return try await Supa.client
            .from("vehicles")
            .insert(row)
            .select(JobVehicle.selectColumns)
            .single()
            .execute()
            .value
    }

    // MARK: - New job: create

    /// Inserts the job row (lines and assignments are separate calls so a
    /// partial failure can be retried without creating a second job).
    static func createJob(shopID: UUID, draft: JobCreateDraft) async throws -> Job {
        let row = JobInsert(shopID: shopID, draft: draft)
        return try await Supa.client
            .from("jobs")
            .insert(row)
            .select(Job.selectColumns)
            .single()
            .execute()
            .value
    }
}

// MARK: - Public drafts

/// Fields for a new vehicle.
struct JobVehicleDraft: Hashable, Sendable {
    var year: Int?
    var make: String = ""
    var model: String = ""
    var trim: String = ""
    var color: String = ""
    var vin: String = ""
    var licensePlate: String = ""
    var categoryID: UUID?

    /// Something identifies the vehicle (year, make, model or VIN).
    var isMeaningful: Bool {
        year != nil || make.trimmedNonEmpty != nil || model.trimmedNonEmpty != nil || vin.trimmedNonEmpty != nil
    }
}

/// Everything the job row needs at creation. Totals are never sent.
struct JobCreateDraft: Hashable, Sendable {
    var customerID: UUID
    var vehicleID: UUID?
    /// `.scheduled` with a time, or `.requested` without one.
    var status: JobStatus
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var locationType: JobLocationType
    var serviceAddressLine1: String?
    var serviceAddressLine2: String?
    var serviceCity: String?
    var serviceRegion: String?
    var servicePostalCode: String?
    var resourceID: UUID?
    var notes: String?
    var internalNotes: String?
    var discountKind: JobDiscountKind
    var discountValue: Int
}

/// Manager+ edits of scheduling, location, resource, notes and deposit.
/// Every field is sent (nulls clear values); coordinates are cleared when
/// the address changes so maps never point at a stale pin.
// table: jobs
struct JobDetailsPatch: Encodable, Hashable, Sendable {
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var locationType: JobLocationType
    var serviceAddressLine1: String?
    var serviceAddressLine2: String?
    var serviceCity: String?
    var serviceRegion: String?
    var servicePostalCode: String?
    var clearCoordinates: Bool
    var resourceID: UUID?
    var notes: String?
    var depositRequiredCents: Int
    /// Also move the job to this status in the same update. Used when an
    /// unscheduled (requested / cancelled) job is scheduled or confirmed:
    /// `jobs_schedule_required` needs the time in the same row write.
    var status: JobStatus? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case locationType = "location_type"
        case serviceAddressLine1 = "service_address_line1"
        case serviceAddressLine2 = "service_address_line2"
        case serviceCity = "service_city"
        case serviceRegion = "service_region"
        case servicePostalCode = "service_postal_code"
        case serviceLat = "service_lat"
        case serviceLng = "service_lng"
        case resourceID = "resource_id"
        case notes
        case depositRequiredCents = "deposit_required_cents"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scheduledStart, forKey: .scheduledStart)
        try container.encode(scheduledEnd, forKey: .scheduledEnd)
        try container.encode(locationType, forKey: .locationType)
        try container.encode(serviceAddressLine1, forKey: .serviceAddressLine1)
        try container.encode(serviceAddressLine2, forKey: .serviceAddressLine2)
        try container.encode(serviceCity, forKey: .serviceCity)
        try container.encode(serviceRegion, forKey: .serviceRegion)
        try container.encode(servicePostalCode, forKey: .servicePostalCode)
        if clearCoordinates {
            try container.encodeNil(forKey: .serviceLat)
            try container.encodeNil(forKey: .serviceLng)
        }
        try container.encode(resourceID, forKey: .resourceID)
        try container.encode(notes, forKey: .notes)
        try container.encode(max(0, depositRequiredCents), forKey: .depositRequiredCents)
        try container.encodeIfPresent(status?.rawValue, forKey: .status)
    }
}

// MARK: - Private wire types (file scope: never nest types in generic functions)

private struct JobShopParam: Encodable {
    let p_shop_id: UUID
}

private struct JobCalendarParams: Encodable {
    let p_shop_id: String
    let p_from: String
    let p_to: String
    let p_include_cancelled: Bool
}

private struct JobIDParam: Encodable {
    let p_job_id: UUID
}

private struct JobTemplatePreviewParams: Encodable {
    let p_job_id: UUID
    let p_key: String
    let p_channel: String
}

// table: jobs
private struct JobInternalNotesPatch: Encodable {
    let internalNotes: String?

    enum CodingKeys: String, CodingKey {
        case internalNotes = "internal_notes"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(internalNotes, forKey: .internalNotes)
    }
}

private struct JobDiscountPatch: Encodable {
    let discount_kind: String
    let discount_value: Int
}

private struct JobAssignmentInsert: Encodable {
    let shop_id: UUID
    let job_id: UUID
    let member_id: UUID
}

// table: job_line_items
private struct JobLineInsert: Encodable {
    let shopID: UUID
    let jobID: UUID
    let draft: JobLineDraft

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case jobID = "job_id"
        case serviceID = "service_id"
        case vehicleID = "vehicle_id"
        case name
        case description
        case quantity
        case unitPriceCents = "unit_price_cents"
        case discountCents = "discount_cents"
        case taxable
        case durationMinutes = "duration_minutes"
        case sort
    }

    /// Every key on every row (nulls explicit) so a batch insert is uniform.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(draft.serviceID, forKey: .serviceID)
        try container.encode(draft.vehicleID, forKey: .vehicleID)
        try container.encode(draft.name, forKey: .name)
        try container.encode(draft.description, forKey: .description)
        try container.encode(draft.quantity, forKey: .quantity)
        try container.encode(draft.unitPriceCents, forKey: .unitPriceCents)
        try container.encode(draft.discountCents, forKey: .discountCents)
        try container.encode(draft.taxable, forKey: .taxable)
        try container.encode(draft.durationMinutes, forKey: .durationMinutes)
        try container.encode(draft.sort, forKey: .sort)
    }
}

private struct JobCustomerInsert: Encodable {
    let shop_id: UUID
    let first_name: String?
    let last_name: String?
    let phone: String?
    let email: String?
}

// table: vehicles
private struct JobVehicleInsert: Encodable {
    let shopID: UUID
    let customerID: UUID
    let draft: JobVehicleDraft

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case customerID = "customer_id"
        case year
        case make
        case model
        case trim
        case color
        case vin
        case licensePlate = "license_plate"
        case categoryID = "category_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(customerID, forKey: .customerID)
        try container.encodeIfPresent(draft.year, forKey: .year)
        try container.encodeIfPresent(draft.make.trimmedNonEmpty, forKey: .make)
        try container.encodeIfPresent(draft.model.trimmedNonEmpty, forKey: .model)
        try container.encodeIfPresent(draft.trim.trimmedNonEmpty, forKey: .trim)
        try container.encodeIfPresent(draft.color.trimmedNonEmpty, forKey: .color)
        let vin = VIN.normalize(draft.vin)
        try container.encodeIfPresent(vin.isEmpty ? nil : vin, forKey: .vin)
        try container.encodeIfPresent(draft.licensePlate.trimmedNonEmpty?.uppercased(), forKey: .licensePlate)
        try container.encodeIfPresent(draft.categoryID, forKey: .categoryID)
    }
}

// table: jobs
private struct JobInsert: Encodable {
    let shopID: UUID
    let draft: JobCreateDraft

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case status
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case locationType = "location_type"
        case serviceAddressLine1 = "service_address_line1"
        case serviceAddressLine2 = "service_address_line2"
        case serviceCity = "service_city"
        case serviceRegion = "service_region"
        case servicePostalCode = "service_postal_code"
        case resourceID = "resource_id"
        case notes
        case internalNotes = "internal_notes"
        case source
        case discountKind = "discount_kind"
        case discountValue = "discount_value"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(draft.customerID, forKey: .customerID)
        try container.encodeIfPresent(draft.vehicleID, forKey: .vehicleID)
        try container.encode(draft.status.rawValue, forKey: .status)
        try container.encodeIfPresent(draft.scheduledStart, forKey: .scheduledStart)
        try container.encodeIfPresent(draft.scheduledEnd, forKey: .scheduledEnd)
        try container.encode(draft.locationType, forKey: .locationType)
        if draft.locationType == .mobile {
            try container.encodeIfPresent(draft.serviceAddressLine1?.trimmedNonEmpty, forKey: .serviceAddressLine1)
            try container.encodeIfPresent(draft.serviceAddressLine2?.trimmedNonEmpty, forKey: .serviceAddressLine2)
            try container.encodeIfPresent(draft.serviceCity?.trimmedNonEmpty, forKey: .serviceCity)
            try container.encodeIfPresent(draft.serviceRegion?.trimmedNonEmpty, forKey: .serviceRegion)
            try container.encodeIfPresent(draft.servicePostalCode?.trimmedNonEmpty, forKey: .servicePostalCode)
        }
        try container.encodeIfPresent(draft.resourceID, forKey: .resourceID)
        try container.encodeIfPresent(draft.notes?.trimmedNonEmpty, forKey: .notes)
        try container.encodeIfPresent(draft.internalNotes?.trimmedNonEmpty, forKey: .internalNotes)
        try container.encode("staff", forKey: .source)
        try container.encode(draft.discountKind, forKey: .discountKind)
        try container.encode(draft.discountKind == .none ? 0 : max(0, draft.discountValue), forKey: .discountValue)
    }
}

private struct JobMessageSendBody: Encodable {
    let action: String
    let shop_id: String
    let job_id: String
    let channel: String
    let template_key: String
    let request_nonce: String
}

private struct JobMessageSendReply: Decodable {
    let message_id: String?
    let channel: String?
    let status: String?
    let error: String?
}

