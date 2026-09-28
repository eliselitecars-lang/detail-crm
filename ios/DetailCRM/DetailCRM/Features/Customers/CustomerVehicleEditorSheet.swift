//
//  CustomerVehicleEditorSheet.swift
//  DetailCRM
//
//  Add / edit a customer's vehicle (managers and above). A VIN — typed or
//  scanned from the door-jamb / windshield barcode (P-22) — can fill
//  year / make / model / trim via NHTSA vPIC after DetailCore's VIN checks.
//  The size class (vehicle category) drives catalog pricing.
//

import SwiftUI
import DetailCore

struct CustomerVehicleEditorSheet: View {
    let customerID: UUID
    /// nil = add a new vehicle.
    let vehicle: Vehicle?
    let categories: [VehicleCategory]
    let onSaved: (Vehicle) -> Void
    let onRemoved: (UUID) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: VehicleDraft
    @State private var showValidation = false
    @State private var formError: String?
    @State private var decodeMessage: CustomerVINDecodeMessage?
    @State private var confirmation: ConfirmationRequest?

    init(
        customerID: UUID,
        vehicle: Vehicle?,
        categories: [VehicleCategory],
        onSaved: @escaping (Vehicle) -> Void,
        onRemoved: @escaping (UUID) -> Void
    ) {
        self.customerID = customerID
        self.vehicle = vehicle
        self.categories = categories
        self.onSaved = onSaved
        self.onRemoved = onRemoved
        _draft = State(initialValue: vehicle.map { VehicleDraft(vehicle: $0) } ?? VehicleDraft())
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                AnyView(CustomerVINSection(draft: $draft, message: $decodeMessage))
                AnyView(CustomerVehicleDetailsSection(draft: $draft, categories: categories, showValidation: showValidation))
                VStack(spacing: Theme.Spacing.sm) {
                    if let formError {
                        InlineMessage(text: formError, kind: .error)
                    }
                    AsyncButton(vehicle == nil ? "Add vehicle" : "Save vehicle") {
                        await save()
                    }
                    if vehicle != nil {
                        Button(role: .destructive) {
                            confirmRemove()
                        } label: {
                            Label("Remove vehicle", systemImage: "trash")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.dangerInk)
                                .frame(maxWidth: .infinity, minHeight: Theme.Size.controlHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(vehicle == nil ? "New vehicle" : "Edit vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .confirmation($confirmation)
    }

    private func save() async {
        showValidation = true
        if let problem = draft.validationError {
            formError = problem
            return
        }
        formError = nil
        do {
            let shopID = try appState.requireShopID()
            let saved: Vehicle
            if let vehicle {
                saved = try await VehicleService.update(shopID: shopID, vehicleID: vehicle.id, draft: draft)
            } else {
                saved = try await VehicleService.create(shopID: shopID, customerID: customerID, draft: draft)
            }
            onSaved(saved)
            dismiss()
        } catch {
            formError = ErrorText.message(for: error)
        }
    }

    private func confirmRemove() {
        guard let vehicle else { return }
        confirmation = ConfirmationRequest(
            title: "Remove this vehicle?",
            message: "It disappears from this customer's vehicles. Past jobs keep their vehicle details.",
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await VehicleService.archive(shopID: shopID, vehicleID: vehicle.id)
                onRemoved(vehicle.id)
                dismiss()
            } catch {
                formError = ErrorText.message(for: error)
            }
        }
    }
}

/// Outcome of the last VIN lookup, shown under the VIN field.
struct CustomerVINDecodeMessage: Equatable {
    /// The (normalized) VIN this message is about; hidden once the VIN
    /// field no longer matches it.
    let vin: String
    let text: String
    let kind: InlineMessage.Kind
}

// MARK: - VIN

private struct CustomerVINSection: View {
    @Binding var draft: VehicleDraft
    @Binding var message: CustomerVINDecodeMessage?

    @State private var showingScanner = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "VIN")
            FormRow("Vehicle identification number", hint: "17 characters, on the dash or door jamb. Decoding fills in the details.") {
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("1HGCM82633A004352", text: $draft.vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(Theme.Typography.body.monospaced())
                        .inputFieldStyle()
                    AsyncButton("Decode", style: .themeSecondaryCompact) {
                        await decode()
                    }
                    .disabled(!canDecode)
                }
            }
            Button {
                showingScanner = true
            } label: {
                Label("Scan the VIN barcode", systemImage: "barcode.viewfinder")
            }
            .buttonStyle(.themeSecondaryCompact)
            .accessibilityHint("Opens the camera to read the VIN from the door jamb or windshield")
            if let message, message.vin == VIN.normalize(draft.vin) {
                InlineMessage(text: message.text, kind: message.kind)
            } else if let warning = precheckWarning {
                InlineMessage(text: warning, kind: .info)
            }
        }
        .sheet(isPresented: $showingScanner) {
            JobsVINScannerView { result in
                scanned(result)
            }
        }
    }

