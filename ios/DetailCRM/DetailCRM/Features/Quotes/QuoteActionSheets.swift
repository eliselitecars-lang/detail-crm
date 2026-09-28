//
//  QuoteActionSheets.swift
//  DetailCRM
//
//  Sheets for the quote screen: send (mark sent + the quote_sent message),
//  record the customer's approval / decline (with the proposal option they
//  chose), convert to a job, and the online self-scheduling switch.
//

import SwiftUI
import DetailCore

// MARK: - Send

struct QuoteSendSheet: View {
    let quote: Quote
    let customer: QuoteCustomerRef?
    let onSent: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var notifyCustomer = true
    @State private var channel: MoneyMessageChannel = .sms
    @State private var errorText: String?
    /// One per compose (reused when Send is tapped again after a failure,
    /// so the server never queues the message twice); new per channel.
    @State private var nonce = MoneyEdge.newNonce()

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(isResend ? "Resend \(quote.title)" : "Send \(quote.title)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("The quote is marked as sent. The customer opens it from their link to pick optional items and approve it.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Toggle("Message the customer", isOn: $notifyCustomer)
                        .font(Theme.Typography.body)
                        .tint(Theme.glacier)
                    Picker("Send by", selection: $channel) {
                        ForEach(MoneyMessageChannel.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!notifyCustomer)
                    .opacity(notifyCustomer ? 1 : 0.45)
                    if notifyCustomer {
                        MoneyDocumentMessagePreviewView(
                            request: MoneyDocumentMessage.Request(kind: .quoteSent, id: quote.id, channel: channel)
                        )
                    } else {
                        Text("No message is sent. Share the client link yourself from the quote.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .cardStyle()
                .onChange(of: channel) {
                    nonce = MoneyEdge.newNonce()
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton(isResend ? "Resend quote" : "Send quote") {
                    await send()
                }
            }
            .navigationTitle(isResend ? "Resend quote" : "Send quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var isResend: Bool { quote.status != .draft }

    private func send() async {
        errorText = nil
        do {
            try await QuoteService.markSent(quoteID: quote.id)
        } catch {
            errorText = ErrorText.message(for: error)
            return
        }
        var messageProblem: String?
        if notifyCustomer {
            do {
                let shopID = try appState.requireShopID()
                let result = try await QuoteService.sendQuoteMessage(
                    shopID: shopID,
                    quote: quote,
                    channel: channel,
                    nonce: nonce
                )
                if result.failed {
                    messageProblem = result.error?.trimmedNonEmpty ?? "The message could not be delivered."
                }
            } catch {
                messageProblem = ErrorText.message(for: error)
            }
        }
        await onSent()
        if let messageProblem {
            toasts.show("Quote marked as sent, but the message wasn't sent: \(messageProblem)", style: .error, duration: .seconds(6))
        } else {
            toasts.show(notifyCustomer ? "Quote sent" : "Quote marked as sent")
        }
        dismiss()
    }
}

// MARK: - Record approval / decline

struct QuoteResponseSheet: View {
    let quote: Quote
    let customer: QuoteCustomerRef?
    /// The quote's lines: an approval lets staff tick the optional items
    /// the customer chose.
    let lines: [QuoteLineItem]
    /// Proposal options (P-15): an approval must say which one was chosen.
    var options: [MoneyQuoteOption] = []
    let isApproval: Bool
    let onDone: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorText: String?
    @State private var didPrefill = false
    @State private var selectedOptionalIDs: Set<UUID> = []
    /// The option the customer chose (quotes with options).
    @State private var chosenOptionID: UUID?

    var body: some View {
        NavigationStack {
            FormScreen {
                Text(explanation)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isApproval {
                    ThemedTextField(
                        label: "Approved by",
                        placeholder: "Customer's name",
                        text: $text,
                        kind: .name
                    )
                    if !options.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Option the customer chose")
                                .font(Theme.Typography.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            MoneyQuoteOptionPicker(
                                choices: orderedOptions.map { MoneyQuoteOptionPicker.Choice(option: $0) },
                                selection: $chosenOptionID,
                                accessibilityTitle: "Chosen option"
                            )
                            if let chosen = orderedOptions.first(where: { $0.id == chosenOptionID }) {
                                HStack {
                                    Text("\(chosen.name) total")
                                        .font(Theme.Typography.subheadline)
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer(minLength: Theme.Spacing.sm)
                                    MoneyText(cents: chosen.totalCents, currencyCode: appState.currencyCode)
                                }
                                .accessibilityElement(children: .combine)
                                Text("With the optional items picked so far; the quote total follows the choices below once recorded.")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Choose the option the customer approved.")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .cardStyle()
                    }
                    if !optionalLines.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text("Optional items the customer chose")
                                .font(Theme.Typography.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            ForEach(optionalLines) { line in
                                Toggle(isOn: selectionBinding(line.id)) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                                        Text(line.name)
                                            .font(Theme.Typography.body)
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer(minLength: Theme.Spacing.sm)
                                        if let total = line.totalCents {
                                            MoneyText(cents: total, currencyCode: appState.currencyCode, size: .small)
                                        }
                                    }
                                }
                                .tint(Theme.glacier)
                            }
                        }
                        .cardStyle()
                    }
                } else {
                    FormRow("Reason (optional)") {
                        TextField("Why the customer declined", text: $text, axis: .vertical)
                            .lineLimit(2...6)
                            .inputFieldStyle()
                    }
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                if isApproval {
                    AsyncButton("Record approval") { await submit() }
                } else {
                    AsyncButton("Record decline", role: .destructive, style: .themeDestructive) { await submit() }
                }
            }
            .navigationTitle(isApproval ? "Record approval" : "Record decline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if !didPrefill {
                    didPrefill = true
                    if isApproval, let customer {
                        text = customer.displayName
                    }
                    if let selected = quote.selectedOptionID, options.contains(where: { $0.id == selected }) {
                        chosenOptionID = selected
                    }
                    selectedOptionalIDs = Set(lines.filter { $0.isOptional && $0.isSelected }.map { $0.id })
                }
            }
        }
    }

    private var orderedOptions: [MoneyQuoteOption] {
        MoneyQuoteOption.ordered(options)
    }

    /// Optional items that can be picked: shared ones plus those of the
    /// chosen option (none of another option's).
    private var optionalLines: [QuoteLineItem] {
        lines
            .filter { $0.isOptional && ($0.optionID == nil || (chosenOptionID != nil && $0.optionID == chosenOptionID)) }
            .sorted { $0.sort < $1.sort }
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedOptionalIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedOptionalIDs.insert(id)
                } else {
                    selectedOptionalIDs.remove(id)
                }
            }
        )
    }

