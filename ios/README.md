# Detail CRM — iPhone app

Native SwiftUI staff app (owner / admin / manager / technician) on the same
Supabase database as the web app. Clients use the web portal, not this app.

```
ios/
  DetailCore/                 Swift package: pure business logic + XCTest (Foundation only)
  DetailCRM/
    DetailCRM.xcodeproj       hand-written project (objectVersion 77, synchronized folder)
    DetailCRM/                every file in here is part of the app target automatically
      App/                    DetailCRMApp (entry), AppState (session + tenancy), RootView, SetupRequiredView,
                              JobsAppDelegate / JobsPushRegistrar / JobsPushRouter (push notifications)
      Core/Config/            AppConfig (reads Config.plist)
      Core/Theme/Theme.swift  ALL colors, type, spacing, radii, button styles, card modifiers
      Core/Components/        LoadState, state views, AsyncButton, toasts, confirmations,
                              money/status/avatar views, form rows, signature pad,
                              photo/camera pickers, map/phone/email links, brand mark,
                              VIN scanner, subscription status line (BillingNotice)
      Core/Networking/        Supa.swift (the one SupabaseClient, error text, AnyJSON helpers),
                              EdgeErrorDecoder.swift (edge-function errors + EdgeFunctions.invoke),
                              JobsRealtimeHub.swift (live change signals per table)
      Core/Models/            Codable structs mirroring tables / RPC results
      Core/Services/          one static enum per domain (AuthService, ShopService, …)
      Features/<Feature>/     screens, one folder per feature
      Assets.xcassets         AppIcon, AccentColor (Glacier)
      Config.plist            SUPABASE_URL / SUPABASE_ANON_KEY / WEB_APP_URL,
                              TAP_TO_PAY_ENABLED / TERMINAL_BLUETOOTH_ENABLED (both NO)
      DetailCRM.entitlements  aps-environment (push); Tap to Pay is added once Apple grants it
      PrivacyInfo.xcprivacy   required-reason APIs (UserDefaults)
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
  The client uses the **implicit** auth flow (`flowType: .implicit`;
  supabase-swift defaults to PKCE): the app has no URL scheme, so
  password-reset and sign-up confirmation emails open the web app, which
  can only redeem a link that carries the session in its fragment, not a
  PKCE `?code=` whose verifier is in the phone's keychain. `AuthLinks`
  (DetailCore) sends them to `WEB_APP_URL/reset-password` and
  `WEB_APP_URL/auth/callback`: the web accepts link tokens only on those
  pages and scrubs them anywhere else, so a confirmation to the Site URL
  root would leave the person on the sign-in page, not signed in.
  **Session expiry:** when the session is over (Auth refuses a refresh, or
  the Auth client drops the session itself) AppState signs out through its
  one sign-out path, on this device only, and the sign-in screen shows
  `signInNotice`. Services report through `SessionMonitor`
  (`EdgeFunctions.failure(from:)` for a gateway 401 without our envelope,
  `Supa.currentUserID()` for a refused refresh); a gateway 401 is checked
  with one token refresh before anyone is signed out, and 401s in our
  `{error, code, details}` envelope never sign out. The rules and the gate
  that makes one lost session sign out exactly once are DetailCore's
  `SessionExpiry` / `SessionExpiryGate`.
  Membership API: `refreshMemberships()` (re-read the list, never changes the
  active shop or phase), `activateShop(_:)` (after create/join),
  `refreshCurrentShop()` (after settings edits), `selectShop(_:)`,
  `beginSwitchingShop()` / `cancelSwitchingShop()`, `leaveShop(_:)`
  (`leave_shop` from Your account > Your shops, any role but owner; leaving
  the active shop forgets it and opens the only other shop or the picker).
  The async ones throw so the screen can show the error.
* **Push notifications (APNs).** `JobsAppDelegate` (via
  `@UIApplicationDelegateAdaptor`) receives the device token and taps.
  `JobsPushRegistrar` asks for permission the first time the main tabs
  appear (once per install), registers the token for the signed-in user
  (`register_push_token`; `sandbox` in DEBUG builds, `production`
  otherwise) and keeps the icon badge = unread notifications across shops.
  Signing out removes the token (`unregister_push_token`, bounded wait);
  when that can't reach the server the device leaves APNs instead, so a
  signed-out phone never shows another account's pushes. A tap becomes
  `AppState.pendingPush` (`JobsPushRouter`: same destination rule as the
  in-app list, `task_*` kinds open the Tasks screen, another shop's
  notification switches shops first) and `MainTabView` pushes it onto Today / More.
  What is pushed is decided by the server (`claim_push_batch`: kinds the
  member may read, their per-kind choices and mute in
  `JobsNotificationPrefsView`, reached from the Notifications screen).
* **Realtime.** `JobsRealtimeHub.shared` (also in the environment) joins
  one channel per active shop with `postgres_changes` on jobs,
  notifications, messages, payments, time_entries and tasks (RLS applies)
  and exposes debounced (300 ms) counters: a screen reloads with
  `.onChange(of: realtime.revision(.jobs)) { … }`. `MainTabView` starts it
  per shop; sign-out stops it; returning to the foreground rejoins and bumps
  every counter. Payloads are never decoded — screens re-read through
  their services.
* **Tenancy.** Every query against a tenant table filters by the active
  `shop_id` (`try appState.requireShopID()`); RLS enforces the same boundary.
* **Roles.** `ShopRole` and the SPEC §3 capability matrix live in
  `DetailCore` (`role.can(.manageInvoices, policy:)`, or `appState.can(...)`).
  UI hides what a role can't do; the server enforces it regardless.
* **Pure logic in DetailCore** (tested with XCTest on Linux and macOS):
  `Money` (format/parse cents), `DocumentTotals` (exact mirror of
  `public.compute_document_totals`, SPEC §4.5, including
  `TotalsLine.discountEligible`: the document discount applies to eligible
  lines only), `VIN.candidates(in:)` (VIN readings from scanned text or
  barcodes, check-digit-verified first), `JobStatus` + transition
  rules, quote/invoice/payment/membership statuses, `ShopRole`/`Capability`,
  `TemplateRenderer` (`{{placeholder}}`), `PhoneNumber` (E.164), `VIN`,
  `ShopClock` (shop-timezone days/weeks, DST-safe; `weekInterval` is the
  Sunday-first calendar grid week, `totalsWeekInterval` the Monday-first
  week every "This week" total uses, matching the server's
  `date_trunc('week')` and the web app), `Validation` (email and
  slug rules identical to the database), `SessionExpiry` (when a refused
  request means the session is over; `SessionExpiryGate`),
  `ShopEntitlement` (the shop's subscription standing, which status line
  to show — with the reason when the trial ended or the shop has no
  subscription or trial, e.g. a person's second shop since 0120 — what
  Create shop says once the new shop exists, and the PT402 / HTTP 402
  refusal text), `MarketingAddress` (0119: marketing email needs the
  shop's street address and city; email follow-ups read "Not sent" and
  Business profile warns while either is blank), `UnsentVideoWarning`
  (the sign-out / discard / account-deletion wording while job videos
  haven't finished uploading), `ListPage` / `IDChunks` (paged "Load more"
  lists fetched with one extra row; id look-ups split into de-duplicated
  chunks of 100 to keep request URLs short) and `SideLoad` (an optional
  extra such as saved cards or a pay-link token whose failure is reported
  to the screen, never silently turned into "none"), `JobTime` (the job
  page's Time section: totals, who is on the clock, and whether the
  member gets "Clock in on this job", "Clock out" or "clocked in
  elsewhere"), `PaymentApplication` (what a ledger payment pays, unapplied
  money, what can be applied or refunded — the web's paymentFormat.ts) and
  `BookingLink` (`WEB_APP_URL/booking/<token>` and the channels the link
  can be sent on).

## Shared building blocks (jobs agent; other features use them read-only)

* `JobsVINScannerView { result in … }` — VisionKit live scanner (VIN
  barcodes + printed text) in a sheet; a check-digit-verified VIN is
  accepted at once, anything else is shown for confirmation; unsupported
  devices / denied camera fall back to typing.
* `JobsDocument` + `JobsDocumentService` — files on jobs (`.job(id)`) and
  customers (`.customer(id)`) in the `documents` bucket: list, upload
  (type/size checked against the bucket), visibility, rename, delete,
  `downloadForPreview` for Quick Look. `JobsDocumentsSection.importableTypes`
  is the file-picker type list.
* `JobsCustomField` / `JobsCustomFieldType` / `JobsCustomValue` +
  `JobsCustomFieldService` — shop-defined fields and their values in
  `custom_data` (`mergedData` keeps archived answers).
* `JobsShopFee` — preset fees (`JobService.fees`, `JobService.addFeeLine`
  with `.job` / `.quote` / `.invoice`).
* `JobsResumableUploader` — TUS 1.0.0 uploads to Storage (6 MB chunks,
  resumable across launches); used for job videos (`job-media` bucket).
  Pending uploads belong to the account that recorded them: only that user
  lists and resumes them, Sign out deletes them (and the local copies), and
  another account signing in deletes the previous one's. The camera
  recorder doesn't save to Photos, so a pending upload is the only copy:
  every Sign out button confirms through `ConfirmationRequest.signOut`,
  which names the unsent videos it would delete (DetailCore
  `UnsentVideoWarning`; account deletion adds the same note), and a paused
  upload's menu has "Save or share video" (share sheet, incl. Save Video)
  and a confirmed "Discard this video".
* Theme additions: `Theme.scrim` (dark overlay behind white text on
  camera / video) and `Theme.Typography.caption2`.
* `JobStorageImage` — every private Storage image on the job screen
  (photo thumbnails, the full-screen viewer, damage-mark photos,
  signatures). DetailCore `SignedImageLoad` signs a link when the list
  had none, re-signs once when a link from the list fails (an expired
  hour-long link), and otherwise ends in a message with Retry — never an
  endless spinner. The viewer's `JobZoomableImageView` is a UIScrollView:
  pinch where the fingers are, double-tap to zoom at the tap, drag to pan;
  at the photo's edge the pager takes over.
* `JobsGateOverridesNotice` — on the job screen under the header, every
  move past the completion gates (`job_gate_overrides`: who, when, the
  reason and what was missing, DetailCore `GateWaiver`), for everyone who
  can work the job.

**Type names:** new top-level types start with their owner's prefix
(`Jobs*`, `Money*`, `Ops*`); nested helper types live inside them.

## Field operations (ops agent)

* **Tasks (P-32).** `OpsTasksView` (More › Tasks, every role; mine / all
  for managers, done) with `OpsTaskRow` and `OpsTaskEditorSheet`;
  `OpsTaskService` reads and writes `tasks` (RLS decides who sees what) and
  the list stays live through `JobsRealtimeHub` `.tasks`. `task_assigned` /
  `task_due` notifications open the Tasks screen, from a push and from the
  in-app list alike.
* **Geostamped clock in / out (P-24).** Both punch screens — Time Clock
  and the Today tab's shift card — ask `OpsClockLocationProvider` for a
  one-shot "while using the app" fix (up to 10 s; nil when declined, off
  or not found) and send it with `clock_in` / `clock_out` through
  `TimeClockService` (`p_lat`, `p_lng`, `p_accuracy_m`). The punch goes
  through without a location; nothing is tracked in the background.
* **Week totals (Time Clock, Team time).** `TimeClockService.entries`
  loads every entry that overlaps the shop week (starts before it ends and
  is open or ends after it starts), and `TimeClockTotalsRow` counts only
  each entry's part inside the week (DetailCore `TimeTotals`), the same cut
  as the web timesheet and `report_team`: a shift across Sunday night is
  split between the two weeks, and a shift left open from last week is
  listed (so a manager can close it) and counts from Monday.
* **Time on the job page.** `JobTimeSection` (the web TimeCard) lists the
  job's `time_entries` (`TimeClockService.jobEntries`, paged past the
  1,000-row reply cap) with member, start, end, duration and the total,
  says who is on the clock, and offers an assigned member "Clock in on
  this job" / "Clock out" through the same geostamped `clock_in` /
  `clock_out`. It stays live through `JobsRealtimeHub` `.timeEntries`;
  a completed, cancelled or no-show job never offers "Clock in" and hides
  the section when no time was recorded.
* **Customer screen:** custom fields (`OpsCustomerCustomDataSection`),
  documents (`OpsCustomerDocumentsSection`), referral link
  (`OpsReferralCodeRow`). Managers and up also see "Web form requests"
  (`CustomerLeadRequestsSection`, `CustomerService.leadRequests`): the
  message, vehicle described and answers of the customer's lead form
  submissions, newest 10 with the total (a lead form never changes an
  existing customer, so this is the only place the request is kept; the
  new-lead notification opens this screen). Jobs, quotes and invoices load
  50 at a time with the server's exact count (`CustomerService.jobsPage` /
  `quotesPage` / `invoicesPage`, DetailCore `HistoryList`): a longer
  history says "Showing the 50 most recent of 80 jobs." with "Load 30
  more", so every row the overview tiles count can be reached.
* **Settings:** booking link QR code (`OpsBookingQRView`) and the personal
  iCal feed in Your account (`OpsCalendarFeedRow`).
* **Reports:** `OpsEarningsCard` (technicians: their own; owners / admins:
  per member, by job), lead sources and quote conversion cards.

## Money screens (money agent)

* **Quotes** support up to 4 proposal options (`MoneyQuoteOption`,
  `MoneyQuoteOptionPicker`, `MoneyQuoteOptionsSection`); an approval
  records the chosen option; preset fees in the builder are added by
  `add_fee_line` on save. Every `add_fee_line` call sends
  `p_request_nonce`: a UUID string made once per user action (a fee line
  added to the quote draft, `QuoteDraftLine.feeRequestNonce`; a fee tapped
  in the job's fee picker) and reused when that action is retried, so a
  retry after a lost response never adds the fee twice.
* **Quotes and invoices** show their automatic follow-ups with a pause
  switch (`MoneyFollowupStatusRow`) and "Share PDF" (`MoneyPDFService`
  calls `pdf` `staff_document` and opens the share sheet).
* **Invoices** group lines by job for fleet invoices
  (`MoneyInvoiceGroupedLinesSection`), take gift cards and store credit
  (`MoneyGiftCardService`, `MoneyGiftCardRedeemSheet`), list bank and
  pay-later payments still clearing, and reload on realtime payment
  changes.
* **In-person payments:** `MoneyTapToPayModel` is the only place besides
  `MoneyTerminalTokenProvider` that imports StripeTerminal (its `Toggle`,
  `PaymentMethod` and `PaymentStatus` names clash with SwiftUI and
  DetailCore); it runs Tap to Pay or a Bluetooth reader and asks for
  location access first (see below). When a payment ends (paid,
  declined / failed, canceled) the progress sheet announces it to
  VoiceOver and moves focus to the result (DetailCore
  `PaymentOutcomeSpeech`): Apple's card screen has just closed, so the
  changed text alone isn't heard.
* **Memberships** support weekly plans, visit limits (`Membership.Usage`,
  `MoneyMembershipUsageRow`) and "Offer on the online join page". While
  the shop is lapsed, Memberships and the new-membership sheet show the
  paused notice (`BillingPausedNotice`, DetailCore
  `Notice.pausesNewRecords`) and "Create membership" waits, since the
  server refuses a new membership (PT402).
* **Payments ledger** rows say what the money pays (invoice or job — tap
  to open —, membership, or "Unapplied" with the server's note), and
  "Unapplied only" filters like the web's `?unapplied=1`. Managers and
  above get "Apply to invoice…" on unapplied money (`PaymentApplySheet`,
  `PaymentService.applyToInvoice` → `apply_payment_to_invoice`, releasing
  open card pay pages on 55000 `checkout_open` and trying once more);
  owners and admins get "Refund…" on any received payment (the invoice
  screen's `InvoiceRefundSheet`: Stripe-backed ones through `payments`
  `refund`, manual ones through `refund_manual_payment`).
* **Deposit due on the job page** (managers+, job still open):
  `JobsDepositRequestRow` texts or emails the shop's "Booking confirmed"
  message, which carries the booking link (`JobService.sendBookingLink`,
  `messaging` `send` with `template_key` `booking_confirmed`), or copies
  the link (`JobService.bookingLink`: `job_booking_token` +
  `WEB_APP_URL/booking/<token>`).
* **Save a card without charging** (customer screen, managers and above):
  `CustomerAddCardSheet` calls `payments` `setup_card` and opens Stripe's
  PaymentSheet in setup mode; the webhook stores the card and the sheet
  polls `PaymentService.awaitNewSavedCard` until it shows.
* **Legal links:** Create account, Sign in, the shop picker (under the
  choices and in its account menu), Create shop and Join a team show the
  Terms of Service and Privacy Policy (`LegalLinksFooter`, DetailCore
  `LegalNotice`, web `/terms` and `/privacy`) with the sentence that says
  the step counts as accepting the Terms; Your account lists them too.
* **Job price / deposit cuts** (line edits and removals, the discount, the
  deposit) are refused by the database while a deposit payment page of the
  job can still be paid (0118: 55000 HINT `checkout_open`). For members who
  may release payments, the job screens ASK first
  (`JobDetailModel.checkoutReleaseRequest`: "Cancel open payments"), since
  releasing closes the page the customer may be paying on. After the
  release (`JobService.releaseForEdit`: `cancel_open_payments` with
  `job_id`) the change is saved again only when no payment went through or
  is still processing (DetailCore `OpenCheckoutRefusal.releaseThenSaveAgain`);
  otherwise it is not saved, the job's money is re-read and
  `OpenCheckoutRefusal.releaseSummary` says what came in, like the web's
  job edit toast. Nothing re-checks a cut against what was paid, so it is
  never retried blindly (manual invoice payments are, because the server
  checks those against the balance again). Other members see the server's
  message, which says when the page closes.
* **Status reasons** (cancel reason, completion-gate override) are checked
  against the server's 500-character limit (DetailCore
  `Validation.statusReasonMaxLength`, counted like Postgres `char_length`)
  and sent whole; the app never cuts a reason short. The cancel reason is
  shown to the customer on their booking page.

## Shop subscription status (billing)

The iPhone app never sells anything: no plans, no prices, no purchase or
"manage billing" buttons or links (App Store 3.1.1 / 3.1.3). Owners buy
and manage the shop's subscription on the web app.

* `BillingService.entitlement(shopID:)` reads `shop_entitlement`
  (DetailCore `ShopEntitlement`). `BillingService.notice(shopID:)` never
  throws: a failed read shows nothing and never holds up a screen.
* `BillingNoticeBanner` (Core/Components/BillingNotice.swift) shows one
  neutral line under the Today greeting and under the account header in
  More (`.billingNotice($notice, shopID:)` reloads it on appear, shop
  change and return to the foreground):
  owner while trialing — "Trial ends <day, in the shop's time zone>.";
  owner while past due — "There's a problem with this shop's subscription
  payment."; everyone while lapsed — "This shop's subscription is
  inactive. Creating new jobs, quotes, invoices and customers is paused."
  Nothing while billing is off or the shop is active or comped.
* The database refuses new records of a lapsed shop (and invites past a
  plan's seat limit) with errcode `PT402` (HTTP 402). `ErrorText` shows
  the server's sentence for a `PostgrestError` with code PT402, a raw
  `HTTPError` 402 and an edge-function 402 (the neutral paused text when
  the server sent none). Edge functions answer it with the envelope
  `{error: <the database's sentence>, code: "payment_required", details:
  {reason: "subscription_inactive" | "seat_limit"}}`; `EdgeErrorDecoder`
  keeps `error` verbatim.
* `billing_payment_failed` notifications (owners only) are plain
  notifications: a neutral icon and the server's title and body; tapping
  one (in the list or as a push) opens nothing but the Notifications list.

## In-person payments (Stripe Terminal) — ships switched off

The app links `StripeTerminal` (4.x, SPM) and declares the Bluetooth and
location usage strings, but shows nothing until both flags are on:

1. Apple grants the **Tap to Pay on iPhone** entitlement to the team.
2. Add to `DetailCRM/DetailCRM.entitlements`:
   `<key>com.apple.developer.proximity-reader.payment.acceptance</key><true/>`
   (and enable the capability on the App ID so cloud signing includes it).
3. Set `TAP_TO_PAY_ENABLED` to `YES` in `Config.plist` (and
   `TERMINAL_BLUETOOTH_ENABLED` to `YES` to offer Bluetooth readers).
4. Stripe Terminal must be enabled on the connected accounts; the
   `payments` function creates the Terminal location and tokens.

`AppConfig.tapToPayEnabled` / `.terminalBluetoothEnabled` read the flags
(`YES` / `true` / `1`).

## Info.plist usage strings (pbxproj `INFOPLIST_KEY_*`)

Camera (photos, videos, VIN scanning), microphone (sound on walkaround
videos), photo library (read / add), location when in use (Tap to Pay
verification, geostamped clock-in, the day map), Bluetooth (card readers).

## Conventions (follow these in every feature)

1. **Services are static enums over `Supa.client`** — no view talks to
   Supabase directly. Money amounts are derived by the server; the app never
   sends totals or prices for server-priced flows.
2. **Every data screen owns a `LoadState<T>`** and renders it with
   `LoadStateView` (loading / error-with-retry / content); empty collections
   render `EmptyStateView`. Refresh failures while content is on screen go to
   `toasts.showError(error)`. Every toast is also announced to VoiceOver
   (`ToastCenter`, DetailCore `ToastSpeech`), so don't post a second
   announcement for the same outcome. Human text for any error: `ErrorText.message(for:)`
   (PostgREST errors keep the server's wording; PT402 / HTTP 402 is the
   shop's inactive subscription, see "Shop subscription status").
3. **Theme tokens only.** Colors, fonts, spacing, radii and button styles come
   from `Theme` (`.themePrimary`, `.themeMoney` for money actions only,
   `.cardStyle()`, `.screenBackground()`, …). Amber is reserved for money.
   `Theme.amber/success/warning/danger` are *fill* colors (buttons, badge
   tints, bars); text and icons use the matching ink (`moneyInk`,
   `successInk`, `warningInk`, `dangerInk`, `glacierInk`, or
   `Theme.color(for: tone)`), which meets WCAG AA 4.5:1 in both modes.
   `swift_sanity.py` rejects a fill color passed to `foregroundStyle`.
   White text (`Theme.onAccent`) sits only on the solid fills
   (`glacierSolid`, `dangerSolid`, `successSolid`, `neutralSolid`: at least
   4.5:1 in both modes; white on the dark-mode Glacier is 3.26:1), and
   Glacier text on a Glacier tint (`Theme.fill(for: .info)`,
   `Theme.glacier.opacity(…)`) uses `glacierInk`; both are checked too.
   Theme buttons wrap their labels at accessibility text sizes; put two or
   more side by side in `AdaptiveButtonRow` (it stacks them at AX sizes),
   never a bare `HStack` (also checked). Anything drawn for pointing only
   (the inspection diagram) needs a button path too (`JobVehicleView.areas`).
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
   (`swift_sanity.py` and `check_contracts.py` check it names a real
   function); code that calls `functions.invoke` itself reads failures with
   `EdgeFunctions.failure(from:)` so a gateway 401 reaches AppState. Every failure is an
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
11. **Money attempts.** Stripe refunds and saved-card charges send a
   `request_nonce` per attempt (`RequestAttempt` in DetailCore, the same rule
   as the web dialogs): kept when the server may have acted without
   answering (no answer, 5xx), so tapping again is a retry and never moves
   money twice; replaced after a success or a 4xx, so a deliberate second
   refund of the same amount is a new refund (without a nonce the server
   refuses it for 10 minutes as `possible_duplicate_refund`).
   Cash / check payments and gift card / store credit redemptions go
   through `PaymentService.releasingOpenCheckouts`: while a card payment
   page of the invoice (or of a job it bills) can still be paid the
   database refuses them (0109, 55000 HINT `checkout_open`), so the app
   releases the pages (`cancel_open_payments`) and tries once more
   (`OpenCheckoutRefusal` in DetailCore); a page already processing keeps
   the server's message, which names when it closes.
12. **Complete lists page.** PostgREST returns at most `max_rows` (1,000)
   rows per request whatever `.limit(...)` asks for, without saying so. A
   list the app must hold in full (the catalog's services and prices, which
   the price editor diffs against) is read with `PagedQuery.all`: ranges of
   500 with an exact count, ordered by a unique key; `PagedRows`
   (DetailCore) throws rather than return a partial list.

## Running locally (macOS with Xcode 26+)

1. Put your Supabase project URL and anon key in
   `DetailCRM/DetailCRM/Config.plist` (never commit real values). Until then
   the app launches into a "Setup required" screen. The committed file holds
   only `YOUR_…` placeholders and no workflow fills it: `ios.yml` builds for
   the simulator with the placeholders, and any archive/TestFlight pipeline
   must write the real values from repository secrets before building.
2. Open `DetailCRM/DetailCRM.xcodeproj`, let Swift packages resolve
   (supabase-swift 2.x, stripe-ios-spm 24.x, stripe-terminal-ios 4.x, local
   `../DetailCore`), choose an iPhone simulator and run. Push notifications
   need a device and a team with the Push Notifications capability; the
   simulator build signs without them.
3. DetailCore tests: `cd ios/DetailCore && swift test` (works on macOS and on
   Linux with a Swift 5.9+ toolchain).

TestFlight builds come from `.github/workflows/ios-testflight.yml`
(`fastlane/Fastfile`, docs/DEPLOY.md section 5). They must be built with
Xcode 26 / the iOS 26 SDK or later: App Store Connect rejects uploads from
older SDKs (Apple's minimum since April 28, 2026). Both workflows pick the
Xcode with `ci/select_xcode.sh` (newest release Xcode, at least
`MIN_XCODE_MAJOR` = 26; tests in `ci/select_xcode_test.sh`) and the lane
refuses to upload an archive built with an older SDK (`MIN_UPLOAD_SDK_MAJOR`). The build number rises by
itself; the app version (`MARKETING_VERSION`, 1.0) does not: after each App
Store approval run the workflow with `app_version` or raise
`MARKETING_VERSION` in the project, or the upload is rejected.

## How CI verifies (`.github/workflows/ios.yml`)

Runs on `macos-26` with the TestFlight workflow's Xcode (`ci/select_xcode.sh`,
26 or later) for pushes that touch `ios/**`, `scripts/swift_sanity.py`
or the workflow, and on manual dispatch (macOS minutes are expensive — batch
iOS changes):

1. `python3 scripts/swift_sanity.py --self-test` and `python3 scripts/swift_sanity.py`
   (bracket balance ignoring strings/comments, pbxproj id integrity,
   model annotations, forbidden patterns, sign-out only through
   `ConfirmationRequest.signOut`, the workflows' Xcode choice through
   `ci/select_xcode.sh`, FEATURE_STUB count; `--strict`
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
