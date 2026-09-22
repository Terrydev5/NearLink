#!/bin/zsh
set -euo pipefail

apple_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nearlink-device-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

sources=("$apple_root"/NearLink/App/*.swift "$apple_root"/NearLink/Core/**/*.swift)
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
  "${sources[@]}" "$apple_root/Tests/DeviceHistoryTests.swift" \
  -o "$test_dir/device-history-tests"
"$test_dir/device-history-tests"
