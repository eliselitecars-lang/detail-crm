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

| Variable                 | Meaning                     |
| ------------------------ | --------------------------- |
| `VITE_SUPABASE_URL`      | `https://<ref>.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | the **anon** public key     |

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
`/invite/:token`, `/book/:slug`, `/booking/:token`, `/q/:token`, `/i/:token`,
`/f/:token`, `/portal`, `/app` (dashboard), `/app/{calendar,jobs,customers,
quotes,invoices,payments,memberships,messages,campaigns,reports,team,timesheets,
catalog,settings,notifications}`, `/app/onboarding`.

## Auth & tenancy

- `useAuth()` (`@/features/auth/authContext`) → `{ status, user, session, signOut }`.
- `useShop()` (`@/features/shop/shopContext`) — only under staff routes →
  `{ shop, shopId, role, memberId, timezone, currency, techsCanCollectPayments,
permissions, memberships, switchShop }`. `memberId` is `shop_members.id`
  (use it for assignments / time entries).
- The last-used shop is remembered per user in localStorage; switching shops
  keeps caches separate because every tenant query key contains the shop id.

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
  Edge function errors: `await edgeFunctionError(error)`.
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
- Show feedback with `useToast()` (`toast.success('Saved')`, `toast.error(err)`).

### Realtime

```ts
useRealtime({ table: 'jobs', shopId }); // invalidates shopKey(shopId, 'jobs')
useRealtime({ table: 'messages', shopId, invalidate: [msgKeys.thread(shopId, id)], onChange });
```

Tables in the publication: `jobs`, `messages`, `notifications`, `payments`,
`time_entries`. Changes are debounced (300 ms) into one invalidation; RLS still
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
KeyValueList, SignaturePad (`ref` → `toBlob()` for the `signatures` bucket).

Forms: react-hook-form + zod (`zodResolver`) with shared field schemas in
`@/lib/validation` (`zEmail`, `zPhone`, `zOptionalPhone`, `zCents`,
`zPercentBps`, …). Wrap controls in `<FormField label error>`; use
`<Controller>` for MoneyInput/PhoneInput/Combobox.

Styling: Tailwind utilities over design tokens only (`bg-surface`, `text-ink`,
`text-muted`, `border-line`, `bg-primary`, `bg-money`, `text-success-ink`,
`rounded-card`, `rounded-control`, …) — defined in `src/index.css` for light and
dark. Never hard-code hex colours. Layouts must work at 360 px wide. Calendars
use FullCalendar MIT plugins only (daygrid, timegrid, interaction, list), which
pick up the tokens automatically.

## Testing

- Unit/component tests live next to the code (`*.test.ts(x)`), run in jsdom with
  `TZ=Pacific/Honolulu` so "browser zone ≠ shop zone" is always exercised.
- `renderRoute(ui, { path, routePath, auth, shop, routes })` from
  `@/test/render` gives a memory router + Query + Toast + Auth/Shop contexts.
- Mock the backend with `vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'))`,
  then drive `supabase.auth.*`, `supabase.rpc.mockReturnValueOnce(createBuilder({ data }))`
  and `setTableResult('jobs', { data: [...] })`; assert on `builders.<table>`.
- Query by role/label (accessible names), not test ids.
- E2E: `mockSupabase(page, { user, tables, rpc, counts, accounts })` from
  `e2e/support/mockSupabase.ts` intercepts auth, PostgREST, RPC and realtime.
  Locally Playwright uses the browsers in `PLAYWRIGHT_BROWSERS_PATH`
  (`PW_CHROMIUM_EXECUTABLE` overrides the binary); CI installs Chromium.
