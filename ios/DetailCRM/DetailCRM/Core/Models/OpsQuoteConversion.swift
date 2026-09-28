//
//  OpsQuoteConversion.swift
//  DetailCRM
//
//  Quote conversion analytics (P-33, `report_quote_conversion`, ops 0078):
//  quotes sent in the range, how many were viewed / approved (converted
//  ones included) / declined / expired, the approval rate, average quote
//  and approved-quote amounts, the median time to approval, and a row per
//  month of the range (empty months included). Rates, averages and the
//  median are null when there is nothing to divide. Owners / admins /
//  managers only.
//

import Foundation

// rpc: report_quote_conversion
struct OpsQuoteConversion: Codable, Hashable, Sendable {
    var sent: Int
    var viewed: Int
    /// Approved and converted quotes.
    var approved: Int
    var declined: Int
    var expired: Int
    var converted: Int
    var conversionRateBps: Int?
    var averageQuoteCents: Int?
    var averageApprovedCents: Int?
    var medianHoursToApprove: Double?
    var byMonth: [Month]

    enum CodingKeys: String, CodingKey {
        case sent
        case viewed
        case approved
        case declined
        case expired
        case converted
        case conversionRateBps = "conversion_rate_bps"
        case averageQuoteCents = "average_quote_cents"
        case averageApprovedCents = "average_approved_cents"
        case medianHoursToApprove = "median_hours_to_approve"
        case byMonth = "by_month"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        viewed = try c.decodeIfPresent(Int.self, forKey: .viewed) ?? 0
        approved = try c.decodeIfPresent(Int.self, forKey: .approved) ?? 0
        declined = try c.decodeIfPresent(Int.self, forKey: .declined) ?? 0
        expired = try c.decodeIfPresent(Int.self, forKey: .expired) ?? 0
        converted = try c.decodeIfPresent(Int.self, forKey: .converted) ?? 0
        conversionRateBps = try c.decodeIfPresent(Int.self, forKey: .conversionRateBps)
        averageQuoteCents = try c.decodeIfPresent(Int.self, forKey: .averageQuoteCents)
        averageApprovedCents = try c.decodeIfPresent(Int.self, forKey: .averageApprovedCents)
        medianHoursToApprove = try c.decodeIfPresent(Double.self, forKey: .medianHoursToApprove)
        byMonth = try c.decodeIfPresent([Month].self, forKey: .byMonth) ?? []
    }

    /// Quotes that were sent but are neither answered nor expired yet.
    var awaiting: Int { max(0, sent - approved - declined - expired) }

    /// "3.5 hours", "2 days" for the median time to approval.
    static func durationText(hours: Double) -> String {
        if hours < 1 {
            let minutes = max(1, Int((hours * 60).rounded()))
            return "\(minutes) min"
        }
        if hours < 48 {
            let rounded = (hours * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return "\(text) hour\(rounded == 1 ? "" : "s")"
        }
        let days = (hours / 24 * 10).rounded() / 10
        let text = days == days.rounded() ? String(Int(days)) : String(format: "%.1f", days)
        return "\(text) days"
    }

    /// One month of the range (`YYYY-MM` in the shop time zone).
    // rpc: report_quote_conversion
    struct Month: Codable, Identifiable, Hashable, Sendable {
        var month: String
        var sent: Int
        var approved: Int
        var approvedCents: Int

        var id: String { month }

        enum CodingKeys: String, CodingKey {
            case month
            case sent
            case approved
            case approvedCents = "approved_cents"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            month = try c.decode(String.self, forKey: .month)
            sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
            approved = try c.decodeIfPresent(Int.self, forKey: .approved) ?? 0
            approvedCents = try c.decodeIfPresent(Int.self, forKey: .approvedCents) ?? 0
        }

        /// "Sep 2026" for `2026-09` (the raw text when it doesn't parse).
        func label(locale: Locale = .current) -> String {
            let parts = month.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let number = Int(parts[1]), (1...12).contains(number) else {
                return month
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            var components = DateComponents()
            components.year = year
            components.month = number
            components.day = 15
            guard let date = calendar.date(from: components) else { return month }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
            return formatter.string(from: date)
        }
    }
}
