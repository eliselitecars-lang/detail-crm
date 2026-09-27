# Detail CRM — iPhone app

Native SwiftUI staff app (owner / admin / manager / technician) on the same
Supabase database as the web app. Clients use the web portal, not this app.

```
ios/
  DetailCore/                 Swift package: pure business logic + XCTest (Foundation only)
  DetailCRM/
    DetailCRM.xcodeproj       hand-written project (objectVersion 77, synchronized folder)
    DetailCRM/                every file in here is part of the app target automatically
      App/                    DetailCRMApp (entry), AppState (session + tenancy), RootView, SetupRequiredView
      Core/Config/            AppConfig (reads Config.plist)
      Core/Theme/Theme.swift  ALL colors, type, spacing, radii, button styles, card modifiers
      Core/Components/        LoadState, state views, AsyncButton, toasts, confirmations,
                              money/status/avatar views, form rows, signature pad,
                              photo/camera pickers, map/phone/email links, brand mark
      Core/Networking/        Supa.swift (the one SupabaseClient, error text, AnyJSON helpers),
                              EdgeErrorDecoder.swift (edge-function errors + EdgeFunctions.invoke)
      Core/Models/            Codable structs mirroring tables / RPC results
      Core/Services/          one static enum per domain (AuthService, ShopService, …)
      Features/<Feature>/     screens, one folder per feature
      Assets.xcassets         AppIcon, AccentColor (Glacier)
      Config.plist            SUPABASE_URL / SUPABASE_ANON_KEY / WEB_APP_URL
```

## Architecture

* **SwiftUI, iOS 17+, Observation.** App-wide state objects are
  `@Observable @MainActor final class` and are read with
  `@Environment(Type.self)`: `AppState` (auth phase, memberships, current
  shop + role) and `ToastCenter` (transient banners).
* **Session phases** (`AppState.Phase`): `launching → signedOut | needsShop |
  ready | failed(message)`, driven by `Supa.client.auth.authStateChanges`.
  `needsShop` shows the shop picker (pick / create a shop / join by invite);
  the chosen shop id is remembered per user in `UserDefaults`.
  `RootView` keys the main tabs by shop id, so switching shops rebuilds every
  screen and nothing from the previous tenant survives.
  The client emits the stored session as `.initialSession` even when its
  access token has expired (`emitLocalSessionAsInitialSession`); bootstrap
  refreshes it, so opening the app offline lands on `failed` (Retry) rather
  than Sign In, and a later `.tokenRefreshed` finishes the bootstrap.
  Membership API: `refreshMemberships()` (re-read the list, never changes the
  active shop or phase), `activateShop(_:)` (after create/join),
  `refreshCurrentShop()` (after settings edits), `selectShop(_:)`,
  `beginSwitchingShop()` / `cancelSwitchingShop()`. The async ones throw so
  the screen can show the error.
* **Tenancy.** Every query against a tenant table filters by the active
  `shop_id` (`try appState.requireShopID()`); RLS enforces the same boundary.
* **Roles.** `ShopRole` and the SPEC §3 capability matrix live in
  `DetailCore` (`role.can(.manageInvoices, policy:)`, or `appState.can(...)`).
  UI hides what a role can't do; the server enforces it regardless.
* **Pure logic in DetailCore** (tested with XCTest on Linux and macOS):
  `Money` (format/parse cents), `DocumentTotals` (exact mirror of
  `public.compute_document_totals`, SPEC §4.5), `JobStatus` + transition
  rules, quote/invoice/payment/membership statuses, `ShopRole`/`Capability`,
  `TemplateRenderer` (`{{placeholder}}`), `PhoneNumber` (E.164), `VIN`,
  `ShopClock` (shop-timezone days/weeks, DST-safe), `Validation` (email and
  slug rules identical to the database).

## Conventions (follow these in every feature)

1. **Services are static enums over `Supa.client`** — no view talks to
   Supabase directly. Money amounts are derived by the server; the app never
   sends totals or prices for server-priced flows.
2. **Every data screen owns a `LoadState<T>`** and renders it with
   `LoadStateView` (loading / error-with-retry / content); empty collections
   render `EmptyStateView`. Refresh failures while content is on screen go to
   `toasts.showError(error)`. Human text for any error: `ErrorText.message(for:)`.
3. **Theme tokens only.** Colors, fonts, spacing, radii and button styles come
   from `Theme` (`.themePrimary`, `.themeMoney` for money actions only,
   `.cardStyle()`, `.screenBackground()`, …). Amber is reserved for money.
4. **Model annotations.** Every Codable struct mapped to a table has explicit
   `CodingKeys` and a `// table: <name>` line directly above it; RPC result
   structs use `// rpc: <name>`. `scripts/check_contracts.py` checks the
   names against the schema; `scripts/swift_sanity.py` checks the tags exist.
