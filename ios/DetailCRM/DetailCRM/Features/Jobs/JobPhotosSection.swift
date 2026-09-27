//
//  JobPhotosSection.swift
//  DetailCRM
//
//  Before / after photos: library picker and camera (JPEG, 0.8 quality,
//  longest side 2048 px via ImageCompression), a thumbnail grid from
//  signed URLs, and a full-screen pager. Uploaders delete their own
//  photos; managers delete any.
//

import SwiftUI
import UIKit
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
    @State private var viewer: JobPhotoViewerRequest?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]

    var body: some View {
        JobSectionCard("Photos") {
            JobSectionStateView(model.photos, loadingLabel: "Loading photos…", retry: { await model.loadPhotos() }) { items in
                grid(items)
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
        .fullScreenCover(item: $viewer) { request in
            JobPhotoViewer(
                model: model,
                startID: request.id,
                permissions: permissions
            )
        }
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
                    .accessibilityLabel("\(item.photo.kind.displayName) photo")
                    .accessibilityHint("Opens the photo full screen")
                }
            }
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
            HStack(spacing: Theme.Spacing.sm) {
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
            }
            .disabled(isUploading)
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

    var body: some View {
        NavigationStack {
            pager
                .overlay(alignment: .bottom) { errorBanner }
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle(current?.photo.kind.displayName ?? "Photo")
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
                    JobZoomablePhoto(url: item.url)
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
