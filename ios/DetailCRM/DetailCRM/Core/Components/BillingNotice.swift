//
//  BillingNotice.swift
//  DetailCRM
//
//  The shop's subscription status line on Today and in More (and, when the
//  shop is lapsed, on Memberships and the new-membership sheet, before a
//  sale the server would refuse): the owner's
//  trial end or a failing subscription payment, and for everyone the
//  "creating new records is paused" notice while the subscription is
//  inactive, with the reason when the trial ended or the shop never had a
//  subscription or trial (DetailCore `ShopEntitlement.notice`). Text only — no prices,
//  no plans, no buttons or links toward buying (App Store 3.1.1 / 3.1.3).
//  Nothing shows while billing is off, the shop is active or comped, or
//  the standing can't be read; it never holds up the screen it sits on.
//

import SwiftUI
import DetailCore

struct BillingNoticeBanner: View {
    let notice: ShopEntitlement.Notice
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(notice.isWarning ? Theme.warningInk : Theme.glacier)
                .accessibilityHidden(true)
            Text(notice.text(clock: clock))
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The lapsed-shop notice on a screen that offers to create something the
/// server will refuse while creating is paused (PT402), e.g. a new
/// membership: shows only `.paused` / `.trialEnded` / `.noSubscription`
/// (`Notice.pausesNewRecords`), with what it means on this screen. Text
/// only, like the status line on Today and More.
struct BillingPausedNotice: View {
    let notice: ShopEntitlement.Notice?
    let clock: ShopClock
    /// One line on what is paused here ("New memberships are paused too.").
    var detail: String?

    var body: some View {
        if let notice, notice.pausesNewRecords {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                BillingNoticeBanner(notice: notice, clock: clock)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
    }
}

extension View {
    /// Keeps `notice` in step with the shop's subscription standing: read
    /// when the screen appears, when the shop changes and when the app
    /// comes back to the foreground. A failed read shows nothing.
    func billingNotice(_ notice: Binding<ShopEntitlement.Notice?>, shopID: UUID?) -> some View {
        modifier(BillingNoticeLoader(notice: notice, shopID: shopID))
    }
}

private struct BillingNoticeLoader: ViewModifier {
    @Binding var notice: ShopEntitlement.Notice?
    let shopID: UUID?

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: shopID) { await reload() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await reload() }
            }
    }

    private func reload() async {
        guard let shopID else {
            notice = nil
            return
        }
        let loaded = await BillingService.notice(shopID: shopID)
        guard !Task.isCancelled else { return }
        notice = loaded
    }
}
