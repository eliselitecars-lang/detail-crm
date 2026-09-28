//
//  JobsLineVehiclePicker.swift
//  DetailCRM
//
//  Which of the customer's vehicles a line is for (P-7): fleet and dealer
//  jobs bill several vehicles on one job, and a grouped invoice lists each
//  line under its vehicle. Defaults to the job's vehicle; the server checks
//  the vehicle belongs to the job's customer.
//

import SwiftUI
import DetailCore

struct JobsLineVehiclePicker: View {
    let model: JobDetailModel
    @Binding var vehicleID: UUID?

    @State private var state: LoadState<[JobVehicle]> = .idle

    var body: some View {
        FormRow("Vehicle", hint: "For jobs covering several of the customer's vehicles.") {
            switch state {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().tint(Theme.glacier)
                    Text("Loading vehicles…")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let message):
                JobReferenceLoadError(text: message) { await load() }
            case .loaded(let vehicles):
                Picker("Vehicle", selection: $vehicleID) {
                    Text("No vehicle").tag(UUID?.none)
                    ForEach(vehicles) { vehicle in
                        Text(vehicle.label).tag(UUID?.some(vehicle.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.glacier)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard state.value == nil else { return }
        state = .loading
        let result = await LoadState<[JobVehicle]>.result {
            try await model.customerVehicles()
        }
        state = result
    }
}