    /// A scanned VIN (P-22) fills the field and is decoded straight away.
    private func scanned(_ result: JobsVINScanResult) {
        draft.vin = result.vin
        message = nil
        Task { await decode() }
    }

    private var canDecode: Bool {
        VINDecoder.precheck(draft.vin).blocking == nil
    }

    /// Shown while typing a full-length VIN that fails a check.
    private var precheckWarning: String? {
        let check = VINDecoder.precheck(draft.vin)
        guard check.vin.count == 17 else { return nil }
        return check.blocking ?? check.warning
    }

    private func decode() async {
        do {
            let decoded = try await VINDecoder.decode(draft.vin)
            draft.vin = decoded.vin
            if let year = decoded.year { draft.year = String(year) }
            if let make = decoded.make { draft.make = make }
            if let model = decoded.model { draft.model = model }
            if let trim = decoded.trim { draft.trim = trim }
            var text = "Found \(decoded.summary)."
            if let warning = decoded.warning {
                text += " Note: \(warning)"
            }
            message = CustomerVINDecodeMessage(vin: decoded.vin, text: text, kind: decoded.warning == nil ? .success : .info)
        } catch is CancellationError {
            return
        } catch {
            message = CustomerVINDecodeMessage(vin: VIN.normalize(draft.vin), text: ErrorText.message(for: error), kind: .error)
        }
    }
}

// MARK: - Details

private struct CustomerVehicleDetailsSection: View {
    @Binding var draft: VehicleDraft
    let categories: [VehicleCategory]
    let showValidation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Vehicle")
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ThemedTextField(
                    label: "Year",
                    placeholder: "2021",
                    text: $draft.year,
                    kind: .number,
                    error: showValidation ? draft.yearError : nil
                )
                .frame(maxWidth: 110)
                ThemedTextField(label: "Make", placeholder: "Honda", text: $draft.make, kind: .name)
            }
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ThemedTextField(label: "Model", placeholder: "Civic", text: $draft.model, kind: .name)
                ThemedTextField(label: "Trim", placeholder: "Optional", text: $draft.trim, kind: .name)
            }
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ThemedTextField(label: "Color", placeholder: "Black", text: $draft.color, kind: .name)
                ThemedTextField(label: "Plate", placeholder: "Optional", text: $draft.licensePlate)
            }
            if !categories.isEmpty {
                FormRow("Size class", hint: "Used to price services for this vehicle.") {
                    Picker("Size class", selection: $draft.categoryID) {
                        Text("Not set").tag(UUID?.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.glacier)
                }
            }
            FormRow("Notes") {
                TextField("Paint condition, coatings, anything to watch for", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...8)
                    .padding(.vertical, Theme.Spacing.sm)
                    .inputFieldStyle()
            }
            if showValidation, let problem = draft.vinError {
                InlineMessage(text: problem, kind: .error)
            }
        }
    }
}
