# Real-stack harness (`scripts/stack/`)

Everything else in the repo tests against mocks (web Playwright mocks
Supabase, edge functions use fakes) or a vanilla-Postgres shim
(`scripts/test_db.sh`). This harness runs the product on the **real Supabase
stack** locally — the same containers the Supabase CLI runs — so platform
behaviour (real roles, GoTrue, PostgREST grants, Storage API + RLS, Realtime,
the edge runtime, pg_net) is exercised end to end. LOCAL / CI ONLY.

| Piece | What runs | Port |
|---|---|---|
| Supabase (`supabase start`) | Postgres 17, GoTrue, PostgREST, Realtime, Storage, Kong, mailpit, edge runtime | API 54321, DB 54322, mailpit 54324 |
| Migrations | `supabase db reset` — every file in `supabase/migrations`, the real migration path | |
| Local platform setup | `sql/setup_local.sql`: `set_app_base_url('http://127.0.0.1:5173')`, `pg_cron`, `pg_net` (no jobs scheduled) | |
| Stripe | [stripe-mock](https://github.com/stripe/stripe-mock) (stateless API simulator) | 12111 |
| Twilio + Resend | `provider_mock.mjs` (records every request) | 12120 |
| Edge functions | `supabase functions serve --env-file supabase/functions/.env.stack` | via 54321 |

Excluded to save disk/RAM: studio, postgres-meta, imgproxy, vector,
logflare (analytics), supavisor (pooler).

## Run it

Prerequisites: Docker, Node 22, the Supabase CLI (2.118.0 tested) and
stripe-mock (0.205.0 tested) on `PATH` — or `STACK_DOWNLOAD=1` to fetch both
from GitHub releases into `scripts/stack/.cache/bin`. `psql` is optional
(falls back to `docker exec`), except for `test_db_stack.sh`.

```bash
scripts/stack/up.sh                         # start (idempotent; re-running resets the DB)
scripts/stack/test_db_stack.sh              # SQL suite on the real DB — run FIRST, on the fresh DB
node scripts/stack/verify_stack.mjs         # platform / API / functions checks
cd web && npx playwright test -c playwright.stack.config.ts   # browser tests (no mocks)
scripts/stack/down.sh                       # stop everything (--keep-db keeps the volume)
```

`up.sh` prints the API URL and the anon/service keys, and writes:

* `scripts/stack/.state/stack.env` — `STACK_API_URL`, `STACK_ANON_KEY`,
  `STACK_SERVICE_ROLE_KEY`, `STACK_DB_URL`, mock URLs, webhook/cron secrets
  (read by `verify_stack.mjs` and `web/e2e-stack/support/stackEnv.ts`;
  `source` it in a shell).
* `supabase/functions/.env.stack` (git-ignored) — function secrets: fake
  `sk_test_`/`pk_test_`/`whsec_test_` Stripe keys, fake Twilio/Resend
  credentials, `APP_BASE_URL=http://127.0.0.1:5173`, `CRON_SECRET`,
  `FUNCTIONS_PUBLIC_URL`, and the API base overrides below.
* logs: `.state/functions.log`, `.state/stripe-mock.log`,
  `.state/provider-mock.log`, `.state/db-reset.log`.

Knobs: `STACK_SKIP_RESET=1` (keep data), `STACK_SKIP_FUNCTIONS=1`,
`STACK_DOWNLOAD=1`, `SUPABASE_BIN`, `STRIPE_MOCK_BIN`, `STACK_APP_URL`,
`STACK_EXTRA_CA_FILE` (see below).

### Provider API base overrides

`supabase/functions/_shared/api_base.ts` lets the harness point the
functions at the simulators. Unset (every hosted project) means the real
hosts. Covered by `_shared/api_base_test.ts`.

| Variable | Harness value | Default |
|---|---|---|
| `STRIPE_API_BASE` | `http://host.docker.internal:12111` | `https://api.stripe.com` |
| `TWILIO_API_BASE` | `http://host.docker.internal:12120/2010-04-01` | `https://api.twilio.com/2010-04-01` |
| `RESEND_API_BASE` | `http://host.docker.internal:12120` | `https://api.resend.com` |

The edge runtime runs in Docker, so host services are reached through
`host.docker.internal` (the CLI maps it to the host gateway).

### Provider mock (Twilio + Resend)

Records every provider call (Authorization stripped) to memory and
`.state/provider-requests.json`. Control API for tests:

* `GET /__control/requests[?service=twilio|resend][&since=<iso>]`, `DELETE /__control/requests`
* `POST /__control/twilio/numbers {phone_number, sms_url}` — a number the
  shop "owns" in Twilio (the messaging sender looks it up and requires its
  SmsUrl to be `…/messaging?action=twilio_inbound&shop_id=<shop>`)
* `POST /__control/fail {service, status, code?, message?, times?}` — make the
  next N calls fail (e.g. Twilio `21610` for an unsubscribed recipient)

### Webhooks in tests

* Stripe: sign with `STACK_STRIPE_WEBHOOK_SECRET`:
  `Stripe-Signature: t=<ts>,v1=hex(HMAC-SHA256(secret, "<ts>.<body>"))`.
  stripe-mock is stateless — it never sends events; tests post them.
* Twilio: sign with `STACK_TWILIO_AUTH_TOKEN` over
  `STACK_FUNCTIONS_URL + "/messaging?" + query` + sorted params
  (HMAC-SHA1, base64) — see `verify_stack.mjs`.
* Cron: send `x-cron-secret: $STACK_CRON_SECRET` to `process_queue`,
  `run_automations`, `sweep_payment_sheets`, `purge`.

## What `verify_stack.mjs` proves

63 checks (62 PASS + 1 KNOWN on the current tree: the Kong CORS platform
difference below), each printed with evidence (`--json out.json` saves them):
extensions (pg_cron, pg_net, vault; app extensions in `extensions`), the
realtime publication (exactly the 0044 + 0081 tables: jobs, messages,
notifications, payments, tasks, time_entries — the tables the web subscribes
to), buckets, RLS on every table, no anon table grants;
PostgREST exposure + grants of every `public_*` RPC for anon (including
`public_billing_plans`, the /pricing page) and denial of staff/service RPCs,
a not-found public RPC answering HTTP 404 `PT404` (never a 5xx); GoTrue signup (auto-confirmed), password login, refresh
rotation, profile trigger, account deletion through the GoTrue admin API
(FK `SET NULL` cascades run as `supabase_auth_admin`; owners are refused); owner shop creation, RLS inserts and tenant
isolation; Storage uploads/downloads/denials under the `job-photos` and
`shop-assets` policies, MIME allow-list, API delete vs blocked SQL delete;
Realtime `postgres_changes` under RLS (and `jobs.public_token` not leaked);
every edge function boots and returns the documented error envelope, gateway
JWT checks, cron-secret checks, Stripe signature verification, Stripe Connect
through stripe-mock, Twilio signature validation, invites delivered to the
Resend mock, and pg_net → Kong → functions (the pg_cron job path).

`known(...)` checks document platform differences / open defects (below):
they print `KNOWN` and do not fail the run unless `STACK_STRICT=1`; they print
`FIXED` once the problem is gone (then turn them into normal checks).

## SQL suite on the real database (`test_db_stack.sh`)

Installs only the `tests` helper schema (`supabase/shim/30_test_helpers.sql`)
plus `sql/test_helpers_stack.sql`, then runs every `supabase/tests/*.sql` in
`BEGIN … ROLLBACK` like `scripts/test_db.sh`. Differences it absorbs:

* GoTrue's real `auth.users.id` has **no default** — the overlay's
  `tests.create_user` passes an explicit id.
* Real Storage blocks SQL `DELETE` on `storage.objects` (`storage.protect_delete`)
  unless `storage.allow_delete_query=true`, which is what the Storage API sets
  before deleting as the caller; the runner sets it so RLS delete policies are
  still what the tests prove.
* The suite assumes a fresh deployment: each file first deletes the
  harness's `platform_config` row (rolled back), and the suite must run right
  after `up.sh` (`10_money_security.sql` counts all `stripe_events` rows).
* Per-file preludes (`sql/prelude/<file>.sql`) run inside that file's
  transaction, before it, and are rolled back with it. They are only for
  documented real-platform differences, and there are currently none:
  `00_audit_user_delete.sql` used to need one (it deleted `auth.users` rows
  as `service_role`, which has no SELECT/DELETE on `auth.users` on real
  Supabase). It now deletes as `tests.as_superuser()` and passes on the real
  stack as is. The product's real path (GoTrue admin API as
  `supabase_auth_admin`) is proven by `verify_stack.mjs`.
