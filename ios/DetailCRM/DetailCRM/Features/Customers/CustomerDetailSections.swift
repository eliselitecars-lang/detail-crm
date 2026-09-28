//
//  CustomerDetailSections.swift
//  DetailCRM
//
//  The sections of the customer screen. The content is split into small
//  subviews joined by AnyView seams (deep generic view types on long
//  screens have crashed at runtime before — see ios/README.md).
//

import SwiftUI
import DetailCore

struct CustomerDetailContent: View {
    let customer: Customer
    let history: CustomerDetailHistory
    let permissions: CustomerDetailPermissions
    let clock: ShopClock
    let currencyCode: String
    let categories: [VehicleCategory]
    let actions: CustomerDetailActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                AnyView(CustomerHeaderCard(customer: customer, clock: clock))
                AnyView(CustomerPrimaryActions(customer: customer, permissions: permissions, newJob: actions.newJob))
                AnyView(CustomerContactDetails(customer: customer))
                AnyView(CustomerTagsAndNotes(customer: customer))
                AnyView(OpsCustomerCustomDataSection(
                    customer: customer,
                    fields: history.customFields,
                    canEdit: permissions.canEdit,
                    retry: actions.retryCustomFields,
                    onSaved: actions.customerUpdated
                ))
                if permissions.canSeeSummary {
                    AnyView(CustomerSummarySection(
                        state: history.summary,
                        clock: clock,
                        currencyCode: currencyCode,
                        retry: actions.retrySummary
                    ))
                }
                AnyView(CustomerVehiclesSection(
                    state: history.vehicles,
                    categories: categories,
                    canEdit: permissions.canEdit,
                    add: actions.addVehicle,
                    edit: actions.editVehicle,
                    retry: actions.retryHistory
                ))
                AnyView(CustomerJobsSection(
                    state: history.jobs,
                    showTotals: permissions.canSeeJobTotals,
                    clock: clock,
                    currencyCode: currencyCode,
                    retry: actions.retryHistory
                ))
                if permissions.canManageDocuments {
                    AnyView(OpsCustomerDocumentsSection(customerID: customer.id, canManage: permissions.canManageDocuments))
                }
                if permissions.canUseReferrals && history.referralProgramOn {
                    AnyView(OpsReferralCodeRow(customer: customer))
                }
                AnyView(moneySections)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// Quotes, invoices, memberships and cards — only for roles that
    /// handle money.
    private var moneySections: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if permissions.canSeeQuotes {
                AnyView(CustomerQuotesSection(state: history.quotes, clock: clock, currencyCode: currencyCode, retry: actions.retryHistory))
            }
            if permissions.canSeeInvoices {
                AnyView(CustomerInvoicesSection(state: history.invoices, clock: clock, currencyCode: currencyCode, retry: actions.retryHistory))
            }
            if permissions.canSeeMemberships {
                AnyView(CustomerMembershipsSection(state: history.memberships, clock: clock, currencyCode: currencyCode, retry: actions.retryHistory))
            }
            if permissions.canSeeSavedCards {
                AnyView(CustomerSavedCardsSection(
                    state: history.savedCards,
                    canRemove: permissions.canRemoveCards,
                    canAdd: permissions.canAddCards && !customer.isArchived,
                    remove: actions.removeCard,
                    add: actions.addCard,
                    retry: actions.retryHistory
                ))
            }
        }
    }
}

// MARK: - Header

