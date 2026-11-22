#!/bin/bash
# Starts a simulator for the UI tests and grants the app its permissions.
#
# It does not wait for the boot to finish. Waiting for a complete boot costs
# minutes on a build machine, and the tests wait for exactly as much of it as
# they need. The grants are retried until the simulator accepts them.
#
# Usage: Scripts/start-simulator.sh <device identifier>
set -u
device=$1
bundle=com.guillim.babyphone

xcrun simctl boot "$device"
for permission in camera microphone; do
  for attempt in $(seq 1 90); do
    xcrun simctl privacy "$device" grant "$permission" "$bundle" 2>/dev/null && break
    sleep 2
  done
done
