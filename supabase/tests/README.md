# SQL test suite

Plain SQL files run by `scripts/test_db.sh` against a throwaway Postgres
cluster with the local Supabase shim (`supabase/shim/`) and every migration
applied from zero.

```bash
scripts/test_db.sh                                   # everything
scripts/test_db.sh --tests '00_*.sql'                # a subset of files
scripts/test_db.sh --ranges 0001-0009 --tests '00_*' # only some migrations
scripts/test_db.sh --tests none --keep               # migrate, keep cluster, print psql command
scripts/test_db.sh --verbose                         # show psql output of passing files too
```

The runner auto-detects the newest `/usr/lib/postgresql/*/bin` (override with
`PG_BIN=...`), runs server binaries as the `postgres` OS user when invoked as
root, uses a private temp dir with a unix socket only (no TCP port) so many
copies can run at once, and always removes the cluster unless `--keep`.

## How a file runs

Each file is executed by psql with `ON_ERROR_STOP=1` inside
`BEGIN; ... ROLLBACK;`, so:

* files are independent — nothing a file creates survives it;
* a file must **not** `COMMIT`/`ROLLBACK` itself (savepoints are fine);
* the first failing statement or assertion stops the file and marks it FAIL;
* a file that makes no `tests.*` assertion is reported as FAIL.

The runner prints `PASS`/`FAIL` per file with its assertion count, then a
total, and exits non-zero on any failure. Query output is discarded unless
`--verbose`; errors and notices are always shown for failing files.

Because everything happens in one transaction, `now()` is constant for the
whole file. Deferred constraint triggers never fire on their own (the
transaction never commits); force them with `set constraints <name> immediate`.

## File prefixes

| Prefix | Domain |
|---|---|
| `00_` | foundation: shim, tenancy, shop setup, CRM, catalog, jobs, totals, scheduling, schema-wide security invariants |
| `10_` | money (quotes, invoices, payments, memberships) |
| `20_` | field operations (checklists, inspections, photos, forms, time clock, storage) |
| `30_` | communication (templates, messages, automations, campaigns, notifications) |
| `40_` | integration flows (online booking, portal, public RPCs) |
| `45_` | reports |
| `90_` | cross-cutting hardening and integration (0090–0099) |

## Helpers (schema `tests`, defined in `supabase/shim/30_test_helpers.sql`)

### Assertions — each passing call counts one assertion; failures `RAISE 'FAIL: ...'`

| Helper | Meaning |
|---|---|
| `tests.ok(bool, msg)` | condition must be `true` (NULL fails) |
| `tests.eq(got, expected, msg)` | `IS NOT DISTINCT FROM`; arguments are `anycompatible` (int vs bigint is fine; cast literals like `1::bigint` when comparing to `count(*)` for clarity) |
| `tests.throws(sql, sqlstate default null, msg default null)` | `sql` (run as the **current** role) must raise; if `sqlstate` is given it must match |
| `tests.throws_like(sql, sqlstate, pattern, msg default null)` | as above and the message must match `ILIKE pattern` (use to prove *why* it failed) |
| `tests.lives(sql, msg default null)` | `sql` must not raise |
| `tests.row_count(sql) → bigint` | rows returned (SELECT) or affected (INSERT/UPDATE/DELETE) — not an assertion by itself; wrap in `tests.eq` |

Useful SQLSTATEs: `42501` insufficient privilege / RLS `WITH CHECK` violation /
RPC permission denial; `23514` check or business-rule violation; `23503`
foreign key (e.g. composite-FK cross-shop injection); `23505` unique;
`23P01` exclusion; `22023` invalid argument; `P0002` not found (staff and
internal RPCs); `PT404` not found in a public (anon) RPC — every `public_*`
function, `get_available_slots` and `create_online_booking` raise it for an
unknown slug / token / document so PostgREST answers HTTP 404 instead of 500
(see the 0042 header); `55000` feature not enabled (e.g. online booking off);
`428C9` writing a generated column; `40001` a compare-and-set lost a race
(e.g. `set_stripe_refund_total`).

**RLS semantics to remember:** `SELECT`/`UPDATE`/`DELETE` on rows you cannot
see silently affect 0 rows (assert with `tests.row_count(...) = 0`), while
`INSERT` (or an `UPDATE` whose new row fails `WITH CHECK`) raises `42501`.

### Identity

| Helper | Effect (transaction-local) |
|---|---|
| `tests.create_user(email, confirmed default true, meta jsonb default '{}') → uuid` | inserts `auth.users` with every column GoTrue's admin API sets (explicit `id`, `aud`/`role` `authenticated`, `instance_id` 00000000-…, provider metadata), so it also works on a real Supabase database; the profile is created by the app trigger; `meta` becomes `raw_user_meta_data` |
| `tests.user_id(email) → uuid` | look up a user |
| `tests.authenticate_as(user_id)` | `role authenticated` + `request.jwt.claims` {sub, email, role, aud, is_anonymous, app/user_metadata} — `auth.uid()`, `auth.email()`, `auth.jwt()` behave as on Supabase |
| `tests.as_anon()` | `role anon`, claims `{"role":"anon"}` |
| `tests.as_service()` | `role service_role` (BYPASSRLS) |
| `tests.as_superuser()` / `tests.reset()` | back to the connecting superuser, no claims |

