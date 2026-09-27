//
//  Extensions.swift
//  DetailCRM
//
//  Tiny general-purpose helpers shared across features.
//

import Foundation

extension String {
    /// nil when empty, else self — handy for `??` fallbacks.
    var nonEmpty: String? { isEmpty ? nil : self }

    /// Trimmed of surrounding whitespace/newlines; nil when that is empty.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
