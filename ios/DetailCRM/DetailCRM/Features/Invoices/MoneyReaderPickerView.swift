//
//  MoneyReaderPickerView.swift
//  DetailCRM
//
//  Take an in-person payment on a Bluetooth card reader (P-6): find the
//  shop's Stripe reader nearby, connect it, then collect the amount on it.
//  Shown only when Config.plist turns readers on (TERMINAL_BLUETOOTH_ENABLED).
//  Required reader software updates install while connecting; optional ones
//  can be installed here.
//

import SwiftUI
import DetailCore

struct MoneyReaderPickerView: View {
    let invoice: Invoice
    let amountCents: Int?
    let tipCents: Int
    /// A problem with the sheet's entries (e.g. an unreadable tip).
    var entryProblem: String? = nil
    let onFinished: () async -> Void
    /// Closes the card payment sheet after a successful payment.
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var activeRequest: MoneyTapToPayModel.Request?
    @State private var connectingID: String?

    private var model: MoneyTapToPayModel { .shared }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                // Also after a Tap to Pay payment (that reader stays
                // connected; looking for readers switches away from it).
                if !model.hasBluetoothReader {
                    readersSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Card reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.stopDiscovery()
                        dismiss()
                    }
                    .disabled(model.phase.isBusy)
                }
            }
            .interactiveDismissDisabled(model.phase.isBusy)
            .onAppear {
                // A finished Tap to Pay attempt's result isn't this sheet's.
                model.reset()
                startScanIfNeeded()
            }
            .onDisappear { model.stopDiscovery() }
            .sheet(item: $activeRequest) { request in
                MoneyTapToPayButton.ProgressSheet(
                    request: request,
                    currencyCode: appState.currencyCode,
                    onFinished: onFinished,
                    // Closing the card sheet closes this one with it.
                    onDone: onDone
                )
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if model.hasBluetoothReader, let name = model.connectedReaderName {
                Label(name, systemImage: "creditcard.viewfinder")
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .themedRow()
                if model.readerUpdateAvailable {
                    Button {
                        model.installReaderUpdate()
                    } label: {
                        Label("Install reader update", systemImage: "arrow.down.circle")
                            .foregroundStyle(Theme.glacier)
                    }
                    .disabled(model.phase.isBusy)
                    .themedRow()
                }
                if case .preparing(let text) = model.phase {
                    progressRow(text)
                }
                Button {
                    start()
                } label: {
                    Label(collectTitle, systemImage: "creditcard")
                }
                .buttonStyle(.themeMoney)
                .disabled(validationProblem != nil || model.phase.isBusy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let validationProblem {
                    Text(validationProblem)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                }
                Button(role: .destructive) {
                    Task {
                        await model.disconnectReader()
                        startScanIfNeeded()
                    }
                } label: {
                    Text("Disconnect reader")
                        .foregroundStyle(Theme.dangerInk)
                }
                .disabled(model.phase.isBusy)
                .themedRow()
            } else {
                if case .preparing(let text) = model.phase {
                    progressRow(text)
                } else if case .failed(let message) = model.phase {
                    InlineMessage(text: message)
                        .themedRow()
                } else {
                    Text("Turn the reader on and keep it next to this iPhone. It appears below; tap it to connect.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                }
            }
        } header: {
            Text("Reader")
        }
    }

    @ViewBuilder
    private var readersSection: some View {
        Section {
            if model.discoveredReaders.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    if model.isDiscovering {
                        ProgressView().tint(Theme.glacier)
                        Text("Looking for readers…")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("No readers found.")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .themedRow()
            } else {
                ForEach(model.discoveredReaders) { reader in
                    Button {
                        connect(reader)
                    } label: {
                        readerRow(reader)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.phase.isBusy)
                    .themedRow()
                }
            }
            if !model.isDiscovering {
                Button {
                    startScanIfNeeded()
                } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                        .foregroundStyle(Theme.glacier)
                }
                .themedRow()
            }
        } header: {
            Text("Nearby readers")
        } footer: {
            Text("Stripe card readers only. The reader is registered to your shop's location the first time it connects.")
        }
    }

    private func readerRow(_ reader: MoneyTapToPayModel.DiscoveredReader) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "creditcard.viewfinder")
                .foregroundStyle(Theme.glacier)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(reader.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if let detail = detail(reader) {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if connectingID == reader.id {
                ProgressView().tint(Theme.glacier)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects this reader")
    }

    private func detail(_ reader: MoneyTapToPayModel.DiscoveredReader) -> String? {
        var parts: [String] = []
        if let battery = reader.batteryLevel {
            parts.append("Battery \(Int((battery * 100).rounded()))%")
        }
        if reader.isSimulated {
            parts.append("Test reader")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView().tint(Theme.glacier)
            Text(text)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedRow()
    }

    // MARK: Values

    private var collectTitle: String {
        guard let amountCents, amountCents > 0 else { return "Collect on the reader" }
        return "Collect \(Money.format(cents: amountCents + tipCents, currencyCode: appState.currencyCode))"
    }

    private var validationProblem: String? {
        if let entryProblem { return entryProblem }
        guard let amountCents, amountCents > 0 else { return "Enter the amount to collect first." }
        guard amountCents <= invoice.balanceCents else { return "The amount can't be more than the balance due." }
        return nil
    }

    // MARK: Actions

    private func startScanIfNeeded() {
        guard !model.hasBluetoothReader, let shopID = try? appState.requireShopID() else { return }
        model.startBluetoothDiscovery(shopID: shopID)
    }

    private func connect(_ reader: MoneyTapToPayModel.DiscoveredReader) {
        guard let shopID = try? appState.requireShopID() else { return }
        connectingID = reader.id
        Task {
            await model.connectBluetoothReader(id: reader.id, shopID: shopID)
            connectingID = nil
        }
    }

    private func start() {
        guard validationProblem == nil, let amountCents, let shopID = try? appState.requireShopID() else { return }
        model.reset()
        activeRequest = MoneyTapToPayModel.Request(
            shopID: shopID,
            invoiceID: invoice.id,
            amountCents: amountCents == invoice.balanceCents ? nil : amountCents,
            tipCents: tipCents,
            merchantName: appState.shop?.name ?? "Payment",
            mode: .bluetoothReader
        )
    }
}
