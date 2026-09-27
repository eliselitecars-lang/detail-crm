//
//  CustomersView.swift
//  DetailCRM
//
//  Customers tab: searchable (name / phone / email / company, debounced),
//  filterable (lifecycle, tag), sortable list with paging, plus an Add
//  customer sheet for managers and above. Technicians get whatever the
//  server returns for them (customers on their assigned jobs), read-only.
//

import SwiftUI
import DetailCore

struct CustomersView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var query = CustomerService.ListQuery()
    @State private var state: LoadState<[Customer]> = .idle
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    /// The last "load more" failed: the row offers Try again instead of
    /// claiming to load.
    @State private var loadMoreFailed = false
    @State private var tags: [String] = []
    @State private var showingAdd = false
    @State private var openedCustomer: CustomersOpenedCustomer?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading customers…", retry: { await reload() }) { customers in
            CustomersListContent(
                customers: customers,
                query: $query,
                canLoadMore: canLoadMore,
                isLoadingMore: isLoadingMore,
                loadMoreFailed: loadMoreFailed,
                canEdit: appState.can(.editCustomers),
                loadMore: { await loadMore() },
                addCustomer: { showingAdd = true }
            )
        }
        .screenBackground()
        .navigationTitle("Customers")
        .searchable(text: $query.search, prompt: "Name, phone, email or company")
        .toolbar { toolbarContent }
        .task(id: query) {
            // Debounce typing; the first load runs right away.
            if state.value != nil {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await reload()
        }
        .task {
            await loadTags()
        }
        .refreshable {
            await reload()
            await loadTags()
        }
        .sheet(isPresented: $showingAdd) {
            CustomerEditorSheet(mode: .create, suggestions: tags) { customer in
                handleCreated(customer)
            }
        }
        .navigationDestination(item: $openedCustomer) { opened in
            CustomerDetailView(customerID: opened.id)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            CustomersFilterMenu(query: $query, tags: tags)
        }
        if appState.can(.editCustomers) {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add customer")
            }
        }
    }

    // MARK: Loading

    private func reload() async {
        guard let shopID = try? appState.requireShopID() else { return }
        let snapshot = query
        state.beginLoading()
        let result = await LoadState<[Customer]>.result {
            try await CustomerService.list(shopID: shopID, query: snapshot)
        }
        // A newer query replaced this one while it ran: its own task loads.
        guard snapshot == query else { return }
        if case .failed(let message) = result, state.value != nil {
            toasts.show(message, style: .error)
        }
        if case .loaded(let rows) = result {
            canLoadMore = rows.count == CustomerService.pageSize
            loadMoreFailed = false
        }
        state.apply(result)
    }

    private func loadMore() async {
        guard canLoadMore, !isLoadingMore, let current = state.value,
              let shopID = try? appState.requireShopID() else { return }
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }
        let snapshot = query
        do {
            let next = try await CustomerService.list(shopID: shopID, query: snapshot, offset: current.count)
            guard snapshot == query, let latest = state.value else { return }
            let known = Set(latest.map { $0.id })
            state = .loaded(latest + next.filter { !known.contains($0.id) })
            canLoadMore = next.count == CustomerService.pageSize
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Shown inline on the load-more row, with Try again.
            guard snapshot == query else { return }
            loadMoreFailed = true
        }
    }

    private func loadTags() async {
        guard let shopID = try? appState.requireShopID() else { return }
        // Tags only drive the filter menu and suggestions: a failure here
        // is not worth interrupting the list for.
        if let loaded = try? await CustomerService.allTags(shopID: shopID) {
            tags = loaded
        }
    }

    private func handleCreated(_ customer: Customer) {
        toasts.show("Customer added")
        if var rows = state.value {
            rows.insert(customer, at: 0)
            state = .loaded(rows)
        }
        for tag in customer.tags where !tags.contains(where: { $0.lowercased() == tag.lowercased() }) {
            tags.append(tag)
        }
        openedCustomer = CustomersOpenedCustomer(id: customer.id)
    }
}

/// Push target after creating a customer.
struct CustomersOpenedCustomer: Identifiable, Hashable {
    let id: UUID
}

// MARK: - List

private struct CustomersListContent: View {
    let customers: [Customer]
    @Binding var query: CustomerService.ListQuery
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    let canEdit: Bool
    let loadMore: () async -> Void
    let addCustomer: () -> Void

