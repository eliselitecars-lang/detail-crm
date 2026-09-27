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
    /// Set when the booking requests failed to load (the rest of the
    /// dashboard still shows; the section renders this instead).
    var requestsError: String? = nil
    /// Set when the open time entries failed to load. The clock card must
    /// then not offer Clock in (the member may already be on the clock).
    var entriesError: String? = nil

    var openShift: DashboardSummaryTimeEntry? {
        openEntries.first { $0.isShift && $0.isOpen }
    }

    var openJobEntry: DashboardSummaryTimeEntry? {
        openEntries.first { !$0.isShift && $0.isOpen }
    }
}

/// A secondary section's rows, or why they could not be loaded.
struct TodayPartial<Item: Sendable>: Sendable {
    let items: [Item]
    let errorMessage: String?
}

enum TodayLoader {

    /// Loads everything concurrently. The summary and today's jobs must
    /// succeed (they are the dashboard). Booking requests and open time
    /// entries are secondary: a failure there degrades to an inline error
    /// in that section instead of hiding the whole screen. The next job's
    /// address is best effort (the card still shows without it).
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
        let pending: TodayPartial<DashboardSummaryBookingRequest> = await requestsTask
        let open: TodayPartial<DashboardSummaryTimeEntry> = await entriesTask

        var details: DashboardSummaryNextJobDetails?
        if let next = summary.nextJob {
            details = try? await DashboardService.nextJobDetails(shopID: shopID, jobID: next.id)
        }

        return TodaySnapshot(
            summary: summary,
            jobs: todaysJobs(from: events),
            requests: pending.items,
            nextJobDetails: details,
            openEntries: open.items,
            requestsError: pending.errorMessage,
            entriesError: open.errorMessage
        )
    }

    /// Openable jobs only (busy blocks and blocked time are calendar-only),
    /// without no-shows — matching `dashboard_summary.jobs_today.total`,
    /// which excludes cancelled and no-show jobs (the feed already leaves
    /// out cancelled ones).
    static func todaysJobs(from events: [CalendarEvent]) -> [CalendarEvent] {
        events
            .filter { $0.isOpenableJob && $0.status != .noShow && $0.status != .cancelled }
            .sorted(by: CalendarService.startOrder)
    }

    private static func requests(shopID: UUID, include: Bool) async -> TodayPartial<DashboardSummaryBookingRequest> {
        guard include else { return TodayPartial(items: [], errorMessage: nil) }
        do {
            let items = try await DashboardService.bookingRequests(shopID: shopID)
            return TodayPartial(items: items, errorMessage: nil)
        } catch {
            return TodayPartial(items: [], errorMessage: ErrorText.message(for: error))
        }
    }

    private static func entries(shopID: UUID, memberID: UUID?) async -> TodayPartial<DashboardSummaryTimeEntry> {
        guard let memberID else { return TodayPartial(items: [], errorMessage: nil) }
        do {
            let items = try await DashboardService.openTimeEntries(shopID: shopID, memberID: memberID)
            return TodayPartial(items: items, errorMessage: nil)
        } catch {
            return TodayPartial(items: [], errorMessage: ErrorText.message(for: error))
        }
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
