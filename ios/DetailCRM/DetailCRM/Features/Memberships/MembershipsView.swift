//
//  MembershipsView.swift
//  DetailCRM
//
//  Memberships (owner/admin/manager): subscribers with their status (paged
//  newest first with "Load more", filtered by status, searched by
//  customer), and the shop's plans. New memberships start incomplete; the
//  customer activates billing through a Stripe Checkout link shared here.
//

import SwiftUI
import DetailCore

enum MembershipsTab: String, CaseIterable, Identifiable, Hashable {
    case members
    case plans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .members: return "Members"
        case .plans: return "Plans"
        }
    }
}

enum MembershipsSheet: Identifiable {
    case newMembership
    case newPlan
    case editPlan(MembershipPlan)
    case member(Membership)

    var id: String {
        switch self {
        case .newMembership: return "newMembership"
        case .newPlan: return "newPlan"
        case .editPlan(let plan): return "plan-\(plan.id.uuidString)"
        case .member(let membership): return "member-\(membership.id.uuidString)"
        }
    }
}

/// What the member list shows (reloads when either changes).
struct MembershipsQueryKey: Hashable {
    var status: MembershipStatus?
    var search: String
}

struct MembershipsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var tab: MembershipsTab = .members
    @State private var membersState: LoadState<MembershipService.ListData> = .idle
    @State private var plansState: LoadState<[MembershipPlan]> = .idle
    @State private var statusFilter: MembershipStatus?
    @State private var search = ""
    @State private var activeSheet: MembershipsSheet?

    var body: some View {
        Group {
            if appState.can(.manageMemberships) {
                content
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Memberships aren't available",
                    message: "Owners, admins and managers manage membership plans and members."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Memberships")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        activeSheet = .newMembership
                    } label: {
                        Label("New membership", systemImage: "person.badge.plus")
                    }
                    Button {
                        activeSheet = .newPlan
                    } label: {
                        Label("New plan", systemImage: "plus.rectangle.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!appState.can(.manageMemberships))
                .accessibilityLabel("Add membership or plan")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(MembershipsTab.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.sm)
            if tab == .members {
                membersScreen
            } else {
                plansScreen
            }
        }
    }

    // MARK: Members

    private var membersScreen: some View {
        VStack(spacing: 0) {
            MoneyListHeader(search: $search, prompt: "Customer name, phone or email") {
                MoneyFilterChip(title: "All", isSelected: statusFilter == nil) {
                    statusFilter = nil
                }
                ForEach(MembershipStatus.allCases, id: \.self) { status in
                    MoneyFilterChip(title: status.displayName, isSelected: statusFilter == status) {
                        statusFilter = status
                    }
                }
            }
            LoadStateView(membersState, loadingLabel: "Loading members…", retry: { await loadMembers() }) { data in
                MembershipsMemberList(
                    data: data,
                    isFiltered: statusFilter != nil,
                    isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    currencyCode: appState.currencyCode,
                    clock: appState.clock,
                    onSelect: { membership in activeSheet = .member(membership) },
                    onCreate: { activeSheet = .newMembership },
                    onLoadMore: { await loadMoreMembers() }
                )
            }
        }
        .refreshable { await loadMembers() }
        .task(id: MembershipsQueryKey(status: statusFilter, search: search)) {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            await loadMembers()
        }
    }

    // MARK: Plans

    private var plansScreen: some View {
        LoadStateView(plansState, loadingLabel: "Loading plans…", retry: { await loadPlans() }) { plans in
            MembershipsPlanList(
                plans: plans,
                currencyCode: appState.currencyCode,
                onSelect: { plan in activeSheet = .editPlan(plan) },
                onCreate: { activeSheet = .newPlan }
            )
        }
        .refreshable { await loadPlans() }
        .task { await loadPlans() }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: MembershipsSheet) -> some View {
        switch sheet {
        case .newMembership:
            MembershipNewSheet {
                await reloadAll()
            }
        case .newPlan:
            MembershipPlanEditorSheet(plan: nil) {
                await reloadAll()
            }
        case .editPlan(let plan):
            MembershipPlanEditorSheet(plan: plan) {
                await reloadAll()
            }
        case .member(let membership):
            MembershipDetailSheet(
                membership: membership,
                plan: membersState.value?.plans[membership.planID],
                customer: membersState.value?.customers[membership.customerID],
                vehicle: membership.vehicleID.flatMap { membersState.value?.vehicles[$0] }
            ) {
                await loadMembers()
            }
        }
    }

    // MARK: Loading

    private func reloadAll() async {
        await loadMembers()
        await loadPlans()
    }

    private func loadMembers() async {
        guard let shopID = try? appState.requireShopID() else { return }
        membersState.beginLoading()
        let status = statusFilter
        let term = search
        let result = await LoadState<MembershipService.ListData>.result {
            try await MembershipService.memberships(shopID: shopID, status: status, search: term)
        }
        if let message = result.errorMessage, membersState.value != nil {
            toasts.show(message, style: .error)
        }
        membersState.apply(result)
    }

    /// Appends the next page of older memberships.
    private func loadMoreMembers() async {
        guard let shopID = try? appState.requireShopID(),
              let current = membersState.value, current.hasMore else { return }
        let status = statusFilter
        let term = search
        do {
            let page = try await MembershipService.memberships(
                shopID: shopID,
                status: status,
                search: term,
                offset: current.memberships.count
            )
            // Ignore a page for a filter or search that changed meanwhile.
            guard status == statusFilter, term == search, let latest = membersState.value else { return }
            membersState = .loaded(latest.appending(page))
        } catch {
            toasts.show(ErrorText.message(for: error), style: .error)
        }
    }

    private func loadPlans() async {
        guard let shopID = try? appState.requireShopID() else { return }
        plansState.beginLoading()
        let result = await LoadState<[MembershipPlan]>.result {
            try await MembershipService.plans(shopID: shopID)
        }
        if let message = result.errorMessage, plansState.value != nil {
            toasts.show(message, style: .error)
        }
        plansState.apply(result)
    }
}

// MARK: - Member list

private struct MembershipsMemberList: View {
    let data: MembershipService.ListData
    let isFiltered: Bool
    let isSearching: Bool
    let currencyCode: String
    let clock: ShopClock
    let onSelect: (Membership) -> Void
    let onCreate: () -> Void
    let onLoadMore: () async -> Void

    var body: some View {
        if data.memberships.isEmpty {
            if isSearching {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No matching members",
                    message: isFiltered ? "Try another search or status." : "Try another name, phone or email."
                )
            } else if isFiltered {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No members with this status",
                    message: "Try another status."
                )
            } else {
                EmptyStateView(
                    systemImage: "person.2.badge.gearshape",
                    title: "No members yet",
                    message: "Sign a customer up for a plan, then share the checkout link so they can start billing.",
                    actionTitle: "New membership",
                    action: onCreate
                )
            }
        } else {
            List {
                ForEach(data.memberships) { membership in
                    Button {
                        onSelect(membership)
                    } label: {
                        MembershipMemberRow(
                            membership: membership,
                            plan: data.plans[membership.planID],
                            customerName: data.customers[membership.customerID]?.displayName ?? "Customer",
                            vehicle: membership.vehicleID.flatMap { data.vehicles[$0] },
                            currencyCode: currencyCode,
                            clock: clock
                        )
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
                if data.hasMore {
                    MoneyLoadMoreRow(shownCount: data.memberships.count, noun: "memberships", action: onLoadMore)
                        .themedRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct MembershipMemberRow: View {
    let membership: Membership
    let plan: MembershipPlan?
    let customerName: String
    let vehicle: QuoteVehicleRef?
    let currencyCode: String
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(customerName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    StatusBadge(membership.status)
                }
                Text(planLine)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let periodText = MembershipText.period(membership, clock: clock) {
                    Text(periodText)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let price = membership.price(plan: plan) {
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    MoneyText(cents: price, currencyCode: currencyCode, size: .small)
                    if let billing = membership.billingText(plan: plan) {
                        Text(billing)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var planLine: String {
        var parts = [plan?.name ?? "Plan"]
        if let vehicle { parts.append(vehicle.displayName) }
        return parts.joined(separator: " · ")
    }
}

/// Shared wording for membership periods.
enum MembershipText {
    static func period(_ membership: Membership, clock: ShopClock) -> String? {
        switch membership.status {
        case .incomplete:
            return membership.needsCheckout ? "Waiting for the customer to finish checkout" : "Starting…"
        case .active, .pastDue:
            guard let end = membership.currentPeriodEnd else { return nil }
            return membership.cancelAtPeriodEnd
                ? "Ends \(clock.shortDayText(end))"
                : "Renews \(clock.shortDayText(end))"
        case .cancelled:
            return membership.cancelledAt.map { "Cancelled \(clock.shortDayText($0))" }
        }
    }
}

// MARK: - Plan list

private struct MembershipsPlanList: View {
    let plans: [MembershipPlan]
    let currencyCode: String
    let onSelect: (MembershipPlan) -> Void
    let onCreate: () -> Void

    var body: some View {
        if plans.isEmpty {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "No plans yet",
                message: "Create a recurring plan with your price and billing period.",
                actionTitle: "New plan",
                action: onCreate
            )
        } else {
            List {
                ForEach(plans) { plan in
                    Button {
                        onSelect(plan)
                    } label: {
                        MembershipPlanRow(plan: plan, currencyCode: currencyCode)
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct MembershipPlanRow: View {
    let plan: MembershipPlan
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(plan.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if !plan.active {
                        StatusBadge(text: "Inactive", tone: .neutral)
                    } else if plan.onlineJoinable {
                        StatusBadge(text: "Online", tone: .info)
                    }
                }
                if let description = plan.planDescription?.trimmedNonEmpty {
                    Text(description)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if let discount = plan.discountText {
                    Text(discount)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !plan.includedServiceIDs.isEmpty {
                    Text("\(plan.includedServiceIDs.count) included service\(plan.includedServiceIDs.count == 1 ? "" : "s")")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let uses = plan.usesText {
                    Text(uses)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                MoneyText(cents: plan.priceCents, currencyCode: currencyCode)
                Text(plan.billingText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
