# CloudMount persistent identities

Phase 4 authority: the director's persistent identity catalog specification.
The outcome is opaque, durable File Provider identities, not remote synchronization.

## Architecture

The per-user Agent owns `Application Support/Rclone CloudMount/catalog.sqlite3`.
Apple SQLite provides transactions and constraints without an added dependency.
DATA requests carry a domain and opaque item/parent identifier. Only the Agent
resolves the catalog's relative path and calls the existing Go path bridge.
Provider responses contain identifiers and public item metadata, never relative
paths, backend IDs or selectors. Root uses File Provider's root identifier.

One locked SQLite connection serializes catalog transactions. A small mapping lock
captures domain-generation snapshots and validates them again before committing
catalog results or completing content transfers. Backend I/O stays concurrent and
outside that lock. Stale completions cannot repopulate a remapped domain, including
remove/re-add and A-to-B-to-A transitions. Cancellation stays independently callable.
Discovery gates serialize observation and reconciliation of the same directory
within a binding generation; unrelated directories and transfers stay concurrent.
Gates are retained only while callers are active, including callers waiting their turn.

## Persistence and reconciliation

Version 1 has domain bindings (SHA-256 of selector, no selector itself) and items
(domain, UUID, parent UUID, relative path, filename, kind, size, mtime, optional
backend ID, content/metadata versions, created/last-seen timestamps). Domain+ID
and domain+path are unique. Composite parent foreign keys cascade deletion.
Each successful directory listing reconciles its immediate children atomically.
Same-path/same-kind entries retain IDs; absence or changed kind retires the old ID.
Explicit known-continuity path updates retain IDs and rewrite directory descendants
in one transaction; there is no production remote rename operation yet.

Configuration remains in domains.json. Every DATA request first checks the
SQLite binding against the current mapping. Configure writes JSON then binds;
remove purges SQLite then removes JSON. A crash between stores cannot expose old
IDs under a new selector: recovery checks the binding before resolution. Removal
interrupted before JSON removal may retain the mapping but only fresh IDs.

## Identity and versions

Non-root IDs are canonical lowercase `i-UUID`, independent of kind and path.
Old path-encoded, malformed, unknown and cross-domain IDs fail as noSuchItem.
Development domains must be recreated on upgrade from the path-ID prototype.
Content versions hash kind/size/mtime; metadata versions additionally hash stable
parent ID and filename. These are best-effort metadata observations, not content
digests. Rename alone does not change content version. No remote download is
performed to compute versions.

External rename continuity is not inferred from unproven backend IDs. This phase
characterizes SMB and conservatively uses delete/create when continuity is unknown.
No writes, polling, change journal, partial hydration, eviction or sync is added.

## Safety and acceptance

SQLite failures and newer schema versions fail closed, without backend error text.
Private directory/file permissions are 0700/0600. Tests exercise reopening,
transactions, duplicates, concurrent discovery, rename/move, domain isolation,
purge, corruption and schema rejection. Native signed runtime uses only the
authorized disposable `ha:media/testing/cloudmount-phase4-UUID` subtree.
Full-only hydration, CONTROL/DATA authorization, FD-only transfer, macOS 13.0,
universal Agent and private paths remain unchanged. Full Go/native regression,
SMB restart/identity/media acceptance and cleanup precede commit/push.
