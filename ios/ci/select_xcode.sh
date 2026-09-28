#!/usr/bin/env bash
# Picks the Xcode the iOS workflows build with (ios.yml, ios-testflight.yml):
# the newest installed release (no beta) whose major version is at least
# MIN_XCODE_MAJOR (default 26).
#
# Why 26: since April 28, 2026 App Store Connect accepts uploads, TestFlight
# included, only from Xcode 26 / the iOS 26 SDK or later (Apple raises this
# minimum every spring). An archive built with Xcode 16 still exports, but the
# upload or its processing is rejected, so no build reaches testers. ios.yml
# uses the same Xcode, so a green CI build means the TestFlight archive
# compiles. When Apple raises the minimum again, raise MIN_XCODE_MAJOR here
# and MIN_UPLOAD_SDK_MAJOR in fastlane/Fastfile (docs/DEPLOY.md section 5).
#
# Usage: ios/ci/select_xcode.sh            select it (sudo xcode-select -s)
#        ios/ci/select_xcode.sh --print    only print the chosen path
# Env:   APPS_DIR (default /Applications), MIN_XCODE_MAJOR (default 26)
set -euo pipefail

APPS_DIR="${APPS_DIR:-/Applications}"
MIN_XCODE_MAJOR="${MIN_XCODE_MAJOR:-26}"

# Xcode_<version>.app (the runner images' names); Xcode.app counts only
# when its version can be read from its Info.plist (on macOS).
version_of() {
  local app="$1" name
  name="$(basename "$app" .app)"
  case "$name" in
    *[Bb]eta*|*_RC*|*[Rr]elease_[Cc]andidate*) return 1 ;;
    Xcode_*) printf '%s\n' "${name#Xcode_}" ;;
    Xcode)
      if [ -x /usr/libexec/PlistBuddy ] && [ -f "$app/Contents/Info.plist" ]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || return 1
      else
        return 1
      fi ;;
    *) return 1 ;;
  esac
}

candidates=""
while IFS= read -r app; do
  [ -n "$app" ] || continue
  version="$(version_of "$app")" || continue
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
  [ "${version%%.*}" -ge "$MIN_XCODE_MAJOR" ] || continue
  candidates+="$version"$'\t'"$app"$'\n'
done < <(find "$APPS_DIR" -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort)

best_line="$(printf '%s' "$candidates" | sort -V | tail -1)"
best="${best_line#*$'\t'}"
best_version="${best_line%%$'\t'*}"

if [ -z "$best" ]; then
  echo "::error::No Xcode $MIN_XCODE_MAJOR or later (release, not beta) in $APPS_DIR. App Store Connect accepts only builds made with Xcode $MIN_XCODE_MAJOR / the iOS $MIN_XCODE_MAJOR SDK or later; use a runner image that has it (runs-on: macos-26)." >&2
  find "$APPS_DIR" -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort >&2 || true
  exit 1
fi

if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$best"
  exit 0
fi

echo "Selecting $best (Xcode $best_version)"
sudo xcode-select -s "$best"
xcodebuild -version
