# Deploy runbook (operator)

How to put Detail CRM into production and keep it there: the hosted Supabase
backend, the web app on Cloudflare Pages, and the iPhone app on TestFlight.
Everything is scripted and safe to re-run. The non-technical launch checklist
(accounts, DNS, App Store review) is [LAUNCH.md](LAUNCH.md); this file is the
reference for the scripts and settings.

| Piece | Script / workflow | What it touches |
|---|---|---|
| Backend | `scripts/deploy/deploy_backend.sh` · `.github/workflows/deploy-backend.yml` | Supabase: migrations, edge functions, function secrets, Auth, pg_cron/Vault, shop billing settings; optionally the Stripe webhook endpoints (Connect; platform billing) |
| Backend smoke checks | `scripts/deploy/verify_live.mjs` (run by deploy-backend) | read-only calls against the live project |
| Web | `scripts/deploy/web_headers.mjs` · `.github/workflows/deploy-web.yml` | Cloudflare Pages project |
| Web header check | `scripts/deploy/verify_web.mjs` (run by deploy-web) | read-only |
| CSP proof | `scripts/deploy/csp_proof.mjs` | local only (build + Chromium) |
| iPhone | `ios/fastlane/Fastfile` · `.github/workflows/ios-testflight.yml` | App Store Connect / TestFlight |

## 1. Order

First launch (each step can be re-run on its own later):

