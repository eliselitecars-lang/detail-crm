import Foundation

/// Renders message templates with `{{placeholder}}` tokens (SPEC §4.7).
///
/// Must behave exactly like the server renderers — SQL
/// `public.render_template` (migration 0032) and `renderTemplate()` in
/// `supabase/functions/_shared/templates.ts` — so an in-app preview shows the
/// text the customer actually receives. Both use the regex
/// `\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}`, applied left to right:
///
/// * A placeholder is `{{`, optional spaces/tabs, a name matching
///   `[A-Za-z_][A-Za-z0-9_]*` (ASCII, case-sensitive, no length cap),
///   optional spaces/tabs, `}}`. Only space and tab count as padding.
/// * Known names are replaced with their value; unknown names render as an
///   empty string.
/// * Single pass: substituted values are never re-scanned.
/// * Anything that is not a well-formed placeholder (a lone `{{`,
///   `{{ a b }}`, `{{customer.name}}`, `{{1x}}`) is left exactly as written.
///   Scanning resumes one character later, so `{{{a}}}` renders as
///   `{` + value + `}`, as the regex does.
///
/// Matching works on Unicode scalars (the pattern is pure ASCII), so
/// combining marks or emoji next to braces cannot change what matches, just
/// as with the server's code-point/code-unit regex engines.
public enum TemplateRenderer {

    public static func render(_ template: String, values: [String: String]) -> String {
        let scalars = Array(template.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if let match = matchPlaceholder(in: scalars, at: index) {
                output.append(contentsOf: (values[match.name] ?? "").unicodeScalars)
                index = match.end
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// Placeholder names used in `template`, in first-seen order, deduplicated.
    public static func placeholders(in template: String) -> [String] {
        let scalars = Array(template.unicodeScalars)
        var names: [String] = []
        var seen = Set<String>()
        var index = 0
        while index < scalars.count {
            if let match = matchPlaceholder(in: scalars, at: index) {
                if seen.insert(match.name).inserted { names.append(match.name) }
                index = match.end
            } else {
                index += 1
            }
        }
        return names
    }

    /// Whether `name` is a valid placeholder name (`[A-Za-z_][A-Za-z0-9_]*`).
    public static func isValidName(_ name: String) -> Bool {
        var scalars = name.unicodeScalars.makeIterator()
        guard let first = scalars.next(), isNameStart(first) else { return false }
        while let next = scalars.next() {
            guard isNameContinue(next) else { return false }
        }
        return true
    }

    // MARK: - Matching

    private struct Match {
        let name: String
        /// Index just past the closing `}}`.
        let end: Int
    }

    /// Anchored match of `\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}` at
    /// `start`. Padding, name characters and braces are disjoint classes, so
    /// a greedy scan accepts exactly what the regex accepts.
    private static func matchPlaceholder(in scalars: [Unicode.Scalar], at start: Int) -> Match? {
        let count = scalars.count
        var i = start
        guard i + 1 < count, scalars[i] == "{", scalars[i + 1] == "{" else { return nil }
        i += 2
        while i < count, isPadding(scalars[i]) { i += 1 }
        guard i < count, isNameStart(scalars[i]) else { return nil }
        let nameStart = i
        i += 1
        while i < count, isNameContinue(scalars[i]) { i += 1 }
        let nameEnd = i
        while i < count, isPadding(scalars[i]) { i += 1 }
        guard i + 1 < count, scalars[i] == "}", scalars[i + 1] == "}" else { return nil }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: scalars[nameStart..<nameEnd])
        return Match(name: String(name), end: i + 2)
    }

    private static func isPadding(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "_": return true
        default: return false
        }
    }

    private static func isNameContinue(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_": return true
        default: return false
        }
    }
}
