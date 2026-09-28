//
//  QuoteDetailView.swift
//  DetailCRM
//
//  One quote: customer & vehicle, lines (optional items marked, grouped by
//  proposal option), the options with their server totals, the server's
//  totals, notes, a status timeline, and the actions that fit the status
//  (send, share the client link or a PDF, record the customer's answer,
//  convert to a job, revise, delete), plus online self-scheduling and the
//  automatic follow-ups. Sections are separated by AnyView seams to keep
//  the composed view type shallow.
//

import SwiftUI
import DetailCore

/// Sheets the quote screen presents.
enum QuoteDetailSheet: Identifiable {
    case edit(QuoteDraft)
    case send
    case approve
    case decline
    case convert

    var id: String {
        switch self {
        case .edit: return "edit"
        case .send: return "send"
        case .approve: return "approve"
        case .decline: return "decline"
        case .convert: return "convert"
        }
    }
}

/// Buttons on the quote screen.
enum QuoteDetailAction {
    case edit
    case send
    case approve
    case decline
    case convert
    case reviseToDraft
    case delete
}

struct QuoteDetailView: View {
    let quoteID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState<QuoteService.DetailData> = .idle
    @State private var activeSheet: QuoteDetailSheet?
    @State private var confirmation: ConfirmationRequest?
    @State private var pendingJobRoute: AppRoute?
    @State private var jobRoute: AppRoute?

