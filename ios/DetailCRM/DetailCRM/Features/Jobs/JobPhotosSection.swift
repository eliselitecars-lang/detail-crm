//
//  JobPhotosSection.swift
//  DetailCRM
//
//  Before / after photos: library picker and camera (JPEG, 0.8 quality,
//  longest side 2048 px via ImageCompression), a thumbnail grid from
//  signed URLs, and a full-screen pager. Uploaders delete their own
//  photos; managers delete any.
//
//  Videos (P-30): staff on the job record walkaround videos (up to two
//  minutes, medium quality) that upload with the resumable protocol, with
//  a poster frame for the grid; an interrupted upload stays listed with
//  Resume, "Save or share video" and a confirmed Discard (the camera
//  recorder doesn't save to Photos, so it is the only copy). Photos and videos can be marked "visible to the customer" for
//  the job report (P-8).
//

import SwiftUI
import UIKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import DetailCore

/// Opens the full-screen viewer at a photo.
struct JobPhotoViewerRequest: Identifiable, Hashable {
    let id: UUID
}

struct JobPhotosSection: View {
    let model: JobDetailModel
    let permissions: JobDetailPermissions

    @Environment(ToastCenter.self) private var toasts
    @State private var uploadKind: JobPhotoKind = .before
    @State private var isUploading = false
    @State private var showingCamera = false
    @State private var showingVideoRecorder = false
    @State private var isPreparingVideo = false
    @State private var viewer: JobPhotoViewerRequest?
    @State private var confirmation: ConfirmationRequest?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]

    var body: some View {
        JobSectionCard("Photos") {
            JobSectionStateView(model.photos, loadingLabel: "Loading photos…", retry: { await model.loadPhotos() }) { items in
                grid(items)
            }
            if !model.pendingUploads.isEmpty {
                pendingUploadsView
            }
            if permissions.canWork {
                uploadControls
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                captured(image)
            }
            .ignoresSafeArea()
        }
        .task(id: model.pendingUploads.map(\.id)) { await resumePausedUploads() }
        .fullScreenCover(isPresented: $showingVideoRecorder) {
            VideoRecorder { url in
                recorded(url)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewer) { request in
            JobPhotoViewer(
                model: model,
                startID: request.id,
                permissions: permissions
            )
        }
        .confirmation($confirmation)
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ items: [JobPhotoItem]) -> some View {
        if items.isEmpty {
            JobEmptyLine(text: "No photos yet.", systemImage: "photo.on.rectangle")
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(items) { item in
                    Button {
                        viewer = JobPhotoViewerRequest(id: item.id)
                    } label: {
                        JobPhotoThumbnail(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(thumbnailLabel(item))
                    .accessibilityHint(item.photo.isVideo ? "Plays the video" : "Opens the photo full screen")
                }
            }
        }
    }

    private func thumbnailLabel(_ item: JobPhotoItem) -> String {
        var text = "\(item.photo.kind.displayName) \(item.photo.isVideo ? "video" : "photo")"
        if let duration = item.photo.durationText { text += ", \(duration)" }
        if item.photo.isCustomerVisible { text += ", visible to the customer" }
        return text
    }

    // MARK: - Pending video uploads

    private var pendingUploadsView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(model.pendingUploads) { upload in
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "video.badge.ellipsis")
                        .foregroundStyle(Theme.glacier)
                        .accessibilityHidden(true)
                    if let fraction = model.uploadProgress[upload.id] {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Uploading video… \(Int(fraction * 100))%")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.textSecondary)
                            ProgressView(value: fraction)
                                .tint(Theme.glacier)
                        }
                    } else {
                        Text("Video upload paused (\(ByteCountFormatter.string(fromByteCount: Int64(upload.size), countStyle: .file)))")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Button("Resume") { resume(upload) }
                            .buttonStyle(.themeSecondaryCompact)
                        Menu {
                            // The only copy until it uploads (the camera
                            // doesn't save to Photos): the share sheet's
                            // Save Video keeps one in Photos.
                            ShareLink(item: JobsResumableUploader.localURL(for: upload)) {
                                Label("Save or share video", systemImage: "square.and.arrow.up")
                            }
                            Button("Discard this video", role: .destructive) { confirmDiscard(upload) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .iconTapTarget()
                        }
                        .accessibilityLabel("More for this upload")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Discarding deletes the only copy of the recording, so it asks first
    /// (as deleting an uploaded photo does).
    private func confirmDiscard(_ upload: JobsResumableUploader.Upload) {
        let prompt = UnsentVideoWarning.discard
        confirmation = ConfirmationRequest(
            title: prompt.title,
            message: prompt.message,
            confirmTitle: prompt.confirmTitle,
            isDestructive: true
        ) {
            model.discardUpload(upload)
            toasts.show("Video discarded")
        }
    }

    private func resume(_ upload: JobsResumableUploader.Upload) {
        Task {
            await JobPhotosSection.withBackgroundTime {
                do {
                    try await model.finishUpload(upload)
                    toasts.show("Video added")
                } catch {
                    toasts.showError(error)
                }
            }
        }
    }

    /// Paused uploads continue by themselves when the job opens again.
    private func resumePausedUploads() async {
        for upload in model.pendingUploads where model.uploadProgress[upload.id] == nil {
            await JobPhotosSection.withBackgroundTime {
                try? await model.finishUpload(upload)
            }
        }
    }

    static func withBackgroundTimeThrowing(_ work: () async throws -> Void) async throws {
        let task = UIApplication.shared.beginBackgroundTask(withName: "job-video-upload")
        defer {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        try await work()
    }

    /// Asks iOS for extra time so an upload survives a short trip to the
    /// background; if it still stops, the upload resumes later.
    static func withBackgroundTime(_ work: () async -> Void) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "job-video-upload")
        await work()
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: - Upload

    private var uploadControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Photo type", selection: $uploadKind) {
                ForEach(JobPhotoKind.uploadChoices) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                PhotoPickerButton(maxSelection: 10, onPicked: { images, failed in
                    picked(images, failed: failed)
                }) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                        .font(Theme.Typography.buttonCompact)
                        .foregroundStyle(Theme.glacier)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.compactControlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
                        )
                }
                .accessibilityLabel("Add photos from the library")
                if CameraPicker.isAvailable {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themeSecondaryCompact)
                    .accessibilityLabel("Take a photo")
                }
                if VideoRecorder.isAvailable {
                    Button {
                        showingVideoRecorder = true
                    } label: {
                        Label("Video", systemImage: "video")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themeSecondaryCompact)
                    .accessibilityLabel("Record a video, up to two minutes")
                }
            }
            .disabled(isUploading || isPreparingVideo)
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .tint(Theme.glacier)
                Text("Uploading…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .opacity(isUploading ? 1 : 0)
            .accessibilityHidden(!isUploading)
        }
    }

    private func picked(_ images: [Data], failed: Int) {
        if images.isEmpty {
            if failed > 0 { toasts.show("Those photos couldn't be read.", style: .error) }
            return
        }
        upload(images, unreadable: failed)
    }

    private func captured(_ image: UIImage) {
        guard let data = ImageCompression.jpegData(from: image) else {
            toasts.show("That photo couldn't be prepared.", style: .error)
            return
        }
        upload([data], unreadable: 0)
    }

    /// A recorded video: poster frame + length, then the resumable upload.
    private func recorded(_ url: URL) {
        let kind = uploadKind
        isPreparingVideo = true
        Task {
            defer { isPreparingVideo = false }
            let asset = AVURLAsset(url: url)
            var seconds = 1
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                seconds = max(1, Int(duration.seconds.rounded()))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            var poster: Data?
            if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                poster = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.8)
            }
            do {
                try await JobPhotosSection.withBackgroundTimeThrowing {
                    try await model.uploadVideo(fileURL: url, durationSeconds: seconds, posterJPEG: poster, kind: kind)
                }
                toasts.show("Video added")
            } catch {
                model.refreshPendingUploads()
                toasts.show(
                    ErrorText.message(for: error) + " The video is kept on this iPhone: tap Resume to try again.",
                    style: .error,
                    duration: .seconds(8)
                )
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func upload(_ images: [Data], unreadable: Int) {
        let kind = uploadKind
        isUploading = true
        Task {
            do {
                let failures = try await model.uploadPhotos(images, kind: kind) + unreadable
                if failures > 0 {
                    toasts.show("\(failures) photo(s) couldn't be uploaded.", style: .error)
                } else {
                    toasts.show(images.count == 1 ? "Photo added" : "\(images.count) photos added")
                }
            } catch {
                toasts.showError(error)
            }
            isUploading = false
        }
    }
}

