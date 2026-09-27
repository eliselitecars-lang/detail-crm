#!/usr/bin/env bash
# Runs the SQL test suite (supabase/tests/*.sql) against the REAL local
# Supabase database started by scripts/stack/up.sh — real roles (postgres is
# NOT a superuser there), real auth/storage schemas, real extensions — instead
# of the vanilla-Postgres shim used by scripts/test_db.sh.
#
# Only the `tests` helper schema (supabase/shim/30_test_helpers.sql) is
# installed, plus scripts/stack/sql/test_helpers_stack.sql (tests.create_user
# for GoTrue's real auth.users, whose id has no default); the platform parts
# of the shim (roles, auth, storage) are NOT, because the real stack provides
# them. Every file runs inside
# BEGIN ... ROLLBACK exactly like scripts/test_db.sh, so the database is left
# unchanged (apart from the `tests` schema itself).
#
# Usage:
#   scripts/stack/test_db_stack.sh                    # every file, as supabase_admin
#   scripts/stack/test_db_stack.sh --tests '10_*.sql' # a subset
#   scripts/stack/test_db_stack.sh --as postgres      # as the dashboard/migration role
#
# Default role is supabase_admin (the real stack's superuser) because the
# suite assumes it connects as a superuser (the shim's `postgres`): as
# `postgres` — NOT a superuser on Supabase — 00_shim_helpers.sql
# ("as_superuser returns to superuser") and 10_money_races.sql (dblink needs
# a password for non-superusers) fail by design; everything else passes.
#   scripts/stack/test_db_stack.sh --verbose
#
# Env: STACK_SQL_DB_URL  full connection URL override (default
#                        postgresql://<--as role>:postgres@127.0.0.1:54322/postgres).
#                        STACK_DB_URL (stack.env, the `postgres` role) is
#                        deliberately IGNORED: `source scripts/stack/.state/stack.env`
#                        must not silently switch the suite to a non-superuser.
#      PSQL (default: psql on PATH, else /usr/lib/postgresql/*/bin/psql).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_GLOB='*.sql'
VERBOSE=0
ROLE=supabase_admin
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tests) TEST_GLOB="$2"; shift 2 ;;
    --as) ROLE="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

DB_URL="${STACK_SQL_DB_URL:-postgresql://${ROLE}:postgres@127.0.0.1:54322/postgres}"
if [[ -n "${STACK_SQL_DB_URL:-}" ]]; then
  ROLE="$(sed -E 's|^[a-z]+://([^:@/]+).*|\1|' <<<"$STACK_SQL_DB_URL")"
fi
if [[ -z "${PSQL:-}" ]]; then
  if command -v psql >/dev/null 2>&1; then PSQL=psql
  else PSQL="$(ls -d /usr/lib/postgresql/*/bin/psql 2>/dev/null | sort -V | tail -n 1)"; fi
fi
[[ -n "$PSQL" ]] || { echo "psql not found" >&2; exit 2; }
# Real Supabase Storage installs storage.protect_delete() triggers that reject
# plain SQL DELETEs on storage.objects/buckets unless the session sets
# storage.allow_delete_query=true, which is exactly what the Storage API does
# before it runs the DELETE as the caller's role (so storage RLS DELETE
# policies still apply). The suite deletes objects in SQL to prove those
# policies, so emulate the Storage API session here.
export PGOPTIONS="${PGOPTIONS:-} -c storage.allow_delete_query=true"
PSQL_CMD=("$PSQL" -X -q "$DB_URL" -v ON_ERROR_STOP=1)

now_ms() { date +%s%3N; }

# Helpers are (re)installed as the real superuser so any --as role can use
# them (the schema is dropped first: a stale copy may belong to another role).
ADMIN_URL="${STACK_ADMIN_DB_URL:-postgresql://supabase_admin:postgres@127.0.0.1:54322/postgres}"
ADMIN_CMD=("$PSQL" -X -q "$ADMIN_URL" -v ON_ERROR_STOP=1)
echo "installing tests helper schema (supabase/shim/30_test_helpers.sql + stack overlay)"
{
  echo 'set client_min_messages = warning;'
  echo 'drop schema if exists tests cascade;'
  cat "$ROOT/supabase/shim/30_test_helpers.sql" "$ROOT/scripts/stack/sql/test_helpers_stack.sql"
  echo 'grant usage, create on schema tests to postgres;'
  echo 'grant all on all tables in schema tests to postgres;'
  echo 'grant execute on all functions in schema tests to postgres;'
} | "${ADMIN_CMD[@]}" >/dev/null || { echo "could not install test helpers" >&2; exit 1; }

