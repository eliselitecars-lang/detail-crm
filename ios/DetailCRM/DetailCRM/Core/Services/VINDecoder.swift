//
//  VINDecoder.swift
//  DetailCRM
//
//  Decodes a VIN with NHTSA's free vPIC API (no key):
//  https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/<VIN>?format=json
//  The VIN is checked with DetailCore's `VIN` rules first, so obviously
//  mistyped VINs never leave the phone. vPIC returns every value as a
//  string ("" when unknown); `ErrorCode` "0" means a clean decode, other
//  codes can still carry a usable year/make/model.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DetailCore

enum VINDecoder {

    /// What vPIC knew about a VIN (nil = not reported).
    struct Decoded: Equatable, Sendable {
        var vin: String
        var year: Int?
        var make: String?
        var model: String?
        var trim: String?
        var bodyClass: String?
        /// vPIC's own note when the decode was partial (e.g. a check-digit
        /// warning), nil for a clean decode.
        var warning: String?

        /// True when vPIC recognized at least the make or model.
        var isUseful: Bool { make != nil || model != nil }

        /// "2021 Honda Civic Sport".
        var summary: String {
            [year.map { String($0) }, make, model, trim]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    enum DecodeError: LocalizedError, Equatable {
        case invalidVIN(String)
        case notFound
        case service

        var errorDescription: String? {
            switch self {
            case .invalidVIN(let message): return message
            case .notFound: return "No vehicle details were found for this VIN. Enter them by hand."
            case .service: return "The VIN lookup service didn't respond. Try again or enter the details by hand."
            }
        }
    }

    /// Checks a VIN before decoding: 17 characters, no I/O/Q. The check
    /// digit is only mandatory for North American vehicles, so a mismatch
    /// is returned as a warning rather than blocking the lookup.
    static func precheck(_ input: String) -> (vin: String, blocking: String?, warning: String?) {
        let vin = VIN.normalize(input)
        switch VIN.validate(vin, requireCheckDigit: false) {
        case .valid:
            let warning = VIN.isValid(vin, requireCheckDigit: true) ? nil : VIN.ValidationResult.invalidCheckDigit.message
            return (vin, nil, warning)
        case let problem:
            return (vin, problem.message, nil)
        }
    }

    /// The vPIC URL for a (normalized) VIN.
    static func url(for vin: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "vpic.nhtsa.dot.gov"
        components.path = "/api/vehicles/DecodeVinValues/\(vin)"
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url
    }

    /// Looks the VIN up. Throws `DecodeError` (readable text) on failure.
    static func decode(_ input: String, session: URLSession = .shared) async throws -> Decoded {
        let check = precheck(input)
        if let blocking = check.blocking { throw DecodeError.invalidVIN(blocking) }
        guard let url = url(for: check.vin) else { throw DecodeError.invalidVIN(VIN.ValidationResult.invalidCharacters.message) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DecodeError.service
        }
        guard let decoded = parse(data, vin: check.vin) else { throw DecodeError.service }
        guard decoded.isUseful else { throw DecodeError.notFound }
        return decoded
    }

    /// Parses a DecodeVinValues JSON body. Internal for testing.
    static func parse(_ data: Data, vin: String) -> Decoded? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let results = root["Results"] as? [Any],
              let first = results.first as? [String: Any] else { return nil }

        func value(_ key: String) -> String? {
            guard let text = first[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "Not Applicable" { return nil }
            return trimmed
        }

        let year = value("ModelYear").flatMap { Int($0) }.flatMap { (1886...2100).contains($0) ? $0 : nil }
        let errorCode = value("ErrorCode") ?? "0"
        let cleanCodes: Set<String> = ["0"]
        let codes = Set(errorCode.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let warning = codes.isSubset(of: cleanCodes) ? nil : value("ErrorText")

        return Decoded(
            vin: vin,
            year: year,
            make: value("Make").map { displayCase($0) }.map { clip($0, 60) },
            model: value("Model").map { clip($0, 60) },
            trim: value("Trim").map { clip($0, 60) },
            bodyClass: value("BodyClass"),
            warning: warning
        )
    }

    /// vPIC returns makes in capitals ("TOYOTA"); long all-caps words read
    /// better title-cased ("Toyota", "Mercedes-Benz") while short brand
    /// acronyms stay as they are ("BMW", "GMC", "KIA").
    static func displayCase(_ make: String) -> String {
        guard make == make.uppercased() else { return make }
        let words = make.split(separator: " ").map { word -> String in
            let text = String(word)
            if text.count <= 3 { return text }
            return text.lowercased()
                .split(separator: "-", omittingEmptySubsequences: false)
                .map { part in part.prefix(1).uppercased() + part.dropFirst() }
                .joined(separator: "-")
        }
        return words.joined(separator: " ")
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
