import Foundation

/// Money is always an integer number of minor units ("cents") plus an
/// ISO-4217 currency code. These helpers format cents for display and turn
/// what a person typed into cents. They never do float math.
public enum Money {

    /// ISO-4217 codes Stripe treats as zero-decimal (amounts are whole units).
    public static let zeroDecimalCurrencies: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA",
        "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF",
    ]

    /// Number of minor-unit digits for a currency (2 for USD, 0 for JPY).
    public static func minorUnitDigits(for currencyCode: String) -> Int {
        zeroDecimalCurrencies.contains(currencyCode.uppercased()) ? 0 : 2
    }

    /// Converts minor units to a `Decimal` major-unit amount (1234 USD -> 12.34).
    public static func decimal(fromCents cents: Int, currencyCode: String = "USD") -> Decimal {
        let digits = minorUnitDigits(for: currencyCode)
        var value = Decimal(cents)
        for _ in 0..<digits { value /= 10 }
        return value
    }

    /// Localized currency string, e.g. `format(cents: 123456)` -> "$1,234.56"
    /// in en_US. Currency codes are case-insensitive (`usd` works).
    public static func format(
        cents: Int,
        currencyCode: String = "USD",
        locale: Locale = .current,
        showsZeroFraction: Bool = true
    ) -> String {
        let code = currencyCode.uppercased()
        let digits = minorUnitDigits(for: code)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        if !showsZeroFraction && digits > 0 && cents % pow10(digits) == 0 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        }
        let number = NSDecimalNumber(decimal: decimal(fromCents: cents, currencyCode: code))
        if let text = formatter.string(from: number) {
            return text
        }
        return fallbackFormat(cents: cents, code: code, digits: digits)
    }

    /// Parses user input ("$1,234.5", "12", "0.99") into minor units.
    ///
    /// Accepts the locale's grouping and decimal separators, a currency
    /// symbol or code, and surrounding whitespace. Returns `nil` for
    /// anything ambiguous: more fractional digits than the currency allows,
    /// several decimal separators, stray characters, a negative amount when
    /// `allowNegative` is false, or amounts above `maxCents`.
    public static func parseCents(
        _ input: String,
        currencyCode: String = "USD",
        locale: Locale = .current,
        allowNegative: Bool = false,
        maxCents: Int = 99_999_999_999
    ) -> Int? {
        let code = currencyCode.uppercased()
        let digits = minorUnitDigits(for: code)
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","

        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var negative = false
        if text.hasPrefix("-") || text.hasPrefix("\u{2212}") {
            negative = true
            text.removeFirst()
        } else if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }

        // Strip currency symbols / codes and whitespace (incl. NBSP).
        var symbols: [String] = [code, "$", "€", "£", "¥"]
        let symbolFormatter = NumberFormatter()
        symbolFormatter.locale = locale
        symbolFormatter.numberStyle = .currency
        symbolFormatter.currencyCode = code
        if let symbol = symbolFormatter.currencySymbol, !symbol.isEmpty {
            symbols.insert(symbol, at: 0)
        }
        for symbol in symbols {
            text = text.replacingOccurrences(of: symbol, with: "", options: .caseInsensitive)
        }
        if !negative && text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        }
        text = text.filter { !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "\u{202F}" }
        guard !text.isEmpty else { return nil }
        if negative && !allowNegative { return nil }

        // Grouping separators are removed only when they are not also the
        // decimal separator (some locales use "." for grouping).
        if groupingSeparator != decimalSeparator {
            text = text.replacingOccurrences(of: groupingSeparator, with: "")
        }

        let parts = text.components(separatedBy: decimalSeparator)
        guard parts.count <= 2 else { return nil }
        let wholePart = parts[0]
        let fractionPart = parts.count == 2 ? parts[1] : ""
        guard wholePart.allSatisfy(\.isASCIIDigit), fractionPart.allSatisfy(\.isASCIIDigit) else {
            return nil
        }
        guard !(wholePart.isEmpty && fractionPart.isEmpty) else { return nil }
        guard fractionPart.count <= digits else { return nil }
        guard wholePart.count <= 15 else { return nil }

        let whole = Int(wholePart.isEmpty ? "0" : wholePart) ?? 0
        let paddedFraction = fractionPart.padding(toLength: digits, withPad: "0", startingAt: 0)
        let fraction = digits == 0 ? 0 : (Int(paddedFraction) ?? 0)

        let (scaled, overflow1) = whole.multipliedReportingOverflow(by: pow10(digits))
        guard !overflow1 else { return nil }
        let (cents, overflow2) = scaled.addingReportingOverflow(fraction)
        guard !overflow2, cents <= maxCents else { return nil }
        return negative ? -cents : cents
    }

    /// Plain editable text for a cents value, without symbol or grouping
    /// ("1234.50"), suitable for pre-filling a text field.
    public static func editableString(cents: Int, currencyCode: String = "USD", locale: Locale = .current) -> String {
        let digits = minorUnitDigits(for: currencyCode)
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        if digits == 0 { return "\(sign)\(magnitude)" }
        let divisor = UInt(pow10(digits))
        let whole = magnitude / divisor
        let fraction = String(magnitude % divisor)
        let padded = String(repeating: "0", count: max(0, digits - fraction.count)) + fraction
        let separator = locale.decimalSeparator ?? "."
        return "\(sign)\(whole)\(separator)\(padded)"
    }

    // MARK: - Private

    static func pow10(_ exponent: Int) -> Int {
        var value = 1
        for _ in 0..<exponent { value *= 10 }
        return value
    }

    private static func fallbackFormat(cents: Int, code: String, digits: Int) -> String {
        "\(code) \(editableString(cents: cents, currencyCode: code, locale: Locale(identifier: "en_US_POSIX")))"
    }
}

extension Character {
    /// True for the ASCII digits 0-9 only (not other Unicode numerals).
    var isASCIIDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}
