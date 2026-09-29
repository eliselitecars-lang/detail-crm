import Foundation

/// Marketing email and the shop's mailing address (0119, CAN-SPAM). Every
/// marketing email ends with the shop's postal address. While the shop has
/// no street line or no city on file, a campaign launch by email is refused
/// and every other marketing email (rebooking and maintenance follow-ups, or
/// one of those templates sent by hand) is simply not queued — nothing
/// tells the staff at send time. These rules let the phone say so where the
/// follow-ups and the address are shown (the web's `marketingAddress.ts`).
public enum MarketingAddress {

    /// Mirrors `comms_shop_postal_address` (0119): the address counts only
    /// with a street line and a city that are not blank. Postgres `btrim`
    /// drops spaces only, so only spaces are ignored here.
    public static func isOnFile(addressLine1: String?, city: String?) -> Bool {
        !isBlank(addressLine1) && !isBlank(city)
    }

    /// A maintenance follow-up that is switched on but won't be sent: an
    /// email one while the shop has no mailing address. `addressOnFile` nil
    /// (not known yet) never warns. Texts are not affected.
    public static func isBlockedFollowup(channel: String, enabled: Bool, addressOnFile: Bool?) -> Bool {
        enabled && channel.lowercased() == "email" && addressOnFile == false
    }

    /// Why marketing email stops without the address.
    public static let requiredText =
        "The law requires your shop's mailing address in every marketing email, and there's no street address and city on file."

    /// Catalog item → Follow-ups, while an email follow-up is on.
    public static let followupsBlockedText = "The email follow-ups here are on but aren't being sent."

    /// Badge of an email follow-up that is on but not sent.
    public static let notSentBadge = "Not sent"

    /// Business profile → Address: what the address is used for.
    public static let useText =
        "Marketing emails (campaigns, rebooking and maintenance follow-ups) end with this address, as the law requires."

    /// Business profile → Address, while the street line or city is blank.
    public static let missingText =
        "Without a street address and city, marketing email isn't sent: campaigns can't be launched by email, and rebooking and maintenance follow-up emails are skipped. Texts and other emails are not affected."

    /// Where the address is added: owners and admins edit it themselves.
    public static func addAddressText(canEditBusinessProfile: Bool) -> String {
        canEditBusinessProfile
            ? "Add the street address and city in Settings → Business profile."
            : "Ask an owner or admin to add it in Settings → Business profile."
    }

    /// The whole follow-ups warning.
    public static func followupsWarning(canEditBusinessProfile: Bool) -> String {
        [followupsBlockedText, requiredText, addAddressText(canEditBusinessProfile: canEditBusinessProfile)]
            .joined(separator: " ")
    }

    private static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty
    }
}
