//
//  CompactTitle.swift
//  DetailCore
//
//  A title laid out for a very narrow box (the calendar's Week columns,
//  about 45 pt wide on an iPhone): whole words, one per line, so a line
//  that doesn't fit is truncated ("Christo…") instead of the word being
//  broken mid-word ("Christo / pher").
//

import Foundation

public enum CompactTitle {

    /// The title's words, one per line, at most `maxLines` lines; the last
    /// line carries every remaining word ("Mary Ann Van Dyke" in three
    /// lines is "Mary", "Ann", "Van Dyke"). Whitespace runs collapse; an
    /// empty title gives no lines.
    public static func lines(_ title: String, maxLines: Int) -> [String] {
        let words = title.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard maxLines > 0, !words.isEmpty else { return [] }
        guard words.count > maxLines else { return words }
        let head = Array(words.prefix(maxLines - 1))
        let rest = words.dropFirst(maxLines - 1).joined(separator: " ")
        return head + [rest]
    }
}
