//
//  InboxThreadView.swift
//  DetailCRM
//
//  One conversation: message bubbles (inbound left, outbound right, with
//  delivery status and times in the shop time zone), an opt-out banner,
//  and a composer for free-form texts/emails or shop templates. Inbound
//  messages are marked read when shown. Refreshes every 15 seconds while
//  open.
//

import SwiftUI
import DetailCore

struct InboxThreadView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var key: MessageThreadKey
    @State private var customer: Customer?
    @State private var state: LoadState<[Message]> = .idle
    @State private var channel: Message.Channel
    @State private var draftBody = ""
    @State private var draftSubject = ""
    @State private var didChooseChannel: Bool
    @State private var showingTemplates = false
    @State private var showingAddCustomer = false
    /// A background refresh already reported a failure; stay quiet until a
    /// refresh succeeds again (no toast every 15 s while offline).
    @State private var pollFailureReported = false

    init(key: MessageThreadKey, customer: Customer? = nil) {
        _key = State(initialValue: key)
        _customer = State(initialValue: customer)
        _channel = State(initialValue: InboxComposeRules.preferredChannel(for: customer))
        _didChooseChannel = State(initialValue: customer != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            AnyView(InboxThreadBanner(
                key: key,
                customer: customer,
                channel: channel,
                canAddCustomer: appState.can(.editCustomers),
                addCustomer: { showingAddCustomer = true }
            ))
            LoadStateView(state, loadingLabel: "Loading messages…", retry: { await loadMessages() }) { messages in
                InboxMessageList(messages: messages, clock: appState.clock)
            }
            .frame(maxHeight: .infinity)
            .refreshable {
                await loadMessages()
            }
            if key.customerID != nil {
                AnyView(InboxComposer(
                    customer: customer,
                    channel: $channel,
                    draftBody: $draftBody,
                    draftSubject: $draftSubject,
                    send: { await send() },
                    openTemplates: { showingTemplates = true }
                ))
            }
        }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: key) {
            await loadCustomerIfNeeded()
            var isBackground = false
            while !Task.isCancelled {
                await loadMessages(isBackground: isBackground)
                isBackground = true
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $showingTemplates) {
            if let customer {
                InboxTemplatePickerSheet(customer: customer, initialChannel: channel) { result in
                    templateSent(result)
                }
            }
        }
        .sheet(isPresented: $showingAddCustomer) {
            if case .unknownSender(let address) = key {
                CustomerEditorSheet(mode: .create, suggestions: [], prefillPhone: address) { created in
                    customerCreated(created)
                }
            }
        }
    }

    private var title: String {
        switch key {
        case .customer:
            return customer?.displayName ?? "Conversation"
        case .unknownSender(let address):
            return PhoneNumber.format(address)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let customerID = key.customerID {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: AppRoute.customer(customerID)) {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Customer details")
            }
        }
    }

    // MARK: Loading

    /// Loads (or refreshes) the customer: opt-outs and addresses decide
    /// which channels the composer offers.
    private func loadCustomerIfNeeded() async {
        guard let customerID = key.customerID,
              let shopID = try? appState.requireShopID() else { return }
        if let loaded = try? await CustomerService.fetch(shopID: shopID, customerID: customerID) {
            customer = loaded
            if !didChooseChannel {
                channel = InboxComposeRules.preferredChannel(for: loaded)
                didChooseChannel = true
            }
        }
    }

    /// `isBackground` = the 15-second poll: it never swaps the error screen
    /// (with its Retry button) for a spinner and reports a refresh failure
    /// at most once until a refresh succeeds. The first load, Retry and pull
    /// to refresh always surface their errors.
    private func loadMessages(isBackground: Bool = false) async {
        guard let shopID = try? appState.requireShopID() else { return }
        let threadKey = key
        if !isBackground || state.errorMessage == nil {
            state.beginLoading()
        }
        let result = await LoadState<[Message]>.result {
            try await MessageService.messages(shopID: shopID, thread: threadKey)
        }
        guard threadKey == key else { return }
        switch result {
        case .loaded:
            pollFailureReported = false
        case .failed(let message):
            if state.value != nil && (!isBackground || !pollFailureReported) {
                toasts.show(message, style: .error)
                if isBackground { pollFailureReported = true }
            }
        case .idle, .loading:
            break
        }
        state.apply(result)
        if let messages = result.value, messages.contains(where: { $0.isUnread }) {
            await markRead(shopID: shopID, key: threadKey)
        }
    }

    /// Marks the conversation read on the server, then locally.
    private func markRead(shopID: UUID, key threadKey: MessageThreadKey) async {
        do {
            try await MessageService.markRead(shopID: shopID, thread: threadKey)
            guard threadKey == key, var messages = state.value else { return }
            let now = Date()
            for index in messages.indices where messages[index].isUnread {
                messages[index].readAt = now
            }
            state = .loaded(messages)
        } catch {
            // Not worth interrupting the conversation; the next refresh retries.
        }
    }

    // MARK: Sending

    private func send() async {
        guard let customerID = key.customerID, let shopID = try? appState.requireShopID() else { return }
        if let reason = InboxComposeRules.blockReason(channel: channel, customer: customer) {
            toasts.show(reason, style: .error)
            return
        }
        if let problem = InboxComposeRules.draftProblem(channel: channel, body: draftBody) {
            toasts.show(problem, style: .error)
            return
        }
        do {
            let result = try await MessageService.send(
                shopID: shopID,
                customerID: customerID,
                channel: channel,
                subject: channel == .email ? draftSubject : nil,
                body: draftBody
            )
            draftBody = ""
            draftSubject = ""
            report(result)
            await loadMessages()
        } catch {
            toasts.showError(error)
        }
    }

    private func templateSent(_ result: InboxSendResult) {
        report(result)
        Task { await loadMessages() }
    }

    private func report(_ result: InboxSendResult) {
        if result.didFail {
            toasts.show("The message couldn't be delivered. See the details under it.", style: .error)
        } else if result.status == .queued {
            toasts.show("Queued — it will be retried shortly.", style: .info)
        } else {
            toasts.show(result.channel == .sms ? "Text sent" : "Email sent")
        }
    }

    private func customerCreated(_ created: Customer) {
        toasts.show("Customer added")
        // The server attaches this number's earlier texts to the new
        // customer, so the conversation continues under their name.
        customer = created
        channel = InboxComposeRules.preferredChannel(for: created)
        didChooseChannel = true
        state = .idle
        key = .customer(created.id)
    }
}

