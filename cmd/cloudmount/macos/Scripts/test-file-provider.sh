#!/bin/sh
set -eu

native_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/cloudmount-native-tests.XXXXXX")
trap 'rm -f "$test_dir/hydration-mode" "$test_dir/range-alignment" "$test_dir/domain-store"; rmdir "$test_dir"' EXIT

xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    "$native_root/Shared/CloudMountShared.swift" "$native_root"/FileProvider/*.swift \
    "$native_root/Tests/HydrationModeTests.swift" -o "$test_dir/hydration-mode"
"$test_dir/hydration-mode"

xcrun swiftc "$native_root/FileProvider/RangeAlignment.swift" \
    "$native_root/Tests/RangeAlignmentTests.swift" -o "$test_dir/range-alignment"
"$test_dir/range-alignment"

xcrun swiftc "$native_root/Agent/DomainConfigurationStore.swift" \
    "$native_root/Tests/DomainConfigurationStoreTests.swift" -o "$test_dir/domain-store"
"$test_dir/domain-store"
