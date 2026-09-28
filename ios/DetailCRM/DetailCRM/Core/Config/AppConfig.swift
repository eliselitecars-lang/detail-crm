//
//  AppConfig.swift
//  DetailCRM
//
//  Reads Config.plist. The app never crashes on missing configuration:
//  `isConfigured` gates the whole UI and shows SetupRequiredView until real
//  Supabase values are supplied. Stripe keys are never bundled — the
//  `payments` edge function returns the publishable key and connected
//  account id with each PaymentSheet session.
//

import Foundation

enum AppConfig {

    private static let values: [String: String] = {
        guard
            let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any]
        else { return [:] }
        // Flags may be typed as <true/> / <false/> as well as strings.
        return dict.compactMapValues { raw in
            if let text = raw as? String { return text }
            if let flag = raw as? Bool { return flag ? "YES" : "NO" }
            return nil
        }
    }()

    static var supabaseURLString: String { value("SUPABASE_URL") }
    static var supabaseAnonKey: String { value("SUPABASE_ANON_KEY") }
    static var webAppURLString: String { value("WEB_APP_URL") }

    /// True when a value is missing or still a `YOUR_...` placeholder.
    static func isPlaceholder(_ value: String) -> Bool {
        value.isEmpty || value.hasPrefix("YOUR_")
    }

    /// The Supabase URL, when configured and well-formed.
    static var supabaseURL: URL? {
        guard !isPlaceholder(supabaseURLString),
              let url = URL(string: supabaseURLString),
              let scheme = url.scheme, scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    /// The public web app base URL (for invite and booking links), if set.
    static var webAppURL: URL? {
        guard !isPlaceholder(webAppURLString), let url = URL(string: webAppURLString),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Tap to Pay on iPhone (Stripe Terminal). Ships `NO`: turning it on
    /// also needs Apple's proximity-reader entitlement (ios/README.md). The
    /// payment screens additionally check that the device supports it.
    static var tapToPayEnabled: Bool { flag("TAP_TO_PAY_ENABLED") }

    /// Stripe Bluetooth card readers (Stripe Terminal). Ships `NO`.
    static var terminalBluetoothEnabled: Bool { flag("TERMINAL_BLUETOOTH_ENABLED") }

    /// `YES` / `true` / `1` (any case) switch a flag on; anything else,
    /// including a missing key, leaves it off.
    static func isEnabledFlag(_ raw: String) -> Bool {
        ["yes", "true", "1"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Supabase URL + anon key are required for the app to function at all.
    static var isConfigured: Bool {
        supabaseURL != nil && !isPlaceholder(supabaseAnonKey)
    }

    /// Human-readable list of what is still missing (for SetupRequiredView).
    static var missingKeys: [String] {
        var missing: [String] = []
        if supabaseURL == nil { missing.append("SUPABASE_URL") }
        if isPlaceholder(supabaseAnonKey) { missing.append("SUPABASE_ANON_KEY") }
        return missing
    }

    private static func value(_ key: String) -> String {
        (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flag(_ key: String) -> Bool {
        isEnabledFlag(value(key))
    }
}
