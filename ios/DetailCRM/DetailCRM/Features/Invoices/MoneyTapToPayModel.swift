//
//  MoneyTapToPayModel.swift
//  DetailCRM
//
//  In-person card payments through the Stripe Terminal SDK (P-6): Tap to
//  Pay on iPhone, or a Bluetooth card reader when the shop turns readers on.
//
//  One payment:
//    1. the token provider is set to the shop (a different shop clears the
//       SDK's cached credentials and disconnects),
//    2. Tap to Pay: the built-in reader is discovered and connected to the
//       shop's Terminal Location (`terminal_location`); a Bluetooth reader is
//       picked in MoneyReaderPickerView first,
//    3. the server creates a `card_present` PaymentIntent for the invoice
//       (`terminal_payment_intent`: amount bounded by the balance, tip on
//       top, recorded as a pending payment),
//    4. the SDK retrieves it, collects the card (the system Tap to Pay
//       screen or the reader) and confirms it,
//    5. the Stripe webhook records the payment; the model waits briefly for
//       it so the invoice shows it (the webhook stays the source of truth).
//  Stopping before the card is confirmed releases the attempt on the server
//  (`cancel_open_payments`), so it never blocks a cash payment or a void.
//
//  Only this file and MoneyTerminalTokenProvider import StripeTerminal (its
//  type names — Toggle, PaymentMethod, PaymentStatus, Location … — would
//  clash with SwiftUI and DetailCore elsewhere); the screens read plain
//  state from here.
//

import Foundation
import Observation
import StripeTerminal
#if canImport(CoreLocation)
import CoreLocation
#endif

@Observable
@MainActor
final class MoneyTapToPayModel {

    /// The one model: the SDK has one reader connection per app.
    static let shared = MoneyTapToPayModel()

    // MARK: Types

    /// How the card is read.
    enum Mode: Hashable, Sendable {
        /// This iPhone (Tap to Pay on iPhone).
        case tapToPay
        /// A Bluetooth reader chosen in MoneyReaderPickerView.
        case bluetoothReader
    }

    /// What is happening now, for the screens.
    enum Phase: Equatable {
        case idle
        /// Getting ready (connecting, preparing the payment, updating).
        case preparing(String)
        /// Waiting for the card; the text is what to tell the customer.
        case collecting(String)
        /// The card was read; Stripe is confirming the charge.
        case processing
        case succeeded(String)
        case failed(String)
        case canceled

        /// A payment is under way (the sheet must not close meanwhile).
        var isBusy: Bool {
            switch self {
            case .preparing, .collecting, .processing: return true
            case .idle, .succeeded, .failed, .canceled: return false
            }
        }
    }

    /// One in-person payment. `amountCents` nil = the whole balance.
    struct Request: Hashable, Sendable {
        var shopID: UUID
        var invoiceID: UUID
        var amountCents: Int?
        var tipCents: Int
        /// Shown to the customer by Tap to Pay ("Pay <name>").
        var merchantName: String
        var mode: Mode
    }

    /// A Bluetooth reader found nearby.
    struct DiscoveredReader: Identifiable, Hashable, Sendable {
        /// The reader's serial number.
        var id: String
        var name: String
        /// 0…1 when the reader reports it.
        var batteryLevel: Double?
        var isSimulated: Bool
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    /// Bluetooth readers found by the running scan.
    private(set) var discoveredReaders: [DiscoveredReader] = []
    private(set) var isDiscovering = false
    /// "Stripe M2 · STRM26…" while a reader is connected.
    private(set) var connectedReaderName: String?
    /// Which kind of reader is connected (nil = none).
    private(set) var connectedMode: Mode?
    /// What the server set the running payment up to charge (amount + tip,
    /// from `terminal_payment_intent`); nil until it answers.
    private(set) var chargeCents: Int?
    /// A Bluetooth reader has an optional software update to install.
    private(set) var readerUpdateAvailable = false
    /// Why this iPhone can't use Tap to Pay (nil = it can, or not checked).
    private(set) var tapToPayUnavailableReason: String?
    private(set) var hasCheckedTapToPay = false

    // MARK: SDK plumbing

