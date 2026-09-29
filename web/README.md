# Detail CRM — web app

Staff dashboard, public booking/quote/invoice/form pages and the client portal.
Vite + React 19 + TypeScript (strict) + React Router 7 (data mode) + TanStack
Query 5 + supabase-js 2 + Tailwind CSS 4. Product/architecture contract:
[`docs/SPEC.md`](../docs/SPEC.md); column-level contract: `docs/SCHEMA.md`.

## Run it

```bash
cd web
cp .env.example .env.local      # fill in your Supabase project URL + anon key
npm ci
npm run dev                     # http://localhost:5173
```

Without the env vars the app renders a **Setup** screen instead of crashing.

| Script                              | What it does                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------------- |
| `npm run dev` / `build` / `preview` | Vite dev server / production build / serve the build                          |
| `npm run typecheck`                 | `tsc -b --noEmit` (app + tests + configs + e2e)                               |
| `npm run lint`                      | ESLint (typescript-eslint type-checked, react-hooks, jsx-a11y), zero warnings |
| `npm run test`                      | Vitest unit/component tests (jsdom)                                           |
| `npm run e2e`                       | Playwright smoke tests against a mocked Supabase                              |
| `npm run check`                     | typecheck → lint → test → build (what CI runs, plus e2e)                      |
| `npm run format`                    | Prettier (with Tailwind class sorting)                                        |

Node 22, npm (commit `package-lock.json`). CI: `.github/workflows/web.yml`.

### Environment

| Variable                 | Meaning                                                                                 |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `VITE_SUPABASE_URL`      | `https://<ref>.supabase.co`                                                             |
| `VITE_SUPABASE_ANON_KEY` | the **anon** public key                                                                 |
| `VITE_LEGAL_ENTITY_NAME` | optional: legal name of the operator, shown on `/privacy` and `/terms`                  |
| `VITE_SUPPORT_EMAIL`     | optional: where privacy requests and questions go (a `mailto:` link on both pages)      |
| `VITE_LEGAL_COUNTRY`     | optional: governing law, as it reads after "the laws of" (`the State of Delaware, USA`) |
| `VITE_LEGAL_ADDRESS`     | optional: postal address (`\n` for line breaks)                                         |

The legal pages render without the `VITE_LEGAL_*` values: they then say "the
operator of this service" and never show a made-up name, address or email.
Their wording lives in `src/features/legal/content.tsx` and must stay true to
what the code does (update it, and `LEGAL_LAST_UPDATED`, with the change).

Only public values may be `VITE_` variables — they ship to every browser.
Stripe/Twilio/Resend secrets and the service-role key live in Supabase function
env / GitHub secrets only.

## Folder conventions

```
src/
  app/            router, route registry, providers, theme, error boundary, 404, setup screen
  components/
    ui/           the UI kit (import from '@/components/ui')
    layout/       AppShell, AuthLayout, PublicLayout, nav, top-bar widgets
  features/<name>/
    routes.tsx    exports `routes: FeatureRoutes` (the ONLY thing the shell imports)
    api.ts        TanStack Query hooks + query keys for this feature
    *Page.tsx     route components (default export, lazy loaded)
    components/   feature-private components
  lib/            supabase client, money, dates, phone, errors, queryKeys, useRealtime, validation
  test/           vitest setup, render helpers, supabase mock
e2e/              Playwright specs + support/mockSupabase.ts (backend mock)
```

Rules:

- A feature only edits files inside `src/features/<name>/`. Shared changes
  (UI kit, lib, shell) are separate, reviewed changes.
- Import with the `@/` alias (`@/lib/money`), never long relative paths across features.
- `react-router` (not `react-router-dom`), `@date-fns/tz` via `@/lib/dates`
  (ESLint enforces both).
- Every screen renders **loading / empty / error** (`LoadingState`,
  `EmptyState`, `ErrorState` with retry).
- **Money is integer cents** (`formatCents`, `MoneyInput`, `parseMoneyInput`).
  Never compute totals, tax or balances in the client — the server does (SPEC §4.5).
  Public flows never send prices.
- **Dates display in the shop timezone** (`useShop().timezone` + `@/lib/dates`),
  never the browser's. Convert form input with `shopLocalToUtcIso(date, time, tz)`.
