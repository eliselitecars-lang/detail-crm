//
//  OpsTaskService.swift
//  DetailCRM
//
//  Staff tasks (P-32) on `public.tasks`. RLS decides what each role reads
//  and writes (see OpsTask); the `tasks_80_guard` trigger stamps
//  `created_by` / `done_at` / `done_by` and refuses a technician's change
//  of assignee, customer or job (42501). Every query is scoped to the
//  active shop.
//

import Foundation
import Supabase

enum OpsTaskService {

    /// Most rows one list shows (open tasks are few; done ones are recent).
    static let openLimit = 300
    static let doneLimit = 100

    /// Tasks for the list. `.mine` = assigned to `memberID`, or created by
    /// `userID` and assigned to nobody.
    static func list(
        shopID: UUID,
        status: OpsTask.Status,
        scope: OpsTask.Scope,
        memberID: UUID?,
        userID: UUID?
    ) async throws -> [OpsTask] {
        var request = Supa.client
            .from("tasks")
            .select(OpsTask.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        switch status {
        case .open:
            request = request.is("done_at", value: nil)
        case .done:
            request = request.gt("done_at", value: "1970-01-01T00:00:00Z")
        }
        if scope == .mine {
            var parts: [String] = []
            if let memberID {
                parts.append("assignee_member_id.eq.\(memberID.uuidString.lowercased())")
            }
            if let userID {
                parts.append("and(assignee_member_id.is.null,created_by.eq.\(userID.uuidString.lowercased()))")
            }
            guard !parts.isEmpty else { return [] }
            request = request.or(parts.joined(separator: ","))
        }
        switch status {
        case .open:
            let rows: [OpsTask] = try await request
                .order("due_at", ascending: true, nullsFirst: false)
                .order("created_at", ascending: false)
                .limit(openLimit)
                .execute()
                .value
            return rows.sorted(by: OpsTask.openOrder)
        case .done:
            return try await request
                .order("done_at", ascending: false)
                .limit(doneLimit)
                .execute()
                .value
        }
    }

    static func create(shopID: UUID, draft: OpsTask.Draft) async throws -> OpsTask {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = shopID
        do {
            return try await Supa.client
                .from("tasks")
                .insert(payload, returning: .representation)
                .select(OpsTask.selectColumns)
                .single()
                .execute()
                .value
        } catch {
            throw friendly(error)
        }
    }

    static func update(shopID: UUID, taskID: UUID, draft: OpsTask.Draft) async throws -> OpsTask {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = nil
        do {
            let rows: [OpsTask] = try await Supa.client
                .from("tasks")
                .update(payload, returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: taskID.uuidString)
                .select(OpsTask.selectColumns)
                .execute()
                .value
            guard let row = rows.first else {
                throw AppError.message("This task couldn't be changed. It may have been deleted, or it isn't yours to edit.")
            }
            return row
        } catch {
            throw friendly(error)
        }
    }

    /// Marks a task done or open again (the server stamps the time and
    /// who completed it).
    static func setDone(shopID: UUID, taskID: UUID, done: Bool) async throws -> OpsTask {
        let value: AnyJSON = done ? .string(Supa.iso(Date())) : .null
        do {
            let rows: [OpsTask] = try await Supa.client
                .from("tasks")
                .update(["done_at": value], returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: taskID.uuidString)
                .select(OpsTask.selectColumns)
                .execute()
                .value
            guard let row = rows.first else {
                throw AppError.message("This task couldn't be updated. It may have been deleted.")
            }
            return row
        } catch {
            throw friendly(error)
        }
    }

    /// Deletes a task (managers+, or the member who created it).
    static func delete(shopID: UUID, taskID: UUID) async throws {
        do {
            let rows: [OpsTask] = try await Supa.client
                .from("tasks")
                .delete(returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: taskID.uuidString)
                .select(OpsTask.selectColumns)
                .execute()
                .value
            if rows.isEmpty {
                throw AppError.message("Only managers and the person who created a task can delete it.")
            }
        } catch {
            throw friendly(error)
        }
    }

    // MARK: - Names next to tasks

    /// Team members, customer names and job numbers for `tasks`. Each part
    /// is best effort: rows the caller can't read are simply missing.
    static func references(shopID: UUID, tasks: [OpsTask], current: OpsTask.References) async -> OpsTask.References {
        var result = current
        if let members = try? await TeamService.directory(shopID: shopID) {
            result.members = members
            result.membersLoaded = true
        }
        let customerIDs = Array(Set(tasks.compactMap(\.customerID)).subtracting(result.customerNames.keys))
        if !customerIDs.isEmpty, let names = try? await customerNames(shopID: shopID, ids: customerIDs) {
            result.customerNames.merge(names) { _, new in new }
        }
        let jobIDs = Array(Set(tasks.compactMap(\.jobID)).subtracting(result.jobNumbers.keys))
        if !jobIDs.isEmpty, let numbers = try? await TimeClockService.jobNumbers(shopID: shopID, jobIDs: jobIDs) {
            result.jobNumbers.merge(numbers) { _, new in new }
        }
        return result
    }

    static func customerNames(shopID: UUID, ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let rows: [JobCustomer] = try await Supa.client
            .from("customers")
            .select(JobCustomer.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: ids.map { $0.uuidString })
            .execute()
            .value
        var result: [UUID: String] = [:]
        for row in rows { result[row.id] = row.displayName }
        return result
    }

    // MARK: - Errors

    /// Readable text for the task rules the server enforces.
    static func friendly(_ error: Error) -> Error {
        guard let postgrest = error as? PostgrestError else { return error }
        switch postgrest.code {
        case "42501":
            let message = postgrest.message.lowercased()
            if message.contains("reassign") {
                return AppError.message("Only owners, admins and managers can change who a task is for, or its customer or job.")
            }
            if message.contains("row-level security") {
                return AppError.message("You can only add tasks for yourself, linked to a job you work on.")
            }
            return error
        case "23503":
            return AppError.message("That team member, customer or job is no longer in this shop.")
        case "22023":
            return AppError.message(ErrorText.sentence(postgrest.message))
        default:
            return error
        }
    }
}