    @ObservationIgnored private let delegate = Delegate()
    #if canImport(CoreLocation)
    @ObservationIgnored private let locationPermission = LocationPermission()
    #endif
    @ObservationIgnored private var readersBySerial: [String: Reader] = [:]
    @ObservationIgnored private var discoveryCancelable: Cancelable?
    @ObservationIgnored private var collectCancelable: Cancelable?
    /// The invoice with an unconfirmed Terminal attempt on the server.
    @ObservationIgnored private var openAttempt: Request?
    /// Waiting for a Tap to Pay discovery result.
    @ObservationIgnored private var pendingTapDiscovery: CheckedContinuation<Reader, Error>?

    /// SCPErrorCanceled (SCPErrors.h): the operation was canceled.
    private static let canceledErrorCode = 2020
    /// Our own errors (never the SDK's).
    private static let appErrorDomain = "DetailCRM.Terminal"

    /// Simulated readers in the iOS Simulator (Stripe's test readers).
    static var usesSimulatedReaders: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private init() {
        delegate.model = self
    }

    // MARK: Availability

    /// Whether Tap to Pay can run here: the Config.plist switch, then the
    /// SDK's check of this iPhone and iOS version. Sets
    /// `tapToPayUnavailableReason`. Safe to call repeatedly.
    func checkTapToPaySupport(shopID: UUID) {
        guard AppConfig.tapToPayEnabled else {
            tapToPayUnavailableReason = "Tap to Pay on iPhone isn't turned on in this app."
            hasCheckedTapToPay = true
            return
        }
        prepareSDK(shopID: shopID)
        let result = Terminal.shared.supportsReaders(
            of: .tapToPay,
            discoveryMethod: .tapToPay,
            simulated: Self.usesSimulatedReaders
        )
        switch result {
        case .success:
            tapToPayUnavailableReason = nil
        case .failure(let error):
            tapToPayUnavailableReason = Self.describe(error, fallback: "This iPhone can't take Tap to Pay payments (it needs an iPhone XS or later with a recent iOS).")
        }
        hasCheckedTapToPay = true
    }

    /// Token provider in place and set to the shop; a new shop drops the old
    /// shop's reader connection and cached credentials.
    private func prepareSDK(shopID: UUID) {
        MoneyTerminalTokenProvider.install()
        let changed = MoneyTerminalTokenProvider.shared.use(shopID: shopID)
        if changed {
            let terminal = Terminal.shared
            if terminal.connectedReader != nil {
                terminal.disconnectReader { _ in }
            }
            terminal.clearCachedCredentials()
            connectedReaderName = nil
            connectedMode = nil
            readerUpdateAvailable = false
            readersBySerial = [:]
            discoveredReaders = []
        }
    }

    // MARK: Taking a payment

    /// Runs one in-person payment. Ends in `.succeeded`, `.failed` or
    /// `.canceled`; never throws.
    func collect(_ request: Request) async {
        guard !phase.isBusy else { return }
        chargeCents = nil
        prepareSDK(shopID: request.shopID)
        do {
            try await ensureReader(for: request)
            phase = .preparing("Setting up the payment…")
            let reply = try await MoneyTerminalService.paymentIntent(
                shopID: request.shopID,
                invoiceID: request.invoiceID,
                amountCents: request.amountCents,
                tipCents: request.tipCents,
                nonce: MoneyEdge.newNonce()
            )
            openAttempt = request
            // The server bounds the amount (balance less payments in
            // flight); this is what the card is charged.
            chargeCents = reply.chargeCents
            let intent = try await retrieveIntent(clientSecret: reply.clientSecret)
            phase = .collecting(request.mode == .tapToPay
                ? "Hold the card, phone or watch near the top of this iPhone."
                : "Tap, insert or swipe the card on the reader.")
            let collected = try await collectPaymentMethod(intent)
            phase = .processing
            let confirmed = try await confirm(collected)
            // Confirmed with Stripe: never cancel it from here on.
            openAttempt = nil
            let intentID = confirmed.stripeId ?? reply.paymentIntentID
            let settled = await PaymentService.awaitSettlement(shopID: request.shopID, paymentIntentID: intentID)
            if settled == .succeeded {
                phase = .succeeded("Payment received")
            } else if settled == .failed || settled == .cancelled {
                phase = .failed("The card payment didn't go through. Try again or use another method.")
            } else {
                phase = .succeeded("Payment submitted — it shows on the invoice once Stripe confirms it.")
            }
        } catch {
            await releaseOpenAttempt()
            if Self.isCanceled(error) {
                phase = .canceled
            } else {
                phase = .failed(Self.describe(error, fallback: "The payment couldn't be completed. Try again or use another method."))
            }
        }
        collectCancelable = nil
    }

