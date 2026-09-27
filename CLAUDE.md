# CLAUDE.md — Detail CRM (source of truth)

Multi-tenant CRM for detailing / coating / tint / PPF shops: a from-scratch,
capability-equivalent alternative to Urable (never copy Urable branding,
copy, or visuals). Web app + iPhone app on one Supabase database.
**docs/SPEC.md is the product & architecture contract; docs/SCHEMA.md is the
column-level contract.** Read the relevant sections before changing anything.

## Layout
- `supabase/migrations/` numbered SQL (ranges in SPEC §9) · `supabase/tests/`
  SQL tests · `supabase/shim/` local Supabase compatibility shim ·
  `supabase/functions/` Deno edge functions (`_shared/` helpers)
- `web/` Vite + React + TS strict; features in `web/src/features/<name>/`
- `ios/DetailCRM/` SwiftUI app (hand-written pbxproj, synchronized groups);
  `ios/DetailCore/` Swift package (pure logic + XCTest)
- `scripts/` test runners, generators, contract checkers

## Non-negotiables
- Every tenant table has `shop_id` and RLS enabled; roles owner/admin/manager/
  technician per SPEC §3 matrix, enforced server-side (RLS/RPC/edge), never
  only in UI. Clients & anonymous users touch data only via `portal_*` /
  `public_*` SECURITY DEFINER RPCs (`set search_path = ''`, curated columns).
- Money = integer cents; totals/tax/balances computed server-side per SPEC
  §4.5; clients never send totals or prices for public flows; tips never
  change balances.
- Card data stays in Stripe (ids, brand, last4 only). Card payment rows are
  written only by service_role (edge functions / webhook).
- Secrets only in Supabase function env / GitHub secrets — never in the repo.
- No invented pricing or fake data in UI or seeds (seeded defaults are names
  and generic template wording only).

## Verification (run before every commit that touches the area)
- DB: `scripts/test_db.sh` (real Postgres 16 + shim, all migrations from zero + tests)
- Contracts: `python3 scripts/gen_types.py && python3 scripts/check_contracts.py`
- Functions: `scripts/test_functions.sh` (deno check + deno test)
- Web: `cd web && npm run check` (tsc, eslint, vitest, build)
- iOS: GitHub Actions `ios.yml` (macOS xcodebuild + `swift test`). macOS
  minutes are expensive on private repos — batch iOS changes, don't push
  one-line fixes just to re-run CI.

## Swift traps (learned the hard way)
No types nested in generic functions; no state-driven safeAreaInset +
preference loops; no negative frames; don't `if`-gate views you animate;
split giant view bodies with AnyView seams at section boundaries (deep
generic metadata stack-overflows at runtime); AnyJSON needs `import Supabase`;
PostgREST has no `.not(in:)` — chain `.neq`.

## Git
Development branch `claude/build-v1`; `main` holds reviewed milestones.
Commits end with the Co-Authored-By + Claude-Session trailers.