- Phones are stored E.164 (`zPhone` / `normalizePhone`), shown with `formatPhone`.
- Amber (`variant="money"`, `bg-money`, `tone="money"`) only for money and money actions.

### Feature stubs

Every feature folder starts with a placeholder page whose first line contains
`FEATURE_STUB`. Replace the page (and delete the marker). A release check greps
for `FEATURE_STUB` and must find nothing.

## Routing

`src/app/router.tsx` builds the tree; `src/app/featureRoutes.ts` collects each
feature's `routes`:

```tsx
// src/features/jobs/routes.tsx
import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'jobs', // relative to /app
      element: (
        <RequireRole capability="jobs.viewAssigned">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./JobsPage')) },
        { path: ':jobId', lazy: lazyPage(() => import('./JobDetailPage')) },
      ],
    },
  ],
  public: [/* absolute paths, e.g. { path: '/book/:slug', lazy: … } */],
};
```

- `staff` routes render inside `AppShell` for a signed-in user **with a current
  shop** (`RequireAuth` → `ShopProvider` → `RequireShop`). Users without a shop
  are sent to `/app/onboarding`.
- `public` routes render with no shell; wrap them in `PublicLayout` (shop logo +
  brand colour from the public RPC). The portal adds `RequireAuth` itself.
- Pages are lazy (`lazyPage`) and must `export default` the component.
- Each top-level feature route gets `RouteErrorBoundary` automatically (a crash
  shows an error panel; stale-deploy chunk errors offer a reload).
- `useNavigate`, `Link`, `useParams`, `useSearchParams` from `react-router`.

