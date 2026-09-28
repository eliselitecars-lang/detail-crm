import Foundation

/// The "Apply member discount" switch of a new job.
///
/// A one-off job saves the manager's choice. A repeating job does not: the
/// server creates the series and every later visit itself and always prices
/// visits with the customer's membership discount (`create_job_series`
/// takes no discount choice). So for a repeating job the switch shows on
/// and cannot be turned off, and the totals shown include the discount.
public enum MemberDiscountChoice {

    /// Whether the discount applies to what gets created.
    public static func applies(switchOn: Bool, repeating: Bool) -> Bool {
        repeating || switchOn
    }

    /// Whether the manager can turn the discount off.
    public static func isOptional(repeating: Bool) -> Bool {
        !repeating
    }

    /// Shown under the switch (and on the review) for a repeating job.
    public static let repeatingNote =
        "A repeating job always gets the member discount: every visit is priced with it."
}
