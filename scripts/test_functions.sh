#!/usr/bin/env bash
# Edge-function quality gate (SPEC section 8.3): deno fmt --check, deno lint,
# deno check on every .ts file, and deno test with Stripe/Twilio/Resend/
# Supabase faked. Tests get NO network permission, so a missing fake can
# never fall through to a real API.
#
# Deno resolution: $DENO, then `deno` on PATH, then a Deno installed under a
# Claude Code scratchpad (tools/node_modules/.bin/deno).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS_DIR="$ROOT/supabase/functions"

resolve_deno() {
  if [[ -n "${DENO:-}" ]]; then
    if [[ -x "$DENO" ]] || command -v "$DENO" >/dev/null 2>&1; then
      echo "$DENO"
      return 0
    fi
    echo "DENO is set to '$DENO' but it is not executable" >&2
    return 1
  fi
  if command -v deno >/dev/null 2>&1; then
    command -v deno
    return 0
  fi
  local candidate
  for candidate in /tmp/claude-*/*/*/scratchpad/tools/node_modules/.bin/deno; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "deno not found: install Deno 2 (https://deno.com) or set DENO=/path/to/deno" >&2
  return 1
}

DENO_BIN="$(resolve_deno)"
version="$("$DENO_BIN" --version | head -n 1)"
case "$version" in
  "deno 2."*) ;;
  *)
    echo "Deno 2.x is required (found: $version)" >&2
    exit 1
    ;;
esac
echo "Using $version ($DENO_BIN)"

cd "$FUNCTIONS_DIR"
export NO_COLOR=1

step() { printf '\n==> %s\n' "$*"; }

step "deno fmt --check"
"$DENO_BIN" fmt --check

step "deno lint"
"$DENO_BIN" lint

step "deno check (every .ts under supabase/functions)"
mapfile -t ts_files < <(find . -name '*.ts' -not -path '*/node_modules/*' | LC_ALL=C sort)
if [[ ${#ts_files[@]} -eq 0 ]]; then
  echo "no TypeScript files found under $FUNCTIONS_DIR" >&2
  exit 1
fi
"$DENO_BIN" check "${ts_files[@]}"

step "deno test"
# --allow-read=.. lets config_test.ts read supabase/config.toml; --allow-env
# covers Env's Deno.env source. No --allow-net: all HTTP goes through fakes.
"$DENO_BIN" test --allow-env --allow-read=.. --no-prompt

step "all edge function checks passed"