private struct CustomerHeaderCard: View {
    let customer: Customer
    let clock: ShopClock

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                AvatarView(name: customer.displayName, size: Theme.Size.avatarLarge)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(customer.displayName)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let company = customer.secondaryCompany {
                        Text(company)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        StatusBadge(
                            text: customer.lifecycle.displayName,
                            tone: customer.lifecycle == .lead ? .warning : .info
                        )
                        if customer.mergedIntoID != nil {
                            StatusBadge(text: "Merged", tone: .neutral)
                        } else if customer.isArchived {
                            StatusBadge(text: "Archived", tone: .neutral)
                        }
                    }
                    Text("Since \(CustomersFormatting.sinceText(customer.createdAt, clock: clock)) · \(customer.source.displayName)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            if let survivorID = customer.mergedIntoID {
                NavigationLink(value: AppRoute.customer(survivorID)) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(Theme.glacier)
                            .accessibilityHidden(true)
                        Text("This duplicate was merged into another customer. Their vehicles, jobs and history are there now.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the customer it was merged into")
            }
            HStack(spacing: Theme.Spacing.sm) {
                CustomerContactButton(title: "Call", systemImage: "phone.fill", isEnabled: callURL != nil) {
                    if let callURL { openURL(callURL) }
                }
                CustomerContactButton(title: "Text", systemImage: "message.fill", isEnabled: textURL != nil) {
                    if let textURL { openURL(textURL) }
                }
                CustomerContactButton(title: "Email", systemImage: "envelope.fill", isEnabled: emailURL != nil) {
                    if let emailURL { openURL(emailURL) }
                }
                CustomerContactButton(title: "Directions", systemImage: "map.fill", isEnabled: mapURL != nil) {
                    if let mapURL { openURL(mapURL) }
                }
            }
        }
        .cardStyle()
    }

    private var callURL: URL? { customer.phone.flatMap { ContactLinks.call($0) } }
    private var textURL: URL? { customer.phone.flatMap { ContactLinks.text($0) } }
    private var emailURL: URL? { customer.email.flatMap { ContactLinks.email($0) } }
    private var mapURL: URL? { customer.addressSummary.flatMap { MapLinks.directions(toAddress: $0) } }
}

// MARK: - Primary actions

private struct CustomerPrimaryActions: View {
    let customer: Customer
    let permissions: CustomerDetailPermissions
    let newJob: () -> Void

    var body: some View {
        if permissions.canCreateJobs || permissions.canMessage {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                AdaptiveButtonRow(spacing: Theme.Spacing.md) {
                    if permissions.canCreateJobs && !customer.isArchived {
                        Button(action: newJob) {
                            Label("New job", systemImage: "plus")
                        }
                        .buttonStyle(.themePrimary)
                    }
                    if permissions.canMessage {
                        NavigationLink {
                            InboxThreadView(key: .customer(customer.id), customer: customer)
                        } label: {
                            Label("Message", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.themeSecondary)
                    }
                }
                if customer.hasSmsOptOut {
                    InlineMessage(text: "This customer opted out of text messages.", kind: .info)
                }
            }
        }
    }
}

// MARK: - Contact details

private struct CustomerContactDetails: View {
    let customer: Customer

    var body: some View {
        if customer.formattedPhone != nil || customer.email?.trimmedNonEmpty != nil || customer.addressSummary != nil {
            CustomersSectionCard("Contact") {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if let phone = customer.formattedPhone {
                        CustomerCopyableRow(systemImage: "phone", label: "Mobile", value: phone)
                    }
                    if let email = customer.email?.trimmedNonEmpty {
                        CustomerCopyableRow(systemImage: "envelope", label: "Email", value: email)
                    }
                    if let address = customer.addressSummary {
                        CustomerCopyableRow(systemImage: "mappin.and.ellipse", label: "Address", value: address)
                    }
                }
            }
        }
    }
}

/// Label + value with a long-press Copy menu.
private struct CustomerCopyableRow: View {
    let systemImage: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(value)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tags & notes

private struct CustomerTagsAndNotes: View {
    let customer: Customer

