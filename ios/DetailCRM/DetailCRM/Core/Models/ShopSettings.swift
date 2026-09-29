//
//  ShopSettings.swift
//  DetailCRM
//
//  The settings subset the phone edits (SPEC §3: managers read, owners and
//  admins write): business profile + tax + payment policy on `shops`,
//  `booking_settings` toggles, `business_hours`, the read-only Stripe
//  Connect status, and the signed-in user's own profile / membership name.
//  Everything else (branding, templates, coupons, resources…) is edited on
//  the web.
//

import Foundation
import DetailCore

// MARK: - Business profile (shops)

/// Editable copy of the shop's profile fields. Built from `Shop`, turned
/// into a validated update payload.
struct ShopSettingsProfileDraft: Equatable, Sendable {
    var name: String
    var phone: String
    var email: String
    var addressLine1: String
    var addressLine2: String
    var city: String
    var region: String
    var postalCode: String
    var timezone: String
    var reviewURL: String

    init(shop: Shop) {
        name = shop.name
        phone = shop.phone.map { PhoneNumber.format($0) } ?? ""
        email = shop.email ?? ""
        addressLine1 = shop.addressLine1 ?? ""
        addressLine2 = shop.addressLine2 ?? ""
        city = shop.city ?? ""
        region = shop.region ?? ""
        postalCode = shop.postalCode ?? ""
        timezone = shop.timezone
        reviewURL = shop.reviewURL ?? ""
    }

    /// Field problems keyed by field name ("name", "phone", "email",
    /// "reviewURL"); empty when the draft can be saved.
    var problems: [String: String] {
        var result: [String: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            result["name"] = "Enter the business name."
        } else if trimmedName.count > 120 {
            result["name"] = "Use 120 characters or fewer."
        }
        if let phoneText = phone.trimmedNonEmpty, PhoneNumber.normalize(phoneText) == nil {
            result["phone"] = "Enter a valid phone number."
        }
        if let emailText = email.trimmedNonEmpty, !Validation.isValidEmail(emailText) {
            result["email"] = "Enter a valid email address."
        }
        if let url = reviewURL.trimmedNonEmpty {
            if url.count > 1000 {
                result["reviewURL"] = "That link is too long."
            } else if !Self.isWebURL(url) {
                result["reviewURL"] = "Enter a full link starting with https://"
            }
        }
        if addressLine1.count > 200 || addressLine2.count > 200 {
            result["address"] = "Address lines are limited to 200 characters."
        }
        if city.count > 100 || region.count > 100 || postalCode.count > 20 {
            result["address"] = "City, state or postal code is too long."
        }
        return result
    }

    /// The update payload (nil when `problems` is not empty).
    func update() -> ShopSettingsProfileUpdate? {
        guard problems.isEmpty else { return nil }
        return ShopSettingsProfileUpdate(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: phone.trimmedNonEmpty.flatMap { PhoneNumber.normalize($0) },
            email: email.trimmedNonEmpty.map { Validation.normalizedEmail($0) },
            addressLine1: addressLine1.trimmedNonEmpty,
            addressLine2: addressLine2.trimmedNonEmpty,
            city: city.trimmedNonEmpty,
            region: region.trimmedNonEmpty,
            postalCode: postalCode.trimmedNonEmpty,
            timezone: timezone,
            reviewURL: reviewURL.trimmedNonEmpty
        )
    }

    static func isWebURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, host.contains(".") else { return false }
        return true
    }
}

/// `shops` profile columns (explicit nulls clear a field).
// table: shops
struct ShopSettingsProfileUpdate: Encodable, Equatable, Sendable {
    var name: String
    var phone: String?
    var email: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var timezone: String
    var reviewURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case phone
        case email
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case timezone
        case reviewURL = "review_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(phone, forKey: .phone)
        try container.encode(email, forKey: .email)
        try container.encode(addressLine1, forKey: .addressLine1)
        try container.encode(addressLine2, forKey: .addressLine2)
        try container.encode(city, forKey: .city)
        try container.encode(region, forKey: .region)
        try container.encode(postalCode, forKey: .postalCode)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(reviewURL, forKey: .reviewURL)
    }
}

/// Tax rate on `shops`.
// table: shops
struct ShopSettingsTaxUpdate: Encodable, Sendable {
    var taxRateBps: Int

    enum CodingKeys: String, CodingKey {
        case taxRateBps = "tax_rate_bps"
    }
}

/// Payment policy switch on `shops`.
// table: shops
struct ShopSettingsCollectUpdate: Encodable, Sendable {
    var techsCanCollectPayments: Bool

    enum CodingKeys: String, CodingKey {
        case techsCanCollectPayments = "techs_can_collect_payments"
    }
}

