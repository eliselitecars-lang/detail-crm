import Foundation

/// The job page's Time section (the web job page's `TimeCard`): the job's
/// time entries with their total, who is on the clock for the job right
/// now, and the one clock action the signed-in member gets there.
///
/// The server stamps every punch and enforces the rules (`clock_in`: one
/// open entry per member and kind, only a member who can work the job,
/// never on a cancelled or no-show job); this only decides what to show.
public enum JobTime {

    /// One `time_entries` row of the job, reduced to what the section needs.
    public struct Entry: Hashable, Sendable {
        public var id: UUID
        public var memberID: UUID
        public var clockIn: Date
        /// nil while the entry is open (the member is still on the clock).
        public var clockOut: Date?

        public init(id: UUID, memberID: UUID, clockIn: Date, clockOut: Date?) {
            self.id = id
            self.memberID = memberID
            self.clockIn = clockIn
            self.clockOut = clockOut
        }

        public var isOpen: Bool { clockOut == nil }

        /// Worked seconds; an open entry runs until `now` (never negative).
        public func seconds(now: Date) -> Int {
            let end = clockOut ?? max(now, clockIn)
            return max(0, Int(end.timeIntervalSince(clockIn)))
        }
    }

    /// Totals over the job's entries.
    public struct Summary: Hashable, Sendable {
        /// Worked seconds over every entry (open ones run until `now`).
        public var totalSeconds: Int
        /// Seconds of the entries that are closed (the figure that no
        /// longer changes).
        public var closedSeconds: Int
        public var entryCount: Int
        /// Members on the clock for this job now, earliest clock-in first,
        /// each once (a member has at most one open job entry, but a list
        /// from two reads may briefly repeat one).
        public var openMemberIDs: [UUID]

        public var isEmpty: Bool { entryCount == 0 }
        public var hasOpenEntries: Bool { !openMemberIDs.isEmpty }
    }

    public static func summary(of entries: [Entry], now: Date) -> Summary {
        var total = 0
        var closed = 0
        var open: [UUID] = []
        for entry in entries.sorted(by: { $0.clockIn < $1.clockIn }) {
            let seconds = entry.seconds(now: now)
            total += seconds
            if entry.isOpen {
                if !open.contains(entry.memberID) { open.append(entry.memberID) }
            } else {
                closed += seconds
            }
        }
        return Summary(totalSeconds: total, closedSeconds: closed, entryCount: entries.count, openMemberIDs: open)
    }

    /// Newest first (the order the section lists them in).
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.clockIn != rhs.clockIn { return lhs.clockIn > rhs.clockIn }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The clock action the signed-in member gets on the job page.
    public enum Action: Hashable, Sendable {
        /// Assigned, no job timer running, the job still open.
        case clockIn
        /// Their job timer runs on this job (offered even once the job is
        /// closed, so a timer left running can still be stopped).
        case clockOut
        /// Their job timer runs on another job: clock out there first.
        case clockedInElsewhere
        /// Not assigned, or the job is completed / cancelled / no-show.
        case none
    }

    /// `openJobTimerJobID` is the job of the member's open `job` entry
    /// (nil when no job timer runs; job entries always name their job).
    public static func action(
        jobID: UUID,
        jobStatus: JobStatus,
        isAssigned: Bool,
        openJobTimerJobID: UUID?
    ) -> Action {
        guard isAssigned else { return .none }
        if let running = openJobTimerJobID {
            return running == jobID ? .clockOut : .clockedInElsewhere
        }
        return jobStatus.isClosed ? .none : .clockIn
    }

    /// Whether the job page shows the Time section: always while the job
    /// is open; once it is completed, cancelled or no-show only when time
    /// was recorded on it (the entries and their total stay visible, with
    /// no clock-in).
    public static func showsSection(jobStatus: JobStatus, entryCount: Int) -> Bool {
        !jobStatus.isClosed || entryCount > 0
    }
}
