# Detail CRM — Product & Architecture Spec (source of truth)

Detail CRM is a multi-tenant CRM for auto-detailing, ceramic-coating, tint and
PPF shops — a from-scratch, feature-equivalent alternative to Urable. Any
shop signs up, gets an isolated workspace, and runs its whole business from a
**web app** (staff dashboard + public booking + client portal) and a native
**iPhone app** (staff), both on **one Supabase database**.

Nothing in this repo may copy Urable's name, logo, copy, or visual design.
We replicate *capabilities*, not branding.

---------------------------------------------------------------------------

## 1. Stack

| Layer | Choice |
|---|---|
| Database / auth / storage / realtime | Supabase (Postgres 15+, RLS on every table) |
| Server logic | Postgres functions (RPC) first; Supabase Edge Functions (Deno 2, TypeScript) only for third-party calls (Stripe, Twilio, Resend) and webhooks |
| Payments | Stripe **Connect** (each shop connects its own Express account; platform uses direct charges with `Stripe-Account` header; optional `PLATFORM_FEE_BPS` application fee) |
| SMS | Twilio (platform account; each shop has `sms_from_number`) |
| Email | Resend |
| Web | Vite + React + TypeScript (strict) + React Router + TanStack Query + supabase-js v2 + Tailwind CSS v4 + FullCalendar (MIT plugins only) + react-hook-form + zod + date-fns/date-fns-tz + Recharts |
| iOS | SwiftUI, iOS 17+, Observation (`@Observable @MainActor`), supabase-swift 2.x, StripePaymentSheet; pure logic in local Swift package `ios/DetailCore` with XCTest tests |
| CI | GitHub Actions: `db.yml` (Postgres service + SQL tests), `web.yml`, `functions.yml` (deno check/test), `ios.yml` (macOS xcodebuild + `swift test`) |

## 2. Repository layout

```
docs/                 SPEC.md (this), SCHEMA.md (generated/maintained column-level contract), DECISIONS.md
supabase/
  migrations/         numbered SQL (see §9 ranges)
  tests/              SQL test suite (plain SQL + assertions) run on real Postgres
  shim/               local-only Supabase compatibility shim (auth schema, roles, storage stub)
  functions/          edge functions (Deno)
  setup/              one-time SQL needing project values (pg_cron schedules)
scripts/              test runners, type generators, contract checkers
web/                  Vite React app
ios/DetailCRM/        Xcode project (hand-written pbxproj, file-system-synchronized groups)
ios/DetailCore/       Swift package with pure logic + tests
.github/workflows/    CI
```

## 3. Tenancy, identity, roles

* `auth.users` — Supabase auth. `profiles` (id = auth user id, full_name, phone, avatar_path).
* `shops` — the tenant. Every tenant-owned table carries `shop_id uuid not null`
  (denormalized, even on child tables) so RLS is a single indexed check.
* `shop_members` — (shop_id, user_id, role, display_name, phone, calendar_color, active).
  Unique (shop_id, user_id).
* Staff roles (`shop_role` enum): `owner`, `admin`, `manager`, `technician`.
* **Client** users (customers) are plain auth users linked to `customers.portal_user_id`.
  Clients have **no direct table access**; everything they see comes from
  curated `portal_*` SECURITY DEFINER RPCs. Anonymous visitors likewise only use
  `public_*` RPCs keyed by slug or unguessable token.

### Capability matrix (enforced by RLS/RPC — never only in UI)

