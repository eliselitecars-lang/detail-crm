# Screenshot tooling (`scripts/screenshots/`)

Fills the **local real stack** (`scripts/stack/up.sh`) with a believable,
clearly fictional **sample** detailing shop and captures screenshots of the
web app. Sample data is for screenshots only: it never ships in the product,
and the seed refuses non-local API URLs (`SEED_ALLOW_REMOTE=1` overrides).

```bash
scripts/stack/up.sh                          # real stack (resets the DB)
node scripts/screenshots/seed_demo.mjs       # sample shop -> .state/demo.json
node scripts/screenshots/web_shots.mjs       # web screenshots (see below)
```

## `seed_demo.mjs` — the sample shop

Node 22, no dependencies. Reads `STACK_API_URL`, `STACK_ANON_KEY`,
`STACK_SERVICE_ROLE_KEY`, `STACK_FUNCTIONS_URL`, `STACK_PROVIDER_MOCK_URL`,
`STACK_STRIPE_WEBHOOK_SECRET`, `STACK_TWILIO_AUTH_TOKEN`, `STACK_CRON_SECRET`,
`STACK_APP_URL` from the environment or `scripts/stack/.state/stack.env`.
Takes a few seconds.

**Summit Auto Detailing** (Nashville, America/Chicago, shop + mobile, a
generated sample logo): owner Jordan Avery, technician Marcus Reed (joined
through the real invite flow, with a pay rate) and one pending invite, a priced
catalog (8 services × 4 vehicle sizes, 5 add-ons, 2 membership plans, a coupon,
a checklist, 2 bays and a van), online booking with a 25% deposit, 14 customers
with vehicles, ~38 jobs relative to *today* in the shop zone (24 completed
over the last ~4 weeks, 4 today: completed / in progress / on the way /
confirmed, ~10 upcoming), invoices (paid by card with tips, cash, partially
paid, open, overdue), a deposit, quotes (draft, sent, approved, converted,
declined), an online booking request, SMS threads (outbound + signed inbound
replies), the shop's automatic texts and emails (on the way, job done,
receipts, reminders) delivered by the cron path, timesheets (past shifts and
job time, owner and technician on the clock today), tasks, a sent and a draft
campaign, and a client portal login. Phones are 555-01xx, emails
`@example.com`.

Records are created through the paths the apps use: GoTrue sign-ups, the
owner's JWT on PostgREST (RLS) and the real RPCs and edge functions
(`invites`, `messaging`, `stripe-connect`), anon `create_online_booking` /
`public_respond_quote`, signed Stripe Connect and Twilio webhooks (a card
payment is dated by its Stripe charge's `created`). The service role is used
only as the e2e journeys use it (Stripe `charges_enabled`, provisioning the
SMS number) plus one **history** step: the stack clock cannot move, so the
server-stamped times of past work (job started/completed, invoice issued/due,
quote sent/answered, campaign launched, the messages and notifications they
produced, customer since) are shifted back to when that work happened. The
queued automatic messages are delivered with the cron secret, as pg_cron
does (`messaging` `run_automations` / `process_queue`).

**Re-runs**: the first run on a fresh database uses the canonical logins
below and `/book/summit-auto`. When they already exist, the script creates a
fresh copy with a run suffix (`jordan.avery+r1a2b@example.com`,
`/book/summit-auto-r1a2b`); `SEED_SUFFIX=<x>` forces one. `demo.json` always
describes the latest run.

| login | email | password |
|---|---|---|
| owner | `jordan.avery@example.com` | `Summit-Demo-Owner-2026!` |
| technician | `marcus.reed@example.com` | `Summit-Demo-Tech-2026!` |
| client (`/portal`) | `emily.carter@example.com` | `Summit-Demo-Client-2026!` |

### `.state/demo.json` contract

```jsonc
{
  "sample": true, "generatedAt": "…", "shopToday": "YYYY-MM-DD",
  "apiUrl": "http://127.0.0.1:54321", "anonKey": "…", "appUrl": "http://127.0.0.1:5173",
  "shop": { "id", "slug", "name", "timeZone", "smsNumber" },
  "owner": { "email", "password", "name", "userId" },
  "technician": { "email", "password", "name", "userId" },
  "client": { "email", "password", "name", "userId" },
  "links": { "booking": "/book/<slug>", "quote": "/q/<token>", "invoice": "/i/<token>",
             "invoiceOverdue": "/i/<token>", "manageBooking": "/booking/<token>",
             "join": "/join/<slug>", "portal": "/portal", "login": "/login" },
  "ids": { "jobInProgress", "jobEnRoute", "jobCompletedToday", "customer",
           "customerWithThread", "quoteSent", "quoteApproved", "invoiceOpen",
           "invoiceOverdue", "invoicePartial", "invoicePaidToday", "onlineBookingJobToken" }
}
```

Not seeded: active memberships (stripe-mock is stateless: activating a
subscription would store its fixture price and a period end in 2000) and job
photos.

## `web_shots.mjs` — web screenshots

Builds the web app against the stack (`vite build` with `VITE_SUPABASE_URL` /
`VITE_SUPABASE_ANON_KEY` from `stack.env`, into `.state/web-dist`), serves it
with `vite preview` on the origin the stack expects (`STACK_APP_URL`, default
`http://127.0.0.1:5173`; stop a dev server there first), signs in through the
real login page and saves ~40 PNGs plus `MANIFEST.md` to `SHOTS_DIR` (default
`scripts/screenshots/.state/web`): staff screens at 1440×900 @2x, the
technician's view, public pages (booking flow, quote, invoice, portal,
pricing) and phone-width (390×844 @3x) shots. Each shot waits for network
idle, no skeletons and loaded fonts; API errors, page errors and error states
are listed under "Issues seen" in the manifest. Uses Playwright's Chromium
from `web/node_modules` (`PW_CHROMIUM_EXECUTABLE` overrides).

Knobs: `SHOTS_SKIP_BUILD=1` reuses the last build, `SHOTS_ONLY=<regex>`
captures matching file names only (no manifest). Behind an HTTPS proxy
(`HTTPS_PROXY`), Google Fonts are fetched by Node (`NODE_USE_ENV_PROXY`)
because Chromium cannot verify the proxy's certificate.
