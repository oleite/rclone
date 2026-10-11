# CloudMount identities implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Replace pathname identities with an Agent-owned durable catalog.
**Architecture:** Locked Apple SQLite catalog, identity-only DATA interface, existing Go path bridge. Short mapping locks and per-domain generation snapshots protect lifecycle bindings; backend I/O remains concurrent.
**Tech Stack:** Swift, SQLite3, CryptoKit, FileProvider, existing Go/C archive.
**Spec:** docs/superpowers/specs/2026-10-10-cloudmount-identities-design.md plus director attachment.

## Global Constraints

- macOS minimum 13.0; Agent arm64 + x86_64.
- Full hydration only; CONTROL app-only / DATA provider-only; mutual authentication.
- Provider never receives selector/path; content uses FileHandle/FD only.
- No CloudMount writes, polling, eviction, synchronization or partial optimization.
- Only disposable SMB root `ha:media/testing/cloudmount-phase4-<UUID>`.

## Review Focus

- Remapping interrupted between JSON and SQLite must never resolve old IDs to new content (catalog binding tests + runtime restart).
- Concurrent discovery and duplicate listings must not mint multiple IDs or lose parents (catalog concurrency/rollback tests).
- Directory move collisions must roll back all descendants, not leave mixed paths (catalog transactional move tests).
- Corrupt/newer catalogs must fail closed, never silently reset identities (schema/open tests).
- Stale or cross-domain identifiers must never become pathname requests (identity/catalog tests + DATA runtime harness).
- Overlapping discovery of one directory must not retire newer identities; unrelated discovery remains concurrent (ordered-discovery regression).

### Task 1: Catalog and opaque identifier contract

**Files:** Shared/CloudMountShared.swift; Agent/ItemCatalog.swift; Tests/ItemCatalogTests.swift; Tests/IdentityTests.swift; Scripts/test-file-provider.sh (under cmd/cloudmount/macos).
**Interfaces:** Produces CloudMountItemIdentifier validation; CloudMountItemMetadata/Response; ItemCatalog.bind/purge/reconcile/resolve/update/relocate.

- [x] Write real SQLite tests: same path stable after reopen, canonical IDs, parent IDs, concurrent discovery, duplicate-path rollback, rename/move preserving IDs/content version, domain isolation/remapping/purge, corruption/newer/schema validation, private permissions.
- [x] Run new tests first. Expected: missing catalog/identity API failure.
- [x] Implement minimal versioned catalog and identity/wire contracts; no selectors in records.
- [x] Run catalog/identity tests. Expected: PASS, existing native tests unaffected until consumer migration.

### Task 2: Agent resolution and provider consumption

**Files:** Agent/main.swift; FileProvider/{FileProviderItem,FileProviderEnumerator,FileProviderExtension}.swift; project.pbxproj; tests/README.
**Interfaces:** Consumes Task 1 catalog and metadata. DATA list takes parentIdentifier; stat/fetch take itemIdentifier. Go bridge remains path-based internally.

- [x] Write FileProviderItem tests proving Agent-provided item/parent IDs and distinct content/metadata versions are consumed, not derived from filenames; malformed/old IDs rejected.
- [x] Run tests against path codec. Expected: missing identity consumer contract.
- [x] Integrate catalog lifecycle, identity DATA methods and path-free provider; preserve compiled partial logic but do not advertise it. Test stale directory completions, A-to-B-to-A remapping and remove/re-add snapshot rejection.
- [x] Run Scripts/test-file-provider.sh. Expected: all native tests PASS.
- [x] Build signed Debug and unsigned Release. Expected: PASS, 13.0/universal/topology unchanged.

### Task 3: Installed SMB acceptance and review

**Files:** README.md acceptance/limitations; temporary ignored runtime harnesses only.
**Interfaces:** Installed signed app/Agent/provider; disposable SMB fixtures.

- [x] Run clean Go baseline/regression with SDK workaround. Expected: tests/race/full suite/build/diff PASS.
- [x] Install over existing app, recreate development domain, create compact fixtures; repeat enumerate/stat/restart/hydration and characterize external renames. Expected: persistent opaque IDs, exact contents, safe stale/cross-domain failure.
- [x] Test full-only binary/photo/EXR/video consumers and app->DATA rejection. Expected: exact results, zero partial callbacks/awake timeout.
- [x] Measure initial/repeat enumeration; remove domain/mapping/Agent and exact remote UUID root, preserving parent.
- [x] Rerun final required Go/native/build/signature checks. Expected: acceptance and regression PASS, cleanup verified.

## Final review and finish

Inspect the full staged diff against the starting HEAD and dispatch one fresh
reviewer. Fix important findings with RED/GREEN and full regression. Commit and
push only origin/cloudmount-macos after acceptance; no PR or next phase.
