//
//  NewJobCustomerVehicleSteps.swift
//  DetailCRM
//
//  Steps 1–2 of the New Job flow: find or create the customer, then pick
//  or add the vehicle (with optional VIN decode).
//

import SwiftUI
import DetailCore

// MARK: - Step 1: customer

struct NewJobCustomerStep: View {
    @Bindable var model: NewJobModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let selected = model.customer {
                    selectedCard(selected)
                }
                SearchBar(text: $model.customerQuery, prompt: "Search name, phone or email")
                results
                newCustomerSection
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .task(id: model.customerQuery) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.searchCustomers()
        }
    }

    private func selectedCard(_ customer: JobCustomer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Selected")
            Button {
                Task { await model.selectCustomer(customer) }
            } label: {
                NewJobCustomerRow(customer: customer, isSelected: true)
            }
            .buttonStyle(.plain)
            .cardStyle(padding: Theme.Spacing.sm)
        }
    }

    @ViewBuilder
    private var results: some View {
        switch model.customerResults {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().tint(Theme.glacier)
                Text("Searching…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await model.searchCustomers()
                }
            }
        case .loaded(let customers):
            if model.customerQuery.trimmedNonEmpty == nil {
                Text("Search for an existing customer, or add a new one below.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else if customers.isEmpty {
                JobEmptyLine(text: "No customers match “\(model.customerQuery)”.", systemImage: "person.crop.circle.badge.questionmark")
            } else {
                VStack(spacing: 0) {
                    ForEach(customers) { customer in
                        Button {
                            Task { await model.selectCustomer(customer) }
                        } label: {
                            NewJobCustomerRow(customer: customer, isSelected: customer.id == model.customer?.id)
                        }
                        .buttonStyle(.plain)
                        if customer.id != customers.last?.id {
                            JobDivider()
                        }
                    }
                }
                .cardStyle(padding: Theme.Spacing.sm)
            }
        }
    }

    private var newCustomerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                model.isAddingCustomer.toggle()
            } label: {
                Label(model.isAddingCustomer ? "Hide new customer" : "New customer", systemImage: model.isAddingCustomer ? "chevron.up" : "person.badge.plus")
                    .font(Theme.Typography.buttonCompact)
            }
            .buttonStyle(.themeSecondaryCompact)
            if model.isAddingCustomer {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let error = model.customerError {
                        InlineMessage(text: error, kind: .error)
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        ThemedTextField(label: "First name", placeholder: "First", text: $model.customerDraft.firstName, kind: .name)
                        ThemedTextField(label: "Last name", placeholder: "Last", text: $model.customerDraft.lastName, kind: .name)
                    }
                    ThemedTextField(label: "Mobile phone", placeholder: "(555) 555-0100", text: $model.customerDraft.phone, kind: .phone)
                    ThemedTextField(label: "Email", placeholder: "name@example.com", text: $model.customerDraft.email, kind: .email)
                    AsyncButton("Add customer", style: .themePrimary) {
                        await model.createCustomer()
                    }
                    .disabled(!model.customerDraft.hasName)
                }
                .cardStyle()
            }
        }
    }
}

