# Deploy runbook (operator)

How to put Detail CRM into production and keep it there: the hosted Supabase
backend, the web app on Cloudflare Pages, and the iPhone app on TestFlight.
Everything is scripted and safe to re-run. The non-technical launch checklist
(accounts, DNS, App Store review) is [LAUNCH.md](LAUNCH.md); this file is the
reference for the scripts and settings.

| Piece | Script / workflow | What it touches |
|---|---|---|
| Backend | `scripts/deploy/deploy_backend.sh` · `.github/workflows/deploy-backend.yml` | Supabase: migrations, edge functions, function secrets, Auth, pg_cron/Vault; optionally the Stripe Connect webhook endpoint |
| Backend smoke checks | `scripts/deploy/verify_live.mjs` (run by deploy-backend) | read-only calls against the live project |
| Web | `scripts/deploy/web_headers.mjs` · `.github/workflows/deploy-web.yml` | Cloudflare Pages project |
| Web header check | `scripts/deploy/verify_web.mjs` (run by deploy-web) | read-only |
| CSP proof | `scripts/deploy/csp_proof.mjs` | local only (build + Chromium) |
| iPhone | `ios/fastlane/Fastfile` · `.github/workflows/ios-testflight.yml` | App Store Connect / TestFlight |

## 1. Order

First launch (each step can be re-run on its own later):

