//
//  QuoteBuilderView.swift
//  DetailCRM
//
//  New / edit quote sheet: customer + vehicle, lines from the catalog
//  (priced by the server's `price_services` for the vehicle's size and the
//  customer's memberships) or custom lines, optional upsells, discount,
//  validity, notes and terms. The totals shown here are a labelled
//  estimate; the saved quote's totals are computed by the database.
//

import SwiftUI
import DetailCore

/// Sheets the builder presents on top of itself.
enum QuoteBuilderSheet: Identifiable {
    case customer
    case services
    case newLine
    case editLine(QuoteDraftLine)

    var id: String {
        switch self {
        case .customer: return "customer"
        case .services: return "services"
        case .newLine: return "newLine"
        case .editLine(let line): return "line-\(line.localID.uuidString)"
        }
    }
}

struct QuoteBuilderView: View {
    let onSaved: (UUID) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var draft: QuoteDraft
    @State private var vehicles: [QuoteVehicleRef] = []
    @State private var vehiclesError: String?
    @State private var activeSheet: QuoteBuilderSheet?
    @State private var discountText = ""
    @State private var hasExpiry = false
    @State private var expiryDate = Date()
    @State private var didSetUp = false
    @State private var isSaving = false
    @State private var isPricing = false
    @State private var errorText: String?
    /// Customer + vehicle the catalog lines are currently priced for.
    @State private var pricedContext = QuoteBuilderPricingContext()
    /// Re-pricing runs one after another (latest context wins).
    @State private var repriceTask: Task<Void, Never>?
    /// Set when re-pricing for a new customer/vehicle failed.
    @State private var repriceProblem: String?

    init(draft: QuoteDraft, onSaved: @escaping (UUID) -> Void) {
        self.onSaved = onSaved
        self._draft = State(initialValue: draft)
        self._hasExpiry = State(initialValue: draft.validUntil != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                customerSection
                linesSection
                discountSection
                validitySection
                notesSection
                estimateSection
            }
            .screenBackground()
            .navigationTitle(draft.quoteID == nil ? "New quote" : "Edit quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(isSaving)
            .onAppear(perform: setUp)
            .task(id: draft.customer?.id) {
                await loadVehicles()
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
            }
        }
    }

    // MARK: Sections

    private var customerSection: some View {
        Section {
            MoneyPickerField(
                label: "Customer",
                value: draft.customer?.displayName,
                placeholder: "Choose a customer"
            ) {
                activeSheet = .customer
            }
            .themedRow()
            if draft.customer != nil {
                Picker("Vehicle", selection: vehicleSelection) {
                    Text("No vehicle").tag(UUID?.none)
                    ForEach(vehicles) { vehicle in
                        Text(vehicle.displayName).tag(Optional(vehicle.id))
                    }
                }
                .themedRow()
                if let vehiclesError {
                    InlineMessage(text: vehiclesError)
                        .themedRow()
                }
            }
        } header: {
            Text("Customer")
        } footer: {
            Text("Catalog prices follow the vehicle's size class and the customer's active memberships.")
        }
    }

