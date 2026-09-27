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
    testing/           FakeFetch, FakeSupabase, request builders, test env, Stripe signer
  <function>/index.ts  one directory per deployed function (stripe-connect, payments,
                       stripe-webhook, messaging, invites)
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
pg_cron jobs in `supabase/setup/`.

## Deploy

```sh
supabase link --project-ref <ref>
supabase functions deploy stripe-connect
supabase functions deploy payments
supabase functions deploy stripe-webhook
supabase functions deploy messaging
supabase functions deploy invites
# or all at once (every [functions.*] entry must exist as a directory):
supabase functions deploy
```

`verify_jwt` comes from `config.toml`: `stripe-connect` and `invites` require
a Supabase JWT at the gateway; `payments`, `stripe-webhook` and `messaging`
have public/webhook/cron entry points and authenticate every request
themselves.

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
   `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.paid`,
   `invoice.payment_failed`, `account.updated`.
5. Copy the signing secret into `STRIPE_WEBHOOK_SECRET`.

Each event carries `event.account` (`eventAccount(event)`); map it to the shop
via `shop_stripe_accounts.stripe_account_id` and ignore unknown accounts.
Local testing: `stripe listen --forward-connect-to localhost:54321/functions/v1/stripe-webhook`
(use the printed `whsec_...`).

## Twilio webhooks

Configure each shop's number (not a Messaging Service) in the Twilio Console;
full procedure in `supabase/setup/twilio.md`:

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
