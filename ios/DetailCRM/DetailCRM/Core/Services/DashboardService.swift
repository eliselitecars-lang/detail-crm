//
//  DashboardService.swift
//  DetailCRM
//
//  Today tab: `dashboard_summary`, online booking requests (approve /
//  decline), the next job's location, and the compact shift clock
//  (`clock_in` / `clock_out`, 0024). Every rule — who may approve, status
//  transitions, clock overlaps — is enforced by RLS, triggers and RPCs;
//  these calls only ask.
//

import Foundation
import Supabase

enum DashboardService {

    // MARK: - Summary

    /// The home-screen summary in the shop time zone (`dashboard_summary`).
    /// The server clock is used (`p_now` is ignored for API callers).
    static func summary(shopID: UUID) async throws -> DashboardSummary {
        try await Supa.client
            .rpc("dashboard_summary", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
    }

    // MARK: - Booking requests

    /// Online bookings still waiting for a decision (`requested`) with
    /// customer / vehicle / service names. Requests without a requested
    /// time come first: they never appear in the Calendar (it lists
    /// scheduled jobs only), so they must not be the ones cut off by the
    /// page limit. Then soonest appointment first.
    /// Manager+ only (RLS returns nothing useful to technicians).
    static func bookingRequests(shopID: UUID, limit: Int = 25) async throws -> [DashboardSummaryBookingRequest] {
        let jobs: [DashboardSummaryRequestJob] = try await Supa.client
            .from("jobs")
            .select(DashboardSummaryRequestJob.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("status", value: "requested")
            .eq("source", value: "online_booking")
            .order("scheduled_start", ascending: true, nullsFirst: true)
            .order("created_at", ascending: true)
            .limit(limit)
            .execute()
            .value
        guard !jobs.isEmpty else { return [] }

        let customerIDs = Array(Set(jobs.map { $0.customerID.uuidString }))
        let vehicleIDs = Array(Set(jobs.compactMap { $0.vehicleID?.uuidString }))
        let jobIDs = jobs.map { $0.id.uuidString }

        let customers: [DashboardSummaryCustomerName] = try await Supa.client
            .from("customers")
            .select(DashboardSummaryCustomerName.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: customerIDs)
            .execute()
            .value

        var vehicles: [DashboardSummaryVehicleName] = []
        if !vehicleIDs.isEmpty {
            vehicles = try await Supa.client
                .from("vehicles")
                .select(DashboardSummaryVehicleName.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: vehicleIDs)
                .execute()
                .value
        }

        let lines: [DashboardSummaryLineName] = try await Supa.client
            .from("job_line_items")
            .select(DashboardSummaryLineName.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("job_id", values: jobIDs)
            .order("sort", ascending: true)
            .execute()
            .value

        return assembleRequests(jobs: jobs, customers: customers, vehicles: vehicles, lines: lines)
    }

    /// Joins the separately fetched names onto the request jobs (pure).
    static func assembleRequests(
        jobs: [DashboardSummaryRequestJob],
        customers: [DashboardSummaryCustomerName],
        vehicles: [DashboardSummaryVehicleName],
        lines: [DashboardSummaryLineName]
    ) -> [DashboardSummaryBookingRequest] {
        var customersByID: [UUID: DashboardSummaryCustomerName] = [:]
        for customer in customers { customersByID[customer.id] = customer }
        var vehiclesByID: [UUID: DashboardSummaryVehicleName] = [:]
        for vehicle in vehicles { vehiclesByID[vehicle.id] = vehicle }
        var linesByJob: [UUID: [DashboardSummaryLineName]] = [:]
        for line in lines { linesByJob[line.jobID, default: []].append(line) }

        return jobs.map { job in
            let names = (linesByJob[job.id] ?? [])
                .sorted { $0.sort < $1.sort }
                .map { $0.name }
            return DashboardSummaryBookingRequest(
                job: job,
                customerName: customersByID[job.customerID]?.fullName ?? "Customer",
                vehicleLabel: job.vehicleID.flatMap { vehiclesByID[$0]?.label },
                serviceNames: names
            )
        }
    }

    private struct StatusChange: Encodable {
        let status: String
    }

    private struct CancelChange: Encodable {
        let status: String
        let cancel_reason: String?
    }

    private struct UpdatedJobRow: Decodable {
        let id: UUID
    }

    /// Accepts an online booking: `requested` -> `scheduled`. The server's
    /// status machine validates the move and sends the customer the
    /// booking-confirmed message.
    static func approveBooking(shopID: UUID, jobID: UUID) async throws {
        let rows: [UpdatedJobRow] = try await Supa.client
            .from("jobs")
            .update(StatusChange(status: "scheduled"))
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .eq("status", value: "requested")
            .select("id")
            .execute()
            .value
        if rows.isEmpty {
            throw AppError.message("That booking was already handled. Pull to refresh.")
        }
    }

    /// Declines an online booking: `requested` -> `cancelled` with a reason.
    /// `cancel_reason` is customer-facing (the public booking page shows
    /// it), so callers must present it as a message to the customer.
    static func declineBooking(shopID: UUID, jobID: UUID, reason: String?) async throws {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let change = CancelChange(
            status: "cancelled",
            cancel_reason: (trimmed?.isEmpty ?? true) ? nil : String((trimmed ?? "").prefix(1000))
        )
        let rows: [UpdatedJobRow] = try await Supa.client
            .from("jobs")
            .update(change)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .eq("status", value: "requested")
            .select("id")
            .execute()
            .value
        if rows.isEmpty {
            throw AppError.message("That booking was already handled. Pull to refresh.")
        }
    }

    // MARK: - Next job details

    /// Service address and customer name for the hero card. Technicians can
    /// read both only for jobs assigned to them (RLS); nil parts are fine.
    static func nextJobDetails(shopID: UUID, jobID: UUID) async throws -> DashboardSummaryNextJobDetails {
        let locations: [DashboardSummaryJobLocation] = try await Supa.client
            .from("jobs")
            .select(DashboardSummaryJobLocation.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let location = locations.first else {
            return DashboardSummaryNextJobDetails(location: nil, customer: nil)
        }
        let customers: [DashboardSummaryCustomerName] = try await Supa.client
            .from("customers")
            .select(DashboardSummaryCustomerName.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: location.customerID.uuidString)
            .limit(1)
            .execute()
            .value
        return DashboardSummaryNextJobDetails(location: location, customer: customers.first)
    }

    // MARK: - Shift clock

    /// The member's open time entries (shift and/or job) in this shop.
    static func openTimeEntries(shopID: UUID, memberID: UUID) async throws -> [DashboardSummaryTimeEntry] {
        try await Supa.client
            .from("time_entries")
            .select(DashboardSummaryTimeEntry.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("member_id", value: memberID.uuidString)
            .is("clock_out", value: nil)
            .order("clock_in", ascending: true)
            .execute()
            .value
    }

    /// Starts the caller's shift (`clock_in`, kind shift, source app).
    @discardableResult
    static func clockIn(shopID: UUID) async throws -> DashboardSummaryTimeEntry {
        try await Supa.client
            .rpc("clock_in", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
    }

    /// Ends the caller's shift (`clock_out`); the server also closes any
    /// open job clock.
    @discardableResult
    static func clockOut(shopID: UUID) async throws -> DashboardSummaryTimeEntry {
        try await Supa.client
            .rpc("clock_out", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
    }
}
