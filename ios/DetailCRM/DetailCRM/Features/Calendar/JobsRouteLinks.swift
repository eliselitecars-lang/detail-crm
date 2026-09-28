//
//  JobsRouteLinks.swift
//  DetailCRM
//
//  Hands a day's stops to a navigation app (P-18). Google Maps takes the
//  whole route in one link (origin = where the phone is, up to 9 stops in
//  between); Apple Maps is offered for the next stop. No routing API is
//  called: the maps apps plan the drive.
//

import Foundation
import MapKit

enum JobsRouteLinks {

    /// Google Maps allows at most 9 waypoints between origin and destination.
    static let maxWaypoints = 9

    /// A stop: coordinates when known, else the address text.
    struct Stop: Hashable, Sendable {
        var latitude: Double?
        var longitude: Double?
        var address: String?

        /// "lat,lng" or the address, as Google Maps reads it.
        var query: String? {
            if let latitude, let longitude {
                return String(format: "%.6f,%.6f", latitude, longitude)
            }
            return address?.trimmedNonEmpty
        }
    }

    /// Driving directions through the first ten usable stops in order,
    /// starting from the phone's location: the tenth is the destination and
    /// the nine before it are waypoints, so the route never skips a stop in
    /// the middle of the day. Nil without a usable stop. Stops past the
    /// tenth are left out (`isTruncated`).
    static func googleMapsURL(stops: [Stop]) -> URL? {
        let usable = Array(stops.compactMap(\.query).prefix(maxWaypoints + 1))
        guard let destination = usable.last else { return nil }
        let middle = Array(usable.dropLast())
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/dir/"
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        if !middle.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: middle.joined(separator: "|")))
        }
        components.queryItems = items
        return components.url
    }

    /// Whether some stops don't fit in one Google Maps link.
    static func isTruncated(stops: [Stop]) -> Bool {
        stops.compactMap(\.query).count > maxWaypoints + 1
    }

    /// Opens Apple Maps with driving directions to one stop.
    @MainActor
    static func openInAppleMaps(latitude: Double, longitude: Double, name: String) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}
