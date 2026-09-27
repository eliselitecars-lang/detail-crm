#!/usr/bin/env bash
# Starts the REAL local Supabase stack for Detail CRM plus local provider
# simulators, idempotently. LOCAL / CI ONLY — see scripts/stack/README.md.
#
#   1. supabase start (Postgres 17, GoTrue, PostgREST, Realtime, Storage,
#      Kong, mailpit, edge runtime) — studio, postgres-meta, imgproxy, vector,
#      logflare and supavisor are excluded.
#   2. supabase db reset — applies EVERY migration from zero through the real
#      migration path (skip with STACK_SKIP_RESET=1).
#   3. Local platform setup: app_base_url (public.set_app_base_url) and the
#      pg_cron / pg_net extensions (scripts/stack/sql/setup_local.sql).
#   4. stripe-mock on :12111 (Stripe API simulator).
#   5. scripts/stack/provider_mock.mjs on :12120 (Twilio + Resend simulator
#      that records every request to scripts/stack/.state/provider-requests.json).
#   6. supabase/functions/.env.stack (git-ignored) with test secrets + API
#      base overrides, then `supabase functions serve --env-file …` in the
#      background.
#   7. scripts/stack/.state/stack.env — API URL, keys, ports for test suites
#      (source it, or read it from Playwright/Node).
#
# Env knobs:
#   SUPABASE_BIN / STRIPE_MOCK_BIN   binaries (default: PATH, then the Claude
#                                    scratchpad stack-cache/bin)
#   STACK_SKIP_RESET=1               keep the current database (no db reset)
#   STACK_SKIP_FUNCTIONS=1           do not start `functions serve`
#   STACK_DOWNLOAD=1                 download missing supabase / stripe-mock
#                                    binaries from GitHub releases into
#                                    $STACK_CACHE_DIR/bin
#   STACK_CACHE_DIR                  download cache (default scripts/stack/.cache)
#   STACK_APP_URL                    web origin (default http://127.0.0.1:5173)
#   STACK_EXTRA_CA_FILE              extra CA bundle the edge runtime must trust
#                                    (TLS-intercepting proxies; defaults to
#                                    $DENO_CERT when set). Copied to
#                                    supabase/functions/.stack-ca.pem (git-ignored)
#                                    because the runtime container only mounts
#                                    supabase/functions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK_DIR="$ROOT/scripts/stack"
STATE="$STACK_DIR/.state"
mkdir -p "$STATE"
cd "$ROOT"

SUPABASE_CLI_VERSION="${SUPABASE_CLI_VERSION:-2.118.0}"
STRIPE_MOCK_VERSION="${STRIPE_MOCK_VERSION:-0.205.0}"
STACK_CACHE_DIR="${STACK_CACHE_DIR:-$STACK_DIR/.cache}"
APP_URL="${STACK_APP_URL:-http://127.0.0.1:5173}"
STRIPE_MOCK_PORT=12111
STRIPE_MOCK_HTTPS_PORT=12112
PROVIDER_MOCK_PORT=12120
EXCLUDE="studio,postgres-meta,imgproxy,vector,logflare,supavisor"
ENV_FILE="$ROOT/supabase/functions/.env.stack"

log() { printf '\033[1m[stack]\033[0m %s\n' "$*"; }
die() { printf '[stack] ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ tools
find_bin() { # name env-var-value
  local name="$1" override="${2:-}" c
  if [[ -n "$override" ]]; then [[ -x "$override" ]] && { echo "$override"; return 0; }; die "$name not executable: $override"; fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  for c in "$STACK_CACHE_DIR/bin/$name" /tmp/claude-*/*/*/scratchpad/stack-cache/bin/"$name"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

download() { # name
  mkdir -p "$STACK_CACHE_DIR/bin"
  case "$1" in
    supabase)
      log "downloading supabase CLI v$SUPABASE_CLI_VERSION"
      curl -fsSL "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_linux_amd64.tar.gz" \
        | tar -xz -C "$STACK_CACHE_DIR/bin" supabase ;;
    stripe-mock)
      log "downloading stripe-mock v$STRIPE_MOCK_VERSION"
      curl -fsSL "https://github.com/stripe/stripe-mock/releases/download/v${STRIPE_MOCK_VERSION}/stripe-mock_${STRIPE_MOCK_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C "$STACK_CACHE_DIR/bin" stripe-mock ;;
  esac
  echo "$STACK_CACHE_DIR/bin/$1"
}

