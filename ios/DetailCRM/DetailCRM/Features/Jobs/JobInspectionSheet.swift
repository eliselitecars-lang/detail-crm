//
//  JobInspectionSheet.swift
//  DetailCRM
//
//  One inspection: pick a view (front / rear / sides / top / interior),
//  tap the diagram (or pick a named area from "Add mark", the path for
//  VoiceOver and Switch Control) to mark damage (type, note, optional
//  photo), record
//  mileage and fuel, and collect the customer's signature — which locks
//  the inspection (a manager must remove the signature to change it).
//

import SwiftUI
import UIKit
import DetailCore

/// A new mark waiting for its damage type.
struct JobMarkDraftRequest: Identifiable, Hashable {
    let id = UUID()
    let inspectionID: UUID
    let view: JobVehicleView
    let x: Double
    let y: Double
    /// The named area chosen from "Add mark"; prefills the mark's note.
    var areaName: String? = nil
}

/// Fuel gauge choices (stored as percent).
enum JobFuelLevelChoice: Int, CaseIterable, Identifiable {
    case notRecorded = -1
    case empty = 0
    case quarter = 25
    case half = 50
    case threeQuarters = 75
    case full = 100

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .notRecorded: return "—"
        case .empty: return "E"
        case .quarter: return "¼"
        case .half: return "½"
        case .threeQuarters: return "¾"
        case .full: return "F"
        }
    }

    var percent: Int? { self == .notRecorded ? nil : rawValue }

    /// Nearest choice for a stored percent.
    static func nearest(_ percent: Int?) -> JobFuelLevelChoice {
        guard let percent else { return .notRecorded }
        let choices: [JobFuelLevelChoice] = [.empty, .quarter, .half, .threeQuarters, .full]
        return choices.min(by: { abs($0.rawValue - percent) < abs($1.rawValue - percent) }) ?? .notRecorded
    }
}

struct JobInspectionSheet: View {
    let model: JobDetailModel
    let inspectionID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var selectedView: JobVehicleView = .front
    @State private var selectedMarkID: UUID?
    @State private var markDraft: JobMarkDraftRequest?
    @State private var mileageText = ""
    @State private var fuel: JobFuelLevelChoice = .notRecorded
    /// True once the user picks a fuel segment. Until then the stored
    /// percent (any 0–100 value, e.g. 60 from the web app) is kept exactly
    /// and never rounded to the nearest quarter on save or sign.
    @State private var fuelEdited = false
    @State private var notesText = ""
    @State private var signerName = ""
    @State private var drawing = SignatureDrawing()
    @State private var errorMessage: String?
    @State private var didPrefill = false
    @State private var confirmation: ConfirmationRequest?

    private var bundle: JobInspectionBundle? { model.inspection(inspectionID) }
    private var canWork: Bool { model.permissions.canWork }

    var body: some View {
        NavigationStack {
            content
                .screenBackground()
                .navigationTitle(bundle?.inspection.kind.displayName ?? "Inspection")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(item: $markDraft) { draft in
                    JobMarkEditorSheet(model: model, draft: draft)
                }
                .confirmation($confirmation)
                .onAppear { prefill() }
        }
    }

