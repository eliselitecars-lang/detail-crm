//
//  JobsRepeatPickerSection.swift
//  DetailCRM
//
//  "Repeat" on the new-job schedule step (P-1): weekly on chosen days or
//  monthly on a day / an nth weekday, every 1–12 weeks or months, ending
//  never / on a date / after N visits. The list of the first visits comes
//  from the server (`job_series_preview`), so what is shown is exactly what
//  will be created.
//

import SwiftUI
import DetailCore

struct JobsRepeatPickerSection: View {
    @Bindable var model: NewJobModel

    @State private var untilDate = Date()
    @State private var count = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Toggle("Repeat", isOn: $model.repeatEnabled)
                .tint(Theme.glacier)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .disabled(model.scheduleLater)
            if model.repeatEnabled && !model.scheduleLater {
                ruleFields
                endFields
                preview
            }
        }
        .task(id: model.repeatPreviewKey) {
            // Let quick edits settle before asking the server.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.loadRepeatPreview()
        }
    }

    // MARK: - Rule

    private var ruleFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Picker("Repeats", selection: $model.repeatDraft.rule.frequency) {
                Text("Weekly").tag(JobsSeriesDraft.Frequency.week)
                Text("Monthly").tag(JobsSeriesDraft.Frequency.month)
            }
            .pickerStyle(.segmented)

            Stepper(value: $model.repeatDraft.rule.interval, in: 1...12) {
                Text(intervalText)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }

            if model.repeatDraft.rule.frequency == .week {
                weekdayChips
            } else {
                monthFields
            }
        }
    }

    private var intervalText: String {
        let rule = model.repeatDraft.rule
        let unit = rule.frequency.unitName
        return rule.interval == 1 ? "Every \(unit)" : "Every \(rule.interval) \(unit)s"
    }

    private var weekdayChips: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<7, id: \.self) { day in
                let isOn = model.repeatDraft.rule.weekdays.contains(day)
                Button {
                    if isOn {
                        model.repeatDraft.rule.weekdays.remove(day)
                    } else {
                        model.repeatDraft.rule.weekdays.insert(day)
                    }
                } label: {
                    Text(String(JobsSeriesDraft.Rule.weekdayNames[day].prefix(2)))
                        .font(Theme.Typography.captionEmphasis)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.compactControlHeight)
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.textPrimary)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(isOn ? Theme.glacier : Theme.surfaceMuted)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(JobsSeriesDraft.Rule.weekdayLongNames[day])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private var monthFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Picker("On", selection: $model.repeatDraft.rule.monthMode) {
                Text("Day of the month").tag(JobsSeriesDraft.MonthMode.dayOfMonth)
                Text("Weekday").tag(JobsSeriesDraft.MonthMode.nthWeekday)
            }
            .pickerStyle(.segmented)
            if model.repeatDraft.rule.monthMode == .dayOfMonth {
                Stepper(value: $model.repeatDraft.rule.monthDay, in: 1...31) {
                    Text("On day \(model.repeatDraft.rule.monthDay)")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                }
                if model.repeatDraft.rule.monthDay > 28 {
                    Text("In shorter months the visit falls on the last day.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                HStack {
                    Picker("Which", selection: $model.repeatDraft.rule.monthNth) {
                        ForEach([1, 2, 3, 4, 5, -1], id: \.self) { n in
                            Text(JobsSeriesDraft.Rule.ordinal(n).capitalized).tag(n)
                        }
                    }
                    Picker("Weekday", selection: $model.repeatDraft.rule.monthWeekday) {
                        ForEach(0..<7, id: \.self) { day in
                            Text(JobsSeriesDraft.Rule.weekdayLongNames[day]).tag(day)
                        }
                    }
                }
                .pickerStyle(.menu)
                if model.repeatDraft.rule.monthNth == 5 {
                    Text("Months without a fifth one are skipped.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - End

    private var endFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Ends", selection: endKind) {
                Text("Never").tag(0)
                Text("On a date").tag(1)
                Text("After").tag(2)
            }
            .pickerStyle(.segmented)
            switch model.repeatDraft.end {
            case .never:
                Text("Visits are added automatically about 3 months ahead.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            case .onDate:
                DatePicker("Last visit on or before", selection: untilBinding, in: model.start..., displayedComponents: [.date])
                    .environment(\.timeZone, model.clock.timeZone)
                    .font(Theme.Typography.body)
            case .afterCount:
                Stepper(value: countBinding, in: 1...500) {
                    Text(count == 1 ? "1 visit" : "\(count) visits")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var endKind: Binding<Int> {
        Binding(
            get: {
                switch model.repeatDraft.end {
                case .never: return 0
                case .onDate: return 1
                case .afterCount: return 2
                }
            },
            set: { kind in
                switch kind {
                case 1:
                    if untilDate < model.start {
                        untilDate = model.clock.addingDays(90, to: model.start)
                    }
                    model.repeatDraft.end = .onDate(untilDate)
                case 2:
                    model.repeatDraft.end = .afterCount(count)
                default:
                    model.repeatDraft.end = .never
                }
            }
        )
    }

    private var untilBinding: Binding<Date> {
        Binding(
            get: { untilDate },
            set: { day in
                untilDate = day
                model.repeatDraft.end = .onDate(day)
            }
        )
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { count },
            set: { value in
                count = value
                model.repeatDraft.end = .afterCount(value)
            }
        )
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(model.repeatDraft.rule.summary)
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            switch model.repeatPreview {
            case .idle:
                if let problem = model.repeatProblem {
                    InlineMessage(text: problem, kind: .info)
                } else if model.customer == nil {
                    InlineMessage(text: "Choose a customer to see the visits.", kind: .info)
                }
            case .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().tint(Theme.glacier)
                    Text("Working out the visits…")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let message):
                InlineMessage(text: message, kind: .error)
            case .loaded(let visits):
                if visits.isEmpty {
                    InlineMessage(text: "No visits fall inside this repeat. Check the days and the end.", kind: .error)
                } else {
                    Text("First visits")
                        .font(Theme.Typography.eyebrow)
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(visits) { visit in
                        Text("\(visit.seq). " + model.clock.dateTimeText(visit.startsAt))
                            .font(Theme.Typography.footnote.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("Each visit is its own job with these services, priced when it's created.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
