#!/bin/zsh
set -euo pipefail

apple_root="${0:A:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nearlink-transfer-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
  "$apple_root"/NearLink/Core/Protocol/*.swift \
  "$apple_root"/NearLink/Core/Transfer/IncomingFilePolicy.swift \
  "$apple_root"/Tests/TransferSafetyTests.swift -o "$test_dir/transfer-safety-tests"
"$test_dir/transfer-safety-tests" "$@"
