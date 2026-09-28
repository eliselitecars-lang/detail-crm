//
//  CustomerDetailView.swift
//  DetailCRM
//
//  One customer: contact card (call / text / email / Maps), tags, notes,
//  custom fields (P-9), vehicles (add / edit with VIN scan and decode),
//  job history, documents (P-25), the referral link (P-29), and — for roles
//  that handle money — quotes, invoices, memberships (read-only summary;
//  the Money screens own the details) and saved cards. Managers and above
//  see the server's overview (lifetime paid, open balance, visits), can
//  edit, archive, start a new job, open the message thread and remove a
//  saved card.
//

import SwiftUI
import DetailCore

struct CustomerDetailView: View {
    let customerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<Customer> = .idle
    @State private var history = CustomerDetailHistory()
    @State private var categories: [VehicleCategory] = []
    @State private var tagSuggestions: [String] = []
    @State private var sheet: CustomerDetailSheet?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading customer…", retry: { await loadAll() }) { customer in
            CustomerDetailContent(
                customer: customer,
                history: history,
                permissions: permissions,
                clock: appState.clock,
                currencyCode: appState.currencyCode,
                categories: categories,
                actions: actions
            )
        }
        .screenBackground()
        .navigationTitle(state.value?.displayName ?? "Customer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            if state.value == nil { await loadAll() }
        }
        .refreshable {
            await loadAll()
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
            sheetContent(sheet)
        }
        .confirmation($confirmation)
    }

    // MARK: Permissions & actions

    private var permissions: CustomerDetailPermissions {
        CustomerDetailPermissions(
            canEdit: appState.can(.editCustomers),
            canCreateJobs: appState.can(.createJobs),
            canMessage: appState.can(.useInbox),
            canSeeQuotes: appState.can(.manageQuotes),
            canSeeInvoices: appState.can(.manageInvoices),
            canSeeMemberships: appState.can(.manageMemberships),
            canSeeSavedCards: appState.can(.useSavedCards),
            canSeeSummary: appState.role?.isManagerOrAbove ?? false,
            canManageDocuments: appState.can(.editCustomers),
            canUseReferrals: appState.role?.isManagerOrAbove ?? false
        )
    }

    private var actions: CustomerDetailActions {
        CustomerDetailActions(
            addVehicle: { sheet = .addVehicle },
            editVehicle: { vehicle in sheet = .editVehicle(vehicle) },
            newJob: { sheet = .newJob },
            retryHistory: { await loadHistory() },
            retrySummary: { await reloadSummary() },
            retryCustomFields: { await reloadCustomFields() },
            removeCard: { card in confirmRemoveCard(card) },
            customerUpdated: { updated in state = .loaded(updated) }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let customer = state.value, permissions.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        sheet = .edit(customer)
                    } label: {
                        Label("Edit customer", systemImage: "pencil")
                    }
                    if customer.isArchived {
                        Button {
                            Task { await setArchived(false) }
                        } label: {
                            Label("Restore customer", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button(role: .destructive) {
                            confirmArchive()
                        } label: {
                            Label("Archive customer", systemImage: "archivebox")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Customer actions")
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: CustomerDetailSheet) -> some View {
        switch sheet {
        case .edit(let customer):
            CustomerEditorSheet(mode: .edit(customer), suggestions: tagSuggestions) { saved in
                state = .loaded(saved)
                toasts.show("Customer saved")
            }
        case .addVehicle:
            CustomerVehicleEditorSheet(
                customerID: customerID,
                vehicle: nil,
                categories: categories,
                onSaved: { saved in vehicleSaved(saved) },
                onRemoved: { id in vehicleRemoved(id) }
            )
        case .editVehicle(let vehicle):
            CustomerVehicleEditorSheet(
                customerID: customerID,
                vehicle: vehicle,
                categories: categories,
                onSaved: { saved in vehicleSaved(saved) },
                onRemoved: { id in vehicleRemoved(id) }
            )
        case .newJob:
            NewJobView(prefillStart: nil, prefillCustomerID: customerID)
        }
    }

    /// A job created from the New job sheet shows up in the history (and
    /// the overview's upcoming count).
    private func sheetDismissed() {
        Task {
            await reloadJobs()
            await reloadSummary()
        }
    }

    private func vehicleSaved(_ saved: Vehicle) {
        var vehicles = history.vehicles.value ?? []
        if let index = vehicles.firstIndex(where: { $0.id == saved.id }) {
            vehicles[index] = saved
            toasts.show("Vehicle saved")
        } else {
            vehicles.append(saved)
            toasts.show("Vehicle added")
        }
        history.vehicles = .loaded(vehicles)
    }

    private func vehicleRemoved(_ id: UUID) {
        let vehicles = (history.vehicles.value ?? []).filter { $0.id != id }
        history.vehicles = .loaded(vehicles)
        toasts.show("Vehicle removed")
    }

    // MARK: Archive

    private func confirmArchive() {
        confirmation = ConfirmationRequest(
            title: "Archive this customer?",
            message: "They're hidden from the customer list and search. Their jobs, invoices and history stay. You can restore them any time.",
            confirmTitle: "Archive",
            isDestructive: true
        ) {
            await setArchived(true)
        }
    }

    private func setArchived(_ archived: Bool) async {
        do {
            let shopID = try appState.requireShopID()
            let updated = try await CustomerService.setArchived(shopID: shopID, customerID: customerID, archived: archived)
            state = .loaded(updated)
            toasts.show(archived ? "Customer archived" : "Customer restored")
        } catch {
            toasts.showError(error)
        }
    }

    // MARK: Saved cards

    private func confirmRemoveCard(_ card: SavedCard) {
        confirmation = ConfirmationRequest(
            title: "Remove \(card.label)?",
            message: "The card is removed from this customer in Stripe, so it can't be charged again. The customer can save a card again from a pay link.",
            confirmTitle: "Remove card",
            isDestructive: true
        ) {
            await removeCard(card)
        }
    }

    private func removeCard(_ card: SavedCard) async {
        do {
            let shopID = try appState.requireShopID()
            try await PaymentService.removeSavedCard(
                shopID: shopID,
                customerID: customerID,
                paymentMethodID: card.stripePaymentMethodID
            )
            if let cards = history.savedCards.value {
                history.savedCards = .loaded(cards.filter { $0.id != card.id })
            }
            toasts.show("Card removed")
        } catch {
            toasts.showError(error)
        }
        await reloadSavedCards()
    }

    private func reloadSavedCards() async {
        guard permissions.canSeeSavedCards, let shopID = try? appState.requireShopID() else { return }
        let id = customerID
        let result = await LoadState<[SavedCard]>.result {
            try await CustomerService.savedCards(shopID: shopID, customerID: id)
        }
        history.savedCards.apply(result)
    }

    // MARK: Loading

    private func loadAll() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let result = await LoadState<Customer>.result {
            try await CustomerService.fetch(shopID: shopID, customerID: customerID)
        }
        if case .failed(let message) = result, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        guard state.value != nil else { return }
        await loadHistory()
        await loadReferenceData()
    }

    private func loadHistory() async {
        guard let shopID = try? appState.requireShopID() else { return }
        let loaded = await CustomerDetailLoader.load(
            shopID: shopID,
            customerID: customerID,
            permissions: permissions,
            current: history
        )
        history = loaded
    }

    private func reloadJobs() async {
        guard let shopID = try? appState.requireShopID() else { return }
        let id = customerID
        let result = await LoadState<[CustomerJobSummary]>.result {
            try await CustomerService.jobs(shopID: shopID, customerID: id)
        }
        history.jobs.apply(result)
    }

    private func reloadCustomFields() async {
        guard let shopID = try? appState.requireShopID() else { return }
        if history.customFields.value == nil { history.customFields = .loading }
        history.customFields.apply(await CustomerDetailLoader.loadCustomFields(shopID: shopID))
    }

    private func reloadSummary() async {
        guard permissions.canSeeSummary else { return }
        let id = customerID
        if history.summary.value == nil { history.summary = .loading }
        let result = await LoadState<CustomerSummary>.result {
            try await CustomerService.summary(customerID: id)
        }
        history.summary.apply(result)
    }

    /// Size classes for the vehicle editor and tag suggestions for the
    /// customer editor — both optional helpers, so failures stay quiet.
    private func loadReferenceData() async {
        guard let shopID = try? appState.requireShopID() else { return }
        if categories.isEmpty, let loaded = try? await VehicleService.categories(shopID: shopID) {
            categories = loaded
        }
        if permissions.canEdit, let loaded = try? await CustomerService.allTags(shopID: shopID) {
            tagSuggestions = loaded
        }
    }
}

// MARK: - Supporting types

enum CustomerDetailSheet: Identifiable {
    case edit(Customer)
    case addVehicle
    case editVehicle(Vehicle)
    case newJob

    var id: String {
        switch self {
        case .edit: return "edit"
        case .addVehicle: return "addVehicle"
        case .editVehicle(let vehicle): return "vehicle-" + vehicle.id.uuidString
        case .newJob: return "newJob"
        }
    }
}

/// What the signed-in role may see and do on this screen (UI gating; the
/// server enforces the same rules).
struct CustomerDetailPermissions: Equatable {
    var canEdit: Bool
    var canCreateJobs: Bool
    var canMessage: Bool
    var canSeeQuotes: Bool
    var canSeeInvoices: Bool
    var canSeeMemberships: Bool
    var canSeeSavedCards: Bool
    /// The server's overview (`customer_summary`) is owner/admin/manager.
    var canSeeSummary: Bool
    /// Customer files (P-25): add, show to the customer, remove (managers+).
    var canManageDocuments: Bool
    /// Referral links (P-29): owner/admin/manager.
    var canUseReferrals: Bool
    /// Removing a saved card follows the saved-card capability (manager+).
    var canRemoveCards: Bool { canSeeSavedCards }

    /// Money amounts on job rows follow invoice access.
    var canSeeJobTotals: Bool { canSeeInvoices }
}

struct CustomerDetailActions {
    let addVehicle: () -> Void
    let editVehicle: (Vehicle) -> Void
    let newJob: () -> Void
    let retryHistory: () async -> Void
    let retrySummary: () async -> Void
    let retryCustomFields: () async -> Void
    let removeCard: (SavedCard) -> Void
    /// A section saved the customer row (custom fields).
    let customerUpdated: (Customer) -> Void
}

/// Each history section loads (and fails) on its own, so one missing
/// section never blanks the whole customer.
struct CustomerDetailHistory {
    var vehicles: LoadState<[Vehicle]> = .idle
    var jobs: LoadState<[CustomerJobSummary]> = .idle
    var quotes: LoadState<[CustomerQuoteSummary]> = .idle
    var invoices: LoadState<[CustomerInvoiceSummary]> = .idle
    var memberships: LoadState<[CustomerMembershipItem]> = .idle
    var savedCards: LoadState<[SavedCard]> = .idle
    var summary: LoadState<CustomerSummary> = .idle
    /// The shop's customer fields, archived ones included (P-9).
    var customFields: LoadState<[JobsCustomField]> = .idle
    /// Whether the shop's referral program is on (P-29; managers+ read it,
    /// false when unknown).
    var referralProgramOn = false
}

/// Loads every history section in parallel.
enum CustomerDetailLoader {

    static func load(
        shopID: UUID,
        customerID: UUID,
        permissions: CustomerDetailPermissions,
        current: CustomerDetailHistory
    ) async -> CustomerDetailHistory {
        async let vehicles = loadVehicles(shopID: shopID, customerID: customerID)
        async let jobs = loadJobs(shopID: shopID, customerID: customerID)
        async let quotes = loadQuotes(allowed: permissions.canSeeQuotes, shopID: shopID, customerID: customerID)
        async let invoices = loadInvoices(allowed: permissions.canSeeInvoices, shopID: shopID, customerID: customerID)
        async let memberships = loadMemberships(allowed: permissions.canSeeMemberships, shopID: shopID, customerID: customerID)
        async let savedCards = loadSavedCards(allowed: permissions.canSeeSavedCards, shopID: shopID, customerID: customerID)
        async let summary = loadSummary(allowed: permissions.canSeeSummary, customerID: customerID)
        async let customFields = loadCustomFields(shopID: shopID)
        async let referralProgramOn = loadReferralProgram(allowed: permissions.canUseReferrals, shopID: shopID)

        var next = current
        next.vehicles.apply(await vehicles)
        next.jobs.apply(await jobs)
        next.quotes.apply(await quotes)
        next.invoices.apply(await invoices)
        next.memberships.apply(await memberships)
        next.savedCards.apply(await savedCards)
        next.summary.apply(await summary)
        next.customFields.apply(await customFields)
        next.referralProgramOn = await referralProgramOn
        return next
    }

    static func loadCustomFields(shopID: UUID) async -> LoadState<[JobsCustomField]> {
        await LoadState<[JobsCustomField]>.result {
            try await JobsCustomFieldService.allFields(shopID: shopID, entity: .customer)
        }
    }

    /// The referral card is an extra: a failed read just hides it.
    private static func loadReferralProgram(allowed: Bool, shopID: UUID) async -> Bool {
        guard allowed else { return false }
        return (try? await OpsReferralService.isProgramEnabled(shopID: shopID)) ?? false
    }

    private static func loadVehicles(shopID: UUID, customerID: UUID) async -> LoadState<[Vehicle]> {
        await LoadState<[Vehicle]>.result {
            try await VehicleService.list(shopID: shopID, customerID: customerID)
        }
    }

    private static func loadJobs(shopID: UUID, customerID: UUID) async -> LoadState<[CustomerJobSummary]> {
        await LoadState<[CustomerJobSummary]>.result {
            try await CustomerService.jobs(shopID: shopID, customerID: customerID)
        }
    }

    private static func loadQuotes(allowed: Bool, shopID: UUID, customerID: UUID) async -> LoadState<[CustomerQuoteSummary]> {
        guard allowed else { return .loaded([]) }
        return await LoadState<[CustomerQuoteSummary]>.result {
            try await CustomerService.quotes(shopID: shopID, customerID: customerID)
        }
    }

    private static func loadInvoices(allowed: Bool, shopID: UUID, customerID: UUID) async -> LoadState<[CustomerInvoiceSummary]> {
        guard allowed else { return .loaded([]) }
        return await LoadState<[CustomerInvoiceSummary]>.result {
            try await CustomerService.invoices(shopID: shopID, customerID: customerID)
        }
    }

    private static func loadMemberships(allowed: Bool, shopID: UUID, customerID: UUID) async -> LoadState<[CustomerMembershipItem]> {
        guard allowed else { return .loaded([]) }
        return await LoadState<[CustomerMembershipItem]>.result {
            try await CustomerService.memberships(shopID: shopID, customerID: customerID)
        }
    }

    private static func loadSavedCards(allowed: Bool, shopID: UUID, customerID: UUID) async -> LoadState<[SavedCard]> {
        guard allowed else { return .loaded([]) }
        return await LoadState<[SavedCard]>.result {
            try await CustomerService.savedCards(shopID: shopID, customerID: customerID)
        }
    }

    /// Not loaded at all for roles below manager (the section is hidden).
    private static func loadSummary(allowed: Bool, customerID: UUID) async -> LoadState<CustomerSummary> {
        guard allowed else { return .idle }
        return await LoadState<CustomerSummary>.result {
            try await CustomerService.summary(customerID: customerID)
        }
    }
}
