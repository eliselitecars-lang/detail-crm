//
//  QuoteActionSheets.swift
//  DetailCRM
//
//  Sheets for the quote screen: send (mark sent + the quote_sent message),
//  record the customer's approval / decline, and convert to a job.
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
    let isApproval: Bool
    let onDone: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorText: String?
    @State private var didPrefill = false
    @State private var selectedOptionalIDs: Set<UUID> = []

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
                    selectedOptionalIDs = Set(optionalLines.filter { $0.isSelected }.map { $0.id })
                }
            }
        }
    }

    private var optionalLines: [QuoteLineItem] {
        lines.filter { $0.isOptional }.sorted { $0.sort < $1.sort }
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
        return optionalLines.isEmpty
            ? "Use this when the customer approved in person or by phone."
            : "Use this when the customer approved in person or by phone. Tick the optional items they chose; the total follows."
    }

    private func submit() async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            if isApproval {
                try await QuoteService.recordApproval(
                    shopID: shopID,
                    quoteID: quote.id,
                    approvedByName: text,
                    selectedOptionalIDs: optionalLines.isEmpty
                        ? nil
                        : optionalLines.map { $0.id }.filter { selectedOptionalIDs.contains($0) }
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
                Text("Creates a job with the quote's items (optional items only when the customer chose them), discount and notes.")
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
