//
//  AppState.swift
//  DetailCRM
//
//  Session + tenancy state for the whole app. Listens to the Supabase auth
//  stream, loads the signed-in user's shop memberships, and tracks which
//  shop is active (persisted per user in UserDefaults).
//
//  Phases:
//    launching  — waiting for the stored session / first membership load
//    signedOut  — show sign in / sign up
//    needsShop  — signed in, but no shop chosen yet (picker / create / join)
//    ready      — a shop is active; the main tabs are shown
//    failed     — bootstrap failed (e.g. offline at launch with an expired
//                 access token); Retry reruns it, and a later successful
//                 token refresh finishes it automatically
//

import Foundation
import Observation
import Supabase
import DetailCore
import os

@Observable
@MainActor
final class AppState {

    enum Phase: Equatable {
        case launching
        case signedOut
        case needsShop
        case ready
        case failed(String)
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.detailcrm.app",
        category: "bootstrap"
    )
    private static let selectedShopKeyPrefix = "detailcrm.selectedShop."

    private(set) var phase: Phase = .launching
    private(set) var userID: UUID?
    private(set) var userEmail: String?
    private(set) var profile: Profile?
    /// Active memberships, sorted by shop name.
    private(set) var memberships: [ShopMembership] = []
    /// The active shop + the user's membership in it (nil unless `.ready`,
    /// or while switching shops).
    private(set) var current: ShopMembership?

