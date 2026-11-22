#!/bin/bash
# Starts the app as a baby unit for the two-device test, and waits until it shows its pairing code.
#
# The baby unit has no test runner: it monitors by itself and tells the test what
# happens through files in the session folder. A launch that a build machine
# loses is made again, five times at most.
#
# Usage: Scripts/start-baby-unit.sh <device identifier> <path to the built app> <session folder>
set -u
device=$1
app=$2
folder=$3
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist") || exit 1

mkdir -p "$folder"
for round in 1 2 3 4 5; do
  xcrun simctl terminate "$device" "$bundle" 2> /dev/null || true
  if xcrun simctl install "$device" "$app" \
    && SIMCTL_CHILD_NID_UI_TEST_STATE=baby SIMCTL_CHILD_NID_TEST_SHARED_DIR="$folder" \
      xcrun simctl launch "$device" "$bundle" -AppleLanguages "(fr)" -AppleLocale fr_FR; then
    for attempt in $(seq 1 30); do
      [ -f "$folder/code" ] && exit 0
      sleep 2
    done
  fi
  sleep 5
done
echo "The baby unit did not show a pairing code."
exit 1
