//
//  JobsVINScannerView.swift
//  DetailCRM
//
//  VIN scanning (P-22) with VisionKit's live data scanner: door-jamb and
//  windshield barcodes (Code 39 / Code 128 / Data Matrix / QR) and printed
//  text. Candidates are read with DetailCore `VIN.candidates(in:)`; one
//  whose check digit matches is accepted at once, anything else is shown
//  for the user to confirm (many non-North-American VINs have no check
//  digit). Present it in a sheet; it closes itself after a result.
//
//  The first time it opens, the camera permission is asked for
//  (VisionKit's `isAvailable` stays false until access is granted, so the
//  scanner itself would never trigger the prompt). Devices without the
//  scanner (older phones, the simulator) or without camera access get a
//  clear message and fall back to typing the VIN.
//
//  Shared component: the new-job flow (jobs) and the vehicle editor (ops)
//  both present it.
//

import SwiftUI
import UIKit
import AVFoundation
import Vision
import VisionKit
import DetailCore

/// A VIN read by the scanner.
struct JobsVINScanResult: Hashable, Sendable {
    /// Normalised 17-character VIN.
    var vin: String
    /// The North American check digit matched (otherwise the user
    /// confirmed the reading).
    var checkDigitVerified: Bool

    var modelYear: Int? { VIN.modelYear(vin) }
}

