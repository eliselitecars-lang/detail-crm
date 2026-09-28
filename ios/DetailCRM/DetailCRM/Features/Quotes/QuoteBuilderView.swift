//
//  QuoteBuilderView.swift
//  DetailCRM
//
//  New / edit quote sheet: customer + vehicle, proposal options (good /
//  better / best, P-15), lines from the catalog (priced by the server's
//  `price_services` for the vehicle's size and the customer's memberships),
//  preset fees (priced by the server on save, P-21) or custom lines,
//  optional upsells, discount, validity, notes and terms. The totals shown
//  here are a labelled estimate; the saved quote's totals are computed by
//  the database.
//

import SwiftUI
import DetailCore

/// Sheets the builder presents on top of itself.
enum QuoteBuilderSheet: Identifiable {
    case customer
    case services
    case fees
    case newLine
    case editLine(QuoteDraftLine)

    var id: String {
        switch self {
        case .customer: return "customer"
        case .services: return "services"
        case .fees: return "fees"
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
    /// Which lines are shown and where new ones go: nil = shared by every
    /// option (the only segment of a quote without options).
    @State private var segment: UUID?
    @State private var confirmation: ConfirmationRequest?
    /// Opened for a new quote (a failed first save may already have
    /// created it; the retry still says "created").
    private let startedAsNew: Bool

    init(draft: QuoteDraft, onSaved: @escaping (UUID) -> Void) {
        self.onSaved = onSaved
        self.startedAsNew = draft.quoteID == nil
        self._draft = State(initialValue: draft)
        self._hasExpiry = State(initialValue: draft.validUntil != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                customerSection
                optionsSection
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
            .confirmation($confirmation)
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

    private var optionsSection: some View {
        Section {
            if draft.options.isEmpty {
                Button {
                    startOptions()
                } label: {
                    Label("Offer options (good / better / best)", systemImage: "square.stack.3d.up")
                        .foregroundStyle(Theme.glacier)
                }
                .themedRow()
            } else {
                ForEach($draft.options, id: \.localID) { $option in
                    HStack(spacing: Theme.Spacing.md) {
                        TextField("Option name", text: $option.name)
                            .font(Theme.Typography.body)
                            .accessibilityLabel("Option name")
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(itemCountText(draft.lines(inSegment: option.localID).count))
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .themedRow()
                }
                .onDelete { offsets in
                    requestDeleteOptions(at: offsets)
                }
                .onMove { source, destination in
                    draft.options.move(fromOffsets: source, toOffset: destination)
                }
                if draft.options.count < MoneyQuoteOption.maxPerQuote {
                    Button {
                        addOption()
                    } label: {
                        Label("Add option", systemImage: "plus.circle")
                            .foregroundStyle(Theme.glacier)
                    }
                    .themedRow()
                }
                if let problem = optionNameProblem {
                    InlineMessage(text: problem)
                        .themedRow()
                }
            }
        } header: {
            Text("Options")
        } footer: {
            Text(draft.options.isEmpty
                ? "Let the customer choose between up to \(MoneyQuoteOption.maxPerQuote) versions of this quote. Items can be shared by every option or belong to one."
                : "The customer picks one option when approving. Until then the quote total shows the first option. Swipe to remove an option.")
        }
    }

    private var linesSection: some View {
        Section {
            if !draft.options.isEmpty {
                MoneyQuoteOptionPicker(
                    choices: draft.options.map { MoneyQuoteOptionPicker.Choice(draft: $0) },
                    selection: $segment,
                    sharedTitle: "Every option",
                    accessibilityTitle: "Showing items for"
                )
                .themedRow()
            }
            ForEach(segmentLines, id: \.localID) { line in
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
                        badge: line.isOptional ? "Optional" : (line.feeID != nil ? "Fee" : nil),
                        note: line.pricingNote,
                        noteIsWarning: line.serviceID != nil && line.unitPriceCents == 0 && line.pricingNote != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
            .onDelete { offsets in
                removeSegmentLines(at: offsets)
            }
            .onMove { source, destination in
                moveSegmentLines(from: source, to: destination)
            }
            if segmentLines.isEmpty && !draft.options.isEmpty {
                Text(segment == nil
                    ? "No shared items. Items added here appear in every option."
                    : "No items in this option yet. Shared items are included too.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
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
            Button {
                activeSheet = .fees
            } label: {
                Label("Add a preset fee", systemImage: "tag")
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
                if segmentLines.count > 1 || draft.options.count > 1 {
                    EditButton()
                        .font(Theme.Typography.footnote.weight(.semibold))
                }
            }
        } footer: {
            Text(draft.options.isEmpty
                ? "Optional items are upsells the customer can pick when approving. Tap an item to edit it; swipe to remove."
                : "Items under \"Every option\" are in each option. Optional items are upsells the customer can pick when approving. Tap an item to edit it or move it to another option.")
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
            if !draft.options.isEmpty {
                ForEach(draft.options, id: \.localID) { option in
                    MoneyAmountRow(
                        label: option.name.trimmedNonEmpty ?? "Untitled option",
                        cents: optionPreview(option.localID).totalCents,
                        currencyCode: appState.currencyCode,
                        isStrong: option.localID == estimateOptionLocalID
                    )
                    .themedRow()
                }
                Text("Breakdown for \(estimateOptionName):")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            }
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
            Text(draft.options.isEmpty
                ? "Estimate only — the saved quote's totals are calculated by the server. Optional items count only once the customer picks them."
                : "Estimate only — each option is its own items plus the shared ones, calculated by the server when saved. Optional items count only once the customer picks them.")
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
                .disabled(draft.customer == nil || isPricing || optionNameProblem != nil)
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
        case .fees:
            MoneyFeePickerSheet { fee in
                draft.lines.append(QuoteDraftLine(fee: fee, optionLocalID: segment))
            }
        case .newLine:
            QuoteLineEditorSheet(
                line: QuoteDraftLine(name: "", unitPriceCents: 0, optionLocalID: segment),
                isNew: true,
                currencyCode: appState.currencyCode,
                options: draft.options
            ) { line in
                draft.lines.append(line)
            }
        case .editLine(let line):
            QuoteLineEditorSheet(
                line: line,
                isNew: false,
                currencyCode: appState.currencyCode,
                options: draft.options
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

    /// Lines of the segment being edited (every line without options).
    private var segmentLines: [QuoteDraftLine] {
        draft.lines(inSegment: segment)
    }

    /// The option the estimate breaks down: the one being edited, else the
    /// one the quote total counts.
    private var estimateOptionLocalID: UUID? {
        segment ?? draft.effectiveOptionLocalID
    }

    private var estimateOptionName: String {
        draft.options.first(where: { $0.localID == estimateOptionLocalID })?.name.trimmedNonEmpty ?? "the first option"
    }

    private var previewTotals: DocumentTotals {
        optionPreview(estimateOptionLocalID)
    }

    private func optionPreview(_ optionLocalID: UUID?) -> DocumentTotals {
        var preview = draft
        preview.discountValue = parsedDiscount ?? 0
        return preview.previewTotals(forOption: optionLocalID)
    }

    /// Why the options can't be saved yet, or nil.
    private var optionNameProblem: String? {
        guard draft.options.contains(where: { $0.validName == nil }) else { return nil }
        return "Give every option a name (up to \(MoneyQuoteOption.maxNameLength) characters)."
    }

    private func itemCountText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
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
        // A quote with options opens on its first option unless it has
        // shared items to show.
        if let first = draft.options.first, draft.lines(inSegment: nil).isEmpty {
            segment = first.localID
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

    /// First options: two to start with (the existing items stay shared).
    private func startOptions() {
        let first = MoneyQuoteOption.Draft(name: MoneyQuoteOption.Draft.nextName(existing: []))
        draft.options.append(first)
        draft.options.append(MoneyQuoteOption.Draft(name: MoneyQuoteOption.Draft.nextName(existing: draft.options)))
        segment = first.localID
    }

    private func addOption() {
        guard draft.options.count < MoneyQuoteOption.maxPerQuote else { return }
        let option = MoneyQuoteOption.Draft(name: MoneyQuoteOption.Draft.nextName(existing: draft.options))
        draft.options.append(option)
        segment = option.localID
    }

    /// Removes options; one with items asks first (its items go with it).
    private func requestDeleteOptions(at offsets: IndexSet) {
        let removed = offsets.map { draft.options[$0] }
        let itemCount = removed.reduce(0) { $0 + draft.lines(inSegment: $1.localID).count }
        guard itemCount > 0 else {
            deleteOptions(removed.map { $0.localID })
            return
        }
        let name = removed.count == 1 ? (removed[0].name.trimmedNonEmpty ?? "this option") : "these options"
        confirmation = ConfirmationRequest(
            title: "Remove \(name)?",
            message: "Its \(itemCountText(itemCount)) are removed too. Shared items stay.",
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            deleteOptions(removed.map { $0.localID })
        }
    }

    private func deleteOptions(_ localIDs: [UUID]) {
        let ids = Set(localIDs)
        draft.options.removeAll { ids.contains($0.localID) }
        draft.lines.removeAll { line in line.optionLocalID.map { ids.contains($0) } ?? false }
        if let segment, ids.contains(segment) {
            self.segment = nil
        }
        if draft.options.isEmpty {
            segment = nil
        }
    }

    /// Deletes lines of the segment shown (offsets are into `segmentLines`).
    private func removeSegmentLines(at offsets: IndexSet) {
        let ids = Set(offsets.map { segmentLines[$0].localID })
        draft.lines.removeAll { ids.contains($0.localID) }
    }

    /// Reorders lines of the segment shown; other segments keep their places.
    private func moveSegmentLines(from source: IndexSet, to destination: Int) {
        let shown = segment
        var subset = draft.lines(inSegment: shown)
        subset.move(fromOffsets: source, toOffset: destination)
        var iterator = subset.makeIterator()
        for index in draft.lines.indices where draft.lines[index].optionLocalID == shown {
            if let next = iterator.next() {
                draft.lines[index] = next
            }
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
                        : priced.note,
                    optionLocalID: segment
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
            let quoteID = try await QuoteService.save(shopID: shopID, draft: &toSave)
            toasts.show(startedAsNew ? "Quote created" : "Quote saved")
            onSaved(quoteID)
            dismiss()
        } catch {
            // Keep what did get saved, so Save again finishes the job
            // instead of adding the same options and items twice.
            draft.adoptSaveProgress(from: toSave)
            errorText = ErrorText.message(for: error)
        }
    }
}
