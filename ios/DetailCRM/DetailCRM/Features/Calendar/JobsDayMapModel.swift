//
//  JobsDayMapModel.swift
//  DetailCRM
//
//  The day map (P-18): the day's mobile jobs the member may open, in route
//  order (`jobs.route_position`, then start time). Jobs without
//  coordinates are geocoded on this iPhone, one at a time (Apple's
//  geocoder is rate limited), and the result is saved on the job
//  (`set_job_coordinates`) so the web map can show it too. Reordering
//  saves the stop order for the day (`set_route_order`).
//

import Foundation
import Observation
import CoreLocation
import DetailCore

@Observable
@MainActor
final class JobsDayMapModel {

    /// One mobile job on the map.
    struct Stop: Identifiable, Hashable {
        var event: CalendarEvent
        /// The job row (nil when it couldn't be read): its stored service
        /// address is what gets geocoded and sent with the point.
        var job: Job?
        var routePosition: Int?
        var latitude: Double?
        var longitude: Double?

        var id: UUID { event.id }
        var hasLocation: Bool { latitude != nil && longitude != nil }
        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        var title: String { event.displayTitle }
        var address: String? { event.serviceAddress?.trimmedNonEmpty }
        /// The address to look up: the job's own fields when the row was
        /// read (the server compares them when the point is saved).
        var geocodeAddress: String? {
            if let job { return job.serviceAddressSummary?.trimmedNonEmpty }
            return address
        }

        var routeStop: JobsRouteLinks.Stop {
            JobsRouteLinks.Stop(latitude: latitude, longitude: longitude, address: address)
        }
    }

    let day: Date
    private(set) var state: LoadState<[Stop]> = .idle
    /// Addresses being looked up right now (job ids).
    private(set) var locating: Set<UUID> = []
    /// Stops whose address couldn't be found.
    private(set) var notFound: Set<UUID> = []
    private(set) var isSavingOrder = false

    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var geocodeTask: Task<Void, Never>?
    @ObservationIgnored private let locationManager = CLLocationManager()

    init(day: Date) {
        self.day = day
    }

    var stops: [Stop] { state.value ?? [] }

    // MARK: - Loading

    func load(shopID: UUID, clock: ShopClock) async {
        state.beginLoading()
        let interval = clock.dayInterval(containing: day)
        let result = await LoadState<[Stop]>.result {
            let events = try await CalendarService.events(shopID: shopID, from: interval.start, to: interval.end)
            let mobile = events.filter { event in
                event.isOpenableJob && event.isMobile && event.status != .noShow && event.status != .cancelled
                    && interval.contains(event.startsAt)
            }
            let jobs = try await JobService.routeInfo(shopID: shopID, jobIDs: mobile.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
            let stops = mobile.map { event -> Stop in
                let job = byID[event.id]
                return Stop(
                    event: event,
                    job: job,
                    routePosition: job?.routePosition,
                    latitude: job?.serviceLat ?? event.serviceLat,
                    longitude: job?.serviceLng ?? event.serviceLng
                )
            }
            return JobsDayMapModel.ordered(stops)
        }
        state.apply(result)
        if result.value != nil {
            startGeocoding()
        }
    }

    /// Route position first (unordered stops after), then start time.
    static func ordered(_ stops: [Stop]) -> [Stop] {
        stops.sorted { lhs, rhs in
            switch (lhs.routePosition, rhs.routePosition) {
            case let (l?, r?) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                if lhs.event.startsAt != rhs.event.startsAt { return lhs.event.startsAt < rhs.event.startsAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    // MARK: - Geocoding

    /// Looks up missing coordinates one by one and saves each on its job.
    private func startGeocoding() {
        geocodeTask?.cancel()
        let pending = stops.filter { !$0.hasLocation && $0.geocodeAddress != nil && !notFound.contains($0.id) }
        guard !pending.isEmpty else { return }
        geocodeTask = Task { [weak self] in
            for stop in pending {
                guard !Task.isCancelled, let self, let address = stop.geocodeAddress else { return }
                await self.geocode(stop.id, address: address, job: stop.job)
                // Stay well under Apple's geocoding rate limit.
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func geocode(_ jobID: UUID, address: String, job: Job?) async {
        locating.insert(jobID)
        defer { locating.remove(jobID) }
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            guard let location = placemarks.first?.location else {
                notFound.insert(jobID)
                return
            }
            let coordinate = location.coordinate
            updateStop(jobID) { stop in
                stop.latitude = coordinate.latitude
                stop.longitude = coordinate.longitude
            }
            // Saved for everyone (and the web map) when the job row was
            // read; a failure (e.g. the address changed meanwhile) only
            // means the next device looks it up again.
            if let job {
                try? await JobService.setJobCoordinates(
                    job: job,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
        } catch {
            notFound.insert(jobID)
        }
    }

    private func updateStop(_ id: UUID, _ change: (inout Stop) -> Void) {
        guard var list = state.value, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        state = .loaded(list)
    }

    // MARK: - Order

    /// Moves stops (List reorder) and saves the new order for the day.
    func move(from source: IndexSet, to destination: Int, shopID: UUID) async throws {
        guard let before = state.value else { return }
        var list = Self.moved(before, from: source, to: destination)
        for index in list.indices { list[index].routePosition = index }
        state = .loaded(list)
        isSavingOrder = true
        defer { isSavingOrder = false }
        do {
            try await JobService.setRouteOrder(shopID: shopID, jobIDs: list.map(\.id))
        } catch {
            state = .loaded(before)
            throw error
        }
    }

    /// List reorder semantics (`onMove`): the rows at `source` end up
    /// together before the row that was at `destination`. Plain Foundation
    /// so the model doesn't lean on SwiftUI's `move(fromOffsets:toOffset:)`.
    static func moved<Element>(_ list: [Element], from source: IndexSet, to destination: Int) -> [Element] {
        let valid = source.filter { list.indices.contains($0) }
        guard !valid.isEmpty else { return list }
        let moving = valid.map { list[$0] }
        var rest = list.indices.filter { !valid.contains($0) }.map { list[$0] }
        let target = max(0, min(destination, list.count))
        let insertAt = target - valid.filter { $0 < target }.count
        rest.insert(contentsOf: moving, at: min(max(0, insertAt), rest.count))
        return rest
    }

    // MARK: - Location

    /// Asks for "while using" location so the map can show where you are.
    func requestLocationAccess() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    var locationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    func stopGeocoding() {
        geocodeTask?.cancel()
        geocoder.cancelGeocode()
    }
}
