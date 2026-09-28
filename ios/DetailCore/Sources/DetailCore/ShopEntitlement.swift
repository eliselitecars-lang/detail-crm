import Foundation

/// A shop's subscription standing as the server reports it
/// (`shop_entitlement(p_shop_id)`, a jsonb object readable by every active
/// member). The iPhone app only shows neutral status text from it: no
/// prices, no plan purchase and nothing that leads to buying (App Store
/// 3.1.1 / 3.1.3). The server enforces every rule itself; this only
/// decides what to tell people.
public struct ShopEntitlement: Decodable, Hashable, Sendable {

    /// `state`: what the shop may do right now.
    public enum State: String, Hashable, Sendable {
        case active
        case trialing
        case pastDue = "past_due"
        case lapsed
        case comped
    }

    /// Platform billing is switched on (off = every shop fully usable).
    public var billingEnabled: Bool
    /// nil for a state this build doesn't know.
    public var state: State?
    /// The raw `state` string as sent.
    public var rawState: String?
    /// Why the state is what it is (e.g. `billing_off`).
    public var reason: String?
    /// Owners, admins and managers only (null for everyone else). Never
    /// shown on the iPhone.
    public var planName: String?
    public var trialEndsAt: Date?
    public var currentPeriodEnd: Date?
    public var cancelAtPeriodEnd: Bool
    /// Seat limit of the plan (nil = unlimited).
    public var maxMembers: Int?
    /// Active members plus pending invites.
    public var membersUsed: Int?
    /// False while creating new business records is paused (lapsed).
    public var canWrite: Bool
    /// The caller is the shop's owner.
    public var isOwner: Bool

    enum CodingKeys: String, CodingKey {
        case billingEnabled = "billing_enabled"
        case state
        case reason
        case planName = "plan_name"
        case trialEndsAt = "trial_ends_at"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case maxMembers = "max_members"
        case membersUsed = "members_used"
        case canWrite = "can_write"
        case isOwner = "is_owner"
    }

    public init(
        billingEnabled: Bool,
        state: State?,
        reason: String? = nil,
        planName: String? = nil,
        trialEndsAt: Date? = nil,
        currentPeriodEnd: Date? = nil,
        cancelAtPeriodEnd: Bool = false,
        maxMembers: Int? = nil,
        membersUsed: Int? = nil,
        canWrite: Bool = true,
        isOwner: Bool = false
    ) {
        self.billingEnabled = billingEnabled
        self.state = state
        self.rawState = state?.rawValue
        self.reason = reason
        self.planName = planName
        self.trialEndsAt = trialEndsAt
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.maxMembers = maxMembers
        self.membersUsed = membersUsed
        self.canWrite = canWrite
        self.isOwner = isOwner
    }