Route map: `/login`, `/signup`, `/forgot-password`, `/reset-password`,
`/auth/callback` (sign-up confirmation links), `/invite/:token`, `/book/:slug` (`?embed=1`, `?link=<token>`, prefill
`?services=&category=&coupon=`), `/booking/:token`, `/q/:token`, `/i/:token`,
`/f/:token`, `/r/:token` (customer job report), `/lead/:token` (lead form,
`?embed=1`), `/join/:slug` (membership sign-up), `/gift/:slug` and
`/gift/:slug/done` (gift card shop), `/done/:slug` (`?card=saved|canceled`,
`?membership=active|canceled`: return from a card-setup or membership link
staff sent), `/u/:token` (email unsubscribe),
`/portal`, `/account` (every signed-in role: delete account), `/privacy`,
`/terms` (public; linked under the auth pages, in the public page footer and
on `/account`), `/pricing` (public: the platform's plans), `/app` (dashboard), `/app/{calendar,jobs,customers,quotes,
invoices,payments,memberships,gift-cards,messages,campaigns,reports,team,
timesheets,tasks,inventory,catalog,settings,notifications}`,
`/app/settings/<section>` (see Settings), `/app/onboarding`.

## Auth & tenancy

- `useAuth()` (`@/features/auth/authContext`) → `{ status, user, session, signOut }`.
- `useShop()` (`@/features/shop/shopContext`) — only under staff routes →
  `{ shop, shopId, role, memberId, timezone, currency, techsCanCollectPayments,
permissions, memberships, switchShop }`. `memberId` is `shop_members.id`
  (use it for assignments / time entries).
- The last-used shop is remembered per user in localStorage; switching shops
  keeps caches separate because every tenant query key contains the shop id.
- Sessions in the URL (`src/lib/authUrlSession.ts`, login CSRF): email links
  use the implicit flow so they work on another device, but supabase-js may
  save a session from the URL only for a recovery link on `/reset-password`
  that belongs to the account signed in here (or when nobody is). Sign-up
  confirmation links (`emailRedirectTo` = `/auth/callback?next=…`) show the
  account and sign in only when the visitor continues. Tokens anywhere else
  are ignored and removed from the address bar.

## Permissions

`src/features/shop/permissions.ts` is the single web copy of the SPEC §3
matrix (unit-tested row by row in `permissions.test.ts`). It only drives UI —
RLS/RPCs enforce the same rules server-side.

```tsx
const canRefund = useCan('payments.refund');           // hook
<RequireRole capability="settings.manage">…</RequireRole>  // guard (route or section)
<RequireRole roles={['owner']}>…</RequireRole>
can(permissions, 'jobs.manage');                        // pure function
canChangeMemberRole(actor, target, next);               // team-management rules
```

Capabilities with an `Assigned`/`Own` suffix mean "the screen is allowed; the
server narrows rows" (e.g. technicians see only assigned jobs).
`payments.collect` / `invoices.viewAssigned` follow `shops.techs_can_collect_payments`.

## Data access

- The typed client is `supabase` from `@/lib/supabase` (`SupabaseClient<Database>`).
  `src/lib/database.types.ts` is **generated** by `scripts/gen_types.py` — never
  hand-edit it. Use `Row<'jobs'>`, `InsertRow<'jobs'>`, `RpcArgs<'fn'>` from `@/lib/db`.
- Put all queries/mutations for a feature in `src/features/<x>/api.ts` as
  TanStack Query hooks. Components never call `supabase` directly.
- Throw on errors with `unwrap(result)` / `toAppError(error)` so `error`
  states show friendly text (`errorMessage(err)`); RLS denials never leak
  policy names, and `RAISE EXCEPTION` messages from our SQL are shown as-is.
  Public RPCs raise `PT404` (HTTP 404) for unknown links: kind `not_found`.
  A shop subscription refusal — `PT402` from PostgREST (HTTP 402) or an edge
  function's `402 payment_required` envelope (never `402 payment_failed`, a
  card decline) — is kind `subscription` with the server's neutral sentence
  verbatim (`isSubscriptionError`, `subscriptionRefusalReason` →
  `subscription_inactive` | `seat_limit`). Owners get "Go to Billing": in
  error toasts automatically (the shell registers `toast.setErrorAction`),
  next to inline form errors with `<BillingErrorLink error={…} />`
  (`@/features/billing/BillingErrorLink`).
  Edge functions: `invokeEdge(fn, action, params, schema)` from
  `@/features/quotes/shared/edge` throws `EdgeFunctionError` (`reason` /
  `details` from the `{ error, code, details }` envelope). A body that is not
  our envelope (the gateway's `{ message }`, HTML) falls back to the HTTP
  status: 401 → session expired, 403 → permission, 404 → not found, 429 →
  rate limited, 5xx → generic.
- Messages that may be retried carry a `request_nonce` (one per compose,
  `newRequestNonce()`), reused on a retry after a network error and renewed
  after a send or a definitive refusal, so the server never sends twice.
  `@/lib/requestNonce` generalises it: `useRequestNonces()` keeps one nonce
  per action key until the action settles (kept after network / server /
  unknown errors, renewed after success or a refusal). Used by
  `add_fee_line` (key: document + fee) and each committed import chunk
  (key: file, batch, first row and a fingerprint of the rows; a replayed
  chunk answers `"replayed": true` and is counted once), and by the billing
  checkout.
- Validate untyped results (RPC `jsonb`, embedded selects) with zod at the boundary.

### Query keys

```ts
import { shopKey } from '@/lib/queryKeys';