    /// Stops the payment in progress (before the card is confirmed) or a
    /// running reader scan.
    func cancel() {
        if let pending = pendingTapDiscovery {
            pendingTapDiscovery = nil
            pending.resume(throwing: Self.canceledError())
        }
        if let cancelable = collectCancelable, !cancelable.completed {
            cancelable.cancel { _ in }
        }
        stopDiscovery()
    }

    /// Back to idle after a finished payment (the sheet shows the entry form).
    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
        chargeCents = nil
    }

    /// Releases an unconfirmed attempt on the server so it doesn't block a
    /// cash payment or a void.
    private func releaseOpenAttempt() async {
        guard let attempt = openAttempt else { return }
        openAttempt = nil
        _ = try? await PaymentService.cancelOpenPayments(shopID: attempt.shopID, invoiceID: attempt.invoiceID)
    }

    // MARK: Readers

    /// Stripe Terminal needs location access while in use (it verifies
    /// where in-person payments happen). Asks once; a refusal explains how
    /// to turn it on.
    private func ensureLocationPermission() async throws {
        #if canImport(CoreLocation)
        switch locationPermission.status {
        case .notDetermined:
            phase = .preparing("Waiting for location access…")
            guard await locationPermission.request() else {
                throw Self.message(Self.locationDeniedText)
            }
        case .denied, .restricted:
            throw Self.message(Self.locationDeniedText)
        default:
            return
        }
        #endif
    }

    private static let locationDeniedText =
        "In-person payments need location access. Allow it for Detail CRM in the iPhone Settings app (Privacy & Security › Location Services), then try again."

    /// Connects the reader the request needs, unless it is connected.
    private func ensureReader(for request: Request) async throws {
        let terminal = Terminal.shared
        if let connected = terminal.connectedReader {
            let isTapToPay = connected.deviceType == .tapToPay
            if (request.mode == .tapToPay) == isTapToPay {
                return
            }
            if request.mode == .tapToPay {
                phase = .preparing("Disconnecting the card reader…")
                try await disconnect()
            }
        }
        switch request.mode {
        case .tapToPay:
            try await ensureLocationPermission()
            phase = .preparing("Getting Tap to Pay ready…")
            let locationID = try await MoneyTerminalService.location(shopID: request.shopID)
            let reader = try await discoverTapToPayReader()
            let configuration = try TapToPayConnectionConfigurationBuilder(delegate: delegate, locationId: locationID)
                .setMerchantDisplayName(request.merchantName)
                .setTosAcceptancePermitted(true)
                .build()
            let connected = try await connect(reader, configuration: configuration)
            connectedReaderName = Self.name(of: connected)
            connectedMode = .tapToPay
        case .bluetoothReader:
            throw Self.message("Choose a card reader first.")
        }
    }

    /// Tap to Pay discovery answers once with this iPhone's reader.
    private func discoverTapToPayReader() async throws -> Reader {
        let configuration = try TapToPayDiscoveryConfigurationBuilder()
            .setSimulated(Self.usesSimulatedReaders)
            .build()
        stopDiscovery()
        return try await withCheckedThrowingContinuation { continuation in
            pendingTapDiscovery = continuation
            discoveryCancelable = Terminal.shared.discoverReaders(configuration, delegate: delegate) { [weak self] error in
                Task { @MainActor in
                    guard let self, let pending = self.pendingTapDiscovery else { return }
                    self.pendingTapDiscovery = nil
                    pending.resume(throwing: error ?? Self.message("This iPhone didn't offer Tap to Pay. Check that it's supported and try again."))
                }
            }
        }
    }

