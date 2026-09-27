#!/usr/bin/env bash
# Detail CRM database test runner.
#
# Spins up a throwaway Postgres cluster (private temp dir, unix socket only —
# no TCP port, so any number of copies can run concurrently), applies the
# local Supabase shim, then every migration in lexical order (each in its own
# transaction, like `supabase db push`), then runs each SQL test file inside
# a transaction that is ROLLED BACK, so files are fully independent.
#
# Usage: scripts/test_db.sh [--ranges 0001-0009,0020-0029] [--tests 'glob']
#                           [--keep] [--verbose]
#   --ranges   only apply migrations whose 4-digit prefix is in the ranges
#              (comma-separated; single numbers allowed). Default: all.
#   --tests    glob relative to supabase/tests (default '*.sql');
#              use --tests none to only apply migrations.
#   --keep     leave the cluster running and print how to connect.
#   --verbose  print psql output for passing files too.
# Test files must not COMMIT/ROLLBACK themselves and must make at least one
# tests.* assertion; see supabase/tests/README.md.
# Env: PG_BIN overrides the Postgres bin dir (default: newest
#      /usr/lib/postgresql/*/bin, else whatever is on PATH).
#      DB_TMPDIR overrides the parent dir of the cluster (default /tmp; keep it
#      short — unix socket paths are limited to ~100 bytes).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RANGES=""
TEST_GLOB="*.sql"
KEEP=0
VERBOSE=0

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ranges) RANGES="${2:?--ranges needs a value}"; shift 2 ;;
    --ranges=*) RANGES="${1#*=}"; shift ;;
    --tests) TEST_GLOB="${2:?--tests needs a value}"; shift 2 ;;
    --tests=*) TEST_GLOB="${1#*=}"; shift ;;
    --keep) KEEP=1; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- binaries
if [[ -z "${PG_BIN:-}" ]]; then
  PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -z "$PG_BIN" ]]; then
    PG_BIN="$(dirname "$(command -v initdb 2>/dev/null || echo /usr/bin/initdb)")"
  fi
fi
for b in initdb pg_ctl psql; do
  if [[ ! -x "$PG_BIN/$b" ]]; then
    echo "error: $PG_BIN/$b not found (set PG_BIN)" >&2
    exit 2
  fi
done

# Postgres refuses to run as root: when root, run server-side commands as the
# postgres OS user. psql itself runs as the invoking user.
AS_PG=()
if [[ "$(id -u)" -eq 0 ]]; then
  if ! id postgres >/dev/null 2>&1; then
    echo "error: running as root but there is no 'postgres' OS user" >&2
    exit 2
  fi
  AS_PG=(runuser -u postgres --)
fi

