import XCTest
@testable import DetailCore

final class JobStatusTests: XCTestCase {

    func testRawValuesMatchDatabaseEnum() {
        XCTAssertEqual(JobStatus.allCases.map(\.rawValue), [
            "requested", "scheduled", "confirmed", "en_route",
            "in_progress", "completed", "cancelled", "no_show",
        ])
    }

    func testTransitionTableMatchesMigration() {
        // 20 forward + 14 backward edges, as seeded in 0006_foundation_jobs.
        XCTAssertEqual(JobStatusTransition.all.count, 34)
        XCTAssertEqual(JobStatusTransition.all.filter { $0.direction == .forward }.count, 20)
        XCTAssertEqual(JobStatusTransition.all.filter { $0.direction == .backward }.count, 14)
        // No duplicate edges, no self-loops, technicians only forward.
        let pairs = Set(JobStatusTransition.all.map { "\($0.from.rawValue)>\($0.to.rawValue)" })
        XCTAssertEqual(pairs.count, JobStatusTransition.all.count)
        XCTAssertTrue(JobStatusTransition.all.allSatisfy { $0.from != $0.to })
        XCTAssertTrue(JobStatusTransition.all.allSatisfy { !$0.technicianAllowed || $0.direction == .forward })
        XCTAssertEqual(
            Set(JobStatusTransition.all.filter(\.technicianAllowed).map { "\($0.from.rawValue)>\($0.to.rawValue)" }),
            ["scheduled>en_route", "scheduled>in_progress", "confirmed>en_route",
             "confirmed>in_progress", "en_route>in_progress", "in_progress>completed"]
        )
    }

