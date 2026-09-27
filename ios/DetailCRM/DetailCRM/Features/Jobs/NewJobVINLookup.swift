//
//  NewJobVINLookup.swift
//  DetailCRM
//
//  Tiny NHTSA vPIC client for the New Job flow (free, no key):
//  GET https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/<VIN>?format=json
//  Callers validate the VIN with DetailCore `VIN.validate` first.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Year / make / model / trim decoded from a VIN.
struct NewJobVINResult: Hashable, Sendable {
    var year: Int?
    var make: String?
    var model: String?
    var trim: String?

    var isEmpty: Bool { year == nil && make == nil && model == nil }
}

enum NewJobVINLookup {

    static func decode(_ vin: String, session: URLSession = .shared) async throws -> NewJobVINResult {
        guard let url = url(for: vin) else {
            throw AppError.invalidInput("That VIN can't be looked up.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.message("The VIN service isn't responding. Enter the details by hand.")
        }
        let result = try parse(data)
        if result.isEmpty {
            throw AppError.message("No vehicle was found for that VIN. Enter the details by hand.")
        }
        return result
    }

    static func url(for vin: String) -> URL? {
        let cleaned = vin.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard cleaned.count == 17 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "vpic.nhtsa.dot.gov"
        components.path = "/api/vehicles/DecodeVinValues/\(cleaned)"
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url
    }

    /// Reads the first `Results` row; empty strings and "Not Applicable"
    /// count as missing.
    static func parse(_ data: Data) throws -> NewJobVINResult {
        let payload = try JSONDecoder().decode(NewJobVINPayload.self, from: data)
        guard let row = payload.Results.first else { return NewJobVINResult() }
        return NewJobVINResult(
            year: clean(row.ModelYear).flatMap { Int($0) },
            make: clean(row.Make).map(titleCased),
            model: clean(row.Model),
            trim: clean(row.Trim)
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("Not Applicable") == .orderedSame { return nil }
        return trimmed
    }

    /// "MERCEDES-BENZ" -> "Mercedes-Benz"; short all-caps makes like "BMW"
    /// or "GMC" stay as they are.
    static func titleCased(_ make: String) -> String {
        guard make == make.uppercased(), make.count > 3 else { return make }
        return make.lowercased().capitalized
    }
}

// MARK: - Wire types
// Property names match vPIC's JSON keys exactly (not a database contract,
// so no CodingKeys / table annotation).

private struct NewJobVINPayload: Decodable {
    let Results: [NewJobVINRow]
}

private struct NewJobVINRow: Decodable {
    let Make: String?
    let Model: String?
    let ModelYear: String?
    let Trim: String?
}
