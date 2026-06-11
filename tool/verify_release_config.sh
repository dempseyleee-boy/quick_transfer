#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gradle_file="$root_dir/mobile/android/app/build.gradle"
workflow_file="$root_dir/.github/workflows/build.yml"

fail() {
  printf 'release config check failed: %s\n' "$1" >&2
  exit 1
}

if rg -n 'signingConfig\s*=\s*signingConfigs\.debug' "$gradle_file"; then
  fail "Android release build still uses the debug signing key"
fi

rg -q "rootProject\.file\\([\"']key\\.properties[\"']\\)" "$gradle_file" ||
  fail "Android signing does not load key.properties"
rg -q 'signingConfigs\.release' "$gradle_file" ||
  fail "Android release signing config is not selected"
rg -q 'ndkVersion\s*=\s*"26\.1\.10909125"' "$gradle_file" ||
  fail "Android NDK version does not satisfy the current plugins"
rg -q "tags:" "$workflow_file" ||
  fail "release workflow is not triggered by version tags"
rg -q 'flutter build apk --release' "$workflow_file" ||
  fail "release workflow does not build an APK"
rg -q 'flutter build appbundle --release' "$workflow_file" ||
  fail "release workflow does not build an AAB"
rg -q 'windows.*\.zip|quick-transfer-windows' "$workflow_file" ||
  fail "release workflow does not package the Windows bundle"
rg -q 'dpkg-deb' "$workflow_file" ||
  fail "release workflow does not package a Debian release"

if rg -n 'Version:\s*1\.0\.0|quick-transfer_1\.0\.0' "$workflow_file"; then
  fail "release workflow still hard-codes version 1.0.0"
fi

desktop_version="$(sed -n 's/^version:[[:space:]]*\([^+]*\).*/\1/p' "$root_dir/pubspec.yaml")"
mobile_version="$(sed -n 's/^version:[[:space:]]*\([^+]*\).*/\1/p' "$root_dir/mobile/pubspec.yaml")"
test "$desktop_version" = "$mobile_version" ||
  fail "desktop and mobile public versions do not match"

if find "$root_dir/releases" -type f \( -name '*.apk' -o -name '*.aab' -o -name '*.deb' -o -name '*.zip' \) -print -quit 2>/dev/null | rg -q .; then
  fail "prebuilt release packages must not be committed to the source tree"
fi

printf 'release configuration is valid\n'
