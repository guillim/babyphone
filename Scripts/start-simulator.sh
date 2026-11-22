#!/bin/bash
# Starts a simulator for the UI tests, waits until it has finished booting, and
# grants the app its permissions so that no alert interrupts the tests.
#
# A simulator that is still booting accepts a test run and then fails it: apps
# do not launch, taps get lost. So the wait is worth its minutes. It is limited
# to ten: after that the tests run anyway and say what is wrong.
#
# With --no-wait the script returns as soon as the simulator accepts the
# permissions, for a caller that checks by itself that the app is up.
#
# Usage: Scripts/start-simulator.sh <device identifier> [--no-wait]
set -u
device=$1
bundle=com.guillim.babyphone

xcrun simctl boot "$device"

if [ "${2:-}" != "--no-wait" ]; then
  xcrun simctl bootstatus "$device" > /dev/null &
  boot=$!
  ( sleep 600; kill "$boot" 2> /dev/null ) &
  limit=$!
  wait "$boot"
  kill "$limit" 2> /dev/null
fi

for permission in camera microphone; do
  for attempt in $(seq 1 90); do
    xcrun simctl privacy "$device" grant "$permission" "$bundle" 2> /dev/null && break
    sleep 2
  done
done
exit 0
