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
    fetch_timeout.ts   withTimeout: per-request time cap (body included) for Twilio/Resend calls
    testing/           FakeFetch, FakeSupabase, request builders, test env, Stripe signer
  <function>/index.ts  one directory per deployed function (stripe-connect, payments,
                       stripe-webhook, messaging, invites, storage-purge)
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
| Stripe | `verifyStripeWebhook(stripe, rawBody, req.headers.get("stripe-signature"), env.stripeWebhookSecret())` before parsing anything. |
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
`service_unavailable`, Twilio/Resend failures -> `502 upstream_error`.

| code | status | when |
|---|---|---|
| `bad_request`, `invalid_json`, `validation_failed`, `unknown_action` | 400 | malformed input |
| `invalid_signature` | 400 | webhook signature failed |
| `unauthorized` | 401 | no/invalid session, bad cron secret |
| `payment_failed` | 402 | card declined |
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
  `stripe-connect` and `invites` (`verify_jwt = true`) the Supabase gateway
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

`verify_jwt = false`: two actions are public, one is cron; the rest verify
the staff JWT themselves. Payment rows are written server-side;
`stripe-webhook` is the source of truth for final states, so after a
checkout/sheet completes, re-read the invoice/booking rather than trusting
the client.

#### `invoice_checkout` (PUBLIC, invoice token)

Body `{token, tip_cents?, request_nonce?}` (`token` = `invoices.public_token`,
the `/i/<token>` link). Opens a Stripe Checkout Session for the invoice's
**whole current balance** plus the optional tip (a separate "Tip" line).

200: `{url, expires_at, amount_cents, tip_cents, currency}`: redirect to
`url`. `amount_cents` is the balance charged, `tip_cents` the tip. The
session lives about 32-42 minutes; opening a new one expires the invoice's
older links and the job's open deposit links. Stripe returns the customer to
`/i/<token>?paid=1` or `/i/<token>?canceled=1`. The card is saved for
off-session use.

Errors: `404 not_found` (unknown token or a draft invoice), `409 conflict`
reasons `void`, `paid`, `payment_in_progress`, `checkout_superseded`
(links keep changing: refresh), `422 unprocessable` reasons `tip_too_large`
(`details.max_tip_cents`), `amount_out_of_range`, `stripe_not_connected`,
`charges_disabled`.

#### `booking_deposit_checkout` (PUBLIC, booking token)

Body `{token, request_nonce?}` (`token` = `jobs.public_token`, the
`/booking/<token>` link). No tip. Charges the deposit still due, computed by
the database (`public_get_booking.deposit.due_cents` = least(deposit
required, job total) minus money received), capped at what the job's
non-void invoice still owes.

200: `{url, expires_at, amount_cents, tip_cents: 0, currency}`. Returns to
`/booking/<token>?paid=1` or `?canceled=1`. A new deposit link expires the
job's open deposit and invoice pay links.

Errors: `404 not_found` (unknown token), `409 conflict` reasons
`booking_closed` (job cancelled / no-show / completed), `deposit_not_due`,
`payment_in_progress`, `checkout_superseded`, `422 unprocessable` reasons
`amount_out_of_range`, `stripe_not_connected`, `charges_disabled`.

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
invoice. Earlier open sheets on the invoice are cancelled (latest sheet
wins) and its open pay/deposit links are expired. **Call
`cancel_open_payments` when the sheet is dismissed without paying**;
otherwise the cron sweep releases it after 30 minutes.

Errors: `403 forbidden` (technician not allowed or not assigned),
`404 not_found` (invoice not in this shop), invoice-state errors,
`409 conflict` reasons `payment_in_progress`, `payment_superseded`,
`422 unprocessable` reasons `amount_exceeds_balance`
(`details.balance_cents`), `tip_too_large` (`details.max_tip_cents`),
`amount_out_of_range`, `stripe_not_connected`, `charges_disabled`.

#### `cancel_open_payments` (same callers as `payment_sheet`)

Body `{shop_id, invoice_id}`. Releases the invoice: cancels its unconfirmed
PaymentSheet intents, records any that already succeeded, and expires its
open Checkout pay links and its job's deposit links. Call it when a sheet is
dismissed and **before voiding or editing** an invoice. It never cancels a
payment that is already processing.

200: `{invoice_id, cancelled, succeeded, in_progress, sessions_expired}`
(counts; all 0 when the shop has no Stripe account). `in_progress > 0` means
money is still moving: do not void yet.

Errors: `403 forbidden`, `404 not_found`.

#### `sweep_payment_sheets` (pg_cron, `x-cron-secret`)

Body `{}` (just `{"action":"sweep_payment_sheets"}`). Settles PaymentSheet
rows left unconfirmed for 30+ minutes, in batches across shops.
200: `{checked, succeeded, cancelled, in_progress, unchanged, failed}`.
Errors: `401 unauthorized`.

#### `charge_saved_card` (manager+)

Body `{shop_id, invoice_id, payment_method_id?, amount_cents?, request_nonce?}`.
`payment_method_id` (`pm_...`, `card_...` or `src_...`) must be one of the
invoice customer's saved cards (`customer_payment_methods`); if it is
omitted, the default card is used. `amount_cents` defaults to the balance.
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
`422 unprocessable` reasons `no_saved_card`, `amount_exceeds_balance`
(`details.balance_cents`), `amount_out_of_range`, `stripe_not_connected`,
`charges_disabled`.

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
200: `{url, expires_at}`. Stripe returns the customer to
`APP_BASE_URL/portal?card=saved` or `?card=canceled`. Errors are the same as
`setup_card`.

