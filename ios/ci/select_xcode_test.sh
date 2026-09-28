#!/usr/bin/env bash
# Tests for select_xcode.sh against fake /Applications folders (runs on Linux).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
pick() { # pick <min-major> <app names...> -> prints the chosen name or "ERROR"
  local min="$1"; shift
  local dir; dir="$(mktemp -d)"
  for name in "$@"; do mkdir -p "$dir/$name"; done
  local out
  if out="$(APPS_DIR="$dir" MIN_XCODE_MAJOR="$min" "$HERE/select_xcode.sh" --print 2>/dev/null)"; then
    basename "$out"
  else
    echo ERROR
  fi
  rm -rf "$dir"
}
expect() { # expect <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; fail=1; fi
}
expect "newest 26.x over 16.x" Xcode_26.2.app "$(pick 26 Xcode_16.4.app Xcode_26.0.1.app Xcode_26.2.app Xcode_16.2.app)"
expect "version order, not text order" Xcode_26.10.app "$(pick 26 Xcode_26.9.app Xcode_26.10.app)"
expect "later majors count" Xcode_27.0.app "$(pick 26 Xcode_26.3.app Xcode_27.0.app)"
expect "betas are skipped" Xcode_26.0.app "$(pick 26 Xcode_26.0.app Xcode_26.1_beta_2.app Xcode_26.1_Release_Candidate.app)"
expect "only 16.x installed fails" ERROR "$(pick 26 Xcode_16.4.app Xcode_16.2.app Xcode.app)"
expect "only a beta 26 fails" ERROR "$(pick 26 Xcode_16.4.app Xcode_26.0_beta.app)"
expect "nothing installed fails" ERROR "$(pick 26)"
expect "minimum is configurable" Xcode_27.1.app "$(pick 27 Xcode_26.4.app Xcode_27.1.app)"
exit $fail
