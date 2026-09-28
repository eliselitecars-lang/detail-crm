//
//  TodayBookingRequests.swift
//  DetailCRM
//
//  Online bookings still waiting for a decision (manager+). Approve moves
//  the job to Scheduled (the server sends the customer the
//  booking-confirmed message when that template is enabled); Decline
//  cancels it with an optional reason that the customer sees on their
//  booking page (`jobs.cancel_reason`).
//

import SwiftUI
import DetailCore

struct TodayBookingRequestsSection: View {
    let requests: [DashboardSummaryBookingRequest]
    /// Server count of all pending requests (may exceed the loaded page).
    let totalPending: Int
    let context: TodayContext
    let actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: totalPending > 0 ? "Booking requests (\(totalPending))" : "Booking requests")
            ForEach(requests) { request in
                TodayBookingRequestCard(request: request, context: context, actions: actions)
            }
            if totalPending > requests.count {
                // Requests without a requested time sort last and never
                // appear in the Calendar (it lists scheduled jobs only), so
                // point at deciding these first rather than at the Calendar.
                Text("Showing the first \(requests.count) of \(totalPending). Approve or decline these to see the rest.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

private struct TodayBookingRequestCard: View {
    let request: DashboardSummaryBookingRequest
    let context: TodayContext
    let actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(request.customerName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: request.job.totalCents, currencyCode: context.currencyCode, size: .small)
            }
            if let vehicle = request.vehicleLabel {
                Label(vehicle, systemImage: "car")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !request.serviceNames.isEmpty {
                Text(request.serviceNames.joined(separator: ", "))
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(whenText, systemImage: "calendar")
                .font(Theme.Typography.subheadline.weight(.medium))
                .foregroundStyle(request.job.scheduledStart == nil ? Theme.warningInk : Theme.textPrimary)

            if context.canDecideBookings {
                AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                    Button("Approve") { actions.approve(request) }
                        .buttonStyle(.themePrimaryCompact)
                        .disabled(request.job.scheduledStart == nil)
                    Button("Decline") { actions.decline(request) }
                        .buttonStyle(.themeSecondaryCompact)
                    Spacer(minLength: 0)
                    NavigationLink(value: AppRoute.job(request.job.id)) {
                        Text("Details")
                    }
                    .buttonStyle(.themePlain)
                }
                if request.job.scheduledStart == nil {
                    InlineMessage(text: "Open the job and pick a time before approving.", kind: .info)
                }
            } else {
                NavigationLink(value: AppRoute.job(request.job.id)) {
                    Text("Details")
                }
                .buttonStyle(.themeSecondaryCompact)
            }
        }
        .cardStyle()
    }

    private var whenText: String {
        guard let start = request.job.scheduledStart else { return "No time requested" }
        let clock = context.clock
        let end = request.job.scheduledEnd ?? start
        return "\(clock.relativeDayText(start)), \(clock.rangeText(from: start, to: end))"
    }
}

// MARK: - Decline sheet

struct TodayDeclineSheet: View {
    let request: DashboardSummaryBookingRequest
    /// Returns true when the booking was declined (the sheet then closes).
    let onDecline: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(request.customerName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if !request.serviceNames.isEmpty {
                        Text(request.serviceNames.joined(separator: ", "))
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                // jobs.cancel_reason is customer-facing: the online booking
                // page shows it in the "This booking was cancelled" banner.
                FormRow(
                    "Reason for the customer (optional)",
                    hint: "The customer sees this on their booking page. Don't include internal notes."
                ) {
                    TextField("e.g. We're fully booked that day", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(.vertical, Theme.Spacing.sm)
                        .inputFieldStyle()
                }
                InlineMessage(
                    text: "The customer isn't messaged automatically. Let them know from the job or the inbox.",
                    kind: .info
                )
                AsyncButton("Decline booking", role: .destructive, style: .themeDestructive) {
                    if await onDecline(reason) {
                        dismiss()
                    }
                }
            }
            .navigationTitle("Decline booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