1. Accounts, domains and DNS ready ([LAUNCH.md](LAUNCH.md) sections 1-3).
2. GitHub settings filled in ([section 2](#2-settings-reference)).
3. **deploy-backend** with `dry_run` = true. Read the plan: pending
   migrations, which secrets would be created, the Auth changes, the cron jobs.
4. **deploy-backend** with `dry_run` = false and `stripe_webhooks` = true
   (creates the Stripe Connect endpoint and stores its signing secret). The
   job ends with `verify_live.mjs`; it must print `0 failed`.
5. **deploy-web** (manual dispatch). It checks, builds, generates the security
   headers, uploads to Cloudflare Pages and checks the served headers.
   Attach the custom domain (`app.yourdomain.com`) to the Pages project once.
6. **ios-testflight** (manual dispatch or push a change to
   `.github/trigger-testflight`).
7. Per shop that wants texting: Twilio number + A2P registration
   ([`supabase/setup/twilio.md`](../supabase/setup/twilio.md)).

Later releases: backend and web deploys are independent. Deploy the backend
first when a web/iOS change needs a new migration or function.

## 2. Settings reference

Put these in **Settings -> Secrets and variables -> Actions** of the GitHub
repository, either at repository level or in an environment named
`production` (all three workflows run in that environment, so you can add
required reviewers there). *Secret* = encrypted, never shown again;
*variable* = plain text (only for values that are public anyway). Every
workflow's first step lists whatever is missing.

### Backend (deploy-backend)

| Name | Kind | Required | Where to get it |
|---|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | secret | yes | supabase.com -> Account -> [Access Tokens](https://supabase.com/dashboard/account/tokens) (personal token of an owner of the project) |
| `SUPABASE_PROJECT_REF` | variable | yes | Project Settings -> General -> Reference ID (20 lowercase letters) |
| `SUPABASE_DB_PASSWORD` | secret | yes | chosen when the project was created (Project Settings -> Database to reset it) |
| `APP_BASE_URL` | variable | yes | the web app origin, e.g. `https://app.yourdomain.com` (https, no trailing path needed) |
| `CRON_SECRET` | secret | yes | generate once: `openssl rand -hex 32` (at least 24 characters, no quotes/spaces) |
| `STRIPE_SECRET_KEY` | secret | yes | Stripe Dashboard -> Developers -> API keys, **platform** account (`sk_live_...`; `sk_test_...` for a staging project) |
| `STRIPE_PUBLISHABLE_KEY` | variable | yes | same page (`pk_live_...`), same mode as the secret key |
| `STRIPE_WEBHOOK_SECRET` | secret | unless `stripe_webhooks` | signing secret of the Connect endpoint; with `stripe_webhooks` the deploy creates the endpoint and stores it for you |
| `PLATFORM_FEE_BPS` | variable | no | your platform fee on card payments in basis points (100 = 1%); unset = 0 |
| `TWILIO_ACCOUNT_SID` | secret | yes | Twilio Console -> Account info (`AC...`) |
| `TWILIO_AUTH_TOKEN` | secret | yes | Twilio Console -> Account info |
| `RESEND_API_KEY` | secret | yes | Resend -> API Keys (`re_...`, sending access). Also used as the Auth SMTP password |
| `EMAIL_FROM` | variable | yes | `Detail CRM <notifications@yourdomain.com>` on a domain verified in Resend |
| `CORS_ALLOWED_ORIGINS` | variable | no | extra browser origins, comma-separated bare origins (a staging web app) |
| `SUPABASE_ANON_KEY` | variable | no | Project Settings -> API (anon / publishable). Used by verify_live; fetched with the access token when unset |
| `REQUIRE_LIVE_STRIPE` | variable | no | `1` = refuse to deploy with test-mode Stripe keys |
| `AUTH_SMTP_SENDER_EMAIL` / `AUTH_SMTP_SENDER_NAME` | variable | no | sender of Auth emails; default: the address and name in `EMAIL_FROM` |
| `AUTH_ADDITIONAL_REDIRECT_URLS` | variable | no | extra allowed Auth redirect URLs, comma-separated (e.g. `https://staging.yourdomain.com/**`) |
| `AUTH_RATE_LIMIT_EMAIL_SENT` | variable | no | Auth emails per hour, project-wide (default 100) |
| `AUTH_PASSWORD_MIN_LENGTH` | variable | no | default 8 = the apps' own rule; 8-72 |
| `AUTH_PASSWORD_HIBP` | variable | no | `1` = reject leaked passwords (a paid-plan Auth feature) |

Never set: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` as
*function* secrets (Supabase injects them), and `STRIPE_API_BASE`,
`TWILIO_API_BASE`, `RESEND_API_BASE` (local test harness only: the deploy
removes them from the project if it finds them).

### Web (deploy-web)

| Name | Kind | Required | Where to get it |
|---|---|---|---|
| `SUPABASE_URL` | variable | yes | `https://<ref>.supabase.co` (becomes `VITE_SUPABASE_URL`) |
| `SUPABASE_ANON_KEY` | variable | yes | Project Settings -> API, anon/publishable key (becomes `VITE_SUPABASE_ANON_KEY`; it ships to every browser, it is not a secret) |
| `CLOUDFLARE_API_TOKEN` | secret | yes (not for dry runs) | Cloudflare -> My Profile -> API Tokens -> Create token, permission **Account -> Cloudflare Pages -> Edit** |
| `CLOUDFLARE_ACCOUNT_ID` | variable or secret | yes (not for dry runs) | Cloudflare dashboard -> Workers & Pages -> Account ID |
| `CLOUDFLARE_PAGES_PROJECT` | variable | yes (not for dry runs) | the Pages project name (created on the first deploy if missing) |
| `DEPLOY_WEB` | variable | no | `true` = also deploy on every push to `main` that touches `web/` |
| `WEB_EMBED_PATHS` | variable | no | comma-separated paths other sites may iframe, e.g. `/book/*` (default: none; see [4.3](#43-framing-embeds)) |
| `WEB_EMBED_ANCESTORS` | variable | no | who may frame those paths (default `*`) |

### iPhone (ios-testflight)

| Name | Kind | Required | Where to get it |
|---|---|---|---|
| `ASC_KEY_ID` | secret | yes | App Store Connect -> Users and Access -> Integrations -> App Store Connect API -> Team Keys (role **Admin**: Xcode creates the cloud-managed signing certificate and profiles with it) |
| `ASC_ISSUER_ID` | secret | yes | same page, "Issuer ID" |
| `ASC_KEY_P8` | secret | yes | the downloaded `AuthKey_<id>.p8` (downloadable once). Paste the file content, or its base64 (`base64 -i AuthKey_X.p8`); both work |
| `APPLE_TEAM_ID` | secret | yes | developer.apple.com -> Account -> Membership details -> Team ID (10 characters) |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `APP_BASE_URL` | variables | yes | shared with the web settings above |
| `IOS_BUNDLE_ID` | variable | no | default `com.detailcrm.app` |

## 3. Backend: `deploy_backend.sh`

```bash
# locally (Node 20+, bash, git; the Supabase CLI is used from PATH or via npx, pinned 2.118.0)
export SUPABASE_ACCESS_TOKEN=... SUPABASE_PROJECT_REF=... SUPABASE_DB_PASSWORD=...
export APP_BASE_URL=https://app.yourdomain.com CRON_SECRET=... STRIPE_SECRET_KEY=... # etc. (section 2)
scripts/deploy/deploy_backend.sh --dry-run                     # plan only
scripts/deploy/deploy_backend.sh --stripe-webhooks            # first deploy
scripts/deploy/deploy_backend.sh                              # later deploys
node scripts/deploy/verify_live.mjs                           # smoke checks
```

Flags: `--dry-run`, `--stripe-webhooks`, `--include-all` (see 3.2),
`--allow-dirty` (deploy although `supabase/` has uncommitted changes; the
default refuses). Inputs come only from environment variables: values are
never printed, never passed on a command line and never written to a file in
the repository (the helper masks every known secret in its output).

The nine steps, in order:

1. **Validate inputs** - every required name, with the same format rules as
   the functions (`supabase/functions/_shared/env.ts`): Stripe key prefixes
   and matching test/live mode, `whsec_`, `AC` + 32 hex, `re_`,
   `EMAIL_FROM` shape, https `APP_BASE_URL`, `CRON_SECRET` length. Missing
   or invalid inputs stop the run before anything is contacted, with the list
   and where each value comes from. Test-mode Stripe keys only warn (unless
   `REQUIRE_LIVE_STRIPE=1`).
2. **Project and CLI** - Management API project lookup; a snapshot of
   `supabase/config.toml`, `migrations/`, `functions/` (dot files excluded)
   and `setup/cron.sql` into a temporary directory that is deleted at exit, so
   a concurrent edit of the working tree cannot mix versions mid-deploy.
3. **Link** - `supabase link --project-ref` (password from
   `SUPABASE_DB_PASSWORD` in the environment).
4. **Migrations** - `supabase db push --dry-run` (always printed), then the
   real push. Skipped in a dry run.
5. **Function secrets** - Management API `POST /v1/projects/{ref}/secrets`
   with only the names from `supabase/functions/README.md`. Unchanged values
   (compared by SHA-256 digest) are not re-sent.
6. **Stripe Connect webhook** (only with `--stripe-webhooks`) - see 3.3.
7. **Edge functions** - one `supabase functions deploy <name> --use-api`
   per `[functions.<name>]` in `config.toml`, with `--no-verify-jwt` exactly
   where `verify_jwt = false` (`payments`, `stripe-webhook`, `messaging`,
   `storage-purge`: Stripe, Twilio and pg_cron send no Supabase JWT);
   `stripe-connect` and `invites` keep the gateway JWT check. Afterwards the
   deployed list is read back and every function's `verify_jwt` must match.
   `SUPABASE_FUNCTIONS_BUNDLER=docker` bundles locally with Docker instead of
   `--use-api`.
8. **Production Auth** - Management API `PATCH /v1/projects/{ref}/config/auth`
   (3.4), then read back.
9. **Platform setup** - `supabase/setup/cron.sql` rendered in memory with the
   real values and executed through the Management API (3.5), then checked.

### 3.1 `config.toml` is never pushed

`supabase/config.toml` is tuned for **local** journeys (email confirmations
off, `site_url` `http://127.0.0.1:5173`, loose local rate limits). The deploy
**never runs `supabase config push`** or anything else that syncs
`config.toml` to the hosted project: every CLI call goes through a guard that
refuses `config`, `db reset`, `db pull`, `secrets` and `branches` commands,
and the test suite asserts `config push` is never invoked. Production Auth is
set only through the Management API with email confirmations **ON** (3.4).
Do not run `supabase config push` by hand against production either.

### 3.2 Migrations

- `db push` applies every file in `supabase/migrations` that the project has
  not recorded yet, in file-name order, and refuses to run when a pending
  file is numbered **below** one already applied. SPEC section 9 gives each
  domain its own number range, so this happens when, say, `0055_...` lands
  after `0090_...` is live. Check that the out-of-order migration does not
  depend on anything applied later, then run with `--include-all`
  (`include_all_migrations` in the workflow).
- Migrations are forward-only. There are no down-migrations: fix forward with
  a new migration, or restore the database (section 7).

### 3.3 Stripe webhook endpoint

With `--stripe-webhooks` the deploy manages **one Connect endpoint**
("Events on Connected accounts") at
`https://<ref>.supabase.co/functions/v1/stripe-webhook`, with exactly the
events in `HANDLED_EVENT_TYPES` (`supabase/functions/stripe-webhook/handlers.ts`,
read at deploy time) and the API version `STRIPE_API_VERSION`
(`_shared/stripe.ts`). It is tagged with the metadata
`detail_crm_role=connect`.

- New endpoint: Stripe returns its signing secret once; it is stored straight
  away as the function secret `STRIPE_WEBHOOK_SECRET` (never printed).
- Existing tagged endpoint: events are updated and the endpoint re-enabled;
  the stored secret is kept. If `STRIPE_WEBHOOK_SECRET` is not stored, the run
  stops: Stripe cannot reveal an existing secret, so copy it from the
  Dashboard or re-run with `STRIPE_WEBHOOK_RECREATE=1`.
- An endpoint at the same URL that the deploy did not create (for example one
  made by hand from the functions README) is never modified: delete it, or set
  `STRIPE_WEBHOOK_ADOPT=we_...` if it is the Connect endpoint whose secret is
  `STRIPE_WEBHOOK_SECRET`.
- `STRIPE_WEBHOOK_RECREATE=1` deletes and recreates the endpoint (new signing
  secret stored automatically). Needed after an SDK / `STRIPE_API_VERSION`
  upgrade, because Stripe cannot change an endpoint's API version.
- **No platform (non-Connect) endpoint is created.** Every handler acts only on
  events of a connected account (`event.account`): charges are direct charges
  on the shop's Express account. The function also verifies a single signing
  secret, so a second endpoint (different secret) would fail signature checks
  on every delivery and Stripe would eventually disable it.

### 3.4 Auth settings applied

| Setting | Value |
|---|---|
| `site_url` | `APP_BASE_URL` |
| redirect allow-list | `APP_BASE_URL/**`, `/reset-password`, `/invite/**`, `/portal`, `/app/**`, `/login` (+ `AUTH_ADDITIONAL_REDIRECT_URLS`). The iPhone app has no URL scheme: its password-reset links open the web app's `/reset-password` |
| email sign-up | on; phone and anonymous sign-in off |
| email confirmations | **on** (`mailer_autoconfirm = false`): `portal_claim_customers()` links portal users by *confirmed* email |
| secure email change, reauthentication for password change | on |
| refresh-token rotation / reuse interval / JWT expiry | on / 10 s / 3600 s |
| minimum password length | 8 (`AUTH_PASSWORD_MIN_LENGTH`), the same rule as the web and iOS forms |
| SMTP | `smtp.resend.com:465`, user `resend`, password `RESEND_API_KEY`, sender from `EMAIL_FROM` |
| email rate limit | `AUTH_RATE_LIMIT_EMAIL_SENT` per hour (default 100) |
| minimum interval between emails to one user | 60 s |

Email templates are left at their current values (edit them in the Dashboard
if you want your own wording).

### 3.5 Platform setup (cron.sql)

`supabase/setup/cron.sql` is the one-time SQL that stores `APP_BASE_URL` in
`platform_config` (every customer link in messages is built from it) and
schedules the five pg_cron jobs (queue, automations, quote expiry, payment
sheet sweep, storage purge) with the functions URL and `CRON_SECRET` kept in
Vault. The deploy replaces exactly the three assignments the file asks you to
edit (`v_functions_url`, `v_cron_secret`, `v_app_base_url`), in memory, and
sends the result over HTTPS to the Management API; no edited copy is written
anywhere. It then checks `platform_config.app_base_url`, the five active jobs
and the two Vault entries.

Dependency: this matches cron.sql's **current** placeholder format. If that
file changes how it is parameterized, the deploy stops with
"placeholder format changed" (it never guesses); update `CRON_ASSIGNMENTS` in
`scripts/deploy/lib/config.mjs` together with the file.

Rotating `CRON_SECRET`: set the new value and re-run the deploy. Steps 5 and 9
update the function secret and Vault in the same run; cron calls in between
(at most a minute or two) get 401 and simply run again on the next tick.

### 3.6 Smoke checks: `verify_live.mjs`

Read-only (only denied, unauthenticated or malformed requests and GETs), so
it is safe against production at any time:

```bash
APP_BASE_URL=https://app.yourdomain.com SUPABASE_PROJECT_REF=<ref> \
SUPABASE_ANON_KEY=<anon> [SUPABASE_ACCESS_TOKEN=<token>] [SUPABASE_SERVICE_ROLE_KEY=<key>] \
node scripts/deploy/verify_live.mjs [--strict] [--json report.json]
```

It checks: PostgREST answers; anon cannot read tenant tables; every public
RPC is exposed to anon while staff/service RPCs are not; malformed tokens are
400; Auth settings (email on, confirmations on, anonymous/phone off) and
`site_url` / redirect allow-list (Management API, or inferred from GoTrue's
redirects with only the anon key); every function answers with its
documented error envelope and no 5xx, with the gateway JWT check exactly
where `config.toml` says; missing secrets show up as specific failures
(`CRON_SECRET`, Stripe keys + webhook secret, Twilio, `APP_BASE_URL` via the
unsubscribe redirect); CORS allows exactly `APP_BASE_URL`'s origin;
`job-photos` / `signatures` are private and `shop-assets` public; Realtime
accepts the anon key; with the access token also the deployed `verify_jwt`
values, `platform_config.app_base_url` and the cron jobs.

`KNOWN` lines are documented open defects (currently: an unknown public token
answers HTTP 500 `P0002`, see `scripts/stack/README.md`); they do not fail the
run unless `--strict`. Exit code 1 on any `FAIL`.

### 3.7 Tests of the deploy tooling

`node --test "scripts/deploy/test/*.test.mjs"` (the backend workflow runs it
first). It drives `deploy_backend.sh` end to end against a fake Supabase CLI
and a fake Management + Stripe API: command order, verify_jwt flags, dry run
without mutations, missing/invalid inputs, no secret in output or argv,
idempotent re-runs, `config push` never invoked, a foreign Stripe endpoint
left alone. It also covers `verify_live.mjs` against a fake project with each
deploy mistake injected, and the header generator.

## 4. Web: Cloudflare Pages

The web app is a static single-page app (Vite build, React Router
`BrowserRouter`); Stripe Checkout and Connect onboarding are full-page
redirects (no Stripe.js).

```bash
cd web && npm ci && VITE_SUPABASE_URL=https://<ref>.supabase.co VITE_SUPABASE_ANON_KEY=<anon> npx vite build
cd .. && VITE_SUPABASE_URL=https://<ref>.supabase.co node scripts/deploy/web_headers.mjs --dist web/dist
npx wrangler@4.142.0 pages deploy web/dist --project-name <project> --branch main
node scripts/deploy/verify_web.mjs https://<deployment>.pages.dev --dist web/dist
```

`web_headers.mjs` writes `dist/_headers` and `dist/_redirects` **after** the
build (the inline-script hash depends on the built `index.html`):

| Path | Headers |
|---|---|
| `/*` | CSP (below) with `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `Strict-Transport-Security: max-age=31536000; includeSubDomains`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` (camera, microphone, geolocation, payment, USB, serial, MIDI, sensors, display capture off), `Cross-Origin-Opener-Policy: same-origin`, `Cache-Control: no-cache` |
| `/assets/*` | `Cache-Control: public, max-age=31536000, immutable` (Vite content-hashed files) |
| `WEB_EMBED_PATHS` | same CSP but `frame-ancestors WEB_EMBED_ANCESTORS`, no `X-Frame-Options` |

SPA fallback: Cloudflare Pages serves `index.html` (200) for every unknown
path as long as the build has no top-level `404.html` (the generator refuses
one). A `/* /index.html 200` redirect rule is deliberately not written: Pages
ignores it as an infinite loop.

### 4.1 Content-Security-Policy

Exactly what the app loads (audited from `web/src` and `web/index.html`):

```
default-src 'self'; script-src 'self' 'sha256-<theme snippet>';
style-src 'self' https://fonts.googleapis.com 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=';
font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: blob: https://<ref>.supabase.co;
connect-src 'self' https://<ref>.supabase.co wss://<ref>.supabase.co https://vpic.nhtsa.dot.gov;
frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'; manifest-src 'self';
frame-ancestors 'none'
```

- The only inline script is the pre-paint theme snippet in `index.html`,
  allowed by its hash. No `'unsafe-inline'`, no `'unsafe-eval'`.
- The empty-string style hash allows only **empty** inline `<style>` elements:
  FullCalendar creates one and fills it through CSSOM, which CSP does not
  govern. Its icon font is a `data:` URI (hence `font-src data:`).
- Supabase: REST, Auth, Functions and Storage over https, Realtime over wss,
  Storage images (public and signed URLs).
- NHTSA vPIC: VIN decoding in the job and customer forms.
- Google Fonts (Inter) from `index.html`.
- Stripe Checkout / Connect onboarding and Google Maps links are top-level
  navigations, which CSP does not restrict.
- A unit test fails when `web/src` starts referencing a new external origin;
  add it to `KNOWN_EXTERNAL` and `buildCsp` in `web_headers.mjs`.

### 4.2 Proof that the CSP does not break the app

```bash
node scripts/deploy/csp_proof.mjs --out /tmp/csp-proof [--strict]
```

Builds `web/` into the given directory (never `web/dist`), generates the
headers, serves the build with Cloudflare Pages semantics
(`scripts/deploy/lib/static_server.mjs`, mirroring the Pages `_headers`
engine: rules in file order, repeated headers joined with `, `, `! Name`
detaches) and opens login, public booking, dashboard, calendar and reports in
Chromium against a mocked Supabase. It asserts the CSP header is served, zero
`securitypolicyviolation` events, no CSP console errors, no page errors, no
request to an unknown origin; negative controls prove a forbidden fetch,
inline script and image are reported; framing works as configured.

One finding is reported as `KNOWN` (a failure with `--strict`): zod 4 probes
`new Function` once, the CSP blocks it and zod falls back to its interpreter,
so the app works but a violation is reported. The fix (verified with
`--strict` on a copy of `web/`): a module `web/src/zodConfig.ts` that calls
`z.config({ jitless: true })`, imported as the first line of
`web/src/main.tsx`.

### 4.3 Framing (embeds)

Nothing is frameable by default: neither SPEC nor `web/src` has an embed
route yet ("booking embed" is on the SPEC section 9 roadmap). When it ships,
set `WEB_EMBED_PATHS` (e.g. `/book/*`) and optionally `WEB_EMBED_ANCESTORS`.
The generator refuses paths that would expose staff pages (`/app`, `/*`).

### 4.4 Custom domain

Cloudflare -> Workers & Pages -> the project -> Custom domains -> add
`app.yourdomain.com` ([docs](https://developers.cloudflare.com/pages/configuration/custom-domains/)).
`APP_BASE_URL` must be exactly that origin; re-run the backend deploy after
changing it (function secret, Auth `site_url`, `platform_config`).

### 4.5 Other static hosts

The build is plain static files; any host works if it can (1) send the
headers above per path, (2) serve `index.html` for unknown paths with status
200, and (3) cache `/assets/*` long and `index.html` not at all.

- **Netlify**: same `_headers` syntax, but check how it combines headers from
  several matching rules before relying on `! Name`; generate the SPA rule with
  `--host netlify` (`/* /index.html 200`).
- **nginx / S3 + CloudFront / others**: copy the values from the generated
  `_headers` (they are plain header values) into the host's config;
  `try_files $uri /index.html;` (nginx) or a 404 -> `/index.html` (200)
  error document (CloudFront) for the SPA fallback.

After any host change run `verify_web.mjs` against it.

## 5. iPhone: TestFlight

Prerequisites (once, [LAUNCH.md](LAUNCH.md) section 2.6): Apple Developer
Program membership, the bundle id `com.detailcrm.app` (or `IOS_BUNDLE_ID`)
registered, an App Store Connect app record with that bundle id, and a team
API key with the Admin role.

The workflow (macOS 15, the same Xcode choice as `ios.yml`) runs
`scripts/swift_sanity.py`, writes the API key to a private temp file, then
`bundle exec fastlane ios beta`:

1. API key session (`app_store_connect_api_key`); build number = latest
   TestFlight build number + 1 (`latest_testflight_build_number`, or
   `BUILD_NUMBER` to force one).
2. `Config.plist` gets `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `WEB_APP_URL`
   (= `APP_BASE_URL`) for this build (`AppConfig.swift` reads that file); the
   committed placeholders are restored afterwards. The app bundles no Stripe
   key: the `payments` function returns the publishable key per payment.
3. `xcodebuild archive` with `-allowProvisioningUpdates` and the API key
   (`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`):
   Xcode automatic signing with cloud-managed certificates.
   `DEVELOPMENT_TEAM` and `CURRENT_PROJECT_VERSION` are build-setting
   overrides; the project file is not edited. A non-default `IOS_BUNDLE_ID` is
   applied to the app target only for the build and restored (a command-line
   `PRODUCT_BUNDLE_IDENTIFIER` would also rename the Swift packages' resource
   bundles, which App Store Connect rejects as duplicates).
4. `xcodebuild -exportArchive` (method `app-store-connect`, automatic
   signing), then `upload_to_testflight` without waiting for processing.
5. Artifacts: `DetailCRM.ipa`, `DetailCRM.app.dSYM.zip`, the build number, and
   the xcodebuild logs.

`ITSAppUsesNonExemptEncryption = NO` is already set, so builds need no export
compliance answer. Local run on a Mac: `cd ios && bundle install &&
ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/AuthKey_X.p8 APPLE_TEAM_ID=...
SUPABASE_URL=... SUPABASE_ANON_KEY=... WEB_APP_URL=... bundle exec fastlane beta`
(`SKIP_UPLOAD=1` to only build). Output goes to `ios/build/`.

## 6. Re-running

Every step converges on the desired state: migrations only apply what is
pending, unchanged secrets are skipped, the Stripe endpoint is found by its tag
and updated, Auth is patched to the same values, `cron.sql` unschedules before
scheduling. Functions are redeployed each time (a new version with the same
code). A failed run can simply be run again after fixing the cause.

## 7. Rollback

- **Database**: forward-only. Restore from a backup or, with the PITR add-on,
  to a point in time (Dashboard -> Database -> Backups;
  [docs](https://supabase.com/docs/guides/platform/backups)). Restoring
  rewinds all data, so prefer a fix-forward migration when possible.
- **Edge functions**: redeploy the previous code, e.g.
  `git worktree add /tmp/prev <good-sha>` then, from `/tmp/prev`,
  `supabase functions deploy <name> --project-ref <ref> --use-api`
  (add `--no-verify-jwt` for `payments`, `stripe-webhook`, `messaging`,
  `storage-purge`). Do not run the full deploy from an older commit: `db push`
  refuses because the database has newer migrations than that commit.
- **Secrets**: re-run the deploy with the previous values.
- **Web**: Cloudflare -> the Pages project -> Deployments -> an earlier
  production deployment -> Rollback
  ([docs](https://developers.cloudflare.com/pages/configuration/rollbacks/)).
- **iPhone**: TestFlight builds cannot be replaced; expire the bad build in
  App Store Connect and ship a new one.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Missing required inputs` | add the listed names (section 2) |
| `HTTP 401 (SUPABASE_ACCESS_TOKEN is invalid or expired)` | create a new personal access token |
| `link` / `db push` fails on the password | `SUPABASE_DB_PASSWORD` is wrong; reset it in Project Settings -> Database |
| `db push`: migrations "to be inserted before the last migration on remote" | an out-of-order migration (3.2), run with `include_all_migrations` |
| `endpoint ... exists but STRIPE_WEBHOOK_SECRET is not stored` | 3.3 |
| `cron.sql: ... placeholder format changed` | 3.5 |
| verify_live `server_misconfigured` | a function secret is missing or malformed; the function logs name the variable |
| verify_live `deployed with verify_jwt=true` on a webhook function | redeploy it with `--no-verify-jwt` (the deploy does this from `config.toml`) |
| Browser console: `Refused to ... Content Security Policy` | a new external origin in `web/src`: 4.1 |
| Stripe Dashboard shows webhook failures with 400 | the endpoint's signing secret differs from `STRIPE_WEBHOOK_SECRET`: `STRIPE_WEBHOOK_RECREATE=1` |
| fastlane: `Could not read TestFlight builds` | the App Store Connect app record for the bundle id is missing, or the key's role is too low |
