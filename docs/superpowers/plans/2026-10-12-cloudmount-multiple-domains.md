# CloudMount Multiple Domains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three independent native read-only Finder locations backed by configured rclone selectors.

**Architecture:** Dynamic App lifecycle replaces fixed test-domain commands. Keep the existing Agent-owned mapping, domain-scoped SQLite and Provider instance routing; document the provider-wide authenticated principal.

**Tech Stack:** Swift, FileProvider, ServiceManagement, SQLite, existing Go C bridge.

**Spec:** docs/superpowers/specs/2026-10-12-cloudmount-multiple-domains-design.md

## Global Constraints

- Starting HEAD 4096935d48dff3312929f88f56d028cdd2e39ad8; branch cloudmount-macos.
- No remote mutation; no real account/selector/path data in commits or diagnostic output.
- macOS 13.0; Agent arm64 + x86_64; Provider sandboxed, App/Agent unsandboxed.
- Mutual CONTROL/App and DATA/Provider authentication, FD-only contents.
- Full-only hydration, backend/all, fs/cache.Get -> fs.Fs/fs.Object; no VFS frontend.
- Preserve JSON/SQLite v1, stable UUIDs and per-domain binding generations.
- No SMB write work, new dependency, offline behavior, polling, eviction or public CLI.
- Existing specified checkout; native inline execution, one fresh final reviewer.
- Commit/push only after runtime acceptance; temporary harnesses never committed.

## Review Focus

- Registration can partly succeed before returning an error: remove registry state before mapping rollback (Task 1).
- Failed removal cannot orphan a live domain without its mapping (Task 1).
- Display names/IDs with Unicode, separators or control characters need validated behavior (Task 1).
- Identical item UUID strings in separate domains must never bypass domain scope (Task 2).
- A stalled domain must not hold another domain's discovery gate (Task 2).

---

### Task 1: Opaque domain lifecycle

**Files:** Shared/CloudMountShared.swift; App/DomainLifecycle.swift (new); App/main.swift; Xcode project; Tests/DomainLifecycleTests.swift (new); Scripts/test-file-provider.sh; README.md (all under cmd/cloudmount/macos).

**Interfaces:** Produce CloudMountDomainIdentifier.make()/isValid()/isManaged(), DomainLifecycle.add(displayName:remote:identifier:), remove(identifier:); consume injected registry and Agent control closures.

- [ ] Write native tests: 100 generated IDs unique/canonical; malformed IDs rejected; Unicode names survive; three distinct domains persist; collision doesn't remap; configure/registration/partial-registration/rollback/remove failures preserve correct per-domain state; unknown removal has no effects.
- [ ] Compile/run tests against missing implementation. Expected: RED, missing domain model/lifecycle.
- [ ] Implement model/helper, wire general commands, remove fixed registration constants. Keep legacy ID removal-only. Add helper to App Xcode sources.
- [ ] Run `cmd/cloudmount/macos/Scripts/test-file-provider.sh`. Expected: all existing plus lifecycle suites PASS.

### Task 2: Domain isolation and trust regression

**Files:** Tests/MultiDomainTests.swift (new); Scripts/test-file-provider.sh; Agent/main.swift; README.md.

**Interfaces:** Consume existing DomainCatalog Snapshot/withSnapshot/withDirectoryDiscovery, ItemCatalog resolve/reconcile and Provider init(domain:).

- [ ] Add real JSON/SQLite tests for A/B/C restart, remap/remove isolation, same UUID representation with different domain rows, stale A completion rejection, unrelated B/C discovery while A waits; root context display names and per-instance enumeration/fetch runtime tests.
- [ ] Run new tests and existing suites. Expected: current domain-scoped core already passes; fix only an observed regression with a RED reproducer.
- [ ] Enforce same effective user at the listener and document provider-wide principal with Apple source references; keep exact role requirements unchanged.
- [ ] Run native suite. Expected: PASS, full-only conformance retained.

### Task 3: Signed build and real three-domain acceptance

**Files:** Only private local diagnostic harnesses/artifacts; update README backend/security characterization without account data.

**Interfaces:** Consume general App commands and unchanged production DATA protocol.

- [ ] Build signed Debug and unsigned Release; inspect installed signatures/entitlements, macOS minimum and Agent architectures. Expected: PASS.
- [ ] Register Agent, require enabled/pong, register three selectors with opaque IDs. If manual macOS enablement is required, request exact normal UI action and wait.
- [ ] Signed Provider-role harness invokes production enumerators/items/fetch methods for actual domains. Verify root/nested/repeated IDs/parents, A IDs fail B, role/foreign rejection. No private filenames emitted.
- [ ] Compare suitable small ordinary baselines to mounted reads, observe full-only logs; Finder/Quick Look/Preview where practical. Expected: byte equality and zero partial callbacks.
- [ ] Restart Agent/Provider where practical, remove/readd one domain; require B/C IDs and readings unchanged, removed A gets fresh IDs. Characterize safe reconnect or mark untested.
- [ ] Inspect OneDrive/crypt source + official Apple/Graph docs; report ID/delta/write evidence precisely without implementing writes or speculative rename continuity.

### Task 4: Regression and final acceptance commit

**Files:** Complete intended diff; no temporary tests/instrumentation/account data.

**Interfaces:** Consume accepted installed products/domain IDs and private acceptance ledger.

- [ ] Run CloudMount Go tests/race, full Go suite, `go build -p 1 ./...`, native suites, Debug/Release/signing checks and `git diff --check`. Expected: PASS.
- [ ] Leave functioning three domains registered; remove only local diagnostic copies/harnesses and unnecessary private logs. Expected: remote data untouched.
- [ ] Inspect entire diff from base for leakage/destructive operations. Commit focused production changes only after runtime acceptance.
- [ ] Fresh-context most-capable reviewer checks full committed range, spec, plan and ledger. Address Critical/Important findings in one TDD pass; record minors/rulings.
- [ ] Push origin/cloudmount-macos only; verify remote SHA/clean worktree. Expected: PASS and no upstream PR.