struct JobsVINScannerView: View {
    /// Called once with the accepted VIN, just before the sheet closes.
    let onScan: (JobsVINScanResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var torchOn = false
    @State private var unconfirmed: String?
    @State private var unavailableReason: String?
    @State private var finished = false
    /// Camera permission; re-read after the first-use prompt answers.
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan VIN")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            torchOn.toggle()
                            JobsVINScannerView.setTorch(torchOn)
                        } label: {
                            Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                        .accessibilityLabel(torchOn ? "Turn light off" : "Turn light on")
                        .disabled(cameraAccess != .authorized || !JobsVINScannerView.isScannerReady || !JobsVINScannerView.hasTorch)
                    }
                }
        }
        .onDisappear {
            if torchOn { JobsVINScannerView.setTorch(false) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if cameraAccess == .notDetermined && DataScannerViewController.isSupported {
            ProgressView("Waiting for camera access…")
                .tint(Theme.glacier)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenBackground()
                .task { await requestCameraAccess() }
        } else if let reason = unavailableReason ?? JobsVINScannerView.unavailableMessage(cameraAccess: cameraAccess) {
            unavailableView(reason)
        } else {
            ZStack(alignment: .bottom) {
                Scanner(
                    isPaused: unconfirmed != nil || finished,
                    onCandidates: handle,
                    onUnavailable: { message in unavailableReason = message }
                )
                .ignoresSafeArea(edges: .bottom)
                .accessibilityLabel("Camera view. Point it at the VIN barcode or the printed VIN.")

                VStack(spacing: Theme.Spacing.md) {
                    if let vin = unconfirmed {
                        confirmCard(vin)
                    } else {
                        Text("Point the camera at the VIN barcode on the door jamb or the VIN under the windshield.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.onAccent)
                            .multilineTextAlignment(.center)
                            .padding(Theme.Spacing.md)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.scrim.opacity(0.6)))
                    }
                }
                .padding(Theme.Spacing.gutter)
            }
        }
    }

    private func confirmCard(_ vin: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Is this the VIN?")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(vin)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel(vin.map(String.init).joined(separator: " "))
            Text("Its check digit doesn't match, which is normal for some vehicles built outside North America. Compare it with the vehicle before using it.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.sm) {
                Button("Keep scanning") { unconfirmed = nil }
                    .buttonStyle(.themeSecondaryCompact)
                Button("Use this VIN") { finish(vin, verified: false) }
                    .buttonStyle(.themePrimaryCompact)
            }
        }
        .cardStyle()
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            EmptyStateView(
                systemImage: "barcode.viewfinder",
                title: "Scanning isn't available",
                message: reason
            )
            if cameraAccess == .denied,
               let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
                    .buttonStyle(.themeSecondaryCompact)
            }
            Button("Type the VIN instead") { dismiss() }
                .buttonStyle(.themePrimaryCompact)
                .padding(.bottom, Theme.Spacing.xl)
        }
        .screenBackground()
    }

    // MARK: - Results

    private func handle(_ candidates: [String]) {
        guard !finished, unconfirmed == nil, let best = candidates.first else { return }
        if VIN.isValid(best, requireCheckDigit: true) {
            finish(best, verified: true)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            unconfirmed = best
        }
    }

    private func finish(_ vin: String, verified: Bool) {
        guard !finished else { return }
        finished = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan(JobsVINScanResult(vin: vin, checkDigitVerified: verified))
        dismiss()
    }

    // MARK: - Device support

    /// Shows the system camera prompt (first use only), then re-reads the
    /// permission so the scanner or the "no access" message appears.
    @MainActor
    private func requestCameraAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Whether this device can run the live scanner right now.
    @MainActor
    static var isScannerReady: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Why scanning can't start, or nil when it can. Called once the
    /// camera permission has been asked for (`notDetermined` is handled by
    /// the prompt first).
    @MainActor
    static func unavailableMessage(cameraAccess: AVAuthorizationStatus) -> String? {
        if !DataScannerViewController.isSupported {
            return "This iPhone can't scan VINs with the camera. Type the VIN instead."
        }
        if cameraAccess == .denied || cameraAccess == .restricted {
            return "Detail CRM doesn't have access to the camera. Allow it in Settings, or type the VIN instead."
        }
        if !DataScannerViewController.isAvailable {
            return "The camera is busy or not allowed right now. Type the VIN instead."
        }
        return nil
    }

    @MainActor
    static var hasTorch: Bool {
        AVCaptureDevice.default(for: .video)?.hasTorch ?? false
    }

    @MainActor
    static func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            // The light is a convenience; scanning works without it.
        }
    }

    // MARK: - VisionKit bridge

    /// The live camera scanner (DataScannerViewController).
    private struct Scanner: UIViewControllerRepresentable {
        let isPaused: Bool
        let onCandidates: ([String]) -> Void
        let onUnavailable: (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onCandidates: onCandidates, onUnavailable: onUnavailable)
        }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [
                    .barcode(symbologies: [.code39, .code128, .dataMatrix, .qr]),
                    .text(),
                ],
                qualityLevel: .accurate,
                recognizesMultipleItems: true,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
            context.coordinator.onCandidates = onCandidates
            context.coordinator.onUnavailable = onUnavailable
            if isPaused {
                if scanner.isScanning { scanner.stopScanning() }
            } else if !scanner.isScanning {
                do {
                    try scanner.startScanning()
                } catch {
                    onUnavailable("The camera couldn't start. Type the VIN instead.")
                }
            }
        }

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
            scanner.stopScanning()
        }

        @MainActor
        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            var onCandidates: ([String]) -> Void
            var onUnavailable: (String) -> Void

            init(onCandidates: @escaping ([String]) -> Void, onUnavailable: @escaping (String) -> Void) {
                self.onCandidates = onCandidates
                self.onUnavailable = onUnavailable
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                report(allItems)
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                didUpdate updatedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                report(allItems)
            }

            func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
                report([item])
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
            ) {
                onUnavailable("The camera stopped. Close this screen and try again, or type the VIN instead.")
            }

            /// Barcodes first (exact payloads), then printed text; verified
            /// VINs first within the whole set.
            private func report(_ items: [RecognizedItem]) {
                var barcodeCandidates: [String] = []
                var textCandidates: [String] = []
                for item in items {
                    switch item {
                    case .barcode(let barcode):
                        if let payload = barcode.payloadStringValue {
                            barcodeCandidates += VIN.candidates(in: payload)
                        }
                    case .text(let text):
                        textCandidates += VIN.candidates(in: text.transcript)
                    @unknown default:
                        continue
                    }
                }
                var all: [String] = []
                for candidate in barcodeCandidates + textCandidates where !all.contains(candidate) {
                    all.append(candidate)
                }
                let verified = all.filter { VIN.isValid($0, requireCheckDigit: true) }
                let ordered = verified + all.filter { !verified.contains($0) }
                if !ordered.isEmpty { onCandidates(ordered) }
            }
        }
    }
}