    var body: some View {
        Group {
            if appState.can(.manageQuotes) {
                LoadStateView(state, loadingLabel: "Loading quote…", retry: { await load() }) { data in
                    QuoteDetailContent(
                        data: data,
                        currencyCode: appState.currencyCode,
                        clock: appState.clock,
                        perform: { action in handle(action, data: data) },
                        onChanged: { await load() }
                    )
                }
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Quotes aren't available",
                    message: "Owners, admins and managers build and send quotes."
                )
            }
        }
        .screenBackground()
        .navigationTitle(state.value?.quote.title ?? "Quote")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $activeSheet, onDismiss: {
            if let route = pendingJobRoute {
                pendingJobRoute = nil
                jobRoute = route
            }
        }, content: { sheet in
            sheetContent(sheet)
        })
        .confirmation($confirmation)
        .navigationDestination(item: $jobRoute) { route in
            AppRouteDestination(route: route)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: QuoteDetailSheet) -> some View {
        if let data = state.value {
            switch sheet {
            case .edit(let draft):
                QuoteBuilderView(draft: draft) { _ in
                    Task { await load() }
                }
            case .send:
                QuoteSendSheet(quote: data.quote, customer: data.customer) {
                    await load()
                }
            case .approve:
                QuoteResponseSheet(
                    quote: data.quote,
                    customer: data.customer,
                    lines: data.lines,
                    options: data.options,
                    isApproval: true
                ) {
                    await load()
                }
            case .decline:
                QuoteResponseSheet(
                    quote: data.quote,
                    customer: data.customer,
                    lines: data.lines,
                    options: data.options,
                    isApproval: false
                ) {
                    await load()
                }
            case .convert:
                QuoteConvertSheet(quote: data.quote, lines: data.countedLines) { jobID in
                    pendingJobRoute = .job(jobID)
                    Task { await load() }
                }
            }
        }
    }

    private func handle(_ action: QuoteDetailAction, data: QuoteService.DetailData) {
        switch action {
        case .edit:
            activeSheet = .edit(QuoteDraft(
                quote: data.quote,
                lines: data.lines,
                options: data.options,
                customer: data.customer,
                vehicle: data.vehicle
            ))
        case .send:
            activeSheet = .send
        case .approve:
            activeSheet = .approve
        case .decline:
            activeSheet = .decline
        case .convert:
            activeSheet = .convert
        case .reviseToDraft:
            confirmation = ConfirmationRequest(
                title: "Revise to draft?",
                message: "The quote goes back to draft and its client link stops accepting answers until you send it again.",
                confirmTitle: "Revise"
            ) {
                await reviseToDraft()
            }
        case .delete:
            confirmation = ConfirmationRequest(
                title: "Delete \(data.quote.title)?",
                message: "This can't be undone.",
                confirmTitle: "Delete",
                isDestructive: true
            ) {
                await deleteQuote()
            }
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let id = quoteID
        let result = await LoadState<QuoteService.DetailData>.result {
            try await QuoteService.detail(shopID: shopID, quoteID: id)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    private func reviseToDraft() async {
        do {
            let shopID = try appState.requireShopID()
            try await QuoteService.reviseToDraft(shopID: shopID, quoteID: quoteID)
            toasts.show("Quote is a draft again")
            await load()
        } catch {
            toasts.showError(error)
        }
    }

    private func deleteQuote() async {
        do {
            let shopID = try appState.requireShopID()
            try await QuoteService.delete(shopID: shopID, quoteID: quoteID)
            toasts.show("Quote deleted")
            dismiss()
        } catch {
            toasts.showError(error)
        }
    }
}

// MARK: - Content

private struct QuoteDetailContent: View {
    let data: QuoteService.DetailData
    let currencyCode: String
    let clock: ShopClock
    let perform: (QuoteDetailAction) -> Void
    let onChanged: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                AnyView(QuoteHeaderSection(data: data, clock: clock))
                AnyView(QuoteLinesSection(data: data, currencyCode: currencyCode))
                if !data.options.isEmpty {
                    AnyView(MoneyQuoteOptionsSection(quote: data.quote, options: data.options, currencyCode: currencyCode))
                }
                AnyView(QuoteTotalsSection(data: data, currencyCode: currencyCode))
                AnyView(QuoteActionsSection(quote: data.quote, perform: perform))
                if QuoteDetailView.SelfScheduleSection.applies(to: data.quote) {
                    AnyView(QuoteDetailView.SelfScheduleSection(data: data, onChanged: onChanged))
                }
                if data.quote.status.isAwaitingCustomer {
                    AnyView(MoneyFollowupStatusRow(kind: .quote, documentID: data.quote.id, refreshKey: data.quote.updatedAt))
                }
                AnyView(QuoteNotesSection(quote: data.quote))
                AnyView(QuoteTimelineSection(quote: data.quote, clock: clock))
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }
}

private struct QuoteHeaderSection: View {
    let data: QuoteService.DetailData
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(data.quote.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(data.quote.status)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                customerRow
                if let vehicle = data.vehicle {
                    InfoRow(label: "Vehicle", value: vehicle.displayName, systemImage: "car")
                }
                if let validText {
                    InfoRow(label: "Valid until", value: validText, systemImage: "calendar")
                }
                if let name = data.quote.approvedByName, data.quote.status == .approved || data.quote.status == .converted {
                    InfoRow(label: "Approved by", value: name, systemImage: "signature")
                }
                if let reason = data.quote.declinedReason, data.quote.status == .declined {
                    InfoRow(label: "Declined", value: reason, systemImage: "xmark.circle")
                }
                if let job = data.convertedJob {
                    convertedJobRow(job)
                }
            }
            .cardStyle()
        }
    }

    /// "Customer scheduled · Job #1042" (or "Converted to Job #1042").
    private func convertedJobRow(_ job: QuoteService.ConvertedJobRef) -> some View {
        NavigationLink(value: AppRoute.job(job.id)) {
            HStack {
                InfoRow(
                    label: data.quote.selfScheduledAt != nil ? "Customer scheduled" : "Converted to",
                    value: jobText(job),
                    systemImage: data.quote.selfScheduledAt != nil ? "calendar.badge.checkmark" : "wrench.and.screwdriver"
                )
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the job")
    }

    private func jobText(_ job: QuoteService.ConvertedJobRef) -> String {
        var text = "Job #\(job.number)"
        if let start = job.scheduledStart {
            text += " · \(clock.shortDayText(start)), \(clock.timeText(start))"
        } else {
            text += " · \(job.status.displayName)"
        }
        return text
    }

    @ViewBuilder
    private var customerRow: some View {
        if let customer = data.customer {
            NavigationLink(value: AppRoute.customer(customer.id)) {
                HStack(spacing: Theme.Spacing.md) {
                    AvatarView(name: customer.displayName, size: Theme.Size.avatarSmall)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(customer.displayName)
                            .font(Theme.Typography.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        if let detail = customer.detailLine {
                            Text(detail)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the customer")
        } else {
            InfoRow(label: "Customer", value: "Not available", systemImage: "person")
        }
    }

    private var validText: String? {
        guard let validUntil = data.quote.validUntil,
              let day = clock.date(fromDateString: validUntil) else { return nil }
        return clock.shortDayText(day)
    }
}

private struct QuoteLinesSection: View {
    let data: QuoteService.DetailData
    let currencyCode: String

    var body: some View {
        MoneySectionCard("Items") {
            if data.lines.isEmpty {
                Text("No items yet. Edit the quote to add services.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else if data.options.isEmpty {
                lineRows(data.lines)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(group.title)
                            .font(Theme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        if group.lines.isEmpty {
                            Text(group.optionID == nil ? "No shared items." : "No items of its own.")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            lineRows(group.lines)
                        }
                    }
                }
            }
        }
    }

    /// Lines of one option (or the shared ones).
    struct LineGroup: Identifiable {
        let optionID: UUID?
        let title: String
        let lines: [QuoteLineItem]

        var id: String { optionID?.uuidString ?? "shared" }
    }

    /// Shared lines, then each option's own lines.
    private var groups: [LineGroup] {
        var result = [LineGroup(optionID: nil, title: "In every option", lines: data.lines.filter { $0.optionID == nil })]
        for option in data.options {
            result.append(LineGroup(optionID: option.id, title: option.name, lines: data.lines.filter { $0.optionID == option.id }))
        }
        return result
    }

    @ViewBuilder
    private func lineRows(_ lines: [QuoteLineItem]) -> some View {
        ForEach(lines) { line in
            MoneyLineRow(
                name: line.name,
                detail: line.lineDescription,
                quantity: line.quantity,
                unitPriceCents: line.unitPriceCents,
                discountCents: line.discountCents,
                totalCents: line.totalCents,
                currencyCode: currencyCode,
                badge: badge(line),
                note: note(line)
            )
            if line.id != lines.last?.id {
                Divider().overlay(Theme.border)
            }
        }
    }

    private func badge(_ line: QuoteLineItem) -> String? {
        if line.isOptional { return "Optional" }
        if line.feeID != nil { return "Fee" }
        return nil
    }

    private func note(_ line: QuoteLineItem) -> String? {
        var parts: [String] = []
        if line.isOptional {
            parts.append(line.isSelected
                ? "Chosen by the customer — included in the total."
                : "Not in the total unless the customer picks it.")
        }
        if !line.discountEligible && data.quote.discountKind != .none {
            parts.append("The quote discount doesn't apply to this item.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private struct QuoteTotalsSection: View {
    let data: QuoteService.DetailData
    let currencyCode: String

    private var quote: Quote { data.quote }

    var body: some View {
        MoneySectionCard("Totals") {
            if let optionName {
                Text("For \(optionName)")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            MoneyTotalsView(
                subtotalCents: quote.subtotalCents,
                discountCents: quote.discountCents,
                taxCents: quote.taxCents,
                taxRateBps: quote.taxRateBps,
                totalCents: quote.totalCents,
                currencyCode: currencyCode
            )
            if data.countedLines.count < data.lines.count {
                Text(data.options.isEmpty
                    ? "Optional items the customer hasn't picked are not included."
                    : "Other options' items, and optional items the customer hasn't picked, are not included.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var optionName: String? {
        guard let effective = data.effectiveOptionID else { return nil }
        return data.options.first(where: { $0.id == effective })?.name
    }
}

private struct QuoteNotesSection: View {
    let quote: Quote

    var body: some View {
        let notes = quote.notes?.trimmedNonEmpty
        let terms = quote.terms?.trimmedNonEmpty
        let internalNotes = quote.internalNotes?.trimmedNonEmpty
        if notes != nil || terms != nil || internalNotes != nil {
            MoneySectionCard("Notes & terms") {
                if let notes {
                    MoneyTextBlock(title: "Notes for the customer", text: notes)
                }
                if let terms {
                    MoneyTextBlock(title: "Terms", text: terms)
                }
                if let internalNotes {
                    MoneyTextBlock(title: "Internal notes (staff only)", text: internalNotes)
                }
            }
        }
    }
}

private struct QuoteTimelineSection: View {
    let quote: Quote
    let clock: ShopClock

    var body: some View {
        MoneySectionCard("Activity") {
            MoneyTimelineView(entries: entries, clock: clock)
        }
    }

    private var entries: [MoneyTimelineEntry] {
        var list: [MoneyTimelineEntry] = [
            MoneyTimelineEntry(id: "created", title: "Created", date: quote.createdAt),
        ]
        if let date = quote.sentAt {
            list.append(MoneyTimelineEntry(id: "sent", title: "Sent to customer", date: date))
        }
        if let date = quote.viewedAt {
            list.append(MoneyTimelineEntry(id: "viewed", title: "Viewed by customer", date: date))
        }
        if let date = quote.approvedAt {
            list.append(MoneyTimelineEntry(id: "approved", title: "Approved", date: date, detail: quote.approvedByName.map { "By \($0)" }))
        }
        if let date = quote.declinedAt {
            list.append(MoneyTimelineEntry(id: "declined", title: "Declined", date: date, detail: quote.declinedReason))
        }
        if let date = quote.expiredAt {
            list.append(MoneyTimelineEntry(id: "expired", title: "Expired", date: date))
        }
        if let date = quote.selfScheduledAt {
            list.append(MoneyTimelineEntry(id: "scheduled", title: "Scheduled online by the customer", date: date))
        }
        if let date = quote.convertedAt {
            list.append(MoneyTimelineEntry(id: "converted", title: "Converted to a job", date: date))
        }
        return list.sorted { $0.date < $1.date }
    }
}

// MARK: - Actions

private struct QuoteActionsSection: View {
    let quote: Quote
    let perform: (QuoteDetailAction) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            primaryActions
            shareLink
            MoneyPDFShareButton(kind: .quote, documentID: quote.id, number: quote.number)
            secondaryActions
        }
    }

    @ViewBuilder
    private var primaryActions: some View {
        switch quote.status {
        case .draft:
            Button("Send to customer") { perform(.send) }
                .buttonStyle(.themePrimary)
        case .sent, .viewed:
            Button("Record approval") { perform(.approve) }
                .buttonStyle(.themePrimary)
            Button("Resend") { perform(.send) }
                .buttonStyle(.themeSecondary)
        case .approved:
            Button("Convert to job") { perform(.convert) }
                .buttonStyle(.themePrimary)
        case .converted:
            if let jobID = quote.convertedJobID {
                NavigationLink(value: AppRoute.job(jobID)) {
                    Text("Open job")
                }
                .buttonStyle(.themePrimary)
            }
        case .declined, .expired:
            EmptyView()
        }
    }

    @ViewBuilder
    private var shareLink: some View {
        if quote.status != .draft && quote.status != .converted {
            if let url = MoneyLinks.quote(token: quote.publicToken) {
                ShareLink(item: url) {
                    Label("Share client link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.themeSecondary)
            } else {
                InlineMessage(text: "Client links need WEB_APP_URL in the app configuration.", kind: .info)
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if quote.isEditable {
            Button("Edit quote") { perform(.edit) }
                .buttonStyle(.themeSecondary)
        }
        if quote.status.isAwaitingCustomer {
            Button("Record decline") { perform(.decline) }
                .buttonStyle(.themeSecondary)
        }
        if quote.status == .approved || quote.status == .declined || quote.status == .expired {
            Button("Revise to draft") { perform(.reviseToDraft) }
                .buttonStyle(.themeSecondary)
        }
        if quote.status != .converted {
            Button(role: .destructive) {
                perform(.delete)
            } label: {
                Text("Delete quote")
                    .foregroundStyle(Theme.dangerInk)
            }
            .buttonStyle(.themePlain)
        }
    }
}
