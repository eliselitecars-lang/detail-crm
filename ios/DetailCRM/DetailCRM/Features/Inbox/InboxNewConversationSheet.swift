//
//  InboxNewConversationSheet.swift
//  DetailCRM
//
//  Start a conversation: search customers (debounced) and pick one; the
//  inbox then opens that customer's thread.
//

import SwiftUI
import DetailCore

struct InboxNewConversationSheet: View {
    let onPick: (Customer) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var state: LoadState<[Customer]> = .idle

    var body: some View {
        NavigationStack {
            LoadStateView(state, loadingLabel: "Loading customers…", retry: { await load() }) { customers in
                InboxCustomerResults(customers: customers, hasSearch: search.trimmedNonEmpty != nil) { customer in
                    onPick(customer)
                    dismiss()
                }
            }
            .screenBackground()
            .navigationTitle("New conversation")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search customers"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: search) {
                if state.value != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                await load()
            }
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        let term = search
        state.beginLoading()
        var query = CustomerService.ListQuery()
        query.search = term
        query.sort = term.trimmedNonEmpty == nil ? .newest : .name
        let snapshot = query
        let result = await LoadState<[Customer]>.result {
            try await CustomerService.list(shopID: shopID, query: snapshot, offset: 0, limit: 40)
        }
        guard term == search else { return }
        state.apply(result)
    }
}

private struct InboxCustomerResults: View {
    let customers: [Customer]
    let hasSearch: Bool
    let pick: (Customer) -> Void

    var body: some View {
        if customers.isEmpty {
            EmptyStateView(
                systemImage: hasSearch ? "magnifyingglass" : "person.2",
                title: hasSearch ? "No matches" : "No customers yet",
                message: hasSearch
                    ? "Try a name, phone number, email or company."
                    : "Add customers in the Customers tab, then message them here."
            )
        } else {
            List {
                Section {
                    ForEach(customers) { customer in
                        Button {
                            pick(customer)
                        } label: {
                            CustomerListRow(customer: customer)
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    Text(hasSearch ? "Matches" : "Recently added")
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
