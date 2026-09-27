//
//  TodayView.swift
//  DetailCRM
//
//  Today tab. Managers and above: collected revenue, invoices / messages /
//  quotes that need attention, online booking requests (approve /
//  decline), the next job, today's jobs and who is on the clock.
//  Technicians: their shift clock, their next job (first name, vehicle,
//  address + Maps) and their jobs today. Everything is in the SHOP time
//  zone and every figure comes from the server (`dashboard_summary`,
//  `calendar_events`); the server also scopes what each role receives.
//

import SwiftUI
import DetailCore

struct TodayView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<TodaySnapshot> = .idle
    @State private var unreadNotifications = 0
    @State private var declining: DashboardSummaryBookingRequest?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading your day…", retry: { await load() }) { snapshot in
            TodayContent(snapshot: snapshot, context: context, actions: actions)
        }
        .screenBackground()
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NotificationsView()
                } label: {
                    Image(systemName: unreadNotifications > 0 ? "bell.badge" : "bell")
                }
                .accessibilityLabel(Text(notificationsLabel))
            }
        }
        .task { await load() }
        .sheet(item: $declining) { request in
            TodayDeclineSheet(request: request) { reason in
                await decline(request, reason: reason)
            }
        }
        .confirmation($confirmation)
    }

    // MARK: - Context & actions

    private var notificationsLabel: String {
        unreadNotifications > 0 ? "Notifications, \(unreadNotifications) unread" : "Notifications"
    }

    private var context: TodayContext {
        TodayContext(
            clock: appState.clock,
            currencyCode: appState.currencyCode,
            displayName: appState.displayName,
            shopAddress: appState.shop?.addressSummary,
            canViewMoney: appState.can(.viewAllReports),
            canDecideBookings: appState.can(.editJobs),
            canOpenInvoices: appState.can(.manageInvoices),
            canOpenQuotes: appState.can(.manageQuotes),
            canOpenInbox: appState.can(.useInbox)
        )
    }

    private var actions: TodayActions {
        TodayActions(
            refresh: { await load() },
            approve: { request in askToApprove(request) },
            decline: { request in declining = request },
            clockIn: { await clockIn() },
            clockOut: { askToClockOut() }
        )
    }

    // MARK: - Loading

    private func load() async {
        let shopID: UUID
        do {
            shopID = try appState.requireShopID()
        } catch {
            state = .failed(ErrorText.message(for: error))
            return
        }
        let memberID = appState.member?.id
        let includeRequests = appState.can(.editJobs)
        let day = appState.clock.dayInterval(containing: Date())

        state.beginLoading()
        let hadContent = state.value != nil
        let result = await LoadState<TodaySnapshot>.result {
            try await TodayLoader.load(
                shopID: shopID,
                memberID: memberID,
                includeRequests: includeRequests,
                day: day
            )
        }
        if hadContent, let message = result.errorMessage {
            toasts.show(message, style: .error, duration: .seconds(5))
        }
        state.apply(result)

        // Badge only: a failure here must not hide the dashboard.
        if let count = try? await NotificationService.unreadCount(shopID: shopID) {
            unreadNotifications = count
        }
    }

    // MARK: - Booking requests

    private func askToApprove(_ request: DashboardSummaryBookingRequest) {
        confirmation = ConfirmationRequest(
            title: "Approve this booking?",
            message: "\(request.customerName)'s job moves to Scheduled and they get your booking-confirmed message (if that template is on).",
            confirmTitle: "Approve"
        ) {
            await approve(request)
        }
    }

    private func approve(_ request: DashboardSummaryBookingRequest) async {
        do {
            let shopID = try appState.requireShopID()
            try await DashboardService.approveBooking(shopID: shopID, jobID: request.job.id)
            toasts.show("Booking approved")
        } catch {
            toasts.showError(error)
        }
        await load()
    }

    private func decline(_ request: DashboardSummaryBookingRequest, reason: String) async -> Bool {
        do {
            let shopID = try appState.requireShopID()
            try await DashboardService.declineBooking(shopID: shopID, jobID: request.job.id, reason: reason)
            toasts.show("Booking declined")
            await load()
            return true
        } catch {
            toasts.showError(error)
            return false
        }
    }

    // MARK: - Shift clock

    private func clockIn() async {
        do {
            let shopID = try appState.requireShopID()
            try await DashboardService.clockIn(shopID: shopID)
            toasts.show("Clocked in")
        } catch {
            toasts.showError(error)
        }
        await load()
    }

    private func askToClockOut() {
        confirmation = ConfirmationRequest(
            title: "Clock out?",
            message: "This ends your shift and stops any job clock that's running.",
            confirmTitle: "Clock out"
        ) {
            await clockOut()
        }
    }

    private func clockOut() async {
        do {
            let shopID = try appState.requireShopID()
            try await DashboardService.clockOut(shopID: shopID)
            toasts.show("Clocked out")
        } catch {
            toasts.showError(error)
        }
        await load()
    }
}

