# Edge functions (Deno 2)

Server logic lives in Postgres (RLS + RPC) first. Edge functions exist only
for third-party calls (Stripe, Twilio, Resend) and webhooks (SPEC section 5).

```
supabase/functions/
  deno.json            shared import map (exact pinned versions), fmt/lint/test config
  .env.example         local secrets template (copy to .env.local, git-ignored)
  _shared/             helpers every function uses (never deployed on its own)
    actions.ts         action routing: JSON {action,...} or ?action= for raw webhooks
    auth.ts            requireUser, requireShopRole, requireJobAccess, requireCronSecret
    billing_plans.ts   shop subscription plans: platform Stripe Products/Prices -> platform_plans
    cors.ts            exact-origin CORS (APP_BASE_URL + CORS_ALLOWED_ORIGINS)
    crypto.ts          timingSafeEqual, HMAC, sha256, randomToken, hex/base64
    env.ts             typed, validated env (EnvError names the bad variable)
    errors.ts          HttpError + stable error codes, UpstreamError
    http.ts            createHandler, json(), parseJson/readForm/readText, error mapping
    ids.ts / links.ts  uuid + Stripe account checks, request ids, customer links
    log.ts             JSON-line logger with secret redaction
    money.ts           integer-cent helpers (round half away from zero, like SQL)
    resend.ts          sendEmail (REST)
    schemas.ts         zod schemas: uuid, cents, e164, email, public link token (uuid), request nonce
    stripe.ts          client factory (pinned apiVersion), onAccount, webhook verify, idempotency keys
    stripe_errors.ts   Stripe SDK error -> client-safe HttpError
    stripe_events.ts   webhook idempotency on the stripe_events ledger (received != processed)
    supabase.ts        adminClient, userClient, getCaller (Auth outage/throttling -> 503, not 401)
    templates.ts       {{placeholder}} rendering (parity with SQL render_template; numbers never in exponent form)
    twilio.ts          sendSms, X-Twilio-Signature validation, opt-out keywords, TwiML
    twilio_urls.ts     the platform's Twilio webhook URLs (inbound binding, status callback)
    fetch_timeout.ts   withTimeout: per-request time cap (body included) for Twilio/Resend calls
    apns.ts            APNs provider JWT (ES256, cached 50 min) + send with answer classification
    ics.ts             RFC 5545 calendar rendering (escaping, 75-octet folding, UTC instants)
    pdf.ts             pdf-lib page writer (wrapping, tables, page breaks, watermark, footers)
                       + PNG/JPEG structure checks before embedding
    ssrf.ts            outbound URL guard: https host names only, resolved addresses public
    webhook_sign.ts    X-DetailCRM-Signature (t=,v1= HMAC-SHA256) sign + reference verify
    testing/           FakeFetch, FakeSupabase, request builders, test env, Stripe signer,
                       APNs test keys, PDF text extraction, image fixtures
  <function>/index.ts  one directory per deployed function (stripe-connect, payments,
                       stripe-webhook, messaging, invites, storage-purge, account, push,
                       calendar-feed, public-media, sms-provisioning, webhooks, pdf,
                       billing, billing-webhook)
```

## Writing a function

Follow `_shared/testing/example_function_test.ts`; it is a complete,
tested template. The shape:

```ts
// supabase/functions/<name>/index.ts
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { createHandler } from "../_shared/http.ts";
import { uuid } from "../_shared/schemas.ts";
import { adminClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch; // tests inject FakeFetch/FakeSupabase here
}

export function makeHandler(deps: Deps = {}) {
  const router = createActionRouter({
    refresh_status: jsonAction(z.object({ shop_id: uuid }).strict(), async (input, ctx) => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const caller = await requireUser(ctx.req, { admin });
      await requireShopRole(admin, caller, input.shop_id, ROLES.adminPlus);
      // ... work, always scoped to input.shop_id ...
      return { ok: true };
    }),
  });
  return createHandler({ name: "<name>", env: deps.env }, (req, ctx) => router(req, ctx));
}

if (import.meta.main) Deno.serve(makeHandler());
```

Add `[functions.<name>]` to `supabase/config.toml` (with a comment explaining
`verify_jwt`) and to `EXPECTED_VERIFY_JWT` in `_shared/config_test.ts`; the
test fails if a function directory is not declared.

### Routing by action

- **JSON actions:** `POST /functions/v1/<fn>` with `{"action": "refund", ...params}`.
  `params` (the body minus `action`) is validated by the action's zod schema.
  Use `.strict()` object schemas so unexpected fields (e.g. a client-sent
  `amount_cents` or `total`) are rejected, not silently ignored.
- **Raw actions:** webhooks that must verify a signature over the untouched
  body use `rawAction` and are selected by query string:
  `/functions/v1/messaging?action=twilio_inbound`. Raw actions can never be
  reached through a JSON body.
- Unknown/missing action -> `400 unknown_action`.
- Web calls functions with `supabase.functions.invoke(name, { body })`;
  iOS with `client.functions.invoke(name, options: .init(body: ...))`.

### Auth rules

