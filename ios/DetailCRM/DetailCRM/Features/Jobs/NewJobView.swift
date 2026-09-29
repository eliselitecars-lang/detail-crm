//
//  NewJobView.swift
//  DetailCRM
//
//  The New Job flow, presented as a sheet: customer (search or create) →
//  vehicle (pick, add, VIN decode) → services (server-priced for the
//  vehicle, memberships applied) → schedule (shop time zone, location,
//  bay/van, team) → review + create.
//
//  On success the job opens: when the presenter passes `onCreated`, the
//  sheet dismisses and hands it the new job's id (so it can push the job
//  on its own stack); otherwise the job opens inside this sheet.
//

import SwiftUI
import DetailCore

struct NewJobView: View {
    let prefillStart: Date?
    let prefillCustomerID: UUID?
    let onCreated: ((UUID) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var model: NewJobModel
    @State private var finishedJobID: UUID?

    init(prefillStart: Date?, prefillCustomerID: UUID?, onCreated: ((UUID) -> Void)? = nil) {
        self.prefillStart = prefillStart
        self.prefillCustomerID = prefillCustomerID
        self.onCreated = onCreated
        _model = State(initialValue: NewJobModel(prefillStart: prefillStart, prefillCustomerID: prefillCustomerID))
    }

    var body: some View {
        NavigationStack {
            root
                .appRouteDestinations()
        }
        .interactiveDismissDisabled(model.hasStartedCreating && finishedJobID == nil)
    }

    private var root: AnyView {
        if let finishedJobID {
            return AnyView(
                JobDetailView(jobID: finishedJobID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            )
        }
        guard appState.can(.createJobs) else {
            return AnyView(
                EmptyStateView(
                    systemImage: "lock",
                    title: "Managers create jobs",
                    message: "Ask an owner, admin or manager to book this job."
                )
                .screenBackground()
                .navigationTitle("New job")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            )
        }
        return AnyView(flow)
    }

    private var flow: some View {
        VStack(spacing: 0) {
            NewJobStepHeader(
                current: model.step,
                isLocked: model.hasStartedCreating,
                reachable: reachableSteps,
                onSelect: { step in
                    // Once the job row exists the earlier choices are fixed
                    // (Retry finishes that job); never jump back.
                    guard !model.hasStartedCreating else { return }
                    model.step = step
                }
            )
            JobDivider()
            if let problem = model.referenceProblem {
                JobReferenceLoadError(text: problem) {
                    await model.loadReferenceData()
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.sm)
                JobDivider()
            }
            stepContent
        }
        .screenBackground()
        .navigationTitle("New job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.hasStartedCreating ? "Close" : "Cancel") { dismiss() }
            }
        }
        .task { await setUp() }
    }

    /// Hands the active shop to the model, then loads categories, team,
    /// resources and the prefilled customer.
    private func setUp() async {
        guard let current = appState.current else { return }
        model.configure(shopID: current.shop.id, clock: appState.clock, businessType: current.shop.businessType)
        await model.loadReferenceData()
    }

    /// Steps the header lets the user jump back to.
    private var reachableSteps: Set<NewJobStep> {
        var steps: Set<NewJobStep> = [.customer]
        if model.customer != nil { steps.insert(.vehicle) }
        if model.customer != nil && model.vehicles.value != nil { steps.insert(.services) }
        if !model.selectedServiceIDs.isEmpty || model.step.rawValue >= NewJobStep.schedule.rawValue {
            steps.insert(.schedule)
        }
        if model.step == .review { steps.insert(.review) }
        return steps
    }

    private var stepContent: AnyView {
        switch model.step {
        case .customer:
            return AnyView(NewJobCustomerStep(model: model))
        case .vehicle:
            return AnyView(NewJobVehicleStep(model: model))
        case .services:
            return AnyView(NewJobServicesStep(model: model))
        case .schedule:
            return AnyView(NewJobScheduleStep(model: model))
        case .review:
            return AnyView(NewJobReviewStep(model: model, onCreate: { await create() }))
        }
    }

    private func create() async {
        guard let jobID = await model.create() else { return }
        toasts.show("Job created")
        if let onCreated {
            dismiss()
            onCreated(jobID)
        } else {
            finishedJobID = jobID
        }
    }
}

/// Step chips; earlier steps are tappable until the job has been created.
struct NewJobStepHeader: View {
    let current: NewJobStep
    let isLocked: Bool
    let reachable: Set<NewJobStep>
    let onSelect: (NewJobStep) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(NewJobStep.allCases) { step in
                    chip(step)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .background(Theme.surface)
    }

    private func chip(_ step: NewJobStep) -> some View {
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        let enabled = !isLocked && !isCurrent && reachable.contains(step)
        return Button {
            onSelect(step)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("\(step.rawValue + 1)")
                    .font(Theme.Typography.captionEmphasis.monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.glacierSolid : Theme.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(isCurrent ? Theme.onAccent : (isDone ? Theme.successSolid : Theme.neutralSolid)))
                Text(step.title)
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(isCurrent ? Theme.onAccent : Theme.textPrimary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: Theme.Size.compactControlHeight)
            .background(Capsule().fill(isCurrent ? Theme.glacierSolid : Theme.surfaceMuted))
        }
        .buttonStyle(.plain)
        // `.disabled` (not just hit testing) so VoiceOver can't activate a
        // locked step either.
        .disabled(!enabled)
        .opacity(enabled || isCurrent || isDone ? 1 : 0.6)
        .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
