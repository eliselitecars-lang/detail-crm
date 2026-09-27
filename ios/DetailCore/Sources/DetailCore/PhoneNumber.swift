import Foundation

/// Phone numbers are stored as E.164 (`+12055550123`) — the database
/// rejects anything else (`public.is_valid_e164`). Input without a
/// country code is treated as North American (NANP, country code 1), the
/// default market; anything typed with a leading `+` or `00` is taken as
/// international.
public enum PhoneNumber {

    /// Normalizes free-form input to E.164, or nil when it cannot be a valid
    /// number. Extensions (`x12`, `ext. 12`) are ignored.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Drop an extension suffix.
        let lower = text.lowercased()
        for marker in ["ext.", "ext", "x", "#"] {
            if let range = lower.range(of: marker) {
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                text = String(text.prefix(offset))
                break
            }
        }

        // Only digits, spaces and common punctuation may remain.
        let allowedPunctuation: Set<Character> = [" ", "-", ".", "(", ")", "/", "\u{00A0}"]
        var international = false
        var digits = ""
        for (offset, character) in text.enumerated() {
            if character.isASCIIDigit {
                digits.append(character)
            } else if character == "+" && offset == leadingOffset(of: text) && digits.isEmpty {
                international = true
            } else if !allowedPunctuation.contains(character) {
                return nil
            }
        }

        if !international && digits.hasPrefix("00") {
            international = true
            digits.removeFirst(2)
        }

        if international {
            // E.164 as the database checks it (`public.is_valid_e164`):
            // `^\+[1-9][0-9]{6,14}$`, i.e. 7–15 digits, no leading 0.
            guard let first = digits.first, first != "0", (7...15).contains(digits.count) else {
                return nil
            }
            if digits.hasPrefix("1") {
                // NANP numbers are validated strictly.
                return nanp(String(digits.dropFirst()))
            }
            return "+" + digits
        }

        if digits.count == 11 && digits.hasPrefix("1") {
            return nanp(String(digits.dropFirst()))
        }
        if digits.count == 10 {
            return nanp(digits)
        }
        return nil
    }

    /// True when `input` normalizes to a valid number.
    public static func isValid(_ input: String) -> Bool {
        normalize(input) != nil
    }

    /// Human display: NANP numbers as `(205) 555-0123`, others as the
    /// normalized E.164 string. Unparseable input is returned unchanged.
    public static func format(_ input: String) -> String {
        guard let e164 = normalize(input) else { return input }
        guard e164.hasPrefix("+1"), e164.count == 12 else { return e164 }
        let national = Array(e164.dropFirst(2))
        let area = String(national[0..<3])
        let exchange = String(national[3..<6])
        let line = String(national[6..<10])
        return "(\(area)) \(exchange)-\(line)"
    }

    /// Digits-only form suitable for `tel:` / `sms:` URLs (keeps the `+`).
    public static func dialable(_ input: String) -> String? {
        normalize(input)
    }

    // MARK: - Private

    /// Validates a 10-digit NANP national number: area code and exchange
    /// must start with 2–9.
    private static func nanp(_ national: String) -> String? {
        guard national.count == 10, national.allSatisfy(\.isASCIIDigit) else { return nil }
        let chars = Array(national)
        guard let areaFirst = chars[0].wholeNumberValue, areaFirst >= 2,
              let exchangeFirst = chars[3].wholeNumberValue, exchangeFirst >= 2 else {
            return nil
        }
        return "+1" + national
    }

    private static func leadingOffset(of text: String) -> Int {
        var offset = 0
        for character in text {
            if character == " " || character == "\u{00A0}" || character == "(" {
                offset += 1
            } else {
                break
            }
        }
        return offset
    }
}
