//
//  NotificationsView.swift
//  DetailCRM
//
//  The signed-in member's in-app notifications for the active shop:
//  unread first, then newest. Tapping one marks it read and, when it is
//  about a job, opens the job. Swipe to toggle read or dismiss; "Mark all
//  read" in the toolbar. Rows are created by the server (new bookings,
//  quote answers, payments, inbound messages, signed forms).
//

import SwiftUI
import DetailCore

struct NotificationsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<[AppNotification]> = .idle

    private var unreadCount: Int {
        state.value?.filter { $0.isUnread }.count ?? 0
    }

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading notifications…", retry: { await load() }) { items in
            NotificationsList(
                items: items,
                clock: appState.clock,
                onRefresh: { await load() },
                onOpen: { item in markRead(item) },
                onToggleRead: { item in toggleRead(item) },
                onDelete: { item in delete(item) }
            )
        }
        .screenBackground()
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all read") {
                    Task { @MainActor in
                        await markAllRead()
                    }
                }
                .disabled(unreadCount == 0)
            }
        }
        .task { await load() }
    }

    // MARK: - Loading

    private func load() async {
        let shopID: UUID
        do {
            shopID = try appState.requireShopID()
        } catch {
            state = .failed(ErrorText.message(for: error))
            return
        }
        state.beginLoading()
        let hadContent = state.value != nil
        let result = await LoadState<[AppNotification]>.result {
            NotificationService.sortedForDisplay(try await NotificationService.list(shopID: shopID))
        }
        if hadContent, let message = result.errorMessage {
            toasts.show(message, style: .error, duration: .seconds(5))
        }
        state.apply(result)
    }

    // MARK: - Mutations (optimistic, rolled back on failure)

    private func replace(_ item: AppNotification) {
        guard var items = state.value, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        state = .loaded(items)
    }

    /// Uses the current row (not the captured one) so a job page that
    /// appears again after a push/pop doesn't re-send the update.
    private func markRead(_ item: AppNotification) {
        let current = state.value?.first(where: { $0.id == item.id }) ?? item
        guard current.isUnread else { return }
        setRead(current, read: true)
    }

    private func toggleRead(_ item: AppNotification) {
        setRead(item, read: item.isUnread)
    }

    private func setRead(_ item: AppNotification, read: Bool) {
        guard let shopID = try? appState.requireShopID() else { return }
        var updated = item
        updated.readAt = read ? Date() : nil
        replace(updated)
        Task { @MainActor in
            do {
                try await NotificationService.setRead(shopID: shopID, id: item.id, read: read)
            } catch {
                replace(item)
                toasts.showError(error)
            }
        }
    }

    private func delete(_ item: AppNotification) {
        guard let shopID = try? appState.requireShopID(), let before = state.value else { return }
        state = .loaded(before.filter { $0.id != item.id })
        Task { @MainActor in
            do {
                try await NotificationService.delete(shopID: shopID, id: item.id)
            } catch {
                state = .loaded(before)
                toasts.showError(error)
            }
        }
    }

    private func markAllRead() async {
        do {
            let shopID = try appState.requireShopID()
            try await NotificationService.markAllRead(shopID: shopID)
            if let items = state.value {
                let now = Date()
                state = .loaded(items.map { item in
                    var copy = item
                    if copy.readAt == nil { copy.readAt = now }
                    return copy
                })
            }
        } catch {
            toasts.showError(error)
        }
    }
}

// MARK: - List

private struct NotificationsList: View {
    static func readActionTitle(_ item: AppNotification) -> String {
        item.isUnread ? "Read" : "Unread"
    }

    let items: [AppNotification]
    let clock: ShopClock
    let onRefresh: () async -> Void
    let onOpen: (AppNotification) -> Void
    let onToggleRead: (AppNotification) -> Void
    let onDelete: (AppNotification) -> Void

    var body: some View {
        if items.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "bell",
                    title: "You're all caught up",
                    message: "New bookings, quote answers, payments and messages will show up here."
                )
                .frame(minHeight: 360)
            }
            .refreshable { await onRefresh() }
        } else {
            List {
                ForEach(items) { item in
                    NotificationsRowLink(item: item, clock: clock, onOpen: onOpen)
                        .themedRow()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                onToggleRead(item)
                            } label: {
                                Label(NotificationsList.readActionTitle(item),
                                      systemImage: item.isUnread ? "envelope.open" : "envelope.badge")
                            }
                            .tint(Theme.glacier)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete(item)
                            } label: {
                                Label("Dismiss", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await onRefresh() }
        }
    }
}

/// A job notification opens the job and is marked read when the job
/// page appears — so every way of activating the link (tap, VoiceOver
/// double-tap, Switch Control, keyboard) marks it. Any other one is just
/// marked read on activation.
private struct NotificationsRowLink: View {
    let item: AppNotification
    let clock: ShopClock
    let onOpen: (AppNotification) -> Void

    var body: some View {
        if let jobID = item.jobID {
            NavigationLink {
                AppRouteDestination(route: AppRoute.job(jobID))
                    .onAppear { onOpen(item) }
            } label: {
                NotificationsRow(item: item, clock: clock)
            }
        } else {
            Button {
                onOpen(item)
            } label: {
                NotificationsRow(item: item, clock: clock)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NotificationsRow: View {
    let item: AppNotification
    let clock: ShopClock

    var body: some View {
        let kind = item.kindValue
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: kind.systemImage)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(iconColor(kind))
                    .frame(width: Theme.Size.avatarSmall, height: Theme.Size.avatarSmall)
                    .background(Circle().fill(iconColor(kind).opacity(0.14)))
                Circle()
                    .fill(Theme.glacier)
                    .frame(width: 9, height: 9)
                    .opacity(item.isUnread ? 1 : 0)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(item.title)
                        .font(item.isUnread ? Theme.Typography.bodyEmphasis : Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.sm)
                    Text(timeText)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let detail = item.body?.trimmedNonEmpty {
                    Text(detail)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
                Text(kind.displayName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// "9:30 AM" today, else "Yesterday" / "Tue, Mar 10" (shop zone).
    private var timeText: String {
        if clock.isSameDay(item.createdAt, Date()) {
            return clock.timeText(item.createdAt)
        }
        return clock.relativeDayText(item.createdAt)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if item.isUnread { parts.append("Unread") }
        parts.append(item.title)
        if let detail = item.body?.trimmedNonEmpty { parts.append(detail) }
        parts.append(timeText)
        return parts.joined(separator: ", ")
    }

    /// Money notifications use the money tone; everything else Glacier.
    private func iconColor(_ kind: AppNotificationKind) -> Color {
        switch kind {
        case .paymentReceived: return Theme.amber
        case .bookingCancelled, .quoteDeclined: return Theme.danger
        case .quoteApproved, .formSigned: return Theme.success
        case .newBooking, .inboundMessage, .general: return Theme.glacier
        }
    }
}
