# CloudMount Remote Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, with one fresh final review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durable external-change convergence into the existing three native mounts.

**Architecture:** Backend-generic live hints plus authoritative observed-directory scans commit an SQLite journal; DATA exports durable anchors and Working Set changes; Agent signals File Provider after commit.

**Tech Stack:** Swift, Apple FileProvider/SQLite, existing Go/C bridge and rclone ChangeNotify.

**Spec:** docs/superpowers/specs/2026-10-13-cloudmount-remote-sync-design.md

## Global Constraints

- Start 24c4999785a2b59519db699a6a8d30f37a5b4283 on cloudmount-macos in the specified checkout.
- Existing three domains/UUIDs persist; v1 -> v2 transaction, no reset/recreation.
- macOS 13.0, universal Agent; Provider sandboxed, App/Agent unsandboxed.
- Existing CONTROL/DATA roles, same UID, provider-wide trusted principal, private paths/selectors, FD-only content.
- backend/all and direct fs/cache.Get -> fs.Fs/fs.Object; no VFS frontend, no core API expansion.
- Read-only full hydration; external mutations solely within newly created phase fixture trees.
- No recursive whole-drive polling; ChangeNotify not sole correctness source; no durable Graph tokens.
- Production: journal 20,000 rows/domain; delta pages <=200; hints 60s, safety 300s, debounce 1s.
- User authorizes autonomous tactical execution; no design approval stalls; push only passing origin/cloudmount-macos, no upstream PR.

## Review Focus

- Journal pruning between two pages must expire the cursor, never skip history (Task 1).
- A normal enumeration racing a safety scan must not retire newer items (Tasks 1/3).
- Restart between journal commit and failed signal must still wake durable changes (Task 3).
- Update/delete of the same UUID within a page must translate to one final observer state (Tasks 1/2).
- Watch start completing after remove/remap must release its handle and never signal old state (Task 3).

---

### Task 1: Durable catalog and anchor model

**Files:** Shared/CloudMountShared.swift; Agent/ItemCatalog.swift; Tests/ItemCatalogTests.swift; Tests/SyncCatalogTests.swift; Scripts/test-file-provider.sh.

**Interfaces:** Produce CloudMountSyncAnchor(epoch:sequence:).data/decode; ItemCatalog.currentAnchor(domain:), changes(domain:container:from:limit:), workingSet(domain:page:limit:), authoritativeDirectories(domain:), revision(domain:). Reconcile/update/relocate share transactional journal helpers.

- [ ] Write tests using actual SQLite for v1 migration/UUIDs, first/unchanged scans, create/update/delete/subtree tombstones, reopen, wrong/future/old epochs, pagination/irrelevant sequences, pruning/rollback, baseline working-set pagination and three-domain concurrency. Expected RED: missing durable APIs / schema v2.
- [ ] Implement schema v2 and strict anchor/page codecs, bounded journal and one reconciliation pipeline. Expected GREEN: all catalog tests; no-op unchanged revision; failure preserves state.
- [ ] Run all native suites plus Go baseline. Expected PASS; update future-schema rejection fixture from v2 to v3.
- [ ] Commit logical persistence changes only after tests pass; retain installed v1 product until complete signed acceptance build.

### Task 2: DATA and Working Set change enumeration

**Files:** Shared/CloudMountShared.swift; Agent/DomainCatalog.swift; Agent/main.swift; FileProvider/FileProviderEnumerator.swift; FileProvider/FileProviderExtension.swift; Tests/FileProviderChangeTests.swift; Scripts/test-file-provider.sh.

**Interfaces:** DATA currentSyncAnchor(domainIdentifier:containerIdentifier:reply:), enumerateChanges(domainIdentifier:containerIdentifier:fromAnchor:limit:reply:), enumerateWorkingSet(domainIdentifier:page:limit:reply:). CloudMountChangeResponse carries safe metadata/deletions/anchor/moreComing/page, never backend paths.

