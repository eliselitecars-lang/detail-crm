//
//  TimeZonePickerView.swift
//  DetailCRM
//
//  Searchable list of IANA time zones (the server validates the choice
//  against Postgres' zone list).
//

import SwiftUI

struct TimeZonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let allIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers
        .filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        .sorted()

    private var results: [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Self.allIdentifiers }
        return Self.allIdentifiers.filter { identifier in
            identifier.localizedCaseInsensitiveContains(term.replacingOccurrences(of: " ", with: "_"))
                || Self.displayName(for: identifier).localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        List {
            let deviceZone = TimeZone.current.identifier
            if query.isEmpty, Self.allIdentifiers.contains(deviceZone) {
                Section("This device") {
                    row(for: deviceZone)
                }
            }
            Section("All time zones") {
                if results.isEmpty {
                    Text("No time zones match \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(results, id: \.self) { identifier in
                        row(for: identifier)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .screenBackground()
        .searchable(text: $query, prompt: "City or region")
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for identifier: String) -> some View {
        Button {
            selection = identifier
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(Self.cityName(for: identifier))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(Self.displayName(for: identifier))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if identifier == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.glacier)
                        .accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }

    /// "Chicago" from "America/Chicago".
    static func cityName(for identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// "America/Chicago (Central Time, GMT-5)" style label.
    static func displayName(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
        let offsetMinutes = zone.secondsFromGMT() / 60
        let sign = offsetMinutes < 0 ? "-" : "+"
        let hours = abs(offsetMinutes) / 60
        let minutes = abs(offsetMinutes) % 60
        let offset = minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT%@%d:%02d", sign, hours, minutes)
        return "\(identifier.replacingOccurrences(of: "_", with: " ")) (\(name), \(offset))"
    }
}