#### `refund` (owner/admin)

Body `{shop_id, payment_id, amount_cents?, request_nonce?}`. Only for card
payments (`method` `card`/`card_present`) in status `succeeded` or
`partially_refunded`. Cash and other manual payments use the
`refund_manual_payment` RPC. `amount_cents` defaults to everything still
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
reasons `not_a_card_payment`, `amount_exceeds_refundable`
(`details.refundable_cents`), `refund_failed`, `stripe_not_connected`.

#### `membership_checkout` (manager+)

Body `{shop_id, membership_id, request_nonce?}`. The membership must be
`incomplete` with no subscription yet. The amount is the plan's
`price_cents`, recurring every `interval_count` `interval`s. The plan's
Stripe Product/Price is created on the shop's account when needed. A new link
expires the membership's older links.

200: `{url, expires_at, amount_cents, interval, interval_count, currency}`.
Stripe returns the customer to `APP_BASE_URL/portal?membership=active` or
`?membership=canceled`. The webhook activates the membership.

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
  `cancel_at_period_end`.

Errors: `404 not_found`, `409 conflict` reasons `already_cancelled`,
`membership_changed` (refresh), `422 unprocessable` reason
`stripe_not_connected`.

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

### `messaging`

`verify_jwt = false`. `POST` for every action; `GET` only for
`unsubscribe` (any other GET is `405`).

#### `send` (staff)

Body `{shop_id?, customer_id?, job_id?, channel, template_key?, subject?, body?}`:

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
- Roles: owner/admin/manager can send anything. Technicians can send only
  `template_key` `on_the_way` / `job_started` / `job_completed`, with a
  `job_id` they are assigned to.

200: `{message_id, channel, status, error}`, where `status` is the state
after the immediate delivery attempt: `sent`, `failed` (`error` holds a
short reason), `queued` (retry scheduled), `sending` or `cancelled`. A
repeat of an identical send by the same staff member within 5 minutes
returns the **original** message (its id and current status, which may be
`delivered`) and sends nothing new. A delivery failure is still 200: show
`error`.

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
  `error` says what to set up)
- `empty_message`
- `job_customer_mismatch`
- `job_required` (optionally `details.variables`)
- `not_sendable`

#### `process_queue` (pg_cron, `x-cron-secret`)

Body `{limit?}`, where `limit` is 1-1000 (default 200). Claims and delivers
queued messages.

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

## Dependencies

All functions share `supabase/functions/deno.json` (declared per function as
`import_map = "./functions/deno.json"` in `config.toml`, resolved relative to
`supabase/`). Versions are exact (`config_test.ts` enforces it); `lock` is
off so the hosted edge runtime never trips over a newer lockfile format.
Production code imports only bare package names (`zod`, `stripe`,
`@supabase/supabase-js`) and relative `_shared` files — no subpath imports.
To upgrade Stripe, bump the SDK and `STRIPE_API_VERSION` together (a test
asserts they match) and update the webhook endpoint's API version.

## Secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
by Supabase. Set the rest (never commit them):

```sh
supabase secrets set --project-ref <ref> \
  STRIPE_SECRET_KEY=sk_live_... STRIPE_PUBLISHABLE_KEY=pk_live_... \
  STRIPE_WEBHOOK_SECRET=whsec_... PLATFORM_FEE_BPS=0 \
  TWILIO_ACCOUNT_SID=AC... TWILIO_AUTH_TOKEN=... \
  RESEND_API_KEY=re_... EMAIL_FROM="Detail CRM <notifications@yourdomain.com>" \
  APP_BASE_URL=https://app.yourdomain.com \
  CRON_SECRET="$(openssl rand -hex 32)"
# optional: CORS_ALLOWED_ORIGINS=https://staging.yourdomain.com
supabase secrets list --project-ref <ref>
```

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
# or all at once (every [functions.*] entry must exist as a directory):
supabase functions deploy
```

`verify_jwt` comes from `config.toml`: `stripe-connect` and `invites` require
a Supabase JWT at the gateway; `payments`, `stripe-webhook`, `messaging` and
`storage-purge` have public/webhook/cron entry points and authenticate every
request themselves.

Local: `supabase start`, then
`supabase functions serve --env-file supabase/functions/.env.local`.

## Stripe Connect webhook

Shops connect Express accounts; charges are direct charges on the connected
account, so payment events are emitted **on the connected account**.

1. Dashboard -> Developers -> Webhooks -> Add endpoint.
2. URL: `https://<ref>.supabase.co/functions/v1/stripe-webhook`.
3. Choose **"Events on Connected accounts"** (a Connect endpoint) and API
   version `2026-08-26.dahlia` (= `STRIPE_API_VERSION`).
4. Events: `checkout.session.completed`, `payment_intent.succeeded`,
   `payment_intent.payment_failed`, `payment_intent.canceled`,
   `charge.refunded`, `charge.refund.updated`, `refund.updated`,
   `refund.failed` (a failed refund lowers the refunded total),
   `setup_intent.succeeded`,
   `payment_method.detached`, `customer.deleted` (saved cards removed in
   Stripe are removed from the CRM),
   `charge.dispute.created`, `charge.dispute.updated`,
   `charge.dispute.closed`, `charge.dispute.funds_withdrawn`,
   `charge.dispute.funds_reinstated` (flagged on the payment + owner/admin
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
`.../functions/v1`. Inbound STOP/START/HELP keywords are classified by
`classifyOptKeyword`; reply to Twilio with `emptyTwiml()`.
