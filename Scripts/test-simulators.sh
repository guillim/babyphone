#!/bin/bash
# Runs on this Mac what the Simulators workflow runs on a build machine: the walk
# through the screens, and a whole session between two simulators. It takes a few
# minutes here, against half an hour there, so it is the check to make before
# pushing a change to the app.
#
# Usage: Scripts/test-simulators.sh [baby simulator name] [parent simulator name]
# Without names, the first two iPhones this Xcode has set up are used.
set -u
cd "$(dirname "$0")/.."

derived=${TMPDIR:-/tmp}/nuzzlecam-simulators
app=$derived/Build/Products/Debug-iphonesimulator/Babyphone.app

# The identifier of the simulator called `$1`, or of the `$2`-th iPhone when no name is given.
simulator() {
  if [ -n "$1" ]; then
    xcrun simctl list devices available | grep -F "    $1 (" | head -1 | grep -oE '[0-9A-F-]{36}'
  else
    xcrun simctl list devices available | grep -E '^ +iPhone' | sed -n "$2p" | grep -oE '[0-9A-F-]{36}'
  fi
}
baby=$(simulator "${1:-}" 1)
parent=$(simulator "${2:-}" 2)
if [ -z "$baby" ] || [ -z "$parent" ]; then
  echo "Two iPhone simulators are needed. See: xcrun simctl list devices available"
  exit 1
fi

echo "Building…"
xcodebuild build-for-testing \
  -project Babyphone.xcodeproj -scheme BabyphoneUITests \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=NO > "$derived.build.log" 2>&1 \
  || { grep -E "error:" "$derived.build.log"; echo "The build failed. See $derived.build.log"; exit 1; }

# Runs the tests of one class on one simulator, and prints what failed.
run() {
  local name=$1 device=$2 log=$derived.$1.log
  xcodebuild test-without-building \
    -project Babyphone.xcodeproj -scheme BabyphoneUITests \
    -destination "id=$device" -derivedDataPath "$derived" \
    -only-testing:"BabyphoneUITests/$name" > "$log" 2>&1
  local status=$?
  grep -hE "error: -\[|Test Case .* (passed|failed)" "$log" | cut -c1-300
  return $status
}

status=0
Scripts/start-simulator.sh "$baby" "$app" 2> /dev/null || exit 1
Scripts/start-simulator.sh "$parent" "$app" 2> /dev/null || exit 1

echo "Walking the screens…"
run SmokeTests "$baby" || status=1

echo "Two devices, end to end…"
session=$(mktemp -d)
if Scripts/start-baby-unit.sh "$baby" "$app" "$session" > /dev/null 2>&1; then
  TEST_RUNNER_NUZZLECAM_SHARED_DIR="$session" run TwoDeviceTests "$parent" || status=1
  # A test that was skipped also ends well. Only the baby unit's last word says the session ran.
  [ -f "$session/baby-stopped" ] || { echo "The session did not run to its end."; status=1; }
else
  status=1
fi

if [ $status -eq 0 ]; then echo "All passed."; else echo "Something failed. The logs are next to $derived."; fi
exit $status