export const jobKeys = {
  all: (shopId: string) => shopKey(shopId, 'jobs'),
  list: (shopId: string, f: JobFilters) => [...jobKeys.all(shopId), 'list', f] as const,
  detail: (shopId: string, id: string) => [...jobKeys.all(shopId), 'detail', id] as const,
};
```

`['shop', shopId, domain, …]` for tenant data, `['me', userId, …]` for the
user, `['public', kind, token]` for public pages, `['portal', …]` for clients.
Invalidate the **domain** key after a mutation (`jobKeys.all(shopId)`), plus any
other domain the server changed (e.g. recording a payment → `invoices`,
`payments`, `jobs`).

### Mutations & optimistic updates

- Default: no optimism — `onSuccess`/`onSettled` invalidate and the UI shows
  the server's result (totals, statuses and balances are computed by triggers).
- Optimistic updates are allowed only for local, reversible, non-money fields
  (checklist ticks, notification read state, drag-to-reschedule preview). Use
  the `onMutate` snapshot → `onError` rollback → `onSettled` invalidate pattern.
- **Never** optimistically change money, statuses with server-side side
  effects, or anything a trigger recomputes.
- Mutations never retry automatically; queries don't retry permission/validation errors.
- Offline: queries and mutations use `networkMode: 'always'` (`app/queryClient.ts`), so
  nothing is paused and replayed later: a save made offline fails at once with "Can't reach
  the server…" (dialogs unlock), an unloaded page shows `ErrorState`, and `OfflineBanner`
  says the browser is offline. TanStack Query is the only retry policy for reads
  (postgrest-js' own retries are off: `db: { retry: false }` in `lib/supabase.ts`).
- Show feedback with `useToast()` (`toast.success('Saved')`, `toast.error(err)`).
  Toasts pause while hovered, focused or the tab is hidden, and one with an
  `action` stays until used or dismissed (WCAG 2.2.1). Never put something the
  user must act on or copy only in a toast: a link the browser refused to copy
  goes in `<CopyLinkDialog>` (use `copyText` from `@/features/quotes/shared/format`,
  which also tries the legacy copy command).
- PostgREST caps every response at `max_rows` = 1,000 rows (hosted default and
  `supabase/config.toml`), whatever `.limit()` / `.range()` asks. Anything that
  may need more (CSV exports, timesheet totals) reads pages with
  `readPages(page, { limit, key })` from `@/lib/db` (exact count on the first
  page, `truncated` when more than `limit` match); order by a unique tiebreaker.
- The customer's own booking cancel is the payments edge `booking_cancel`
  (expires the booking's open deposit / invoice pay pages, then
  `public_cancel_booking` as the caller), never the RPC directly: it refuses
  (55000 `checkout_open`) while such a page is alive. Manual payments, gift
  cards and store credit refused with `checkout_open` (`isCheckoutOpenError`)
  offer "Cancel open payments and try again" (`CheckoutOpenNotice`).

### Realtime

```ts
useRealtime({ table: 'jobs', shopId }); // invalidates shopKey(shopId, 'jobs')
useRealtime({ table: 'messages', shopId, invalidate: [msgKeys.thread(shopId, id)], onChange });
```

Tables in the publication: `jobs`, `messages`, `notifications`, `payments`,
`time_entries`, `tasks`. Changes are debounced (300 ms) into one invalidation; RLS still
applies to what each subscriber receives.

## UI kit (`@/components/ui`)

Button (`primary|secondary|ghost|danger|money`, `loading`), IconButton (requires
`label`), Input, Textarea, Select, Combobox (async: parent supplies `options`
from a query), Checkbox, Switch, RadioGroup (`list|cards`), MoneyInput (cents),
PhoneInput, DateInput/TimeInput (shop-local strings), SearchInput (debounced),
FormField (label/help/error + aria wiring for any control inside), Card /
CardHeader / CardBody / CardFooter, SectionCard, Badge, StatusBadge (`kind` =
job|quote|invoice|payment|membership|message), Tabs, Table (sortable headers,
stacked rows < md, `rowHref`), Pagination (+ `pageRange` for `.range()`),
Dialog, Drawer, ConfirmDialog, DropdownMenu, Tooltip, Toast (`useToast`),
Avatar, Skeleton, EmptyState, ErrorState, LoadingState, PageHeader,
KeyValueList, SignaturePad (`ref` → `toBlob()` for the `signatures` bucket;
Draw or Type — a typed signature, keyboard-only, is rendered onto the same
canvas and uploads the same PNG; pass `typedDefault` = the signer's name),
FileDropzone (drag-and-drop or pick; `accept` list, `fileMatchesAccept`,
`formatBytes`), QrCode (renders a QR for a URL, PNG / SVG download), CopyField
(read-only value + copy button, e.g. links and embed snippets), CopyLinkDialog
(a link the browser wouldn't copy, kept on screen until closed).

`@/components/customFields`: `CustomFieldInputs` (inputs for a list of custom
field definitions: booking questions, lead forms, customer / job custom data)
and `CustomFieldValues` (read-only display).

Forms: react-hook-form + zod (`zodResolver`) with shared field schemas in
`@/lib/validation` (`zEmail`, `zPhone`, `zOptionalPhone`, `zCents`,
`zPercentBps`, …). Emails use `isValidEmail`, the database's own
`is_valid_email` rule (also the iPhone's and CSV import's), never zod's
stricter `z.email()`: an address the server stores must stay editable.
Links are `text-primary-ink`, never the fill token `text-primary`
(`src/lib/linkColor.test.ts`). Wrap controls in `<FormField label error>`; use
`<Controller>` for MoneyInput/PhoneInput/Combobox.

Class names: `cn(...)` from `@/lib/cn` (clsx + tailwind-merge, token-aware), so a
component's `className` prop overrides its defaults (`cn('px-2', className)`).

Styling: Tailwind utilities over design tokens only (`bg-surface`, `text-ink`,
`text-muted`, `border-line`, `bg-primary`, `bg-money`, `text-success-ink`,
`rounded-card`, `rounded-control`, …) — defined in `src/index.css` for light and
dark. Never hard-code hex colours. Layouts must work at 360 px wide. Calendars
use FullCalendar MIT plugins only (daygrid, timegrid, interaction, list), which
pick up the tokens automatically.

## Shared lib modules added with the parity work

- `@/lib/customFields`: custom field types, limits, zod schemas for
  `custom_data` (`customDataSchema`, `readCustomData`), draft ↔ value
  conversion (`toDraft` / `fromDraft`), validation (`customValueError`) and
  display (`formatCustomValue`). Definitions come from
  `features/settings/data/customFields` (`useCustomFields`, `toFieldDef`).
- `@/lib/qr`: `qrSvg`, `qrPngDataUrl`, `downloadQr` (generated in the
  browser, no service).
- `@/lib/csv`: `toCsv` / `rowsToCsv` / `downloadCsv` with spreadsheet-formula
  neutralising (`csvCell`), `centsCell`, and `stripFormulaGuard` so an
  exported file imports back unchanged.
- `@/lib/download`: `downloadUrl`, `downloadBlob`, `fileStem`.
- `@/lib/env`: `functionsUrl(path)` → absolute edge-function URL (calendar
  feed links people paste into calendar apps).

## Settings

`/app/settings/<section>`; the sections, their sub-nav groups (Business,
Booking, Money, Messages, Data & integrations, Account) and the capability
that guards each one live in `src/features/settings/sections.ts`. Every route
is wrapped in its own `RequireRole capability={section.view}` (routes.tsx);
the sub-nav lists only what the member may open. Most sections are
`settings.view` (managers read, owner/admin edit via `useSettingsAccess`);
Payments and SMS are `shop.connectStripe` / `shop.manageSmsNumber`
(owner/admin), Import & export `import.run` (managers+), Webhooks
`webhooks.manage` (owner/admin), Delete shop `shop.delete` (owner), and
Calendar feed `calendarFeed.own` (everyone — technicians get only that
section, and `/app/settings` sends them there). Settings data hooks live in
`src/features/settings/data/*` (booking links, calendar feed, custom fields,
fees, follow-ups, import/export, lead forms, money settings, SMS
provisioning, webhooks); other features import only `useCustomFields` /
`toFieldDef`, `useShopFees` and the blocked-time helpers
(`blockedTimes.ts`, `schemas.ts`) read-only. Saving follow-up settings or a
template also refreshes the quote / invoice follow-up status cards
(`['shop', id, 'followups']`).

## Booking embed, QR code and tracking tags

- **Embed** (Settings -> Online booking and Settings -> Lead forms show the
  snippets, `src/features/settings/embed.ts`):

  ```html
  <div data-detailcrm-book="<slug>"></div>
  <!-- optional: data-link="<private link token>" | data-lead="<lead form token>" | data-title="…" | data-theme="dark|auto" -->
  <script src="https://<app origin>/embed.js" async></script>
  ```

  `public/embed.js` (vanilla, no dependencies, no cookies) replaces each div
  with an iframe of `/book/<slug>?embed=1` (`&link=<token>`) or
  `/lead/<token>?embed=1` (invalid slugs / tokens get no frame);
  `window.DetailCRMEmbed.init()` picks up divs added later. In embed mode the
  page has no chrome, a transparent background, links that leave it open in
  the top window, and it posts only `{type:'detailcrm:height', height}` and
  `{type:'detailcrm:scroll-top'}` to its parent (`src/features/booking/embed.ts`);
  embed.js applies them only for its own frames and only from the app's
  origin (min 320 px). The embedded page is light whatever the visitor's
  device theme or saved preference (`src/app/embedTheme.ts`, mirrored in the
  `index.html` boot script); `data-theme="dark"` (`&theme=dark`) makes it
  dark and `"auto"` follows the device, and embed.js gives the iframe the
  matching `color-scheme` so the browser paints no opaque canvas behind the
  transparent page. A plain iframe of the same URL (snippet style
  `color-scheme:light`) works without the script. Only `/book/*` and `/lead/*` render inside a frame
  (`src/app/RootLayout.tsx` + `src/app/framing.ts`); the deploy must set
  `WEB_EMBED_PATHS=/book/*,/lead/*` for the headers to allow it
  (docs/DEPLOY.md 4.3). E2E: `e2e/booking-embed.spec.ts` embeds both on a
  page of another origin.

- **QR code**: the booking link card and each lead form offer PNG / SVG
  downloads (`@/lib/qr`).
- **Tracking tags (shop opt-in)**: a shop's own Meta Pixel id / GA4
  measurement id (Settings -> Online booking; `booking_settings`, returned by
  `public_shop_profile.tracking`). `src/features/booking/tracking.ts` loads
  them only on `/book/<slug>` (never private links, lead forms or any other
  page) and only GA4 on `/booking/<token>?paid=1` to report the deposit.
  Events: page view, begin checkout, booking created (value), deposit paid
  (GA4). Never names, emails, phones, coupon codes or tokens: GA4 gets a page
  location without query or token; Meta's history page views and automatic
  configuration are off. While a tag is on, links to token pages are full
  page loads (`PublicLink`), links into the booking page are full loads
  without a referrer (`BookingPageLink`), the footer's legal links leave the
  document (`PublicLayout fullPageLinks`), and leaving the wizard stops the
  tags. The deploy CSP allows the tag origins only on `WEB_TRACKING_PATHS`.
  Keep `src/features/legal/content.tsx` in step with any change here.

## Parity features: where they live

- **Gift cards / store credit** (`features/gift-cards`): staff list + detail
  (`giftCards.view`; issue / redeem `giftCards.manage`, adjust / void
  owner-admin), public shop `/gift/:slug` → Stripe Checkout, order status
  `/gift/:slug/done`. Cards are tender, not discounts: redeeming pays an
  invoice (`RecordPaymentDialog` gift card tab, `/i/:token` code panel).
  Codes are shown once; only the last 4 are stored readable.
- **Tasks** (`features/tasks`, `/app/tasks`): staff reminders; everyone sees
  tasks assigned to or created by them (`tasks.own`), managers all
  (`tasks.manage`). Realtime on `tasks`.
- **Inventory** (`features/inventory`, `/app/inventory`, managers):
  products, stock movements (`record_inventory_movement`), consumables per
  service (catalog), low-stock state; job / service profit in reports.
- **Job reports** (`features/jobs/reportApi.ts` staff side,
  `features/job-report` public `/r/:token`): publish / revoke a customer
  report with chosen photos, videos, inspection and documents (media signed
  by the `public-media` function, refreshed before expiry); remote
  inspection sign-off with a drawn signature.
- **Leads** (`features/leads`, `/lead/:token`): the shop's lead forms
  (Settings -> Lead forms) with custom questions, honeypot and server rate
  limits (`leadSubmitErrorBanner`); submissions create or match customers
  server-side.
- **Calendar events & capacity v2** (`features/calendar`): `EventDialog`
  creates / edits calendar events (kinds, whole shop or one member,
  customer-linked, repeat rules from `features/settings/blockedTimes.ts`;
  "every occurrence" or "this and later" — there is no single-occurrence
  exception); managers open any event from the grid. Bays view
  (`ResourceDayView`): jobs per bay / van, events without a bay once in the
  "No bay / van" column. Capacity per location type, member availability and
  multi-day jobs are booking settings.
- **Routes / day map** (`features/calendar/DayMapView.tsx`, `route.ts`,
  `LeafletMap.tsx`): the day's mobile jobs that start that day, in route
  order (drag or arrows → `set_route_order`), filtered like the grid;
  earlier-started jobs are listed separately; "Open route in Google Maps"
  (from the shop, or the first stop, through up to 10 stops). Map tiles
  from OpenStreetMap (the only map origin in the CSP); coordinates come
  from the iPhone app's geocoder — the browser never geocodes.
- **Recurring jobs** (`features/jobs/series.ts`, `seriesApi.ts`,
  `components/RepeatFields.tsx`): repeat rules on new jobs
  (`create_job_series`), "edit repeat" / "end repeat" for this and following
  visits (`update_job_series` / `end_job_series`; an unchanged monthly rule
  is sent back as it is).
- **Import / export** (Settings -> Import & export, `settings/importing.ts`,
  `settings/data/importExport.ts`): customers + vehicles and services from
  CSV, parsed in the browser (papaparse), column mapping remembered per shop,
  dry run then commit in chunks (`import_customers` / `import_services`,
  resumable through `import_batches`); exports of customers (with their
  custom fields), vehicles and jobs (`export_jobs`) as formula-safe CSV.

## Shop subscription billing (`features/billing`)

The platform's own subscription for shops (SPEC §4.10, docs/BILLING.md).
Nothing about a plan, price, trial or limit is written in the web: all of it
comes from `shop_entitlement(p_shop_id)`, `public_billing_plans()` and the
`billing` edge function.

- **Settings → Billing** (`/app/settings/billing`, section `billing` in
  `settings/sections.ts`, capability `billing.view` = owner/admin/manager;
  `billing.manage` = owner): status from `shop_entitlement` + the
  `shop_billing` status (explicit non-Stripe columns), plan cards from
  `public_billing_plans()`, **Choose plan** → `billing` `checkout` →
  `redirectTo` (Stripe URLs only), **Manage billing** → `portal`. Listed only
  while `billing_enabled`; opened while off it says billing isn't enabled.
  Checkout returns with `?checkout=success` (the status is polled every 2 s
  for at most 60 s, then "Check again") or `?checkout=cancelled`.
- **Banner** (`BillingBanner` in the app shell): owner — trial ending within
  7 days, payment problem (dismissible per session); everyone — lapsed (not
  dismissible). Hidden on the billing page itself.
- **Refusals**: see Data access (kind `subscription`).
- **`/pricing`** (public): the plans, or "Pricing coming soon" without any.
- The notification kind `billing_payment_failed` opens Billing for owners
  (`notifications/links.ts`) and is pushable for owners only.

## Testing

- Unit/component tests live next to the code (`*.test.ts(x)`), run in jsdom with
  `TZ=Pacific/Honolulu` so "browser zone ≠ shop zone" is always exercised.
- `renderRoute(ui, { path, routePath, auth, shop, routes })` from
  `@/test/render` gives a memory router + Query + Toast + Auth/Shop contexts.
- Mock the backend with `vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'))`
  (one shared double — no per-feature copies), call `resetSupabaseMock()` in
  `beforeEach`, then drive:
  - tables: `setTableResult('jobs', { data: [...] })`; assert on `builders.<table>`;
  - RPCs: `mockRpc({ fn: { data } | pgError('PT404', 'quote not found') | (args) => … })`
    (returns the recorded calls) or `supabase.rpc.mockReturnValueOnce(createBuilder({ data }))`;
  - edge functions: `setFunctionResult('payments', { data })`, or per call
    `supabase.functions.invoke.mockResolvedValueOnce({ data: null, error: edgeHttpError(422, { error, code, details: { reason } }) })`;
  - storage: `supabase.storage.from('shop-assets').upload` / `remove` / `createSignedUrl(s)`
    (one mock per bucket, reset with the rest).
- Query by role/label (accessible names), not test ids.
- E2E: `mockSupabase(page, { user, tables, rpc, counts, accounts, functions, storage })` from
  `e2e/support/mockSupabase.ts` intercepts auth, PostgREST, RPC, edge functions
  (`/functions/v1/<name>`, unknown names → 404), storage and realtime. Any
  handler may answer `reply(status, body)` for an error, e.g. an edge refusal
  `reply(422, { error, code: 'unprocessable', details: { reason } })`, the
  gateway's `reply(401, { code: 401, message: 'Invalid JWT' })` or a PostgREST
  `reply(404, { code: 'PT404', message })` — no `page.route` workarounds per spec.
  `PW_PORT` moves the two dev servers (default 5173 and 5174) when those ports
  are taken. Locally Playwright uses the browsers in `PLAYWRIGHT_BROWSERS_PATH`
  (`PW_CHROMIUM_EXECUTABLE` overrides the binary); CI installs Chromium.
