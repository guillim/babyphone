#!/bin/bash
# Starts a simulator for the UI tests, waits until it has finished booting, and
# grants the app its permissions so that no alert interrupts the tests.
#
# A simulator that is still booting accepts a test run and then fails it: apps
# do not launch, taps get lost. So the wait is worth its minutes. It is limited
# to ten. The script fails when the simulator does not accept the permissions:
# an alert that nothing can answer would otherwise stop a test much later.
# No call to the simulator waits without a limit.
#
# Usage: Scripts/start-simulator.sh <device identifier> <path to the built app>
set -u
device=$1
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$2/Info.plist") || exit 1


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

within 120 xcrun simctl boot "$device"
within 600 xcrun simctl bootstatus "$device" > /dev/null

for attempt in $(seq 1 30); do
  within 20 xcrun simctl privacy "$device" grant camera "$bundle" 2> /dev/null \
    && within 20 xcrun simctl privacy "$device" grant microphone "$bundle" 2> /dev/null \
    && exit 0
  sleep 2
done
echo "The simulator did not accept the camera and microphone permissions."
exit 1
