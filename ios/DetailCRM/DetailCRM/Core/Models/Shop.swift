//
//  Shop.swift
//  DetailCRM
//
//  The tenant. Mirrors `public.shops` (SPEC §4.1). `sms_from_number` is
//  intentionally not selected here — staff read it through an RPC.
//

import Foundation
import DetailCore

/// `business_type` enum: where the shop does the work.
enum BusinessType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed
    case mobile
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fixed: return "At my shop"
        case .mobile: return "Mobile (I go to customers)"
        case .both: return "Both"
        }
    }

    var systemImage: String {
        switch self {
        case .fixed: return "building.2"
        case .mobile: return "car.side"
        case .both: return "arrow.triangle.branch"
        }
    }
}

// table: shops
struct Shop: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var slug: String
    var email: String?
    var phone: String?
    var website: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String
    var lat: Double?
    var lng: Double?
    var timezone: String
    var currency: String
    var logoPath: String?
    var brandColor: String?
    var businessType: BusinessType
    var taxRateBps: Int
    var techsCanCollectPayments: Bool
    var reviewURL: String?
    var invoiceDueDays: Int
    var createdAt: Date
    var updatedAt: Date
    /// Technicians on a job may publish and send its customer report (P-8).
    var techsCanShareReports: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case email
        case phone
        case website
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case country
        case lat
        case lng
        case timezone
        case currency
        case logoPath = "logo_path"
        case brandColor = "brand_color"
        case businessType = "business_type"
        case taxRateBps = "tax_rate_bps"
        case techsCanCollectPayments = "techs_can_collect_payments"
        case reviewURL = "review_url"
        case invoiceDueDays = "invoice_due_days"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case techsCanShareReports = "techs_can_share_reports"
    }

    /// Explicit column list for `.select(...)` (keeps `sms_from_number` and
    /// long terms text out of routine fetches).
    static let selectColumns = [
        "id", "name", "slug", "email", "phone", "website",
        "address_line1", "address_line2", "city", "region", "postal_code", "country",
        "lat", "lng", "timezone", "currency", "logo_path", "brand_color", "business_type",
        "tax_rate_bps", "techs_can_collect_payments", "review_url", "invoice_due_days",
        "created_at", "updated_at", "techs_can_share_reports",
    ].joined(separator: ",")

    /// Calendar math and formatting in the shop's time zone. Its display
    /// week (the calendar grid) starts on Sunday like the web calendar; every
    /// "This week" total (reports, payments, hours) uses
    /// `totalsWeekInterval`, which starts on Monday like the server's
    /// `date_trunc('week')` and the web app.
    var clock: ShopClock {
        ShopClock(timeZoneIdentifier: timezone)
    }

    /// Role-dependent switches (SPEC §3).
    var policy: ShopPolicy {
        ShopPolicy(
            techsCanCollectPayments: techsCanCollectPayments,
            techsCanShareReports: techsCanShareReports ?? false
        )
    }

    /// Single-line address for display and map links, if any part is set.
    var addressSummary: String? {
        let cityLine = [city, region, postalCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let parts = [addressLine1, addressLine2, cityLine]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