    var body: some View {
        if !customer.tags.isEmpty || customer.notes?.trimmedNonEmpty != nil {
            CustomersSectionCard("Tags & notes") {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if !customer.tags.isEmpty {
                        CustomerTagRow(tags: customer.tags)
                    }
                    if let notes = customer.notes?.trimmedNonEmpty {
                        Text(notes)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Vehicles

private struct CustomerVehiclesSection: View {
    let state: LoadState<[Vehicle]>
    let categories: [VehicleCategory]
    let canEdit: Bool
    let add: () -> Void
    let edit: (Vehicle) -> Void
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Vehicles", actionTitle: canEdit ? "Add" : nil, action: canEdit ? add : nil) {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let vehicles):
                if vehicles.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No vehicles yet."))
                } else {
                    ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, vehicle in
                        if index > 0 { CustomersRowDivider() }
                        if canEdit {
                            Button {
                                edit(vehicle)
                            } label: {
                                CustomerVehicleRow(vehicle: vehicle, categoryName: categoryName(vehicle), showsChevron: true)
                            }
                            .buttonStyle(.themeRow)
                            .accessibilityHint("Edit vehicle")
                        } else {
                            CustomerVehicleRow(vehicle: vehicle, categoryName: categoryName(vehicle), showsChevron: false)
                        }
                    }
                }
            }
        }
    }

    private func categoryName(_ vehicle: Vehicle) -> String? {
        guard let id = vehicle.categoryID else { return nil }
        return categories.first(where: { $0.id == id })?.name
    }
}

private struct CustomerVehicleRow: View {
    let vehicle: Vehicle
    let categoryName: String?
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "car.side")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.glacier)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(vehicle.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                if let detail = detailText {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let vin = vehicle.vin?.trimmedNonEmpty {
                    Text("VIN \(vin)")
                        .font(Theme.Typography.caption.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detailText: String? {
        let parts = [vehicle.detailLine, categoryName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Jobs

private struct CustomerJobsSection: View {
    let state: LoadState<[CustomerJobSummary]>
    let showTotals: Bool
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    @State private var showAll = false

    private let collapsedCount = 5

    var body: some View {
        CustomersSectionCard("Jobs") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let jobs):
                if jobs.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No jobs yet."))
                } else {
                    let visible = showAll ? jobs : Array(jobs.prefix(collapsedCount))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { CustomersRowDivider() }
                        NavigationLink(value: AppRoute.job(job.id)) {
                            CustomerJobRow(job: job, showTotal: showTotals, clock: clock, currencyCode: currencyCode)
                        }
                        .buttonStyle(.themeRow)
                    }
                    if jobs.count > collapsedCount {
                        CustomersRowDivider()
                        let toggleTitle: String = showAll ? "Show fewer" : "Show all \(jobs.count) jobs"
                        Button(toggleTitle) {
                            showAll.toggle()
                        }
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.glacier)
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }
            }
        }
    }
}

private struct CustomerJobRow: View {
    let job: CustomerJobSummary
    let showTotal: Bool
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(CustomersFormatting.jobTitle(job.number))
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    StatusBadge(job.status)
                }
                Text(whenText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if showTotal {
                MoneyText(cents: job.totalCents, currencyCode: currencyCode, size: .small, emphasis: .secondary)
            }
            Image(systemName: "chevron.right")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var whenText: String {
        guard let start = job.scheduledStart else { return "Not scheduled yet" }
        return clock.relativeDayText(start) + ", " + clock.timeText(start)
    }
}

// MARK: - Quotes

private struct CustomerQuotesSection: View {
    let state: LoadState<[CustomerQuoteSummary]>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Quotes") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let quotes):
                if quotes.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No quotes yet."))
                } else {
                    ForEach(Array(quotes.enumerated()), id: \.element.id) { index, quote in
                        if index > 0 { CustomersRowDivider() }
                        NavigationLink(value: AppRoute.quote(quote.id)) {
                            CustomerMoneyDocumentRow(
                                title: CustomersFormatting.quoteTitle(quote.number),
                                badge: StatusBadge(quote.status),
                                detail: quoteDetail(quote),
                                amountCents: quote.totalCents,
                                attention: false,
                                currencyCode: currencyCode
                            )
                        }
                        .buttonStyle(.themeRow)
                    }
                }
            }
        }
    }

    private func quoteDetail(_ quote: CustomerQuoteSummary) -> String {
        if let raw = quote.validUntil, let day = clock.date(fromDateString: raw),
           quote.status == .sent || quote.status == .viewed || quote.status == .draft {
            return "Valid through " + CustomersFormatting.dayText(day, clock: clock)
        }
        return "Created " + CustomersFormatting.dayText(quote.createdAt, clock: clock)
    }
}

