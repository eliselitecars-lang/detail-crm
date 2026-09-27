import Foundation

/// Input validation shared by forms. Server-side checks are authoritative;
/// these mirror them so people see problems before submitting.
public enum Validation {

    // MARK: - Email (mirrors public.is_valid_email)

    /// Same rule the database enforces (`public.is_valid_email`): at most
    /// 254 characters and `^[^@\s]+@[^@\s]+\.[^@\s]+$` — one `@`, no
    /// whitespace, and a dot inside the domain. Input is trimmed first.
    public static func isValidEmail(_ input: String) -> Bool {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.count <= 254,
              !email.contains(where: { $0.isWhitespace }) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = Array(parts[1])
        // `[^@\s]+\.[^@\s]+`: some dot with at least one character on each side.
        guard domain.count >= 3 else { return false }
        return domain[1..<(domain.count - 1)].contains(".")
    }

    /// Lowercased, trimmed email for storage/comparison (`citext` columns).
    public static func normalizedEmail(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Shop slug (mirrors public.is_valid_slug / create_shop)

    public static let slugMinLength = 3
    public static let slugMaxLength = 50

    /// Identical to `public.is_reserved_slug` (compared case-insensitively).
    public static let reservedSlugs: Set<String> = [
        "app", "api", "admin", "book", "booking", "login", "signup", "portal",
        "invite", "www", "support", "help", "static", "assets", "q", "i", "f",
    ]

    public enum SlugProblem: Equatable, Sendable {
        case tooShort
        case tooLong
        case invalidCharacters
        case badHyphens
        case reserved

        public var message: String {
            switch self {
            case .tooShort: return "Use at least \(Validation.slugMinLength) characters."
            case .tooLong: return "Use at most \(Validation.slugMaxLength) characters."
            case .invalidCharacters: return "Use lowercase letters, numbers and hyphens only."
            case .badHyphens: return "Start and end with a letter or number."
            case .reserved: return "That address is reserved. Try another."
            }
        }
    }

    /// Nil when `slug` is acceptable, else the first problem found. Same
    /// rule as the database: `^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$` and not
    /// reserved.
    public static func slugProblem(_ slug: String) -> SlugProblem? {
        if slug.count < slugMinLength { return .tooShort }
        if slug.count > slugMaxLength { return .tooLong }
        guard slug.allSatisfy({ $0.isASCIIDigit || ($0.isASCIILetter && $0.isLowercase) || $0 == "-" }) else {
            return .invalidCharacters
        }
        if slug.hasPrefix("-") || slug.hasSuffix("-") { return .badHyphens }
        if reservedSlugs.contains(slug.lowercased()) { return .reserved }
        return nil
    }

    public static func isValidSlug(_ slug: String) -> Bool {
        slugProblem(slug) == nil
    }

    /// Suggests a slug from a business name: ASCII-folds accents, lowercases,
    /// turns runs of anything else into single hyphens, trims to the max
    /// length. The result may still be reserved or taken.
    public static func suggestedSlug(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var slug = ""
        var pendingHyphen = false
        for character in folded {
            if character.isASCIIDigit || (character.isASCIILetter && character.isLowercase) {
                if pendingHyphen && !slug.isEmpty { slug.append("-") }
                pendingHyphen = false
                slug.append(character)
            } else {
                pendingHyphen = true
            }
        }
        if slug.count > slugMaxLength {
            slug = String(slug.prefix(slugMaxLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }

    // MARK: - Misc

    /// Non-empty after trimming.
    public static func isPresent(_ input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Minimum password rule used by sign-up (Supabase default is 6; we ask
    /// for 8).
    public static let minimumPasswordLength = 8

    public static func isAcceptablePassword(_ password: String) -> Bool {
        password.count >= minimumPasswordLength
    }
}

extension Character {
    /// True for ASCII a–z / A–Z only.
    var isASCIILetter: Bool {
        guard let ascii = asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }
}
