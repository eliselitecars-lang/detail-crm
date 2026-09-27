import Foundation

/// Visual tone a status maps to; the app turns it into Theme colors.
public enum StatusTone: String, Sendable {
    case neutral
    case info
    case success
    case warning
    case danger
    case money
}

// MARK: - Job status (SPEC §4.4)

/// `job_status`: requested → scheduled → confirmed → en_route →
/// in_progress → completed, with side exits cancelled and no_show.
public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case requested
    case scheduled
    case confirmed
    case enRoute = "en_route"
    case inProgress = "in_progress"
    case completed
    case cancelled
    case noShow = "no_show"

    /// The forward pipeline, in order (side exits excluded).
    public static let pipeline: [JobStatus] = [
        .requested, .scheduled, .confirmed, .enRoute, .inProgress, .completed,
    ]

    public var displayName: String {
        switch self {
        case .requested: return "Requested"
        case .scheduled: return "Scheduled"
        case .confirmed: return "Confirmed"
        case .enRoute: return "On the way"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .noShow: return "No-show"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .requested: return .warning
        case .scheduled, .confirmed: return .info
        case .enRoute, .inProgress: return .info
        case .completed: return .success
        case .cancelled, .noShow: return .danger
        }
    }

    /// Position in the pipeline, or nil for side exits.
    public var pipelineIndex: Int? { Self.pipeline.firstIndex(of: self) }

    /// cancelled or no_show.
    public var isSideExit: Bool { self == .cancelled || self == .noShow }

    /// Nothing further happens on the job (completed, cancelled, no_show).
    public var isClosed: Bool { self == .completed || isSideExit }

    /// The transition edge from `self` to `target`, if the status machine
    /// allows it at all (mirrors `public.job_status_transitions`).
    public func transition(to target: JobStatus) -> JobStatusTransition? {
        JobStatusTransition.all.first { $0.from == self && $0.to == target }
    }

    /// Whether `role` may move a job from `self` to `target`.
    ///
    /// * The edge must exist in the status machine (`job_status_transitions`).
    /// * Owners, admins and managers may use every edge, forward or backward.
    /// * Technicians may use only edges marked technician-allowed (forward
    ///   along en_route / in_progress / completed), and only on jobs
    ///   assigned to them.
    public func canTransition(to target: JobStatus, role: ShopRole, isAssigned: Bool) -> Bool {
        guard let edge = transition(to: target) else { return false }
        if role.isManagerOrAbove { return true }
        return isAssigned && edge.technicianAllowed
    }

    /// The statuses `role` may choose next, in display order.
    public func allowedTargets(role: ShopRole, isAssigned: Bool) -> [JobStatus] {
        JobStatus.allCases.filter { canTransition(to: $0, role: role, isAssigned: isAssigned) }
    }

    /// The natural next step on the pipeline (used for the primary action
    /// button), or nil when closed.
    public var nextPipelineStatus: JobStatus? {
        guard let index = pipelineIndex, index + 1 < Self.pipeline.count else { return nil }
        return Self.pipeline[index + 1]
    }
}

/// One allowed edge of the job status machine. `all` is an exact copy of
/// the rows seeded into `public.job_status_transitions` (0006_foundation_jobs).
public struct JobStatusTransition: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case forward
        case backward
    }

    public let from: JobStatus
    public let to: JobStatus
    public let direction: Direction
    /// Technicians may take this edge on jobs assigned to them.
    public let technicianAllowed: Bool

    public static let all: [JobStatusTransition] = [
        // forward
        .init(from: .requested, to: .scheduled, direction: .forward, technicianAllowed: false),
        .init(from: .requested, to: .confirmed, direction: .forward, technicianAllowed: false),
        .init(from: .requested, to: .cancelled, direction: .forward, technicianAllowed: false),
        .init(from: .scheduled, to: .confirmed, direction: .forward, technicianAllowed: false),
        .init(from: .scheduled, to: .enRoute, direction: .forward, technicianAllowed: true),
        .init(from: .scheduled, to: .inProgress, direction: .forward, technicianAllowed: true),
        .init(from: .scheduled, to: .completed, direction: .forward, technicianAllowed: false),
        .init(from: .scheduled, to: .cancelled, direction: .forward, technicianAllowed: false),
        .init(from: .scheduled, to: .noShow, direction: .forward, technicianAllowed: false),
        .init(from: .confirmed, to: .enRoute, direction: .forward, technicianAllowed: true),
        .init(from: .confirmed, to: .inProgress, direction: .forward, technicianAllowed: true),
        .init(from: .confirmed, to: .completed, direction: .forward, technicianAllowed: false),
        .init(from: .confirmed, to: .cancelled, direction: .forward, technicianAllowed: false),
        .init(from: .confirmed, to: .noShow, direction: .forward, technicianAllowed: false),
        .init(from: .enRoute, to: .inProgress, direction: .forward, technicianAllowed: true),
        .init(from: .enRoute, to: .completed, direction: .forward, technicianAllowed: false),
        .init(from: .enRoute, to: .cancelled, direction: .forward, technicianAllowed: false),
        .init(from: .enRoute, to: .noShow, direction: .forward, technicianAllowed: false),
        .init(from: .inProgress, to: .completed, direction: .forward, technicianAllowed: true),
        .init(from: .inProgress, to: .cancelled, direction: .forward, technicianAllowed: false),
        // backward (owner/admin/manager only)
        .init(from: .scheduled, to: .requested, direction: .backward, technicianAllowed: false),
        .init(from: .confirmed, to: .requested, direction: .backward, technicianAllowed: false),
        .init(from: .confirmed, to: .scheduled, direction: .backward, technicianAllowed: false),
        .init(from: .enRoute, to: .scheduled, direction: .backward, technicianAllowed: false),
        .init(from: .enRoute, to: .confirmed, direction: .backward, technicianAllowed: false),
        .init(from: .inProgress, to: .scheduled, direction: .backward, technicianAllowed: false),
        .init(from: .inProgress, to: .confirmed, direction: .backward, technicianAllowed: false),
        .init(from: .inProgress, to: .enRoute, direction: .backward, technicianAllowed: false),
        .init(from: .completed, to: .inProgress, direction: .backward, technicianAllowed: false),
        .init(from: .cancelled, to: .requested, direction: .backward, technicianAllowed: false),
        .init(from: .cancelled, to: .scheduled, direction: .backward, technicianAllowed: false),
        .init(from: .cancelled, to: .confirmed, direction: .backward, technicianAllowed: false),
        .init(from: .noShow, to: .scheduled, direction: .backward, technicianAllowed: false),
        .init(from: .noShow, to: .confirmed, direction: .backward, technicianAllowed: false),
    ]
}