// MARK: - Banner

private struct InboxThreadBanner: View {
    let key: MessageThreadKey
    let customer: Customer?
    let channel: Message.Channel
    let canAddCustomer: Bool
    let addCustomer: () -> Void

    var body: some View {
        if case .unknownSender = key {
            banner(
                text: "This number isn't saved as a customer. Add them to reply and keep their history.",
                systemImage: "person.crop.circle.badge.questionmark",
                actionTitle: canAddCustomer ? "Add customer" : nil
            )
        } else if let customer, channel == .sms, customer.hasSmsOptOut {
            banner(
                text: "Texts are off: this customer replied STOP. They can text START to opt back in.",
                systemImage: "nosign",
                actionTitle: nil
            )
        } else if let customer, channel == .email, customer.hasEmailOptOut {
            banner(
                text: "This customer unsubscribed from email.",
                systemImage: "nosign",
                actionTitle: nil
            )
        }
    }

    private func banner(text: String, systemImage: String, actionTitle: String?) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(text)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle {
                    Button(actionTitle, action: addCustomer)
                        .buttonStyle(.themeSecondaryCompact)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.fill(for: .warning))
    }
}

// MARK: - Messages

/// Messages of one shop-local day.
struct InboxDaySection: Identifiable {
    let id: Date
    let title: String
    let messages: [Message]
}

private struct InboxMessageList: View {
    let messages: [Message]
    let clock: ShopClock