// MARK: - Content

/// The scrolling body. Each section is an AnyView seam so the composed
/// generic type stays shallow (big-screen metadata crash trap).
private struct TodayContent: View {
    let snapshot: TodaySnapshot
    let context: TodayContext
    let actions: TodayActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                AnyView(TodayGreeting(context: context))
                if snapshot.summary.isOwnScope {
                    AnyView(TodayTechnicianSections(snapshot: snapshot, context: context, actions: actions))
                } else {
                    AnyView(TodayManagerSections(snapshot: snapshot, context: context, actions: actions))
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await actions.refresh() }
    }
}

private struct TodayTechnicianSections: View {
    let snapshot: TodaySnapshot
    let context: TodayContext
    let actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            AnyView(clockCard)
            if let next = snapshot.summary.nextJob {
                AnyView(TodayNextJobCard(
                    job: next,
                    details: snapshot.nextJobDetails,
                    useFirstName: true,
                    context: context
                ))
            } else {
                AnyView(TodayNoNextJobCard())
            }
            AnyView(TodayJobsSection(
                title: "My jobs today",
                emptyText: "No jobs assigned to you today.",
                jobs: snapshot.jobs,
                jobsToday: snapshot.summary.jobsToday,
                context: context
            ))
            AnyView(TodayWeekFootnote(count: snapshot.summary.jobsThisWeek, own: true))
        }
    }

    private var clockCard: some View {
        TodayClockCard(
            openShift: snapshot.openShift,
            openJobEntry: snapshot.openJobEntry,
            clock: context.clock,
            onClockIn: actions.clockIn,
            onClockOut: actions.clockOut
        )
    }
}

private struct TodayManagerSections: View {
    let snapshot: TodaySnapshot
    let context: TodayContext
    let actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if context.canViewMoney, let revenue = snapshot.summary.revenue {
                AnyView(TodayRevenueSection(revenue: revenue, context: context))
            }
            AnyView(TodayAttentionSection(summary: snapshot.summary, context: context))
            if !snapshot.requests.isEmpty {
                AnyView(TodayBookingRequestsSection(
                    requests: snapshot.requests,
                    totalPending: snapshot.summary.pendingBookingRequests ?? snapshot.requests.count,
                    context: context,
                    actions: actions
                ))
            }
            if let next = snapshot.summary.nextJob {
                AnyView(TodayNextJobCard(
                    job: next,
                    details: snapshot.nextJobDetails,
                    useFirstName: false,
                    context: context
                ))
            }
            AnyView(TodayJobsSection(
                title: "Today's jobs",
                emptyText: "No jobs on the schedule today.",
                jobs: snapshot.jobs,
                jobsToday: snapshot.summary.jobsToday,
                context: context
            ))
            AnyView(TodayWeekFootnote(count: snapshot.summary.jobsThisWeek, own: false))
            AnyView(TodayClockedInSection(clockedIn: snapshot.summary.clockedIn, context: context))
            AnyView(TodayClockCard(
                openShift: snapshot.openShift,
                openJobEntry: snapshot.openJobEntry,
                clock: context.clock,
                onClockIn: actions.clockIn,
                onClockOut: actions.clockOut
            ))
        }
    }
}

private struct TodayNoNextJobCard: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Nothing up next")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("You have no upcoming jobs assigned.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

private struct TodayWeekFootnote: View {
    let count: Int
    let own: Bool

    private var text: String {
        let jobs = count == 1 ? "1 job" : "\(count) jobs"
        return own ? "\(jobs) assigned to you this week." : "\(jobs) on the schedule this week."
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.xs)
    }
}
