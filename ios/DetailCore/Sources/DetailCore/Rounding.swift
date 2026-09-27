import Foundation

/// Exact integer rounding helpers that mirror Postgres `round(numeric)`:
/// halves round away from zero (2.5 -> 3, -2.5 -> -3). All money math in
/// DetailCore goes through these so previews match the server to the cent.
public enum Rounding {

    /// `numerator / denominator` rounded half away from zero.
    /// - Precondition: `denominator > 0`.
    public static func divideHalfAwayFromZero(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator > 0, "denominator must be positive")
        let magnitude = numerator.magnitude
        let d = UInt(denominator)
        let quotient = magnitude / d
        let remainder = magnitude % d
        // remainder * 2 >= d  <=>  fractional part >= 0.5
        let roundedUp = remainder >= d - remainder
        let result = Int(quotient + (roundedUp ? 1 : 0))
        return numerator < 0 ? -result : result
    }

    /// Rounds a `Decimal` to `scale` fractional digits, half away from zero
    /// (Postgres `round(numeric, scale)` semantics).
    public static func round(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, .plain)
        return output
    }
}
