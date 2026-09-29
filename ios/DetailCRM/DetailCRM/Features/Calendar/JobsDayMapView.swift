//
//  JobsDayMapView.swift
//  DetailCRM
//
//  A day's mobile jobs on a map (P-18): numbered pins in route order,
//  where you are (when location is allowed), the stop list with drag to
//  reorder (saved for everyone), and hand-off of the whole route to Google
//  Maps or the next stop to Apple Maps. Addresses without coordinates are
//  looked up on this iPhone and saved on the job.
//

import SwiftUI
import MapKit
import DetailCore

struct JobsDayMapView: View {
    let day: Date

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL
    @State private var model: JobsDayMapModel
    @State private var position: MapCameraPosition = .automatic
    @State private var editMode: EditMode = .inactive

    init(day: Date) {
        self.day = day
        _model = State(initialValue: JobsDayMapModel(day: day))
    }

    var body: some View {
        LoadStateView(model.state, loadingLabel: "Loading the day's route…", retry: { await load() }) { stops in
            content(stops)
        }
        .screenBackground()
        .navigationTitle(appState.clock.relativeDayText(day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if (model.state.value?.count ?? 0) > 1 {
                    EditButton()
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task { await load() }
        .onDisappear { model.stopGeocoding() }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else { return }
        await model.load(shopID: shopID, clock: appState.clock)
    }

    // MARK: - Content (AnyView seam: map + list are large generic trees)

    private func content(_ stops: [JobsDayMapModel.Stop]) -> AnyView {
        if stops.isEmpty {
            return AnyView(
                EmptyStateView(
                    systemImage: "map",
                    title: "No mobile jobs",
                    message: "Mobile jobs scheduled for this day appear here in route order."
                )
            )
        }
        return AnyView(
            VStack(spacing: 0) {
                map(stops)
                    .frame(height: 300)
                handOffBar(stops)
                stopList(stops)
            }
        )
    }

    private func map(_ stops: [JobsDayMapModel.Stop]) -> some View {
        let located = stops.filter(\.hasLocation)
        return Map(position: $position) {
            UserAnnotation()
            ForEach(located) { stop in
                Annotation(stop.title, coordinate: stop.coordinate ?? CLLocationCoordinate2D()) {
                    let number = (stops.firstIndex(where: { $0.id == stop.id }) ?? 0) + 1
                    Text("\(number)")
                        .font(Theme.Typography.captionEmphasis)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.glacierSolid))
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                        .accessibilityLabel("Stop \(number), \(stop.title)")
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onAppear { model.requestLocationAccess() }
    }

    private func handOffBar(_ stops: [JobsDayMapModel.Stop]) -> some View {
        let routeStops = stops.map(\.routeStop)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                if let url = JobsRouteLinks.googleMapsURL(stops: routeStops) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Route in Google Maps", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .buttonStyle(.themePrimaryCompact)
                }
                if let next = nextStop(stops), let latitude = next.latitude, let longitude = next.longitude {
                    Button {
                        JobsRouteLinks.openInAppleMaps(latitude: latitude, longitude: longitude, name: next.title)
                    } label: {
                        Label("Next stop", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                }
            }
            if JobsRouteLinks.isTruncated(stops: routeStops) {
                Text("Google Maps takes the first 10 stops; open the rest from their jobs.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.locationDenied {
                Text("Location is off for Detail CRM, so the map can't show where you are.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first stop that isn't finished yet.
    private func nextStop(_ stops: [JobsDayMapModel.Stop]) -> JobsDayMapModel.Stop? {
        stops.first { stop in
            stop.event.status != .completed && stop.hasLocation
        }
    }

    private func stopList(_ stops: [JobsDayMapModel.Stop]) -> some View {
        List {
            Section {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    NavigationLink(value: AppRoute.job(stop.id)) {
                        stopRow(stop, number: index + 1)
                    }
                    .themedRow()
                }
                .onMove { source, destination in
                    Task { await move(source, destination) }
                }
            } footer: {
                Text(editMode.isEditing
                     ? "Drag stops into the order you'll drive them. The order is saved for the whole team."
                     : "Tap Edit to change the stop order.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    private func stopRow(_ stop: JobsDayMapModel.Stop, number: Int) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(number)")
                .font(Theme.Typography.captionEmphasis)
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(stop.hasLocation ? Theme.glacierSolid : Theme.neutralSolid))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(stop.title)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Text(appState.clock.rangeText(from: stop.event.startsAt, to: stop.event.endsAt))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if let address = stop.address {
                    Text(address)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                locationNote(stop)
            }
            Spacer(minLength: 0)
            if let status = stop.event.status {
                StatusBadge(status)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stopAccessibilityLabel(stop, number: number))
    }

    /// Everything the row shows, in reading order: VoiceOver hears the time,
    /// address, status and any warning, not just the stop number and title.
    private func stopAccessibilityLabel(_ stop: JobsDayMapModel.Stop, number: Int) -> String {
        var parts = [
            "Stop \(number)",
            stop.title,
            appState.clock.rangeText(from: stop.event.startsAt, to: stop.event.endsAt),
        ]
        if let address = stop.address?.trimmedNonEmpty {
            parts.append(address)
        }
        if let status = stop.event.status {
            parts.append(status.displayName)
        }
        if let note = locationNoteText(stop) {
            parts.append(note.text)
        }
        return parts.joined(separator: ", ")
    }

    /// The row's map warning or progress line, if any (`isWarning` picks
    /// the colour).
    private func locationNoteText(_ stop: JobsDayMapModel.Stop) -> (text: String, isWarning: Bool)? {
        if model.locating.contains(stop.id) {
            return ("Finding this address…", false)
        }
        if model.notFound.contains(stop.id) {
            return ("Couldn't place this address on the map. Check it on the job.", true)
        }
        if stop.address == nil {
            return ("No service address on this job.", true)
        }
        return nil
    }

    @ViewBuilder
    private func locationNote(_ stop: JobsDayMapModel.Stop) -> some View {
        if let note = locationNoteText(stop) {
            Text(note.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(note.isWarning ? Theme.warningInk : Theme.textTertiary)
        }
    }

    private func move(_ source: IndexSet, _ destination: Int) async {
        guard let shopID = appState.shop?.id else { return }
        do {
            try await model.move(from: source, to: destination, shopID: shopID)
            toasts.show("Stop order saved")
        } catch {
            toasts.showError(error)
        }
    }
}