    private var content: AnyView {
        guard let bundle else {
            return AnyView(
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: "Inspection not found",
                    message: "It may have been deleted."
                )
            )
        }
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    diagramSection(bundle)
                    marksSection(bundle)
                    detailsSection(bundle)
                    signatureSection(bundle)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.lg)
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            if let bundle, canWork, !bundle.inspection.isSigned {
                Menu {
                    Button("Delete inspection", role: .destructive) {
                        confirmDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
    }

    // MARK: - Diagram

    private func diagramSection(_ bundle: JobInspectionBundle) -> AnyView {
        let editable = canWork && !bundle.inspection.isSigned
        let marks = bundle.marks(on: selectedView)
        return AnyView(
            JobSectionCard("Damage") {
                JobInspectionViewPicker(selection: $selectedView, bundle: bundle)
                JobVehicleDiagramView(
                    view: selectedView,
                    marks: marks,
                    selectedMarkID: selectedMarkID,
                    onTap: editable ? { point in addMark(at: point, inspectionID: bundle.id) } : nil,
                    onSelectMark: { mark in selectedMarkID = mark.id }
                )
                if editable {
                    addMarkMenu(inspectionID: bundle.id)
                }
                Text(editable
                     ? "Tap the drawing where the damage is, or choose the spot from Add mark."
                     : "This inspection is signed and locked.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        )
    }

    /// Adds a mark on a named part of the current view: the way to record
    /// damage without pointing at the drawing (VoiceOver, Switch Control,
    /// Voice Control, Full Keyboard Access), and handy for small panels.
    private func addMarkMenu(inspectionID: UUID) -> some View {
        Menu {
            ForEach(selectedView.areas) { area in
                Button(area.name) {
                    addMark(
                        at: CGPoint(x: area.x, y: area.y),
                        inspectionID: inspectionID,
                        areaName: area.name
                    )
                }
            }
        } label: {
            Label("Add mark", systemImage: "plus.circle")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.themeSecondary)
        .accessibilityLabel("Add damage mark on the \(selectedView.displayName.lowercased()) view")
        .accessibilityHint("Choose the part of the vehicle that is damaged.")
    }

    private func addMark(at point: CGPoint, inspectionID: UUID, areaName: String? = nil) {
        markDraft = JobMarkDraftRequest(
            inspectionID: inspectionID,
            view: selectedView,
            x: Double(point.x),
            y: Double(point.y),
            areaName: areaName
        )
    }

    // MARK: - Marks list

    private func marksSection(_ bundle: JobInspectionBundle) -> AnyView {
        let marks = bundle.marks(on: selectedView)
        let editable = canWork && !bundle.inspection.isSigned
        return AnyView(
            JobSectionCard("\(selectedView.displayName) marks") {
                if marks.isEmpty {
                    JobEmptyLine(text: "No damage marked on this view.", systemImage: "checkmark.shield")
                } else {
                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                        JobMarkRow(
                            mark: mark,
                            number: index + 1,
                            isSelected: mark.id == selectedMarkID,
                            onDelete: editable ? { confirmDeleteMark(mark) } : nil
                        )
                    }
                }
            }
        )
    }

    // MARK: - Details

    private func detailsSection(_ bundle: JobInspectionBundle) -> AnyView {
        let editable = canWork && !bundle.inspection.isSigned
        return AnyView(
            JobSectionCard("Vehicle condition") {
                ThemedTextField(label: "Mileage", placeholder: "Odometer reading", text: $mileageText, kind: .number)
                    .disabled(!editable)
                FormRow("Fuel level") {
                    Picker("Fuel level", selection: fuelBinding) {
                        ForEach(JobFuelLevelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!editable)
                }
                if let note = recordedFuelNote(bundle.inspection) {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                FormRow("Notes") {
                    TextField("Condition notes", text: $notesText, axis: .vertical)
                        .lineLimit(3...8)
                        .inputFieldStyle()
                        .disabled(!editable)
                }
                if editable {
                    AsyncButton("Save details", style: .themeSecondary) {
                        _ = await saveDetails(bundle.inspection)
                    }
                }
            }
        )
    }

    /// Parses the fields; nil (with an error shown) when invalid.
    private func parsedMileage() -> Int?? {
        guard let text = mileageText.trimmedNonEmpty else { return .some(nil) }
        let digits = text.filter { $0 != "," && $0 != " " }
        guard let value = Int(digits), value >= 0, value <= 9_999_999 else {
            errorMessage = "Mileage must be a whole number."
            return nil
        }
        return .some(value)
    }

    /// Picking a segment marks the fuel as edited.
    private var fuelBinding: Binding<JobFuelLevelChoice> {
        Binding(
            get: { fuel },
            set: { newValue in
                fuel = newValue
                fuelEdited = true
            }
        )
    }

    /// The fuel percent to save: the user's pick, or the stored value
    /// untouched when they didn't change it.
    private func fuelToSave(_ inspection: Inspection) -> Int? {
        fuelEdited ? fuel.percent : inspection.fuelLevel
    }

    /// Shows the exact stored percent when it isn't one of the segments.
    private func recordedFuelNote(_ inspection: Inspection) -> String? {
        guard !fuelEdited, let stored = inspection.fuelLevel,
              JobFuelLevelChoice(rawValue: stored) == nil else { return nil }
        return "Recorded: \(stored)%"
    }

    private func isDirty(_ inspection: Inspection) -> Bool {
        let mileage = Int(mileageText.filter { $0 != "," && $0 != " " })
        return mileage != inspection.mileage
            || fuelToSave(inspection) != inspection.fuelLevel
            || notesText.trimmedNonEmpty != inspection.notes?.trimmedNonEmpty
    }

    @discardableResult
    private func saveDetails(_ inspection: Inspection) async -> Bool {
        errorMessage = nil
        guard let mileage = parsedMileage() else { return false }
        do {
            try await model.updateInspection(
                inspection.id,
                mileage: mileage,
                fuelLevel: fuelToSave(inspection),
                notes: notesText
            )
            toasts.show("Inspection saved")
            return true
        } catch {
            errorMessage = ErrorText.message(for: error)
            return false
        }
    }

    // MARK: - Signature

    private func signatureSection(_ bundle: JobInspectionBundle) -> AnyView {
        AnyView(
            JobSectionCard("Customer signature") {
                if bundle.inspection.isSigned {
                    JobSignedBlock(
                        signerName: bundle.inspection.signedByName,
                        signedAt: bundle.inspection.signedAt,
                        signaturePath: bundle.inspection.customerSignaturePath,
                        clock: appState.clock
                    )
                } else if canWork {
                    Text("The customer confirms the condition above. Signing locks this inspection.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ThemedTextField(label: "Signer name", placeholder: "Full name", text: $signerName, kind: .name)
                    SignaturePadView(drawing: $drawing, prompt: "Customer signs above")
                    AsyncButton("Sign and lock", style: .themePrimary) {
                        await sign(bundle.inspection)
                    }
                    .disabled(drawing.isEmpty || signerName.trimmedNonEmpty == nil)
                } else {
                    JobEmptyLine(text: "Not signed yet.", systemImage: "signature")
                }
            }
        )
    }

    private func sign(_ inspection: Inspection) async {
        errorMessage = nil
        guard let png = drawing.pngData() else {
            errorMessage = "Ask the customer to sign in the box."
            return
        }
        if isDirty(inspection) {
            guard await saveDetails(inspection) else { return }
        }
        do {
            try await model.signInspection(inspection.id, signerName: signerName, signaturePNG: png)
            toasts.show("Inspection signed")
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    // MARK: - Setup & deletes

    private func prefill() {
        guard !didPrefill, let inspection = bundle?.inspection else { return }
        didPrefill = true
        mileageText = inspection.mileage.map(String.init) ?? ""
        fuel = JobFuelLevelChoice.nearest(inspection.fuelLevel)
        fuelEdited = false
        notesText = inspection.notes ?? ""
        signerName = model.snapshot?.customer?.displayName ?? ""
        if let first = bundle?.marks.first {
            selectedView = first.view
        }
    }

    private func confirmDeleteMark(_ mark: InspectionMark) {
        confirmation = ConfirmationRequest(
            title: "Remove this mark?",
            message: mark.damage.displayName,
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            do {
                errorMessage = nil
                try await model.deleteMark(mark)
                if selectedMarkID == mark.id { selectedMarkID = nil }
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func confirmDelete() {
        confirmation = ConfirmationRequest(
            title: "Delete this inspection?",
            message: "Its damage marks are removed too.",
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                try await model.deleteInspection(inspectionID)
                toasts.show("Inspection deleted")
                dismiss()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// Chips for the six views, each with its mark count.
struct JobInspectionViewPicker: View {
    @Binding var selection: JobVehicleView
    let bundle: JobInspectionBundle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(JobVehicleView.allCases) { view in
                    chip(view)
                }
            }
        }
    }

    private func chip(_ view: JobVehicleView) -> some View {
        let count = bundle.marks(on: view).count
        let isSelected = view == selection
        return Button {
            selection = view
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(view.displayName)
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Typography.captionEmphasis)
                        .foregroundStyle(isSelected ? Theme.glacierSolid : Theme.onAccent)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .background(Capsule().fill(isSelected ? Theme.onAccent : Theme.dangerSolid))
                }
            }
            .font(Theme.Typography.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.compactControlHeight)
            .background(Capsule().fill(isSelected ? Theme.glacierSolid : Theme.surfaceMuted))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(view.displayName), \(count) marks")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One mark in the list: number, damage, note and photo.
struct JobMarkRow: View {
    let mark: InspectionMark
    let number: Int
    let isSelected: Bool
    let onDelete: (() -> Void)?

    /// The number badge grows with Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var badgeSide: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(number)")
                .font(Theme.Typography.captionEmphasis.monospacedDigit())
                .foregroundStyle(Theme.onAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: badgeSide, height: badgeSide)
                .background(Circle().fill(Theme.dangerSolid))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(mark.damage.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                if let note = mark.note?.trimmedNonEmpty {
                    Text(note)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let photoPath = mark.photoPath {
                    JobStorageImage(
                        bucket: JobOpsService.photosBucket,
                        path: photoPath,
                        initialURL: nil,
                        noun: "photo"
                    ) { phase, retry in
                        JobMarkPhoto(phase: phase, retry: retry)
                    }
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.dangerInk)
                        .iconTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove mark \(number)")
            }
        }
        .padding(Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.glacier.opacity(0.10) : Color.clear)
        )
    }
}

/// "Signed by … at …" with the signature image.
struct JobSignedBlock: View {
    let signerName: String?
    let signedAt: Date?
    let signaturePath: String?
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                Text(caption)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.successInk)
            }
            if let signaturePath {
                // Signs its own link; a failure says so with Retry instead
                // of spinning forever.
                JobStorageImage(
                    bucket: JobOpsService.signaturesBucket,
                    path: signaturePath,
                    initialURL: nil,
                    noun: "signature"
                ) { phase, retry in
                    JobSignatureImage(phase: phase, retry: retry)
                }
            }
        }
    }

    private var caption: String {
        let who = signerName?.trimmedNonEmpty ?? "Signed"
        guard let signedAt else { return who }
        return "\(who) · \(clock.dateTimeText(signedAt))"
    }
}

/// A damage-mark photo tile; when it couldn't be loaded, tapping it tries
/// again.
private struct JobMarkPhoto: View {
    let phase: JobStorageImagePhase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .failed(let message):
            Button(action: retry) {
                tile
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Damage photo. " + message)
            .accessibilityHint("Tries again")
        case .image, .loading:
            tile
                .accessibilityLabel("Damage photo")
        }
    }

    private var tile: some View {
        JobStorageImageTile(phase: phase)
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The signature image, its loading state, or the failure with Retry.
private struct JobSignatureImage: View {
    let phase: JobStorageImagePhase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .image(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surfaceMuted)
                )
                .accessibilityLabel("Signature")
        case .loading:
            ProgressView()
                .tint(Theme.glacier)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surfaceMuted)
                )
                .accessibilityLabel("Loading signature")
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                Button("Retry", action: retry)
                    .buttonStyle(.themeSecondaryCompact)
            }
        }
    }
}

