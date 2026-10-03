#!/bin/zsh
set -euo pipefail
windows_root="${0:A:h:h}"
apple_root="$windows_root/../apple"
windows_fixture="${1:?Pass the Windows fixture JSON exported by the core tests}"
apple_fixture="${2:?Pass an output path for the Apple fixture JSON}"
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/nearlink-windows-interop.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
  "$apple_root"/NearLink/Core/Protocol/*.swift \
  "$windows_root/Tests/AppleInteropTests.swift" -o "$test_directory/apple-interop"
"$test_directory/apple-interop" "$windows_fixture" "$apple_fixture"