// MARK: - Invoices

private struct CustomerInvoicesSection: View {
    let state: LoadState<[CustomerInvoiceSummary]>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Invoices") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let invoices):
                if invoices.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No invoices yet."))
                } else {
                    ForEach(Array(invoices.enumerated()), id: \.element.id) { index, invoice in
                        if index > 0 { CustomersRowDivider() }
                        NavigationLink(value: AppRoute.invoice(invoice.id)) {
                            CustomerMoneyDocumentRow(
                                title: CustomersFormatting.invoiceTitle(invoice.number),
                                badge: StatusBadge(invoice.status),
                                detail: invoiceDetail(invoice),
                                amountCents: showsBalance(invoice) ? invoice.balanceCents : invoice.totalCents,
                                attention: showsBalance(invoice),
                                currencyCode: currencyCode
                            )
                        }
                        .buttonStyle(.themeRow)
                    }
                }
            }
        }
    }

    /// Open invoices show what is still due (amber); others their total.
    private func showsBalance(_ invoice: CustomerInvoiceSummary) -> Bool {
        (invoice.status == .open || invoice.status == .partiallyPaid) && invoice.balanceCents > 0
    }

    private func invoiceDetail(_ invoice: CustomerInvoiceSummary) -> String {
        if showsBalance(invoice) {
            if let due = invoice.dueAt {
                return "Balance due · due " + CustomersFormatting.dayText(due, clock: clock)
            }
            return "Balance due"
        }
        let date = invoice.issuedAt ?? invoice.createdAt
        return "Issued " + CustomersFormatting.dayText(date, clock: clock)
    }
}

/// Shared row for quotes and invoices.
private struct CustomerMoneyDocumentRow: View {
    let title: String
    let badge: StatusBadge
    let detail: String
    let amountCents: Int
    let attention: Bool
    let currencyCode: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    badge
                }
                Text(detail)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(
                cents: amountCents,
                currencyCode: currencyCode,
                size: .small,
                emphasis: attention ? .attention : .normal
            )
            Image(systemName: "chevron.right")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Memberships (read-only summary)

private struct CustomerMembershipsSection: View {
    let state: LoadState<[CustomerMembershipItem]>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Memberships") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let items):
                if items.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No memberships."))
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CustomersRowDivider() }
                        CustomerMembershipRow(item: item, clock: clock, currencyCode: currencyCode)
                    }
                }
            }
        }
    }
}

private struct CustomerMembershipRow: View {
    let item: CustomerMembershipItem
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(item.plan?.name ?? "Membership")
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    StatusBadge(item.membership.status)
                }
                if let detail = periodText {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            // The membership's own billing terms, not the plan's current price.
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                MoneyText(cents: item.membership.priceCents, currencyCode: currencyCode, size: .small)
                Text(item.membership.cadenceText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var periodText: String? {
        guard let end = item.membership.currentPeriodEnd else { return nil }
        switch item.membership.status {
        case .active, .pastDue:
            let day = CustomersFormatting.dayText(end, clock: clock)
            return item.membership.cancelAtPeriodEnd ? "Ends " + day : "Renews " + day
        case .incomplete, .cancelled:
            return nil
        }
    }
}

// MARK: - Saved cards

private struct CustomerSavedCardsSection: View {
    let state: LoadState<[SavedCard]>
    let canRemove: Bool
    /// Managers and above can save a card without charging it.
    let canAdd: Bool
    let remove: (SavedCard) -> Void
    let add: () -> Void
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Saved cards") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let cards):
                if cards.isEmpty {
                    CustomersSectionStatusRow(kind: .empty("No saved cards."))
                } else {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { CustomersRowDivider() }
                        CustomerSavedCardRow(card: card, canRemove: canRemove, remove: { remove(card) })
                    }
                }
                if canAdd {
                    CustomersRowDivider()
                    Button(action: add) {
                        Label("Save a card", systemImage: "plus")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .accessibilityHint("The customer enters a card on this phone. Nothing is charged.")
                }
                CustomersRowDivider()
                Text(canAdd
                     ? "Cards are stored securely by Stripe. Save one here without charging it, then charge it from an invoice."
                     : "Cards are stored securely by Stripe. Charge them from an invoice.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Spacing.xxs)
            }
        }
    }
}

