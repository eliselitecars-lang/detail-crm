#!/usr/bin/env bash
# Stops everything scripts/stack/up.sh started: `supabase functions serve`,
# stripe-mock, the Twilio/Resend mock and the Supabase containers.
#
#   scripts/stack/down.sh            stop; the database volume is deleted (no backup)
#   scripts/stack/down.sh --keep-db  stop but keep the database volume
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="$ROOT/scripts/stack/.state"
KEEP_DB=0
[[ "${1:-}" == "--keep-db" ]] && KEEP_DB=1

log() { printf '\033[1m[stack]\033[0m %s\n' "$*"; }

stop_pid() { # name pidfile
  local pid
  [[ -f "$2" ]] || return 0
  pid="$(cat "$2")"
  if kill -0 "$pid" 2>/dev/null; then
    log "stopping $1 (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$2"
}

stop_pid "functions serve" "$STATE/functions.pid"
stop_pid "stripe-mock" "$STATE/stripe-mock.pid"
stop_pid "provider mock" "$STATE/provider-mock.pid"

SUPABASE="${SUPABASE_BIN:-}"
if [[ -z "$SUPABASE" ]]; then
  SUPABASE="$(command -v supabase || true)"
  for c in "$ROOT/scripts/stack/.cache/bin/supabase" /tmp/claude-*/*/*/scratchpad/stack-cache/bin/supabase; do
    [[ -z "$SUPABASE" && -x "$c" ]] && SUPABASE="$c"
  done
fi
if [[ -n "$SUPABASE" ]]; then
  cd "$ROOT"
  if [[ $KEEP_DB -eq 1 ]]; then
    log "supabase stop (database volume kept)"
    "$SUPABASE" stop
  else
    log "supabase stop --no-backup"
    "$SUPABASE" stop --no-backup
  fi
else
  log "supabase CLI not found; skipping supabase stop"
fi
rm -f "$ROOT/supabase/functions/.env.stack" "$ROOT/supabase/functions/.stack-ca.pem" \
  "$STATE/stack.env" "$STATE/status.env"
log "stack is down"
