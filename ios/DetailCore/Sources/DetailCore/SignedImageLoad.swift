//
//  SignedImageLoad.swift
//  DetailCore
//
//  Job photos, damage photos and signatures are private Storage objects
//  shown through signed links that expire (an hour). Loading one has two
//  steps that can each fail: getting a signed link, then downloading the
//  image. Every failure has to end in a visible error with a Retry — a
//  missing link must not look like "still loading" forever.
//
//  A link handed in from outside (signed when the list loaded) may have
//  expired by the time the image is shown, e.g. on a job page left open
//  during a long coating job, so the first download failure of such a link
//  gets one fresh link automatically. A link this loader signed itself is
//  not re-signed again: its failure is shown with Retry.
//

import Foundation
// CGSize/CGPoint/CGRect members (.zero, CGRect(x:y:width:height:)) live in the
// CoreGraphics overlay on Apple platforms; Linux Foundation defines them itself.
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct SignedImageLoad: Equatable, Sendable {

    public enum Failure: Equatable, Sendable {
        /// No signed link could be made (offline, file missing, no access).
        case noLink
        /// The link was made but the image didn't download or decode.
        case imageUnavailable
    }

    public enum State: Equatable, Sendable {
        /// Signing a link (`url == nil`) or downloading the image from `url`.
        case fetching(url: URL?)
        case loaded
        case failed(Failure)
    }

    /// One unit of work for the screen: sign a link, or download `url`.
    /// Changes whenever the work does, so it can drive `.task(id:)`.
    public struct Work: Hashable, Sendable {
        public let attempt: Int
        public let url: URL?
    }

    public private(set) var state: State
    /// Bumped on every new try; results of an older try are ignored.
    public private(set) var attempt: Int
    /// The current link was signed by this loader (not handed in).
    public private(set) var linkIsFresh: Bool

    /// Starts from a link signed earlier, or by signing one.
    public init(initialURL: URL?) {
        state = .fetching(url: initialURL)
        attempt = 0
        linkIsFresh = false
    }

    /// What the screen should do now (nil once loaded or failed).
    public var work: Work? {
        if case .fetching(let url) = state { return Work(attempt: attempt, url: url) }
        return nil
    }

    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// A link was signed for `attempt`.
    public mutating func signed(_ url: URL, attempt: Int) {
        guard attempt == self.attempt, case .fetching(url: .none) = state else { return }
        linkIsFresh = true
        state = .fetching(url: url)
    }

    /// Signing failed for `attempt`.
    public mutating func signingFailed(attempt: Int) {
        guard attempt == self.attempt, case .fetching(url: .none) = state else { return }
        state = .failed(.noLink)
    }

    /// The image of `attempt` is on screen.
    public mutating func imageLoaded(attempt: Int) {
        guard attempt == self.attempt, case .fetching(url: .some) = state else { return }
        state = .loaded
    }

    /// The image of `attempt` failed to download or decode. A handed-in
    /// link (possibly expired) is re-signed once; otherwise it's a failure.
    public mutating func imageFailed(attempt: Int) {
        guard attempt == self.attempt, case .fetching(url: .some) = state else { return }
        if linkIsFresh {
            state = .failed(.imageUnavailable)
        } else {
            self.attempt += 1
            state = .fetching(url: nil)
        }
    }

    /// Retry: a fresh link, then the image.
    public mutating func retry() {
        attempt += 1
        linkIsFresh = false
        state = .fetching(url: nil)
    }

    /// A newer link arrived from outside (the list was reloaded). Adopted
    /// unless the image is already on screen.
    public mutating func adopt(_ url: URL?) {
        guard let url, state != .loaded else { return }
        if state == .fetching(url: url) { return }
        attempt += 1
        linkIsFresh = false
        state = .fetching(url: url)
    }

    /// Text for a failure, naming the thing shown ("photo", "signature").
    public static func message(for failure: Failure, noun: String) -> String {
        switch failure {
        case .noLink:
            return "This \(noun) couldn't be opened. Check your connection and try again."
        case .imageUnavailable:
            return "This \(noun) couldn't be loaded. Try again, or pull to refresh the job."
        }
    }
}

/// Geometry of the zoomable photo viewer (pinch, double-tap and pan).
public enum ZoomGeometry {

    /// Largest zoom the viewer allows.
    public static let maximumScale: CGFloat = 5
    /// Zoom a double-tap goes to.
    public static let doubleTapScale: CGFloat = 2.5

    /// The size an image of `image` points takes when fitted inside
    /// `bounds` without cropping (aspect fit). Zero for empty sizes.
    public static func fittedSize(image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let ratio = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * ratio, height: image.height * ratio)
    }

    /// Insets that centre content of `content` size in `bounds` while it is
    /// smaller than the view (0 on an axis where it is larger).
    public static func centeringInsets(content: CGSize, in bounds: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(0, (bounds.width - content.width) / 2), max(0, (bounds.height - content.height) / 2))
    }

    /// The rectangle (in the unzoomed image's coordinates) to zoom to so
    /// that `point` ends up centred at `scale`, kept inside `content`.
    public static func zoomRect(around point: CGPoint, scale: CGFloat, viewSize: CGSize, content: CGSize) -> CGRect {
        guard scale > 0 else { return CGRect(origin: .zero, size: content) }
        let width = min(viewSize.width / scale, content.width)
        let height = min(viewSize.height / scale, content.height)
        let x = min(max(point.x - width / 2, 0), max(0, content.width - width))
        let y = min(max(point.y - height / 2, 0), max(0, content.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
