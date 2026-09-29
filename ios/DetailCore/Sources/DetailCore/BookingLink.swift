import Foundation

/// The customer's booking page on the web app: `WEB_APP_URL/booking/<token>`
/// (the web's `bookingPageUrl`). There the customer sees the appointment,
/// can cancel it and pays a deposit that is due. The token comes from
/// `job_booking_token` (owners, admins and managers only; it is a
/// credential, so it is asked for on demand and never stored).
public enum BookingLink {

    /// Web path of the booking page.
    public static let path = "booking"

    /// The page for `token`, or nil when the build has no web app URL or
    /// the token is empty.
    public static func url(token: String, webAppBase: URL?) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let webAppBase, !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return webAppBase
            .appendingPathComponent(path)
            .appendingPathComponent(trimmed)
    }

    /// Channels the booking link can be sent on: a text when the customer
    /// has a phone, an email when they have an address (the server still
    /// checks consent and opt-outs). Text first, like the web.
    public static func channels(hasPhone: Bool, hasEmail: Bool) -> [Channel] {
        var result: [Channel] = []
        if hasPhone { result.append(.sms) }
        if hasEmail { result.append(.email) }
        return result
    }

    public enum Channel: String, Hashable, Sendable {
        case sms
        case email

        /// "Text booking link" / "Email booking link".
        public var actionTitle: String {
            switch self {
            case .sms: return "Text booking link"
            case .email: return "Email booking link"
            }
        }

        /// Said once the message is on its way.
        public var sentText: String {
            switch self {
            case .sms: return "Booking link texted."
            case .email: return "Booking link emailed."
            }
        }
    }
}
