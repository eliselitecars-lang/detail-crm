//
//  InboxView.swift
//  DetailCRM
//
//  Inbox tab (owner / admin / manager; technicians never see it — they send
//  templated job messages from the job screen). Conversations grouped by
//  customer with the latest message and unread count; refreshes on appear,
//  every 30 seconds while visible, and on pull to refresh.
//

import SwiftUI
import DetailCore

struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<[MessageThread]> = .idle
    @State private var showUnreadOnly = false
    @State private var search = ""
    @State private var showingNewConversation = false
    @State private var pendingCustomer: Customer?
    @State private var openedConversation: InboxOpenedConversation?
    /// A background refresh already reported a failure; stay quiet until a
    /// refresh succeeds again (no toast every 30 s while offline).
    @State private var pollFailureReported = false

    var body: some View {
        Group {
            if appState.can(.useInbox) {
                LoadStateView(state, loadingLabel: "Loading conversations…", retry: { await load() }) { threads in
                    InboxThreadList(
                        threads: filtered(threads),
                        totalCount: threads.count,
                        isFiltered: showUnreadOnly || search.trimmedNonEmpty != nil,
                        clock: appState.clock,
                        startConversation: { showingNewConversation = true }
                    )
                }
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Inbox is for managers",
                    message: "Send on-my-way and job-complete messages from the job screen."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Inbox")
        .searchable(text: $search, prompt: "Search conversations")
        .toolbar { toolbarContent }
        .task {
            guard appState.can(.useInbox) else { return }
            var isBackground = false
            while !Task.isCancelled {
                await load(isBackground: isBackground)
                isBackground = true
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .refreshable {
            await load()
        }
        .navigationDestination(for: MessageThread.self) { thread in
            InboxThreadView(key: thread.key, customer: thread.customer)
        }
        .navigationDestination(item: $openedConversation) { opened in
            InboxThreadView(key: .customer(opened.customer.id), customer: opened.customer)
        }
        .sheet(isPresented: $showingNewConversation, onDismiss: openPendingConversation) {
            InboxNewConversationSheet { customer in
                pendingCustomer = customer
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if appState.can(.useInbox) {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showUnreadOnly.toggle()
                } label: {
                    Image(systemName: showUnreadOnly ? "envelope.badge.fill" : "envelope.badge")
                }
                .accessibilityLabel(showUnreadOnly ? "Showing unread only" : "Show unread only")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
            }
        }
    }

    private func filtered(_ threads: [MessageThread]) -> [MessageThread] {
        var result = threads
        if showUnreadOnly {
            result = result.filter { $0.unreadCount > 0 }
        }
        if let term = search.trimmedNonEmpty?.lowercased() {
            let digits = term.filter { $0.isASCII && $0.isNumber }
            result = result.filter { thread in
                if thread.title.lowercased().contains(term) { return true }
                if let subtitle = thread.subtitle, subtitle.lowercased().contains(term) { return true }
                if thread.latest.preview.lowercased().contains(term) { return true }
                if digits.count >= 3, let phone = thread.customer?.phone, phone.contains(digits) { return true }
                if digits.count >= 3, case .unknownSender(let address) = thread.key, address.contains(digits) { return true }
                return false
            }
        }
        return result
    }

    /// `isBackground` = the 30-second poll: it never swaps an error screen
    /// for a spinner and reports a refresh failure at most once until a
    /// refresh succeeds. The first load, Retry and pull to refresh always
    /// surface their errors.
    private func load(isBackground: Bool = false) async {
        guard let shopID = try? appState.requireShopID() else { return }
        if !isBackground || state.errorMessage == nil {
            state.beginLoading()
        }
        let result = await LoadState<[MessageThread]>.result {
            try await MessageService.threads(shopID: shopID)
        }
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
    }

    private func openPendingConversation() {
        guard let customer = pendingCustomer else { return }
        pendingCustomer = nil
        openedConversation = InboxOpenedConversation(customer: customer)
    }
}

/// Push target for a conversation started from the New conversation sheet.
struct InboxOpenedConversation: Identifiable, Hashable {
    let customer: Customer

    var id: UUID { customer.id }
}

// MARK: - List

private struct InboxThreadList: View {
    let threads: [MessageThread]
    let totalCount: Int
    let isFiltered: Bool
    let clock: ShopClock
    let startConversation: () -> Void

    var body: some View {
        if threads.isEmpty {
            if isFiltered && totalCount > 0 {
                EmptyStateView(
                    systemImage: "tray",
                    title: "Nothing here",
                    message: "No conversations match. Clear the search or the unread filter."
                )
            } else {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No messages yet",
                    message: "Texts and emails with your customers show up here, including their replies.",
                    actionTitle: "Start a conversation",
                    action: startConversation
                )
            }
        } else {
            List {
                ForEach(threads) { thread in
                    NavigationLink(value: thread) {
                        InboxThreadRow(thread: thread, clock: clock)
                    }
                    .themedRow()
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct InboxThreadRow: View {
    let thread: MessageThread
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            AvatarView(name: thread.title, size: Theme.Size.avatarMedium)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(thread.title)
                        .font(isUnread ? Theme.Typography.bodyEmphasis : Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    Text(InboxFormatting.listTime(thread.latest.displayDate, clock: clock))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isUnread ? Theme.glacier : Theme.textTertiary)
                }
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Text(previewText)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(isUnread ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isUnread {
                        Text("\(thread.unreadCount)")
                            .font(Theme.Typography.captionEmphasis)
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(Capsule().fill(Theme.glacier))
                            .accessibilityLabel("\(thread.unreadCount) unread")
                    }
                }
                if case .unknownSender = thread.key {
                    Text("Not a saved customer")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var isUnread: Bool { thread.unreadCount > 0 }

    private var previewText: String {
        let latest = thread.latest
        var prefix = ""
        if !latest.isInbound { prefix += "You: " }
        if latest.channel == .email {
            prefix += "Email · "
        }
        if latest.status == .failed || latest.status == .cancelled {
            prefix = "Not delivered · " + prefix
        }
        return prefix + latest.preview
    }
}

// MARK: - Formatting

enum InboxFormatting {

    /// "9:41 AM" today, "Yesterday", else "Tue, Mar 10" (shop time zone).
    static func listTime(_ date: Date, clock: ShopClock, now: Date = Date()) -> String {
        if clock.isSameDay(date, now) { return clock.timeText(date) }
        return clock.relativeDayText(date, now: now)
    }
}
