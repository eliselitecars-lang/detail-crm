//
//  OpsClockLocationProvider.swift
//  DetailCRM
//
//  One-shot device location for geostamped clock in / out (P-24). Asks for
//  "while using the app" permission the first time, then listens for up to
//  10 seconds and returns the best fix (good enough at 50 m or better).
//  Returns nil — and clocking goes ahead without a location — when the
//  member declines, location services are off or no fix arrives in time.
//  Nothing is tracked in the background: the location is read only at the
//  moment of the punch.
//

import Foundation
import CoreLocation

@MainActor
final class OpsClockLocationProvider: NSObject {

    static let shared = OpsClockLocationProvider()

    /// How long to wait for a fix after permission is settled.
    static let fixTimeout: Duration = .seconds(10)
    /// How long to wait for the member to answer the permission prompt.
    static let permissionTimeout: Duration = .seconds(30)
    /// A fix this good ends the wait early.
    static let goodAccuracyMeters: CLLocationAccuracy = 50
    /// The server accepts accuracies up to 10 km.
    static let maxAccuracyMeters: CLLocationAccuracy = 10_000

    private let manager: CLLocationManager
    private var fixContinuation: CheckedContinuation<TimeEntry.Spot?, Never>?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private var best: CLLocation?
    private var startedAt = Date()
    private var timeoutTask: Task<Void, Never>?
    private var permissionTimeoutTask: Task<Void, Never>?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Whether the member has turned location off for the app (clocking
    /// then records no location).
    var isDenied: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// The toast after a punch: `base`, plus why no location was recorded
    /// when `spot` is nil (Time Clock and Today use the same wording).
    func punchMessage(_ base: String, spot: TimeEntry.Spot?) -> String {
        guard spot == nil else { return base }
        if isDenied {
            return base + " Location is off for this app, so none was recorded."
        }
        return base + " Your location couldn't be read, so none was recorded."
    }

    /// The device location now, or nil (see the file header).
    func currentSpot() async -> TimeEntry.Spot? {
        // One punch at a time: a second request while one runs gets nothing.
        guard fixContinuation == nil, permissionContinuation == nil else { return nil }
        if manager.authorizationStatus == .notDetermined {
            await requestPermission()
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            return nil
        }
        return await withCheckedContinuation { continuation in
            fixContinuation = continuation
            best = nil
            startedAt = Date()
            manager.startUpdatingLocation()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: OpsClockLocationProvider.fixTimeout)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    // MARK: - Internals

    private func requestPermission() async {
        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            manager.requestWhenInUseAuthorization()
            permissionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: OpsClockLocationProvider.permissionTimeout)
                guard !Task.isCancelled else { return }
                self?.permissionSettled()
            }
        }
    }

    private func permissionSettled() {
        permissionTimeoutTask?.cancel()
        permissionTimeoutTask = nil
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume()
    }

    private func received(_ locations: [CLLocation]) {
        guard fixContinuation != nil else { return }
        for location in locations {
            // Ignore invalid readings and cached ones from before this punch.
            guard location.horizontalAccuracy >= 0,
                  location.timestamp >= startedAt.addingTimeInterval(-30) else { continue }
            if best == nil || location.horizontalAccuracy < (best?.horizontalAccuracy ?? .greatestFiniteMagnitude) {
                best = location
            }
        }
        if let best, best.horizontalAccuracy <= Self.goodAccuracyMeters {
            finish()
        }
    }

    private func failed(_ error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return // keep listening until the timeout
        }
        best = nil
        finish()
    }

    /// Stops listening and hands back the best fix so far.
    private func finish() {
        manager.stopUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = fixContinuation
        fixContinuation = nil
        var spot: TimeEntry.Spot?
        if let best {
            let coordinate = best.coordinate
            if CLLocationCoordinate2DIsValid(coordinate) {
                spot = TimeEntry.Spot(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    accuracyMeters: min(best.horizontalAccuracy, Self.maxAccuracyMeters)
                )
            }
        }
        best = nil
        continuation?.resume(returning: spot)
    }
}

extension OpsClockLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, status != .notDetermined else { return }
            self.permissionSettled()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let readings = locations
        Task { @MainActor [weak self] in
            self?.received(readings)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure = error
        Task { @MainActor [weak self] in
            self?.failed(failure)
        }
    }
}