1. Accounts, domains and DNS ready ([LAUNCH.md](LAUNCH.md) sections 1-3).
2. GitHub settings filled in ([section 2](#2-settings-reference)).
3. **deploy-backend** with `dry_run` = true and `stripe_webhooks` = true
   (a new project holds no webhook secret yet, so a run without it stops in
   step 2). Read the plan: pending migrations, which secrets would be
   created, the Stripe endpoint it would create, the Auth changes, the cron
   jobs.
4. **deploy-backend** with `dry_run` = false and `stripe_webhooks` = true
   (creates the Stripe Connect endpoint and stores its signing secret in the
   project; later deploys keep it). The job ends with `verify_live.mjs`; it
   must print `0 failed`.
5. **deploy-web** (manual dispatch). It checks, builds, generates the security
   headers, uploads to Cloudflare Pages and checks the served headers.
   Attach the custom domain (`app.yourdomain.com`) to the Pages project once.
6. **ios-testflight** (manual dispatch or push a change to
   `.github/trigger-testflight`).
7. Per shop that wants texting: Twilio number + A2P registration
   ([`supabase/setup/twilio.md`](../supabase/setup/twilio.md)).
8. When you are ready to charge shops a subscription: [BILLING.md](BILLING.md)
   (plans in Stripe, Customer Portal, then `BILLING_ENABLED` and a deploy
   with `stripe_webhooks`). Billing stays off until then.

Later releases: backend and web deploys are independent. Deploy the backend
first when a web/iOS change needs a new migration or function. A backend
release is a plain run (`dry_run` first, then without it): `stripe_webhooks`
is needed again only to create an endpoint (first launch, billing turned on)
or together with the recreate / adopt inputs (3.3). A new iPhone build for
the App Store needs a higher app version once the current one is approved
(section 5, "Versions").

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
| `STRIPE_WEBHOOK_SECRET` | secret | no (see the note below) | signing secret of the Connect endpoint. Leave it unset when the deploy manages the endpoint: the first deploy with `stripe_webhooks` creates it and stores the secret in the project, and later deploys keep that stored secret. Set it only for an endpoint you made by hand |
| `BILLING_ENABLED` | variable | no | `true` turns on shop subscription billing ([BILLING.md](BILLING.md)); `false` or unset = off (every shop fully usable). A database setting, applied in step 9 |
| `BILLING_TRIAL_DAYS` | variable | no | free trial for shops in whole days, `0`-`730`; unset = `0`. Applied with `BILLING_ENABLED` |
| `STRIPE_BILLING_WEBHOOK_SECRET` | secret | no (see the note below) | signing secret of the **platform** billing endpoint (`billing-webhook`), used while `BILLING_ENABLED=true`. Like `STRIPE_WEBHOOK_SECRET`: the first deploy with billing on and `stripe_webhooks` creates the endpoint and stores it; set it only for an endpoint you made by hand |
| `BILLING_AUTOMATIC_TAX` | variable | no | `true` = Stripe Tax on shop subscription Checkout, once Stripe Tax is set up on the platform account ([BILLING.md](BILLING.md) section 9); unset = off |
| `PLATFORM_FEE_BPS` | variable | no | your platform fee on card payments in basis points (100 = 1%); unset = 0 |
| `TWILIO_ACCOUNT_SID` | secret | yes | Twilio Console -> Account info (`AC...`) |
| `TWILIO_AUTH_TOKEN` | secret | yes | Twilio Console -> Account info |
| `RESEND_API_KEY` | secret | yes | Resend -> API Keys (`re_...`, sending access). Also used as the Auth SMTP password |
| `EMAIL_FROM` | variable | yes | `Detail CRM <notifications@yourdomain.com>` on a domain verified in Resend |
| `CORS_ALLOWED_ORIGINS` | variable | no | extra browser origins, comma-separated bare origins (a staging web app) |
| `FUNCTIONS_PUBLIC_URL` | variable | no | leave unset. Only with a custom API domain: `https://<host>/functions/v1`; the Stripe webhook endpoints, pg_cron and the Twilio callback URLs then use it |
| `APNS_KEY_ID` | variable | no (push) | developer.apple.com -> Certificates, Identifiers & Profiles -> Keys -> an **Apple Push Notifications service (APNs)** key: its 10-character Key ID. Set all four `APNS_*` values or none (the deploy preflight refuses a partial set, which would make every push run fail); without them the iPhone app gets no push notifications (the in-app list still works) |
| `APNS_TEAM_ID` | variable | no (push) | developer.apple.com -> Account -> Membership details -> Team ID |
| `APNS_PRIVATE_KEY` | secret | no (push) | the contents of the downloaded `AuthKey_<id>.p8` (downloadable once); line breaks may be written as `\n` |
| `APNS_TOPIC` | variable | no (push) | the iPhone app's bundle id. The App ID needs the **Push Notifications** capability |
| `SMS_PROVISIONING_ENABLED` | variable | no | `true` turns on self-serve text numbers (search, buy, toll-free verification) once the platform Twilio account can buy numbers and submit toll-free verifications; unset = off, support connects numbers by hand |
| `TWILIO_ISV_ENABLED` | variable | no | `true` also offers local-number (A2P 10DLC) registration; only once the platform Twilio account is an approved ISV |
| `TWILIO_PRIMARY_CUSTOMER_PROFILE_SID` | variable | with `TWILIO_ISV_ENABLED` | Twilio Console -> Trust Hub -> the platform's approved primary customer profile (`BU...`). The deploy preflight refuses `TWILIO_ISV_ENABLED=true` without it |
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

**Optional values are the desired state, removal included.** Every deploy
sends the optional values that are set and **removes** from the project each
optional function secret that is not set: `PLATFORM_FEE_BPS`,
`BILLING_AUTOMATIC_TAX`, `SMS_PROVISIONING_ENABLED`, `TWILIO_ISV_ENABLED`,
`TWILIO_PRIMARY_CUSTOMER_PROFILE_SID`, `CORS_ALLOWED_ORIGINS`,
`FUNCTIONS_PUBLIC_URL` and the four `APNS_*`. So deleting the GitHub
variable switches the feature off at the next deploy ("unset = off", or no
fee); `0` or `false` work too and are stored as values. The step prints each
one as `remove <NAME>` with a `WARN` line, and the dry run shows it first. A
**local** run must export every optional value you use, or it removes them:
run it with `--dry-run` first.

**Webhook signing secrets** are the exception: when `STRIPE_WEBHOOK_SECRET`
(or, with billing on, `STRIPE_BILLING_WEBHOOK_SECRET`) is not an input, the
project keeps the secret it holds. A deploy without `stripe_webhooks` checks
in step 2 that the project holds it and stops, before anything changes, when
it does not (a new project: run once with `stripe_webhooks`). After the
deploy created or recreated an endpoint, do not keep an older value of that
secret in GitHub: the next deploy would send the old value back and Stripe's
deliveries would fail with 400 (the deploy warns when it replaces a value
from the inputs).

### Web (deploy-web)

| Name | Kind | Required | Where to get it |
|---|---|---|---|
| `SUPABASE_URL` | variable | yes | `https://<ref>.supabase.co` (becomes `VITE_SUPABASE_URL`) |
| `SUPABASE_ANON_KEY` | variable | yes | Project Settings -> API, anon/publishable key (becomes `VITE_SUPABASE_ANON_KEY`; it ships to every browser, it is not a secret) |
| `CLOUDFLARE_API_TOKEN` | secret | yes (not for dry runs) | Cloudflare -> My Profile -> API Tokens -> Create token, permission **Account -> Cloudflare Pages -> Edit** |
| `CLOUDFLARE_ACCOUNT_ID` | variable or secret | yes (not for dry runs) | Cloudflare dashboard -> Workers & Pages -> Account ID |
| `CLOUDFLARE_PAGES_PROJECT` | variable | yes (not for dry runs) | the Pages project name (created on the first deploy if missing) |
| `DEPLOY_WEB` | variable | no | `true` = also deploy on every push to `main` that touches `web/` |
| `WEB_EMBED_PATHS` | variable | no | comma-separated paths other sites may iframe: `/book/*,/lead/*` for the booking and lead-form embeds (default: none; see [4.3](#43-framing-embeds)) |
| `WEB_EMBED_ANCESTORS` | variable | no | who may frame those paths (default `*`) |
| `WEB_TRACKING_PATHS` | variable | no | `/book/*,/booking/*` lets shops' own Meta Pixel / GA4 tags load on the public booking pages (default: none, the tags are blocked; see [4.3](#43-framing-embeds)) |
| `LEGAL_ENTITY_NAME` | variable | no (recommended) | your legal company name, shown on `/privacy` and `/terms` (becomes `VITE_LEGAL_ENTITY_NAME`) |
| `SUPPORT_EMAIL` | variable | no (recommended) | where people send privacy requests and questions; a `mailto:` link on both pages (becomes `VITE_SUPPORT_EMAIL`) |
| `LEGAL_COUNTRY` | variable | no (recommended) | the governing law of the terms, written as it reads after "the laws of", e.g. `the State of Delaware, United States` (becomes `VITE_LEGAL_COUNTRY`) |
| `LEGAL_ADDRESS` | variable | no | postal address for the contact sections; `\n` or real line breaks separate lines (becomes `VITE_LEGAL_ADDRESS`) |

The four `LEGAL_*` / `SUPPORT_EMAIL` values are public (they ship in the
build). Without them the legal pages still render and say "the operator of
this service" instead of a name, and name no address, email or country; the
workflow prints a warning. They are read at build time, so re-run deploy-web
after changing them.

Shop subscription billing needs **no web setting**: the web reads everything
at run time from the backend (`shop_entitlement`, `public_billing_plans()`,
the `billing` function). While `BILLING_ENABLED` is off, Settings -> Billing
is not listed, the page says billing isn't enabled, no banner shows, and the
public `<APP_BASE_URL>/pricing` page says pricing is coming soon (it never
shows a made-up price). Once billing is on and plans are synced, `/pricing`
and Settings -> Billing list the plans from Stripe. The privacy policy and
terms (`/privacy`, `/terms`) already describe subscriptions (billed on your
platform Stripe account; renewal, cancellation in the Customer Portal, what a
lapsed shop can still do); have them reviewed before you turn billing on.

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
scripts/deploy/deploy_backend.sh --stripe-webhooks            # first deploy (stores the webhook secrets)
scripts/deploy/deploy_backend.sh                              # later deploys (keep them)
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
   `REQUIRE_LIVE_STRIPE=1`). A webhook signing secret that is not an input
   is left to step 2; the recreate / adopt knobs (3.3) are refused without
   `--stripe-webhooks`.
2. **Project and CLI** - Management API project lookup; a webhook signing
   secret that is not an input must already be stored in the project (it is
   kept as it is), else the run stops here with what to do; a snapshot of
   `supabase/config.toml`, `migrations/`, `functions/` (dot files excluded)
   and `setup/cron.sql` into a temporary directory that is deleted at exit, so
   a concurrent edit of the working tree cannot mix versions mid-deploy.
3. **Link** - `supabase link --project-ref` (password from
   `SUPABASE_DB_PASSWORD` in the environment).
4. **Migrations** - `supabase db push --dry-run` (always printed), then the
   real push. Skipped in a dry run.
5. **Function secrets** - Management API `POST /v1/projects/{ref}/secrets`
   with only the names from `supabase/functions/README.md`. Unchanged values
   (compared by SHA-256 digest) are not re-sent; optional secrets the inputs
   leave unset and the local-harness names are removed
   (`DELETE /v1/projects/{ref}/secrets`, section 2); the result is read back.
6. **Stripe webhook endpoints** (only with `--stripe-webhooks`): the Connect
   endpoint, and the platform billing endpoint when `BILLING_ENABLED=true` -
   see 3.3.
7. **Edge functions** - one `supabase functions deploy <name> --use-api`
   per `[functions.<name>]` in `config.toml`, with `--no-verify-jwt` exactly
   where `verify_jwt = false` (`payments`, `stripe-webhook`, `messaging`,
   `storage-purge`, `billing`, `billing-webhook`, ...: Stripe, Twilio and
   pg_cron send no Supabase JWT);
   `stripe-connect` and `invites` keep the gateway JWT check. Afterwards the
   deployed list is read back and every function's `verify_jwt` must match.
   `SUPABASE_FUNCTIONS_BUNDLER=docker` bundles locally with Docker instead of
   `--use-api`.
8. **Production Auth** - Management API `PATCH /v1/projects/{ref}/config/auth`
   (3.4), then read back.
9. **Platform setup** - `supabase/setup/cron.sql` rendered in memory with the
   real values and executed through the Management API (3.5), then checked;
   then the billing settings (`set_billing_config`) and, with billing on, a
   plan sync from Stripe (3.5.1).

### 3.1 `config.toml` is never pushed

`supabase/config.toml` is tuned for **local** journeys (email confirmations
off, `site_url` `http://127.0.0.1:5173`, loose local rate limits). The deploy
**never runs `supabase config push`** or anything else that syncs
`config.toml` to the hosted project: every CLI call goes through a guard that
refuses `config`, `db reset`, `db pull`, `secrets` and `branches` commands,
and the test suite asserts `config push` is never invoked. Production Auth is
set only through the Management API with email confirmations **ON** (3.4).
Do not run `supabase config push` by hand against production either.

Because of that, `config.toml`'s `[storage] file_size_limit = "200MiB"`
never reaches production. The five buckets (`job-photos`, `signatures`,
`shop-assets`, `documents` 25 MiB, `job-media` 200 MiB) and their per-bucket
limits come from the migrations, but the **project-wide upload limit** caps
every bucket: set it by hand to at least 200 MB (Dashboard -> Storage ->
Settings; plan-dependent, see LAUNCH.md 1.1), or job videos over the project
limit fail to upload.

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

### 3.3 Stripe webhook endpoints

With `--stripe-webhooks` the deploy manages **the Connect endpoint**
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
  Dashboard into `STRIPE_WEBHOOK_SECRET`, or recreate the endpoint (below).
- An endpoint at the same URL that the deploy did not create (for example one
  made by hand from the functions README) is never modified: delete it, or
  adopt it (below) if it is the Connect endpoint. Its signing secret must be
  stored or given as `STRIPE_WEBHOOK_SECRET` in that run (or recreate it in
  the same run).
- Recreate and adopt are one-shot choices of a single run, together with
  `stripe_webhooks`. The deploy refuses them in step 1 without
  `stripe_webhooks` (and the billing ones while billing is off) instead of
  ignoring them:

  | Workflow input (deploy-backend, with `stripe_webhooks`) | Local run (with `--stripe-webhooks`) | Effect |
  |---|---|---|
  | `stripe_webhook_recreate` = `connect`, `billing` or `both` | `STRIPE_WEBHOOK_RECREATE=1`, `STRIPE_BILLING_WEBHOOK_RECREATE=1` | deletes the tagged endpoint and creates a new one; its new signing secret is stored automatically. Needed after an SDK / `STRIPE_API_VERSION` upgrade (Stripe cannot change an endpoint's API version; the deploy warns when they differ) and when the stored secret is wrong or lost |
  | `stripe_webhook_adopt_connect` = `we_...` | `STRIPE_WEBHOOK_ADOPT=we_...` | manages the hand-made endpoint at `.../stripe-webhook` from now on (tagged, events set) |
  | `stripe_webhook_adopt_billing` = `we_...` | `STRIPE_BILLING_WEBHOOK_ADOPT=we_...` | the same for `.../billing-webhook` (with `BILLING_ENABLED=true`) |

  Unset the local variables again afterwards.
- **Platform billing endpoint** (only while `BILLING_ENABLED=true`): a second,
  **non-Connect** endpoint ("Events on your account") at
  `https://<ref>.supabase.co/functions/v1/billing-webhook` for shop
  subscriptions ([BILLING.md](BILLING.md)), tagged
  `detail_crm_role=billing`, with exactly the events in `HANDLED_EVENT_TYPES`
  of `supabase/functions/billing-webhook/handlers.ts` and the same API
  version. It works exactly like the Connect endpoint above, with its own
  secret and knobs: the signing secret is stored as
  `STRIPE_BILLING_WEBHOOK_SECRET`, `stripe_webhook_recreate` = `billing`
  replaces it, and `stripe_webhook_adopt_billing` adopts an endpoint made by
  hand. With billing off the endpoint is neither created nor removed, and its
  stored secret is kept (existing subscriptions keep syncing after billing is
  turned off).
- The two endpoints never share a URL or a secret: `stripe-webhook` acts only
  on connected-account events (`event.account`; charges are direct charges on
  the shop's Express account) and `billing-webhook` only on the platform
  account's own events.

### 3.4 Auth settings applied

| Setting | Value |
|---|---|
| `site_url` | `APP_BASE_URL` |
| redirect allow-list | `APP_BASE_URL/**`, `/reset-password`, `/invite/**`, `/portal`, `/app/**`, `/login` (+ `AUTH_ADDITIONAL_REDIRECT_URLS`) |
| email sign-up | on; phone and anonymous sign-in off |
| email confirmations | **on** (`mailer_autoconfirm = false`): `portal_claim_customers()` links portal users by *confirmed* email |
| secure email change, reauthentication for password change | on |
| refresh-token rotation / reuse interval / JWT expiry | on / 10 s / 3600 s |
| minimum password length | 8 (`AUTH_PASSWORD_MIN_LENGTH`), the same rule as the web and iOS forms |
| SMTP | `smtp.resend.com:465`, user `resend`, password `RESEND_API_KEY`, sender from `EMAIL_FROM` |
| email rate limit | `AUTH_RATE_LIMIT_EMAIL_SENT` per hour (default 100) |
| minimum interval between emails to one user | 60 s |

Email links (both apps): the web app and the iPhone app both use Supabase
Auth's **implicit flow**. A sign-up confirmation, password-reset or
email-change link carries the session in the URL fragment, so it works in
any browser on any device, whichever app sent it. The iPhone app has no URL
scheme: its password-reset emails link to `APP_BASE_URL/reset-password` and
its sign-up confirmations to `APP_BASE_URL/auth/callback` (the build's
`WEB_APP_URL`, which ios-testflight takes from the same `APP_BASE_URL`
variable), the same pages the web's own emails use. The web accepts link
tokens only on those two pages; a link to the Site URL root is scrubbed and
refused, so it would land on the sign-in page without signing anyone in.
Both are on the allow-list above (`APP_BASE_URL/**`), so nothing is set by
hand. A build without `WEB_APP_URL` sends no redirect and its links fall
back to the Site URL. Keep the web app and the iPhone build on the same
`APP_BASE_URL`; a reset link to another origin needs that origin in
`AUTH_ADDITIONAL_REDIRECT_URLS`, otherwise Supabase falls back to the Site
URL, which signs the person in but shows no new-password form.

Email templates are left at their current values (edit them in the Dashboard
if you want your own wording). Keep their `{{ .ConfirmationURL }}` link:
neither app verifies a `{{ .TokenHash }}` link, so a template rewritten that
way breaks confirmation and reset links.

### 3.5 Platform setup (cron.sql)

`supabase/setup/cron.sql` is the one-time SQL that stores `APP_BASE_URL` in
`platform_config` (every customer link in messages is built from it) and
schedules the twelve pg_cron jobs (message queue, automations, quote expiry,
payment sheet sweep, storage purge, push notifications, outbound webhooks,
SMS verification status, recurring job series, billing plan sync, billing
customer sync, SMS number releases) with the functions URL and
`CRON_SECRET` kept in Vault. The file's header lists each job's name,
schedule and purpose; `detail-crm-billing-sync-customers` keeps each shop's
platform Stripe customer on its current owner's email, and
`detail-crm-sms-releases` releases the Twilio numbers of deleted shops.
The deploy replaces exactly the three assignments the file asks you to edit (`v_functions_url`, `v_cron_secret`,
`v_app_base_url`), in memory, and sends the result over HTTPS to the
Management API; no edited copy is written anywhere. It then checks
`platform_config.app_base_url`, that every job in cron.sql is active, and the
two Vault entries. The push and SMS-status jobs are harmless no-ops until
their settings exist (`APNS_*`, `SMS_PROVISIONING_ENABLED`).

Dependency: this matches cron.sql's **current** placeholder format. If that
file changes how it is parameterized, the deploy stops with
"placeholder format changed" (it never guesses); update `CRON_ASSIGNMENTS` in
`scripts/deploy/lib/config.mjs` together with the file.

Rotating `CRON_SECRET`: set the new value and re-run the deploy. Steps 5 and 9
update the function secret and Vault in the same run; cron calls in between
(at most a minute or two) get 401 and simply run again on the next tick.

#### 3.5.1 Billing settings and plan sync

After cron.sql, step 9 calls
`public.set_billing_config(p_enabled, p_trial_days)` with `BILLING_ENABLED`
(default `false`) and `BILLING_TRIAL_DAYS` (default `0`) through the same
Management API SQL endpoint and reads `platform_config` back
(`billing: ON, trial N day(s)` / `billing: off`). Turning billing on gives
every shop that never subscribed a trial of that length from that moment
([BILLING.md](BILLING.md) section 5). With billing on it then calls the
**deployed** `billing` function's `sync_plans` with `CRON_SECRET` (the
functions were deployed in step 7) and prints how many plan prices are active,
plus a `WARN` line per Stripe Price that was skipped and per metadata value
that was ignored; a failed sync fails the step. Re-running is harmless (same
settings, same plans).

An **unset** input never changes a project that has another value: when
`BILLING_ENABLED` is unset but billing is on in the project, or
`BILLING_TRIAL_DAYS` is unset but the project has a trial, the step stops
before running anything and asks for the value (so a local run without the
repository variables cannot switch billing off). This differs on purpose
from the optional function secrets (section 2), which follow their inputs:
the billing switch and trial change every shop's access, so an omission
never changes them. A dry run prints the `set_billing_config` call it would
make and sends nothing.

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
unsubscribe redirect); `billing` answers its own 401 / 400 envelopes (no
session, a client-sent price, no cron secret) and `billing-webhook` rejects
unsigned and forged requests (a missing `STRIPE_BILLING_WEBHOOK_SECRET` is a
`SKIP` while `BILLING_ENABLED` is not `true`, a `FAIL` when it is);
CORS allows exactly `APP_BASE_URL`'s origin;
`job-photos` / `signatures` are private and `shop-assets` public; Realtime
accepts the anon key; with the access token also the deployed `verify_jwt`
values, `platform_config.app_base_url`, the cron jobs, and that the
project's billing settings match `BILLING_ENABLED` / `BILLING_TRIAL_DAYS`
when they are set.

It also checks that an unknown public link answers HTTP 404 `PT404` (never a
5xx): the old HTTP 500 `P0002` defect is fixed (`scripts/stack/README.md`),
so a regression is a `FAIL`. `KNOWN` lines would be documented open defects
that do not fail the run unless `--strict`; there are none at present. Exit
code 1 on any `FAIL`.

### 3.7 Tests of the deploy tooling

`node --test "scripts/deploy/test/*.test.mjs"` (the backend workflow runs it
first, and `.github/workflows/deploy-tools.yml` runs it on every push or pull
request that changes `scripts/deploy/`, `supabase/config.toml`,
`supabase/setup/cron.sql`, a function's `index.ts`, `_shared/env.ts`,
`_shared/stripe.ts` or the webhook's `handlers.ts`). It drives `deploy_backend.sh` end to end against a fake Supabase CLI
and a fake Management + Stripe API: command order, verify_jwt flags, dry run
without mutations, missing/invalid inputs, no secret in output or argv,
idempotent re-runs, `config push` never invoked, a foreign Stripe endpoint
left alone (and adopted on request), recreating an endpoint, later deploys
that keep the stored webhook secrets, optional secrets removed when their
input is unset, that the deploy-backend workflow passes every secret and
knob to the script, and billing (the platform endpoint with exactly the
billing events and its own secret, `set_billing_config`, the plan sync after
the functions deploy, the unset-input guard, a failed sync). It also covers
`verify_live.mjs` against a fake project with each deploy mistake injected
(including a regression of unknown public links to HTTP 500), and the header
generator.

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
| `WEB_TRACKING_PATHS` | same CSP plus the Meta Pixel / GA4 sources (`TRACKING_SOURCES` in `web_headers.mjs`: script `connect.facebook.net`, `www.googletagmanager.com`; images and beacons to `www.facebook.com` and Google Analytics); only `/book/*` and `/booking/*` are accepted |

SPA fallback: Cloudflare Pages serves `index.html` (200) for every unknown
path as long as the build has no top-level `404.html` (the generator refuses
one). A `/* /index.html 200` redirect rule is deliberately not written: Pages
ignores it as an infinite loop.

### 4.1 Content-Security-Policy

Exactly what the app loads (audited from `web/src` and `web/index.html`):

```
default-src 'self'; script-src 'self' 'sha256-<theme snippet>';
style-src 'self' https://fonts.googleapis.com 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=';
font-src 'self' https://fonts.gstatic.com data:;
img-src 'self' data: blob: https://<ref>.supabase.co https://tile.openstreetmap.org;
media-src 'self' blob: https://<ref>.supabase.co;
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
  Storage images (public and signed URLs) and job videos (signed URLs,
  `media-src`).
- NHTSA vPIC: VIN decoding in the job and customer forms.
- OpenStreetMap tiles (`tile.openstreetmap.org`, images only): the calendar's
  day map of mobile jobs (Leaflet, bundled). The map shows the OpenStreetMap
  attribution; the browser never geocodes (points come from the iPhone app),
  and the multi-stop "Open route in Google Maps" hand-off is a navigation.
- Google Fonts (Inter) from `index.html`.
- Stripe Checkout / Connect onboarding, the shop subscription's Checkout
  and Customer Portal (Settings -> Billing: `checkout.stripe.com`,
  `billing.stripe.com`, reached with `window.location.assign` after the
  `billing` function returns the URL; no form post, so `form-action 'self'`
  is unaffected) and Google Maps links are top-level navigations, which CSP
  does not restrict. Billing needs no header change.
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
detaches) and opens login, public booking, dashboard, calendar, reports, the
public `/pricing` page and Settings -> Billing (owner, with plans) in
Chromium against a mocked Supabase. It asserts the CSP header is served, zero
`securitypolicyviolation` events, no CSP console errors, no page errors, no
request to an unknown origin; negative controls prove a forbidden fetch,
inline script and image are reported; framing works as configured.

`--strict` also fails on findings the tool reports as `KNOWN`. There are
none: zod 4 used to probe `new Function` once (blocked by the CSP, then
falling back to its interpreter); `web/src/zodConfig.ts` calls
`z.config({ jitless: true })` and is imported as the first line of
`web/src/main.tsx`, so no violation is reported. The proof does not open the
calendar's day map; its only extra origin is the OpenStreetMap tiles in
`img-src` (4.1).

### 4.3 Framing (embeds)

Nothing is frameable by default. Shops embed their booking page and lead
forms on their own websites (Settings -> Online booking and Settings -> Lead
forms show the snippets). The snippet is
`<div data-detailcrm-book="<slug>" [data-link="<token>"] [data-lead="<token>"]></div>`
plus `<script src="<APP_BASE_URL>/embed.js" async></script>`:
`web/public/embed.js` (no dependencies, no cookies) replaces each div with an
iframe of `/book/<slug>?embed=1` (`&link=<token>` for a private booking
link) or `/lead/<token>?embed=1`, grows it from the page's
`detailcrm:height` messages and scrolls its top into view on
`detailcrm:scroll-top`; both are accepted only from that frame and only from
the app's origin (web/README.md, "Booking embed"). A plain iframe of the same
URL works without the script (fixed height). To allow framing, set
`WEB_EMBED_PATHS=/book/*,/lead/*` (and optionally `WEB_EMBED_ANCESTORS`,
e.g. to specific shop domains). The generator refuses
paths that would expose staff pages (`/app`, `/*`). Independently of the
headers, the web app itself refuses to render any other route inside a frame
(`web/src/app/RootLayout.tsx` shows "This page can't be shown here"), and in
embed mode (`?embed=1`) links that leave the booking page (manage booking,
deposit payment) open in the top window.

An embedded lead form is public (its token is in the shop's page source), so
the database limits what it can do (`public_submit_lead`, migration 0088):
at most 10 submissions per client connection per form (an IPv6 /64 counts
as one connection, migration 0105), 3 per email or phone and 200
per form in any 24 hours (then HTTP 429). The optional auto-reply never
repeats what the visitor typed (it greets them as "there"); it is emailed
to the address given and **texted only to a phone number the shop already
verified** on an existing customer, never to the number a new lead typed
in, so a form cannot be used to send texts, at the platform's cost, to
arbitrary numbers. Restrict Twilio's Geo permissions to the countries your
shops serve as well ([LAUNCH.md](LAUNCH.md) 1.3).

Shops can add their own Meta Pixel / GA4 measurement id (Settings ->
Online booking). The public booking page `/book/<slug>` loads those tags
only when an id is set (never for private booking links); the customer's
own booking page `/booking/<token>` loads only GA4, once, to report a
deposit paid online (with the token left out of the page address); lead
forms and every other page never load them. The CSP allows their origins
only on `WEB_TRACKING_PATHS` (accepted values: `/book/*`, `/booking/*`;
default none, so the tags are blocked). Set
`WEB_TRACKING_PATHS=/book/*,/booking/*` when the platform allows shops to use
them (`/book/*` alone keeps the deposit report off); the privacy policy
(`web/src/features/legal/content.tsx`) already describes what those tags
receive.

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

Prerequisites (once, [LAUNCH.md](LAUNCH.md) section 1.6): Apple Developer
Program membership, the bundle id `com.detailcrm.app` (or `IOS_BUNDLE_ID`)
registered, an App Store Connect app record with that bundle id, and a team
API key with the Admin role.

The workflow runs on `macos-26` and selects the newest release Xcode 26 or
later with `ios/ci/select_xcode.sh` (the same choice as `ios.yml`, so a green
`ios.yml` build means the archive compiles), runs `scripts/swift_sanity.py`,
writes the API key to a private temp file, then `bundle exec fastlane ios beta`:

0. SDK check: the selected Xcode's iOS SDK must be 26 or later (see
   "Xcode and the iOS SDK" below); an upload run stops here otherwise.
1. API key session (`app_store_connect_api_key`); build number = latest
   TestFlight build number + 1 (`latest_testflight_build_number`, or
   `BUILD_NUMBER` to force one); app version = the `app_version` input
   (`APP_VERSION` locally), else the project's `MARKETING_VERSION`. Before
   archiving, an upload run compares it with the version live on the App
   Store and stops with a message when it is not higher (see "Versions").
2. `Config.plist` gets `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `WEB_APP_URL`
   (= `APP_BASE_URL`) for this build (`AppConfig.swift` reads that file); the
   committed placeholders are restored afterwards. The app bundles no Stripe
   key: the `payments` function returns the publishable key per payment.
3. `xcodebuild archive` with `-allowProvisioningUpdates` and the API key
   (`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`):
   Xcode automatic signing with cloud-managed certificates.
   `DEVELOPMENT_TEAM`, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are
   build-setting overrides; the project file is not edited. A non-default `IOS_BUNDLE_ID` is
   applied to the app target only for the build and restored (a command-line
   `PRODUCT_BUNDLE_IDENTIFIER` would also rename the Swift packages' resource
   bundles, which App Store Connect rejects as duplicates).
4. `xcodebuild -exportArchive` (method `app-store-connect`, automatic
   signing); the archive's SDK (`DTSDKName` in the app's Info.plist) is
   checked again, then `upload_to_testflight` without waiting for processing.
5. Artifacts: `DetailCRM.ipa`, `DetailCRM.app.dSYM.zip`, the build number,
   the version, and the xcodebuild logs.

**Xcode and the iOS SDK.** Apple raises the minimum SDK for App Store
Connect uploads every spring; since April 28, 2026 apps uploaded to App Store
Connect, TestFlight included, must be built with Xcode 26 / the iOS 26 SDK or
later. An archive made with Xcode 16 (iOS 18 SDK) still archives and exports,
but its upload or processing is rejected with an SDK-version error, so no
build reaches testers or App Review. Both iOS workflows therefore run on
`macos-26` and use `ios/ci/select_xcode.sh`, which picks the newest installed
release Xcode (betas skipped) whose major version is at least
`MIN_XCODE_MAJOR` (26) and fails the job when the image has none; the lane
checks the SDK before archiving (`MIN_UPLOAD_SDK_MAJOR` in
`ios/fastlane/Fastfile`) and the archive's SDK before uploading, so a wrong
Xcode stops the run with a message instead of an App Store Connect rejection.
When Apple announces the next minimum, raise `MIN_XCODE_MAJOR` and
`MIN_UPLOAD_SDK_MAJOR` together (and `runs-on` if the new Xcode needs a newer
image). Locally, `xcode-select -s` an Xcode 26+ before `fastlane beta`
(`SKIP_UPLOAD=1` only warns). The deployment target stays iOS 17; building
with the iOS 26 SDK gives the system bars, tab bar, sheets and alerts the
iOS 26 look on iOS 26 devices, so check those screens on a TestFlight build
(Apple's temporary `UIDesignRequiresCompatibility` Info.plist key keeps the
previous look while Apple still honors it, if a screen needs time).

**Versions.** App Store Connect groups builds by app version (the project's
`MARKETING_VERSION`, 1.0 in git; "Version" in App Store Connect). The build
number goes up by itself; the version does not. Builds of a version can be
uploaded until that version is approved for the App Store: then its train
is closed and every later upload of it is rejected ("The train version ... is
closed" / `CFBundleShortVersionString` must be higher than the previously
approved version), even though the archive and export succeed. So after each
App Store approval, raise the version before the next build:

- for one run: Actions -> ios-testflight -> Run workflow -> `app_version`
  (e.g. `1.1`; locally `APP_VERSION=1.1`);
- for good (so pushes to `.github/trigger-testflight` use it too): set
  `MARKETING_VERSION` in `ios/DetailCRM/DetailCRM.xcodeproj/project.pbxproj`
  (the Debug and Release lines, which must match; Xcode -> target DetailCRM
  -> General -> Version edits both) and commit it.

Use one to three numbers (`1.1`, `1.2.0`, `2`), each release higher than the
last approved one. The lane checks only the version that is live on the App
Store: a version approved but not yet released (manual release) also closes
its train, so raise the version past it yourself.

`ITSAppUsesNonExemptEncryption = NO` is already set, so builds need no export
compliance answer. Local run on a Mac: `cd ios && bundle install &&
ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/AuthKey_X.p8 APPLE_TEAM_ID=...
SUPABASE_URL=... SUPABASE_ANON_KEY=... WEB_APP_URL=... bundle exec fastlane beta`
(`SKIP_UPLOAD=1` to only build). Output goes to `ios/build/`.

## 6. Re-running

Every step converges on the desired state: migrations only apply what is
pending, unchanged secrets are skipped, optional secrets whose input was
removed are removed (section 2), the stored webhook signing secrets are kept,
the Stripe endpoints are found by their tag and updated (with
`stripe_webhooks`), Auth is patched to the same values, `cron.sql`
unschedules before scheduling. Functions are redeployed each time (a new
version with the same code). A failed run can simply be run again after
fixing the cause.

## 7. Rollback

- **Database**: forward-only. Restore from a backup or, with the PITR add-on,
  to a point in time (Dashboard -> Database -> Backups;
  [docs](https://supabase.com/docs/guides/platform/backups)). Restoring
  rewinds all data, so prefer a fix-forward migration when possible.
- **Edge functions**: redeploy the previous code, e.g.
  `git worktree add /tmp/prev <good-sha>` then, from `/tmp/prev`,
  `supabase functions deploy <name> --project-ref <ref> --use-api`
  (add `--no-verify-jwt` for every function with `verify_jwt = false` in
  `config.toml`: `payments`, `stripe-webhook`, `messaging`, `storage-purge`,
  `billing`, `billing-webhook`, ...). Do not run the full deploy from an older commit: `db push`
  refuses because the database has newer migrations than that commit.
- **Secrets**: re-run the deploy with the previous values.
- **Web**: Cloudflare -> the Pages project -> Deployments -> an earlier
  production deployment -> Rollback
  ([docs](https://developers.cloudflare.com/pages/configuration/rollbacks/)).
- **iPhone**: TestFlight builds cannot be replaced; expire the bad build in
  App Store Connect and ship a new one (a fixed build of the reverted code).
  If the bad build's version is already approved for the App Store, the new
  build needs a higher version (section 5, "Versions").

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Missing required inputs` | add the listed names (section 2) |
| `HTTP 401 (SUPABASE_ACCESS_TOKEN is invalid or expired)` | create a new personal access token |
| `link` / `db push` fails on the password | `SUPABASE_DB_PASSWORD` is wrong; reset it in Project Settings -> Database |
| `db push`: migrations "to be inserted before the last migration on remote" | an out-of-order migration (3.2), run with `include_all_migrations` |
| `STRIPE_WEBHOOK_SECRET is neither an input nor stored in the project` (step 2) | a project that never had the endpoint: run once with `stripe_webhooks` (3.3), or set the secret of an endpoint you made by hand. The same for `STRIPE_BILLING_WEBHOOK_SECRET` once `BILLING_ENABLED=true` |
| `endpoint ... exists but STRIPE_WEBHOOK_SECRET is not stored` | 3.3 |
| `... acts only together with --stripe-webhooks` | a recreate / adopt input without `stripe_webhooks` (3.3): check it too |
| `WARN ... set in the project but not in this deploy's inputs, so this deploy removes them` | an optional variable is missing (section 2): set it again if the feature should stay on |
| `cron.sql: ... placeholder format changed` | 3.5 |
| verify_live `server_misconfigured` | a function secret is missing or malformed; the function logs name the variable |
| verify_live `deployed with verify_jwt=true` on a webhook function | redeploy it with `--no-verify-jwt` (the deploy does this from `config.toml`) |
| Browser console: `Refused to ... Content Security Policy` | a new external origin in `web/src`: 4.1 |
| Stripe Dashboard shows webhook failures with 400 | the endpoint's signing secret differs from the stored `STRIPE_WEBHOOK_SECRET` (often an old GitHub secret sent back after the deploy made a new one: delete it): run with `stripe_webhooks` and `stripe_webhook_recreate` = `connect` |
| `BILLING_ENABLED is not set, but billing is ON in this project` | 3.5.1: set the variable explicitly |
| `billing sync_plans: HTTP ...` | the plan sync failed after the functions deploy: the code names why (`unauthorized` = `CRON_SECRET` differs; `service_unavailable` = Stripe); [BILLING.md](BILLING.md) section 11 |
| Stripe shows 400s on the `billing-webhook` endpoint | its signing secret differs from the stored `STRIPE_BILLING_WEBHOOK_SECRET`: run with `stripe_webhooks` and `stripe_webhook_recreate` = `billing` |
| fastlane: `Could not read TestFlight builds` | the App Store Connect app record for the bundle id is missing, or the key's role is too low |
| fastlane: `Version X is not higher than Y, the version on the App Store`, or the upload is rejected because the train version is closed | raise the app version (section 5, "Versions") |