struct NewJobCustomerRow: View {
    let customer: JobCustomer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: customer.displayName, size: Theme.Size.avatarSmall)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(customer.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(contactLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(minHeight: Theme.Size.controlHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var contactLine: String {
        let parts: [String] = [customer.phoneDisplay, customer.email?.trimmedNonEmpty, customer.secondaryLine]
            .compactMap { $0 }
        return parts.isEmpty ? "No contact details" : parts.joined(separator: " · ")
    }
}

// MARK: - Step 2: vehicle

struct NewJobVehicleStep: View {
    @Bindable var model: NewJobModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let customer = model.customer {
                    Text("Vehicle for \(customer.displayName)")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                }
                vehicleList
                addVehicleSection
                noVehicleSection
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private var vehicleList: some View {
        switch model.vehicles {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().tint(Theme.glacier)
                Text("Loading vehicles…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await model.loadVehicles()
                }
            }
        case .loaded(let vehicles):
            if vehicles.isEmpty {
                JobEmptyLine(text: "No vehicles on file for this customer.", systemImage: "car")
            } else {
                VStack(spacing: 0) {
                    ForEach(vehicles) { vehicle in
                        Button {
                            model.selectVehicle(vehicle)
                        } label: {
                            NewJobVehicleRow(
                                vehicle: vehicle,
                                categoryName: categoryName(vehicle.categoryID),
                                isSelected: vehicle.id == model.vehicle?.id
                            )
                        }
                        .buttonStyle(.plain)
                        if vehicle.id != vehicles.last?.id {
                            JobDivider()
                        }
                    }
                }
                .cardStyle(padding: Theme.Spacing.sm)
            }
        }
    }

    private func categoryName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return model.categories.first { $0.id == id }?.name
    }

    private var addVehicleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                model.isAddingVehicle.toggle()
            } label: {
                Label(model.isAddingVehicle ? "Hide new vehicle" : "Add a vehicle", systemImage: model.isAddingVehicle ? "chevron.up" : "car.side")
            }
            .buttonStyle(.themeSecondaryCompact)
            if model.isAddingVehicle {
                NewJobVehicleForm(model: model)
                    .cardStyle()
            }
        }
    }

    private var noVehicleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "No vehicle")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Book without a vehicle (e.g. a product sale). Prices use the size you pick, or base prices.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.categories.isEmpty {
                    Picker("Price as", selection: $model.pricingCategoryID) {
                        Text("Base prices").tag(UUID?.none)
                        ForEach(model.categories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                }
                Button("Continue without a vehicle") {
                    model.selectVehicle(nil)
                }
                .buttonStyle(.themeSecondary)
            }
            .cardStyle()
        }
    }
}

struct NewJobVehicleRow: View {
    let vehicle: JobVehicle
    let categoryName: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "car.fill")
                .foregroundStyle(Theme.glacier)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(vehicle.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(categoryName == nil ? Theme.warningInk : Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(minHeight: Theme.Size.controlHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let line = vehicle.detailLine { parts.append(line) }
        parts.append(categoryName ?? "No size category — base prices")
        return parts.joined(separator: " · ")
    }
}

/// New vehicle fields with VIN scan (P-22) and decode.
struct NewJobVehicleForm: View {
    @Bindable var model: NewJobModel

    @State private var showingScanner = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let error = model.vehicleError {
                InlineMessage(text: error, kind: .error)
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                ThemedTextField(label: "VIN (optional)", placeholder: "17 characters", text: $model.vehicleDraft.vin)
                    .textInputAutocapitalization(.characters)
                AsyncButton("Decode", style: .themeSecondaryCompact) {
                    await model.decodeVIN()
                }
                .disabled(VIN.normalize(model.vehicleDraft.vin).count != 17)
                .padding(.bottom, 6)
            }
            Button {
                showingScanner = true
            } label: {
                Label("Scan the VIN barcode", systemImage: "barcode.viewfinder")
            }
            .buttonStyle(.themeSecondaryCompact)
            .accessibilityHint("Opens the camera to read the VIN from the door jamb or windshield")
            HStack(spacing: Theme.Spacing.sm) {
                ThemedTextField(label: "Year", placeholder: "2022", text: $model.vehicleYearText, kind: .number)
                    .frame(maxWidth: 110)
                ThemedTextField(label: "Make", placeholder: "Toyota", text: $model.vehicleDraft.make)
            }
            HStack(spacing: Theme.Spacing.sm) {
                ThemedTextField(label: "Model", placeholder: "RAV4", text: $model.vehicleDraft.model)
                ThemedTextField(label: "Trim", placeholder: "XLE", text: $model.vehicleDraft.trim)
            }
            ThemedTextField(label: "Color", placeholder: "Blue", text: $model.vehicleDraft.color)
            if !model.categories.isEmpty {
                FormRow("Size category", hint: "Sets which prices apply.") {
                    Picker("Size category", selection: $model.vehicleDraft.categoryID) {
                        Text("Not set").tag(UUID?.none)
                        ForEach(model.categories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                }
            }
            AsyncButton("Add vehicle", style: .themePrimary) {
                await model.createVehicle()
            }
        }
        .sheet(isPresented: $showingScanner) {
            JobsVINScannerView { result in
                model.vehicleDraft.vin = result.vin
                Task { await model.decodeVIN(requireCheckDigit: result.checkDigitVerified) }
            }
        }
    }
}
