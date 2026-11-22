#!/bin/bash
# Runs the package tests on a Mac and, if they stall, shows where before giving up.
#
# A deadlock between threads makes a test run hang without a word: the output is
# buffered and the time limits of the tests cannot interrupt a blocked thread.
# This script gives the tests a terminal, so each line appears as it is printed,
# and when the time is up it prints the stack of every thread of the test process.
#
# Usage: Scripts/test-with-watchdog.sh [seconds] [arguments for swift test]
limit=${1:-300}
shift

script -q /dev/null swift test --package-path Packages/BabyphoneKit "$@" &
tests=$!

(
  sleep "$limit"
  echo "The tests are still running after $limit seconds. Thread stacks follow."
  for pid in $(pgrep -f 'BabyphoneKitPackageTests|swiftpm-testing'); do
    sample "$pid" 2 2>/dev/null | sed -n '1,700p'
  done
  pkill -f 'BabyphoneKitPackageTests|swiftpm-testing'
  kill "$tests" 2>/dev/null
) &
watchdog=$!

wait "$tests"
status=$?
kill "$watchdog" 2>/dev/null
exit "$status"