// MARK: - Percentages in basis points

/// Percent text <-> basis points (8.25% = 825 bps), exact (no floating
/// point): at most two decimals, 0…100 %.
enum ShopSettingsPercent {

    /// "8.25" -> 825, "10" -> 1000, "0.5" -> 50; nil for anything else.
    static func basisPoints(from input: String, locale: Locale = .current) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        if separator != "." {
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty),
              whole.allSatisfy({ $0.isASCII && $0.isNumber }),
              fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
              fraction.count <= 2, whole.count <= 3 else { return nil }
        let wholeValue = Int(whole.isEmpty ? "0" : whole) ?? 0
        let padded = fraction.padding(toLength: 2, withPad: "0", startingAt: 0)
        let fractionValue = Int(padded) ?? 0
        let bps = wholeValue * 100 + fractionValue
        guard bps >= 0, bps <= 10_000 else { return nil }
        return bps
    }

    /// 825 -> "8.25", 1000 -> "10", 50 -> "0.5".
    static func text(fromBasisPoints bps: Int, locale: Locale = .current) -> String {
        let clamped = max(0, bps)
        let whole = clamped / 100
        let fraction = clamped % 100
        if fraction == 0 { return "\(whole)" }
        let separator = locale.decimalSeparator ?? "."
        var fractionText = String(format: "%02d", fraction)
        if fractionText.hasSuffix("0") { fractionText.removeLast() }
        return "\(whole)\(separator)\(fractionText)"
    }

    /// "8.25%".
    static func display(_ bps: Int) -> String {
        "\(text(fromBasisPoints: bps))%"
    }
}

// MARK: - Booking settings

// table: booking_settings
struct ShopSettingsBooking: Codable, Hashable, Sendable {
    var shopID: UUID
    var enabled: Bool
    var autoConfirm: Bool
    var leadTimeMinutes: Int
    var maxDaysAhead: Int
    var slotIntervalMinutes: Int
    var requireDeposit: Bool

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case enabled
        case autoConfirm = "auto_confirm"
        case leadTimeMinutes = "lead_time_minutes"
        case maxDaysAhead = "max_days_ahead"
        case slotIntervalMinutes = "slot_interval_minutes"
        case requireDeposit = "require_deposit"
    }

    static let selectColumns = "shop_id,enabled,auto_confirm,lead_time_minutes,max_days_ahead,slot_interval_minutes,require_deposit"
}

/// The booking switches the phone edits. Only non-nil fields are sent, so
/// each switch writes just its own column.
// table: booking_settings
struct ShopSettingsBookingUpdate: Encodable, Sendable {
    var enabled: Bool?
    var autoConfirm: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case autoConfirm = "auto_confirm"
    }

    var isEmpty: Bool { enabled == nil && autoConfirm == nil }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(autoConfirm, forKey: .autoConfirm)
    }
}

// MARK: - Business hours

/// One open interval on a weekday (0 = Sunday … 6 = Saturday), wall-clock
/// time in the shop's zone. No rows for a weekday = closed.
// table: business_hours
struct BusinessHour: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var weekday: Int
    /// Postgres `time` text: `HH:mm:ss`.
    var opensAt: String
    var closesAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case weekday
        case opensAt = "opens_at"
        case closesAt = "closes_at"
    }

    static let selectColumns = "id,shop_id,weekday,opens_at,closes_at"

    var opensMinutes: Int { ShopSettingsHours.minutes(fromTime: opensAt) ?? 0 }
    var closesMinutes: Int { ShopSettingsHours.minutes(fromTime: closesAt) ?? 0 }

    /// "9:00 AM – 5:00 PM".
    var rangeText: String {
        "\(ShopSettingsHours.label(forMinutes: opensMinutes)) – \(ShopSettingsHours.label(forMinutes: closesMinutes))"
    }
}

/// Insert / update payload for `business_hours`.
// table: business_hours
struct BusinessHourDraft: Encodable, Sendable {
    var shopID: UUID
    var weekday: Int
    var opensAt: String
    var closesAt: String

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case weekday
        case opensAt = "opens_at"
        case closesAt = "closes_at"
    }
}

/// Time-of-day helpers for the hours editor (15-minute steps).
enum ShopSettingsHours {

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func weekdayName(_ weekday: Int) -> String {
        guard weekday >= 0, weekday < weekdayNames.count else { return "Day \(weekday)" }
        return weekdayNames[weekday]
    }

    /// Weekdays in display order starting at `firstWeekday` (1 = Sunday).
    static func orderedWeekdays(firstWeekday: Int = 1) -> [Int] {
        ShopClock.orderedWeekdayNumbers(firstWeekday: firstWeekday)
    }

