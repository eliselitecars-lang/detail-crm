//
//  JobLinesEditorSheet.swift
//  DetailCRM
//
//  Manager+: the job's services. Catalog lines are priced by the server
//  (`price_services` for the job's customer and vehicle — category price,
//  membership inclusions); custom lines take a typed price. After every
//  write the job row is re-read so the totals shown are the server's.
//

import SwiftUI
import DetailCore

/// Screens inside the lines editor.
enum JobLinesRoute: Hashable {
    case catalog
    case custom
    case edit(UUID)
}

struct JobLinesEditorSheet: View {
    let model: JobDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var path: [JobLinesRoute] = []
    @State private var suggestedDiscountBps: Int = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            listContent
                .navigationTitle("Services")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: JobLinesRoute.self) { route in
                    destination(route)
                }
        }
    }

    private func destination(_ route: JobLinesRoute) -> AnyView {
        switch route {
        case .catalog:
            return AnyView(
                JobCatalogPickerView(model: model) { suggestion in
                    suggestedDiscountBps = suggestion
                    path.removeAll()
                }
            )
        case .custom:
            return AnyView(JobLineFormView(model: model, line: nil) { path.removeAll() })
        case .edit(let id):
            let line = model.snapshot?.lineItems.first { $0.id == id }
            return AnyView(JobLineFormView(model: model, line: line) { path.removeAll() })
        }
    }

    private var listContent: AnyView {
        let lines = model.snapshot?.lineItems ?? []
        let currency = appState.currencyCode
        return AnyView(
            List {
                if let errorMessage {
                    Section {
                        InlineMessage(text: errorMessage, kind: .error)
                            .themedRow()
                    }
                }
                Section {
                    if lines.isEmpty {
                        JobEmptyLine(text: "No services yet.", systemImage: "list.bullet.rectangle")
                            .themedRow()
                    }
                    ForEach(lines) { line in
                        NavigationLink(value: JobLinesRoute.edit(line.id)) {
                            JobLineRow(line: line, currencyCode: currency)
                        }
                        .themedRow()
                    }
                }
                Section {
                    NavigationLink(value: JobLinesRoute.catalog) {
                        Label("Add from catalog", systemImage: "list.bullet.rectangle.portrait")
                            .foregroundStyle(Theme.glacier)
                    }
                    .themedRow()
                    NavigationLink(value: JobLinesRoute.custom) {
                        Label("Add a custom line", systemImage: "square.and.pencil")
                            .foregroundStyle(Theme.glacier)
                    }
                    .themedRow()
                }
                if let job = model.job {
                    Section("Job discount") {
                        JobDiscountEditor(
                            model: model,
                            job: job,
                            suggestedBps: suggestedDiscountBps,
                            onError: { message in errorMessage = message }
                        )
                        .themedRow()
                    }
                    Section("Totals") {
                        totalsRows(job, currency: currency)
                            .themedRow()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .screenBackground()
        )
    }

    private func totalsRows(_ job: Job, currency: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            JobMoneyRow(label: "Subtotal", cents: job.subtotalCents, currencyCode: currency)
            if job.discountCents > 0 {
                JobMoneyRow(label: "Discount", cents: -job.discountCents, currencyCode: currency)
            }
            JobMoneyRow(label: "Tax", cents: job.taxCents, currencyCode: currency)
            JobMoneyRow(label: "Total", cents: job.totalCents, currencyCode: currency, isTotal: true)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// Job-level discount: none, percent or a fixed amount.
struct JobDiscountEditor: View {
    let model: JobDetailModel
    let job: Job
    let suggestedBps: Int
    let onError: (String?) -> Void

    @Environment(AppState.self) private var appState
    @State private var kind: JobDiscountKind = .none
    @State private var valueText = ""
    @State private var didPrefill = false

    var body: some View {
        if job.couponID != nil {
            InlineMessage(text: "This job's discount comes from a coupon. Remove the coupon on the web app to set a manual discount.", kind: .info)
                .padding(.vertical, Theme.Spacing.xs)
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Discount", selection: $kind) {
                ForEach(JobDiscountKind.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if kind != .none {
                TextField(kind == .percent ? "Percent, e.g. 10" : "Amount, e.g. 25", text: $valueText)
                    .keyboardType(.decimalPad)
                    .inputFieldStyle()
            }
            if suggestedBps > 0 && job.discountKind == .none {
                Button("Apply member discount (\(JobsFormatting.percent(bps: suggestedBps)))") {
                    kind = .percent
                    valueText = JobsFormatting.percent(bps: suggestedBps).replacingOccurrences(of: "%", with: "")
                }
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.glacier)
            }
            AsyncButton("Save discount", style: .themeSecondaryCompact) {
                await save()
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            kind = job.discountKind
            switch job.discountKind {
            case .none: valueText = ""
            case .percent: valueText = JobsFormatting.percent(bps: job.discountValue).replacingOccurrences(of: "%", with: "")
            case .fixed: valueText = Money.editableString(cents: job.discountValue, currencyCode: appState.currencyCode)
            }
        }
    }

    private func save() async {
        onError(nil)
        var value = 0
        switch kind {
        case .none:
            value = 0
        case .percent:
            guard let bps = JobsFormatting.parsePercentBps(valueText) else {
                onError("Enter a percent between 0 and 100.")
                return
            }
            value = bps
        case .fixed:
            guard let cents = Money.parseCents(valueText, currencyCode: appState.currencyCode) else {
                onError("Enter the discount as an amount, like 25 or 24.99.")
                return
            }
            value = cents
        }
        do {
            try await model.updateDiscount(kind: kind, value: value)
        } catch {
            onError(ErrorText.message(for: error))
        }
    }
}

/// Add a custom line, or edit / delete an existing one.
struct JobLineFormView: View {
    let model: JobDetailModel
    let line: JobLineItem?
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var quantityText = "1"
    @State private var priceText = ""
    @State private var discountText = ""
    @State private var durationText = ""
    @State private var taxable = true
    @State private var errorMessage: String?
    @State private var didPrefill = false
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        FormScreen {
            if let errorMessage {
                InlineMessage(text: errorMessage, kind: .error)
            }
            ThemedTextField(label: "Name", placeholder: "Service or item", text: $name)
            FormRow("Description (optional)") {
                TextField("Details the customer sees", text: $descriptionText, axis: .vertical)
                    .lineLimit(2...5)
                    .inputFieldStyle()
            }
            HStack(spacing: Theme.Spacing.sm) {
                ThemedTextField(label: "Quantity", placeholder: "1", text: $quantityText, kind: .money)
                ThemedTextField(label: "Unit price", placeholder: "0.00", text: $priceText, kind: .money)
            }
            HStack(spacing: Theme.Spacing.sm) {
                ThemedTextField(label: "Line discount", placeholder: "0.00", text: $discountText, kind: .money)
                ThemedTextField(label: "Minutes", placeholder: "0", text: $durationText, kind: .number)
            }
            Toggle("Taxable", isOn: $taxable)
                .tint(Theme.glacier)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
            AsyncButton(line == nil ? "Add line" : "Save line", style: .themePrimary) {
                await save()
            }
            if line != nil {
                Button("Remove line", role: .destructive) {
                    confirmDelete()
                }
                .buttonStyle(.themeSecondary)
            }
        }
        .navigationTitle(line == nil ? "Custom line" : "Edit line")
        .navigationBarTitleDisplayMode(.inline)
        .confirmation($confirmation)
        .onAppear { prefill() }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let line else { return }
        let currency = appState.currencyCode
        name = line.name
        descriptionText = line.description ?? ""
        quantityText = JobsFormatting.quantity(line.quantity)
        priceText = Money.editableString(cents: line.unitPriceCents, currencyCode: currency)
        discountText = line.discountCents > 0 ? Money.editableString(cents: line.discountCents, currencyCode: currency) : ""
        durationText = line.durationMinutes > 0 ? String(line.durationMinutes) : ""
        taxable = line.taxable
    }

    private func draft() -> JobLineDraft? {
        let currency = appState.currencyCode
        guard let trimmedName = name.trimmedNonEmpty, trimmedName.count <= 200 else {
            errorMessage = "Enter a name (up to 200 characters)."
            return nil
        }
        guard let quantity = JobsFormatting.parseQuantity(quantityText) else {
            errorMessage = "Quantity must be more than 0, with at most 2 decimals."
            return nil
        }
        guard let price = Money.parseCents(priceText, currencyCode: currency) else {
            errorMessage = "Enter the unit price, like 150 or 149.99."
            return nil
        }
        var discount = 0
        if let text = discountText.trimmedNonEmpty {
            guard let cents = Money.parseCents(text, currencyCode: currency) else {
                errorMessage = "Enter the line discount as an amount."
                return nil
            }
            discount = cents
        }
        var minutes = 0
        if let text = durationText.trimmedNonEmpty {
            guard let value = Int(text), value >= 0, value <= 44_640 else {
                errorMessage = "Minutes must be a whole number."
                return nil
            }
            minutes = value
        }
        return JobLineDraft(
            serviceID: line?.serviceID,
            vehicleID: line?.vehicleID ?? model.job?.vehicleID,
            name: trimmedName,
            description: descriptionText.trimmedNonEmpty,
            quantity: quantity,
            unitPriceCents: price,
            discountCents: discount,
            taxable: taxable,
            durationMinutes: minutes,
            sort: line?.sort ?? model.nextLineSort
        )
    }

    private func save() async {
        errorMessage = nil
        guard let draft = draft() else { return }
        do {
            if let line {
                try await model.updateLine(line.id, draft: draft)
            } else {
                try await model.addLines([draft])
            }
            onDone()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func confirmDelete() {
        guard let line else { return }
        confirmation = ConfirmationRequest(
            title: "Remove \(line.name)?",
            message: "The job's totals update right away.",
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                try await model.deleteLine(line.id)
                onDone()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}
