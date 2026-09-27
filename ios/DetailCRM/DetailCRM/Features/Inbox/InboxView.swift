//
//  InboxView.swift
//  DetailCRM
//
//  Inbox tab (owner / admin / manager; technicians never see it — they send
//  templated job messages from the job screen). Conversations come from the
//  server (`inbox_threads`: latest message + unread count per customer or
//  unknown sender), 50 at a time; scrolling to the end loads older ones.
//  The first page refreshes on appear, every 30 seconds while visible and
//  on pull to refresh (older pages already loaded are kept).
//

import SwiftUI
import DetailCore

struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<InboxListData> = .idle
    @State private var loadingOlder = false
    @State private var olderError: String?
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
                LoadStateView(state, loadingLabel: "Loading conversations…", retry: { await load() }) { data in
                    InboxThreadList(
                        threads: filtered(data.threads),
                        totalCount: data.threads.count,
                        unreadTotal: data.unreadTotal,
                        isFiltered: showUnreadOnly || search.trimmedNonEmpty != nil,
                        olderCursor: data.nextBefore,
                        loadingOlder: loadingOlder,
                        olderError: olderError,
                        clock: appState.clock,
                        startConversation: { showingNewConversation = true },
                        loadOlder: { await loadOlder() }
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
            InboxThreadView(key: thread.key)
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
                if thread.preview.lowercased().contains(term) { return true }
                if digits.count >= 3, let address = thread.address, address.contains(digits) { return true }
                if digits.count >= 3, case .unknownSender(let address) = thread.key, address.contains(digits) { return true }
                return false
            }
        }
        return result
    }

    /// Loads the first page and the unread total. `isBackground` = the
    /// 30-second poll: it never swaps an error screen for a spinner and
    /// reports a refresh failure at most once until a refresh succeeds. The
    /// first load, Retry and pull to refresh always surface their errors.
    /// Older pages already on screen are kept.
    private func load(isBackground: Bool = false) async {
        guard let shopID = try? appState.requireShopID() else { return }
        if !isBackground || state.errorMessage == nil {
            state.beginLoading()
        }
        let result = await LoadState<InboxPage>.result {
            try await MessageService.inbox(shopID: shopID)
        }
        // The unread total is a badge: its failure never fails the list.
        let unread = try? await MessageService.unreadCount(shopID: shopID)
        switch result {
        case .loaded(let page):
            pollFailureReported = false
            let current = state.value ?? InboxListData()
            state = .loaded(current.refreshed(with: page, unreadTotal: unread ?? current.unreadTotal))
        case .failed(let message):
            if state.value != nil && (!isBackground || !pollFailureReported) {
                toasts.show(message, style: .error)
                if isBackground { pollFailureReported = true }
            }
            state.apply(.failed(message))
        case .idle, .loading:
            state.apply(.idle)
        }
    }

    /// The next (older) page, when the list scrolls to its end.
    private func loadOlder() async {
        guard !loadingOlder, let shopID = try? appState.requireShopID(),
              let current = state.value, let before = current.nextBefore else { return }
        loadingOlder = true
        olderError = nil
        defer { loadingOlder = false }
        do {
            let page = try await MessageService.inbox(shopID: shopID, before: before)
            // A refresh may have replaced the list meanwhile; merge into the latest.
            let latest = state.value ?? current
            state = .loaded(latest.appending(page))
        } catch is CancellationError {
            return
        } catch {
            olderError = ErrorText.message(for: error)
        }
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
    let unreadTotal: Int?
    let isFiltered: Bool
    /// The next page's cursor (nil when every conversation is loaded).
    let olderCursor: Date?
    let loadingOlder: Bool
    let olderError: String?
    let clock: ShopClock
    let startConversation: () -> Void
    let loadOlder: () async -> Void

    var body: some View {
        if threads.isEmpty && !(isFiltered && olderCursor != nil) {
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
                if let unreadTotal, unreadTotal > 0 {
                    Text(unreadTotal == 1 ? "1 unread message" : "\(unreadTotal) unread messages")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                }
                ForEach(threads) { thread in
                    NavigationLink(value: thread) {
                        InboxThreadListRow(thread: thread, clock: clock)
                    }
                    .themedRow()
                }
                if let olderCursor {
                    InboxOlderFooter(
                        cursor: olderCursor,
                        isFiltered: isFiltered,
                        loading: loadingOlder,
                        error: olderError,
                        loadOlder: loadOlder
                    )
                    .themedRow()
                }
            }
            .listStyle(.plain)
        }
    }
}

/// End of the loaded conversations: loads the next page as it scrolls into
/// view (unless the last attempt failed — then only on tap).
private struct InboxOlderFooter: View {
    let cursor: Date
    let isFiltered: Bool
    let loading: Bool
    let error: String?
    let loadOlder: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let error {
                InlineMessage(text: error, kind: .error)
            } else if isFiltered {
                Text("Only loaded conversations are searched. Load older ones to search further.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loading {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().tint(Theme.glacier)
                    Text("Loading older conversations…")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                AsyncButton("Load older conversations", style: .themeSecondaryCompact) {
                    await loadOlder()
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task(id: cursor) {
            // Scrolled into view (or a page loaded while it stays in view):
            // fetch the next page automatically.
            if error == nil && !isFiltered {
                await loadOlder()
            }
        }
    }
}

/// The conversations on screen plus the paging cursor.
struct InboxListData: Sendable {
    var threads: [MessageThread] = []
    /// `before` for the next (older) page; nil when everything is loaded.
    var nextBefore: Date?
    /// `inbox_unread_count` (nil when it could not be read).
    var unreadTotal: Int?

    /// A fresh first page replaces the newest conversations; older pages
    /// already loaded (strictly older than the fresh page) are kept with
    /// their cursor.
    func refreshed(with first: InboxPage, unreadTotal: Int?) -> InboxListData {
        guard let boundary = first.nextBefore else {
            return InboxListData(threads: first.threads, nextBefore: nil, unreadTotal: unreadTotal)
        }
        let freshIDs = Set(first.threads.map { $0.id })
        let older = threads.filter { !freshIDs.contains($0.id) && $0.lastCreatedAt < boundary }
        if older.isEmpty {
            return InboxListData(threads: first.threads, nextBefore: first.nextBefore, unreadTotal: unreadTotal)
        }
        return InboxListData(threads: first.threads + older, nextBefore: nextBefore, unreadTotal: unreadTotal)
    }

    /// Adds an older page (a conversation already listed keeps its newer row).
    func appending(_ page: InboxPage) -> InboxListData {
        let known = Set(threads.map { $0.id })
        var merged = self
        merged.threads += page.threads.filter { !known.contains($0.id) }
        merged.nextBefore = page.nextBefore
        return merged
    }
}

private struct InboxThreadListRow: View {
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
                    Text(InboxFormatting.listTime(thread.lastCreatedAt, clock: clock))
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
        var prefix = ""
        if !thread.isLastInbound { prefix += "You: " }
        if thread.lastChannel == .email {
            prefix += "Email · "
        }
        if thread.lastStatus == .failed || thread.lastStatus == .cancelled {
            prefix = "Not delivered · " + prefix
        }
        return prefix + thread.preview
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
