//
//  MediaPickers.swift
//  DetailCRM
//
//  Photo library picking (PhotosPicker), camera capture
//  (UIImagePickerController) and JPEG preparation for Storage uploads.
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Image preparation

enum ImageCompression {

    /// Downscales so the longest side is at most `maxDimension` pixels and
    /// encodes as JPEG. Orientation is baked in. Returns nil for data that
    /// is not an image.
    static func jpegData(from data: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(from: image, maxDimension: maxDimension, quality: quality)
    }

    static func jpegData(from image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }
        let factor = min(1, maxDimension / longest)
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Photo library

/// A button that opens the system photo picker and returns prepared JPEG
/// data for each chosen image. Images that fail to load are skipped and
/// counted in `failedCount`.
struct PhotoPickerButton<Label: View>: View {
    let maxSelection: Int
    let onPicked: (_ images: [Data], _ failedCount: Int) -> Void
    let label: Label

    @State private var items: [PhotosPickerItem] = []
    @State private var isLoading = false

    init(
        maxSelection: Int = 10,
        onPicked: @escaping (_ images: [Data], _ failedCount: Int) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.maxSelection = maxSelection
        self.onPicked = onPicked
        self.label = label()
    }

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: maxSelection, matching: .images) {
            ZStack {
                label.opacity(isLoading ? 0.3 : 1)
                ProgressView().opacity(isLoading ? 1 : 0)
            }
        }
        .disabled(isLoading)
        .onChange(of: items) { _, newItems in
            guard !newItems.isEmpty else { return }
            isLoading = true
            Task { @MainActor in
                var images: [Data] = []
                var failed = 0
                for item in newItems {
                    if let raw = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImageCompression.jpegData(from: raw) {
                        images.append(jpeg)
                    } else {
                        failed += 1
                    }
                }
                items = []
                isLoading = false
                onPicked(images, failed)
            }
        }
    }
}

// MARK: - Camera

/// Full-screen camera capture. Present with
/// `.fullScreenCover(isPresented:) { CameraPicker { image in … }.ignoresSafeArea() }`
/// and only when `CameraPicker.isAvailable`.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