/// New mark: damage type, note and an optional photo.
struct JobMarkEditorSheet: View {
    let model: JobDetailModel
    let draft: JobMarkDraftRequest

    @Environment(\.dismiss) private var dismiss
    @State private var damage: JobDamageKind = .scratch
    /// Starts as the chosen area's name ("Front door") so the saved mark
    /// says where it is even to someone who can't see the pin.
    @State private var note: String
    @State private var photo: Data?
    @State private var showingCamera = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]

    init(model: JobDetailModel, draft: JobMarkDraftRequest) {
        self.model = model
        self.draft = draft
        _note = State(initialValue: draft.areaName ?? "")
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                FormRow("Damage") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(JobDamageKind.allCases) { kind in
                            damageChip(kind)
                        }
                    }
                }
                FormRow("Note", hint: "Optional — size, depth, panel.") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .inputFieldStyle()
                }
                photoRow
            }
            .navigationTitle("Mark on \(draft.view.displayName.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton("Save", style: .themePrimaryCompact) {
                        await save()
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    photo = ImageCompression.jpegData(from: image)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func damageChip(_ kind: JobDamageKind) -> some View {
        let isSelected = kind == damage
        return Button {
            damage = kind
        } label: {
            Text(kind.displayName)
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.compactControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(isSelected ? Theme.glacierSolid : Theme.surfaceMuted)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var photoRow: some View {
        FormRow("Photo", hint: "Optional close-up of the damage.") {
            HStack(spacing: Theme.Spacing.sm) {
                PhotoPickerButton(maxSelection: 1, onPicked: { images, _ in
                    if let first = images.first { photo = first }
                }) {
                    Label(photo == nil ? "Library" : "Replace", systemImage: "photo")
                        .font(Theme.Typography.buttonCompact)
                        .foregroundStyle(Theme.glacier)
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(minHeight: Theme.Size.compactControlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
                        )
                }
                if CameraPicker.isAvailable {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                }
                if let photo, let image = UIImage(data: photo) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                        .accessibilityLabel("Selected photo")
                    Button {
                        self.photo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove photo")
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        do {
            try await model.addMark(
                inspectionID: draft.inspectionID,
                view: draft.view,
                x: draft.x,
                y: draft.y,
                damage: damage,
                note: note,
                photoJPEG: photo
            )
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
