//
//  TimeClockService.swift
//  DetailCRM
//
//  Clocking in/out (`clock_in` / `clock_out` RPCs — the server stamps the
//  time, enforces one open entry per kind and job assignment) and the
//  timesheet reads/edits managers make directly on `time_entries` (RLS:
//  managers+ insert/update/delete; technicians read their own rows).
//

import Foundation
import Supabase
import DetailCore

enum TimeClockService {

    // MARK: - Clock in / out (self)

    /// Starts a shift (no job) or a job timer (`jobID` set).
    static func clockIn(shopID: UUID, jobID: UUID?) async throws -> TimeEntry {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_job_id: UUID?
            let p_kind: String
        }
        let params = Params(
            p_shop_id: shopID,
            p_job_id: jobID,
            p_kind: (jobID == nil ? TimeEntryKind.shift : TimeEntryKind.job).rawValue
        )
        do {
            return try await Supa.client
                .rpc("clock_in", params: params)
                .execute()
                .value
        } catch {
            throw friendly(error)
        }
    }

    /// Ends the open entry of `kind`. Ending a shift also ends a job timer.
    static func clockOut(shopID: UUID, kind: TimeEntryKind) async throws -> TimeEntry {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_kind: String
        }
        do {
            return try await Supa.client
                .rpc("clock_out", params: Params(p_shop_id: shopID, p_kind: kind.rawValue))
                .execute()
                .value
        } catch {
            throw friendly(error)
        }
    }

    // MARK: - Reads

    /// Open entries (shift and/or job) of one member.
    static func openEntries(shopID: UUID, memberID: UUID) async throws -> [TimeEntry] {
        try await Supa.client
            .from("time_entries")
            .select(TimeEntry.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("member_id", value: memberID.uuidString)
            .is("clock_out", value: nil)
            .order("clock_in", ascending: false)
            .execute()
            .value
    }

    /// Entries that start inside `interval`, optionally for one member,
    /// newest first. Technicians only ever receive their own rows (RLS).
    static func entries(shopID: UUID, memberID: UUID?, interval: DateInterval) async throws -> [TimeEntry] {
        var query = Supa.client
            .from("time_entries")
            .select(TimeEntry.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .gte("clock_in", value: Supa.iso(interval.start))
            .lt("clock_in", value: Supa.iso(interval.end))
        if let memberID {
            query = query.eq("member_id", value: memberID.uuidString)
        }
        return try await query
            .order("clock_in", ascending: false)
            .limit(1000)
            .execute()
            .value
    }

    /// Everyone currently clocked in (managers+; technicians see only themselves).
    static func openEntriesForShop(shopID: UUID) async throws -> [TimeEntry] {
        try await Supa.client
            .from("time_entries")
            .select(TimeEntry.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .is("clock_out", value: nil)
            .order("clock_in", ascending: true)
            .limit(500)
            .execute()
            .value
    }

    /// Jobs assigned to `memberID` that overlap the shop-local day
    /// containing `now` and can still be clocked (not cancelled / no-show).
    static func clockableJobsToday(shopID: UUID, memberID: UUID, clock: ShopClock, now: Date = Date()) async throws -> [TimeClockJobOption] {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_from: String
            let p_to: String
            let p_include_cancelled: Bool
        }
        let day = clock.dayInterval(containing: now)
        let rows: [TimeClockJobOption] = try await Supa.client
            .rpc("calendar_events", params: Params(
                p_shop_id: shopID,
                p_from: Supa.iso(day.start),
                p_to: Supa.iso(day.end),
                p_include_cancelled: false
            ))
            .execute()
            .value
        return rows
            .filter { $0.isClockable && $0.assignedMemberIDs.contains(memberID) }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
    }

    /// Job numbers for entries that reference jobs (ids the caller can't
    /// see are simply missing).
    static func jobNumbers(shopID: UUID, jobIDs: [UUID]) async throws -> [UUID: Int] {
        let unique = Array(Set(jobIDs))
        guard !unique.isEmpty else { return [:] }
        let rows: [TimeClockJobRef] = try await Supa.client
            .from("jobs")
            .select("id,number")
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: unique.map { $0.uuidString })
            .execute()
            .value
        var result: [UUID: Int] = [:]
        for row in rows { result[row.id] = row.number }
        return result
    }

    // MARK: - Manager edits

    /// Adds a manual entry (source is forced to `manual` by the server).
    static func addEntry(_ draft: TimeEntryDraft) async throws -> TimeEntry {
        do {
            let rows: [TimeEntry] = try await Supa.client
                .from("time_entries")
                .insert(draft, returning: .representation)
                .select(TimeEntry.selectColumns)
                .execute()
                .value
            guard let row = rows.first else {
                throw AppError.message("You don't have permission to add time entries.")
            }
            return row
        } catch {
            throw friendly(error)
        }
    }

    /// Changes the times / notes of an entry (managers+).
    static func updateEntry(shopID: UUID, entryID: UUID, edit: TimeEntryEdit) async throws -> TimeEntry {
        do {
            let rows: [TimeEntry] = try await Supa.client
                .from("time_entries")
                .update(edit, returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: entryID.uuidString)
                .select(TimeEntry.selectColumns)
                .execute()
                .value
            guard let row = rows.first else {
                throw AppError.message("That entry couldn't be changed. It may have been deleted, or you don't have permission.")
            }
            return row
        } catch {
            throw friendly(error)
        }
    }

    static func deleteEntry(shopID: UUID, entryID: UUID) async throws {
        do {
            try await Supa.client
                .from("time_entries")
                .delete()
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: entryID.uuidString)
                .execute()
        } catch {
            throw friendly(error)
        }
    }

    // MARK: - Errors

    /// Readable text for the time-clock constraint errors.
    static func friendly(_ error: Error) -> Error {
        guard let postgrest = error as? PostgrestError else { return error }
        switch postgrest.code {
        case "23P01":
            return AppError.message("This time overlaps another entry of the same kind for this person. Adjust the times and try again.")
        case "23505":
            if postgrest.message.lowercased().contains("already clocked in") {
                return AppError.message(ErrorText.sentence(postgrest.message))
            }
            return AppError.message("This person already has an open entry of that kind. Close it first.")
        case "23514":
            if postgrest.message.lowercased().contains("time_entries_order") {
                return AppError.message("Clock-out must be after clock-in.")
            }
            return error
        default:
            return error
        }
    }
}