SUPABASE="$(find_bin supabase "${SUPABASE_BIN:-}" || true)"
[[ -z "$SUPABASE" && "${STACK_DOWNLOAD:-0}" == 1 ]] && SUPABASE="$(download supabase | tail -n 1)"
[[ -n "$SUPABASE" ]] || die "supabase CLI not found (install it, set SUPABASE_BIN, or STACK_DOWNLOAD=1)"
STRIPE_MOCK="$(find_bin stripe-mock "${STRIPE_MOCK_BIN:-}" || true)"
[[ -z "$STRIPE_MOCK" && "${STACK_DOWNLOAD:-0}" == 1 ]] && STRIPE_MOCK="$(download stripe-mock | tail -n 1)"
[[ -n "$STRIPE_MOCK" ]] || die "stripe-mock not found (set STRIPE_MOCK_BIN or STACK_DOWNLOAD=1)"
command -v node >/dev/null 2>&1 || die "node (22+) is required for the provider mock"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
log "supabase $("$SUPABASE" --version) · stripe-mock $("$STRIPE_MOCK" -version 2>&1 | awk '{print $2}')"

pid_alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
wait_for() { # description seconds command...
  local what="$1" secs="$2"; shift 2
  local i
  for ((i = 0; i < secs; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  die "timed out after ${secs}s waiting for $what"
}

# --------------------------------------------------------------- supabase
if "$SUPABASE" status >/dev/null 2>&1; then
  log "supabase stack already running"
else
  log "supabase start -x $EXCLUDE"
  "$SUPABASE" start -x "$EXCLUDE"
fi

if [[ "${STACK_SKIP_RESET:-0}" != 1 ]]; then
  log "supabase db reset (all migrations from zero)"
  "$SUPABASE" db reset --local --no-seed 2>&1 | tee "$STATE/db-reset.log"
  grep -qiE '^(error|failed)|ERROR:' "$STATE/db-reset.log" && die "db reset reported errors (see $STATE/db-reset.log)"
fi

# `supabase status -o env` prints KEY="value" lines.
"$SUPABASE" status -o env > "$STATE/status.env" 2>/dev/null || die "supabase status failed"
# shellcheck disable=SC1091
set -a; source "$STATE/status.env"; set +a
[[ -n "${API_URL:-}" && -n "${ANON_KEY:-}" && -n "${SERVICE_ROLE_KEY:-}" && -n "${DB_URL:-}" ]] \
  || die "could not read API_URL/ANON_KEY/SERVICE_ROLE_KEY/DB_URL from supabase status"

# Run SQL as postgres: host psql when available, else psql inside the db container.
PSQL_BIN="$(command -v psql || ls -d /usr/lib/postgresql/*/bin/psql 2>/dev/null | sort -V | tail -n 1 || true)"
run_sql_file() {
  if [[ -n "$PSQL_BIN" ]]; then
    "$PSQL_BIN" -X -q -v ON_ERROR_STOP=1 "$DB_URL" -f "$1"
  else
    docker exec -i supabase_db_detail-crm psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres < "$1"
  fi
}
log "local platform setup (app_base_url=$APP_URL, pg_cron, pg_net)"
sed "s|__APP_BASE_URL__|$APP_URL|g" "$STACK_DIR/sql/setup_local.sql" > "$STATE/setup_local.sql"
run_sql_file "$STATE/setup_local.sql"

# ------------------------------------------------------------ stripe-mock
if port_open "$STRIPE_MOCK_PORT"; then
  log "stripe-mock already listening on :$STRIPE_MOCK_PORT"
else
  log "starting stripe-mock on :$STRIPE_MOCK_PORT"
  nohup "$STRIPE_MOCK" -http-port "$STRIPE_MOCK_PORT" -https-port "$STRIPE_MOCK_HTTPS_PORT" \
    > "$STATE/stripe-mock.log" 2>&1 &
  echo $! > "$STATE/stripe-mock.pid"
  wait_for stripe-mock 30 port_open "$STRIPE_MOCK_PORT"
fi

# ---------------------------------------------------------- provider mock
if port_open "$PROVIDER_MOCK_PORT"; then
  log "provider mock already listening on :$PROVIDER_MOCK_PORT"
else
  log "starting Twilio/Resend mock on :$PROVIDER_MOCK_PORT"
  nohup node "$STACK_DIR/provider_mock.mjs" --port "$PROVIDER_MOCK_PORT" \
    --file "$STATE/provider-requests.json" > "$STATE/provider-mock.log" 2>&1 &
  echo $! > "$STATE/provider-mock.pid"
  wait_for provider-mock 15 curl -fsS "http://127.0.0.1:$PROVIDER_MOCK_PORT/__control/health"
fi

# --------------------------------------------------------- function env
# Deterministic, obviously-fake test secrets (never real keys). The edge
# runtime runs in Docker, so host services are reached via
# host.docker.internal (the CLI maps it to the host gateway).
CRON_SECRET="stack-cron-secret-0123456789abcdef"
cat > "$ENV_FILE" <<EOF
# GENERATED by scripts/stack/up.sh — LOCAL real-stack harness only (git-ignored).
# SUPABASE_* are listed for test tooling; the CLI injects its own values into
# the edge runtime (it skips SUPABASE_-prefixed names from env files).
SUPABASE_URL=$API_URL
SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
STRIPE_SECRET_KEY=sk_test_stackharness0000000000000000
STRIPE_PUBLISHABLE_KEY=pk_test_stackharness0000000000000000
STRIPE_WEBHOOK_SECRET=whsec_test_stackharness00000000000000
STRIPE_API_BASE=http://host.docker.internal:$STRIPE_MOCK_PORT
TWILIO_ACCOUNT_SID=AC00000000000000000000000000000000
TWILIO_AUTH_TOKEN=stack_twilio_auth_token_0000000000
TWILIO_API_BASE=http://host.docker.internal:$PROVIDER_MOCK_PORT/2010-04-01
RESEND_API_KEY=re_stack_harness_key
RESEND_API_BASE=http://host.docker.internal:$PROVIDER_MOCK_PORT
EMAIL_FROM=Detail CRM <notifications@stack.test>
APP_BASE_URL=$APP_URL
CRON_SECRET=$CRON_SECRET
FUNCTIONS_PUBLIC_URL=$API_URL/functions/v1
CORS_ALLOWED_ORIGINS=http://localhost:5173
PLATFORM_FEE_BPS=0
EOF
# The edge runtime downloads npm:/jsr: imports at boot. Behind a
# TLS-intercepting proxy it must trust the proxy CA, and the container only
# sees supabase/functions, so the bundle is copied there (git-ignored).
EXTRA_CA="${STACK_EXTRA_CA_FILE:-${DENO_CERT:-}}"
if [[ -n "$EXTRA_CA" && -r "$EXTRA_CA" ]]; then
  cp "$EXTRA_CA" "$ROOT/supabase/functions/.stack-ca.pem"
  {
    echo "DENO_CERT=$ROOT/supabase/functions/.stack-ca.pem"
    echo "SSL_CERT_FILE=$ROOT/supabase/functions/.stack-ca.pem"
    echo "DENO_TLS_CA_STORE=mozilla,system"
  } >> "$ENV_FILE"
  log "edge runtime will trust the extra CA bundle $EXTRA_CA"
fi

# ------------------------------------------------------- functions serve
if [[ "${STACK_SKIP_FUNCTIONS:-0}" != 1 ]]; then
  if pid_alive "$STATE/functions.pid"; then
    log "restarting supabase functions serve (env may have changed)"
    kill "$(cat "$STATE/functions.pid")" 2>/dev/null || true
    sleep 2
  fi
  log "supabase functions serve --env-file supabase/functions/.env.stack"
  nohup "$SUPABASE" functions serve --env-file "$ENV_FILE" > "$STATE/functions.log" 2>&1 &
  echo $! > "$STATE/functions.pid"
  # Ready when the runtime answers a function with OUR JSON error envelope
  # (payments answers 400 unknown_action to an empty action). A runtime
  # BOOT_ERROR (503) means a function failed to load: fail fast with the log.
  functions_ready() {
    local out
    out="$(curl -sS -X POST "$API_URL/functions/v1/payments" -H 'content-type: application/json' \
      -H "apikey: $ANON_KEY" -d '{}' 2>/dev/null || true)"
    if grep -q '"BOOT_ERROR"' <<<"$out"; then
      touch "$STATE/functions.boot_error"
      return 0
    fi
    grep -q '"unknown_action"' <<<"$out"
  }
  rm -f "$STATE/functions.boot_error"
  wait_for "edge functions" 240 functions_ready
  if [[ -f "$STATE/functions.boot_error" ]]; then
    tail -n 30 "$STATE/functions.log" >&2
    die "edge functions failed to boot (see scripts/stack/.state/functions.log)"
  fi
fi

# ------------------------------------------------------------ stack.env
cat > "$STATE/stack.env" <<EOF
# GENERATED by scripts/stack/up.sh
STACK_API_URL=$API_URL
STACK_REST_URL=$API_URL/rest/v1
STACK_FUNCTIONS_URL=$API_URL/functions/v1
STACK_DB_URL=$DB_URL
STACK_ANON_KEY=$ANON_KEY
STACK_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
STACK_MAILPIT_URL=${MAILPIT_URL:-${INBUCKET_URL:-http://127.0.0.1:54324}}
STACK_STRIPE_MOCK_URL=http://127.0.0.1:$STRIPE_MOCK_PORT
STACK_PROVIDER_MOCK_URL=http://127.0.0.1:$PROVIDER_MOCK_PORT
STACK_PROVIDER_REQUESTS_FILE=$STATE/provider-requests.json
STACK_STRIPE_WEBHOOK_SECRET=whsec_test_stackharness00000000000000
STACK_TWILIO_AUTH_TOKEN=stack_twilio_auth_token_0000000000
STACK_CRON_SECRET=$CRON_SECRET
STACK_APP_URL=$APP_URL
EOF

log "stack is up"
cat <<EOF

  API URL           $API_URL
  DB URL            $DB_URL
  anon key          $ANON_KEY
  service_role key  $SERVICE_ROLE_KEY
  functions         $API_URL/functions/v1   (log: scripts/stack/.state/functions.log)
  mailpit           ${MAILPIT_URL:-${INBUCKET_URL:-http://127.0.0.1:54324}}
  stripe-mock       http://127.0.0.1:$STRIPE_MOCK_PORT
  Twilio/Resend     http://127.0.0.1:$PROVIDER_MOCK_PORT  (GET /__control/requests)

  Test env:  source scripts/stack/.state/stack.env
  Verify:    node scripts/stack/verify_stack.mjs
  SQL suite: scripts/stack/test_db_stack.sh
  Web e2e:   cd web && npx playwright test -c playwright.stack.config.ts
  Stop:      scripts/stack/down.sh
EOF