/// Square thumbnail with the kind badge.
struct JobPhotoThumbnail: View {
    let item: JobPhotoItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder(systemImage: "exclamationmark.triangle")
                    case .empty:
                        placeholder(systemImage: "photo")
                    @unknown default:
                        placeholder(systemImage: "photo")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                if item.photo.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.onAccent)
                        .shadow(radius: 2)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Theme.Spacing.xxs) {
                    if let duration = item.photo.durationText {
                        Text(duration)
                            .font(Theme.Typography.eyebrow.monospacedDigit())
                    }
                    if item.photo.isCustomerVisible {
                        Image(systemName: "eye")
                            .font(Theme.Typography.eyebrow)
                    }
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, Theme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .fill(Theme.scrim.opacity(0.65))
                )
                .padding(Theme.Spacing.xs)
                .opacity(item.photo.isVideo || item.photo.isCustomerVisible ? 1 : 0)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.photo.kind.displayName)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.7))
                    )
                    .padding(Theme.Spacing.xs)
            }
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Theme.surfaceMuted
            Image(systemName: systemImage)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Full-screen pager over the job's photos with delete for permitted users.
struct JobPhotoViewer: View {
    let model: JobDetailModel
    let startID: UUID
    let permissions: JobDetailPermissions

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var selection: UUID
    @State private var confirmation: ConfirmationRequest?
    @State private var errorMessage: String?