private struct CustomerSavedCardRow: View {
    let card: SavedCard
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "creditcard")
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(card.label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if card.isDefault {
                StatusBadge(text: "Default", tone: .neutral)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if canRemove {
                Button("Remove", role: .destructive, action: remove)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.dangerInk)
                    .accessibilityLabel("Remove \(card.label)")
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

// MARK: - Overview (customer_summary)

private struct CustomerSummarySection: View {
    let state: LoadState<CustomerSummary>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        CustomersSectionCard("Overview") {
            switch state {
            case .idle, .loading:
                CustomersSectionStatusRow(kind: .loading)
            case .failed(let message):
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            case .loaded(let summary):
                CustomerSummaryGrid(summary: summary, clock: clock, currencyCode: currencyCode)
            }
        }
    }
}

private struct CustomerSummaryGrid: View {
    let summary: CustomerSummary
    let clock: ShopClock
    let currencyCode: String

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md, alignment: .topLeading),
        GridItem(.flexible(), spacing: Theme.Spacing.md, alignment: .topLeading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.md) {
            CustomerSummaryTile(
                title: "Lifetime paid",
                value: Money.format(cents: summary.lifetimePaidCents, currencyCode: currencyCode),
                detail: summary.tipsCents > 0
                    ? "+ \(Money.format(cents: summary.tipsCents, currencyCode: currencyCode)) tips"
                    : nil,
                tone: .money
            )
            CustomerSummaryTile(
                title: "Open balance",
                value: Money.format(cents: summary.openBalanceCents, currencyCode: currencyCode),
                detail: summary.overdueBalanceCents > 0
                    ? "\(Money.format(cents: summary.overdueBalanceCents, currencyCode: currencyCode)) overdue"
                    : nil,
                tone: summary.overdueBalanceCents > 0 ? .danger : .plain
            )
            CustomerSummaryTile(
                title: "Completed jobs",
                value: "\(summary.completedJobs)",
                detail: summary.upcomingJobs > 0 ? "\(summary.upcomingJobs) upcoming" : nil,
                tone: .plain
            )
            CustomerSummaryTile(
                title: summary.nextJobAt != nil ? "Next job" : "Last visit",
                value: visitText,
                detail: summary.nextJobAt != nil ? lastVisitDetail : nil,
                tone: .plain
            )
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var visitText: String {
        if let next = summary.nextJobAt {
            return CustomersFormatting.dayText(next, clock: clock)
        }
        if let last = summary.lastVisitAt {
            return CustomersFormatting.dayText(last, clock: clock)
        }
        return "No visits yet"
    }

    private var lastVisitDetail: String? {
        summary.lastVisitAt.map { "Last visit " + CustomersFormatting.dayText($0, clock: clock) }
    }
}

private struct CustomerSummaryTile: View {
    enum Tone {
        case plain
        case money
        case danger
    }

    let title: String
    let value: String
    let detail: String?
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(tone == .plain ? Theme.Typography.headline : Theme.Typography.money)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(tone == .danger ? Theme.dangerInk : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var valueColor: Color {
        switch tone {
        case .plain: return Theme.textPrimary
        case .money: return Theme.moneyInk
        case .danger: return Theme.dangerInk
        }
    }
}