    var body: some View {
        if customers.isEmpty {
            CustomersEmptyView(query: $query, canEdit: canEdit, addCustomer: addCustomer)
        } else {
            List {
                if query.lifecycle != nil || query.tag != nil || query.includeArchived {
                    Section {
                        CustomersActiveFilters(query: $query)
                            .themedRow()
                    }
                }
                Section {
                    ForEach(customers) { customer in
                        NavigationLink(value: AppRoute.customer(customer.id)) {
                            CustomerListRow(customer: customer)
                        }
                        .themedRow()
                    }
                    if canLoadMore {
                        CustomersLoadMoreRow(isLoading: isLoadingMore, failed: loadMoreFailed, loadMore: loadMore)
                            .themedRow()
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// Appears at the end of the list; loads the next page when it scrolls
/// into view. After a failure it says so and offers Try again (it also
/// retries when scrolled back into view).
private struct CustomersLoadMoreRow: View {
    let isLoading: Bool
    let failed: Bool
    let loadMore: () async -> Void

    var body: some View {
        // A plain container (not Group) so `.task` runs once per appearance,
        // not again whenever the content switches between states.
        HStack(spacing: Theme.Spacing.sm) {
            Spacer(minLength: 0)
            if failed && !isLoading {
                Text("Couldn't load more customers.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Button("Try again") {
                    Task { @MainActor in
                        await loadMore()
                    }
                }
                .buttonStyle(.borderless)
                .font(Theme.Typography.footnote.weight(.semibold))
                .tint(Theme.glacier)
            } else {
                ProgressView()
                    .tint(Theme.glacier)
                    .opacity(isLoading ? 1 : 0)
                Text("Loading more…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task {
            await loadMore()
        }
    }
}

private struct CustomersEmptyView: View {
    @Binding var query: CustomerService.ListQuery
    let canEdit: Bool
    let addCustomer: () -> Void

    var body: some View {
        if query.search.trimmedNonEmpty != nil || query.lifecycle != nil || query.tag != nil {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "No customers match your search or filters.",
                actionTitle: "Clear search and filters",
                action: {
                    query = CustomerService.ListQuery(sort: query.sort)
                }
            )
        } else if canEdit {
            EmptyStateView(
                systemImage: "person.2",
                title: "No customers yet",
                message: "Add your first customer, or they'll appear here as people book online.",
                actionTitle: "Add customer",
                action: addCustomer
            )
        } else {
            EmptyStateView(
                systemImage: "person.2",
                title: "No customers to show",
                message: "Customers on jobs assigned to you will appear here."
            )
        }
    }
}

/// Chips for the active filters, each removable.
private struct CustomersActiveFilters: View {
    @Binding var query: CustomerService.ListQuery

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                if let lifecycle = query.lifecycle {
                    CustomerTagChip(text: lifecycle.pluralName, isSelected: true) {
                        query.lifecycle = nil
                    }
                }
                if let tag = query.tag {
                    CustomerTagChip(text: "Tag: \(tag)", isSelected: true) {
                        query.tag = nil
                    }
                }
                if query.includeArchived {
                    CustomerTagChip(text: "Including archived", isSelected: true) {
                        query.includeArchived = false
                    }
                }
            }
        }
    }
}

/// Toolbar menu: lifecycle, tag, sort and archived filters.
private struct CustomersFilterMenu: View {
    @Binding var query: CustomerService.ListQuery
    let tags: [String]

    var body: some View {
        Menu {
            Picker("Show", selection: $query.lifecycle) {
                Text("Everyone").tag(Customer.Lifecycle?.none)
                ForEach(Customer.Lifecycle.allCases) { lifecycle in
                    Text(lifecycle.pluralName).tag(Customer.Lifecycle?.some(lifecycle))
                }
            }
            if !tags.isEmpty {
                Picker("Tag", selection: $query.tag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(tags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                }
                .pickerStyle(.menu)
            }
            Picker("Sort by", selection: $query.sort) {
                ForEach(CustomerService.SortOrder.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            Toggle("Include archived", isOn: $query.includeArchived)
        } label: {
            Image(systemName: isFiltered
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(isFiltered ? "Filters (active)" : "Filters")
    }

    private var isFiltered: Bool {
        query.lifecycle != nil || query.tag != nil || query.includeArchived
    }
}

// MARK: - Row

struct CustomerListRow: View {
    let customer: Customer

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: customer.displayName, size: Theme.Size.avatarMedium)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(customer.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if customer.lifecycle == .lead {
                        StatusBadge(text: "Lead", tone: .warning)
                    }
                    if customer.isArchived {
                        StatusBadge(text: "Archived", tone: .neutral)
                    }
                }
                if let detail = detailLine {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !customer.tags.isEmpty {
                    Text(customer.tags.prefix(3).joined(separator: " · "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.glacier)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String? {
        let contact: String? = customer.formattedPhone ?? customer.email?.trimmedNonEmpty
        let parts = [customer.secondaryCompany, contact].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
