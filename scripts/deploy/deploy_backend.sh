#!/usr/bin/env bash
# Production deploy of the Detail CRM backend to a hosted Supabase project:
# migrations, edge functions (verify_jwt from config.toml), function secrets,
# optional Stripe webhooks, production Auth (Management API), the platform
# setup of supabase/setup/cron.sql and billing. Idempotent: safe to re-run.
# Operator runbook: docs/DEPLOY.md (billing: docs/BILLING.md).
#
#   scripts/deploy/deploy_backend.sh [--dry-run] [--stripe-webhooks]
#                                    [--include-all] [--allow-dirty]
#
#   --dry-run          validate inputs, link, list pending migrations and print
#                      what every other step would change; changes nothing
#   --stripe-webhooks  create/update the Stripe webhook endpoints (Connect; the
#                      platform billing one too when BILLING_ENABLED=true);
#                      without it the stored signing secrets are kept
#   --include-all      pass --include-all to `supabase db push` (a migration
#                      numbered below one already applied; see docs/DEPLOY.md)
#   --allow-dirty      deploy although supabase/ has uncommitted changes
#
# Inputs come from the environment only (never argv, never a file in the
# repo); values are never printed. Required: SUPABASE_ACCESS_TOKEN,
# SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD and the function secrets listed
# in docs/DEPLOY.md (scripts/deploy/lib/config.mjs SECRET_SPECS). The inputs
# are the desired state: an optional secret they leave unset is removed from
# the project (unset = off).
#
# NEVER runs `supabase config push` (or anything else that syncs
# supabase/config.toml to the hosted project): config.toml is tuned for local
# journeys (email confirmations off, 127.0.0.1 URLs). Production Auth is set
# only through the Management API with email confirmations ON.
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

DRY_RUN=0
STRIPE_WEBHOOKS=0
INCLUDE_ALL=0
ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --stripe-webhooks) STRIPE_WEBHOOKS=1 ;;
    --include-all) INCLUDE_ALL=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
API="$HERE/lib/deploy_api.mjs"
SUPABASE_CLI_VERSION="${SUPABASE_CLI_VERSION:-2.118.0}"
TOTAL=9

step() { printf '\n==> [%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || die "node (20 or newer) is required"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || die "node 20 or newer is required (found $(node --version))"

api_flags=()
[ "$DRY_RUN" = 1 ] && api_flags+=(--dry-run)
secret_flags=()
[ "$STRIPE_WEBHOOKS" = 1 ] && secret_flags+=(--stripe-webhooks)

# The Supabase CLI: $SUPABASE_CLI, else `supabase` on PATH, else npx (pinned).
if [ -n "${SUPABASE_CLI:-}" ]; then
  SB=("$SUPABASE_CLI")
elif command -v supabase >/dev/null 2>&1; then
  SB=(supabase)
else
  SB=(npx --yes "supabase@${SUPABASE_CLI_VERSION}")
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/detail-crm-deploy.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Every CLI call goes through here. Refuses anything that would push
# config.toml (local-only auth settings) or otherwise touch what this script
# manages through the Management API.
sb() {
  case "${1:-} ${2:-}" in
    "config "* | "db reset" | "secrets "* | "db pull" | "db remote"* | "branches "*)
      die "refusing to run 'supabase $1 ${2:-}' against production (see docs/DEPLOY.md)"
      ;;
  esac
  "${SB[@]}" "$@" --workdir "$WORK"
}

printf 'Detail CRM backend deploy%s\n' "$([ "$DRY_RUN" = 1 ] && printf ' (DRY RUN: nothing is changed)')"

