//
//  TodayCards.swift
//  DetailCRM
//
//  The two action cards of the Today tab: the "next up" hero card (who,
//  what car, when, where — with a Maps link) and the compact shift clock
//  (clock_in / clock_out with a running timer). The full timesheet lives
//  in TimeClockView (Ops group).
//

import SwiftUI
import DetailCore

// MARK: - Next up

struct TodayNextJobCard: View {
    let job: DashboardSummaryNextJob
    let details: DashboardSummaryNextJobDetails?
    /// Technicians see the customer's first name; managers the full name.
    let useFirstName: Bool
    let context: TodayContext

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("NEXT UP")
                    .font(Theme.Typography.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(Theme.glacier)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(job.status)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(customerName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let vehicle = job.vehicleLabel?.trimmedNonEmpty {
                    Label(vehicle, systemImage: "car")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Label(whenText, systemImage: "clock")
                .font(Theme.Typography.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            TodayNextJobPlace(
                place: place,
                directions: directionsURL,
                openURL: { url in openURL(url) }
            )

            NavigationLink(value: AppRoute.job(job.id)) {
                Text("Open job")
            }
            .buttonStyle(.themePrimary)
        }
        .cardStyle()
    }

    private var customerName: String {
        if useFirstName, let first = details?.customer?.greetingName {
            return first
        }
        if let full = details?.customer?.fullName, !useFirstName {
            return full
        }
        let name = job.customerName?.trimmedNonEmpty ?? "Customer"
        return useFirstName ? TodayLoader.firstName(name) : name
    }

    private var whenText: String {
        let clock = context.clock
        let day = clock.relativeDayText(job.scheduledStart)
        return "\(day), \(clock.rangeText(from: job.scheduledStart, to: job.scheduledEnd))"
    }

    /// Where the work happens: the service address for mobile jobs, the
    /// shop's address otherwise.
    private var place: TodayNextJobPlaceInfo {
        let mobile = details?.location?.isMobile ?? job.isMobile
        if mobile {
            return TodayNextJobPlaceInfo(
                title: "Mobile job",
                address: details?.location?.serviceAddress,
                systemImage: "car.side"
            )
        }
        return TodayNextJobPlaceInfo(
            title: "At the shop",
            address: context.shopAddress,
            systemImage: "building.2"
        )
    }

    private var directionsURL: URL? {
        let mobile = details?.location?.isMobile ?? job.isMobile
        if mobile, let location = details?.location {
            if let lat = location.serviceLat, let lng = location.serviceLng {
                return MapLinks.directions(latitude: lat, longitude: lng, name: location.serviceAddress)
            }
            if let address = location.serviceAddress {
                return MapLinks.directions(toAddress: address)
            }
            return nil
        }
        if !mobile, let address = context.shopAddress {
            return MapLinks.directions(toAddress: address)
        }
        return nil
    }
}

struct TodayNextJobPlaceInfo {
    let title: String
    let address: String?
    let systemImage: String
}

private struct TodayNextJobPlace: View {
    let place: TodayNextJobPlaceInfo
    let directions: URL?
    let openURL: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: place.systemImage)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(place.title)
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(place.address ?? "No address on file")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(place.address == nil ? Theme.textTertiary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let directions {
                Button {
                    openURL(directions)
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                .buttonStyle(.themeSecondaryCompact)
                .accessibilityLabel("Directions in Maps")
            }
        }
    }
}

// MARK: - Shift clock

struct TodayClockCard: View {
    let openShift: DashboardSummaryTimeEntry?
    let openJobEntry: DashboardSummaryTimeEntry?
    let clock: ShopClock
    let onClockIn: () async -> Void
    let onClockOut: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: openShift == nil ? "clock" : "clock.fill")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(openShift == nil ? Theme.textSecondary : Theme.successInk)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(openShift == nil ? "Off the clock" : "On the clock")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                statusDetail
            }

            Spacer(minLength: Theme.Spacing.sm)

            if openShift != nil {
                Button("Clock out", action: onClockOut)
                    .buttonStyle(.themeSecondaryCompact)
            } else {
                AsyncButton("Clock in", style: .themePrimaryCompact) {
                    await onClockIn()
                }
            }
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusDetail: some View {
        if let shift = openShift {
            HStack(spacing: Theme.Spacing.xs) {
                Text(shift.clockIn, style: .timer)
                    .font(Theme.Typography.money)
                    .foregroundStyle(Theme.successInk)
                Text("since \(clock.timeText(shift.clockIn))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if let job = openJobEntry {
            Text("Clocked in to a job since \(clock.timeText(job.clockIn))")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text("Clock in when your shift starts.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
