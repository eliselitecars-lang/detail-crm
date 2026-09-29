//
//  JobStorageImage.swift
//  DetailCRM
//
//  Private Storage images on the job screen — photo thumbnails, the
//  full-screen photo viewer, damage-mark photos and customer signatures —
//  shown through signed links that expire after an hour. The loader
//  (DetailCore `SignedImageLoad`) signs a link when none came with the list,
//  downloads the image, re-signs once when a link from the list fails (it
//  may have expired on a job page left open), and otherwise ends in a
//  visible failure with Retry. Nothing spins forever: a missing link and a
//  failed download each have their own message.
//
//  The full-screen viewer zooms with a UIScrollView (pinch where the
//  fingers are, double-tap to zoom in at the tap, drag to pan). While
//  zoomed, a drag pans the photo; at the photo's edge the pager takes over
//  and moves to the next one, as in Photos.
//

import SwiftUI
import UIKit
import DetailCore

/// What a `JobStorageImage` shows at the moment.
enum JobStorageImagePhase {
    case loading
    case image(UIImage)
    /// Failed; the message says why. Retry signs a fresh link.
    case failed(String)
}

/// Loads one Storage image and hands its phase to `content`.
struct JobStorageImage<Content: View>: View {
    let bucket: String
    /// Object path; nil = nothing to load (content gets `.failed`).
    let path: String?
    /// A link signed with the list, when there is one.
    let initialURL: URL?
    /// Names the thing in failure messages ("photo", "signature").
    let noun: String
    let content: (JobStorageImagePhase, _ retry: @escaping () -> Void) -> Content

    @State private var load: SignedImageLoad
    @State private var image: UIImage?

    init(
        bucket: String,
        path: String?,
        initialURL: URL?,
        noun: String,
        @ViewBuilder content: @escaping (JobStorageImagePhase, _ retry: @escaping () -> Void) -> Content
    ) {
        self.bucket = bucket
        self.path = path
        self.initialURL = initialURL
        self.noun = noun
        self.content = content
        _load = State(initialValue: SignedImageLoad(initialURL: initialURL))
    }

    var body: some View {
        content(phase, retry)
            .task(id: JobStorageImageTaskKey(path: path, work: load.work)) {
                await perform()
            }
            .onChange(of: initialURL) { _, newURL in
                load.adopt(newURL)
            }
            .onChange(of: path) { _, _ in
                image = nil
                load.retry()
            }
    }

    private var phase: JobStorageImagePhase {
        if path == nil {
            return .failed("This \(noun) is missing.")
        }
        switch load.state {
        case .loaded:
            if let image { return .image(image) }
            return .loading
        case .failed(let failure):
            return .failed(SignedImageLoad.message(for: failure, noun: noun))
        case .fetching:
            return .loading
        }
    }

    private func retry() {
        image = nil
        load.retry()
    }

    /// One step of the current work: sign a link, or download the image.
    private func perform() async {
        guard let path, let work = load.work else { return }
        if let url = work.url {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                guard !Task.isCancelled else { return }
                image = decoded
                load.imageLoaded(attempt: work.attempt)
            } catch {
                if Self.isCancellation(error) { return }
                load.imageFailed(attempt: work.attempt)
            }
        } else {
            do {
                let url = try await JobOpsService.signedURL(bucket: bucket, path: path)
                guard !Task.isCancelled else { return }
                load.signed(url, attempt: work.attempt)
            } catch {
                if Self.isCancellation(error) { return }
                load.signingFailed(attempt: work.attempt)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

/// Restarts the load task when the object or the work changes.
private struct JobStorageImageTaskKey: Hashable {
    let path: String?
    let work: SignedImageLoad.Work?
}

// MARK: - Uses

/// A small square-ish image (thumbnails, damage-mark photos): a muted tile
/// while loading, a warning tile when it failed (tap the parent to open it
/// or pull to refresh).
struct JobStorageImageTile: View {
    let phase: JobStorageImagePhase

    var body: some View {
        switch phase {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .loading:
            ZStack {
                Theme.surfaceMuted
                ProgressView()
                    .tint(Theme.textTertiary)
            }
        case .failed:
            ZStack {
                Theme.surfaceMuted
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warningInk)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A photo that fits the screen and zooms: pinch where the fingers are,
/// double-tap to zoom in at the tap (again to zoom out), drag to pan.
struct JobZoomablePhoto: View {
    let item: JobPhotoItem

    var body: some View {
        JobStorageImage(
            bucket: JobOpsService.photosBucket,
            path: item.photo.storagePath,
            initialURL: item.url,
            noun: "photo"
        ) { phase, retry in
            switch phase {
            case .image(let image):
                JobZoomableImageView(image: image)
                    .accessibilityLabel("\(item.photo.kind.displayName) photo")
                    .accessibilityHint("Pinch or double-tap to zoom. Drag to move around when zoomed.")
            case .loading:
                LoadingStateView(label: "Loading photo…")
            case .failed(let message):
                ErrorStateView(message: message) { retry() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// UIScrollView zoom inside the pager: native pinch (anchored at the
/// pinch), pan while zoomed, and the pager's swipe once the photo's edge
/// is reached.
struct JobZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> JobZoomScrollView {
        let view = JobZoomScrollView()
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: JobZoomScrollView, context: Context) {
        view.setImage(image)
    }
}

final class JobZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = ZoomGeometry.maximumScale
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            // First layout, a new photo or rotation: fit it again.
            laidOutSize = bounds.size
            zoomScale = minimumZoomScale
            let fitted = ZoomGeometry.fittedSize(image: image.size, in: bounds.size)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    /// Keeps a photo smaller than the screen centred.
    private func centerContent() {
        let insets = ZoomGeometry.centeringInsets(content: contentSize, in: bounds.size)
        contentInset = UIEdgeInsets(
            top: insets.vertical,
            left: insets.horizontal,
            bottom: insets.vertical,
            right: insets.horizontal
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let rect = ZoomGeometry.zoomRect(
            around: point,
            scale: ZoomGeometry.doubleTapScale,
            viewSize: bounds.size,
            content: imageView.bounds.size
        )
        zoom(to: rect, animated: true)
    }
}