- [ ] Test actual Provider enumerator with injected XPC boundary: durable anchors, update/delete translation, moreComing, expired/malformed anchor, Working Set pages, root/nested/single-item filtering and XPC failure one-shot completion. Expected RED: constant anchor/no working set/absent methods.
- [ ] Wire real DATA catalog APIs and Working Set support. Keep normal directory enumeration authoritative. Expected GREEN: observer arrays/anchor/error match literal fixtures.
- [ ] Run all native suites, signed Debug compile and Go unit tests. Expected PASS, hydration capability unchanged.
- [ ] Commit logical Provider change interface after tests pass.

### Task 3: Watch bridge and generation-safe reconciliation

**Files:** librclone/cloudmount/watch.go; watch_test.go; main.go; Agent/RcloneCloudMountBridge.h; Agent/RemoteChangeCoordinator.swift; Agent/main.swift; Agent/DomainConfigurationStore.swift; Agent/DomainCatalog.swift; Xcode project; Tests/RemoteChangeCoordinatorTests.swift.

**Interfaces:** C WatchStart/Next/Stop opaque handles; private Go watchResponse. Coordinator injected watch/list/signal boundaries; existing DomainCatalog.withDirectoryDiscovery/withSnapshot gates remain production authority.

- [ ] Write Go fake-Fs watch tests for unsupported/supported backend, event/type, bounded overflow, interval, stop/idempotency, blocked Next and concurrent handles. Expected RED: absent watch registry.
- [ ] Implement generic handles/context/channel queue and ABI. Expected GREEN under Go race tests; no backend/core changes.
- [ ] Write coordinator tests for hint coalescing, startup/safety catch-up, failed list preserving catalog, independent domains, remove/remap/shutdown/stale-start, signal retry after committed state and journal-read races. Expected RED: missing coordinator.
- [ ] Implement per-domain workers, known-directory scheduling, debounce/backoff, generation validation, startup restoration and supported Working Set signaling. Expected GREEN: actual SQLite/generation state preserved.
- [ ] Run all Go/native suites and signed Debug/Release compile. Expected PASS. Commit logical watcher/coordinator changes.

### Task 4: Installed acceptance, regression and handoff

**Files:** Private temporary harnesses/fixtures only; README/spec clarifications; intended complete branch diff.

**Interfaces:** Consume current installed three IDs, production DATA/working-set journal and ordinary rclone fixture mutations.

- [ ] Back up private catalog/mapping and record UUID digest before install; install signed Debug, migrate in place and verify signatures/entitlements/architectures/minimum, enabled/pong. Expected same IDs/UUIDs, v2.
- [ ] Create fresh exact fixture prefixes on A/B/C using ordinary rclone (crypt via wrapper). Establish observed folders then create/modify/materialize/rename/move/delete/Unicode/burst stimuli. Expected automatic Working Set callbacks, Finder convergence, exact new bytes, no ghosts/partial callbacks.
- [ ] Restart Agent/Provider with anchors and simulate Agent downtime during fixture mutations. Expected catch-up and unaffected UUIDs survive; failed backend listing never implies deletion. Safe network interruption or explicit honest limitation.
- [ ] Record live-hint/safety/startup/three-domain timings, API-load proxy counts, narrow signal/callback timeline and security role/UID/anchor/domain rejection. Expected no global blockage/privacy regression.
- [ ] Remove only exact phase fixture prefixes through same selectors, verify gone and three mounts preserved; clean own local diagnostics. Expected pre-existing data unchanged.
- [ ] Run CloudMount Go/race, full Go test, serial full build, all native suites, signed Debug, Release, signing and diff check. Expected PASS.
- [ ] Review complete diff/leakage, commit narrow docs/fixes, dispatch one fresh whole-branch reviewer with plan/spec/ledger; address Important/Critical via one TDD pass. Expected no unresolved blocking finding.
- [ ] Push only origin/cloudmount-macos, verify remote SHA/clean worktree, final consolidated report and STOP.