    init(model: JobDetailModel, startID: UUID, permissions: JobDetailPermissions) {
        self.model = model
        self.startID = startID
        self.permissions = permissions
        _selection = State(initialValue: startID)
    }

    private var items: [JobPhotoItem] { model.photos.value ?? [] }

    private var current: JobPhotoItem? {
        items.first { $0.id == selection }
    }

    private var viewerTitle: String {
        guard let current else { return "Photo" }
        let kind = current.photo.kind.displayName
        let base = current.photo.isVideo ? kind + " video" : kind
        return current.photo.isCustomerVisible ? base + " · visible to customer" : base
    }

    var body: some View {
        NavigationStack {
            pager
                .overlay(alignment: .bottom) { errorBanner }
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle(viewerTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .confirmation($confirmation)
        }
    }

    @ViewBuilder
    private var pager: some View {
        if items.isEmpty {
            EmptyStateView(systemImage: "photo", title: "No photos", message: "This photo was removed.")
        } else {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    Group {
                        if item.photo.isVideo {
                            JobPhotosSection.VideoPlayerPage(photo: item.photo)
                        } else {
                            JobZoomablePhoto(url: item.url)
                        }
                    }
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            InlineMessage(text: errorMessage, kind: .error)
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .padding(Theme.Spacing.lg)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .secondaryAction) {
            if let current, permissions.canWork {
                Button {
                    toggleVisibility(current.photo)
                } label: {
                    Label(current.photo.isCustomerVisible ? "Hide from customer" : "Show to customer",
                          systemImage: current.photo.isCustomerVisible ? "eye.slash" : "eye")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if let current, permissions.canDelete(current.photo) {
                Button(role: .destructive) {
                    confirmDelete(current.photo)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete photo")
            }
        }
    }

    private func toggleVisibility(_ photo: JobPhoto) {
        let visible = !photo.isCustomerVisible
        Task {
            do {
                errorMessage = nil
                try await model.setPhotosVisible([photo.id], visible: visible)
                toasts.show(visible ? "Shown on the customer's job report" : "Hidden from the customer")
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func confirmDelete(_ photo: JobPhoto) {
        confirmation = ConfirmationRequest(
            title: "Delete this photo?",
            message: "It will be removed from the job for everyone.",
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                errorMessage = nil
                let remaining = items.filter { $0.id != photo.id }
                try await model.deletePhoto(photo)
                if let next = remaining.first {
                    selection = next.id
                } else {
                    dismiss()
                }
                toasts.show("Photo deleted")
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// A photo that fits the screen and zooms with a pinch (double-tap resets).
struct JobZoomablePhoto: View {
    let url: URL?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(magnification)
                    .onTapGesture(count: 2) {
                        withAnimation(Theme.Motion.standard) {
                            scale = 1
                            lastScale = 1
                        }
                    }
                    .accessibilityLabel("Job photo")
            case .failure:
                ErrorStateView(message: "This photo couldn't be loaded.")
            case .empty:
                LoadingStateView(label: "Loading photo…")
            @unknown default:
                LoadingStateView(label: "Loading photo…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }
}

extension JobPhotosSection {
    /// Plays a job video from a short-lived signed link.
    struct VideoPlayerPage: View {
        let photo: JobPhoto

        @State private var player: AVPlayer?
        @State private var errorMessage: String?

        var body: some View {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel("Job video")
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { await prepare() }
                } else {
                    LoadingStateView(label: "Loading video…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await prepare() }
            .onDisappear { player?.pause() }
        }

        private func prepare() async {
            errorMessage = nil
            do {
                let url = try await JobOpsService.videoURL(photo)
                player = AVPlayer(url: url)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

extension JobPhotosSection {
    /// Records a video with the camera (UIImagePickerController, movie mode,
    /// up to 2 minutes, medium quality). Hands back the file URL.
    struct VideoRecorder: UIViewControllerRepresentable {
        let onRecorded: (URL) -> Void

        @Environment(\.dismiss) private var dismiss

        static var isAvailable: Bool {
            UIImagePickerController.isSourceTypeAvailable(.camera)
                && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(onRecorded: onRecorded, onFinish: { dismiss() })
        }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoMaximumDuration = 120
            picker.videoQuality = .typeMedium
            picker.allowsEditing = false
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            private let onRecorded: (URL) -> Void
            private let onFinish: () -> Void

            init(onRecorded: @escaping (URL) -> Void, onFinish: @escaping () -> Void) {
                self.onRecorded = onRecorded
                self.onFinish = onFinish
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                // The picker deletes its file when dismissed: keep a copy.
                if let source = info[.mediaURL] as? URL {
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension))
                    if (try? FileManager.default.copyItem(at: source, to: copy)) != nil {
                        onRecorded(copy)
                    }
                }
                onFinish()
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                onFinish()
            }
        }
    }
}