# ------------------------------------------------------------------ 1
step 1 "Validate inputs"
set +e
node "$API" validate ${secret_flags[@]+"${secret_flags[@]}"}
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  die "fix the inputs listed above (docs/DEPLOY.md says where each one comes from)"
elif [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  # sed reads all of git's output (head would close the pipe early: SIGPIPE,
  # exit 141 under pipefail, whenever more than 20 paths are dirty).
  DIRTY="$(git -C "$ROOT" status --porcelain -- supabase 2>/dev/null | sed -n '1,20p')"
  info "source: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?') @ $REV"
  if [ -n "$DIRTY" ]; then
    if [ "$DRY_RUN" = 1 ] || [ "$ALLOW_DIRTY" = 1 ]; then
      warn "supabase/ has uncommitted changes; they are part of this $([ "$DRY_RUN" = 1 ] && printf 'dry run' || printf 'deploy'):"
      printf '%s\n' "$DIRTY" | sed 's/^/      /' >&2
    else
      printf '%s\n' "$DIRTY" | sed 's/^/      /' >&2
      die "supabase/ has uncommitted changes: commit them, or pass --allow-dirty to deploy the working tree"
    fi
  fi
fi

# ------------------------------------------------------------------ 2
step 2 "Project and CLI"
# Also checks that the webhook signing secrets that are not inputs are
# already stored in the project (kept as they are), before anything changes.
node "$API" preflight ${secret_flags[@]+"${secret_flags[@]}"}
info "supabase CLI: $("${SB[@]}" --version 2>/dev/null | tail -1) (pinned ${SUPABASE_CLI_VERSION})"
# Snapshot what is deployed, so a concurrent edit of the working tree cannot
# mix versions mid-deploy. Dot files (.env*, local CA bundles) are excluded.
mkdir -p "$WORK/supabase/setup"
cp "$ROOT/supabase/config.toml" "$WORK/supabase/config.toml"
cp -R "$ROOT/supabase/migrations" "$WORK/supabase/migrations"
(cd "$ROOT/supabase" && tar -cf - --exclude='.*' functions) | (cd "$WORK/supabase" && tar -xf -)
cp "$ROOT/supabase/setup/cron.sql" "$WORK/supabase/setup/cron.sql"
# "<name> <verify_jwt>" per [functions.<name>]; fails if config.toml and the
# function directories disagree (captured here so a failure stops the deploy).
FN_PLAN="$(node "$API" functions-plan --supabase-dir "$WORK/supabase")"
info "snapshot: $(find "$WORK/supabase/migrations" -name '*.sql' | wc -l | tr -d ' ') migrations, $(printf '%s\n' "$FN_PLAN" | grep -c .) functions"

# ------------------------------------------------------------------ 3
step 3 "Link project (password from SUPABASE_DB_PASSWORD)"
sb link --project-ref "$SUPABASE_PROJECT_REF"

# ------------------------------------------------------------------ 4
step 4 "Database migrations"
push_flags=(--linked --yes --skip-vault)
[ "$INCLUDE_ALL" = 1 ] && push_flags+=(--include-all)
sb db push ${push_flags[@]+"${push_flags[@]}"} --dry-run
if [ "$DRY_RUN" = 1 ]; then
  info "dry run: migrations not applied"
else
  sb db push ${push_flags[@]+"${push_flags[@]}"}
fi

# ------------------------------------------------------------------ 5
step 5 "Function secrets"
node "$API" secrets ${api_flags[@]+"${api_flags[@]}"} ${secret_flags[@]+"${secret_flags[@]}"}

# ------------------------------------------------------------------ 6
step 6 "Stripe webhook endpoints (Connect; platform billing when enabled)"
if [ "$STRIPE_WEBHOOKS" = 1 ]; then
  node "$API" stripe-webhook ${api_flags[@]+"${api_flags[@]}"} --supabase-dir "$WORK/supabase"
else
  info "skipped (pass --stripe-webhooks to manage them; STRIPE_WEBHOOK_SECRET / STRIPE_BILLING_WEBHOOK_SECRET are used as given, or kept as stored in the project)"
fi

# ------------------------------------------------------------------ 7
step 7 "Edge functions (verify_jwt from supabase/config.toml)"
deploy_flags=()
[ "${SUPABASE_FUNCTIONS_BUNDLER:-api}" = "api" ] && deploy_flags+=(--use-api)
while read -r fn verify; do
  [ -n "$fn" ] || continue
  jwt_flag=()
  [ "$verify" = "false" ] && jwt_flag+=(--no-verify-jwt)
  if [ "$DRY_RUN" = 1 ]; then
    info "would deploy $fn (verify_jwt=$verify)"
  else
    info "deploying $fn (verify_jwt=$verify)"
    sb functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF" ${deploy_flags[@]+"${deploy_flags[@]}"} ${jwt_flag[@]+"${jwt_flag[@]}"}
  fi
done <<<"$FN_PLAN"
node "$API" check-functions ${api_flags[@]+"${api_flags[@]}"} --supabase-dir "$WORK/supabase"

# ------------------------------------------------------------------ 8
step 8 "Production Auth (Management API; config.toml is never pushed)"
node "$API" auth ${api_flags[@]+"${api_flags[@]}"}

# ------------------------------------------------------------------ 9
step 9 "Platform setup (cron.sql with real values, in memory; billing config and plan sync)"
node "$API" platform-setup ${api_flags[@]+"${api_flags[@]}"} --cron-sql "$WORK/supabase/setup/cron.sql"

printf '\n%s\n' "$([ "$DRY_RUN" = 1 ] && printf 'Dry run complete: nothing was changed.' || printf 'Backend deployed.')"
[ "$DRY_RUN" = 1 ] || printf 'Next: node scripts/deploy/verify_live.mjs (post-deploy smoke checks)\n'
