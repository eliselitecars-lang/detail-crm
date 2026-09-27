//
//  Links.swift
//  DetailCRM
//
//  URL builders for Apple Maps directions, phone calls, texts and email.
//  Views open them with `@Environment(\.openURL)`. No force unwraps: every
//  builder returns nil when the input can't form a valid URL.
//

import Foundation
import DetailCore

enum MapLinks {

    /// Driving directions to a free-form address in Apple Maps.
    static func directions(toAddress address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return appleMapsURL([
            URLQueryItem(name: "daddr", value: trimmed),
            URLQueryItem(name: "dirflg", value: "d"),
        ])
    }

    /// Driving directions to coordinates, labeled with `name` when given.
    static func directions(latitude: Double, longitude: Double, name: String? = nil) -> URL? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var items = [
            URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        if let name, !name.isEmpty {
            items.append(URLQueryItem(name: "q", value: name))
        }
        return appleMapsURL(items)
    }

    /// A map pin search for an address.
    static func search(_ query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return appleMapsURL([URLQueryItem(name: "q", value: trimmed)])
    }

    private static func appleMapsURL(_ items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = items
        return components.url
    }
}

enum ContactLinks {

    /// `tel:` URL for a phone number in any common format.
    static func call(_ phone: String) -> URL? {
        guard let e164 = PhoneNumber.normalize(phone) else { return nil }
        return URL(string: "tel:\(e164)")
    }

    /// `sms:` URL, optionally with a pre-filled body.
    static func text(_ phone: String, body: String? = nil) -> URL? {
        guard let e164 = PhoneNumber.normalize(phone) else { return nil }
        var components = URLComponents()
        components.scheme = "sms"
        components.path = e164
        if let body, !body.isEmpty {
            components.queryItems = [URLQueryItem(name: "body", value: body)]
        }
        return components.url
    }

    /// `mailto:` URL, optionally with a subject.
    static func email(_ address: String, subject: String? = nil) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.isValidEmail(trimmed) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = trimmed
        if let subject, !subject.isEmpty {
            components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        }
        return components.url
    }
}