// MARK: - Quote status (SPEC §4.5)

public enum QuoteStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case sent
    case viewed
    case approved
    case declined
    case expired
    case converted

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .sent: return "Sent"
        case .viewed: return "Viewed"
        case .approved: return "Approved"
        case .declined: return "Declined"
        case .expired: return "Expired"
        case .converted: return "Converted"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .draft: return .neutral
        case .sent, .viewed: return .info
        case .approved, .converted: return .success
        case .declined, .expired: return .danger
        }
    }

    /// Staff may still edit lines while the customer has not answered.
    public var isEditable: Bool { self == .draft || self == .sent || self == .viewed }

    /// Waiting on the customer.
    public var isAwaitingCustomer: Bool { self == .sent || self == .viewed }
}

// MARK: - Invoice status (SPEC §4.5)

public enum InvoiceStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case open
    case partiallyPaid = "partially_paid"
    case paid
    case void

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .open: return "Open"
        case .partiallyPaid: return "Partially paid"
        case .paid: return "Paid"
        case .void: return "Void"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .draft: return .neutral
        case .open, .partiallyPaid: return .money
        case .paid: return .success
        case .void: return .danger
        }
    }

    /// Money can still be collected.
    public var acceptsPayment: Bool { self == .open || self == .partiallyPaid }
}

// MARK: - Payment status / kind / method (SPEC §4.5)

public enum PaymentStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case succeeded
    case failed
    case cancelled
    case refunded
    case partiallyRefunded = "partially_refunded"

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .succeeded: return "Paid"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .refunded: return "Refunded"
        case .partiallyRefunded: return "Partially refunded"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .pending: return .warning
        case .succeeded: return .success
        case .failed, .cancelled: return .danger
        case .refunded, .partiallyRefunded: return .neutral
        }
    }

    /// Counts toward `amount_paid_cents` (net of refunds).
    public var countsTowardPaid: Bool {
        self == .succeeded || self == .partiallyRefunded
    }
}

public enum PaymentKind: String, Codable, CaseIterable, Sendable {
    case deposit
    case payment
    case membership

    public var displayName: String {
        switch self {
        case .deposit: return "Deposit"
        case .payment: return "Payment"
        case .membership: return "Membership"
        }
    }
}

public enum PaymentMethod: String, Codable, CaseIterable, Sendable {
    case card
    case cardPresent = "card_present"
    case cash
    case check
    case bankTransfer = "bank_transfer"
    case other

    public var displayName: String {
        switch self {
        case .card: return "Card"
        case .cardPresent: return "Card (in person)"
        case .cash: return "Cash"
        case .check: return "Check"
        case .bankTransfer: return "Bank transfer"
        case .other: return "Other"
        }
    }

    /// Methods staff may record by hand via `record_manual_payment`
    /// (card rows are written only by the Stripe webhook).
    public static let manualMethods: [PaymentMethod] = [.cash, .check, .bankTransfer, .other]
}

public enum MembershipStatus: String, Codable, CaseIterable, Sendable {
    case incomplete
    case active
    case pastDue = "past_due"
    case cancelled

    public var displayName: String {
        switch self {
        case .incomplete: return "Incomplete"
        case .active: return "Active"
        case .pastDue: return "Past due"
        case .cancelled: return "Cancelled"
        }
    }

    public var tone: StatusTone {
        switch self {
        case .incomplete: return .warning
        case .active: return .success
        case .pastDue: return .danger
        case .cancelled: return .neutral
        }
    }
}
