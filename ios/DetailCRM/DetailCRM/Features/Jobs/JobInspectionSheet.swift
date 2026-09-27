//
//  JobInspectionSheet.swift
//  DetailCRM
//
//  One inspection: pick a view (front / rear / sides / top / interior),
//  tap the diagram to mark damage (type, note, optional photo), record
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
                Text(editable ? "Tap the drawing where the damage is." : "This inspection is signed and locked.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        )
    }

    private func addMark(at point: CGPoint, inspectionID: UUID) {
        markDraft = JobMarkDraftRequest(
            inspectionID: inspectionID,
            view: selectedView,
            x: Double(point.x),
            y: Double(point.y)
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
                    Picker("Fuel level", selection: $fuel) {
                        ForEach(JobFuelLevelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!editable)
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

    private func isDirty(_ inspection: Inspection) -> Bool {
        let mileage = Int(mileageText.filter { $0 != "," && $0 != " " })
        return mileage != inspection.mileage
            || fuel.percent != inspection.fuelLevel
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
                fuelLevel: fuel.percent,
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
                        .foregroundStyle(isSelected ? Theme.glacier : Theme.onAccent)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .background(Capsule().fill(isSelected ? Theme.onAccent : Theme.danger))
                }
            }
            .font(Theme.Typography.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.compactControlHeight)
            .background(Capsule().fill(isSelected ? Theme.glacier : Theme.surfaceMuted))
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

    @State private var photoURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.danger))
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
                if mark.photoPath != nil {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.surfaceMuted
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityLabel("Damage photo")
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.danger)
                        .frame(width: 32, height: 32)
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
        .task(id: mark.photoPath) {
            guard let path = mark.photoPath else { return }
            photoURL = try? await JobOpsService.signedURL(bucket: JobOpsService.photosBucket, path: path)
        }
    }
}

/// "Signed by … at …" with the signature image.
struct JobSignedBlock: View {
    let signerName: String?
    let signedAt: Date?
    let signaturePath: String?
    let clock: ShopClock

    @State private var imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                Text(caption)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
            }
            if signaturePath != nil {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                        .tint(Theme.glacier)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                .frame(maxWidth: .infinity, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surfaceMuted)
                )
                .accessibilityLabel("Signature")
            }
        }
        .task(id: signaturePath) {
            guard let signaturePath else { return }
            imageURL = try? await JobOpsService.signedURL(bucket: JobOpsService.signaturesBucket, path: signaturePath)
        }
    }

    private var caption: String {
        let who = signerName?.trimmedNonEmpty ?? "Signed"
        guard let signedAt else { return who }
        return "\(who) · \(clock.dateTimeText(signedAt))"
    }
}

/// New mark: damage type, note and an optional photo.
struct JobMarkEditorSheet: View {
    let model: JobDetailModel
    let draft: JobMarkDraftRequest

    @Environment(\.dismiss) private var dismiss
    @State private var damage: JobDamageKind = .scratch
    @State private var note = ""
    @State private var photo: Data?
    @State private var showingCamera = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.sm)]

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
                        .fill(isSelected ? Theme.glacier : Theme.surfaceMuted)
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
