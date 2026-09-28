//
//  MoneyPDFShareButton.swift
//  DetailCRM
//
//  "Share PDF" for a quote or invoice (P-34): the `pdf` edge function
//  renders it (the customer's own page, as the server has it; drafts are
//  marked DRAFT) and the system share sheet sends, prints or saves it.
//

import SwiftUI
import UIKit
import DetailCore

struct MoneyPDFShareButton: View {
    let kind: MoneyPDFService.Kind
    let documentID: UUID
    let number: Int

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var shared: SharedFile?
    /// The last file handed to the share sheet (removed when it closes;
    /// the sheet clears `shared` before its dismiss handler runs).
    @State private var lastFile: URL?

    var body: some View {
        AsyncButton(style: .themeSecondary) {
            await prepare()
        } label: {
            Label("Share PDF", systemImage: "doc.richtext")
        }
        .accessibilityHint("Creates a PDF of this \(kind.rawValue) to send, print or save")
        .sheet(item: $shared, onDismiss: cleanUp) { file in
            ActivitySheet(items: [file.url])
                .ignoresSafeArea()
        }
    }

    /// The downloaded file being shared.
    struct SharedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private func prepare() async {
        do {
            let shopID = try appState.requireShopID()
            let url = try await MoneyPDFService.download(
                shopID: shopID,
                kind: kind,
                documentID: documentID,
                number: number
            )
            lastFile = url
            shared = SharedFile(url: url)
        } catch {
            toasts.showError(error)
        }
    }

    /// Removes the temporary copy once the share sheet is gone.
    private func cleanUp() {
        guard let url = lastFile else { return }
        lastFile = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The system share sheet (send, print, save to Files).
    struct ActivitySheet: UIViewControllerRepresentable {
        let items: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }

        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
}
