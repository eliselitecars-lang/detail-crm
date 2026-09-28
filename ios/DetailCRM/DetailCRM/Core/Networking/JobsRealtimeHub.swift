//
//  JobsRealtimeHub.swift
//  DetailCRM
//
//  Live updates (P-26). One Supabase Realtime channel per active shop
//  listens to `postgres_changes` on the tables the staff screens show and
//  turns them into per-table change counters. Screens reload when the
//  counter of a table they show moves:
//
//      .onChange(of: realtime.revision(.jobs)) { _, _ in Task { await reload() } }
//
//  Changes are debounced (300 ms per table), so a burst — a job saved with
//  its lines and assignments — reloads a screen once. Row-level security
//  applies to Realtime as to every query: a technician only hears about
//  rows they may read. The payload itself is never used (screens re-read
//  through their services), so nothing here decodes records.
//
//  Lifecycle: MainTabView starts the hub for its shop and stops it when it
//  goes away (shop switch, sign-out). Returning to the foreground rejoins
//  the channel when needed and bumps every counter, since changes made
//  while the app was suspended were not delivered.
//

import Foundation
import Observation
import Supabase
import os

/// Tables the app listens to (all are in the `supabase_realtime`
/// publication and carry `shop_id`).
enum JobsRealtimeTable: String, CaseIterable, Hashable, Sendable {
    case jobs
    case notifications
    case messages
    case payments
    case timeEntries = "time_entries"
    case tasks
}

@Observable
@MainActor
final class JobsRealtimeHub {

    /// The one hub (a single socket per app).
    static let shared = JobsRealtimeHub()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.detailcrm.app",
        category: "realtime"
    )
    private static let debounce: Duration = .milliseconds(300)

    /// Change counters per table (observed by the screens).
    private(set) var revisions: [JobsRealtimeTable: Int] = [:]
    /// The shop the channel listens to, nil when stopped.
    private(set) var shopID: UUID?
    /// True while the channel is joined.
    private(set) var isLive = false

    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var subscriptions: [RealtimeSubscription] = []
    @ObservationIgnored private var pending: [JobsRealtimeTable: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0

    init() {}

    /// The change counter of `table` (0 until something changes).
    func revision(_ table: JobsRealtimeTable) -> Int {
        revisions[table] ?? 0
    }

    // MARK: - Lifecycle

    /// Listens to `shopID` (a no-op when already listening to it).
    func start(shopID: UUID) async {
        if self.shopID == shopID, channel != nil { return }
        await stop()
        guard AppConfig.isConfigured else { return }
        self.shopID = shopID
        generation += 1
        await join(shopID: shopID, generation: generation)
    }

    /// Leaves the channel (shop switch, sign-out).
    func stop() async {
        generation += 1
        for task in pending.values { task.cancel() }
        pending = [:]
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        let old = channel
        channel = nil
        shopID = nil
        isLive = false
        if let old {
            await Supa.client.removeChannel(old)
        }
    }

    /// Back in the foreground: rejoin if the channel dropped, and ask every
    /// screen to refresh (changes made while suspended were missed).
    func resume() async {
        guard let shopID else { return }
        if channel == nil || !isLive {
            let current = generation
            await rejoin(shopID: shopID, generation: current)
        }
        for table in JobsRealtimeTable.allCases {
            bumpNow(table)
        }
    }

    // MARK: - Channel

    private func rejoin(shopID: UUID, generation current: Int) async {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        if let old = channel {
            channel = nil
            await Supa.client.removeChannel(old)
        }
        guard current == generation else { return }
        await join(shopID: shopID, generation: current)
    }

    private func join(shopID: UUID, generation current: Int) async {
        let shopText = shopID.uuidString.lowercased()
        let channel = Supa.client.channel("detailcrm-shop-\(shopText)")
        var tokens: [RealtimeSubscription] = []
        for table in JobsRealtimeTable.allCases {
            let token = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: table.rawValue,
                filter: "shop_id=eq.\(shopText)"
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.bump(table)
                }
            }
            tokens.append(token)
        }
        self.channel = channel
        subscriptions = tokens
        do {
            try await channel.subscribeWithError()
            guard current == generation else { return }
            isLive = true
        } catch {
            guard current == generation else { return }
            isLive = false
            Self.log.error("Realtime subscribe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Signals

    /// Debounced: the counter moves 300 ms after the last change of a burst.
    private func bump(_ table: JobsRealtimeTable) {
        guard shopID != nil else { return }
        pending[table]?.cancel()
        pending[table] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.bumpNow(table)
        }
    }

    private func bumpNow(_ table: JobsRealtimeTable) {
        pending[table] = nil
        revisions[table, default: 0] += 1
    }
}
