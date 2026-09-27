//
//  TodayModels.swift
//  DetailCRM
//
//  What the Today tab loads in one go (Foundation only, no SwiftUI):
//  the dashboard summary, today's jobs (from `calendar_events`, so
//  technicians get only their own jobs with details), pending online
//  bookings for roles that decide on them, the next job's address and the
//  member's open time entries.
//

import Foundation
import DetailCore

struct TodaySnapshot: Sendable {
    var summary: DashboardSummary
    /// Jobs overlapping today that the viewer may open, in start order.
    var jobs: [CalendarEvent]
    /// Pending online bookings (empty for roles that can't decide).
    var requests: [DashboardSummaryBookingRequest]
    var nextJobDetails: DashboardSummaryNextJobDetails?
    /// The signed-in member's open time entries (shift and/or job).
    var openEntries: [DashboardSummaryTimeEntry]

    var openShift: DashboardSummaryTimeEntry? {
        openEntries.first { $0.isShift && $0.isOpen }
    }

    var openJobEntry: DashboardSummaryTimeEntry? {
        openEntries.first { !$0.isShift && $0.isOpen }
    }
}

enum TodayLoader {

    /// Loads everything concurrently. The summary, jobs, requests and time
    /// entries must all succeed; the next job's address is best effort (the
    /// card still shows without it).
    static func load(
        shopID: UUID,
        memberID: UUID?,
        includeRequests: Bool,
        day: DateInterval
    ) async throws -> TodaySnapshot {
        async let summaryTask = DashboardService.summary(shopID: shopID)
        async let eventsTask = CalendarService.events(shopID: shopID, from: day.start, to: day.end)
        async let requestsTask = requests(shopID: shopID, include: includeRequests)
        async let entriesTask = entries(shopID: shopID, memberID: memberID)

        let summary = try await summaryTask
        let events = try await eventsTask
        let pending = try await requestsTask
        let open = try await entriesTask

        var details: DashboardSummaryNextJobDetails?
        if let next = summary.nextJob {
            details = try? await DashboardService.nextJobDetails(shopID: shopID, jobID: next.id)
        }

        return TodaySnapshot(
            summary: summary,
            jobs: todaysJobs(from: events),
            requests: pending,
            nextJobDetails: details,
            openEntries: open
        )
    }

    /// Openable jobs only (busy blocks and blocked time are calendar-only).
    static func todaysJobs(from events: [CalendarEvent]) -> [CalendarEvent] {
        events
            .filter { $0.isOpenableJob }
            .sorted(by: CalendarService.startOrder)
    }

    private static func requests(shopID: UUID, include: Bool) async throws -> [DashboardSummaryBookingRequest] {
        guard include else { return [] }
        return try await DashboardService.bookingRequests(shopID: shopID)
    }

    private static func entries(shopID: UUID, memberID: UUID?) async throws -> [DashboardSummaryTimeEntry] {
        guard let memberID else { return [] }
        return try await DashboardService.openTimeEntries(shopID: shopID, memberID: memberID)
    }

    /// "Good morning" / "Good afternoon" / "Good evening" by shop-local hour.
    static func greeting(now: Date, clock: ShopClock) -> String {
        let minutes = clock.minutesSinceMidnight(now)
        switch minutes {
        case 0..<(12 * 60): return "Good morning"
        case (12 * 60)..<(17 * 60): return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// First word of a display name ("Sam Lee" -> "Sam").
    static func firstName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }
}