    func testManagersUseEveryEdge() {
        for role in [ShopRole.owner, .admin, .manager] {
            XCTAssertTrue(JobStatus.requested.canTransition(to: .scheduled, role: role, isAssigned: false))
            XCTAssertTrue(JobStatus.scheduled.canTransition(to: .completed, role: role, isAssigned: false))
            XCTAssertTrue(JobStatus.completed.canTransition(to: .inProgress, role: role, isAssigned: false))
            XCTAssertTrue(JobStatus.cancelled.canTransition(to: .scheduled, role: role, isAssigned: false))
            XCTAssertTrue(JobStatus.confirmed.canTransition(to: .noShow, role: role, isAssigned: false))
            XCTAssertTrue(JobStatus.noShow.canTransition(to: .confirmed, role: role, isAssigned: false))
            // Not in the machine at all:
            XCTAssertFalse(JobStatus.requested.canTransition(to: .completed, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.requested.canTransition(to: .noShow, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.inProgress.canTransition(to: .noShow, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.completed.canTransition(to: .cancelled, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.completed.canTransition(to: .scheduled, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.noShow.canTransition(to: .requested, role: role, isAssigned: false))
            XCTAssertFalse(JobStatus.confirmed.canTransition(to: .confirmed, role: role, isAssigned: false))
        }
        XCTAssertEqual(JobStatus.confirmed.transition(to: .scheduled)?.direction, .backward)
        XCTAssertEqual(JobStatus.confirmed.transition(to: .enRoute)?.direction, .forward)
        XCTAssertNil(JobStatus.completed.transition(to: .requested))
    }

    func testTechnicianForwardOnlyOnAssignedJobs() {
        let tech = ShopRole.technician
        XCTAssertTrue(JobStatus.scheduled.canTransition(to: .enRoute, role: tech, isAssigned: true))
        XCTAssertTrue(JobStatus.confirmed.canTransition(to: .enRoute, role: tech, isAssigned: true))
        XCTAssertTrue(JobStatus.enRoute.canTransition(to: .inProgress, role: tech, isAssigned: true))
        XCTAssertTrue(JobStatus.confirmed.canTransition(to: .inProgress, role: tech, isAssigned: true))
        XCTAssertTrue(JobStatus.inProgress.canTransition(to: .completed, role: tech, isAssigned: true))

        // Not assigned
        XCTAssertFalse(JobStatus.scheduled.canTransition(to: .enRoute, role: tech, isAssigned: false))
        // Backward
        XCTAssertFalse(JobStatus.inProgress.canTransition(to: .enRoute, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.completed.canTransition(to: .inProgress, role: tech, isAssigned: true))
        // Forward edges reserved for managers
        XCTAssertFalse(JobStatus.scheduled.canTransition(to: .confirmed, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.scheduled.canTransition(to: .completed, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.enRoute.canTransition(to: .completed, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.scheduled.canTransition(to: .cancelled, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.scheduled.canTransition(to: .noShow, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.cancelled.canTransition(to: .enRoute, role: tech, isAssigned: true))
        XCTAssertFalse(JobStatus.requested.canTransition(to: .enRoute, role: tech, isAssigned: true))
    }

    func testAllowedTargets() {
        XCTAssertEqual(
            JobStatus.confirmed.allowedTargets(role: .technician, isAssigned: true),
            [.enRoute, .inProgress]
        )
        XCTAssertEqual(JobStatus.inProgress.allowedTargets(role: .technician, isAssigned: true), [.completed])
        XCTAssertEqual(JobStatus.completed.allowedTargets(role: .technician, isAssigned: true), [])
        XCTAssertEqual(JobStatus.completed.allowedTargets(role: .manager, isAssigned: false), [.inProgress])
        XCTAssertEqual(
            JobStatus.requested.allowedTargets(role: .owner, isAssigned: false),
            [.scheduled, .confirmed, .cancelled]
        )
    }

    func testPipelineHelpers() {
        XCTAssertEqual(JobStatus.requested.nextPipelineStatus, .scheduled)
        XCTAssertEqual(JobStatus.inProgress.nextPipelineStatus, .completed)
        XCTAssertNil(JobStatus.completed.nextPipelineStatus)
        XCTAssertNil(JobStatus.cancelled.nextPipelineStatus)
        XCTAssertTrue(JobStatus.noShow.isClosed)
        XCTAssertFalse(JobStatus.enRoute.isClosed)
    }

    func testOtherEnumsRawValues() {
        XCTAssertEqual(QuoteStatus.allCases.map(\.rawValue),
                       ["draft", "sent", "viewed", "approved", "declined", "expired", "converted"])
        XCTAssertEqual(InvoiceStatus.allCases.map(\.rawValue),
                       ["draft", "open", "partially_paid", "paid", "void"])
        XCTAssertEqual(PaymentStatus.allCases.map(\.rawValue),
                       ["pending", "succeeded", "failed", "cancelled", "refunded", "partially_refunded"])
        XCTAssertEqual(PaymentMethod.allCases.map(\.rawValue),
                       ["card", "card_present", "cash", "check", "bank_transfer", "other"])
        XCTAssertEqual(MembershipStatus.allCases.map(\.rawValue),
                       ["incomplete", "active", "past_due", "cancelled"])
        XCTAssertTrue(InvoiceStatus.partiallyPaid.acceptsPayment)
        XCTAssertFalse(InvoiceStatus.void.acceptsPayment)
        XCTAssertFalse(PaymentMethod.manualMethods.contains(.card))
    }

    func testDecodesFromDatabaseStrings() throws {
        let data = Data(#"["en_route","no_show"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([JobStatus].self, from: data), [.enRoute, .noShow])
    }
}

final class CapabilityTests: XCTestCase {

    func testRoleOrdering() {
        XCTAssertTrue(ShopRole.owner > .admin)
        XCTAssertTrue(ShopRole.admin > .manager)
        XCTAssertTrue(ShopRole.manager > .technician)
        XCTAssertEqual(ShopRole.allCases.map(\.rawValue), ["owner", "admin", "manager", "technician"])
    }

    func testSettingsAndStripe() {
        XCTAssertTrue(ShopRole.owner.can(.editShopSettings))
        XCTAssertTrue(ShopRole.admin.can(.editShopSettings))
        XCTAssertFalse(ShopRole.manager.can(.editShopSettings))
        XCTAssertTrue(ShopRole.owner.can(.viewShopSettings))
        XCTAssertTrue(ShopRole.admin.can(.viewShopSettings))
        XCTAssertTrue(ShopRole.manager.can(.viewShopSettings))
        // SPEC §3: technicians read basic shop info only, never settings
        // or templates (message_templates_select is manager+).
        XCTAssertFalse(ShopRole.technician.can(.viewShopSettings))
        XCTAssertFalse(ShopRole.technician.can(.viewShopSettings,
                                                policy: ShopPolicy(techsCanCollectPayments: true)))
        XCTAssertTrue(ShopRole.admin.can(.manageStripeConnect))
        XCTAssertFalse(ShopRole.manager.can(.manageStripeConnect))
        XCTAssertTrue(ShopRole.owner.can(.deleteOrTransferShop))
        XCTAssertFalse(ShopRole.admin.can(.deleteOrTransferShop))
    }

    func testMoneyCapabilities() {
        for capability in [Capability.manageQuotes, .manageInvoices, .managePayments, .manageMemberships, .useSavedCards] {
            XCTAssertTrue(ShopRole.manager.can(capability), capability.rawValue)
            XCTAssertFalse(ShopRole.technician.can(capability), capability.rawValue)
        }
        XCTAssertTrue(ShopRole.admin.can(.refundPayments))
        XCTAssertFalse(ShopRole.manager.can(.refundPayments))
        XCTAssertFalse(ShopRole.manager.can(.voidInvoices))
    }

    func testTechnicianCollectionDependsOnShopPolicy() {
        XCTAssertFalse(ShopRole.technician.can(.collectPaymentOnAssignedJob))
        XCTAssertTrue(ShopRole.technician.can(.collectPaymentOnAssignedJob,
                                              policy: ShopPolicy(techsCanCollectPayments: true)))
        XCTAssertTrue(ShopRole.manager.can(.collectPaymentOnAssignedJob))
    }

    func testTechnicianScope() {
        let tech = ShopRole.technician
        XCTAssertFalse(tech.can(.viewAllCustomers))
        XCTAssertFalse(tech.can(.editCatalog))
        XCTAssertTrue(tech.can(.viewCatalog))
        XCTAssertFalse(tech.can(.viewAllJobs))
        XCTAssertTrue(tech.can(.progressAssignedJobs))
        XCTAssertFalse(tech.can(.viewAllReports))
        XCTAssertTrue(tech.can(.viewOwnReports))
        XCTAssertFalse(tech.can(.useInbox))
        XCTAssertTrue(tech.can(.sendJobTemplateMessages))
        XCTAssertTrue(tech.can(.useOwnTimeClock))
        XCTAssertFalse(tech.can(.editTimeEntries))
        XCTAssertFalse(tech.can(.viewAllCompensation))
        XCTAssertTrue(tech.can(.viewOwnCompensation))
        XCTAssertTrue(tech.can(.viewTeam))
        XCTAssertFalse(tech.can(.viewTeamDetails))
        XCTAssertFalse(tech.can(.viewShopSettings))
        XCTAssertFalse(tech.can(.editShopSettings))
    }

    func testTeamManagement() {
        XCTAssertTrue(ShopRole.owner.can(.manageTeam))
        XCTAssertTrue(ShopRole.admin.can(.manageTeam))
        XCTAssertFalse(ShopRole.manager.can(.manageTeam))
        XCTAssertTrue(ShopRole.manager.can(.viewTeamDetails))
        XCTAssertTrue(ShopRole.admin.can(.editCompensation))
        XCTAssertFalse(ShopRole.manager.can(.editCompensation))
    }

    func testRoleChanges() {
        XCTAssertTrue(ShopRole.owner.canChangeRole(of: .admin, to: .manager))
        XCTAssertFalse(ShopRole.owner.canChangeRole(of: .owner, to: .admin))
        XCTAssertFalse(ShopRole.owner.canChangeRole(of: .manager, to: .owner))
        XCTAssertTrue(ShopRole.admin.canChangeRole(of: .technician, to: .manager))
        XCTAssertTrue(ShopRole.admin.canChangeRole(of: .manager, to: .admin))
        XCTAssertFalse(ShopRole.admin.canChangeRole(of: .owner, to: .manager))
        XCTAssertFalse(ShopRole.admin.canChangeRole(of: .admin, to: .owner))
        XCTAssertFalse(ShopRole.manager.canChangeRole(of: .technician, to: .manager))
        XCTAssertFalse(ShopRole.owner.canChangeRole(of: .manager, to: .manager))
        XCTAssertTrue(ShopRole.admin.canDeactivate(.manager))
        XCTAssertFalse(ShopRole.admin.canDeactivate(.owner))
        XCTAssertFalse(ShopRole.manager.canDeactivate(.technician))
        XCTAssertEqual(ShopRole.manager.invitableRoles, [])
        XCTAssertFalse(ShopRole.owner.invitableRoles.contains(.owner))
    }

    func testEveryCapabilityDefinedForEveryRole() {
        // The switch in `can` is exhaustive; this guards against a future
        // capability accidentally granted to technicians but not owners.
        for capability in Capability.allCases where ShopRole.technician.can(capability) {
            XCTAssertTrue(ShopRole.owner.can(capability), capability.rawValue)
            XCTAssertTrue(ShopRole.manager.can(capability), capability.rawValue)
        }
        for capability in Capability.allCases where ShopRole.manager.can(capability) {
            XCTAssertTrue(ShopRole.admin.can(capability), capability.rawValue)
        }
        for capability in Capability.allCases where ShopRole.admin.can(capability) {
            XCTAssertTrue(ShopRole.owner.can(capability), capability.rawValue)
        }
    }
}