    /// The hours editor lists Monday first, like the web's
    /// BusinessHoursEditor, whatever week the calendar grid starts on.
    static var editorWeekdays: [Int] { ShopClock.businessHoursWeekdays }

    /// Selectable minutes since midnight: 0, 15, … 1440 (24:00).
    static let quarterHourOptions: [Int] = Array(stride(from: 0, through: 24 * 60, by: 15))

    /// The 15-minute grid plus `extra` exact values (an existing off-grid
    /// time such as 08:50 stays selectable, so saving never rounds it).
    static func pickerOptions(including extra: [Int]) -> [Int] {
        var options = Set(quarterHourOptions)
        for minutes in extra where minutes >= 0 && minutes <= 24 * 60 {
            options.insert(minutes)
        }
        return options.sorted()
    }

    /// "HH:mm[:ss]" -> minutes since midnight (24:00 -> 1440).
    static func minutes(fromTime text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let total = hour * 60 + minute
        return total <= 24 * 60 ? total : nil
    }

    /// Minutes since midnight -> Postgres `time` text ("09:30:00", "24:00:00").
    static func timeString(fromMinutes minutes: Int) -> String {
        let clamped = max(0, min(24 * 60, minutes))
        return String(format: "%02d:%02d:00", clamped / 60, clamped % 60)
    }

    /// "9:30 AM" style (locale-aware); 1440 is "Midnight".
    static func label(forMinutes minutes: Int) -> String {
        if minutes >= 24 * 60 { return "Midnight (end of day)" }
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC") ?? TimeZone.current
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = minutes / 60
        components.minute = minutes % 60
        guard let date = calendar.date(from: components) else {
            return timeString(fromMinutes: minutes)
        }
        let formatter = DateFormatter()
        formatter.timeZone = utc
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// Validation mirroring the table: closes after opens, and no overlap
    /// with the day's other intervals (`excludingID` = the row being edited).
    static func problem(
        opens: Int,
        closes: Int,
        weekday: Int,
        existing: [BusinessHour],
        excludingID: UUID?
    ) -> String? {
        guard closes > opens else { return "Closing time must be after opening time." }
        for hour in existing where hour.weekday == weekday && hour.id != excludingID {
            if opens < hour.closesMinutes && hour.opensMinutes < closes {
                return "This overlaps \(hour.rangeText) on \(weekdayName(weekday))."
            }
        }
        return nil
    }
}

// MARK: - Stripe Connect status (read only)

// table: shop_stripe_accounts
struct ShopSettingsStripeAccount: Codable, Hashable, Sendable {
    var shopID: UUID
    var stripeAccountID: String
    var chargesEnabled: Bool
    var payoutsEnabled: Bool
    var detailsSubmitted: Bool
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case stripeAccountID = "stripe_account_id"
        case chargesEnabled = "charges_enabled"
        case payoutsEnabled = "payouts_enabled"
        case detailsSubmitted = "details_submitted"
        case updatedAt = "updated_at"
    }

    static let selectColumns = "shop_id,stripe_account_id,charges_enabled,payouts_enabled,details_submitted,updated_at"

    var statusText: String {
        if chargesEnabled && payoutsEnabled { return "Connected" }
        if chargesEnabled { return "Accepting payments — payouts pending" }
        if detailsSubmitted { return "Under review by Stripe" }
        return "Setup not finished"
    }

    var tone: StatusTone {
        if chargesEnabled && payoutsEnabled { return .success }
        if chargesEnabled || detailsSubmitted { return .warning }
        return .danger
    }
}

// MARK: - Account (the signed-in user)

/// Own profile edit (`profiles`: full name + phone in E.164).
// table: profiles
struct ShopSettingsAccountUpdate: Encodable, Sendable {
    var fullName: String?
    var phone: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case phone
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fullName, forKey: .fullName)
        try container.encode(phone, forKey: .phone)
    }
}

/// Own membership display name in this shop (`shop_members`).
// table: shop_members
struct ShopSettingsMemberNameUpdate: Encodable, Sendable {
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

/// Where the web app handles what the phone doesn't (Stripe Connect etc.).
enum ShopSettingsWebLinks {
    /// `WEB_APP_URL` + `/app/settings/payments`, when configured.
    static var paymentsSettings: URL? {
        webURL(path: "/app/settings/payments")
    }

    /// `WEB_APP_URL` + `/app/settings`, when configured.
    static var settings: URL? {
        webURL(path: "/app/settings")
    }

    /// `WEB_APP_URL` + `/app/catalog`, when configured.
    static var catalog: URL? {
        webURL(path: "/app/catalog")
    }

    static func webURL(path: String) -> URL? {
        guard let base = AppConfig.webAppURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