5. **Navigation.** Each tab owns one `NavigationStack` (`TabRoot`); feature
   root views never create their own. Link across features with
   `NavigationLink(value: AppRoute.job(id))` (also `.customer`, `.quote`,
   `.invoice`, `.conversation(customerID)`); the destinations are
   registered once per tab. Notifications open `AppNotification.route`
   (same precedence as the web app).
6. **Feature entry points** (keep these names/initializers): `TodayView`,
   `CalendarHomeView`, `CustomersView`, `CustomerDetailView(customerID:)`,
   `InboxView`, `JobDetailView(jobID:)`, `QuotesView`,
   `QuoteDetailView(quoteID:)`, `InvoicesView`, `InvoiceDetailView(invoiceID:)`,
   `PaymentsView`, `MembershipsView`, `TimeClockView`, `ReportsView`,
   `TeamView`, `CatalogView`, `SettingsView`, `NotificationsView`.
   Not-yet-built screens contain the literal marker `FEATURE_STUB`; replace
   the stub (and remove the marker) when the feature lands. When no stub uses
   `FeatureStubView` any more, delete `Features/Shell/FeatureStubView.swift`.
7. **Swift traps** (each crashed or broke a previous app): no types nested in
   generic functions; no state-driven `safeAreaInset` + preference-key loops;
   no negative frames; don't `if`-gate views you animate (animate opacity /
   offset of an always-present view); split very large view bodies into
   subviews or `AnyView` seams at section boundaries; `import Supabase`
   wherever `AnyJSON` appears; PostgREST has no `.not(in:)` — chain `.neq`;
   no `try!`; build URLs with `URLComponents`, never `URL(string:)!`.
8. **Swift 5 language mode** (`SWIFT_VERSION = 5.0`) to avoid strict
   concurrency errors; keep UI types on the main actor.
9. **Edge functions.** Call them through `EdgeFunctions.invoke("name", body:)`
   (or `MoneyEdge.invoke` in the money services) with a string literal name
   (`swift_sanity.py` checks it names a real function). Every failure is an
   `EdgeFunctionError` (`EdgeErrorDecoder`): our `{error, code, details}`
   envelope keeps the server's wording and `details.reason`; a gateway /
   non-envelope body is worded from the HTTP status (401 "Your session has
   expired. Sign in again.", 403, 404, 429, 5xx).
10. **Idempotent sends.** Every message compose carries a `request_nonce`
   (`MoneyEdge.newNonce()`, reused when the same content is sent again after
   a failure — `InboxComposeAttempt`), so a retry never queues a second copy.
   Quote / invoice messages are rendered and queued by the server
   (`messaging` send with `quote_id` / `invoice_id`; preview from
   `preview_document_message`) — the app never renders document wording.

## Running locally (macOS with Xcode 16+)

1. Put your Supabase project URL and anon key in
   `DetailCRM/DetailCRM/Config.plist` (never commit real values). Until then
   the app launches into a "Setup required" screen. The committed file holds
   only `YOUR_…` placeholders and no workflow fills it: `ios.yml` builds for
   the simulator with the placeholders, and any archive/TestFlight pipeline
   must write the real values from repository secrets before building.
2. Open `DetailCRM/DetailCRM.xcodeproj`, let Swift packages resolve
   (supabase-swift 2.x, stripe-ios-spm 24.x, local `../DetailCore`), choose
   an iPhone simulator and run.
3. DetailCore tests: `cd ios/DetailCore && swift test` (works on macOS and on
   Linux with a Swift 5.9+ toolchain).

## How CI verifies (`.github/workflows/ios.yml`)

Runs on `macos-15` for pushes that touch `ios/**`, `scripts/swift_sanity.py`
or the workflow, and on manual dispatch (macOS minutes are expensive — batch
iOS changes):

1. `python3 scripts/swift_sanity.py --self-test` and `python3 scripts/swift_sanity.py`
   (bracket balance ignoring strings/comments, pbxproj id integrity,
   model annotations, forbidden patterns, FEATURE_STUB count; `--strict`
   additionally fails while any stub remains).
2. `swift test` in `ios/DetailCore`.
3. `xcodebuild -resolvePackageDependencies` (SPM checkouts cached by
   Package.resolved/pbxproj hash; the pins are committed in
   `DetailCRM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   and each run uploads what it resolved as the `package-resolved`
   artifact) and `xcodebuild build` for
   `generic/platform=iOS Simulator` with `CODE_SIGNING_ALLOWED=NO`.
4. On failure the first 200 unique `error:` lines of each log are printed and
   the logs are uploaded as an artifact.

Run `python3 scripts/swift_sanity.py` before every push that touches `ios/`.