* Files listed in `known_sql_failures.txt` are reported `KNOWN` (not
  failures) unless `STACK_STRICT=1`, and `FIXED` once they pass. The list is
  currently empty.
* It connects as `supabase_admin` (the real superuser) by default. With
  `--as postgres` (not a superuser on Supabase) `00_shim_helpers.sql` and the
  dblink race tests fail by design (they need a superuser). It ignores
  `STACK_DB_URL` (the `postgres` URL in `stack.env`), so sourcing `stack.env`
  cannot silently switch it to a non-superuser; `STACK_SQL_DB_URL` overrides
  the full connection URL explicitly.

## Known issues / platform differences

Open **product defects** found on the real stack are kept executable so they
are noticed when fixed: `verify_stack.mjs` `known(...)` checks print `KNOWN` /
`FIXED`, and Playwright `test.fail(...)` specs are reported as expected
failures while the defect reproduces and FAIL the run ("expected to fail, but
passed") once it is fixed — then remove the marker. Nothing is
`test.skip`/`test.fixme`.

**There are no open product defects.** The three found earlier are fixed and
kept as regular checks:

* **P0002 -> HTTP 500 for unknown public links**: every `public_*` / booking
  RPC now raises `PT404` (PostgREST: HTTP 404) for an unknown token, slug or
  id; `verify_stack.mjs` checks `public_get_quote` answers 404 `PT404` and that
  no anon-callable public RPC answers 5xx. (Staff RPCs still use `P0002` for a
  record id that no longer exists, e.g. a stale link inside the app; the web
  maps the code to "not found", PostgREST logs it as a 500.)
* **Due-on-receipt invoices overdue at once**: `invoices_maintain`
  (`0012_money_invoices_payments.sql`) sets `due_at` to the END of the local
  due date (23:59:59 shop time), so a freshly issued invoice is not overdue;
  regression `web/e2e-stack/j3-money.spec.ts` J3b.
* **Empty placeholder lines in staff-sent messages**: quote / invoice sends are
  rendered by the server (`preview_document_message`, `messaging.send` with
  `quote_id` / `invoice_id`), which omits lines whose value is unavailable;
  regression J3c.

Platform differences (not product defects):
* **Local Kong masks function CORS.** The CLI's Kong has a global CORS plugin
  that answers every preflight and sets `Access-Control-Allow-Origin: *`, so
  the functions' exact-origin CORS (`_shared/cors.ts`) cannot be observed
  through the local gateway (hosted Supabase does not add this plugin).
  `verify_stack.mjs` therefore also preflights the edge runtime directly on
  the Docker network (`edge_runtime:8081`, via `docker exec` into the db
  container): the app origins get an exact `Access-Control-Allow-Origin`,
  a foreign origin gets `403 origin_not_allowed`.
* `supabase/setup/cron.sql` refuses non-https URLs, so it cannot configure a
  local stack; `sql/setup_local.sql` sets the app URL and creates the
  extensions, and `verify_stack.mjs` drives the pg_net → function path
  directly instead of scheduling jobs.

## Behind a TLS-intercepting proxy

The edge runtime downloads `npm:`/`jsr:` imports at boot. If a proxy
re-signs TLS, pass its CA with `STACK_EXTRA_CA_FILE` (defaults to `$DENO_CERT`
when set): `up.sh` copies it to `supabase/functions/.stack-ca.pem`
(git-ignored; the container only mounts `supabase/functions`) and sets
`DENO_CERT`/`SSL_CERT_FILE` for the runtime. Without it, every function
answers `503 BOOT_ERROR` and `up.sh` fails with the log tail.

## CI

`.github/workflows/e2e-stack.yml` (ubuntu-latest; manual or on pushes to
`supabase/**`, `web/**`, `scripts/stack/**`): setup-cli, stripe-mock release,
Node 22, `up.sh`, `test_db_stack.sh`, `verify_stack.mjs`, the Playwright
stack suite. No repository secrets are needed (every key is a local fake or
comes from `supabase status`). It always uploads the Playwright report,
`verify.json` (including the `KNOWN` evidence) and the harness logs, plus
every Supabase container's log on failure.
