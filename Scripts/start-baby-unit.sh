#!/bin/bash
# Starts the app as a baby unit for the two-device test, and waits until it shows its pairing code.
#
# The baby unit has no test runner: it monitors by itself and tells the test what
# happens through files in the session folder. A launch that a build machine
# loses is made again, five times at most, and no call to the simulator waits
# without a limit.
#
# Usage: Scripts/start-baby-unit.sh <device identifier> <path to the built app> <session folder>
set -u
device=$1
app=$2
folder=$3
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist") || exit 1


# Runs a command, and stops it when it takes more than the given number of seconds.
within() {
  local seconds=$1
  shift
  "$@" &
  local command=$!
  ( sleep "$seconds"; kill "$command" ) > /dev/null 2>&1 &
  local guard=$!
  wait "$command"
  local status=$?
  kill "$guard" 2> /dev/null
  return $status
}

mkdir -p "$folder"
# What the app reads at launch: its role, and where to report.
export SIMCTL_CHILD_NUZZLECAM_UI_TEST_STATE=baby
export SIMCTL_CHILD_NUZZLECAM_TEST_SHARED_DIR="$folder"
for round in 1 2 3 4 5; do
  within 30 xcrun simctl terminate "$device" "$bundle" 2> /dev/null || true
  if within 180 xcrun simctl install "$device" "$app" \
    && within 60 xcrun simctl launch "$device" "$bundle" -AppleLanguages "(fr)" -AppleLocale fr_FR; then
    for attempt in $(seq 1 30); do
      [ -f "$folder/code" ] && exit 0
      sleep 2
    done
  fi
  sleep 5
done
echo "The baby unit did not show a pairing code."
exit 1
