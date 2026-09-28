//
//  OpsMemberEarning.swift
//  DetailCRM
//
//  One job behind a member's earnings (P-12, `report_member_earnings`,
//  money 0065): the member's pre-tax revenue share of a completed job,
//  their commission, service and sales commission, tips and job hours. The
//  money columns add up to the member's `report_team` row (the server
//  allocates the rounded totals across the jobs), so the app only displays
//  them.
//
//  Access (server-enforced): owners / admins may read any member; everyone
//  else only themselves (42501).
//

import Foundation

// rpc: report_member_earnings
struct OpsMemberEarning: Codable, Identifiable, Hashable, Sendable {
    var jobID: UUID
    var jobNumber: Int
    var completedAt: Date
    /// The customer's name, or null when the job has none on file.
    var customerLabel: String?
    var hours: Double
    var revenueShareCents: Int
    var commissionCents: Int
    var serviceCommissionCents: Int
    var salesCommissionCents: Int
    var tipsCents: Int

    var id: UUID { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case jobNumber = "job_number"
        case completedAt = "completed_at"
        case customerLabel = "customer_label"
        case hours
        case revenueShareCents = "revenue_share_cents"
        case commissionCents = "commission_cents"
        case serviceCommissionCents = "service_commission_cents"
        case salesCommissionCents = "sales_commission_cents"
        case tipsCents = "tips_cents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(UUID.self, forKey: .jobID)
        jobNumber = try c.decode(Int.self, forKey: .jobNumber)
        completedAt = try c.decode(Date.self, forKey: .completedAt)
        customerLabel = try c.decodeIfPresent(String.self, forKey: .customerLabel)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? 0
        revenueShareCents = try c.decodeIfPresent(Int.self, forKey: .revenueShareCents) ?? 0
        commissionCents = try c.decodeIfPresent(Int.self, forKey: .commissionCents) ?? 0
        serviceCommissionCents = try c.decodeIfPresent(Int.self, forKey: .serviceCommissionCents) ?? 0
        salesCommissionCents = try c.decodeIfPresent(Int.self, forKey: .salesCommissionCents) ?? 0
        tipsCents = try c.decodeIfPresent(Int.self, forKey: .tipsCents) ?? 0
    }

    /// Whether the viewer can open the job. `readableJobIDs` nil = every
    /// job is readable (owners / admins / managers); otherwise only the
    /// listed ones (a technician's assigned jobs, not jobs they only sold).
    static func canOpen(jobID: UUID, readableJobIDs: Set<UUID>?) -> Bool {
        guard let readableJobIDs else { return true }
        return readableJobIDs.contains(jobID)
    }

    /// Commission of every kind plus tips on this job (hourly pay is not
    /// per job, so it is not part of this sum).
    var earnedCents: Int {
        let commission: Int = commissionCents + serviceCommissionCents + salesCommissionCents
        return commission + tipsCents
    }

    /// Totals of a list of rows (the money matches the report_team row).
    struct Totals: Equatable, Sendable {
        var jobs = 0
        var hours: Double = 0
        var revenueShareCents = 0
        var commissionCents = 0
        var serviceCommissionCents = 0
        var salesCommissionCents = 0
        var tipsCents = 0

        init(_ rows: [OpsMemberEarning] = []) {
            for row in rows {
                jobs += 1
                hours += row.hours
                revenueShareCents += row.revenueShareCents
                commissionCents += row.commissionCents
                serviceCommissionCents += row.serviceCommissionCents
                salesCommissionCents += row.salesCommissionCents
                tipsCents += row.tipsCents
            }
        }

        var earnedCents: Int {
            let commission: Int = commissionCents + serviceCommissionCents + salesCommissionCents
            return commission + tipsCents
        }
    }
}
