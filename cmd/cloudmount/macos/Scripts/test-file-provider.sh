#!/bin/sh
set -eu

native_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/cloudmount-native-tests.XXXXXX")
trap 'rm -f "$test_dir/hydration-mode" "$test_dir/range-alignment" "$test_dir/domain-store" "$test_dir/identity" "$test_dir/catalog" "$test_dir/provider-identity" "$test_dir/domain-catalog" "$test_dir/domain-lifecycle" "$test_dir/multi-domain"; rmdir "$test_dir"' EXIT

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

xcrun swiftc "$native_root/Shared/CloudMountShared.swift" \
    "$native_root/Tests/IdentityTests.swift" -o "$test_dir/identity"
"$test_dir/identity"

xcrun swiftc "$native_root/Shared/CloudMountShared.swift" "$native_root/Agent/ItemCatalog.swift" \
    "$native_root/Tests/ItemCatalogTests.swift" -o "$test_dir/catalog"
"$test_dir/catalog"

xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    "$native_root/Shared/CloudMountShared.swift" "$native_root"/FileProvider/*.swift \
    "$native_root/Tests/FileProviderIdentityTests.swift" -o "$test_dir/provider-identity"
"$test_dir/provider-identity"

xcrun swiftc "$native_root/Shared/CloudMountShared.swift" \
    "$native_root/Agent/ItemCatalog.swift" "$native_root/Agent/DomainConfigurationStore.swift" "$native_root/Agent/DomainCatalog.swift" \
    "$native_root/Tests/DomainCatalogTests.swift" -o "$test_dir/domain-catalog"
"$test_dir/domain-catalog"

xcrun swiftc "$native_root/Shared/CloudMountShared.swift" "$native_root/Agent/DomainConfigurationStore.swift" \
    "$native_root/App/DomainLifecycle.swift" "$native_root/Tests/DomainLifecycleTests.swift" -o "$test_dir/domain-lifecycle"
"$test_dir/domain-lifecycle"

xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    "$native_root/Shared/CloudMountShared.swift" "$native_root/Agent/DomainConfigurationStore.swift" \
    "$native_root/Agent/ItemCatalog.swift" "$native_root/Agent/DomainCatalog.swift" \
    "$native_root"/FileProvider/*.swift "$native_root/Tests/MultiDomainTests.swift" -o "$test_dir/multi-domain"
"$test_dir/multi-domain"
