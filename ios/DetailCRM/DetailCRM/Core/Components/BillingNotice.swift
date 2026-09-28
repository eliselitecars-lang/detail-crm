//
//  BillingNotice.swift
//  DetailCRM
//
//  The shop's subscription status line on Today and in More: the owner's
//  trial end or a failing subscription payment, and for everyone the
//  "creating new records is paused" notice while the subscription is
//  inactive (DetailCore `ShopEntitlement.notice`). Text only — no prices,
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
                .foregroundStyle(notice.isWarning ? Theme.warning : Theme.glacier)
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
