import Foundation

/// Vehicle Identification Number checks (ISO 3779 / 49 CFR 565).
public enum VIN {

    public enum ValidationResult: Equatable, Sendable {
        case valid
        case invalidLength
        /// Contains a character outside A–Z/0–9 or one of I, O, Q.
        case invalidCharacters
        /// Position 9 does not match the North American check digit.
        case invalidCheckDigit

        public var message: String {
            switch self {
            case .valid: return "Valid VIN."
            case .invalidLength: return "A VIN has exactly 17 characters."
            case .invalidCharacters: return "A VIN uses only letters and numbers, never I, O or Q."
            case .invalidCheckDigit: return "This VIN's check digit doesn't match. Double-check each character."
            }
        }
    }

    /// Uppercases and strips spaces/dashes so pasted or scanned VINs compare.
    public static func normalize(_ input: String) -> String {
        input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Validates a VIN. `requireCheckDigit` enforces the position-9 check
    /// digit, which is mandatory for North American vehicles (model year
    /// 1981+) but not for many other markets.
    public static func validate(_ input: String, requireCheckDigit: Bool = true) -> ValidationResult {
        let vin = normalize(input)
        guard vin.count == 17 else { return .invalidLength }
        guard vin.allSatisfy({ transliteration[$0] != nil }) else { return .invalidCharacters }
        if requireCheckDigit {
            guard let expected = checkDigit(for: vin), Array(vin)[8] == expected else {
                return .invalidCheckDigit
            }
        }
        return .valid
    }

    public static func isValid(_ input: String, requireCheckDigit: Bool = true) -> Bool {
        validate(input, requireCheckDigit: requireCheckDigit) == .valid
    }

    /// The expected check digit ("0"–"9" or "X") for a 17-character VIN, or
    /// nil when it contains invalid characters.
    public static func checkDigit(for input: String) -> Character? {
        let vin = Array(normalize(input))
        guard vin.count == 17 else { return nil }
        var sum = 0
        for (index, character) in vin.enumerated() {
            guard let value = transliteration[character] else { return nil }
            sum += value * weights[index]
        }
        let remainder = sum % 11
        if remainder == 10 { return "X" }
        return Character(String(remainder))
    }

    /// Model year from position 10 (30-year cycle). Position 7 disambiguates
    /// the cycle for passenger vehicles: a letter means 2010 or later.
    public static func modelYear(_ input: String) -> Int? {
        let vin = Array(normalize(input))
        guard vin.count == 17 else { return nil }
        let codes: [Character] = Array("ABCDEFGHJKLMNPRSTVWXY123456789")
        guard let index = codes.firstIndex(of: vin[9]) else { return nil }
        let base = 1980 + index
        let seventhIsLetter = vin[6].isLetter
        return seventhIsLetter ? base + 30 : base
    }

    // MARK: - Tables

    static let weights: [Int] = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

    static let transliteration: [Character: Int] = {
        var table: [Character: Int] = [:]
        for digit in 0...9 { table[Character(String(digit))] = digit }
        let letters: [(Character, Int)] = [
            ("A", 1), ("B", 2), ("C", 3), ("D", 4), ("E", 5), ("F", 6), ("G", 7), ("H", 8),
            ("J", 1), ("K", 2), ("L", 3), ("M", 4), ("N", 5), ("P", 7), ("R", 9),
            ("S", 2), ("T", 3), ("U", 4), ("V", 5), ("W", 6), ("X", 7), ("Y", 8), ("Z", 9),
        ]
        for (letter, value) in letters { table[letter] = value }
        return table
    }()
}
