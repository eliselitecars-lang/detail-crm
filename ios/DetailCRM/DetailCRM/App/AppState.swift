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
//  Session expiry: when the session is over (Auth refuses a refresh, or the
//  Auth client drops the session itself) the user is signed out through the
//  same path as the Sign out button — once, on this device only — and the
//  sign-in screen shows `signInNotice`. A gateway 401 from an edge function
//  (SessionMonitor) is checked with a refresh first. SessionExpiryGate
//  (DetailCore) keeps concurrent reports from signing out twice or looping.
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
    /// Why the user was signed out (an expired session), for the sign-in
    /// screen; cleared by the next sign-in or the user's own sign-out.
    private(set) var signInNotice: String?
    /// A tapped push notification waiting for the main tabs to open it
    /// (JobsPushRouter / MainTabView).
    var pendingPush: JobsPushRouter.Pending?

    @ObservationIgnored private var authListener: Task<Void, Never>?
    @ObservationIgnored private var sessionGate = SessionExpiryGate()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startAuthListener()
        startSessionMonitor()
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
            // Our own sign-outs pass here while the gate is signing out, and a
            // repeated event finds nobody signed in: both only clear state.
            // Otherwise the Auth client dropped the session by itself because
            // the server no longer accepts it (a revoked or reused refresh
            // token): the same sign-out, explained on the sign-in screen.
            if userID != nil, sessionGate.beginSignOut() {
                signInNotice = SessionExpiry.notice
                clearSession()
                sessionGate.finishSignOut()
            } else {
                clearSession()
            }
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
        signInNotice = nil
        if self.userID != userID {
            // A different account: nothing from the previous one survives.
            memberships = []
            current = nil
            profile = nil
        }
        // Videos another account left pending on this iPhone (e.g. after
        // its session expired) are deleted, never sent under this user.
        JobsResumableUploader.discardAll(keepingUserID: userID)
        self.userID = userID
        self.userEmail = email
        await bootstrap()
    }

    /// Launch / Retry: loads profile + memberships and picks the phase.
    /// Fetching refreshes an expired access token first; when Auth refuses
    /// that refresh the user is signed out (with the expiry notice), any
    /// other failure (offline, server down) shows `.failed` with Retry.
    private func bootstrap() async {
        do {
            try await fetchProfileAndMemberships()
            chooseShop(preferred: nil)
        } catch {
            // The stored session is over (Auth refused its refresh): sign in
            // again, with the notice. Offline or server trouble: Retry.
            if SessionExpiry.sessionIsGone(after: SessionMonitor.refreshOutcome(of: error)) {
                await endExpiredSession()
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

    // MARK: - Session expiry

    private func startSessionMonitor() {
        guard AppConfig.isConfigured else { return }
        SessionMonitor.setListener { [weak self] signal in
            guard let self else { return }
            Task { await self.handleSessionSignal(signal) }
        }
    }

    /// A request found the session refused. A refused refresh ends it; the
    /// gateway's 401 is first checked with one refresh (a slow device clock
    /// also causes it, and the refresh fixes that), so the user is signed out
    /// only when Auth confirms the session is over. Offline: nothing happens.
    private func handleSessionSignal(_ signal: SessionMonitor.Signal) async {
        switch signal {
        case .refreshRefused:
            await endExpiredSession()
        case .gatewayRejected:
            guard let ticket = sessionGate.beginVerification(signedIn: userID != nil) else { return }
            let outcome: SessionExpiry.RefreshOutcome
            do {
                _ = try await Supa.client.auth.refreshSession()
                outcome = .refreshed
            } catch {
                outcome = SessionMonitor.refreshOutcome(of: error)
            }
            if sessionGate.finishVerification(ticket: ticket, outcome: outcome, signedIn: userID != nil) {
                Self.log.info("Session refused by the server; signing out")
                await performSignOut(scope: .local, notice: SessionExpiry.notice)
            }
        }
    }

    /// Signs out a session the server no longer accepts: on this device only
    /// (the account's other devices keep their sessions), with the notice.
    /// Does nothing when nobody is signed in or a sign-out is running.
    private func endExpiredSession() async {
        guard userID != nil, sessionGate.beginSignOut() else { return }
        Self.log.info("Session expired; signing out")
        await performSignOut(scope: .local, notice: SessionExpiry.notice)
    }

    /// The one sign-out path (the gate is already `.signingOut`). The notice
    /// is set first: the sign-in screen appears as soon as the Auth client
    /// emits `.signedOut`, before the server call returns.
    private func performSignOut(scope: SignOutScope, notice: String?) async {
        signInNotice = notice
        // Stop pushes to this device for the account while the session may
        // still work (bounded wait; falls back to leaving APNs).
        await JobsPushRegistrar.shared.detachBeforeSignOut()
        do {
            try await AuthService.signOut(scope: scope)
        } catch {
            Self.log.error("Sign out failed: \(error.localizedDescription, privacy: .public)")
        }
        // A deliberate sign-out (not an expired session) leaves no recorded
        // video behind; an expired session keeps them for the same user.
        // Every sign-out button confirms through `ConfirmationRequest.signOut`,
        // which names the unsent videos this deletes (they exist nowhere else).
        if notice == nil {
            JobsResumableUploader.discardAll(keepingUserID: nil)
        }
        clearSession()
        sessionGate.finishSignOut()
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
        JobsPushRegistrar.shared.userSignedOut()
        pendingPush = nil
        Task { await JobsRealtimeHub.shared.stop() }
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

    /// The Sign out button (and after deleting the account): every session
    /// of the account. Ignored while a sign-out is already running.
    func signOut() async {
        guard sessionGate.beginSignOut() else { return }
        await performSignOut(scope: .global, notice: nil)
    }
}