    private var explanation: String {
        if !isApproval {
            return "Use this when the customer turned the quote down in person or by phone."
        }
        if !options.isEmpty {
            return "Use this when the customer approved in person or by phone. Choose the option they picked and tick any optional items; the total follows."
        }
        return optionalLines.isEmpty
            ? "Use this when the customer approved in person or by phone."
            : "Use this when the customer approved in person or by phone. Tick the optional items they chose; the total follows."
    }

    private func submit() async {
        errorText = nil
        if isApproval && !options.isEmpty && chosenOptionID == nil {
            errorText = "Choose the option the customer approved."
            return
        }
        do {
            let shopID = try appState.requireShopID()
            if isApproval {
                try await QuoteService.recordApproval(
                    shopID: shopID,
                    quoteID: quote.id,
                    approvedByName: text,
                    selectedOptionalIDs: optionalLines.isEmpty
                        ? nil
                        : optionalLines.map { $0.id }.filter { selectedOptionalIDs.contains($0) },
                    optionID: options.isEmpty ? nil : chosenOptionID
                )
            } else {
                try await QuoteService.recordDecline(shopID: shopID, quoteID: quote.id, reason: text)
            }
            await onDone()
            toasts.show(isApproval ? "Approval recorded" : "Decline recorded")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Convert to job

struct QuoteConvertSheet: View {
    let quote: Quote
    let lines: [QuoteLineItem]
    let onConverted: (UUID) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var schedule = true
    @State private var start = Date()
    @State private var durationMinutes = 60
    @State private var didSetUp = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                Text("Creates a job with the quote's items (optional items only when the customer chose them; for a quote with options, the chosen option's items), discount and notes.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Toggle("Schedule it now", isOn: $schedule)
                        .font(Theme.Typography.body)
                        .tint(Theme.glacier)
                    DatePicker(
                        "Starts",
                        selection: $start,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(Theme.Typography.body)
                    .environment(\.timeZone, appState.clock.timeZone)
                    .disabled(!schedule)
                    .opacity(schedule ? 1 : 0.45)
                    Stepper(value: $durationMinutes, in: 15...1440, step: 15) {
                        Text("Duration: \(ShopClock.durationText(minutes: durationMinutes))")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .disabled(!schedule)
                    .opacity(schedule ? 1 : 0.45)
                    Text(scheduleHint)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cardStyle()
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton("Create job") { await convert() }
            }
            .navigationTitle("Convert to job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: setUp)
        }
    }

    private var scheduleHint: String {
        if schedule {
            let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
            return "\(appState.clock.longDayText(start)), \(appState.clock.rangeText(from: start, to: end)) (shop time)."
        }
        return "The job is created as a request without a time; schedule it from the calendar later."
    }

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        let calendar = appState.clock.calendar
        start = calendar.nextDate(
            after: Date(),
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? Date()
        let counted = lines.filter { !$0.isOptional || $0.isSelected }
        let minutes = counted.reduce(0) { $0 + $1.durationMinutes }
        if minutes > 0 {
            // Round up to the stepper's 15-minute grid.
            durationMinutes = min(1440, max(15, ((minutes + 14) / 15) * 15))
        }
    }

    private func convert() async {
        errorText = nil
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        do {
            let job = try await QuoteService.convertToJob(
                quoteID: quote.id,
                start: schedule ? start : nil,
                end: schedule ? end : nil
            )
            toasts.show("Job #\(job.number) created")
            onConverted(job.id)
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Online self-scheduling (P-16)

extension QuoteDetailView {

    /// "Customer can schedule online": after approving, the customer picks a
    /// time on the quote's page (the shop's online booking hours and
    /// capacity apply) and pays any deposit there. Per quote
    /// (`quotes.self_schedule`); the shop turns the feature on in its online
    /// booking settings on the web.
    struct SelfScheduleSection: View {
        let data: QuoteService.DetailData
        let onChanged: () async -> Void

        @Environment(AppState.self) private var appState
        @Environment(ToastCenter.self) private var toasts
        @State private var isSaving = false

        /// Shown until the quote is converted, declined or expired.
        static func applies(to quote: Quote) -> Bool {
            switch quote.status {
            case .draft, .sent, .viewed, .approved: return true
            case .declined, .expired, .converted: return false
            }
        }

        var body: some View {
            MoneySectionCard("Online scheduling") {
                Toggle(isOn: binding) {
                    Text("Customer can schedule online")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.glacier)
                .disabled(isSaving)
                Text(explanation)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private var shopAllows: Bool? { data.selfScheduleSetting?.isAvailable }

        private var explanation: String {
            switch shopAllows {
            case .none:
                return "After approving, the customer can pick a time on the quote page when your shop's online booking allows it."
            case .some(false):
                return "Online scheduling of approved quotes is off for your shop. Turn it on in the online booking settings on the web."
            case .some(true):
                guard data.quote.selfSchedule else {
                    return "The customer won't be offered times online for this quote. Convert it to a job yourself once it's approved."
                }
                if data.quote.status == .approved {
                    return "Waiting for the customer to pick a time on the quote page. Your online booking hours and capacity apply, and any deposit is paid there."
                }
                return "Once the customer approves, they can pick a time on the quote page. Your online booking hours and capacity apply, and any deposit is paid there."
            }
        }

        private var binding: Binding<Bool> {
            Binding(
                get: { data.quote.selfSchedule },
                set: { enabled in
                    Task { await save(enabled) }
                }
            )
        }

        private func save(_ enabled: Bool) async {
            guard !isSaving else { return }
            isSaving = true
            defer { isSaving = false }
            do {
                let shopID = try appState.requireShopID()
                try await QuoteService.setSelfSchedule(shopID: shopID, quoteID: data.quote.id, enabled: enabled)
                await onChanged()
                toasts.show(enabled ? "The customer can schedule this quote online" : "Online scheduling turned off for this quote")
            } catch {
                toasts.showError(error)
            }
        }
    }
}
