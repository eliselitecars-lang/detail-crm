import Foundation

/// Staff role inside one shop (`shop_role` enum, SPEC §3).
public enum ShopRole: String, Codable, CaseIterable, Sendable, Comparable {
    case owner
    case admin
    case manager
    case technician

    public var displayName: String {
        switch self {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .manager: return "Manager"
        case .technician: return "Technician"
        }
    }

    /// Higher rank = more authority (owner 3 … technician 0).
    public var rank: Int {
        switch self {
        case .owner: return 3
        case .admin: return 2
        case .manager: return 1
        case .technician: return 0
        }
    }

    public static func < (lhs: ShopRole, rhs: ShopRole) -> Bool {
        lhs.rank < rhs.rank
    }

    /// owner, admin or manager.
    public var isManagerOrAbove: Bool { rank >= ShopRole.manager.rank }
    /// owner or admin.
    public var isAdminOrAbove: Bool { rank >= ShopRole.admin.rank }
}

/// Everything the UI may gate by role. This is the single client-side copy
/// of the SPEC §3 capability matrix; the server enforces the same rules via
/// RLS/RPC, so hiding UI is a convenience, never the protection.
public enum Capability: String, CaseIterable, Sendable {
    // Shop setup
    /// Read shop settings, branding, taxes, booking settings and message
    /// templates (managers and above). Technicians only see the basic shop
    /// info carried by their membership (name, time zone, currency).
    case viewShopSettings
    case editShopSettings
    case manageStripeConnect
    case manageSmsNumber
    case deleteOrTransferShop

    // Team
    case viewTeam
    case viewTeamDetails
    case manageTeam
    case viewAllCompensation
    case editCompensation
    case viewOwnCompensation

    // CRM
    case viewAllCustomers
    case editCustomers

    // Catalog
    case viewCatalog
    case editCatalog

    // Jobs / calendar
    case viewAllJobs
    case editJobs
    case createJobs
    case progressAssignedJobs

    // Money
    case manageQuotes
    case manageInvoices
    case managePayments
    case manageMemberships
    case collectPaymentOnAssignedJob
    case refundPayments
    case voidInvoices
    case useSavedCards

    // Reports
    case viewAllReports
    case viewOwnReports

    // Messaging
    case useInbox
    case sendCampaigns
    case sendJobTemplateMessages

    // Time clock
    case viewAllTimeEntries
    case editTimeEntries
    case useOwnTimeClock
}

/// Shop-level switches that change what a role may do.
public struct ShopPolicy: Equatable, Sendable {
    /// `shops.techs_can_collect_payments`.
    public var techsCanCollectPayments: Bool

    public init(techsCanCollectPayments: Bool = false) {
        self.techsCanCollectPayments = techsCanCollectPayments
    }
}

extension ShopRole {

    /// Whether this role has `capability` (SPEC §3 matrix).
    public func can(_ capability: Capability, policy: ShopPolicy = ShopPolicy()) -> Bool {
        switch capability {
        case .viewTeam, .viewCatalog, .progressAssignedJobs,
             .sendJobTemplateMessages, .useOwnTimeClock:
            return true

        case .editShopSettings, .manageStripeConnect, .manageSmsNumber, .manageTeam,
             .viewAllCompensation, .editCompensation, .refundPayments, .voidInvoices:
            return isAdminOrAbove

        case .deleteOrTransferShop:
            return self == .owner

        case .viewOwnCompensation:
            return true

        case .viewShopSettings, .viewTeamDetails, .viewAllCustomers, .editCustomers, .editCatalog,
             .viewAllJobs, .editJobs, .createJobs,
             .manageQuotes, .manageInvoices, .managePayments, .manageMemberships,
             .useSavedCards, .viewAllReports, .useInbox, .sendCampaigns,
             .viewAllTimeEntries, .editTimeEntries:
            return isManagerOrAbove

        case .collectPaymentOnAssignedJob:
            return isManagerOrAbove || policy.techsCanCollectPayments

        case .viewOwnReports:
            return true
        }
    }

    /// Roles this actor may assign when inviting someone.
    public var invitableRoles: [ShopRole] {
        switch self {
        case .owner: return [.admin, .manager, .technician]
        case .admin: return [.admin, .manager, .technician]
        case .manager, .technician: return []
        }
    }

    /// Whether this actor may change a member's role from `current` to `new`.
    /// Owners and admins manage everyone except the owner, and nobody can
    /// grant `owner` here (ownership moves only via an explicit transfer).
    public func canChangeRole(of current: ShopRole, to new: ShopRole) -> Bool {
        guard current != new, isAdminOrAbove else { return false }
        return current != .owner && new != .owner
    }

    /// Whether this actor may deactivate a member holding `target`.
    public func canDeactivate(_ target: ShopRole) -> Bool {
        isAdminOrAbove && target != .owner
    }
}