    /// Starts scanning for Bluetooth readers (MoneyReaderPickerView).
    func startBluetoothDiscovery(shopID: UUID) {
        guard AppConfig.terminalBluetoothEnabled, !isDiscovering, !phase.isBusy else { return }
        prepareSDK(shopID: shopID)
        if hasTapToPayReader {
            // Tap to Pay stays connected after a payment; the SDK looks for
            // readers only while none is connected. Tap to Pay reconnects on
            // its next payment.
            isDiscovering = true
            Task {
                do {
                    try await disconnect()
                } catch {
                    isDiscovering = false
                    phase = .failed(Self.describe(error, fallback: "Couldn't switch from Tap to Pay to a card reader. Try again."))
                    return
                }
                // The picker may have closed meanwhile (stopDiscovery).
                guard isDiscovering else { return }
                isDiscovering = false
                startBluetoothDiscovery(shopID: shopID)
            }
            return
        }
        #if canImport(CoreLocation)
        if locationPermission.status == .notDetermined {
            isDiscovering = true
            Task {
                let granted = await locationPermission.request()
                isDiscovering = false
                if granted {
                    startBluetoothDiscovery(shopID: shopID)
                } else {
                    phase = .failed(Self.locationDeniedText)
                }
            }
            return
        }
        if locationPermission.status == .denied || locationPermission.status == .restricted {
            phase = .failed(Self.locationDeniedText)
            return
        }
        #endif
        let configuration: BluetoothScanDiscoveryConfiguration
        do {
            configuration = try BluetoothScanDiscoveryConfigurationBuilder()
                .setSimulated(Self.usesSimulatedReaders)
                .setTimeout(60)
                .build()
        } catch {
            phase = .failed(Self.describe(error, fallback: "Couldn't start looking for readers."))
            return
        }
        discoveredReaders = []
        readersBySerial = [:]
        isDiscovering = true
        discoveryCancelable = Terminal.shared.discoverReaders(configuration, delegate: delegate) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isDiscovering = false
                self.discoveryCancelable = nil
                // A connected Tap to Pay reader doesn't hide scan problems.
                if let error, !Self.isCanceled(error), !self.hasBluetoothReader {
                    self.phase = .failed(Self.describe(error, fallback: "Couldn't find card readers. Make sure the reader is on and nearby."))
                }
            }
        }
    }

    /// Stops a running scan (leaving the picker).
    func stopDiscovery() {
        if let cancelable = discoveryCancelable, !cancelable.completed {
            cancelable.cancel { _ in }
        }
        discoveryCancelable = nil
        isDiscovering = false
    }

    /// Connects a reader from the scan to the shop's Terminal Location.
    func connectBluetoothReader(id: String, shopID: UUID) async {
        guard let reader = readersBySerial[id], !phase.isBusy else { return }
        prepareSDK(shopID: shopID)
        phase = .preparing("Connecting to the reader…")
        do {
            if Terminal.shared.connectedReader != nil {
                try await disconnect()
            }
            let shopLocation = try await MoneyTerminalService.location(shopID: shopID)
            // Stripe's simulated readers come with their own test location.
            let locationID = reader.simulated ? (reader.locationId ?? shopLocation) : shopLocation
            let configuration = try BluetoothConnectionConfigurationBuilder(delegate: delegate, locationId: locationID)
                .setAutoReconnectOnUnexpectedDisconnect(true)
                .build()
            let connected = try await connect(reader, configuration: configuration)
            connectedReaderName = Self.name(of: connected)
            connectedMode = .bluetoothReader
            readerUpdateAvailable = connected.availableUpdate != nil
            isDiscovering = false
            discoveryCancelable = nil
            phase = .idle
        } catch {
            phase = Self.isCanceled(error)
                ? .idle
                : .failed(Self.describe(error, fallback: "Couldn't connect to the reader. Keep it on and nearby, then try again."))
        }
    }

    /// Disconnects the connected reader (Tap to Pay or Bluetooth).
    func disconnectReader() async {
        guard !phase.isBusy else { return }
        do {
            try await disconnect()
        } catch {
            phase = .failed(Self.describe(error, fallback: "Couldn't disconnect the reader."))
        }
    }

    /// Installs a Bluetooth reader's optional software update; progress
    /// shows in `phase`.
    func installReaderUpdate() {
        guard readerUpdateAvailable, !phase.isBusy else { return }
        Terminal.shared.installAvailableUpdate()
    }

    /// The connected reader is a Bluetooth reader (not this iPhone).
    var hasBluetoothReader: Bool {
        guard connectedMode == .bluetoothReader, let reader = Terminal.shared.connectedReader else { return false }
        return reader.deviceType != .tapToPay
    }

    /// This iPhone's Tap to Pay reader is connected (it stays connected
    /// after a Tap to Pay payment; connecting a Bluetooth reader replaces
    /// it).
    var hasTapToPayReader: Bool {
        guard connectedMode == .tapToPay, let reader = Terminal.shared.connectedReader else { return false }
        return reader.deviceType == .tapToPay
    }

    // MARK: SDK calls as async

    private func connect(_ reader: Reader, configuration: ConnectionConfiguration) async throws -> Reader {
        try await withCheckedThrowingContinuation { continuation in
            Terminal.shared.connectReader(reader, connectionConfig: configuration) { connected, error in
                if let connected {
                    continuation.resume(returning: connected)
                } else {
                    continuation.resume(throwing: error ?? Self.message("Couldn't connect to the reader."))
                }
            }
        }
    }

    private func disconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Terminal.shared.disconnectReader { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        connectedReaderName = nil
        connectedMode = nil
        readerUpdateAvailable = false
    }

    private func retrieveIntent(clientSecret: String) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { intent, error in
                if let intent {
                    continuation.resume(returning: intent)
                } else {
                    continuation.resume(throwing: error ?? Self.message("Couldn't load the payment from Stripe."))
                }
            }
        }
    }

    private func collectPaymentMethod(_ intent: PaymentIntent) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            collectCancelable = Terminal.shared.collectPaymentMethod(intent) { collected, error in
                if let collected {
                    continuation.resume(returning: collected)
                } else {
                    continuation.resume(throwing: error ?? Self.message("The card wasn't read."))
                }
            }
        }
    }

    private func confirm(_ intent: PaymentIntent) async throws -> PaymentIntent {
        try await withCheckedThrowingContinuation { continuation in
            _ = Terminal.shared.confirmPaymentIntent(intent) { confirmed, error in
                if let confirmed {
                    continuation.resume(returning: confirmed)
                } else if let error {
                    continuation.resume(throwing: Self.confirmError(error))
                } else {
                    continuation.resume(throwing: Self.message("Stripe didn't confirm the payment."))
                }
            }
        }
    }

    // MARK: Delegate events (main actor)

    fileprivate func readersFound(_ readers: [Reader]) {
        if let pending = pendingTapDiscovery {
            pendingTapDiscovery = nil
            if let reader = readers.first {
                pending.resume(returning: reader)
            } else {
                pending.resume(throwing: Self.message("This iPhone didn't offer Tap to Pay. Check that it's supported and try again."))
            }
            return
        }
        guard isDiscovering else { return }
        var map: [String: Reader] = [:]
        for reader in readers {
            map[reader.serialNumber] = reader
        }
        readersBySerial = map
        discoveredReaders = readers.map { reader in
            DiscoveredReader(
                id: reader.serialNumber,
                name: Self.name(of: reader),
                batteryLevel: reader.batteryLevel?.doubleValue,
                isSimulated: reader.simulated
            )
        }
    }

    fileprivate func readerMessage(_ text: String) {
        guard case .collecting = phase else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            phase = .collecting(trimmed)
        }
    }

    fileprivate func updateStarted() {
        phase = .preparing("Updating the reader… Keep it nearby and this screen open.")
    }

    fileprivate func updateProgress(_ progress: Float) {
        let percent = Int((min(max(progress, 0), 1) * 100).rounded())
        phase = .preparing("Updating the reader… \(percent)%")
    }

    fileprivate func updateFinished(_ error: Error?) {
        readerUpdateAvailable = false
        if let error {
            phase = .failed(Self.describe(error, fallback: "The reader update didn't finish. Try again."))
        } else if case .preparing = phase, openAttempt == nil {
            phase = .idle
        }
    }

    fileprivate func updateAvailable() {
        readerUpdateAvailable = true
    }

    fileprivate func readerDisconnected() {
        connectedReaderName = nil
        connectedMode = nil
        readerUpdateAvailable = false
    }

    // MARK: Helpers

    private static func name(of reader: Reader) -> String {
        let label = reader.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = Terminal.stringFromDeviceType(reader.deviceType)
        if reader.deviceType == .tapToPay {
            return "Tap to Pay on iPhone"
        }
        if let label, !label.isEmpty {
            return "\(label) · \(type)"
        }
        return "\(type) · \(reader.serialNumber)"
    }

    /// The SDK's "canceled" (SCPErrorCanceled), or our own cancel.
    private static func isCanceled(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.code == canceledErrorCode && ns.domain != NSURLErrorDomain
    }

    private static func canceledError() -> NSError {
        NSError(domain: appErrorDomain, code: canceledErrorCode, userInfo: [NSLocalizedDescriptionKey: "Canceled."])
    }

    /// A decline or processing error from confirming: Stripe's own reason.
    private static func confirmError(_ error: ConfirmPaymentIntentError) -> Error {
        if let decline = error.declineCode, !decline.isEmpty {
            return message("The card was declined (\(decline.replacingOccurrences(of: "_", with: " "))). Try another card or method.")
        }
        return error
    }

    private static func message(_ text: String) -> NSError {
        NSError(domain: appErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Readable text for SDK and server errors.
    private static func describe(_ error: Error, fallback: String) -> String {
        if error is EdgeFunctionError || error is AppError {
            return ErrorText.message(for: error)
        }
        let text = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : ErrorText.sentence(text)
    }

    // MARK: Location permission

    #if canImport(CoreLocation)
    /// Asks for when-in-use location access and waits for the answer.
    private final class LocationPermission: NSObject, CLLocationManagerDelegate {
        private let manager = CLLocationManager()
        private var continuation: CheckedContinuation<Bool, Never>?

        override init() {
            super.init()
            manager.delegate = self
        }

        var status: CLAuthorizationStatus { manager.authorizationStatus }

        /// true when access was granted.
        func request() async -> Bool {
            await withCheckedContinuation { continuation in
                if let previous = self.continuation {
                    previous.resume(returning: false)
                }
                self.continuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            guard status != .notDetermined, let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }
    #endif

    // MARK: SDK delegate

    /// Receives the SDK's delegate calls (any thread) and forwards them to
    /// the model on the main actor.
    private final class Delegate: NSObject, DiscoveryDelegate, TapToPayReaderDelegate, MobileReaderDelegate {
        weak var model: MoneyTapToPayModel?

        private func onMain(_ work: @escaping @MainActor (MoneyTapToPayModel) -> Void) {
            Task { @MainActor [weak self] in
                guard let model = self?.model else { return }
                work(model)
            }
        }

        // DiscoveryDelegate
        func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
            onMain { $0.readersFound(readers) }
        }

        // ReaderDelegate (shared)
        func reader(_ reader: Reader, didDisconnect reason: DisconnectReason) {
            onMain { $0.readerDisconnected() }
        }

        // TapToPayReaderDelegate
        func tapToPayReader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
            onMain { $0.updateStarted() }
        }

        func tapToPayReader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
            onMain { $0.updateProgress(progress) }
        }

        func tapToPayReader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
            onMain { $0.updateFinished(error) }
        }

        func tapToPayReader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
            let text = Terminal.stringFromReaderInputOptions(inputOptions)
            onMain { $0.readerMessage(text) }
        }

        func tapToPayReader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
            let text = Terminal.stringFromReaderDisplayMessage(displayMessage)
            onMain { $0.readerMessage(text) }
        }

        // MobileReaderDelegate (Bluetooth readers)
        func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {
            onMain { $0.updateAvailable() }
        }

        func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
            onMain { $0.updateStarted() }
        }

        func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
            onMain { $0.updateProgress(progress) }
        }

        func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
            onMain { $0.updateFinished(error) }
        }

        func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
            let text = Terminal.stringFromReaderInputOptions(inputOptions)
            onMain { $0.readerMessage(text) }
        }

        func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
            let text = Terminal.stringFromReaderDisplayMessage(displayMessage)
            onMain { $0.readerMessage(text) }
        }
    }
}