    /// Tolerant: a missing flag takes its safe default, an unknown state
    /// stays readable as `rawState`, and timestamps are read from the
    /// strings Postgres writes into jsonb whatever the decoder's date
    /// strategy is.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        billingEnabled = try c.decodeIfPresent(Bool.self, forKey: .billingEnabled) ?? false
        rawState = try c.decodeIfPresent(String.self, forKey: .state)
        state = rawState.flatMap(State.init(rawValue:))
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
        trialEndsAt = try Self.decodeTimestamp(c, .trialEndsAt)
        currentPeriodEnd = try Self.decodeTimestamp(c, .currentPeriodEnd)
        cancelAtPeriodEnd = try c.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
        maxMembers = try c.decodeIfPresent(Int.self, forKey: .maxMembers)
        membersUsed = try c.decodeIfPresent(Int.self, forKey: .membersUsed)
        canWrite = try c.decodeIfPresent(Bool.self, forKey: .canWrite) ?? (state != .lapsed)
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
    }

    private static func decodeTimestamp(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parseTimestamp(raw)
    }

    // MARK: - What to tell people

    /// The status line the app shows, if any.
    public enum Notice: Hashable, Sendable {
        /// Owner, while trialing: when the trial ends.
        case trialEnds(Date)
        /// Owner, while a subscription payment is failing.
        case paymentProblem
        /// Everyone, while the subscription is inactive.
        case paused

        /// Neutral wording (no prices, no purchase prompts). Dates are in
        /// the shop's time zone.
        public func text(clock: ShopClock) -> String {
            switch self {
            case .trialEnds(let date):
                return "Trial ends \(clock.longDayText(date))."
            case .paymentProblem:
                return ShopEntitlement.paymentProblemText
            case .paused:
                return ShopEntitlement.pausedText
            }
        }

        /// Paused creation or a failing payment (as opposed to a reminder).
        public var isWarning: Bool {
            switch self {
            case .trialEnds: return false
            case .paymentProblem, .paused: return true
            }
        }
    }

    public static let paymentProblemText = "There's a problem with this shop's subscription payment."
    public static let pausedText =
        "This shop's subscription is inactive. Creating new jobs, quotes, invoices and customers is paused."

    /// Nothing while billing is off or the shop is active / comped. A
    /// lapsed shop (or one the server says can't write) tells everyone;
    /// the trial end and a failing payment are for the owner only.
    public var notice: Notice? {
        guard billingEnabled else { return nil }
        if state == .lapsed || !canWrite {
            return .paused
        }
        switch state {
        case .trialing:
            guard isOwner, let trialEndsAt else { return nil }
            return .trialEnds(trialEndsAt)
        case .pastDue:
            return isOwner ? .paymentProblem : nil
        case .active, .comped, .lapsed, .none:
            return nil
        }
    }

    // MARK: - "Subscription inactive" refusals (HTTP 402)

    /// A write the server refused because the shop's subscription is
    /// inactive or its plan's seat limit is reached: PostgREST answers
    /// errcode `PT402` with HTTP 402 and the database's own sentence.
    public enum PaymentRequired {
        public static let databaseCode = "PT402"
        public static let httpStatus = 402

        public static func matches(databaseCode code: String?) -> Bool {
            guard let code else { return false }
            return code.caseInsensitiveCompare(databaseCode) == .orderedSame
        }

        public static func matches(httpStatus status: Int) -> Bool {
            status == httpStatus
        }

        /// The server's message; the neutral paused text when it sent none.
        public static func message(serverMessage: String?) -> String {
            let trimmed = serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? ShopEntitlement.pausedText : trimmed
        }

        /// `message` / `error` / `msg` of a JSON error body, if any.
        public static func serverMessage(fromBody data: Data) -> String? {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            for key in ["message", "error", "msg"] {
                if let text = object[key] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
    }

    // MARK: - Timestamps

    /// Reads a Postgres timestamp as jsonb renders it
    /// (`2026-10-12T15:04:05.123456+00:00`), with or without fractional
    /// seconds, `Z` or a `±hh[:mm]` offset (none = UTC), `T` or a space.
    public static func parseTimestamp(_ raw: String) -> Date? {
        let bytes = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        func isDigit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 48 && bytes[i] <= 57 }
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= bytes.count else { return nil }
            var value = 0
            for i in from..<(from + count) {
                guard isDigit(i) else { return nil }
                value = value * 10 + Int(bytes[i] - 48)
            }
            return value
        }
        func byte(_ i: Int) -> UInt8? { i < bytes.count ? bytes[i] : nil }
        // yyyy-MM-dd(T| )HH:mm:ss
        guard let year = number(0, 4), byte(4) == UInt8(ascii: "-"),
              let month = number(5, 2), byte(7) == UInt8(ascii: "-"),
              let day = number(8, 2),
              let separator = byte(10), separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " "),
              let hour = number(11, 2), byte(13) == UInt8(ascii: ":"),
              let minute = number(14, 2), byte(16) == UInt8(ascii: ":"),
              let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else {
            return nil
        }
        var index = 19
        var fraction: TimeInterval = 0
        if byte(index) == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            let first = index
            while isDigit(index) {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
            guard index > first, index - first <= 9 else { return nil }
        }
        var offsetSeconds = 0
        if let zone = byte(index) {
            if zone == UInt8(ascii: "Z") || zone == UInt8(ascii: "z") {
                index += 1
            } else if zone == UInt8(ascii: "+") || zone == UInt8(ascii: "-") {
                guard let hours = number(index + 1, 2), hours <= 23 else { return nil }
                index += 3
                var minutes = 0
                if byte(index) == UInt8(ascii: ":") { index += 1 }
                if isDigit(index) {
                    guard let value = number(index, 2), value < 60 else { return nil }
                    minutes = value
                    index += 2
                }
                offsetSeconds = (zone == UInt8(ascii: "-") ? -1 : 1) * (hours * 3600 + minutes * 60)
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: components),
              calendar.component(.day, from: base) == day else { return nil }
        return base.addingTimeInterval(fraction - TimeInterval(offsetSeconds))
    }
}
