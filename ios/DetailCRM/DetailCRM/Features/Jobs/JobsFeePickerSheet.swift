//
//  JobsFeePickerSheet.swift
//  DetailCRM
//
//  Add a preset fee (travel, disposal, …) to the job (P-21, managers+).
//  Fees and their amounts are set up by the shop on the web; the server
//  prices the line (`add_fee_line`), and fees marked "automatic" are
//  already added to new jobs of the matching location type.
//

import SwiftUI
import DetailCore

struct JobsFeePickerSheet: View {
    let model: JobDetailModel
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<[JobsShopFee]> = .idle
    @State private var adding: UUID?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading fees…", retry: { await load() }) { fees in
            list(fees)
        }
        .screenBackground()
        .navigationTitle("Add a fee")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func list(_ fees: [JobsShopFee]) -> some View {
        if fees.isEmpty {
            EmptyStateView(
                systemImage: "tag",
                title: "No preset fees",
                message: "Owners and admins add fees such as travel or disposal in Settings on the web."
            )
        } else {
            List {
                Section {
                    ForEach(fees) { fee in
                        Button {
                            Task { await add(fee) }
                        } label: {
                            row(fee)
                        }
                        .disabled(adding != nil)
                        .themedRow()
                    }
                } footer: {
                    Text("Fee lines use the amount set for the shop. Remove one like any other line.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ fee: JobsShopFee) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(fee.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                let details = [fee.taxable ? "taxed" : "not taxed", fee.autoApplyText].compactMap { $0 }
                Text(details.joined(separator: " · "))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if adding == fee.id {
                ProgressView().tint(Theme.glacier)
            } else {
                MoneyText(cents: fee.amountCents, currencyCode: appState.currencyCode, size: .small)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Adds this fee to the job")
    }

    private func load() async {
        guard let shopID = appState.shop?.id else { return }
        state.beginLoading()
        let result = await LoadState<[JobsShopFee]>.result {
            try await JobService.fees(shopID: shopID).filter(\.isSelectable)
        }
        state.apply(result)
    }

    private func add(_ fee: JobsShopFee) async {
        adding = fee.id
        defer { adding = nil }
        do {
            try await model.addFee(fee)
            toasts.show("\(fee.name) added")
            onDone()
        } catch {
            toasts.showError(error)
        }
    }
}
