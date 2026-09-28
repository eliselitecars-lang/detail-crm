//
//  OpsTask.swift
//  DetailCRM
//
//  Staff to-dos (P-32, `public.tasks`, comms 0081/0084): a title, optional
//  notes, assignee, due time, customer and job.
//
//  Access (RLS + the `tasks_80_guard` trigger):
//  * owners / admins / managers: every task of the shop; create, assign to
//    anyone, link any customer or job, edit, complete, delete.
//  * technicians: tasks assigned to them or created by them; create for
//    themselves (or nobody), linked at most to a job they work (never a
//    customer); edit title / notes / due time / done; delete what they
//    created.
//  The server stamps `created_by`, `done_at` / `done_by` (on completing,
//  cleared when reopened) and resets the due reminder when the due time
//  changes. Assignees get a `task_assigned` notification and everyone a
//  `task_due` one when the due time arrives.
//

import Foundation

// table: tasks
struct OpsTask: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var title: String
    var notes: String?
    var assigneeMemberID: UUID?
    var dueAt: Date?
    var customerID: UUID?
    var jobID: UUID?
    var doneAt: Date?
    var doneBy: UUID?
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case title
        case notes
        case assigneeMemberID = "assignee_member_id"
        case dueAt = "due_at"
        case customerID = "customer_id"
        case jobID = "job_id"
        case doneAt = "done_at"
        case doneBy = "done_by"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "title", "notes", "assignee_member_id", "due_at", "customer_id", "job_id",
        "done_at", "done_by", "created_by", "created_at", "updated_at",
    ].joined(separator: ",")

    /// Database limits (CHECK constraints on `tasks`).
    static let maxTitleLength = 200
    static let maxNotesLength = 5_000

    var isDone: Bool { doneAt != nil }

    /// Open and past its due time.
    func isOverdue(now: Date = Date()) -> Bool {
        guard !isDone, let dueAt else { return false }
        return dueAt < now
    }

    /// Where an open task sits in the list.
    enum Group: Int, CaseIterable, Identifiable, Sendable {
        case overdue
        case today
        case upcoming
        case someday

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Today"
            case .upcoming: return "Upcoming"
            case .someday: return "No due date"
            }
        }
    }

    /// The group of an open task at `now` (shop-local days).
    func group(now: Date, calendar: Calendar) -> Group {
        guard let dueAt else { return .someday }
        if dueAt < now { return .overdue }
        if calendar.isDate(dueAt, inSameDayAs: now) { return .today }
        return .upcoming
    }

    /// Open tasks in list order: by due time (none last), then newest.
    static func openOrder(_ lhs: OpsTask, _ rhs: OpsTask) -> Bool {
        switch (lhs.dueAt, rhs.dueAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// Which tasks the list shows.
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        /// Assigned to me, or created by me and assigned to nobody.
        case mine
        /// Every task the caller may read (managers: the whole shop).
        case everyone

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mine: return "Mine"
            case .everyone: return "Everyone"
            }
        }
    }

    /// Open (to do) or done.
    enum Status: String, CaseIterable, Identifiable, Sendable {
        case open
        case done

        var id: String { rawValue }

        var title: String {
            switch self {
            case .open: return "To do"
            case .done: return "Done"
            }
        }
    }

    /// Fields a create / edit writes. `created_by`, `done_by` and the due
    /// reminder stamp are server-set and never sent. On an edit every field
    /// is sent (nil clears it); the server refuses a technician's change of
    /// assignee, customer or job, so the editor only offers those to
    /// managers.
    // table: tasks
    struct Draft: Encodable, Equatable, Sendable {
        var title: String = ""
        var notes: String = ""
        var assigneeMemberID: UUID?
        var dueAt: Date?
        var customerID: UUID?
        var jobID: UUID?
        /// Set by the service for inserts only.
        var shopID: UUID?

        enum CodingKeys: String, CodingKey {
            case shopID = "shop_id"
            case title
            case notes
            case assigneeMemberID = "assignee_member_id"
            case dueAt = "due_at"
            case customerID = "customer_id"
            case jobID = "job_id"
        }

        init() {}

        init(task: OpsTask) {
            title = task.title
            notes = task.notes ?? ""
            assigneeMemberID = task.assigneeMemberID
            dueAt = task.dueAt
            customerID = task.customerID
            jobID = task.jobID
        }

        var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// First problem that blocks saving, if any (mirrors the CHECKs).
        var validationError: String? {
            if trimmedTitle.isEmpty { return "Give the task a title." }
            if trimmedTitle.count > OpsTask.maxTitleLength { return "Titles are limited to \(OpsTask.maxTitleLength) characters." }
            if notes.count > OpsTask.maxNotesLength { return "Notes are limited to \(OpsTask.maxNotesLength) characters." }
            return nil
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let shopID {
                try container.encode(shopID, forKey: .shopID)
            }
            try container.encode(trimmedTitle, forKey: .title)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            try container.encode(trimmedNotes.isEmpty ? nil : trimmedNotes, forKey: .notes)
            try container.encode(assigneeMemberID, forKey: .assigneeMemberID)
            try container.encode(dueAt, forKey: .dueAt)
            try container.encode(customerID, forKey: .customerID)
            try container.encode(jobID, forKey: .jobID)
        }
    }

    /// Names shown next to tasks: members, customers and job numbers (ids
    /// the caller may not read are simply missing).
    struct References: Equatable, Sendable {
        var members: [TeamDirectoryEntry] = []
        /// Whether the team directory has loaded at least once. Until it
        /// has, an unknown assignee gets no label (not "Former team
        /// member": the list may simply not be here yet, or failed).
        var membersLoaded = false
        var customerNames: [UUID: String] = [:]
        var jobNumbers: [UUID: Int] = [:]

        /// The assignee's name; "Former team member" only when the loaded
        /// directory doesn't have them (removed, or deactivated and hidden
        /// from technicians); nil while the directory is unknown.
        func memberName(_ id: UUID?) -> String? {
            guard let id else { return nil }
            if let name = members.first(where: { $0.memberID == id })?.displayName {
                return name
            }
            return membersLoaded ? "Former team member" : nil
        }
    }
}