# The suite assumes a FRESH deployment: e.g. 30_app_links.sql asserts that
# platform_config is empty, 30_*.sql insert app_base_url themselves. up.sh
# sets app_base_url for the web/functions, so each file starts by removing
# it inside its own transaction (rolled back afterwards). Other tables must
# be empty too (10_money_security.sql counts ALL stripe_events rows): run
# this suite right after up.sh (db reset), before verify_stack.mjs or
# Playwright add data.
FRESH_DEPLOY_SQL='delete from public.platform_config;'

# Per-file preludes: scripts/stack/sql/prelude/<file>.sql runs inside the
# file's transaction (rolled back with it), right before the file, as the
# runner's role. Only for documented real-platform differences — each prelude
# explains itself (e.g. 00_audit_user_delete.sql: service_role has no DELETE
# on the real auth.users).
PRELUDE_DIR="$ROOT/scripts/stack/sql/prelude"

KNOWN_FILE="$ROOT/scripts/stack/known_sql_failures.txt"
is_known() { [[ "${STACK_STRICT:-0}" != 1 && -f "$KNOWN_FILE" ]] && grep -qE "^$1([[:space:]]|$)" "$KNOWN_FILE"; }

pass=0; fail=0; known=0; assertions=0; failed_files=()
for f in "$ROOT"/supabase/tests/$TEST_GLOB; do
  [[ -f "$f" && "$f" == *.sql ]] || continue
  rel="${f#"$ROOT"/}"
  start=$(now_ms)
  prelude=''
  if [[ -f "$PRELUDE_DIR/$(basename "$f")" ]]; then
    prelude="\\i '$PRELUDE_DIR/$(basename "$f")'"
    [[ $VERBOSE -eq 1 ]] && echo "      prelude: scripts/stack/sql/prelude/$(basename "$f")"
  fi
  quiet='\o /dev/null'
  [[ $VERBOSE -eq 1 ]] && quiet=''
  # psql's \i resolves \ir includes (fixtures/) relative to the file.
  out="$(printf '%s\n' \
    '\set ON_ERROR_STOP 1' \
    'begin;' \
    "$FRESH_DEPLOY_SQL" \
    "$prelude" \
    "$quiet" \
    "\\i '$f'" \
    '\o' \
    'reset role;' \
    '\pset tuples_only on' \
    '\pset format unaligned' \
    "select '@@ASSERTIONS=' || tests.assertion_count();" \
    'rollback;' | "${PSQL_CMD[@]}" 2>&1)"
  rc=$?
  ms=$(( $(now_ms) - start ))
  n="$(grep -o '@@ASSERTIONS=[0-9]*' <<<"$out" | tail -n 1 | cut -d= -f2 || true)"
  base="$(basename "$f")"
  if [[ $rc -eq 0 && -n "$n" && "$n" -gt 0 ]]; then
    pass=$((pass + 1)); assertions=$((assertions + n))
    printf 'PASS  %-48s %5s assertions  %6sms\n' "$rel" "$n" "$ms"
    if is_known "$base"; then echo "      FIXED: remove $base from scripts/stack/known_sql_failures.txt"; fi
  elif is_known "$base"; then
    known=$((known + 1))
    printf 'KNOWN %-48s %6sms  (scripts/stack/known_sql_failures.txt)\n' "$rel" "$ms"
    grep -v '@@ASSERTIONS=' <<<"$out" | sed 's/^/      /' | head -n 4 || true
  else
    fail=$((fail + 1)); failed_files+=("$rel")
    printf 'FAIL  %-48s %6sms\n' "$rel" "$ms"
    grep -v '@@ASSERTIONS=' <<<"$out" | sed 's/^/      /' | head -n 30 || true
  fi
done
echo "----"
echo "real stack ($ROLE): files: $pass passed, $fail failed, $known known; assertions passed: $assertions"
if [[ $fail -gt 0 ]]; then printf 'failed: %s\n' "${failed_files[@]}"; exit 1; fi
