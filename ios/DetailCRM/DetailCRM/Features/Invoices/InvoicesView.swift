//
//  InvoicesView.swift
//  DetailCRM
//
//  Invoices list (owner/admin/manager): status filters including overdue,
//  balance due, search by number or customer. Technicians reach the
//  invoice of an assigned job from the job screen instead (when the shop
//  lets them collect). The detail screen is InvoiceDetailView.swift.
//

import SwiftUI
import DetailCore

struct InvoicesQueryKey: Hashable {
    var filter: InvoiceListFilter
    var search: String
}

struct InvoicesView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<InvoiceService.ListData> = .idle
    @State private var filter: InvoiceListFilter = .all
    @State private var search = ""

    var body: some View {
        Group {
            if appState.can(.manageInvoices) {
                listScreen
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Invoices aren't available",
                    message: "Open an assigned job to see its invoice and collect payment when your shop allows it."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Invoices")
    }

    private var listScreen: some View {
        VStack(spacing: 0) {
            MoneyListHeader(search: $search, prompt: "Invoice # or customer") {
                ForEach(InvoiceListFilter.allCases) { option in
                    MoneyFilterChip(title: option.title, isSelected: filter == option) {
                        filter = option
                    }
                }
            }
            LoadStateView(state, loadingLabel: "Loading invoices…", retry: { await load() }) { data in
                InvoicesListContent(
                    data: data,
                    isFiltered: filter != .all || !search.isEmpty,
                    currencyCode: appState.currencyCode,
                    clock: appState.clock,
                    onLoadMore: { await loadMore() }
                )
            }
        }
        .refreshable { await load() }
        .task(id: InvoicesQueryKey(filter: filter, search: search)) {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            // Also re-runs when the list reappears after a detail screen.
            await load()
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let currentFilter = filter
        let term = search
        let result = await LoadState<InvoiceService.ListData>.result {
            try await InvoiceService.list(shopID: shopID, filter: currentFilter, search: term)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    /// Appends the next page of older invoices.
    private func loadMore() async {
        guard let shopID = try? appState.requireShopID(), let current = state.value, current.hasMore else { return }
        let currentFilter = filter
        let term = search
        do {
            let page = try await InvoiceService.list(
                shopID: shopID,
                filter: currentFilter,
                search: term,
                offset: current.invoices.count
            )
            // Ignore a page for a filter that changed meanwhile.
            guard currentFilter == filter, term == search, let latest = state.value else { return }
            state = .loaded(latest.appending(page))
        } catch {
            toasts.show(ErrorText.message(for: error), style: .error)
        }
    }
}

private struct InvoicesListContent: View {
    let data: InvoiceService.ListData
    let isFiltered: Bool
    let currencyCode: String
    let clock: ShopClock
    let onLoadMore: () async -> Void

    var body: some View {
        if data.invoices.isEmpty {
            EmptyStateView(
                systemImage: isFiltered ? "magnifyingglass" : "doc.plaintext",
                title: isFiltered ? "No matching invoices" : "No invoices yet",
                message: isFiltered
                    ? "Try another filter or search."
                    : "Invoices are created from jobs. Open a completed job and choose Create invoice."
            )
        } else {
            List {
                ForEach(data.invoices) { invoice in
                    NavigationLink(value: AppRoute.invoice(invoice.id)) {
                        InvoiceListRow(
                            invoice: invoice,
                            customerName: data.customers[invoice.customerID]?.displayName ?? "Customer",
                            currencyCode: currencyCode,
                            clock: clock
                        )
                    }
                    .themedRow()
                }
                if data.hasMore {
                    MoneyLoadMoreRow(shownCount: data.invoices.count, noun: "invoices", action: onLoadMore)
                        .themedRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct InvoiceListRow: View {
    let invoice: Invoice
    let customerName: String
    let currencyCode: String
    let clock: ShopClock

    var body: some View {
        let badge = invoice.badge()
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(invoice.title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    StatusBadge(text: badge.text, tone: badge.tone)
                }
                Text(customerName)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(dateLine)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(invoice.isOverdue() ? Theme.dangerInk : Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                if invoice.canCollect {
                    MoneyText(cents: invoice.balanceCents, currencyCode: currencyCode, emphasis: .attention)
                    Text("due of \(Money.format(cents: invoice.totalCents, currencyCode: currencyCode))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    MoneyText(cents: invoice.totalCents, currencyCode: currencyCode)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var dateLine: String {
        switch invoice.status {
        case .draft:
            return "Draft · created \(clock.relativeDayText(invoice.createdAt))"
        case .void:
            return "Voided \(clock.relativeDayText(invoice.voidedAt ?? invoice.updatedAt))"
        case .paid:
            return "Paid \(clock.relativeDayText(invoice.paidAt ?? invoice.updatedAt))"
        case .open, .partiallyPaid:
            if let dueAt = invoice.dueAt {
                return invoice.isOverdue() ? "Was due \(clock.relativeDayText(dueAt))" : "Due \(clock.relativeDayText(dueAt))"
            }
            return "Issued \(clock.relativeDayText(invoice.issuedAt ?? invoice.createdAt))"
        }
    }
}