Superusers bypass RLS: **always switch to `authenticated`/`anon`/`service_role`
before asserting anything about access control.** SECURITY DEFINER RPCs run as
their owner, so guard triggers treat them as trusted; direct table writes as
`authenticated` are "client context".

### Fixtures

| Helper | Effect |
|---|---|
| `tests.fx_set(key, uuid) → uuid` / `tests.fx(key) → uuid` | per-file registry (`tests.fixtures`), readable from every role, so dynamic SQL can say `tests.fx('shop_b')` |
| `tests.make_shop(owner_email, slug default derived, name default derived, timezone default 'America/Chicago') → shop id` | creates/reuses a confirmed owner and calls the real `public.create_shop` as that user, so every domain's `AFTER INSERT ON shops` seeding runs; restores the caller's claims |
| `tests.add_member(shop_id, email, role text, active default true) → shop_members.id` | creates/reuses a confirmed user and inserts the membership directly (bypassing invites) |

`make_shop`/`add_member` are plpgsql defined in the shim (applied before
migrations); their bodies resolve application objects at call time, so they
need migrations `0001-0002` applied.

`supabase/tests/fixtures/two_shops.psql` (include with
`\ir fixtures/two_shops.psql`) builds two shops (`shop_a`, `shop_b`, slugs
`shop-a`/`shop-b`, America/Chicago) with an owner, admin, manager and
technician each (`u_*` user ids, `m_*` member ids, plus `u_tech2_a`,
`u_outsider`), a category/service/price, resources, coupons, customers,
vehicles, jobs, line items and assignments — see the header of that file for
every key. Files under `fixtures/` are not run as tests.

## Conventions

### Portable on a real / shared database

The same files also run against a real local Supabase stack
(`scripts/stack/test_db_stack.sh`), whose database is shared and already
holds data. So a file must pass on a non-empty database, and twice in a row:

* never assume a global table is empty — scope counts to the file's own
  shops / ids (`where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))`,
  `where id like 'evt_sec%'`), or reset the shared state explicitly inside
  the file's own transaction (it is rolled back): `two_shops.psql` deletes
  `platform_config.app_base_url`, the storage purge tests empty the global
  purge queue first;
* seed global rows with upserts: `insert into public.platform_config … on
  conflict (key) do update set value = excluded.value`;
* real Storage refuses direct `delete from storage.objects` unless
  `storage.allow_delete_query` is on, as the Storage API sets it: run
  `select set_config('storage.allow_delete_query', 'true', true);` right
  before each direct delete (transaction-local; harmless on the shim);
* auth accounts are deleted as the superuser (`tests.as_superuser()`), like
  the GoTrue admin API (`supabase_auth_admin`) — `service_role` has no
  privileges on `auth.users`, on Supabase or in the shim;
* assertions that need a superuser connection (the dblink race files, the
  shim's own superuser check) are gated:
  `select rolsuper as is_superuser from pg_roles where rolname = current_user \gset`
  then `\if :is_superuser … \else \echo SKIP (needs superuser) … \endif`.

* Cover the happy path, the denial path for every role, and cross-shop
  isolation for every table and RPC you add; prove composite FKs reject
  another shop's parent ids (`23503`).
* Time-dependent functions take an optional `p_now timestamptz default now()`;
  tests pass fixed timestamps. Use past dates for DST cases (tz rules for
  past dates never change).
* `00_security_invariants.sql` loops over **every** table and function in
  `public`: RLS on, anon has no direct access, users of one shop cannot read,
  update or delete another shop's rows, tenant tables expose
  `UNIQUE (shop_id, id)`, tenant-to-tenant FKs include `shop_id`, SECURITY
  DEFINER functions pin `search_path = ''`, and anon may only execute
  `public_*` / booking entry points. New domains get these checks for free —
  if one fails after you add a table, fix the table, not the test.

## Contract files (SPEC §8.2)

Any migration change also changes the generated contract, so after the SQL
suite passes run:

```bash
python3 scripts/gen_types.py        # rewrites web/src/lib/database.types.ts + docs/SCHEMA.md
python3 scripts/check_contracts.py  # fails on stale generated files or any drifted reference
python3 scripts/check_contracts.py --self-test
```

Both build the schema the same way as this runner (`scripts/test_db.sh --tests
none --keep` on a throwaway cluster, always removed afterwards) and need
`web/node_modules` (prettier formats the TypeScript exactly as committed).
`gen_types.py --check` only compares the generated files. `check_contracts.py`
scans `web/src`, `supabase/functions` and `ios/` for `.from(...)` chains
(columns in selects, embeds, filters, payload keys), `.rpc(...)` names and
argument names, storage buckets, `functions.invoke(...)` targets, Swift
`// table:` / `// rpc:` models (CodingKeys, `selectColumns`) and Swift
`String` enums that mirror Postgres enums; app surfaces are also checked
against the `authenticated` grants. Names built at run time are listed with
`--verbose` instead of being counted as verified.