| Capability | owner | admin | manager | technician |
|---|---|---|---|---|
| Shop settings, branding, taxes, booking settings, templates | ✓ | ✓ | ✗ (read) | ✗ (read basic shop info) |
| Stripe Connect, SMS number, delete/transfer shop | ✓ | ✓ (no delete/transfer) | ✗ | ✗ |
| Team: invite, change roles, deactivate | ✓ | ✓ (cannot modify owner or other admins' role to owner) | view | view names/colors only |
| Pay rates / commission (`member_compensation`) | ✓ | ✓ | ✗ | own row read-only |
| Customers & vehicles | all | all | all | read only those on jobs assigned to them |
| Service catalog | edit | edit | edit | read |
| Jobs / calendar | all | all | all | read assigned jobs (+ calendar busy blocks of others without customer details); progress status, checklist, photos, inspections, forms on assigned jobs |
| Quotes, invoices, payments, memberships | all | all | all | only if `shops.techs_can_collect_payments`: read invoice of assigned job + collect payment |
| Refunds, void invoices | ✓ | ✓ | ✗ | ✗ |
| Saved cards, charge card on file | ✓ | ✓ | ✓ | ✗ |
| Reports | all | all | all | own hours/jobs/commission only |
| Messages inbox (2-way SMS/email), campaigns | ✓ | ✓ | ✓ | send templated "on my way"/"job complete" for assigned jobs only |
| Time clock | all entries | all entries | all entries (edit) | own clock in/out; cannot edit closed entries |

Helper SQL functions (SECURITY DEFINER, STABLE, `set search_path = ''`):
`is_shop_member(shop_id)`, `shop_role_of(shop_id) returns shop_role`,
`has_shop_role(shop_id, variadic shop_role[])`, `is_assigned_to_job(job_id)`.

## 4. Domain model (tables)

All ids `uuid default gen_random_uuid()`; timestamps `timestamptz`; money is
**integer cents**; rates are **basis points** (`_bps`); every table has
`created_at`, most have `updated_at` (trigger). Soft-delete via `archived_at`
on customers, vehicles, services, membership_plans, resources.

### 4.1 Shop setup
* `shops` — name, slug (unique, url-safe), email, phone, website, address (line1, line2, city, region, postal_code, country), lat/lng, timezone (IANA), currency (`usd`), logo_path, brand_color, business_type (`fixed`|`mobile`|`both`), tax_rate_bps, techs_can_collect_payments, review_url, quote_terms, invoice_terms, invoice_due_days, sms_from_number (read via RPC by staff; write admin+), created_by.
* `shop_stripe_accounts` — shop_id pk, stripe_account_id, charges_enabled, payouts_enabled, details_submitted, updated_at. Read admin+; write service_role only.
* `shop_invites` — shop_id, email, role, token (unique), invited_by, expires_at, accepted_at, revoked_at.
* `member_compensation` — shop_id, member_id pk, hourly_rate_cents, commission_bps.
* `shop_counters` — (shop_id, kind) → next value; `next_document_number(shop, kind)` for `job`, `quote`, `invoice` (human numbers like 1001).
* `vehicle_categories` — shop-defined size classes (e.g. Car, Small SUV, Large SUV/Truck, Van) with sort. Seeded on shop creation (names only — never prices).
* `business_hours` — shop_id, weekday 0–6, opens_at time, closes_at time (multiple rows per day allowed; no row = closed).
* `blocked_times` — shop_id, member_id nullable (null = whole shop), starts_at, ends_at, reason.
* `resources` — bays/vans: shop_id, name, kind (`bay`|`van`|`other`), active.
* `booking_settings` — shop_id pk: enabled, auto_confirm, lead_time_minutes, max_days_ahead, slot_interval_minutes, buffer_minutes, max_concurrent_jobs, require_deposit, deposit_type (`percent`|`fixed`), deposit_value, service_area_postal_codes text[], booking_message, cancellation_policy, allow_client_cancel_hours.

### 4.2 CRM
* `customers` — first_name, last_name, company, email (citext), phone (E.164), address fields, lat/lng, notes, tags text[], lifecycle (`lead`|`customer`), source (`staff`|`online_booking`|`referral`|`google`|`facebook`|`instagram`|`walk_in`|`other`), sms_opt_in, email_opt_in, portal_user_id, stripe_customer_id, archived_at, phone_unverified (the phone came from the public booking form of a booker who did not prove the email; 0042). Indexes for search (trigram on name/email/phone where available).
* `vehicles` — customer_id, year, make, model, trim, color, vin, license_plate, category_id, notes, archived_at. (VIN decode via NHTSA vPIC from clients — free, no key.)

### 4.3 Catalog
* `service_categories` — name, sort.
* `services` — category_id, name, description, kind (`service`|`package`|`addon`|`product`), duration_minutes, taxable, online_bookable, active, sort, image_path, archived_at.
* `service_prices` — service_id, vehicle_category_id nullable (null = base), price_cents, duration_minutes override. Unique (service_id, vehicle_category_id) with nulls-not-distinct semantics.
* `package_items` — package_id → service_id (what a package includes).
* `service_addons` — service_id → addon_id (add-ons offered with a service; none = all add-ons offered).
* `coupons` — code (unique per shop, case-insensitive), kind (`percent`|`fixed`), value, starts_at, ends_at, max_redemptions, redemptions, online_only, active.

### 4.4 Jobs & scheduling (the core work order)
* `jobs` — number, customer_id, vehicle_id (primary, nullable), status, scheduled_start, scheduled_end, location_type (`shop`|`mobile`), service address fields + lat/lng, resource_id, notes (customer-visible), internal_notes, source (`staff`|`online_booking`|`quote`|`membership`), quote_id, coupon_id, subtotal_cents, discount_cents, tax_rate_bps, tax_cents, total_cents (all server-maintained), deposit_required_cents, public_token, created_by, confirmed_at, en_route_at, started_at, completed_at, cancelled_at, cancel_reason, reminder_sent_at, review_requested_at.
* Job status (`job_status`): `requested` → `scheduled` → `confirmed` → `en_route` → `in_progress` → `completed`; side exits `cancelled`, `no_show`. Transitions validated by trigger; timestamps stamped by trigger. Managers+ may move backward; technicians only forward along en_route/in_progress/completed on assigned jobs.
* `job_line_items` — job_id, service_id nullable, vehicle_id nullable, name, description, quantity numeric(10,2), unit_price_cents, discount_cents, taxable, duration_minutes, sort. Totals trigger recomputes the parent.
* `job_assignments` — job_id, member_id (technicians/any staff).
* Scheduling RPCs: `get_available_slots(shop_slug, service_ids uuid[], from_date, to_date, vehicle_category_id default null)` (public; a shop without vehicle categories books on base prices) honoring business_hours, blocked_times, existing jobs, buffer, capacity (`max_concurrent_jobs`), lead time, max days ahead, shop timezone; `calendar_events(shop, from, to)` for staff (technicians get other jobs as anonymized busy blocks).

### 4.5 Money
* **Totals rule (identical everywhere):** line_total = round(quantity × unit_price) − line discount (≥0). subtotal = Σ line_total. Document discount (coupon or manual) applies to subtotal, capped at subtotal. Tax = round_half_up(taxable_base × tax_rate_bps / 10000) where taxable_base = Σ taxable line_totals minus the document discount prorated to taxable lines. total = subtotal − discount + tax. **Tips never change totals or balances.** Server computes; clients never send totals.
* `quotes` + `quote_line_items` — status `draft|sent|viewed|approved|declined|expired|converted`; valid_until, notes, terms, totals, public_token, sent_at, viewed_at, approved_at, approved_by_name, declined_reason, converted_job_id. Line items support `optional` + `selected` (client picks optional upsells when approving). `convert_quote_to_job(quote_id, start, end)`.
* `invoices` + `invoice_line_items` — status `draft|open|partially_paid|paid|void`; job_id (≤1 non-void invoice per job), customer_id, issued_at, due_at, totals, amount_paid_cents, balance_cents (= total − paid), tip_cents (sum of tips), public_token. `create_invoice_from_job(job_id)` copies lines and attaches that job's earlier deposit payments. Status auto-maintained from payments.
* `payments` — invoice_id nullable, job_id nullable, customer_id, kind (`deposit`|`payment`|`membership`), method (`card`|`card_present`|`cash`|`check`|`bank_transfer`|`other`), status (`pending|succeeded|failed|cancelled|refunded|partially_refunded`), amount_cents (excludes tip), tip_cents, refunded_cents, stripe_payment_intent_id (unique), stripe_charge_id, stripe_checkout_session_id, card_brand, card_last4, note, recorded_by, paid_at, disputed_cents (money a lost card dispute took back, `apply_stripe_dispute`; informational — balances, net amounts and revenue are NOT changed by a dispute: staff decide whether to bill the customer again). **Card rows are written only by service_role (edge functions/webhook).** Manual rows via `record_manual_payment(invoice_id, amount_cents, method, tip_cents, note)` (manager+, or technician when allowed on assigned job). Never store card numbers — only Stripe ids, brand, last4.
* `customer_payment_methods` — customer_id, stripe_payment_method_id, brand, last4, exp_month, exp_year, is_default (manager+ read; service_role write).
* `membership_plans` — name, description, price_cents, interval (`month`|`year`), interval_count, included_service_ids uuid[], discount_bps (on other services), active, stripe_product_id, stripe_price_id.
* `memberships` — plan_id, customer_id, vehicle_id, status (`incomplete|active|past_due|cancelled`), stripe_subscription_id, current_period_end, started_at, cancelled_at.
* `stripe_events` — event id pk (idempotency), type, account, received_at, processed_at, error.

### 4.6 Field operations
* `checklist_templates` — name, items jsonb (`[{id,label}]`), service_id nullable (auto-attach when that service is on a job).
* `job_checklist_items` — job_id, label, sort, done_at, done_by.
* `inspections` — job_id, vehicle_id, kind (`pre`|`post`), mileage, fuel_level, notes, customer_signature_path, signed_by_name, signed_at, created_by.
* `inspection_marks` — inspection_id, view (`front|rear|left|right|top|interior`), x, y (0–1 floats), damage (`scratch|dent|chip|crack|stain|swirl|other`), note, photo_path.
* `job_photos` — job_id, storage_path, kind (`before|after|inspection|other`), caption, uploaded_by.
* `form_templates` — name, body (markdown), requires_signature, attach_to (`all_jobs|online_booking|manual`), active.
* `form_submissions` — form_template_id, job_id, customer_id, body_snapshot, public_token, signer_name, signature_path, signed_at, signer_ip.
* `time_entries` — member_id, job_id nullable, kind (`shift`|`job`), clock_in, clock_out, source (`app`|`web`|`manual`), notes. RPCs `clock_in(shop, job_id?)`, `clock_out(shop)`; at most one open entry per member per kind; no overlaps.
* Storage buckets: `job-photos` (private), `signatures` (private), `shop-assets` (public read; logos/service images). Object path first segment = `shop_id`; storage RLS checks membership (and assignment for technicians where applicable). Deleting a shop, job, inspection or form queues its files for the `storage-purge` function (rows never delete files themselves).

### 4.7 Communication
* `message_templates` — key (`booking_request_received|booking_confirmed|appointment_reminder|on_the_way|job_started|job_completed|quote_sent|invoice_sent|payment_receipt|review_request|follow_up|membership_welcome|invite`), channel (`sms`|`email`), subject, body with `{{placeholders}}` (documented list), enabled, offset_minutes (for time-based ones). Generic default wording seeded per shop.
* `messages` — customer_id, job_id, direction (`outbound|inbound`), channel, to_address, from_address, subject, body, status (`queued|sending|sent|delivered|failed|received`), send_after, provider_message_id, error, template_key, sent_by, read_at. Doubles as the send queue.
* `enqueue_due_automations()` (service_role/cron) queues reminders, review requests, follow-ups exactly once per job (idempotent markers); `claim_queued_messages(limit)` (service_role) locks rows for the sender with `for update skip locked`.
* `campaigns` + `campaign_recipients` — blasts to opted-in customers filtered by tags/lifecycle/last-visit; recipients materialize into `messages`.
* `notifications` — in-app staff notifications (recipient user_id, shop_id, kind, title, body, deep links job_id / customer_id / quote_id / invoice_id, read_at) created by triggers: new online booking, quote approved/declined, payment received, inbound message, form signed.
* Realtime publication: jobs, messages, notifications, payments, time_entries.

### 4.8 Reports (RPCs, manager+; technicians get own-only variants)
`dashboard_summary(shop)`, `report_revenue(shop, from, to, bucket)`, `report_sales_by_service(shop, from, to)`, `report_team(shop, from, to)` (hours, jobs, revenue, commission, labor cost), `report_customers(shop, from, to)` (new vs returning, top by lifetime value), `report_outstanding(shop)` (open balances, aging), `report_payments(shop, from, to)` (by method, tips, refunds, fees if known). All time bucketing in the shop's timezone.

### 4.9 Public & portal RPCs (SECURITY DEFINER, explicit `set search_path = ''`, grant to anon/authenticated as appropriate)
* `public_shop_profile(slug)`, `public_booking_catalog(slug)`, `get_available_slots(...)`, `create_online_booking(slug, payload jsonb)` → validates slot/services/area/coupon server-side, upserts customer by email/phone within the shop (never onto a record whose unverified phone differs from the form's), creates vehicle, job (`requested` or `scheduled` per auto_confirm), line items priced from the catalog, returns job public_token.
* `public_get_booking(token)`, `public_cancel_booking(token)` (respecting `allow_client_cancel_hours`).
* `public_get_quote(token)` (marks viewed), `public_respond_quote(token, action, signer_name, selected_optional_item_ids)`.
* `public_get_invoice(token)`.
* `public_get_form(token)`, `public_sign_form(token, signer_name, signature_path)`.
* `portal_claim_customers()` — links customers whose email equals the caller's **confirmed** auth email.
* `portal_overview()` — the caller's shops, vehicles, upcoming/past jobs, open quotes, invoices, memberships (curated columns only).
* `create_shop(name, slug, timezone, ...)` → creates shop + owner membership; each domain migration seeds its own defaults via `AFTER INSERT ON shops` triggers. `accept_invite(token)`.
* `search_shop(shop, query)` — global search over customers, vehicles, jobs, quotes, invoices.

## 5. Edge functions (supabase/functions)

Shared `_shared/` (cors, supabase admin client, auth → caller membership check, Stripe client factory, Twilio/Resend clients, template renderer, errors). Every function validates the caller's JWT and role **server-side**, derives all amounts from the database, and never trusts client totals.

| Function | Actions |
|---|---|
| `stripe-connect` | `create_account_link`, `refresh_status`, `login_link` (admin+) |
| `payments` | `invoice_checkout` (public by invoice token → Checkout Session on connected account for current balance), `booking_deposit_checkout` (public by booking token), `payment_sheet` (staff; PI for balance or partial ≤ balance + connected account id for iOS PaymentSheet; Stripe customer + ephemeral key only for manager+ — technicians never see saved cards; a new sheet supersedes the invoice's unconfirmed ones), `cancel_open_payments` (same callers; by `invoice_id` or `job_id`: cancels unconfirmed sheets + expires open Checkout links so the invoice can be voided/edited, or before a job is cancelled / no-show / moved to another customer), `sweep_payment_sheets` (pg_cron: abandons sheets unconfirmed 30+ min), `charge_saved_card` (manager+; a card Stripe no longer has is removed: 422 `saved_card_removed`), `remove_saved_card` (manager+; detach in Stripe, then remove), `setup_card` (SetupIntent), `refund` (admin+), `membership_checkout`, `membership_cancel` (expires open links; stops a subscription still billing a cancelled membership), `delete_shop` (owner; typed shop name; settles card attempts — 409 while one is processing — expires every open link, cancels every membership's subscription now, then deletes the shop; the Connect account is left to the owner). Card-only everywhere (`payment_method_types ['card']`). Public Checkout sessions live ~30–40 min and a new link expires the document's older open links |
| `stripe-webhook` | Connect webhook (signature verified, idempotent via `stripe_events`): checkout.session.completed, payment_intent.succeeded/payment_failed/canceled, charge.refunded, charge.refund.updated, refund.updated, refund.failed (a failed refund lowers the refunded total: `set_stripe_refund_total`), setup_intent.succeeded, payment_method.detached, customer.deleted (saved cards follow Stripe), charge.dispute.created/updated/closed/funds_withdrawn/funds_reinstated (outcome in `payments.disputed_cents` via `apply_stripe_dispute`, note + owner/admin notification; balances unchanged), customer.subscription.created/updated/deleted, invoice.paid/payment_failed, account.updated. A card payment that settles an invoice cancels the invoice's other waiting PaymentSheets |
| `messaging` | `send` (staff: free-form or template to customer, role-checked; `quote_id` / `invoice_id` send quote_sent / invoice_sent rendered by the database, manager+; `request_nonce` makes a retry return the same message), `process_queue` (cron secret; sends via Twilio/Resend, updates status), `twilio_inbound` (X-Twilio-Signature verified; routes by To number to shop + by From to customer; STOP opts out, START/UNSTOP/YES opt back in), `twilio_status` |
| `invites` | `send_invite` (admin+; emails invite link) |
| `storage-purge` | `purge` (pg_cron, cron secret): removes the stored files of deleted shops/jobs/inspections/forms queued in `storage_purge_requests` via the Storage API |
| `account` | `delete_account` (any signed-in user, own account; 409 `owns_shops` while they own a shop — transfer ownership or delete it first; App Store 5.1.1(v)) |

Secrets (function env, never in repo): `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PUBLISHABLE_KEY`, `PLATFORM_FEE_BPS`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `RESEND_API_KEY`, `EMAIL_FROM`, `APP_BASE_URL`, `CRON_SECRET`.

## 6. Web app (web/)

* Public: `/login`, `/signup`, `/forgot-password`, `/reset-password`, `/invite/:token`, `/book/:slug` (booking wizard: vehicle → services/add-ons priced by category → date/slot → contact/address → coupon → deposit via Checkout), `/booking/:token` (manage/cancel/pay deposit), `/q/:token` (quote view/approve with optional items + typed signature), `/i/:token` (invoice view/pay), `/f/:token` (form sign with drawn signature), `/portal` (client portal).
* Staff (`/app`, shop switcher in header): onboarding (create shop), dashboard, calendar (day/week/month + resource view, drag/resize reschedule), jobs list + job detail (status stepper, line items, assignments, checklist, photos, inspections, forms, invoice/payments, messages), customers (list/search/detail/history/vehicles/notes/tags/cards/memberships), quotes, invoices, payments, memberships (plans + subscribers), messages inbox (threads by customer, realtime), campaigns, reports (charts), team (invites, roles, compensation), timesheets, catalog (services/packages/add-ons/prices per category/checklists), settings (business, branding, booking & hours, blocked times, resources, taxes, vehicle categories, coupons, templates & automations, forms, payments/Stripe Connect, SMS), notifications.
* Every screen renders loading / empty / error states. Money formatted from cents. Dates in shop timezone.
* Feature code lives in `web/src/features/<feature>/` exposing `routes.tsx`; the shell's route registry imports each feature's routes (stubs pre-created) so features never edit shared files.

## 7. iPhone app (ios/)

Staff app (owner/admin/manager/technician; features hidden AND server-enforced by role):
Sign in/up/reset → shop picker / create shop → tabs **Today** (dashboard, next job, clock in/out), **Calendar** (agenda/day/week), **Customers**, **Inbox** (2-way messages), **More** (Quotes, Invoices, Payments, Memberships, Time clock & timesheets, Reports, Team, Catalog, Settings subset, Notifications, switch shop, sign out).
Job detail: status stepper, customer & vehicle cards (call/text/navigate), line items editor, assignments, checklist, before/after photos (camera + library, upload to Storage), inspection (vehicle diagram with tap-to-mark damage + photo + customer signature), forms signing on device, collect payment (PaymentSheet on connected account; cash/check record), send templated "on my way", create invoice.
New job flow: customer (search/create) → vehicle (VIN decode via NHTSA vPIC) → services priced by vehicle category → date/time with availability → assign → save.
Quote builder + send; invoice detail + send link + collect.
Architecture mirrors good SwiftUI practice: Theme tokens only, services as static enums over one `Supa.client`, per-screen `LoadState`, AnyView seams on very large screens to avoid generic-metadata stack overflows, no types nested in generic functions.

## 8. Quality gates ("no mistakes" policy)

1. **SQL:** every migration applies cleanly from zero on real Postgres 16 with the shim; test suite covers RLS isolation between two shops for every table, every role's allowed/denied operations, totals math, status transitions, slot generation (incl. DST), booking RPC validation, invoice/payment balance, public/portal RPC data exposure (no internal fields), automations idempotency. `scripts/test_db.sh` must pass.
2. **Contract:** `scripts/gen_types.py` generates `web/src/lib/database.types.ts` + `docs/SCHEMA.md` from the live schema; `scripts/check_contracts.py` verifies every table/column/RPC referenced by web (typed), iOS (CodingKeys, `.from(...)`, `.eq(...)`, `.rpc(...)`) and edge functions exists with matching names.
3. **Edge functions:** `deno check` + `deno test` (Stripe/Twilio/Resend faked) pass.
4. **Web:** `tsc -b`, eslint, vitest, `vite build`, Playwright smoke (mocked backend) pass.
5. **iOS:** `xcodebuild` (simulator, no signing) + `swift test` for DetailCore pass on GitHub Actions macOS.
6. Adversarial multi-lens review (security/RLS, money correctness, spec completeness, UX states) until two consecutive rounds find nothing.

## 9. Migration numbering (parallel-safe ranges)

| Range | Domain |
|---|---|
| 0001–0009 | foundation: extensions, enums, helpers, profiles, shops, members, invites, counters, vehicle categories, hours, blocks, resources, booking settings, customers, vehicles, catalog, coupons, jobs, line items, assignments, scheduling RPCs, create_shop, accept_invite |
| 0010–0019 | money: quotes, invoices, payments, saved cards, memberships, stripe_events, money RPCs, public quote/invoice RPCs |
| 0020–0029 | field ops: checklists, inspections, photos, forms, time entries, storage buckets/policies |
| 0030–0039 | communication: templates, messages/queue, automations, campaigns, notifications |
| 0040–0049 | reports, dashboard, search, portal, online booking RPCs, realtime publication |
| 0050–0059 | scheduling v2: recurring job series, calendar event kinds / time off / capacity v2, private booking links, calendar (iCal) feeds, geostamped clock-in |
| 0060–0069 | money v2: Stripe Terminal locations, multi-job invoices + per-line vehicles, tip attribution + commissions, coupon restrictions, gift cards, fees, proposal options, quote self-scheduling, memberships v2 |
| 0070–0079 | field ops v2: customer-facing job reports + remote inspection sign-off, required checklists, documents, customer merge |
| 0080–0089 | comms & integrations v2: push notifications, document follow-ups, multi reminders + per-service maintenance reminders, CSV import/export, custom fields + lead forms, booking embed/pixels, SMS number provisioning |
| 0090–0099 | cross-cutting hardening and integration fixes (grants audit, indexes, cross-surface contract additions) |

Parity roadmap (from the Urable parity audit, 2026-09-27): P0 recurring jobs, push notifications, document follow-ups, multiple + per-service reminders, CSV import/export, Tap to Pay / Terminal (ships dark until Apple grants the entitlement); P1 multi-job invoicing, customer job reports, lead forms + custom fields, booking embed/QR/pixels, required checklists, tips + commissions, coupon restrictions, gift cards, self-serve SMS numbers (gated on Twilio ISV onboarding); P2 proposal options, quote self-scheduling, calendar events/capacity v2, day map + route hand-off, iCal feeds, customer merge, preset fees, VIN barcode scan, memberships v2, geostamped clock-in, documents, iOS realtime. Not built (partner agreements / compliance): QuickBooks sync, own processing, Carfax/Sirius XM, 3D visualizer, marketplace/store, voice calling, Android app, workflow builder, route optimization engine, Reserve with Google, card surcharging.