    private var linesSection: some View {
        Section {
            ForEach(draft.lines, id: \.localID) { line in
                Button {
                    activeSheet = .editLine(line)
                } label: {
                    MoneyLineRow(
                        name: line.name,
                        detail: line.lineDescription,
                        quantity: line.quantity,
                        unitPriceCents: line.unitPriceCents,
                        discountCents: line.discountCents,
                        totalCents: line.totalsLine.lineTotalCents,
                        currencyCode: appState.currencyCode,
                        badge: line.isOptional ? "Optional" : nil,
                        note: line.pricingNote,
                        noteIsWarning: line.serviceID != nil && line.unitPriceCents == 0 && line.pricingNote != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
            .onDelete { offsets in
                draft.lines.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                draft.lines.move(fromOffsets: source, toOffset: destination)
            }
            Button {
                addFromCatalog()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Label("Add from catalog", systemImage: "list.bullet.rectangle")
                    if isPricing {
                        Spacer(minLength: Theme.Spacing.sm)
                        ProgressView()
                    }
                }
                .foregroundStyle(Theme.glacier)
            }
            .disabled(isPricing)
            .themedRow()
            Button {
                activeSheet = .newLine
            } label: {
                Label("Add custom item", systemImage: "plus.circle")
                    .foregroundStyle(Theme.glacier)
            }
            .themedRow()
            if let repriceProblem {
                InlineMessage(text: repriceProblem)
                    .themedRow()
                Button {
                    scheduleReprice()
                } label: {
                    Label("Update catalog prices", systemImage: "arrow.clockwise")
                        .foregroundStyle(Theme.glacier)
                }
                .disabled(isPricing)
                .themedRow()
            }
        } header: {
            HStack {
                Text("Items")
                Spacer()
                if draft.lines.count > 1 {
                    EditButton()
                        .font(Theme.Typography.footnote.weight(.semibold))
                }
            }
        } footer: {
            Text("Optional items are upsells the customer can pick when approving. Tap an item to edit it; swipe to remove.")
        }
    }

    private var discountSection: some View {
        Section {
            Picker("Discount", selection: $draft.discountKind) {
                ForEach(MoneyDiscountKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
            if draft.discountKind != .none {
                TextField(
                    draft.discountKind == .percent ? "Percent, e.g. 10" : "Amount, e.g. 25.00",
                    text: $discountText
                )
                .keyboardType(.decimalPad)
                .font(Theme.Typography.body)
                .themedRow()
                if !discountText.isEmpty && parsedDiscount == nil {
                    InlineMessage(text: draft.discountKind == .percent ? "Enter a percent from 0 to 100." : "Enter an amount like 25.00.")
                        .themedRow()
                }
            }
        } header: {
            Text("Discount")
        }
    }

    private var validitySection: some View {
        Section {
            Toggle("Expires", isOn: $hasExpiry)
                .tint(Theme.glacier)
                .themedRow()
            if hasExpiry {
                DatePicker("Valid through", selection: $expiryDate, displayedComponents: .date)
                    .environment(\.timeZone, appState.clock.timeZone)
                    .themedRow()
            }
        } header: {
            Text("Validity")
        } footer: {
            Text(hasExpiry ? "The customer can approve through the end of this day (shop time)." : "The quote stays open until you change it.")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Notes for the customer", text: $draft.notes, axis: .vertical)
                .lineLimit(2...8)
                .themedRow()
            TextField(draft.quoteID == nil ? "Terms (blank uses your shop's quote terms)" : "Terms", text: $draft.terms, axis: .vertical)
                .lineLimit(2...8)
                .themedRow()
            TextField("Internal notes (staff only)", text: $draft.internalNotes, axis: .vertical)
                .lineLimit(2...8)
                .themedRow()
        } header: {
            Text("Notes & terms")
        }
    }

    private var estimateSection: some View {
        Section {
            let totals = previewTotals
            MoneyTotalsView(
                subtotalCents: totals.subtotalCents,
                discountCents: totals.discountCents,
                taxCents: totals.taxCents,
                taxRateBps: draft.taxRateBps,
                totalCents: totals.totalCents,
                currencyCode: appState.currencyCode
            )
            .themedRow()
            if let errorText {
                InlineMessage(text: errorText)
                    .themedRow()
            }
        } header: {
            Text("Estimate")
        } footer: {
            Text("Estimate only — the saved quote's totals are calculated by the server. Optional items count only once the customer picks them.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(draft.customer == nil || isPricing)
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: QuoteBuilderSheet) -> some View {
        switch sheet {
        case .customer:
            QuoteCustomerPickerSheet { customer in
                if customer.id != draft.customer?.id {
                    draft.customer = customer
                    draft.vehicle = nil
                    vehicles = []
                    scheduleReprice()
                }
            }
        case .services:
            QuoteServicePickerSheet { services in
                Task { await addServices(services) }
            }
        case .newLine:
            QuoteLineEditorSheet(
                line: QuoteDraftLine(name: "", unitPriceCents: 0),
                isNew: true,
                currencyCode: appState.currencyCode
            ) { line in
                draft.lines.append(line)
            }
        case .editLine(let line):
            QuoteLineEditorSheet(
                line: line,
                isNew: false,
                currencyCode: appState.currencyCode
            ) { updated in
                if let index = draft.lines.firstIndex(where: { $0.localID == updated.localID }) {
                    draft.lines[index] = updated
                }
            }
        }
    }

    // MARK: Derived values

    private var currentPricingContext: QuoteBuilderPricingContext {
        QuoteBuilderPricingContext(customerID: draft.customer?.id, vehicleID: draft.vehicle?.id)
    }

    private var vehicleSelection: Binding<UUID?> {
        Binding(
            get: { draft.vehicle?.id },
            set: { id in
                guard id != draft.vehicle?.id else { return }
                draft.vehicle = vehicles.first(where: { $0.id == id })
                scheduleReprice()
            }
        )
    }

    /// Basis points (percent) or cents (fixed); nil when not parseable.
    private var parsedDiscount: Int? {
        switch draft.discountKind {
        case .none:
            return 0
        case .percent:
            return MoneyPercentFormat.basisPoints(from: discountText)
        case .fixed:
            return Money.parseCents(discountText, currencyCode: appState.currencyCode)
        }
    }

    private var previewTotals: DocumentTotals {
        var preview = draft
        preview.discountValue = parsedDiscount ?? 0
        return preview.previewTotals
    }

    // MARK: Actions

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        let clock = appState.clock
        // Saved / new lines are priced for the draft's own customer + vehicle.
        pricedContext = currentPricingContext
        if draft.quoteID == nil {
            draft.taxRateBps = appState.shop?.taxRateBps ?? 0
        }
        switch draft.discountKind {
        case .none:
            discountText = ""
        case .percent:
            discountText = MoneyPercentFormat.text(basisPoints: draft.discountValue)
                .replacingOccurrences(of: "%", with: "")
        case .fixed:
            discountText = Money.editableString(cents: draft.discountValue, currencyCode: appState.currencyCode)
        }
        if let validUntil = draft.validUntil, let day = clock.date(fromDateString: validUntil) {
            expiryDate = day
        } else {
            expiryDate = clock.addingDays(30, to: clock.startOfDay(Date()))
        }
    }

    private func loadVehicles() async {
        vehiclesError = nil
        guard let customerID = draft.customer?.id, let shopID = try? appState.requireShopID() else {
            vehicles = []
            return
        }
        do {
            var list = try await QuoteService.vehicles(shopID: shopID, customerID: customerID)
            // Keep an already-chosen (e.g. since archived) vehicle selectable.
            if let current = draft.vehicle, !list.contains(where: { $0.id == current.id }) {
                list.insert(current, at: 0)
            }
            vehicles = list
        } catch is CancellationError {
            return
        } catch {
            vehiclesError = "Couldn't load vehicles: \(ErrorText.message(for: error))"
        }
    }

    private func addFromCatalog() {
        guard draft.customer != nil else {
            errorText = "Choose a customer first — catalog prices depend on their vehicle and memberships."
            return
        }
        guard pricedContext == currentPricingContext || QuoteBuilderRepricing.serviceIDs(in: draft.lines).isEmpty else {
            errorText = "Update the catalog prices for this customer and vehicle first."
            return
        }
        errorText = nil
        activeSheet = .services
    }

    private func addServices(_ services: [QuoteServiceOption]) async {
        guard !services.isEmpty, let customer = draft.customer, let shopID = try? appState.requireShopID() else { return }
        let context = currentPricingContext
        isPricing = true
        defer { isPricing = false }
        do {
            let pricing = try await QuoteService.price(
                shopID: shopID,
                customerID: customer.id,
                vehicleID: context.vehicleID,
                serviceIDs: services.map { $0.id }
            )
            guard currentPricingContext == context else {
                errorText = "The customer or vehicle changed while pricing. Add the services again."
                return
            }
            // Every catalog line now reflects this customer + vehicle.
            pricedContext = context
            for priced in pricing.lines {
                let missingPrice = priced.unitPriceCents == nil
                draft.lines.append(QuoteDraftLine(
                    serviceID: priced.serviceID,
                    name: priced.name,
                    unitPriceCents: priced.unitPriceCents ?? 0,
                    taxable: priced.taxable,
                    durationMinutes: priced.durationMinutes ?? 0,
                    pricingNote: missingPrice
                        ? QuoteBuilderRepricing.missingPriceNote
                        : priced.note
                ))
            }
            if draft.discountKind == .none,
               pricing.suggestedDiscountKind == .percent,
               let value = pricing.suggestedDiscountValue, value > 0 {
                draft.discountKind = .percent
                draft.discountValue = value
                discountText = MoneyPercentFormat.text(basisPoints: value).replacingOccurrences(of: "%", with: "")
                toasts.show("Membership discount applied", style: .info)
            }
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    /// Queues a re-price after the customer or vehicle changed; runs after
    /// any re-price already in flight so the prices always move from the
    /// context they were computed for.
    private func scheduleReprice() {
        let previous = repriceTask
        repriceTask = Task {
            if let previous {
                await previous.value
            }
            await repriceIfNeeded()
        }
    }

    /// Re-prices catalog lines (and the membership discount) that still
    /// follow the old customer/vehicle's catalog prices.
    private func repriceIfNeeded() async {
        let from = pricedContext
        let to = currentPricingContext
        guard from != to else {
            repriceProblem = nil
            return
        }
        let serviceIDs = QuoteBuilderRepricing.serviceIDs(in: draft.lines)
        guard let customerID = to.customerID, !serviceIDs.isEmpty,
              let shopID = try? appState.requireShopID() else {
            // Nothing priced from the catalog yet (or no customer to price for).
            pricedContext = to
            repriceProblem = nil
            return
        }
        isPricing = true
        defer { isPricing = false }
        do {
            var oldPricing: QuotePricing?
            if let oldCustomerID = from.customerID {
                oldPricing = try await QuoteService.price(
                    shopID: shopID,
                    customerID: oldCustomerID,
                    vehicleID: from.vehicleID,
                    serviceIDs: serviceIDs
                )
            }
            let newPricing = try await QuoteService.price(
                shopID: shopID,
                customerID: customerID,
                vehicleID: to.vehicleID,
                serviceIDs: serviceIDs
            )
            // Changed again meanwhile: the queued re-price takes it from here.
            guard currentPricingContext == to else { return }
            let outcome = QuoteBuilderRepricing.reprice(
                lines: draft.lines,
                old: oldPricing,
                new: newPricing,
                discountKind: draft.discountKind,
                discountValue: parsedDiscount
            )
            draft.lines = outcome.lines
            var discountChanged = false
            switch outcome.discount {
            case .keep:
                break
            case .setPercent(let value):
                draft.discountKind = .percent
                draft.discountValue = value
                discountText = MoneyPercentFormat.text(basisPoints: value).replacingOccurrences(of: "%", with: "")
                discountChanged = true
            case .clear:
                draft.discountKind = .none
                draft.discountValue = 0
                discountText = ""
                discountChanged = true
            }
            pricedContext = to
            repriceProblem = nil
            if outcome.changedLineCount > 0 || discountChanged {
                toasts.show("Catalog prices updated for this customer and vehicle", style: .info)
            }
        } catch is CancellationError {
            return
        } catch {
            repriceProblem = "Catalog prices still reflect the previous customer or vehicle: \(ErrorText.message(for: error))"
        }
    }

    private func save() async {
        errorText = nil
        guard draft.customer != nil else {
            errorText = "Choose a customer."
            return
        }
        if pricedContext != currentPricingContext
            && !QuoteBuilderRepricing.serviceIDs(in: draft.lines).isEmpty {
            errorText = "Catalog prices haven't been updated for this customer and vehicle yet. Tap Update catalog prices, or remove the catalog items."
            return
        }
        guard let discount = parsedDiscount else {
            errorText = "Enter a valid discount."
            return
        }
        if draft.discountKind == .percent && discount > 10_000 {
            errorText = "A percent discount can't be more than 100%."
            return
        }
        var toSave = draft
        toSave.discountValue = draft.discountKind == .none ? 0 : discount
        toSave.validUntil = hasExpiry ? appState.clock.dateString(expiryDate) : nil
        guard let shopID = try? appState.requireShopID() else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let quoteID = try await QuoteService.save(shopID: shopID, draft: toSave)
            toasts.show(draft.quoteID == nil ? "Quote created" : "Quote saved")
            onSaved(quoteID)
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}