    @ObservationIgnored private var authListener: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startAuthListener()
    }

    // MARK: - Convenience accessors

    var shop: Shop? { current?.shop }
    var member: ShopMember? { current?.member }
    var role: ShopRole? { current?.role }

    /// The active shop id, or `AppError.noShopSelected`.
    func requireShopID() throws -> UUID {
        guard let id = current?.shop.id else { throw AppError.noShopSelected }
        return id
    }

    /// Calendar/formatting in the active shop's time zone (device zone
    /// before a shop is chosen).
    var clock: ShopClock {
        shop?.clock ?? ShopClock(timeZone: .current)
    }

    /// Shop currency code (`usd`), for Money formatting.
    var currencyCode: String {
        shop?.currency ?? "usd"
    }

    /// Whether the signed-in member may use `capability` in the active shop.
    /// UI gating only — the server enforces the same rules.
    func can(_ capability: Capability) -> Bool {
        guard let current else { return false }
        return current.role.can(capability, policy: current.shop.policy)
    }

    /// Display name to greet the user with.
    var displayName: String {
        if let name = member?.displayName, !name.isEmpty { return name }
        if let name = profile?.fullName, !name.isEmpty { return name }
        return userEmail ?? "there"
    }

    // MARK: - Auth stream

    private func startAuthListener() {
        guard AppConfig.isConfigured else {
            phase = .signedOut
            return
        }
        authListener = Task { [weak self] in
            for await (event, session) in Supa.client.auth.authStateChanges {
                guard let self, !Task.isCancelled else { return }
                await self.handleAuthEvent(event, session: session)
            }
        }
    }

    /// The client emits the locally stored session as `.initialSession`
    /// even when its access token has expired (`emitLocalSessionAsInitialSession`
    /// in Supa.swift). Bootstrap then refreshes it: offline that fails with a
    /// network error and lands on `.failed` (Retry), not on Sign In; a
    /// revoked refresh token makes the client emit `.signedOut`.
    private func handleAuthEvent(_ event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn:
            if let session {
                await resolveSession(userID: session.user.id, email: session.user.email)
            } else {
                clearSession()
            }
        case .tokenRefreshed:
            // A refresh that succeeds after a failed (offline) bootstrap, or
            // before any user was resolved, finishes signing in.
            guard let session else { return }
            if userID == nil || isFailed {
                await resolveSession(userID: session.user.id, email: session.user.email)
            }
        case .signedOut:
            clearSession()
        case .userUpdated:
            if let session {
                userEmail = session.user.email
                profile = try? await ShopService.myProfile()
            }
        default:
            break
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Session resolution

    private func resolveSession(userID: UUID, email: String?) async {
        // Already bootstrapped for this user (e.g. a repeated SIGNED_IN on
        // foreground): keep the current screen.
        if self.userID == userID, phase == .ready || phase == .needsShop {
            return
        }
        if self.userID != userID {
            // A different account: nothing from the previous one survives.
            memberships = []
            current = nil
            profile = nil
        }
        self.userID = userID
        self.userEmail = email
        await bootstrap()
    }

    /// Launch / Retry: loads profile + memberships and picks the phase.
    /// Fetching refreshes an expired access token first; when that fails
    /// because the session is gone the user is signed out, any other
    /// failure (offline, server down) shows `.failed` with Retry.
    private func bootstrap() async {
        do {
            try await fetchProfileAndMemberships()
            chooseShop(preferred: nil)
        } catch {
            if Self.isSessionGone(error) {
                clearSession()
                return
            }
            Self.log.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
            if current == nil {
                phase = .failed(ErrorText.message(for: error))
            }
        }
    }

    private func fetchProfileAndMemberships() async throws {
        async let profileTask = ShopService.myProfile()
        async let membershipsTask = ShopService.myMemberships()
        let (loadedProfile, loadedMemberships) = try await (profileTask, membershipsTask)
        profile = loadedProfile
        memberships = loadedMemberships
    }

    /// The stored session no longer exists or was revoked (not a network
    /// problem), so the only way forward is signing in again.
    private static func isSessionGone(_ error: Error) -> Bool {
        if let authError = error as? AuthError, case .sessionMissing = authError {
            return true
        }
        return false
    }

    private func chooseShop(preferred: UUID?) {
        var pick: ShopMembership?
        for candidate in [preferred, current?.shop.id, storedShopID()] {
            guard let candidate else { continue }
            if let match = memberships.first(where: { $0.shop.id == candidate }) {
                pick = match
                break
            }
        }
        if let pick {
            activate(pick)
        } else if memberships.count == 1, let only = memberships.first {
            activate(only)
        } else {
            current = nil
            phase = .needsShop
        }
    }

    private func activate(_ membership: ShopMembership) {
        current = membership
        if let userID {
            defaults.set(membership.shop.id.uuidString, forKey: Self.selectedShopKeyPrefix + userID.uuidString)
        }
        phase = .ready
    }

    private func storedShopID() -> UUID? {
        guard let userID,
              let raw = defaults.string(forKey: Self.selectedShopKeyPrefix + userID.uuidString) else { return nil }
        return UUID(uuidString: raw)
    }

    private func clearSession() {
        userID = nil
        userEmail = nil
        profile = nil
        memberships = []
        current = nil
        phase = .signedOut
    }

    // MARK: - Public API

    /// Reruns the failed bootstrap (the Retry button at launch). Offline
    /// retries stay on the error screen; only a missing session signs out.
    func retry() async {
        guard userID != nil else {
            clearSession()
            return
        }
        phase = .launching
        await bootstrap()
    }

    /// Makes `shopID` the active shop (from the shop picker).
    func selectShop(_ shopID: UUID) {
        guard let membership = memberships.first(where: { $0.shop.id == shopID }) else { return }
        activate(membership)
    }

    /// Shows the shop picker (More > Switch Shop). The main UI is torn down,
    /// so no screen keeps showing the previous shop's data. The remembered
    /// shop stays stored so Cancel can return to it.
    func beginSwitchingShop() {
        current = nil
        phase = .needsShop
    }

    /// Leaves the picker without changing shops, when one was active.
    func cancelSwitchingShop() {
        chooseShop(preferred: nil)
    }

    /// Whether the picker can be dismissed back to an active shop.
    var canCancelShopSwitch: Bool {
        storedShopID().map { id in memberships.contains(where: { $0.shop.id == id }) } ?? false
    }

    /// Re-reads profile + memberships for the shop picker's pull to refresh.
    /// Never changes which shop is active or the phase: a user switching
    /// shops stays in the picker. Throws so the caller can show a toast.
    func refreshMemberships() async throws {
        try await fetchProfileAndMemberships()
        if let current {
            if let fresh = memberships.first(where: { $0.shop.id == current.shop.id }) {
                self.current = fresh
            } else {
                // Removed from the active shop meanwhile.
                chooseShop(preferred: nil)
            }
        }
    }

    /// Re-reads memberships and makes `shopID` active (after creating or
    /// joining a shop). Throws, leaving the phase unchanged, when the list
    /// can't be loaded or doesn't contain the shop.
    func activateShop(_ shopID: UUID) async throws {
        try await fetchProfileAndMemberships()
        guard let membership = memberships.first(where: { $0.shop.id == shopID }) else {
            throw AppError.notFound("That shop")
        }
        activate(membership)
    }

    /// Re-reads the active shop row (e.g. after settings change it). Keeps
    /// the current screen when the reload fails; throws so the caller can
    /// tell the user.
    func refreshCurrentShop() async throws {
        guard current != nil else { throw AppError.noShopSelected }
        try await refreshMemberships()
    }

    func signOut() async {
        do {
            try await AuthService.signOut()
        } catch {
            Self.log.error("Sign out failed: \(error.localizedDescription, privacy: .public)")
        }
        clearSession()
    }
}