| Audience | How the function authenticates |
|---|---|
| Staff | `requireUser` (JWT verified via `auth.getUser`, anonymous users rejected) then `requireShopRole(admin, caller, shopId, ROLES.x)` using the **shop_id of the row being acted on** (look the row up first; never trust a client-sent shop id alone). Technicians on job-scoped actions: `requireJobAccess`. |
| Public by token | Look the row up by its unguessable `public_token` (validate with `schemas.publicToken`, a UUID: every token column and `public_*` RPC `p_token` is `uuid`, so a malformed link is a 400 here instead of a 22P02 cast error/500 from Postgres); a well-formed token with no row is `404 not_found`. The token is the credential. Return only curated fields. |
| Stripe | `verifyStripeWebhook(stripe, rawBody, req.headers.get("stripe-signature"), env.stripeWebhookSecret())` before parsing anything (`billing-webhook`: `env.stripeBillingWebhookSecret()`, the platform endpoint's own secret). |
| Twilio | `validateTwilioSignature(authToken, req.headers.get("x-twilio-signature"), publicRequestUrl(env.functionsPublicUrl(), "messaging", req), form)` — validate against the **public URL configured in Twilio**, not `req.url`. |
| pg_cron | `requireCronSecret(req, env.cronSecret())` (`x-cron-secret` header, constant-time compare). |

Role sets: `ROLES.anyStaff`, `ROLES.managerPlus`, `ROLES.adminPlus`,
`ROLES.owner` — mirror SQL `is_shop_member` / `is_shop_manager` /
`is_shop_admin` and the SPEC section 3 capability matrix. Inactive members have
no role. Non-members and wrong roles both get `403 forbidden`.

Use `adminClient()` (service role, bypasses RLS) only after authorization and
only with queries filtered by the authorized `shop_id`; prefer
`userClient(req)` for anything the caller could do directly, so RLS remains
the enforcement point. Card payment rows, `stripe_events`,
`customer_payment_methods` and message status are service-role writes.

### Money

- Amounts are **always derived from the database** (invoice balance, deposit
  required, plan price). A client may only *request* a partial amount where
  the SPEC allows it (`payment_sheet`), validated `0 < amount <= balance`
  server-side. Never accept totals, prices, tax or fees from a client.
- Integer cents only (`money.ts`). `bpsOf` rounds half away from zero, like
  Postgres `round(numeric)`. Platform fee: `applicationFeeCents(amount, env.platformFeeBps())`
  (omit `application_fee_amount` when it is 0).
- `assertChargeableCents` before any Stripe charge (Stripe min/max).
- Tips never change balances (SPEC section 4.5).
- Card data never touches our code: only Stripe ids, brand, last4.

### Idempotency

- Every Stripe create call passes an idempotency key from
  `idempotencyKey(scope, ...parts)`. Include the target row id, the amount and
  a client-supplied `request_nonce` (see `schemas.requestNonce`) for
  user-initiated actions: a network retry reuses the key, a genuinely new
  charge gets a new one.
- Webhooks: use `processStripeEventOnce(admin, event, handler, { log: ctx.log })`
  from `_shared/stripe_events.ts` right after `verifyStripeWebhook`. A
  `stripe_events` row means **received**, not processed: `processed_at` is
  set only after the handler succeeds. On an insert conflict the helper reads
  the row and skips the handler **only if `processed_at` is non-null**;
  otherwise it bumps `attempts`/`last_attempt_at` and runs the handler again.
  A handler error is stored in `error` and rethrown, so the webhook answers
  non-2xx and Stripe retries (for up to 3 days). Never treat an insert
  conflict alone as "already processed": that would acknowledge a retry of an
  event whose first attempt failed, and the payment/refund/subscription
  change would be lost for good. Handlers must still be safe to re-run
  (a failed attempt may have written part of its work, and deliveries can
  overlap). Use `beginStripeEvent` / `completeStripeEvent` / `failStripeEvent`
  directly only when the handler needs a custom flow.
- Messaging: claim queue rows with `claim_queued_messages` (skip locked) and
  pass the message id as Resend's `idempotencyKey`.

### Errors

Every error response is JSON:

```json
{ "error": "Human readable message.", "code": "forbidden", "details": {}, "request_id": "..." }
```

`error` is a plain string so web's `edgeFunctionError` shows it directly;
clients branch on `code`. Throw `HttpError(code, message)` (or `errors.*`);
anything else becomes `500 internal_error` with a generic message and is
logged with the request id. Mapped automatically: zod errors ->
`validation_failed` (with `details.issues[{path,message}]`), `EnvError` ->
`server_misconfigured`, Stripe card errors -> `402 payment_failed` (Stripe's
customer-safe message), other Stripe errors -> `upstream_error` /
`service_unavailable`, Twilio/Resend failures -> `502 upstream_error`, and a
database `PT402` (shop subscription inactive / plan seat limit, migration
0102) -> `402 payment_required` wherever it surfaces: the RPC refusal helpers
(`payments` `rpcError`, `messaging` `rpcRefusal`, `invites`) map it first,
and the handler maps one that a call site passed on wrapped in its own error
(`subscriptionRefusalIn`, `_shared/errors.ts`), never a 500.

| code | status | when |
|---|---|---|
| `bad_request`, `invalid_json`, `validation_failed`, `unknown_action` | 400 | malformed input |
| `invalid_signature` | 400 | webhook signature failed |
| `unauthorized` | 401 | no/invalid session, bad cron secret |
| `payment_failed` | 402 | card declined |
| `payment_required` | 402 | database PT402: `details.reason` `subscription_inactive` or `seat_limit`; `error` is the database's neutral sentence verbatim |
| `forbidden`, `origin_not_allowed` | 403 | role/membership, CORS |
| `not_found` | 404 | row missing (or not visible) |
| `method_not_allowed` | 405 | |
| `conflict` | 409 | state conflict (already paid, duplicate) |
| `gone` | 410 | expired link/token |
| `payload_too_large` / `unsupported_media_type` | 413 / 415 | |
| `unprocessable` | 422 | business rule (e.g. Stripe not connected) |
| `rate_limited` | 429 | |
| `internal_error`, `server_misconfigured` | 500 | bug / missing secret |
| `upstream_error` | 502 | provider rejected the request |
| `service_unavailable` | 503 | provider/auth temporarily down |

Codes are a public contract: add new ones, never rename.

### Logging and CORS

`ctx.log` writes JSON lines tagged with the function name and request id
(clients may send `x-request-id`; it is echoed back). Keys that look secret
(authorization, token, secret, api_key, signature, card...) are redacted.
Browser-facing functions reflect only exact allowed origins; webhook-only
functions pass `cors: false`.

## API contract (as implemented)

This section is the client contract for web and iOS. It documents every
action of every deployed function exactly as the code in this directory
implements it; when you change an action, update it here in the same commit.

### Common rules

- **URL:** `https://<ref>.supabase.co/functions/v1/<function>`. Web:
  `supabase.functions.invoke(name, { body })`; iOS:
  `client.functions.invoke(name, options: .init(body: ...))`.
- **JSON actions:** `POST`, `Content-Type: application/json`, body
  `{"action": "<name>", ...fields}`. The action may instead be given as
  `?action=<name>`; a body naming a different action is `400 bad_request`.
  Every input schema is **strict**: an unknown field (for example a
  client-sent `amount` or `total`) is `400 validation_failed`. Bodies are
  limited to 256 KiB (`413 payload_too_large`).
- **Staff auth:** `Authorization: Bearer <user access token>` (supabase-js
  sends it). The function verifies the JWT with Auth (anonymous users are
  rejected) and then the caller's **active** membership and role in the shop
  that owns the row. Missing/invalid session: `401 unauthorized`. Auth
  outage or throttling: `503 service_unavailable`, not 401. Non-member or
  wrong role: `403 forbidden` (the same answer for both). On
  `stripe-connect`, `invites` and `account` (`verify_jwt = true`) the Supabase gateway
  rejects a missing/invalid JWT first with its own 401, which is **not** our
  error envelope; treat any 401 as "sign in again".
- **Public auth:** the link token in the body (a UUID; a malformed one is
  `400 validation_failed`, a well-formed unknown one `404 not_found`).
- **Cron auth:** header `x-cron-secret: <CRON_SECRET>`; wrong or missing is
  `401 unauthorized`.
- **`request_nonce`** (optional on money actions): 8-64 characters of
  `[A-Za-z0-9_-]`. Generate one per user attempt and reuse it on a network
  retry of that attempt; a retry then gets the same Stripe object instead of
  a second charge. Without a nonce, identical requests within a 10-minute
  window share an idempotency key (double-click protection only).
- **Amounts** are integer cents. Clients never send prices, totals, balances
  or deposits. The only client-chosen amounts are a partial `amount_cents`
  (`payment_sheet`, `charge_saved_card`, `refund`, always
  `0 < amount <= what is due/refundable`) and a `tip_cents` that is at most
  the amount being paid in that attempt.
- **Timestamps:** `expires_at` values from Stripe are Unix **seconds**;
  database timestamps (`current_period_end`, invite `expires_at`) are ISO
  8601 strings.
- **Success:** `200` with the JSON body documented for the action.
- **Errors:** always the envelope
  `{"error": "<human message>", "code": "<code>", "details"?: {...}, "request_id": "..."}`
  (see [Errors](#errors)). Branch on `code` and, where listed, on
  `details.reason`; show `error` to the user. Every response carries
  `x-request-id`.

Errors any JSON action can return (not repeated per action below):
`400 invalid_json | validation_failed (details.issues[{path,message}]) | unknown_action | bad_request`,
`403 origin_not_allowed` (browser preflight from an origin that is not
configured), `405 method_not_allowed`, `413 payload_too_large`,
`415 unsupported_media_type`, `500 internal_error | server_misconfigured`.
Staff actions add `401 unauthorized`, `403 forbidden`,
`503 service_unavailable`. Actions that call Stripe add
`409 conflict` (a Stripe idempotency clash: refresh and retry with a new
nonce), `502 upstream_error` (Stripe rejected the request) and
`503 service_unavailable` (Stripe down or rate limited; honour
`Retry-After`).

Errors shared by the `payments` actions that need the shop's Stripe account:

| status / code | `details.reason` | meaning |
|---|---|---|
| 422 `unprocessable` | `stripe_not_connected` | the shop never connected Stripe |
| 422 `unprocessable` | `charges_disabled` | Stripe onboarding not finished (not raised by `refund` / `membership_cancel`) |
| 422 `unprocessable` | `amount_out_of_range` (+ `amount_cents`) | amount below Stripe's minimum ($0.50) or above its maximum |
| 409 `conflict` | `payment_in_progress` | a card payment for this document is already processing, or a pay link was just paid; refresh in a moment |

Invoice state errors (`assertPayable`), used by the invoice actions:
`422 unprocessable` reason `draft` (not issued), `409 conflict` reason
`void`, `409 conflict` reason `paid` (paid or balance 0).

### `stripe-connect` (owner/admin of `shop_id`)

| action | body | 200 response |
|---|---|---|
| `create_account_link` | `{shop_id, request_nonce?}` | `{url, expires_at, stripe_account_id}` |
| `refresh_status` | `{shop_id}` | `{connected, stripe_account_id, charges_enabled, payouts_enabled, details_submitted}` |
| `login_link` | `{shop_id, request_nonce?}` | `{url}` |

- `create_account_link` creates the shop's Express account on first use
  (one per shop, stored in `shop_stripe_accounts`) and returns a one-time
  onboarding URL (redirect the browser to it). Stripe sends the user back to
  `APP_BASE_URL/app/settings/payments?stripe=return` (finished or left) or
  `?stripe=refresh` (link expired: call `create_account_link` again). After
  a return, call `refresh_status`. Errors: `404 not_found` (shop row
  missing).
- `refresh_status` re-reads the account from Stripe and stores the flags.
  Without an account it answers `connected: false`, `stripe_account_id:
  null` and all flags `false` without calling Stripe.
- `login_link` returns a single-use Express dashboard URL. Errors:
  `422 unprocessable` reason `stripe_not_connected` or
  `onboarding_incomplete` (`details_submitted` is false).

### `payments`

`verify_jwt = false`: seven actions are public (link token or shop slug),
two take a signed-in client's JWT, one is cron; the rest verify the staff
JWT themselves. Payment rows are written server-side; `stripe-webhook` is
the source of truth for final states, so after a checkout/sheet/reader
payment completes, re-read the invoice/booking rather than trusting the
client.

**Payment methods.** The public pay links (`invoice_checkout`,
`booking_deposit_checkout`, `quote_deposit_checkout`) use the connected
account's enabled methods (Stripe dynamic payment methods, no
`payment_method_types`): cards and wallets always, US bank debits (ACH,
recorded `ach_debit`) and pay-later providers (Affirm, Klarna, Afterpay,
Zip, recorded `bnpl`) when the shop turned them on in its Stripe dashboard.
The card is saved for later through
`payment_method_options.card.setup_future_usage = off_session`, so pay-later
stays available. Link is not offered on these links
(`wallet_options.link.display = never`): a Link payment is its own payment
method type that the card options do not save, and the card on file is
card-only (`charge_saved_card` confirms with `card`), so a customer paying
through Link would silently leave no card on file. Apple Pay / Google Pay
stay (they save as cards). A Link payment that still arrives (a link opened
before this) is recorded as a card payment and logged
`stripe_card_not_saved` (reason `link_payment`). An ACH debit is `processing` for a few days: the database
counts it as money in flight (never charged twice) but not as paid; the
balance drops when it succeeds, and nothing changes if it fails. Every
action subtracts processing money from what it charges (`payable` on the
public invoice). Staff intents (`payment_sheet`, `charge_saved_card`,
`setup_card*`) stay card-only; `terminal_payment_intent` is `card_present`;
gift card sales and memberships are card-only.

A public RPC's "not found" (`PT404`, migration 0042) and a staff RPC's
(`P0002`) both answer `404 not_found`.

#### `invoice_checkout` (PUBLIC, invoice token)

Body `{token, tip_cents?, request_nonce?}` (`token` = `invoices.public_token`,
the `/i/<token>` link). Opens a Stripe Checkout Session for the invoice's
**whole current balance** plus the optional tip (a separate "Tip" line).

200: `{url, expires_at, amount_cents, tip_cents, currency}`: redirect to
`url`. `amount_cents` is the balance charged (less any ACH payment still
processing toward it), `tip_cents` the tip. The session lives about 32-42
minutes; opening a new one expires the invoice's older links and the open
deposit links of the jobs it bills (one job, or every job of a grouped
invoice). Stripe returns the customer to `/i/<token>?paid=1` or
`/i/<token>?canceled=1`. A card is saved for off-session use. After
`?paid=1` an ACH payment shows as processing on the invoice for a few days.

Every link is **held** for its invoice before the URL is returned
(`payments_hold_invoice_checkout`, below "Open payment pages"), completed
jobs' and grouped invoices' links too, so cash, checks and gift cards wait
for it; a single-job invoice whose job is still open is also held for the
job (the customer's online cancel waits for it). The hold re-checks the
invoice under its lock; when it refuses, the session is expired and no link
is returned.

Errors: `404 not_found` (unknown token or a draft invoice), `409 conflict`
reasons `void`, `paid`, `payment_in_progress` (also when processing
payments already cover the balance), `checkout_superseded` (links keep
changing: refresh), `invoice_closed` (no longer open, or nothing left to pay:
e.g. cash recorded meanwhile), `balance_changed` (less is left than this
link would charge: refresh), `booking_cancelled` (every appointment on the
invoice was cancelled; the page says it is not payable), `422 unprocessable` reasons `tip_too_large`
(`details.max_tip_cents`), `amount_out_of_range`, `stripe_not_connected`,
`charges_disabled`.

#### `invoice_checkout_cancel` (PUBLIC, invoice token)

Body `{token}` (`token` = `invoices.public_token`, the `/i/<token>` link;
nothing else is accepted). The customer closes the invoice's open card pay
page: `/i` calls it once when Stripe sends the customer back with
`?canceled=1`, and from the gift card panel ("Close it and use the gift
card") after a redemption was refused with `checkout_open`. It expires the
invoice's open `/i` pay links, the Checkout Sessions `invoice_checkout`
opened for it (the invoice customer's open sessions with `kind` `payment`
and this `invoice_id`, and every live hold of the invoice, also a link
opened for a previous customer), and releases their invoice holds and the
job hold a single-job invoice's link took, so gift cards and store credit
are accepted at once instead of after Stripe expires the page. Nothing
else is touched: deposit links and their job holds, card-setup and
membership links, staff PaymentSheets and Terminal payments stay as they
are, and nothing is settled or charged.

200: `{released}`, the number of pay links closed (expired now, or already
closed in Stripe with a hold left behind). Nothing open, or a shop without
Stripe: `{released: 0}` and nothing changes. Repeating the call is
harmless: the expire calls are idempotent per session and a closed link
has no hold left. Like the other link-token actions it is bounded by the
unguessable token (no amount, no new Stripe object; Stripe rate limits
answer `503 service_unavailable` with `Retry-After`).

Errors: `404 not_found` (unknown token or a draft invoice), `409 conflict`
reason `payment_in_progress` when a pay link was just paid, its bank debit /
pay-later payment is processing, or Stripe will not expire it because its
payment is being confirmed; `error` is written for the customer ("Your card
payment is already going through, so the payment page can't be closed.
Refresh in a moment to see it."). That link keeps its holds (its payment
row releases them); the invoice's other links are still closed.

#### `booking_deposit_checkout` (PUBLIC, booking token)

Body `{token, request_nonce?}` (`token` = `jobs.public_token`, the
`/booking/<token>` link). No tip. Charges the deposit still due, computed by
the database (`public_get_booking.deposit.due_cents` = least(deposit
required, job total) minus money received), capped at what the job's live
invoice (single or grouped) still owes less payments processing toward it.
The card is saved for later; ACH / pay-later appear when the shop enabled
them.

200: `{url, expires_at, amount_cents, tip_cents: 0, currency}`. Returns to
`/booking/<token>?paid=1` or `?canceled=1`. A new deposit link expires the
job's open deposit and invoice pay links. The session is held for the job
before the URL is returned; when the job closed while it was being created
the session is expired and the answer is `409 booking_closed`.

Errors: `404 not_found` (unknown token), `409 conflict` reasons
`booking_closed` (job cancelled / no-show / completed), `deposit_not_due`,
`payment_in_progress` (a payment of the job is on its way, including an ACH
debit still processing: `deposit.payment_pending`), `checkout_superseded`,
`422 unprocessable` reasons `amount_out_of_range`, `stripe_not_connected`,
`charges_disabled`.

#### `quote_deposit_checkout` (PUBLIC, quote token)

Body `{token, request_nonce?}` (`token` = `quotes.public_token`, the
`/q/<token>` link). The deposit of the job the customer scheduled on the
quote page (`public_schedule_quote`, P-16); the same amount and link rules
as `booking_deposit_checkout` for that job (the card is saved at approval).
Show "Pay deposit" only when `self_schedule.deposit_due_cents > 0` and
`self_schedule.payment_pending` is not true.

200: `{url, expires_at, amount_cents, tip_cents: 0, currency}`. Returns to
`/q/<token>?paid=1` or `?canceled=1`.

Errors: as `booking_deposit_checkout`, plus `404 not_found` (unknown token or
a draft quote) and `409 conflict` reason `not_scheduled` (the quote was not
scheduled by the customer on its page: approved only, or converted by
staff). The job is offered only while it still belongs to the quote's
customer (as `money_public_quote_json` hands it out): once staff move it to
another customer, the old quote link gets `409 booking_closed`, never a
Checkout on the new customer's Stripe customer.

#### Open payment pages (migrations 0106, 0109)

Every Checkout Session this function opens is **held** before its URL is
handed out:

* a booking or quote deposit link, and the pay link of a single-job invoice
  whose job is still open, for the **job**
  (`payments_hold_job_checkout(shop, job, session, expires_at)`): while it is
  live, `public_cancel_booking` refuses with `55000` HINT `checkout_open`, so
  a deposit cannot be paid on a booking the customer cancelled in another tab;
* every `/i` invoice pay link, for the **invoice**
  (`payments_hold_invoice_checkout(shop, invoice, session, expires_at,
  amount)`, 0109): while it, or a job hold of one of the invoice's jobs, is
  live, `record_manual_payment` and gift card / store credit redemptions
  (staff and public) refuse with `55000` HINT `checkout_open`, so cash cannot
  be taken for a balance the customer can still pay by card (the webhook
  would record the card payment on top: overpaid).

A hold ends when Stripe expires the session, when its payment row turns
processing / received (a trigger), or when this function expires the
session: **every** session it expires (a newer link, a job's deposit links,
a staff PaymentSheet / Terminal intent or saved-card charge superseding the
customer's pages, `booking_cancel`, `invoice_checkout_cancel`,
`cancel_open_payments`) loses its job and invoice holds at once
(`expireOpenSessions`). `cancel_open_payments` also
sweeps every live hold that blocks the document — by `invoice_id` the
invoice's holds and its jobs' holds, by `job_id` the job's and its live
invoice's — expiring any of those sessions still open (also one opened for a
previous customer) and releasing the rest; a page that was just paid keeps
its hold until its payment row lands. So the staff apps' "cancel open
payments and try again" on `checkout_open` always clears what it can. The
Stripe webhook's `checkout.session.expired` releases whatever is left for a
session that ended some other way.

#### `booking_cancel` (PUBLIC, booking token)

Body `{token, reason?}` (`token` = `jobs.public_token`; `reason` is the
optional note for the shop, at most 1,000 characters in the database). The
customer's own cancel, for `/booking/<token>` and the portal — call it
instead of `public_cancel_booking`. When the cancel can go ahead
(`cancellation.allowed` and no payment going through), every page that can
still pay toward the booking is expired first: the current customer's
deposit and invoice pay links of the job and every live hold of the job
(also a page opened for an earlier customer). The holds are released, then
`public_cancel_booking` runs **as the caller** (their JWT, or the anon key),
so its rules apply unchanged: status, cancel deadline, `payment_in_progress`,
`checkout_open` (a page opened meanwhile) and the technician rule. A
technician of the shop who is not the booking's own customer is refused
before any page is touched. When the cancel would be refused anyway, no
page is expired (a customer past the deadline keeps their deposit page).

200: the booking document (`public_get_booking`'s shape, cancelled).

Errors: `404 not_found` (unknown token), `403 forbidden` (a technician of
the shop), `409 conflict` reasons `payment_in_progress` (a page was just
paid, or a payment is going through) and `checkout_open` (a payment page
was opened meanwhile: try again in a few minutes), with the database's
sentence as the message, `422 unprocessable` (no longer cancellable online:
status or deadline, or the reason is too long; the database's sentence).

#### `gift_card_checkout` (PUBLIC, shop slug)

Body `{slug, offer_index? | amount_cents?, purchaser: {name, email},
recipient: {name?, email, message?}, request_nonce?}`: exactly one of
`offer_index` (0-7, one of the shop's `gift_card_settings.offers`) or
`amount_cents` (a custom amount, value = price, only when the shop allows
custom amounts; the database checks the shop's range). Prices never come
from the client: `gift_card_order_prepare` creates the order and prices it.
Card-only Checkout on the shop's account for the offer's **price** (the card
carries its **value**); no Stripe customer is created.

200: `{url, expires_at, price_cents, value_cents, currency}`. Stripe returns
the buyer to `/gift/<slug>/done?order=<order token>` (read it with
`public_gift_card_order_status`) or `/gift/<slug>?canceled=1`. The webhook
issues the card (`gift_card_order_paid`: the code is emailed to the
recipient and the buyer) — a gift card sale is never a payment row.

`request_nonce`: a retry of the same submission (same nonce and the same
details) gets the same open session back, with no second order and no
second use of the buyer's order allowance. The session's metadata carries a
hash of the nonce and details (`request_key`); the order is looked up among
the buyer's pending orders of the last hour. After that order was paid the
retry is `409 payment_in_progress`; after its session expired a new order
is prepared. A new nonce or changed details is a new order. Two requests
sent at the same instant can still each prepare an order (the database has
no nonce column to lock on).

Errors: `404 not_found` (unknown shop), `409 conflict` reason `disabled`
(online sales are off), `422 unprocessable` reasons `amount_out_of_range`,
`invalid_order` (the `error` text says what to fix: an offer no longer
available, custom amounts off, an invalid email...), `stripe_not_connected`,
`charges_disabled`, `429 rate_limited` (5 orders per buyer email, 10 unpaid
orders per connection and 100 unpaid per shop in 24 h; `Retry-After`). The
visitor's address (`_shared/client_ip.ts`: cf-connecting-ip, x-real-ip, the
last x-forwarded-for hop — the same sources as the database's
`form_signer_ip`) is passed as `p_client_ip` (migration 0110), since the
service-role call hides it from the database.

#### `membership_join_checkout` (PUBLIC, shop slug)

Body `{slug, plan_id, customer: {first_name, last_name?, email, phone?,
sms_opt_in?, email_opt_in?}, vehicle?: {year?, make, model}, request_nonce?}`
from the `/join/<slug>` page (plans from `public_membership_plans`).
`membership_join_prepare` matches or creates the customer (never overwriting
a matched one), adds the vehicle, and creates (or reuses a never-billed)
incomplete membership; then the same subscription Checkout as
`membership_checkout` (weekly, monthly or yearly). A customer the join
creates is a lead without marketing consent until the membership is paid
(the webhook's activation applies the consent asked for; migration 0110).
Limits: 3 joins per email, 10 unpaid joins per connection (the visitor's
address is passed as `p_client_ip`, as for gift cards) and 100 unpaid per
shop in 24 h (`429 rate_limited`).

200: `{url, expires_at, amount_cents, interval, interval_count, currency}`.
Stripe returns to `/join/<slug>?joined=1` or `?canceled=1`; the webhook
activates the membership and notifies managers (`membership_joined`).

Errors: `404 not_found` (unknown shop), `409 conflict` reasons
`plan_unavailable` (not sold online / inactive), `join_unavailable` (the
details match an existing membership of the plan; deliberately neutral
wording, "We can't start this sign-up online. If you're already a member,
manage your membership from your client portal, or contact the shop.", so
the anonymous page never confirms that an email holds a plan),
`membership_checkout_completed`,
`plan_changed`, `payment_in_progress`, `checkout_superseded`,
`422 unprocessable` reasons `invalid_details` (the `error` text says what to
fix), `amount_out_of_range`, `stripe_not_connected`, `charges_disabled`,
`429 rate_limited` (3 online joins per email per 24 h).

#### `portal_membership_cancel` (signed-in client)

Body `{membership_id}` with the client's own JWT (the portal user linked to
the membership's customer; `portal_membership_access`). Cancels **at the end
of the paid period** (never immediately) on the shop's account; the webhook
keeps the row in sync. The subscription is re-read after the update: a
cancel after the shop resumed it in Stripe (within Stripe's 24 h
idempotency replay) is sent again under a new key rather than trusting the
replayed "cancelling" response.

200: `{membership_id, status, cancel_at_period_end, current_period_end}`.

Errors: `401 unauthorized`, `403 forbidden` (not this client's membership:
the same answer for unknown ids), `409 conflict` reasons
`already_cancelled`, `membership_not_billed` (never billed; the portal does
not list those), `membership_changed` (Stripe would not take the cancel
after several tries: refresh), `422 unprocessable` reason
`stripe_not_connected`.

#### `portal_billing_portal` (signed-in client)

Body `{membership_id}` (same access rule). A Stripe billing portal session on
the shop's account for the Stripe customer the subscription bills: update the
card and see billing history (cancelling and plan changes are off there;
cancel with `portal_membership_cancel`). The portal configuration is created
once per connected account.

200: `{url}` (redirect; Stripe returns to `APP_BASE_URL/portal`).

Errors: `401 unauthorized`, `403 forbidden`, `409 conflict` reason
`membership_not_billed` (no Stripe customer yet), `422 unprocessable` reason
`stripe_not_connected`.

#### `payment_sheet` (staff: manager+, or an assigned technician)

Body `{shop_id, invoice_id, amount_cents?, tip_cents?, request_nonce?, ephemeral_key_api_version?}`.
Technicians may call it only when `shops.techs_can_collect_payments` is true
**and** they are assigned to the invoice's job. `amount_cents` defaults to
the balance; `tip_cents` must be at most `amount_cents`. The PaymentIntent
charges `amount_cents + tip_cents`. `ephemeral_key_api_version` (for example
`2026-08-26.dahlia`) is the API version the Stripe iOS SDK asks for;
default `STRIPE_API_VERSION`.

200:

```jsonc
{
  "payment_intent_id": "pi_...",
  "payment_intent_client_secret": "pi_..._secret_...",
  "ephemeral_key_secret": "ek_...",   // manager+ only
  "customer_id": "cus_...",            // manager+ only (Stripe customer on the shop's account)
  "publishable_key": "pk_...",
  "stripe_account_id": "acct_...",     // set as the SDK's stripeAccountId
  "amount_cents": 5000,
  "tip_cents": 500,
  "currency": "usd"
}
```

Technicians get no `customer_id`/`ephemeral_key_secret`: their sheet takes a
new card and cannot see saved cards. A pending payment row is recorded on the
invoice. Earlier open sheets and reader intents on the invoice are cancelled
(latest attempt wins) and its open pay/deposit links are expired. **Call
`cancel_open_payments` when the sheet is dismissed without paying**;
otherwise the cron sweep releases it after 30 minutes. "Balance" here and in
`terminal_payment_intent` / `charge_saved_card` means the balance less ACH
payments still processing toward it (`details.balance_cents` reports it).

Errors: `403 forbidden` (technician not allowed or not assigned; grouped
invoices are collected by managers),
`404 not_found` (invoice not in this shop), invoice-state errors,
`409 conflict` reasons `payment_in_progress`, `payment_superseded`,
`422 unprocessable` reasons `amount_exceeds_balance`
(`details.balance_cents`), `tip_too_large` (`details.max_tip_cents`),
`amount_out_of_range`, `stripe_not_connected`, `charges_disabled`.

#### `terminal_location` (staff: manager+, or a technician when the shop lets them collect)

Body `{shop_id}`. The shop's Stripe Terminal Location on its connected
account, created on first use from the shop's address (and again when the
address changes; stored in `shop_terminal_locations`). Tap to Pay on iPhone
ships dark in the app (`TAP_TO_PAY_ENABLED`) until Apple grants the
entitlement; this works as soon as the connected account has Terminal.

200: `{location_id}` (`tml_...`).

Errors: `403 forbidden`, `422 unprocessable` reasons `shop_address_required`
(street, city, postal code and country — plus state in the US, Canada and
Australia — are needed: send the owner to shop settings),
`shop_address_invalid` (Stripe rejected the address), `terminal_unavailable`
(Terminal is not enabled for the shop's Stripe account),
`stripe_not_connected`, `charges_disabled`.

#### `terminal_connection_token` (same callers as `terminal_location`)

Body `{shop_id}`. For the Terminal SDK's `ConnectionTokenProvider`: a fresh
single-use connection token on the connected account, scoped to the shop's
location (ensured as above; a location deleted in Stripe is re-created).

200: `{secret, location_id, stripe_account_id}`. Connect Tap to Pay / the
reader with `location_id`; the SDK acts on `stripe_account_id`.

Errors: as `terminal_location`.

#### `terminal_payment_intent` (same callers as `payment_sheet`)

Body `{shop_id, invoice_id, amount_cents?, tip_cents?, request_nonce?}`. The
same amount, tip, supersede and pay-link rules as `payment_sheet`; the
PaymentIntent is `card_present`, captured automatically when the reader
confirms, without a Stripe customer (no saved cards in person), metadata
`channel: terminal`. A pending `card_present` payment row is recorded; the
webhook settles it (a declined tap stays pending so the same intent can be
retried). Retrieve it in the SDK with `client_secret`, collect, confirm; if
the customer walks away, call `cancel_open_payments` (the sweep releases it
after 30 minutes otherwise).

200: `{payment_intent_id, client_secret, amount_cents, tip_cents, currency, stripe_account_id}`.

Errors: as `payment_sheet`, plus `422 unprocessable` reason
`terminal_unavailable` (card-present payments are not enabled on the
account).

#### `cancel_open_payments` (same callers as `payment_sheet`)

Body `{shop_id, invoice_id}` **or** `{shop_id, job_id}` (exactly one of the
two ids; both or neither is `400 validation_failed`). It never cancels a
payment that is already processing. PaymentSheet and Terminal / Tap to Pay
intents are released alike.

- `invoice_id` releases the invoice: cancels its unconfirmed PaymentSheet
  and reader intents, records any that already succeeded, and expires its
  open Checkout pay links and the deposit links of the jobs it bills, and
  releases every live page hold of the invoice and of the jobs it bills
  (0106 / 0109: also a page an earlier staff attempt or newer link already
  expired, or one opened for a previous customer; a page just paid keeps its
  hold). Call it when a sheet is dismissed, **before voiding or editing** an
  invoice, and on `checkout_open` from a manual payment or gift card before
  retrying.
- `job_id` releases the job: every unsettled card attempt of the job (its
  deposits and its invoice's payments), the deposit links opened for the
  job's **current** customer and, when the job has a live invoice (single or
  grouped), that invoice's pay links, plus every page still held for the
  job (0106, also one opened for an earlier customer) and for its live
  invoice (0109); what it expired is released, so a job staff reopen is not
  left blocked for the customer's online cancel, nor its invoice for cash. Call it **before cancelling a job / marking it
  no-show and before changing a job's customer**. Technicians may call it
  only for a job assigned to them, when the shop lets them collect.

200: `{invoice_id, job_id, cancelled, succeeded, in_progress, sessions_expired}`.
`invoice_id` / `job_id` name what was released (the invoice path answers
the invoice's job or `null` — always `null` for a grouped invoice; the job
path the job's live invoice or `null`). The counts are all 0 when the shop has no Stripe account.
`in_progress > 0` means money is still moving: do not void / cancel / move
the job yet ("A card payment is in progress — wait for it to finish.").
`succeeded > 0` means money was just recorded: refresh the balance.

Errors: `403 forbidden`, `404 not_found` (invoice or job not in this shop).

#### `sweep_payment_sheets` (pg_cron, `x-cron-secret`)

Body `{}` (just `{"action":"sweep_payment_sheets"}`). Settles PaymentSheet
rows left unconfirmed for 30+ minutes, in batches across shops.
200: `{checked, succeeded, cancelled, in_progress, unchanged, failed}`.
Errors: `401 unauthorized`.

#### `charge_saved_card` (manager+)

Body `{shop_id, invoice_id, payment_method_id?, amount_cents?, request_nonce?}`.
`payment_method_id` (`pm_...`, `card_...` or `src_...`) must be one of the
invoice customer's saved cards (`customer_payment_methods`); if it is
omitted, the default card is used. The card is charged on the Stripe
customer it is attached to (`customer_payment_methods.stripe_customer_id`:
a card moved by a customer merge keeps the duplicate's Stripe customer),
else the customer's own. `amount_cents` defaults to the balance.
No tip. Off-session, confirmed immediately. **Send a `request_nonce`**: a
retry with the same nonce can never charge twice.

200: `{payment_id, payment_intent_id, status, amount_cents, card_brand, card_last4}`.
`status` is `"succeeded"` or `"processing"`. `payment_id` is the `payments`
row id, or `null` if recording failed (the webhook records it later).

Errors: `402 payment_failed` with `details {reason, stripe_code, decline_code}`.
`reason` is Stripe's code, `card_declined`, or `authentication_required`
(the bank wants the customer present: send a pay link instead). Also:
`404 not_found` (invoice, or that card is not saved for this customer),
invoice-state errors, `409 conflict` reason `payment_in_progress`, and
`422 unprocessable` reasons `no_saved_card`, `saved_card_removed` (Stripe no
longer has the card, or it is no longer attached to the customer: it was
removed from the customer's saved cards; show `error` and reload the
cards), `amount_exceeds_balance` (`details.balance_cents`),
`amount_out_of_range`, `stripe_not_connected`, `charges_disabled`.

#### `remove_saved_card` (manager+)

Body `{shop_id, customer_id, payment_method_id}`. Detaches the card from the
customer's Stripe customer on the shop's account (so no PaymentSheet or
charge can use it again), then removes it from `customer_payment_methods`
(the customer's newest remaining card becomes the default when the default
is removed). A card Stripe no longer has, or that is attached to another
Stripe customer, is only removed from the CRM. Works without Stripe too.

200: `{removed}`: `false` when the card is not (or no longer) saved for this
customer, e.g. a retry after success; nothing is changed then.

Errors: `403 forbidden`, `404 not_found` (customer not in this shop).

#### `setup_card` (manager+)

Body `{shop_id, customer_id, request_nonce?, ephemeral_key_api_version?}`.
Opens a SetupIntent for the iOS PaymentSheet in setup mode. The webhook
(`setup_intent.succeeded`) stores the card, brand and last4 only.

200: `{setup_intent_id, setup_intent_client_secret, ephemeral_key_secret, customer_id, publishable_key, stripe_account_id}`
(`customer_id` is the Stripe `cus_...` id).

Errors: `404 not_found` (customer), `422 unprocessable` reasons
`customer_archived`, `stripe_not_connected`, `charges_disabled`.

#### `setup_card_link` (manager+)

Body `{shop_id, customer_id, request_nonce?}`. A Stripe Checkout link in
setup mode, to text or email to the customer so they can save a card.
200: `{url, expires_at}`. Stripe returns the customer to the public page
`APP_BASE_URL/done/<shop slug>?card=saved` or `?card=canceled` (no sign-in:
the customer usually has no account; the web route `/done/:slug`,
`web/src/features/portal/CheckoutDonePage.tsx`, shows the shop and the
outcome). Errors are the same as `setup_card`.

#### `refund` (owner/admin)

Body `{shop_id, payment_id, amount_cents?, request_nonce?}`. Only for
payments taken through Stripe (`method` `card`, `card_present`, `ach_debit`,
`bnpl`) in status `succeeded` or `partially_refunded` (an ACH debit still
processing cannot be refunded yet). Cash and other manual payments use the
`refund_manual_payment` RPC; gift card tender is reversed in the CRM. `amount_cents` defaults to everything still
refundable, which is (amount + tip) minus what is already refunded,
according to Stripe. The platform fee is refunded proportionally.

200: `{payment_id, refund_id, refund_status, amount_cents, refunded_cents_total, payment_status}`.
`refund_status` is Stripe's value (`succeeded` / `pending` /
`requires_action`). `payment_status` is the payment row's new status, or
`null` if recording failed (the webhook reconciles). A retry with the **same
`request_nonce`** returns the earlier refund (200) and does not refund again.

Errors: `404 not_found` (payment), `409 conflict` reasons `not_refundable`,
`fully_refunded`, `possible_duplicate_refund` (same amount refunded moments
ago without a nonce; `details {refund_id, amount_cents, refunded_cents_total}`:
send a new nonce if a second refund is really meant), `422 unprocessable`
reasons `not_a_card_payment` (not a Stripe payment; the name is kept for
compatibility), `amount_exceeds_refundable`
(`details.refundable_cents`), `refund_failed`, `stripe_not_connected`.

#### `membership_checkout` (manager+)

Body `{shop_id, membership_id, request_nonce?}`. The membership must be
`incomplete` with no subscription yet. The amount is the plan's
`price_cents`, recurring every `interval_count` `interval`s (`week`,
`month` or `year`). The plan's
Stripe Product/Price is created on the shop's account when needed. A new link
expires the membership's older links.

200: `{url, expires_at, amount_cents, interval, interval_count, currency}`.
Stripe returns the customer to the public page
`APP_BASE_URL/done/<shop slug>?membership=active` or `?membership=canceled`
(no sign-in, like `setup_card_link`). The webhook activates the membership.

Errors: `404 not_found` (membership or plan), `409 conflict` reasons
`membership_not_incomplete`, `membership_checkout_completed` (an earlier link
was paid; it activates shortly), `plan_changed` (retry),
`payment_in_progress`, `checkout_superseded`, `422 unprocessable` reasons
`plan_unavailable` (plan inactive/archived), `amount_out_of_range`,
`stripe_not_connected`, `charges_disabled`.

#### `membership_cancel` (manager+)

Body `{shop_id, membership_id, at_period_end?}` (`at_period_end` defaults to
`false`, which cancels now).

200: `{membership_id, status, cancel_at_period_end, current_period_end, stopped_subscriptions?}`.
`status` is a `membership_status`. `current_period_end` is an ISO timestamp
or null. `stopped_subscriptions` appears only when the membership was
already cancelled in the CRM but Stripe was still billing it: those
subscriptions are stopped.

- A membership that was never billed (`incomplete`) closes its checkout
  links and becomes `cancelled`.
- A billed membership is cancelled in Stripe now, or flagged
  `cancel_at_period_end` (re-read afterwards, as `portal_membership_cancel`,
  so a replayed response after a resume in Stripe is never trusted).

Errors: `404 not_found`, `409 conflict` reasons `already_cancelled`,
`membership_changed` (refresh), `422 unprocessable` reason
`stripe_not_connected`.

#### `delete_shop` (owner only)

Body `{shop_id, confirm_name}`. `confirm_name` is the shop's name as the
owner typed it (compared trimmed and case-insensitively). In order:

1. every unsettled card attempt of the shop is settled (unconfirmed
   PaymentSheets and reader intents cancelled, money that already landed
   recorded); a payment still processing (a card attempt, or an ACH debit
   clearing) refuses the deletion before anything else changes;
2. the shop's own **platform** subscriptions (what the shop pays for the
   CRM, [`docs/BILLING.md`](../../docs/BILLING.md): the one
   `shop_billing.stripe_subscription_id` tracks **and** every other one of
   the shop's platform customer that can still bill, e.g. a duplicate the
   webhook has not resolved yet) stop renewing: `cancel_at_period_end` is
   set on the platform Stripe account (no `Stripe-Account` header). That is
   reversible. One still `incomplete` (nothing paid) is cancelled outright;
   one already set to end is left as it is. A Stripe failure stops the
   deletion here with `502 upstream_error` reason
   `platform_subscription_cancel_failed` — no link, membership or record
   has changed yet;
3. every open Checkout link the CRM created on the account (pay, deposit,
   card-saving, gift card and membership links) is expired;
4. every membership that is not cancelled is cancelled **now**: its Stripe
   subscription is cancelled on the connected account (and any subscription
   a completed link started), then it is recorded `cancelled`;
5. the shop is deleted. The database cascades to every tenant row, queues
   the shop's stored files for `storage-purge` and logs its SMS numbers in
   `sms_number_releases`;
6. only then are the platform subscriptions from step 2 cancelled **now**.
   A Stripe failure here is logged (`platform_subscription_cancel_failed`,
   error level) and the deletion stands: step 2 already stopped renewals;
7. every number the platform bought for the shop through `sms-provisioning`
   (read before step 5) is released in Twilio with its Messaging Service, so
   the platform stops paying for it, and its `sms_number_releases` entry is
   removed. A Twilio failure is logged (`sms_number_release_failed`) and the
   entry stays: `sms-provisioning` `release_worklist` retries it daily.
   Numbers support bound by hand stay on that worklist for the operator
   (`supabase/setup/twilio.md`).

When step 3, 4 or 5 fails (the `409` / `5xx` below) the shop still exists,
so step 2 is undone: renewal is switched back on for each subscription step
2 set to end (a failure to undo is logged as
`platform_subscription_resume_failed`; the owner can resume it in the
Customer Portal).

The Stripe Connect account is left intact: the owner keeps the Express
dashboard, the balance and the payouts. A shop without Stripe Connect skips
steps 1, 3 and 4's Stripe calls (step 2 still runs).

200: `{deleted: true, memberships_cancelled, sessions_expired,
platform_subscription_cancelled}` (`platform_subscription_cancelled`: this
deletion ended at least one live platform subscription). Afterwards drop every cached
query of that shop and leave its screens.

Errors: `403 forbidden` (not the owner), `404 not_found`,
`409 conflict` reason `payment_in_progress` (a card payment is still
processing or a pay link was just paid: nothing was deleted; try again in a
moment), `422 unprocessable` reason `name_mismatch`, `502 upstream_error`
reason `platform_subscription_cancel_failed` (nothing was deleted; try again
in a moment).

### `stripe-webhook` (Stripe only)

`POST /functions/v1/stripe-webhook`, raw body (at most 1 MiB), header
`Stripe-Signature`. No CORS and no JWT. It is not called by apps.

- `200 {received: true, handled, duplicate, result}`: `handled` is false for
  event types it does not act on; `duplicate` is true for a replay of an
  event that was already processed; `result` is `"applied"`, `"ignored"` or
  `null`.
- `400 invalid_signature` (missing or bad signature), `400 bad_request`
  (malformed event id), `409 conflict` (another delivery is processing the
  event: Stripe retries), `413 payload_too_large`, `500 internal_error`
  (processing failed; the error is stored in `stripe_events` and Stripe
  retries).

The events handled are listed in [Stripe Connect webhook](#stripe-connect-webhook).
Besides recording money, refunds (a failed refund lowers the refunded total
again, `set_stripe_refund_total`), subscriptions and saved cards, it:

- records a dispute's outcome in `payments.disputed_cents`
  (`apply_stripe_dispute`: `lost` = what the dispute took back; `won` /
  `warning_closed` = 0), writes one line about it in the payment's note and
  notifies owners/admins (deep links: the payment's job, customer and
  invoice). Balances are not changed by a dispute;
- cancels, once a card payment settles an invoice in full, that invoice's
  other PaymentSheets still waiting for a card (recorded `cancelled`), so a
  sheet left open on another device cannot overpay it;
- keeps money whose job / invoice / membership was deleted as the payer's
  unapplied payment with a note (upsert_stripe_payment drops the stale
  links); money that nothing in the shop can take is logged
  (`stripe_payment_unlinkable`) and acknowledged;
- records asynchronous methods (P-31): an ACH debit is `processing` while it
  clears (`payment_intent.processing`, or a Checkout completed unpaid; one
  still waiting for bank verification is `pending`), then `succeeded`
  (`payment_intent.succeeded`, `checkout.session.async_payment_succeeded`)
  or `failed` (`payment_intent.payment_failed`,
  `checkout.session.async_payment_failed`: a debit returned before it
  settled; only a payment it already tracks). The method follows Stripe's
  type (`us_bank_account` -> `ach_debit`; `affirm` / `klarna` /
  `afterpay_clearpay` / `zip` / ... -> `bnpl`; cards, wallets and Link ->
  `card`; `card_present` / `interac_present` -> `card_present`) and the type
  itself is stored in `payments.stripe_method_type`; a type the CRM has no
  method for is stored as `card` with a note. Cards are saved from Checkout
  when the card options asked for it;
- issues online gift cards: a Checkout / PaymentIntent with metadata
  `kind: gift_card` + `gift_card_order_id` (of this shop) calls
  `gift_card_order_paid` (once; replays hand back the same card) and never
  writes a payment; refunds of such a charge call `gift_card_order_refunded`.
  An amount that does not match the order is logged
  (`gift_card_order_unpaid`) for staff and acknowledged. When such a
  Checkout expires unpaid (`checkout.session.expired`),
  `gift_card_order_expired` turns its pending order `expired` (idempotent;
  a paid or refunded order is never touched; an order that never recorded
  the session, P0002, is acknowledged). An expired invoice or deposit link
  (`kind: payment` / `deposit`) has its page holds released
  (`job_checkout_holds` / `invoice_checkout_holds` rows of that session in
  this shop; the payments function already released the ones it expired
  itself). Other expired sessions need nothing;
- records Terminal / Tap to Pay payments (metadata `channel: terminal`) as
  `card_present` with the card's brand and last4; a declined tap stays
  pending (retryable), and a reader intent still waiting when the invoice is
  paid in full elsewhere is cancelled like a sibling PaymentSheet;
- credits money paid through a link opened for a customer who has since been
  merged into another (P-20) to the surviving customer
  (`customers.merged_into_id`); a saved card is re-saved (refreshed) only on
  its own Stripe customer (`customer_payment_methods.stripe_customer_id`, so
  a card a merge moved keeps refreshing), and a new card only on the
  customer's.

### `messaging`

`verify_jwt = false`. `POST` for every action; `GET` only for
`unsubscribe` (any other GET is `405`).

#### `send` (staff)

Body `{shop_id?, customer_id?, job_id?, quote_id?, invoice_id?, channel, template_key?, subject?, body?, request_nonce?}`:

- `channel`: `"sms"` | `"email"`.
- Give exactly one of `template_key` or `body` (non-blank).
- At least one of `customer_id` / `job_id` is required. With a job, the
  customer defaults to the job's customer; a different `customer_id` is
  `422 job_customer_mismatch`.
- `shop_id` is optional. Without it, the shop comes from the job (else the
  customer), and a caller who is not a member of that shop gets
  `404 not_found`. With it, the job or customer must belong to that shop.
- `template_key` is one of `booking_request_received`, `booking_confirmed`,
  `appointment_reminder`, `on_the_way`, `job_started`, `job_completed`,
  `quote_sent`, `invoice_sent`, `payment_receipt`, `review_request`,
  `follow_up`, `membership_welcome`. Without `job_id`, only
  `review_request`, `follow_up` and `membership_welcome` are allowed, and
  only if the shop's wording uses customer-level variables only.
- `subject`: email free-form only (templates bring their own; SMS has none),
  at most 500 characters. `body`: at most 1600 characters for SMS, 50,000
  for email.
- **Quotes and invoices:** `quote_id` with `template_key: "quote_sent"`, or
  `invoice_id` with `template_key: "invoice_sent"` (owner/admin/manager
  only). The database renders the shop's template with the document's own
  link, amount and balance and queues it (`enqueue_document_message`);
  clients never render or send the wording themselves (use the
  `preview_document_message` RPC to show it first). The customer and job
  come from the document, so `customer_id`, `job_id`, `body` and `subject`
  are not allowed with a document id, nor are both ids at once
  (`400 validation_failed`). A draft quote (mark it sent first) or a draft /
  void invoice has no link yet: `422 missing_link` with `error` "Mark the
  quote as sent first." / "Issue the invoice first." / "This invoice is void;
  it can no longer be sent.". Without a `shop_id`, the shop comes from the
  document.
- `request_nonce` (8-64 of `[A-Za-z0-9_-]`, a UUID string is fine): one per
  compose, reused when that compose is retried, a fresh one after a
  success. The database queues a nonce once per sender and shop
  (`messages.request_nonce`); a retry returns the same message.
- Roles: owner/admin/manager can send anything. Technicians can send only
  `template_key` `on_the_way` / `job_started` / `job_completed`, with a
  `job_id` they are assigned to (never quotes or invoices: `403 forbidden`).

200: `{message_id, channel, status, error}`, where `status` is the state
after the immediate delivery attempt: `sent`, `failed` (`error` holds a
short reason), `queued` (retry scheduled), `sending` or `cancelled`. A
retry with the same `request_nonce` returns the **same** message with its
current status (which may be `delivered`) and never delivers it twice.
Without a nonce, a repeat of an identical send by the same staff member
within 5 minutes returns the **original** message and sends nothing new. A
delivery failure is still 200: show `error`.

Errors: `403 forbidden` (role, technician rules, not assigned),
`404 not_found` (job or customer not found / not visible), and
`422 unprocessable` with `details.reason` from this list:

- `opted_out`
- `no_address`
- `sms_not_configured`
- `template_disabled`
- `no_marketing_consent` (`follow_up`)
- `appointment_closed` (the job is cancelled / no-show)
- `missing_link` (a link placeholder would be blank; `details.variables`;
  `error` says what to set up; also when the platform has no customer app
  URL configured yet)
- `empty_message`
- `job_customer_mismatch`
- `job_required` (optionally `details.variables`)
- `not_sendable`

#### `process_queue` (pg_cron, `x-cron-secret`)

Body `{limit?}`, where `limit` is 1-1000 (default 200). Claims and delivers
queued messages. An SMS whose sending number has a Messaging Service (numbers
bought through `sms-provisioning`; `claim_queued_messages.messaging_service_sid`)
is sent with `MessagingServiceSid` instead of `From`; the recorded sender is
still the shop's number and the provisioning check is the same.

200: `{batches, claimed, sent, failed, retried, cancelled, unrecorded, released, more}`.
Errors: `401 unauthorized`.

#### `run_automations` (cron / manual, `x-cron-secret`)

Body `{}`. Runs `enqueue_due_automations()`. 200: `{queued}`. (The
scheduled job calls the SQL function directly; this action is for manual
runs.)

#### `twilio_inbound` / `twilio_status` (Twilio only)

`POST ?action=twilio_inbound&shop_id=<uuid>` and `POST ?action=twilio_status`,
`application/x-www-form-urlencoded` (at most 64 KiB), header
`X-Twilio-Signature`, validated against the public URL.

200 with an empty TwiML document (`text/xml`) for handled **and** ignored
messages. `400 invalid_signature`; `500` on a database error (Twilio
retries). Not called by apps.

#### `unsubscribe` (PUBLIC, unsubscribe token)

`?action=unsubscribe&token=<unsubscribe token>` (the `List-Unsubscribe` URL of
marketing emails: campaigns and `follow_up`). The token is the email's random
`messages.unsubscribe_token`, never its message id; transactional email has
none.

- `GET`: `303` to `APP_BASE_URL/u/<token>`, which does **not** unsubscribe.
  The web page confirms, then calls the `public_unsubscribe` RPC.
- `POST` (RFC 8058 one-click, any body up to 4 KiB): `200 {unsubscribed: true}`.
- Errors: `400 validation_failed` (malformed token), `404 not_found`
  (unknown token), `413 payload_too_large`.

### `storage-purge` (pg_cron only; `verify_jwt = false`)

#### `purge` (pg_cron, `x-cron-secret`)

Body `{limit?}`, where `limit` is 1-1000 (default 500) objects per batch.
Removes the stored files of deleted shops, jobs, inspections and forms,
which the database queues in `storage_purge_requests` (migration 0025):
`claim_storage_purge` -> Storage API `remove` (service role, per bucket) ->
`finish_storage_purge`, batch after batch until the queue is empty, 20
batches ran or ~40 s passed. A failed removal is recorded on the request and
retried after 15 minutes; objects a live row still references are never
claimed.

200: `{batches, claimed, removed, failed_requests, more}`.
Errors: `401 unauthorized`, `500 internal_error` (database error).

### `invites` (owner/admin; `verify_jwt = true`)

Both actions return:

```jsonc
{
  "invite": { "id": "...", "shop_id": "...", "email": "...", "role": "technician", "expires_at": "2026-10-04T12:00:00Z" },
  "invite_url": "https://app.../invite/<token>",
  "email_sent": true,
  "reissued": false            // resend_invite only
}
```

`email_sent: false` means the invite exists but the email failed: show
`invite_url` so it can be shared another way, or resend.

| action | body | notes |
|---|---|---|
| `send_invite` | `{shop_id, email, role}` | `role`: `admin` \| `manager` \| `technician` (ownership moves only via `transfer_ownership`). `email` is trimmed, at most 320 characters. A fresh (issued within 15 min) pending invite for the same email and role is reused and re-emailed with the same link, so retries are safe. Otherwise a new invite replaces the pending one. |
| `resend_invite` | `{invite_id}` | Re-emails a pending invite. If the invite is expired or older than 15 minutes, a new one is issued (new token, full 7 days) and the response has `reissued: true`. |

Errors: `send_invite` can return `409 conflict` (already a member, or just
invited with another role) and `422 unprocessable` (the invite cannot be
created). `resend_invite` can return `404 not_found` (invite), `409 conflict`
(already accepted) and `410 gone` (revoked). Both can return `403 forbidden`.

### `account` (any signed-in user, own account only; `verify_jwt = true`)

#### `delete_account`

Body `{}` (just `{"action":"delete_account"}`). Deletes the caller's own
account (App Store guideline 5.1.1(v)); every role can, portal clients
included. The caller must not own a shop: ownership is checked as the
caller (`account_deletion_blockers`), because a shop cannot be left without
an owner. The auth user is then deleted with the Auth admin API; the
database cascades remove their memberships and profile, clear customers'
portal links and null audit references. Shop records (customers, jobs,
payments) are never deleted with a person's account.

200: `{deleted: true}`: sign out locally and go to the sign-in page.

Errors: `401 unauthorized` (gateway or function), `409 conflict` reason
`owns_shops` with `details.shops: [{shop_id, name}]` (ordered by name) and
`error` "Transfer ownership or delete these shops first." (link each shop to
its delete-shop page and to the team page for an ownership transfer),
`503 service_unavailable` (Auth could not delete the user right now: try
again).

### `push` (pg_cron + staff; `verify_jwt = false`)

APNs notifications for the staff iPhone app (P-2). The database decides who
is pushed what (`claim_push_batch`, migration 0082: the recipient's current
role may read the kind, the kind is switched on, pushes are not muted, the
notification is at most an hour old) and never puts money or phone numbers
in the text; this function only delivers.

APNs credentials: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY` (the
`.p8` contents), `APNS_TOPIC` (the app's bundle id). All four or none: with
none set, `process_queue` answers `{configured: false, ...}` and leaves the
queue alone; a partial or malformed set is `500 server_misconfigured`.
Each device token is sent to the host of its registered environment
(`api.sandbox.push.apple.com` for development builds, `api.push.apple.com`
otherwise) with `apns-push-type: alert`, `apns-priority: 10` and a one-hour
`apns-expiration`.

Payload (what the app's router reads):

```jsonc
{
  "aps": { "alert": { "title": "New job #1042", "body": "Monday, Jun 2 at 10:00 AM - Full detail" },
           "badge": 3, "sound": "default", "thread-id": "job_assigned" },
  "kind": "job_assigned", "shop_id": "...", "job_id": "..." | null, "customer_id": "..." | null,
  "notification_id": "...",
  "quote_id": "...", "invoice_id": "..."   // only when set
}
```

`badge` is the recipient's unread notifications across shops.

#### `process_queue` (pg_cron, `x-cron-secret`)

Body `{limit?}` (1-500, default 100 per claim). Claims batches until the
queue is empty, 50 claims ran or ~25 s passed. Per device: `410`, or `400`
`BadDeviceToken` / `DeviceTokenNotForTopic` / `Unregistered` ->
`mark_push_token_invalid` (the app registers the device again on next
launch); `429`, `5xx`, a network error, no answer within 10 s (each APNs
request is capped) or a provider-token problem -> `release_push`
(re-queued up to 3 claims) but only when no device of the
recipient got it, so nobody is alerted twice; other `4xx` (payload/topic)
are final. The run has a hard 45 s deadline (the cron's HTTP timeout is
60 s): no APNs request runs past it, and a push not yet attempted by then
counts as a retry and is released, so a stalled APNs connection never leaves
claimed notifications stranded. 200:
`{configured, batches, claimed, sent, failed, released, invalid_tokens, more}`
(`sent` / `failed` count notifications). Errors: `401 unauthorized`,
`500 server_misconfigured`.

#### `send_test` (any active staff member of `shop_id`)

Body `{shop_id}`. Sends "Test notification" to the **caller's own** enabled
devices only. 200 `{sent, failed, invalid_tokens}` (devices). Errors:
`422 unprocessable` reason `no_devices` (no enabled device, or every device
turned out to be unregistered: open the app so it registers again),
`502 upstream_error` (APNs accepted none), `500 server_misconfigured`
(APNs not configured), plus the staff errors.

### `calendar-feed` (PUBLIC by feed token; `verify_jwt = false`)

`GET /functions/v1/calendar-feed?token=<uuid>` (the path returned by
`create_calendar_feed`; subscribe with `https://` or `webcal://`). Answers
`200 text/calendar; charset=utf-8` built by `_shared/ics.ts` from
`calendar_feed_events` (0055): one `VEVENT` per job / calendar-event
occurrence, `UID <id>@detail-crm` (stable across refreshes), `DTSTART` /
`DTEND` / `DTSTAMP` / `LAST-MODIFIED` in UTC, `STATUS` `CONFIRMED` or
`TENTATIVE` (requested jobs), `X-WR-CALNAME` "<shop> - <member>".
`Cache-Control: private, max-age=300`. The feed covers 7 days back to 90
days ahead and never contains prices, phone numbers, emails or notes.
Errors: `400 validation_failed` (missing / malformed token),
`404 not_found` (unknown or revoked token, or the member is no longer
active), `405` for anything but GET. No CORS (calendar apps, not browsers).

### `public-media` (PUBLIC by link token, or signed-in client; `verify_jwt = false`)

Short-lived signed URLs (10 minutes) for the photos, videos, inspection
photos and documents a customer may see. The client never sends a bucket or
a path: the database lists the objects the credential may see (service-role
RPCs from migrations 0072 / 0075) and this function signs them. Objects that
no longer exist are left out.

| action | body | 200 response |
|---|---|---|
| `job_report` | `{token}` (the `/r/<token>` report link) | `{expires_in: 600, items: [{ref_id, kind, url}]}`; `kind` is `photo`, `video`, `poster` (the video's frame: `ref_id` = the video's photo id), `mark_photo` (`ref_id` = the damage mark id) or `document`; `ref_id` matches the ids in `public_get_job_report` |
| `booking_documents` | `{token}` (the booking link's token) | `{expires_in: 600, items: [{ref_id, kind: "document", url}]}`; `ref_id` = the ids of `public_booking_documents` |
| `portal_document` | `{document_id}` + `Authorization: Bearer <client session>` | `{expires_in: 600, url}` for a document of one of the caller's portal customers |

Errors: `400 validation_failed`, `404 not_found` (unknown or revoked report,
unknown booking, or a document the caller may not see), `401 unauthorized`
(`portal_document` without a session). Refresh the URLs by calling again
after `expires_in` seconds.

### `sms-provisioning` (owner/admin + pg_cron; `verify_jwt = false`)

Self-serve text-messaging numbers (P-14), **dark by default**:
`search_numbers`, `purchase_number`, `submit_tollfree_verification` and
`submit_10dlc` answer `422 unprocessable` reason `provisioning_disabled`
until `SMS_PROVISIONING_ENABLED=true` (the platform Twilio account must be
able to buy numbers and submit toll-free verifications). `submit_10dlc`
also needs `TWILIO_ISV_ENABLED=true` (`422` reason `isv_required`
otherwise) and `TWILIO_PRIMARY_CUSTOMER_PROFILE_SID`. Show the flags from
`status` and keep the manual number setup (support binds numbers by hand,
`supabase/setup/twilio.md`) while they are off. Shops in the US and Canada
only (`422` reason `unsupported_country`).

| action | caller | body | 200 response |
|---|---|---|---|
| `status` | owner/admin | `{shop_id}` | `{enabled, isv_enabled, number: {number, kind, verification_status, rejection_reason, provisioned}}` (`sms_provisioning_status`) |
| `search_numbers` | owner/admin | `{shop_id, kind: "tollfree" \| "local", area_code?, contains?}` | `{numbers: [{phone_e164, locality, region}]}` (at most 20, SMS-capable) |
| `purchase_number` | owner/admin | `{shop_id, phone_e164, request_nonce}` | `{number}` (the status object) |
| `submit_tollfree_verification` | owner/admin | `{shop_id, business, edit_reason?}` | `{number}` |
| `submit_10dlc` | owner/admin | `{shop_id, business, campaign}` | `{number}` |
| `release_number` | owner | `{shop_id}` | `{released, number}` |
| `refresh_status` | pg_cron (`x-cron-secret`) | `{}` | `{enabled, checked, updated, failed}` |
| `release_worklist` | pg_cron / operator (`x-cron-secret`) | `{}` | `{checked, pending: [{phone_number, twilio_number_sid, shop_id, shop_name, shop_deleted, released_at}], released, pruned, failed}` |

The platform pays Twilio for every number: `purchase_number` (a new number)
and `submit_10dlc` (carrier registration fees) need a shop in good standing
(`shop_billing_standing`, 0101). While billing is on, a lapsed shop gets
`402 payment_required` reason `subscription_inactive` (the standard
sentence) and a trialing or past-due one `422 unprocessable` reason
`subscription_required` (`details.state`; support can still bind a number by
hand). Billing off: every shop may. A shop that gave back 2 numbers in the
last 30 days (`sms_number_releases`) cannot buy another yet: `429
rate_limited` reason `number_churn_limit`, `details.retry_at` (ISO) when the
older one leaves the window. Resuming an interrupted purchase (the number is
already recorded) and a retry that finds the number it already bought are
not refused.

- `purchase_number` buys the number with the platform's inbound webhook
  (`messaging?action=twilio_inbound&shop_id=<shop>#rc=3&rp=all`, the binding
  `messaging` checks before sending), creates the shop's own Messaging
  Service (inbound on the number's webhook, status callback
  `messaging?action=twilio_status`), attaches the number and records it
  (`record_sms_number`: it becomes the shop's sending number). The
  `request_nonce` makes a retry find the number it already bought instead of
  buying another. Errors: `409 conflict` reason `already_has_number` (release
  the current one first) or `number_unavailable` (search again).
- `submit_tollfree_verification` (toll-free numbers; `422` reason
  `not_tollfree` / `no_number`) sends Twilio's toll-free verification and
  records `pending`. `business` (strict):
  `{legal_name, website, address_line1, address_line2?, city, region,
  postal_code, country: "US"|"CA", contact_first_name, contact_last_name,
  contact_email, contact_phone (E.164), notification_email?,
  use_case_categories: [1-5 of TWO_FACTOR_AUTHENTICATION, ACCOUNT_NOTIFICATIONS,
  CUSTOMER_CARE, CHARITY_NONPROFIT, DELIVERY_NOTIFICATIONS, FRAUD_ALERT_MESSAGING,
  EVENTS, HIGHER_EDUCATION, K12, MARKETING, POLLING_AND_VOTING_NON_POLITICAL,
  POLITICAL_ELECTION_CAMPAIGNS, PUBLIC_SERVICE_ANNOUNCEMENT, SECURITY_ALERT],
  use_case_summary (20-1000), production_message_sample (20-1000),
  opt_in_type: VERBAL|WEB_FORM|PAPER_FORM|VIA_TEXT|MOBILE_QR_CODE,
  opt_in_image_urls: [1-5 URLs], estimated_monthly_volume: "10"|"100"|"1,000"|
  "10,000"|"100,000"|"250,000"|"500,000"|"750,000"|"1,000,000"|"5,000,000"|
  "10,000,000+", additional_information?}`. After a rejection the function
  reads the verification from Twilio first: while Twilio's `edit_allowed` is
  true and `edit_expiration` has not passed, it is edited in place with
  `EditReason` = `edit_reason` (1-500 characters, what was fixed, e.g.
  "Website fixed"; a generic default otherwise); when the rejection is not
  editable or the window has closed, the old verification is deleted and a
  new one submitted (the stored sid is replaced), and one Twilio no longer
  has is simply submitted anew. If Twilio has meanwhile moved it on from
  rejected, that status is recorded and nothing is resubmitted. `409
  conflict` reason `verification_in_progress` / `already_approved` otherwise.
- `submit_10dlc` (local numbers; `422` reason `not_local`) registers a
  secondary Trust Hub customer profile, an A2P messaging profile and the
  brand, and records `pending`; `refresh_status` creates the campaign on the
  shop's Messaging Service once the brand is approved (`in_review`) and
  records `approved` / `rejected` from its vetting. Resources are saved as
  they are created, so a failed submission resumes. `business` (strict):
  `{legal_name, business_type: "Sole Proprietorship"|"Partnership"|"Corporation"|
  "Co-operative"|"Limited Liability Corporation"|"Non-profit Corporation",
  industry (Twilio's business_industry values, e.g. AUTOMOTIVE),
  registration_identifier: "EIN"|"CBN", registration_number, website,
  regions_of_operation: [USA_AND_CANADA|AFRICA|ASIA|EUROPE|LATIN_AMERICA],
  company_type: private|public|non-profit|government, stock_exchange?,
  stock_ticker? (both required for public), address_line1, address_line2?,
  city, region, postal_code, country, email, representative: {first_name,
  last_name, email, phone, business_title, job_position:
  Director|GM|VP|CEO|CFO|"General Counsel"|Other}}`; `campaign` (strict):
  `{use_case: MIXED|CUSTOMER_CARE|ACCOUNT_NOTIFICATION|MARKETING|LOW_VOLUME,
  description (40-2048), message_flow (40-2048), message_samples: [2-5 of
  20-1024], has_embedded_links, has_embedded_phone, opt_in_message?,
  opt_out_message?, help_message?}`. A profile Twilio evaluates as
  incomplete is `422` reason `profile_incomplete` with
  `details.issues: [{requirement, fields}]` (fix and submit again).
- Twilio's `4xx` answers to the admin's own details in `search_numbers`,
  `submit_tollfree_verification` and `submit_10dlc` (an invalid website or
  postal code, an unreachable opt-in image, an address Twilio cannot
  validate, a bad EIN, no numbers for an area code) are `422 unprocessable`
  reason `twilio_rejected_details` with `details: {twilio_code,
  twilio_message}` and Twilio's message in `error`: show it next to the form,
  since retrying cannot help. Twilio `401` / `403` / `404` / `429`, `5xx` and
  network failures stay `502 upstream_error` ("try again shortly"). A
  10DLC submission keeps the resources already created, so the corrected
  resubmission resumes.
- `release_number` is **not** gated by the flag (a shop can always give a
  number back): it releases the number and its service in Twilio and calls
  `release_sms_number`. Without a provisioned number: `{released: false}`.
- `refresh_status` polls up to 50 `pending` / `in_review` numbers per run
  (every 30 minutes); `set_sms_verification` notifies owners/admins of each
  status change. Returns `{enabled: false, ...}` without calling Twilio while
  the flag is off.
- `release_worklist` (daily, and whenever the operator wants the list) works
  through the oldest 200 entries of `sms_number_releases` (0093: a number
  stopped being bound to its shop — `release_number`, a deleted shop, support
  moving it). Per number it asks Twilio (`IncomingPhoneNumbers?PhoneNumber=`)
  whether the platform still rents it: not on the account any more, or bound
  to a shop again → done; still rented, its shop deleted and bought by
  `purchase_number` for that shop (friendly name `dcrm-<shop_id>-...`) →
  released now (`released`); anything else → `pending` (release or
  re-assign it in Twilio, supabase/setup/twilio.md), logged as
  `sms_numbers_awaiting_release` (warn, with the count). Done entries are
  removed (`pruned`) once their shop is gone or they are older than 30 days
  (until then they count toward the shop's release limit). Needs the Twilio
  secrets only when there are entries. Runs whether or not
  `SMS_PROVISIONING_ENABLED` is on (hand-bound numbers land here too).

### `webhooks` (pg_cron only; `verify_jwt = false`)

#### `deliver` (pg_cron, `x-cron-secret`)

Body `{limit?}` (1-500, default 50: the most one claim takes). Claims due
deliveries (`claim_webhook_deliveries`, 0089) until the queue is empty, 60
claims ran or the 40 s budget is used, POSTs each one (5 at a time) and
records the outcome (`mark_webhook_delivery`). 200 `{batches, claimed,
succeeded, failed, more}`. The budget is a hard deadline: each claim takes
only as many deliveries as can all hang until their 10 s timeout (plus 2 s
for the mark) and still finish inside what is left (`claimLimit`: 15 at the
start of a run), and claiming stops when not even one round fits. So a run
never outlives the cron's 60 s HTTP timeout, and a claimed delivery is
never left 'delivering' for the 10-minute stuck re-queue by a killed worker.

Each delivery is:

```
POST <endpoint url>
Content-Type: application/json
User-Agent: DetailCRM-Webhooks/1
X-DetailCRM-Event: job_completed
X-DetailCRM-Delivery: <delivery id>          (the same on every retry: dedupe on it)
X-DetailCRM-Signature: t=1760000000,v1=<64 hex>

{"id": "<event id>", "event": "job_completed", "created_at": "...", "shop": {...}, "data": {...}}
```

Any `2xx` within 10 s (name resolution included) is success. Everything else is retried after 1 min,
5 min, 30 min, 2 h, 6 h, 12 h and 24 h, then marked dead: `3xx` (redirects
are never followed), `4xx`, `5xx`, a network error or a timeout. The
response body is never read. 25 failures in a row disable the endpoint and
notify owners/admins. Before connecting, the URL must pass `_shared/ssrf.ts`:
https, a public host name (no IP literals, `localhost`, `*.local`,
`*.localdomain`, `*.internal`, `*.localhost`, `*.lan`, `*.home`; any port,
as `comms_webhook_url` stores any port, so an endpoint the database accepted
is never refused for its port), and every
address the name resolves to must be public (not loopback, private,
link-local / cloud metadata, CGNAT, unique-local, multicast or reserved);
a refused URL is recorded as a failure with the reason. The edge runtime
cannot pin the checked address for the connection, so a name that changes
its DNS answer in between (rebinding) is not fully excluded; payloads carry
no secrets or tokens.

**Verifying a delivery (receivers):** compute
`HMAC-SHA256(key = the endpoint secret "whsec_...", message = t + "." + raw body)`
as lowercase hex, compare it in constant time with a `v1` value of the
header, and reject a `t` more than 5 minutes from your clock. Use the raw
request bytes, not re-serialized JSON. Node.js:

```js
import { createHmac, timingSafeEqual } from "node:crypto";
function verify(secret, header, rawBody, toleranceSec = 300) {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=", 2)));
  const t = Number(parts.t);
  if (!Number.isInteger(t) || Math.abs(Date.now() / 1000 - t) > toleranceSec) return false;
  const expected = createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
  const given = Buffer.from(parts.v1 ?? "", "utf8");
  return given.length === expected.length && timingSafeEqual(given, Buffer.from(expected, "utf8"));
}
```

(`_shared/webhook_sign.ts` `verifySignatureHeader` is the reference
implementation and also accepts several `v1` entries.)

### `pdf` (PUBLIC by document token, or staff; `verify_jwt = false`)

Quote and invoice PDFs (P-34), rendered from exactly the data the public
`/q` and `/i` pages show (`money_public_quote_json` /
`money_public_invoice_json`); amounts are printed as returned, never
recomputed. Invoices list the payments received (a receipt) and the balance;
quotes list every option with its own totals and the optional add-ons.
Standard PDF fonts cover Western European characters only: other characters
are transliterated or printed as `?`. The shop logo is embedded when it is a
PNG or JPEG of at most 1 MB.

| action | body | notes |
|---|---|---|
| `quote` | `{token}` (the quote's link token) | PUBLIC. A draft (no link yet) or unknown token is `404`. Also `GET ?action=quote&token=<uuid>` |
| `invoice` | `{token}` (the invoice's link token) | PUBLIC. Drafts / unknown: `404`; a void invoice is marked VOID. Also `GET ?action=invoice&token=<uuid>` |
| `staff_document` | `{shop_id, kind: "quote" \| "invoice", id}` | owner/admin/manager; technicians only for invoices they may collect on (`can_collect_for_invoice`), never quotes (`403`). Drafts are rendered marked DRAFT. Unknown id / other shop: `404` |

200 `application/pdf` with `Content-Disposition: inline; filename="quote-<number>.pdf"`
(or `invoice-<number>.pdf`) and `Cache-Control: private, no-store`. Web:
`supabase.functions.invoke("pdf", { body })` returns a `Blob`; iOS:
`functions.invoke` returns the bytes.

### `billing` (shop subscription billing; `verify_jwt = false`)

How the **platform operator charges shops** for Detail CRM (operator guide:
[`docs/BILLING.md`](../../docs/BILLING.md)). Everything runs on the
**platform** Stripe account: no call carries a `Stripe-Account` header. It is
unrelated to how shops charge their own customers (`payments`, Stripe
Connect). Plans, prices, limits and the trial length come from the operator's
Stripe Products/Prices and `set_billing_config`; nothing is hard-coded.
Subscription state is written only by `billing-webhook`.

`verify_jwt = false` because pg_cron and the deploy call `sync_plans` and
`sync_customers` without a Supabase JWT; `plans`, `checkout`, `portal` and
`sync_customer` verify the session in the function, so a missing or invalid session is this function's own
`401 unauthorized` envelope. The iPhone app never calls this function (no
purchase UI in the app: App Store 3.1.1 / 3.1.3); it reads the
`shop_entitlement` RPC only.

| action | caller | body | 200 response |
|---|---|---|---|
| `plans` | any signed-in user | `{}` | `{billing_enabled, plans: [{id, name, description, amount_cents, currency, interval, interval_count, max_members, features}]}` |
| `checkout` | **owner** of `shop_id` | `{shop_id, plan_id, request_nonce?}` | `{url}` (redirect the browser to Stripe Checkout) |
| `portal` | **owner** of `shop_id` | `{shop_id}` | `{url}` (redirect to the Stripe Customer Portal) |
| `sync_customer` | **owner or admin** of `shop_id` | `{shop_id}` | `{synced}` (true when Stripe was updated) |
| `sync_plans` | pg_cron / the deploy (`x-cron-secret`) | `{}` | `{upserted, deactivated, skipped: [{product_id, price_id, reason}], warnings: [{product_id, key, reason}]}` |
| `sync_customers` | pg_cron (`x-cron-secret`) | `{}` | `{checked, updated, failed}` |

- **`plans`**: `public_billing_plans()` ordered by `sort`, then amount. Never
  returns Stripe ids. While billing is off: `{billing_enabled: false, plans: []}`.
  `interval` is `month` or `year`; `max_members` null = unlimited (active
  members + pending invites, owners included); `features` are keys (the web
  maps them to labels). Show the price from `amount_cents` / `currency` /
  `interval` / `interval_count`.
- **`checkout`**: checks run in this order: session (`401`), owner of the shop
  (`403 forbidden` for admin/manager/technician, non-members and former
  owners), billing on, no live subscription, active plan. The shop's
  platform Stripe customer is reused (readdressed first when the owner
  changed, see below), or created (email = owner's email, name = shop name,
  `metadata.shop_id` and `metadata.owner_user_id`; idempotency key per shop)
  and linked
  (`billing_link_customer`) before the session exists. Checkout Session:
  `mode: subscription`, one line item (the plan's Stripe price, quantity 1),
  `client_reference_id` and `metadata.shop_id` = the shop,
  `subscription_data.metadata.shop_id`, `allow_promotion_codes: true`,
  `automatic_tax` + `customer_update.address: auto` only with
  `BILLING_AUTOMATIC_TAX=true`, and `subscription_data.trial_end` = the shop's remaining in-app trial end
  (`billing_checkout_context.trial_end`) **only when it is at least 48 hours
  plus one minute away** (Stripe's minimum is 48 h; closer trials start the
  subscription, and charge, at once). Stripe returns to
  `APP_BASE_URL/app/settings/billing?checkout=success` or `?checkout=cancelled`;
  the subscription becomes visible when `billing-webhook` applies it (poll
  `shop_entitlement` briefly). `request_nonce` as for money actions: a retry
  with the same nonce gets the same session; without one, identical requests
  within 10 minutes share one.
  **One subscription per shop.** Before a session is made, the shop's
  platform customer's subscriptions are listed in Stripe: any that can still
  bill (anything but `canceled` / `incomplete_expired`) is `409
  already_subscribed`, even while `shop_billing` does not know it yet (paid,
  webhook not arrived). The session gets `expires_at` one hour after the end
  of the current 10-minute idempotency window (60 to 70 minutes; Stripe's
  default is 24 hours). After it is made, every OLDER open subscription
  Checkout of the shop is expired, so only the newest link can be paid; an
  older one that completed at that moment wins (the new one is expired too,
  `409 already_subscribed`).
- **`portal`**: a Customer Portal session for the shop's platform customer,
  `return_url` `APP_BASE_URL/app/settings/billing`, using the operator's
  **default portal configuration** (Stripe Dashboard; plan switching,
  cancellation, payment method). Not gated on `billing_enabled`: a shop can
  always manage or cancel what it has.
- **`sync_plans`**: see [Stripe platform billing webhook](#stripe-platform-billing-webhook)
  for the plan rules. Deactivation runs only after the whole Stripe listing
  succeeded.
- **The platform customer follows the owner.** Stripe sends the shop's
  receipts, renewal notices and failed-payment emails (with the hosted
  invoice / update-card links, docs/BILLING.md) to the customer's email, so
  after `transfer_ownership` it must be the NEW owner's. The customer
  carries the owner's email and `metadata.owner_user_id`; `checkout` and
  `portal` update both when they differ from the current owner (a Stripe
  failure there is logged as `billing_customer_contact_sync_failed` and
  never blocks the owner). **`sync_customer`**: both clients call it right
  after a successful transfer, best effort (web `useTransferOwnership`,
  iOS `TeamService.transferOwnership`; the former owner is an admin by then;
  owner or admin, `403` otherwise); `{synced: false}` when there is no billing
  account yet or nothing changed. **`sync_customers`** (pg_cron, daily
  06:20 UTC) lists the platform account's customers tagged with a shop and
  readdresses each one whose `owner_user_id` is not the shop's current
  owner, when it is the customer the shop is linked to (untagged customers,
  unlinked leftovers and deleted shops are left alone). An owner who changes
  their own sign-in email is picked up at their next `checkout` / `portal` /
  `sync_customer`. Invoices Stripe already finalized keep the address they
  were finalized with.

Errors (plus the common ones):

| action | status / code | `details.reason` | meaning |
|---|---|---|---|
| `checkout`, `portal` | 403 `forbidden` | | not the shop's owner (also non-members) |
| `checkout` | 422 `unprocessable` | `billing_disabled` | the platform has not turned billing on |
| `checkout` | 409 `conflict` | `already_subscribed` | the shop has a subscription that can still bill: in `shop_billing` (trialing / active / past_due / unpaid / paused, 0101 `has_live_subscription`) or in Stripe for its platform customer (those, or `incomplete`: a payment still being confirmed; the webhook may not have arrived). Use `portal` to switch plans or settle it; after paying, wait for the confirmation instead of choosing a plan again |
| `checkout` | 404 `not_found` | `plan_not_found` | unknown or inactive plan (refresh the plan list) |
| `checkout` | 409 `conflict` | `billing_account_changed` | `billing_link_customer` 23505: this shop was just linked to a different platform customer (a concurrent first checkout); refresh and retry — the retry uses the linked one |
| `checkout` | 409 `conflict` | `customer_conflict` | `billing_link_customer` 23505: the Stripe customer belongs to another shop (support case) |
| `portal` | 409 `conflict` | `no_billing_account` | no platform customer yet: choose a plan first |
| `portal` | 503 `service_unavailable` | `portal_not_configured` | the operator has not saved the Customer Portal settings in Stripe |
| `sync_customer` | 403 `forbidden` | | not the shop's owner or admin |
| `sync_plans`, `sync_customers` | 401 `unauthorized` | | missing / wrong `x-cron-secret` |

### `billing-webhook` (Stripe only, platform account; `verify_jwt = false`)

`POST /functions/v1/billing-webhook`, raw body (at most 1 MiB), header
`Stripe-Signature` verified with `STRIPE_BILLING_WEBHOOK_SECRET` (a request
without the header is `400 invalid_signature` before the secret is read). No
CORS, no JWT, not called by apps. Responses as `stripe-webhook`:
`200 {received: true, handled, duplicate, result}`, `400 invalid_signature`,
`409 conflict`, `413`, `500 internal_error` (Stripe retries),
`500 server_misconfigured` (the secret is not set).

- **Platform events only**: an event with `account` (a connected account's)
  is acknowledged with `handled: false` and never processed or written to
  the `stripe_events` ledger that `stripe-webhook` shares.
- Idempotent through `processStripeEventOnce` (`stripe_events`): a replay of a
  processed event is `duplicate: true`; a failed attempt is retried.
- `customer.subscription.created` / `updated` / `deleted`, `invoice.paid`:
  the subscription is re-read from Stripe and applied with
  `billing_apply_subscription` (customer, subscription, the first item's
  price, status, `trial_end`, the latest item `current_period_end`,
  `cancel_at_period_end` (also true for a set `cancel_at`), and the event's
  `created`). The RPC ignores events older than the last one applied, so
  out-of-order deliveries never roll a shop back; `deleted` records
  `canceled` and keeps the paid-through period end. A subscription Stripe no
  longer has falls back to the event's object.
- `checkout.session.completed` (`mode: subscription`, `client_reference_id`
  **and** `metadata.shop_id` naming the same shop, as `checkout` sets them):
  `billing_link_customer`, then the subscription is applied. A foreign
  session (a Payment Link, another product) is ignored.
- **One subscription per shop.** Before a subscription that is live or
  `incomplete` is applied, the customer's subscriptions are listed in
  Stripe (`status: all`). The oldest live one (trialing / active / past_due
  / unpaid / paused; `created`, then id) is the shop's: a newer one is a
  duplicate and is never applied — the oldest is applied instead, so the
  row never flips between two subscriptions. A duplicate this platform's
  `checkout` created (`metadata.shop_id` = the shop) is refunded (every paid
  invoice's payment, `reason: duplicate`, idempotency key per payment) and
  then cancelled now (`result: "applied"`, detail
  `duplicate_subscription_cancelled`, warning
  `billing_duplicate_subscription_cancelled` with `refunded_cents`). Refunds
  run first, so a retry after a failure still finds the duplicate live and
  finishes it. One made elsewhere (no such metadata, e.g. the Dashboard) is
  only logged (`ignored`, reason `duplicate_subscription`, warning) for the
  operator. Nothing is cancelled for a customer no shop is linked to.
- `invoice.payment_failed`: the subscription is refreshed (usually
  `past_due`), then `billing_payment_failed` notifies the owner
  (`billing_payment_failed` notification, deep link to Settings > Billing).
  Not for a duplicate (it was just cancelled).
- `product.*` / `price.*`: the whole plan sync runs again.
- Not ours (a customer no shop is linked to — `billing_apply_subscription`
  answers `{shop_id: null, applied: false}`, never an error — a customer or
  subscription another shop owns (23505), an unknown status) is
  `result: "ignored"`, never retried.

## Testing

```sh
scripts/test_functions.sh     # fmt --check, lint, check every .ts, deno test
cd supabase/functions && deno task test
```

Tests run **without network permission**. Inject fakes:

- `FakeFetch` (`_shared/testing/fake_fetch.ts`) routes by method + URL
  pattern, records calls (`call.json`, `call.form`, headers) and rejects
  unmatched requests.
- `FakeSupabase` serves PostgREST tables/RPCs and `auth/v1/user` behind the
  real supabase-js client: `db.admin()`, `db.asUser(token)`, `db.env()`,
  `db.table(name)`, `db.requests[i].role`. RLS is not emulated (the SQL suite
  covers policies); unsupported query syntax fails loudly.
- Put Stripe/Twilio/Resend stubs on `db.http` so one fetch serves everything;
  build Stripe with `createStripe(key, { fetch, maxNetworkRetries: 0 })` or
  `stripeFromEnv(env, { fetch, maxNetworkRetries: 0 })`.
- `signStripePayload` / `stripeEvent` produce signed webhook deliveries;
  `computeTwilioSignature` signs Twilio form posts.
- `jsonRequest`, `formRequest`, `preflightRequest`, `responseJson`,
  `memoryLogger`, `testEnv(overrides)`.
- `apnsTestKey()` (a generated ES256 key as a `.p8` PEM), `pdfText(bytes)` /
  `extractPdfText(bytes)` (the text runs of a PDF written by `_shared/pdf.ts`),
  `LOGO_PNG` (`testing/images.ts`). Outbound DNS is injected too
  (`webhooks` `Deps.resolver`), so no test resolves a real name.

## Dependencies

All functions share `supabase/functions/deno.json` (declared per function as
`import_map = "./functions/deno.json"` in `config.toml`, resolved relative to
`supabase/`). Versions are exact (`config_test.ts` enforces it); `lock` is
off so the hosted edge runtime never trips over a newer lockfile format.
Production code imports only bare package names (`zod`, `stripe`,
`@supabase/supabase-js`, `pdf-lib`) and relative `_shared` files — no subpath
imports. `pdf-lib` (1.17.1) renders the `pdf` function's documents with the
standard PDF fonts; images are structure-checked (`_shared/pdf.ts`) before
pdf-lib decodes them, because its decoders can loop on corrupt files.
To upgrade Stripe, bump the SDK and `STRIPE_API_VERSION` together (a test
asserts they match) and update the webhook endpoint's API version.

## Secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
by Supabase. Set the rest (never commit them):

```sh
supabase secrets set --project-ref <ref> \
  STRIPE_SECRET_KEY=sk_live_... STRIPE_PUBLISHABLE_KEY=pk_live_... \
  STRIPE_WEBHOOK_SECRET=whsec_... PLATFORM_FEE_BPS=0 \
  STRIPE_BILLING_WEBHOOK_SECRET=whsec_... \
  TWILIO_ACCOUNT_SID=AC... TWILIO_AUTH_TOKEN=... \
  RESEND_API_KEY=re_... EMAIL_FROM="Detail CRM <notifications@yourdomain.com>" \
  APP_BASE_URL=https://app.yourdomain.com \
  CRON_SECRET="$(openssl rand -hex 32)"
# optional: CORS_ALLOWED_ORIGINS=https://staging.yourdomain.com
# optional, push notifications for the iPhone app (all four or none):
#   APNS_KEY_ID=ABC123DEFG APNS_TEAM_ID=TEAM123456 APNS_TOPIC=<bundle id> \
#   APNS_PRIVATE_KEY="$(cat AuthKey_ABC123DEFG.p8)"
# optional feature flags (unset = off):
#   SMS_PROVISIONING_ENABLED=true TWILIO_ISV_ENABLED=true \
#   TWILIO_PRIMARY_CUSTOMER_PROFILE_SID=BU...
supabase secrets list --project-ref <ref>
```

| Secret | Needed by | Notes |
|---|---|---|
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_TOPIC` | `push` | An APNs auth key (developer.apple.com -> Keys -> Apple Push Notifications service): its Key ID, your Team ID, the `.p8` contents (literal `\n` line breaks are accepted) and the app's bundle id. The App ID needs the Push Notifications capability. None set = no pushes (the queue is left alone); some set = `server_misconfigured` |
| `STRIPE_BILLING_WEBHOOK_SECRET` | `billing-webhook` | Signing secret of the **platform** billing endpoint ([Stripe platform billing webhook](#stripe-platform-billing-webhook)); a different endpoint and secret from the Connect one. Needed only while billing is on (`scripts/deploy --stripe-webhooks` creates the endpoint and stores it). Billing on/off and the trial length are database settings (`set_billing_config`), not secrets |
| `BILLING_AUTOMATIC_TAX` | `billing` | `true` turns on Stripe Tax for shop subscription Checkout (`automatic_tax`, address saved on the platform customer). Only once Stripe Tax is set up on the platform account; unset = off |
| `SMS_PROVISIONING_ENABLED` | `sms-provisioning` | `true` turns on self-serve numbers. Only once the platform Twilio account may buy numbers and submit toll-free verifications, and number costs are accounted for |
| `TWILIO_ISV_ENABLED` | `sms-provisioning` | `true` also offers A2P 10DLC registration of local numbers (the platform account must be an approved ISV) |
| `TWILIO_PRIMARY_CUSTOMER_PROFILE_SID` | `sms-provisioning` | the ISV's approved primary Trust Hub customer profile (`BU...`), assigned to every shop's secondary profile; required with `TWILIO_ISV_ENABLED` |

Stripe keys must be the same mode (test/live); `Env` rejects mixed pairs.
`CRON_SECRET` must be at least 24 characters and match the value used by the
pg_cron jobs in `supabase/setup/`. `APP_BASE_URL` must also be written to
the database, where customer links in messages are built
(`platform_config.app_base_url`): run `supabase/setup/cron.sql` with the same
value (it calls `set_app_base_url`). Until then link-bearing messages are
not queued and automations refuse to run.

## Deploy

```sh
supabase link --project-ref <ref>
supabase functions deploy stripe-connect
supabase functions deploy payments
supabase functions deploy stripe-webhook
supabase functions deploy messaging
supabase functions deploy invites
supabase functions deploy storage-purge
supabase functions deploy account
supabase functions deploy push
supabase functions deploy calendar-feed
supabase functions deploy public-media
supabase functions deploy sms-provisioning
supabase functions deploy webhooks
supabase functions deploy pdf
supabase functions deploy billing
supabase functions deploy billing-webhook
# or all at once (every [functions.*] entry must exist as a directory):
supabase functions deploy
```

`verify_jwt` comes from `config.toml`: `stripe-connect`, `invites` and
`account` require a Supabase JWT at the gateway; `payments`,
`stripe-webhook`, `messaging`, `storage-purge`, `push`, `calendar-feed`,
`public-media`, `sms-provisioning`, `webhooks`, `pdf`, `billing` and
`billing-webhook` have public, webhook, calendar-app or cron entry points and
authenticate every request themselves.

### Launch / upgrade checklist

Run through it at launch and after every release (`scripts/deploy/`
automates steps 1-3 for a hosted project):

1. **Deploy the functions and set the secrets** ([Secrets](#secrets)):
   every `[functions.*]` entry of `config.toml` is deployed with its
   `verify_jwt`. Migrations first, so the functions find the RPCs they call.
2. **Re-run `supabase/setup/cron.sql`** (with the private values) after any
   release that adds or changes a scheduled job. It is idempotent: every job
   is unscheduled and scheduled again, and the app URL and Vault secrets are
   upserted. Jobs today (the `jobname`s in `cron.job`; the header of
   cron.sql describes each):
   - `detail-crm-process-queue` - `messaging` `process_queue`, every minute
   - `detail-crm-run-automations` - `enqueue_due_automations()`, every 5 min
     (reminders, follow-ups, document follow-ups, task reminders)
   - `detail-crm-expire-quotes` - `expire_quotes()`, daily 06:05 UTC
   - `detail-crm-sweep-payment-sheets` - `payments` `sweep_payment_sheets`,
     every 10 min
   - `detail-crm-storage-purge` - `storage-purge` `purge`, every 15 min
   - `detail-crm-push` - `push` `process_queue`, every minute
   - `detail-crm-webhooks` - `webhooks` `deliver`, every minute
   - `detail-crm-sms-status` - `sms-provisioning` `refresh_status`, every
     30 min
   - `detail-crm-sms-releases` - `sms-provisioning` `release_worklist`,
     daily 06:50 UTC
   - `detail-crm-generate-series` - `generate_series_jobs()`, daily 07:15 UTC
   - `detail-crm-billing-sync-plans` - `billing` `sync_plans`, daily
     06:35 UTC
   - `detail-crm-billing-sync-customers` - `billing` `sync_customers`, daily
     06:20 UTC
   - `detail-crm-prune-cron-history` - daily 04:41 UTC, SQL only: deletes
     `cron.job_run_details` rows older than 7 days of the `detail-crm-*`
     jobs and of jobs no longer scheduled (pg_cron never clears its run
     log); other jobs' history is left alone.

   Any other `detail-crm-*` name in `cron.job` is left over from an older
   release that cron.sql no longer schedules: unschedule it by hand.
   cron.sql is https-only on purpose: local stacks use
   `scripts/stack/sql/setup_local.sql` instead, and
   `scripts/stack/verify_stack.mjs` exercises the scheduled actions there.
3. **Stripe:** the Connect endpoint (`stripe-webhook`, "Events on Connected
   accounts") must be subscribed to **every** event in
   [Stripe Connect webhook](#stripe-connect-webhook), including the refund
   (`charge.refund.updated`, `refund.updated`, `refund.failed`), dispute
   (`charge.dispute.*`) and `payment_method.detached` events; add any event
   a release adds to `HANDLED_EVENT_TYPES`. With billing on, the **platform**
   billing endpoint (`billing-webhook`) must have exactly the events of
   `billing-webhook/handlers.ts` `HANDLED_EVENT_TYPES`
   ([Stripe platform billing webhook](#stripe-platform-billing-webhook)).
4. **Twilio:** each shop number's "A message comes in" webhook points at
   `messaging?action=twilio_inbound&shop_id=<SHOP UUID>#rc=3&rp=all`
   ([Twilio webhooks](#twilio-webhooks), `supabase/setup/twilio.md`); the
   status callback is sent with every SMS. Numbers bought through
   `sms-provisioning` are configured automatically, and released
   automatically when their shop is deleted. Numbers that stop being bound
   to a shop are logged in `public.sms_number_releases`; the daily
   `release_worklist` job reports the ones the platform still rents (log
   `sms_numbers_awaiting_release`, or call the action with the cron secret:
   supabase/setup/twilio.md "Numbers no shop uses") — release those in
   Twilio.
5. **Storage:** job videos go up to 200 MB (`job-media` bucket). Raise the
   hosted project's upload limit (Dashboard -> Storage -> Settings) to at
   least 200 MB; `config.toml` sets it for local stacks.
6. **APNs:** create the auth key once, set the four `APNS_*` secrets, and
   enable the Push Notifications capability on the App ID.

Local: `supabase start`, then
`supabase functions serve --env-file supabase/functions/.env.local`.

## Stripe Connect webhook

Shops connect Express accounts; charges are direct charges on the connected
account, so payment events are emitted **on the connected account**.

1. Dashboard -> Developers -> Webhooks -> Add endpoint.
2. URL: `https://<ref>.supabase.co/functions/v1/stripe-webhook`.
3. Choose **"Events on Connected accounts"** (a Connect endpoint) and API
   version `2026-08-26.dahlia` (= `STRIPE_API_VERSION`).
4. Events: `checkout.session.completed`,
   `checkout.session.async_payment_succeeded`,
   `checkout.session.async_payment_failed`, `checkout.session.expired` (an
   online gift card order whose Checkout expired unpaid becomes `expired`;
   an expired pay / deposit link's page holds are released),
   `payment_intent.processing`
   (ACH debits clearing), `payment_intent.succeeded`,
   `payment_intent.payment_failed`, `payment_intent.canceled`,
   `charge.refunded`, `charge.refund.updated`, `refund.updated`,
   `refund.failed` (a failed refund lowers the refunded total),
   `setup_intent.succeeded`,
   `payment_method.detached`, `customer.deleted` (saved cards removed in
   Stripe are removed from the CRM),
   `charge.dispute.created`, `charge.dispute.updated`,
   `charge.dispute.closed`, `charge.dispute.funds_withdrawn`,
   `charge.dispute.funds_reinstated` (outcome recorded in
   `payments.disputed_cents`, flagged in the payment's note + owner/admin
   notification),
   `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.paid`,
   `invoice.payment_failed`, `account.updated`.
   `HANDLED_EVENT_TYPES` in `stripe-webhook/handlers.ts` is the source of truth.
5. Copy the signing secret into `STRIPE_WEBHOOK_SECRET`.

Each event carries `event.account` (`eventAccount(event)`); map it to the shop
via `shop_stripe_accounts.stripe_account_id` and ignore unknown accounts.
Local testing: `stripe listen --forward-connect-to localhost:54321/functions/v1/stripe-webhook`
(use the printed `whsec_...`).

## Stripe platform billing webhook

Shop subscription billing (operator guide: [`docs/BILLING.md`](../../docs/BILLING.md))
uses the **platform** account's own events, so it has its own endpoint,
separate from the Connect endpoint above:

1. Dashboard -> Developers -> Webhooks -> Add endpoint.
2. URL: `https://<ref>.supabase.co/functions/v1/billing-webhook`.
3. **"Events on your account"** (not Connect), API version
   `2026-08-26.dahlia` (= `STRIPE_API_VERSION`).
4. Events: `checkout.session.completed`, `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`,
   `invoice.paid`, `invoice.payment_failed`, `product.created`,
   `product.updated`, `product.deleted`, `price.created`, `price.updated`,
   `price.deleted`. `HANDLED_EVENT_TYPES` in `billing-webhook/handlers.ts` is
   the source of truth.
5. Copy its signing secret into `STRIPE_BILLING_WEBHOOK_SECRET`.

`scripts/deploy/deploy_backend.sh --stripe-webhooks` does all of this when
`BILLING_ENABLED=true` (tag `detail_crm_role=billing`).

**Plan sync** (`_shared/billing_plans.ts`; `billing` `sync_plans`, every
`product.*` / `price.*` event, the daily cron job and the deploy): every
**active** Product with metadata `detailcrm_plan` = `true` is a plan; each
of its active recurring Prices billed per unit with a fixed amount, monthly
or yearly (any `interval_count`), becomes one `platform_plans` row
(`billing_upsert_plan`): name / description from the Product, amount /
currency / interval from the Price, and from Product metadata
`max_members` (a positive whole number; anything else = unlimited, with a
warning), `features` (comma-separated keys, lowercased; invalid keys left out
with a warning) and `sort` (a whole number; else 0, with a warning). Weekly,
daily, metered, tiered and customer-chosen-amount Prices are skipped with a
reason. Every row whose Price was not listed is deactivated
(`billing_deactivate_plans_except`). Local testing:
`stripe listen --events checkout.session.completed,customer.subscription.created,... --forward-to localhost:54321/functions/v1/billing-webhook`
(use the printed `whsec_...` as `STRIPE_BILLING_WEBHOOK_SECRET`).

## Twilio webhooks

Configure the webhook on each shop's number in the Twilio Console; US numbers
also go in the shop's own A2P 10DLC Messaging Service (one brand, campaign
and service per shop, never shared: Twilio scopes STOP per service), set to
"Defer to sender's webhook" (full procedure in `supabase/setup/twilio.md`):

- **A message comes in:** `POST https://<ref>.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=<SHOP UUID>#rc=3&rp=all`
  (`shop_id` is the platform's binding of the number to its shop: messaging
  only sends from, and routes replies/STOPs through, a number whose inbound
  URL names that shop; `#rc=3&rp=all` makes Twilio retry a 5xx).
- **Status callback:** sent per message as `StatusCallback`
  (`messaging?action=twilio_status#rc=3&rp=all`, see `messaging/deliver.ts`).

The signature covers the exact URL including `?action=...`, so the URL in
Twilio must match `FUNCTIONS_PUBLIC_URL`/`SUPABASE_URL` exactly. When
tunnelling local dev, set `FUNCTIONS_PUBLIC_URL` to the tunnel's
`.../functions/v1`. Inbound keywords are applied by `record_inbound_sms`
(0033): STOP and its synonyms opt out; START, UNSTOP and YES (Twilio's
opt-in keywords; "yes please..." is an ordinary reply) opt back in.
`classifyOptKeyword` mirrors the same lists. Reply to Twilio with
`emptyTwiml()`.
