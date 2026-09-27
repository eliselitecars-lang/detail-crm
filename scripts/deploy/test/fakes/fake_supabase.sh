#!/usr/bin/env bash
# Fake Supabase CLI for scripts/deploy/test/deploy_backend.test.mjs. Records
# every invocation's argv (one line each) in $FAKE_CLI_LOG and emulates
# `link`, `db push [--dry-run]` and `functions deploy`; anything else (for
# example `config push`) is recorded and fails with exit 99.
set -euo pipefail
: "${FAKE_CLI_LOG:?}" "${FAKE_STATE_DIR:?}"
printf '%s\n' "$*" >>"$FAKE_CLI_LOG"

args=("$@")
workdir=""
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--workdir" ]; then workdir="${args[$((i + 1))]}"; fi
done
has() {
  local f
  for f in "${args[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

case "${1:-}" in
  --version) echo "2.118.0" ;;
  link)
    [ -n "${SUPABASE_DB_PASSWORD:-}" ] || {
      echo "fake: SUPABASE_DB_PASSWORD is not in the environment" >&2
      exit 3
    }
    [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || {
      echo "fake: SUPABASE_ACCESS_TOKEN is not in the environment" >&2
      exit 3
    }
    [ -f "$workdir/supabase/config.toml" ] || {
      echo "fake: --workdir has no supabase/config.toml" >&2
      exit 3
    }
    echo "Finished supabase link."
    ;;
  db)
    [ "${2:-}" = push ] || exit 98
    touch "$FAKE_STATE_DIR/applied"
    pending=()
    for f in "$workdir"/supabase/migrations/*.sql; do
      n="$(basename "$f")"
      grep -qx "$n" "$FAKE_STATE_DIR/applied" || pending+=("$n")
    done
    if [ "${#pending[@]}" -eq 0 ]; then
      echo "Remote database is up to date."
      exit 0
    fi
    if has --dry-run; then
      echo "DRY RUN: migrations will *not* be pushed to the database."
      echo "Would push these migrations:"
      printf ' • %s\n' "${pending[@]}"
    else
      for n in "${pending[@]}"; do
        echo "Applying migration $n..."
        echo "$n" >>"$FAKE_STATE_DIR/applied"
      done
      echo "Finished supabase db push."
    fi
    ;;
  functions)
    [ "${2:-}" = deploy ] || exit 98
    name="${3:-}"
    [ -f "$workdir/supabase/functions/$name/index.ts" ] || {
      echo "fake: no function $name in the snapshot" >&2
      exit 3
    }
    verify=true
    if has --no-verify-jwt; then verify=false; fi
    printf '{"slug":"%s","verify_jwt":%s}\n' "$name" "$verify" >>"$FAKE_STATE_DIR/deployed.jsonl"
    echo "Deployed Functions on project: $name"
    ;;
  *)
    echo "fake: unexpected supabase command: $*" >&2
    exit 99
    ;;
esac
