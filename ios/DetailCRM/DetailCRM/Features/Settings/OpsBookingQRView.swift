//
//  OpsBookingQRView.swift
//  DetailCRM
//
//  The shop's online booking link and a QR code for it (P-10): print it on
//  a counter card or a vehicle sticker, or share the image and the link.
//  The QR is made on the phone with Core Image (no network) and scaled up
//  without smoothing so it stays sharp. Putting the booking page on the
//  shop's own website (embed code, Meta Pixel / Google Analytics) is set up
//  in the web app.
//

import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DetailCore

struct OpsBookingQRView: View {
    let shopName: String
    let slug: String
    /// Whether online booking is on (nil = unknown).
    let bookingEnabled: Bool?

    @Environment(ToastCenter.self) private var toasts
    @State private var image: UIImage?

    /// `WEB_APP_URL` + `/book/<slug>`, when configured.
    private var bookingURL: URL? {
        Self.bookingURL(slug: slug)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if bookingEnabled == false {
                    InlineMessage(
                        text: "Online booking is off, so this page can't take bookings yet. Turn it on in Settings first.",
                        kind: .info
                    )
                }
                if let bookingURL {
                    codeCard(url: bookingURL)
                    linkCard(url: bookingURL)
                } else {
                    InlineMessage(
                        text: "The web app address isn't set in this build (WEB_APP_URL), so the booking link can't be shown here. Open Settings in the web app to copy it.",
                        kind: .error
                    )
                }
                Text("To add booking to your own website (an embedded booking page) or to track visits with Meta Pixel or Google Analytics, use the online booking settings in the web app.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Booking link")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: bookingURL) {
            if let bookingURL {
                image = Self.qrImage(for: bookingURL.absoluteString)
            }
        }
    }

    @ViewBuilder
    private func codeCard(url: URL) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .accessibilityLabel("QR code for the booking page of \(shopName)")
                ShareLink(
                    item: Image(uiImage: image),
                    preview: SharePreview("Book with \(shopName)", image: Image(uiImage: image))
                ) {
                    Label("Share QR code", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themePrimary)
            } else {
                ProgressView()
                    .frame(width: 260, height: 260)
                    .accessibilityLabel("Making the QR code")
            }
            Text("Customers scan it with the phone camera to open your booking page.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func linkCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Link")
            Text(url.absoluteString)
                .font(Theme.Typography.body.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.sm) {
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
                Button {
                    UIPasteboard.general.url = url
                    toasts.show("Booking link copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
            }
            Link(destination: url) {
                Label("Open the booking page", systemImage: "safari")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.glacier)
            }
        }
        .cardStyle()
    }

    // MARK: - Helpers

    /// The public booking page of a shop (`/book/<slug>` on the web app).
    static func bookingURL(slug: String) -> URL? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return ShopSettingsWebLinks.webURL(path: "/book/" + trimmed)
    }

    /// A black-on-white QR code for `text`, scaled to about 1024 px with
    /// whole-pixel modules (no smoothing). Medium error correction.
    static func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (1024 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
