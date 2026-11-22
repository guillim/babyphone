#!/bin/bash
# Starts the app as a baby unit for the two-device test, and waits until it shows its pairing code.
#
# The baby unit has no test runner: it monitors by itself and tells the test what
# happens through files in the session folder. Its simulator may still be starting,
# so install and launch are retried until the simulator accepts them.
#
# Usage: Scripts/start-baby-unit.sh <device identifier> <path to the app> <session folder>
set -u
device=$1
app=$2
folder=$3
bundle=com.guillim.babyphone

mkdir -p "$folder"
xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
for attempt in $(seq 1 200); do
  xcrun simctl install "$device" "$app" 2>/dev/null \
    && SIMCTL_CHILD_NID_UI_TEST_STATE=baby SIMCTL_CHILD_NID_TEST_SHARED_DIR="$folder" \
      xcrun simctl launch "$device" "$bundle" -AppleLanguages "(fr)" -AppleLocale fr_FR \
    && break
  sleep 3
done
for attempt in $(seq 1 90); do
  [ -f "$folder/code" ] && exit 0
  sleep 2
done
echo "The baby unit did not show a pairing code."
exit 1
