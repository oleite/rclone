# Persistent CloudMount remote synchronization

## Intent and boundaries

External changes automatically converge into the existing three mounted domains,
including after Agent downtime. CloudMount remains read-only, full-hydration-only,
backend-generic and FD-only. No domain recreation or UUID reset. Same-user,
role-authenticated XPC and the accepted provider-wide principal remain unchanged.
External mutation stimuli are confined to fresh disposable fixture subtrees.

## Selected architecture

Use ChangeNotify as a live hint plus authoritative directory reconciliation and a
CloudMount-owned durable journal. Hint-only processing misses Agent-downtime and
deletion events; persisting Graph tokens would add an unnecessary backend-specific
API. Periodic scans alone are correct but less responsive. Use both independent
mechanisms, sharing the existing per-directory generation/discovery gate.

Apple's installed SDK requires replicated providers to signal only `.workingSet`.
The working set here is the previously observed catalog namespace, not the entire
drive. After directory enumeration, that directory and children belong to it.
Publish its persistent deltas and bounded initial cached pages. Directory and
single-item enumerators filter the same domain-wide journal when requested.
Reference: NSFileProviderManager.h, NSFileProviderReplicatedExtension.h and
[Apple's sample](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions).

## SQLite v2

Transactional v1 migration retains every domain binding and item row. Add per-domain
random sync epoch, monotone revision and journal floor; a directory snapshot table;
and ordered journal rows with parent, UUID, kind and safe metadata payload.
Migration restores authoritative parents evidenced by existing v1 child rows:
only successful complete discovery inserts such children in the production path.
A merely known directory does not thereby acquire an authoritative child snapshot.
Previously empty v1 directories cannot be distinguished from unopened ones and
become authoritative on their next enumeration. Existing nonempty observed roots
and nested directories participate in startup catch-up without a recursive crawl.

Reconcile validates the entire successful listing before any mutation. First
enumeration establishes a baseline without manufacturing update rows for every
child. Subsequent differences and Stat updates append durable transitions in the
same transaction. Deletions retain tombstones for the entire retired subtree.
No-op scans do not advance revision. Baseline namespace changes advance revision
once without a synthetic journal burst, protecting initial working-set pagination.
Known-continuity local moves remain journal-consistent, but external rename/move
uses conservative delete/create; no backend-ID matching is introduced.

Retain at most 20,000 journal entries per domain. Record the greatest removed
sequence as the floor. Older anchors expire, never silently skip lost history.
SQLite/query/remote errors preserve the old snapshot and do not infer deletions.

## Anchors and pagination

Canonical UTF-8 `2:<lowercase epoch UUID>:<nonnegative decimal sequence>` is below
Apple's 500-byte bound and contains no path/selector/backend token. Epoch mismatch,
malformed/noncanonical bytes, future revisions or revisions below floor expire.
Epoch persists across restart and is replaced on domain rebind/removal.
Journal pages are bounded to 200 rows. Filter by container, advance to the last
consumed sequence when more remain, otherwise to current domain revision even if
intermediate revisions concern other containers. Coalesce a page's changes by UUID
to its final state so an update/delete burst is not delivered ambiguously.
Initial working-set pages use a canonical epoch/revision/offset cursor and expire
if the namespace changes mid-pagination; they list cached items only.

## Go watch and Agent coordinator

Go owns opaque watch handles, cancellable contexts, interval channels and bounded
hint queues. Queue overflow produces a rescan-all hint rather than lost correctness.
Stop is idempotent, closes the interval channel/cancels context, releases the handle
and wakes blocked Next. Watch paths never cross DATA XPC. No core/backend changes.

Each Agent domain coordinator owns its binding generation and independent worker.
Start live hints and startup catch-up; debounce hints for one second into a set of
affected authoritative containers. Production hint interval is 60 seconds and
safety interval 300 seconds; retry failures with bounded exponential backoff.
Only known complete snapshots are scanned, root before descendants. Unsupported
watchers retain safety scans. Removal/remap/shutdown stop the watch and reject stale
completions through existing generation validation. A shorter acceptance interval
may be injected locally without changing production defaults.

Commit precedes signaling. The embedded Agent is an Apple-supported related
executable; use NSFileProviderManager for registered domains and signal working set.
Verify actual document-group access/signaling at runtime. If direct access fails,
investigate the smallest supported related-process alternative without weakening
XPC or requiring a manually open App. Signal errors are retried independently of
remote reconciliation; restart re-signals durable pending state.

## Validation and privacy

Deterministic native tests cover migration, snapshots, journal/anchor/pruning,
rollback, subtree deletion, pagination, restart, multi-domain generation races,
coalescing, failure/backoff and Provider observer translation. Go fake-backend tests
cover watch support, delivery, overflow, stop/release and concurrent domains under
race detection. Production callbacks and stores remain real; only remote/network
and XPC boundaries are substituted in deterministic tests.

Signed runtime preserves all three IDs, tests create/modify/rename/move/delete,
materialized-byte replacement, downtime recovery and independent concurrent changes
through each configured Fs (including crypt). Mutate only fresh phase-owned folders
with ordinary rclone, then remove exactly those folders through the same selectors.
Record public IDs/revisions/counts/timings; keep unrelated names, paths, configuration,
backend/delta tokens and credentials private. Final complete Go/native/build/security
checks and one fresh-context review precede origin-only push. Leave working domains
mounted and report limitations honestly; no next phase.