    var body: some View {
        if messages.isEmpty {
            EmptyStateView(
                systemImage: "bubble.left",
                title: "No messages yet",
                message: "Say hello below — texts and emails you send appear here, and so do replies."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(Theme.Typography.captionEmphasis)
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Theme.Spacing.sm)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.messages) { message in
                                InboxMessageBubble(message: message, clock: clock)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.md)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    scrollToEnd(proxy, animated: false)
                }
                .onChange(of: messages.last?.id) {
                    scrollToEnd(proxy, animated: true)
                }
            }
        }
    }

    private var sections: [InboxDaySection] {
        var result: [InboxDaySection] = []
        var currentDay: Date?
        var bucket: [Message] = []
        for message in messages {
            let day = clock.startOfDay(message.displayDate)
            if let currentDay, currentDay != day {
                result.append(InboxDaySection(id: currentDay, title: clock.relativeDayText(currentDay), messages: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(message)
        }
        if let currentDay, !bucket.isEmpty {
            result.append(InboxDaySection(id: currentDay, title: clock.relativeDayText(currentDay), messages: bucket))
        }
        return result
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last?.id else { return }
        if animated {
            withAnimation(Theme.Motion.standard) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct InboxMessageBubble: View {
    let message: Message
    let clock: ShopClock

    private var isOutbound: Bool { !message.isInbound }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOutbound { Spacer(minLength: Theme.Spacing.xxl + Theme.Spacing.lg) }
            VStack(alignment: isOutbound ? .trailing : .leading, spacing: Theme.Spacing.xxs) {
                bubble
                metaLine
                if let error = failureText {
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(isOutbound ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isOutbound { Spacer(minLength: Theme.Spacing.xxl + Theme.Spacing.lg) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if message.channel == .email, let subject = message.subject?.trimmedNonEmpty {
                Text(subject)
                    .font(Theme.Typography.subheadline.weight(.semibold))
            }
            Text(message.body.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isOutbound ? Theme.onAccent : Theme.textPrimary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isOutbound ? Theme.glacier : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isOutbound ? Color.clear : Theme.border, lineWidth: Theme.Size.hairline)
        )
        .opacity(message.status == .cancelled ? 0.6 : 1)
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: message.channel.systemImage)
                .accessibilityHidden(true)
            Text(clock.timeText(message.displayDate))
            if isOutbound {
                Text("·")
                Text(message.status.displayName)
                    .foregroundStyle(Theme.color(for: message.status.tone))
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.textTertiary)
    }

    private var failureText: String? {
        guard isOutbound, message.status == .failed || message.status == .cancelled else { return nil }
        if let error = message.error?.trimmedNonEmpty {
            return "Not delivered: " + error
        }
        return message.status == .cancelled
            ? "Not sent (the customer opted out or the send was withdrawn)."
            : "Not delivered."
    }

    private var accessibilityText: String {
        let who = isOutbound ? "You" : "Customer"
        let status = isOutbound ? ", " + message.status.displayName : ""
        return "\(who), \(message.channel.displayName), \(clock.timeText(message.displayDate))\(status): \(message.body)"
    }
}

// MARK: - Composer

private struct InboxComposer: View {
    let customer: Customer?
    @Binding var channel: Message.Channel
    @Binding var draftBody: String
    @Binding var draftSubject: String
    let send: () async -> Void
    let openTemplates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Send as", selection: $channel) {
                ForEach(Message.Channel.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if let reason = blockReason {
                InlineMessage(text: reason, kind: .info)
            } else {
                if channel == .email {
                    TextField("Subject (optional)", text: $draftSubject)
                        .font(Theme.Typography.subheadline)
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(minHeight: Theme.Size.compactControlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.surfaceMuted)
                        )
                }
                HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                    Button(action: openTemplates) {
                        Image(systemName: "text.badge.plus")
                            .font(Theme.Typography.headline)
                            .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.glacier)
                    .accessibilityLabel("Use a template")
                    TextField(channel == .sms ? "Text message" : "Email message", text: $draftBody, axis: .vertical)
                        .font(Theme.Typography.body)
                        .lineLimit(1...6)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.surfaceMuted)
                        )
                    InboxSendButton(isEnabled: canSend, send: send)
                }
                if channel == .sms && smsLength > 140 {
                    Text("\(smsLength)/\(InboxComposeRules.smsLimit) characters")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(smsLength > InboxComposeRules.smsLimit ? Theme.danger : Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Size.hairline)
        }
    }

    private var blockReason: String? {
        InboxComposeRules.blockReason(channel: channel, customer: customer)
    }

    private var canSend: Bool {
        InboxComposeRules.draftProblem(channel: channel, body: draftBody) == nil
    }

    /// Length of the draft as the server counts it — the same trimmed text
    /// `InboxComposeRules.draftProblem` checks against `smsLimit`.
    private var smsLength: Int {
        InboxComposeRules.smsLength(draftBody.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Round send button that shows a spinner while sending.
private struct InboxSendButton: View {
    let isEnabled: Bool
    let send: () async -> Void

    @State private var isSending = false

    var body: some View {
        Button {
            guard !isSending else { return }
            isSending = true
            Task { @MainActor in
                await send()
                isSending = false
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.glacier)
                    .opacity(isSending ? 0 : 1)
                ProgressView()
                    .tint(Theme.glacier)
                    .opacity(isSending ? 1 : 0)
            }
            .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isSending)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(isSending ? "Sending" : "Send")
    }
}
