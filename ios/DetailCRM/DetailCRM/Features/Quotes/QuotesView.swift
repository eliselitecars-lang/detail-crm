//
//  QuotesView.swift
//  DetailCRM
//
//  Quotes list (owner/admin/manager): status filter, search by number or
//  customer, and a builder sheet for new quotes. The detail screen lives
//  in QuoteDetailView.swift.
//

import SwiftUI
import DetailCore

/// What the list is currently asking the server for.
struct QuotesQueryKey: Hashable {
    var status: QuoteStatus?
    var search: String
}

struct QuotesView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<QuoteService.ListData> = .idle
    @State private var statusFilter: QuoteStatus?
    @State private var search = ""
    @State private var showingBuilder = false
    /// Set by the builder on save; pushed once the sheet has closed.
    @State private var createdQuoteID: UUID?
    @State private var openedQuoteID: UUID?

    var body: some View {
        Group {
            if appState.can(.manageQuotes) {
                listScreen
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Quotes aren't available",
                    message: "Owners, admins and managers build and send quotes."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Quotes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingBuilder = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!appState.can(.manageQuotes))
                .accessibilityLabel("New quote")
            }
        }
        .sheet(isPresented: $showingBuilder, onDismiss: {
            if let quoteID = createdQuoteID {
                createdQuoteID = nil
                openedQuoteID = quoteID
            }
        }, content: {
            QuoteBuilderView(draft: QuoteDraft()) { quoteID in
                createdQuoteID = quoteID
                Task { await load() }
            }
        })
        .navigationDestination(item: $openedQuoteID) { quoteID in
            QuoteDetailView(quoteID: quoteID)
        }
    }

    private var listScreen: some View {
        VStack(spacing: 0) {
            MoneyListHeader(search: $search, prompt: "Quote # or customer") {
                MoneyFilterChip(title: "All", isSelected: statusFilter == nil) {
                    statusFilter = nil
                }
                ForEach(QuoteStatus.allCases, id: \.self) { status in
                    MoneyFilterChip(title: status.displayName, isSelected: statusFilter == status) {
                        statusFilter = status
                    }
                }
            }
            LoadStateView(state, loadingLabel: "Loading quotes…", retry: { await load() }) { data in
                QuotesListContent(
                    data: data,
                    isFiltered: statusFilter != nil || !search.isEmpty,
                    currencyCode: appState.currencyCode,
                    clock: appState.clock,
                    onCreate: { showingBuilder = true },
                    onLoadMore: { await loadMore() }
                )
            }
        }
        .refreshable { await load() }
        .task(id: QuotesQueryKey(status: statusFilter, search: search)) {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            // Also re-runs when the list reappears (back from a detail
            // screen), picking up status changes made there.
            await load()
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let status = statusFilter
        let term = search
        let result = await LoadState<QuoteService.ListData>.result {
            try await QuoteService.list(shopID: shopID, status: status, search: term)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    /// Appends the next page of older quotes.
    private func loadMore() async {
        guard let shopID = try? appState.requireShopID(), let current = state.value, current.hasMore else { return }
        let status = statusFilter
        let term = search
        do {
            let page = try await QuoteService.list(
                shopID: shopID,
                status: status,
                search: term,
                offset: current.quotes.count
            )
            // Ignore a page for a filter that changed meanwhile.
            guard status == statusFilter, term == search, let latest = state.value else { return }
            state = .loaded(latest.appending(page))
        } catch {
            toasts.show(ErrorText.message(for: error), style: .error)
        }
    }
}

private struct QuotesListContent: View {
    let data: QuoteService.ListData
    let isFiltered: Bool
    let currencyCode: String
    let clock: ShopClock
    let onCreate: () -> Void
    let onLoadMore: () async -> Void

    var body: some View {
        if data.quotes.isEmpty {
            if isFiltered {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No matching quotes",
                    message: "Try another status or search."
                )
            } else {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: "No quotes yet",
                    message: "Build a quote from your catalog, send it, and turn it into a job once it's approved.",
                    actionTitle: "New quote",
                    action: onCreate
                )
            }
        } else {
            List {
                ForEach(data.quotes) { quote in
                    NavigationLink(value: AppRoute.quote(quote.id)) {
                        QuoteListRow(
                            quote: quote,
                            customerName: data.customers[quote.customerID]?.displayName ?? "Customer",
                            currencyCode: currencyCode,
                            clock: clock
                        )
                    }
                    .themedRow()
                }
                if data.hasMore {
                    MoneyLoadMoreRow(shownCount: data.quotes.count, noun: "quotes", action: onLoadMore)
                        .themedRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct QuoteListRow: View {
    let quote: Quote
    let customerName: String
    let currencyCode: String
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(quote.title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    StatusBadge(quote.status)
                }
                Text(customerName)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(dateLine)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: quote.totalCents, currencyCode: currencyCode)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var dateLine: String {
        if quote.status.isAwaitingCustomer,
           let validUntil = quote.validUntil,
           let day = clock.date(fromDateString: validUntil) {
            return "Valid until \(clock.shortDayText(day))"
        }
        return "Created \(clock.relativeDayText(quote.createdAt))"
    }
}