now_ms() { # milliseconds since epoch (GNU date %N, else whole seconds)
  local t
  t="$(date +%s%N 2>/dev/null)"
  if [[ "$t" =~ ^[0-9]+$ && ${#t} -gt 12 ]]; then echo $((t / 1000000)); else echo $(( $(date +%s) * 1000 )); fi
}

# ------------------------------------------------------------- range filter
in_ranges() { # $1 = 4-digit prefix
  [[ -z "$RANGES" ]] && return 0
  local n=$((10#$1)) part lo hi
  IFS=',' read -r -a parts <<<"$RANGES"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" == *-* ]]; then lo="${part%-*}"; hi="${part#*-}"; else lo="$part"; hi="$part"; fi
    if ! [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]]; then
      echo "error: bad --ranges entry '$part'" >&2; exit 2
    fi
    if (( n >= 10#$lo && n <= 10#$hi )); then return 0; fi
  done
  return 1
}

# ----------------------------------------------------------------- cluster
WORK="$(mktemp -d "${DB_TMPDIR:-/tmp}/dcrm-db.XXXXXX")"
PGDATA="$WORK/data"
PORT=5432 # socket-only; the port just names the socket file inside $WORK
if [[ ${#AS_PG[@]} -gt 0 ]]; then chown postgres: "$WORK"; fi
chmod 700 "$WORK"

cleanup() {
  local rc=$?
  if [[ $KEEP -eq 1 ]]; then
    exit $rc
  fi
  "${AS_PG[@]}" "$PG_BIN/pg_ctl" -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

"${AS_PG[@]}" "$PG_BIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 \
  --no-locale --no-sync >"$WORK/initdb.log" 2>&1 || { cat "$WORK/initdb.log" >&2; exit 1; }

"${AS_PG[@]}" "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$WORK/server.log" -w -t 60 \
  -o "-c listen_addresses='' -k $WORK -p $PORT -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c timezone=UTC -c max_connections=20" \
  start >/dev/null || { cat "$WORK/server.log" >&2; exit 1; }

PSQL=("$PG_BIN/psql" -X -q -h "$WORK" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1)

run_sql_file() { # $1 = file, applied in a single transaction
  local out
  if ! out="$("${PSQL[@]}" --single-transaction -f "$1" 2>&1)"; then
    echo "FAIL applying ${1#"$ROOT"/}" >&2
    echo "$out" >&2
    exit 1
  fi
  if [[ $VERBOSE -eq 1 && -n "$out" ]]; then echo "$out"; fi
}

# ------------------------------------------------------ shim + migrations
shopt -s nullglob
for f in "$ROOT"/supabase/shim/*.sql; do run_sql_file "$f"; done

applied=0
for f in "$ROOT"/supabase/migrations/*.sql; do
  base="$(basename "$f")"
  prefix="${base:0:4}"
  if ! [[ "$prefix" =~ ^[0-9]{4}$ ]]; then
    echo "error: migration $base does not start with a 4-digit number" >&2; exit 1
  fi
  in_ranges "$prefix" || continue
  run_sql_file "$f"
  applied=$((applied + 1))
done
echo "applied shim + $applied migration(s)"

# -------------------------------------------------------------------- tests
pass=0
fail=0
assertions=0
failed_files=()
if [[ "$TEST_GLOB" != "none" ]]; then
  files=("$ROOT"/supabase/tests/$TEST_GLOB)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "error: no test files match supabase/tests/$TEST_GLOB" >&2
    exit 1
  fi
  for f in "${files[@]}"; do
    [[ "$f" == *.sql ]] || continue
    rel="${f#"$ROOT"/}"
    start=$(now_ms)
    set +e
    quiet='\o /dev/null'
    [[ $VERBOSE -eq 1 ]] && quiet=''
    out="$(printf '%s\n' \
      '\set ON_ERROR_STOP 1' \
      'begin;' \
      "$quiet" \
      "\\i '$f'" \
      '\o' \
      'reset role;' \
      '\pset tuples_only on' \
      '\pset format unaligned' \
      "select '@@ASSERTIONS=' || tests.assertion_count();" \
      'rollback;' | "${PSQL[@]}" 2>&1)"
    rc=$?
    set -e
    ms=$(( $(now_ms) - start ))
    n="$(grep -o '@@ASSERTIONS=[0-9]*' <<<"$out" | tail -n 1 | cut -d= -f2 || true)"
    if [[ $rc -eq 0 && -n "$n" && "$n" -eq 0 ]]; then
      fail=$((fail + 1)); failed_files+=("$rel")
      printf 'FAIL  %-48s %6sms  (no assertions ran)\n' "$rel" "$ms"
    elif [[ $rc -eq 0 && -n "$n" ]]; then
      pass=$((pass + 1)); assertions=$((assertions + n))
      printf 'PASS  %-48s %5s assertions  %6sms\n' "$rel" "$n" "$ms"
      if [[ $VERBOSE -eq 1 ]]; then grep -v '@@ASSERTIONS=' <<<"$out" || true; fi
    else
      fail=$((fail + 1)); failed_files+=("$rel")
      printf 'FAIL  %-48s %6sms\n' "$rel" "$ms"
      grep -v '@@ASSERTIONS=' <<<"$out" | sed 's/^/      /' || true
    fi
  done
fi

echo "----"
echo "files: $pass passed, $fail failed; assertions passed: $assertions"
if [[ $KEEP -eq 1 ]]; then
  echo "cluster kept running. connect with:"
  echo "  $PG_BIN/psql -h $WORK -p $PORT -U postgres -d postgres"
  echo "stop with:"
  echo "  ${AS_PG[*]} $PG_BIN/pg_ctl -D $PGDATA stop && rm -rf $WORK"
fi
if [[ $fail -gt 0 ]]; then
  printf 'failed: %s\n' "${failed_files[@]}"
  exit 1
fi
