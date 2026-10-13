# Rclone CloudMount macOS development shell

This optional Xcode project implements the native File Provider to LaunchAgent path
for CloudMount. The LaunchAgent alone links the dedicated `librclone/cloudmount`
C archive; the app and File Provider do not contain the Go runtime. Normal rclone
Go builds remain independent of Xcode.

## Local configuration

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then set an Apple
development team, a unique bundle identifier, and the App Group suffix.
The local file is ignored by git. The macOS deployment target is 13.0.

CloudMount uses the macOS Team-ID App Group form
`<Developer-Team-ID>.org.rclone.cloudmount`, not a registered `group.*` App Group.
The committed unsigned-build placeholder is `TEAMID`; `Local.xcconfig` maps
`CLOUDMOUNT_TEAM_ID` to `DEVELOPMENT_TEAM`. The Mach services append
`.agent.control` and `.agent.data` to the resulting App Group identifier.

Build the `RcloneCloudMount` scheme in Debug with automatic signing. For stable
runtime registration, copy the result to `~/Applications/RcloneCloudMount.app`
before using the control commands. The build embeds the extension at
`Contents/PlugIns`, the agent at `Contents/MacOS`, and its generated property list
at `Contents/Library/LaunchAgents`.

```sh
APP="$HOME/Applications/RcloneCloudMount.app"
"$APP/Contents/MacOS/RcloneCloudMount" agent-register
"$APP/Contents/MacOS/RcloneCloudMount" agent-status
"$APP/Contents/MacOS/RcloneCloudMount" agent-ping
"$APP/Contents/MacOS/RcloneCloudMount" domain-add "Example location" example:
"$APP/Contents/MacOS/RcloneCloudMount" domain-list
```

The remaining commands are `domain-remove <domain-id>`, `domain-path <domain-id>`
and `agent-unregister`. `domain-path` queries Apple's `getUserVisibleURL` from the
installed containing app; it does not assume a CloudStorage filesystem location.
Status may
be `notRegistered`, `enabled`, `requiresApproval`, or `notFound`. If registration
requires approval, enable Rclone CloudMount in **System Settings > General > Login
Items & Extensions** and run the status command again.

Debug builds request File Provider testing mode so development domains are always
enabled. Release builds omit that entitlement and report the domain's real
`userEnabled` value; enable the provider under **System Settings > General > Login
Items & Extensions > File Providers** when needed.

Personal Teams cannot sign the testing-mode entitlement. For local development
with a Personal Team, set `CLOUDMOUNT_APP_DEBUG_ENTITLEMENTS` to
`App/RcloneCloudMount.entitlements` and clear
`CLOUDMOUNT_TESTING_MODE_SWIFT_CONDITION` in `Local.xcconfig`. This selects normal
user-enabled behavior without changing Release configuration.

`domain-add <display-name> <remote:path>` generates a stable opaque
`org.rclone.cloudmount.domain.<UUID>` identifier and prints it before side effects.
New IDs do not encode account, remote or pathname information. Every add allocates
a fresh ID; an interrupted attempt can be cleaned up using its printed ID.
Registration first stores the domain-to-remote
mapping in the LaunchAgent and then registers a plain File Provider domain. The
File Provider receives opaque item/parent identifiers and item metadata; it never
receives or stores backend-relative paths or the rclone remote selector.

The LaunchAgent persists its versioned mapping in
`~/Library/Application Support/Rclone CloudMount/domains.json`. The directory is
mode `0700`, the file is mode `0600`, and updates are atomic. JSON remains v1;
SQLite v2 transactionally migrates v1 bindings/items without resetting their UUIDs.
Display names/registered IDs remain authoritative in NSFileProviderManager.
Removing a domain removes the File Provider domain first and its Agent mapping
second, without changing another domain. Failed/uncertain registration retains
mapping until a live registration can be removed safely; retry cleanup using the
printed ID. Existing owned-namespace IDs can also be removed with the general command.
Add/remove operations hold a per-domain, process-shared lifecycle lock through
inspection and rollback. A competing operation on that ID fails with retry
guidance; unrelated domains remain independent. Empty private lock files are
retained in `Application Support/Rclone CloudMount/lifecycle-locks` to avoid
replacing an inode another process may have opened.

The Agent exposes two mutually authenticated Mach services in the same process.
The containing app alone can use the control service for ping and domain mapping;
the File Provider alone can use the data service for List, Stat, Fetch and durable
change enumeration. Each
listener enforces the exact same-team client identifier for its role and the
Agent's effective user. Clients enforce the Agent's Apple anchor/team/identifier.

Multiple domains share one authenticated Provider principal for this macOS user.
Apple permits several replicated-extension instances in one process; public XPC
peer attributes identify the process/user, not the originating domain instance.
The trusted extension services all this user's configured CloudMount domains.
Domain+item catalog lookup prevents accidental cross-domain IDs, but it is not
cryptographic per-instance authorization. No shared-container secret is claimed
to provide that separation. See Apple's [domain documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain)
and [XPC peer attributes](https://developer.apple.com/documentation/foundation/nsxpcconnection).

The read-only data path is direct:

```text
File Provider -> authenticated XPC -> Agent -> fs/cache.Get
              -> fs.Fs.List / fs.Fs.NewObject -> fs.Object.Open
```

For hydration, the File Provider creates its temporary destination and passes an
open `FileHandle` over XPC. The Agent passes that descriptor to the Go bridge;
Go duplicates it and owns only the duplicate. No destination pathname crosses
the XPC boundary.

## Hydration baseline

The production extension advertises only `NSFileProviderReplicatedExtension` and
uses `fetchContents` for cold content. Full-only hydration is a temporary
correctness fallback: runtime tests found application-visible POSIX `ETIMEDOUT`
during implicit partial-to-full escalation, although ranged transport returned
correct bytes. The underlying runtime cause remains unresolved. Random reads and
media seeks therefore download the whole file before useful content access.

The partial implementation remains compiled in `FileProviderExtension.swift`;
there is no public hydration switch or separate duplicated implementation.
Future experiments can intentionally restore `NSFileProviderPartialContentFetching`
conformance and revise the production capability guard, but must independently
validate the lifecycle before changing the default.

The retained partial implementation uses Apple's aligned requested range, a DATA-XPC operation
identifier, and `fs.RangeOption`. Go sizes the temporary file to the retrieved
range end, seeks to the retrieved offset, and writes only that exact range so a
prefix before a nonzero offset stays sparse. Full and partial fetches use private cancellable
transfer handles; cancellation closes an active source reader.

CloudMount does not import or instantiate `vfs.VFS`. Some registered backends may
use VFS internally as their own implementation detail. Directory enumeration uses
full-directory `List`; CloudMount does not provide writes or remote-change synchronization.

## Persistent identities

The Agent owns `~/Library/Application Support/Rclone CloudMount/catalog.sqlite3`,
with private directory/file permissions (`0700`/`0600`). Apple SQLite is the only
database dependency. One locked connection uses transactional directory
reconciliation, unique `(domain, identifier)` and `(domain, path)` constraints,
and domain-scoped parent foreign keys. Absent directories delete their catalog
subtree. Successful same-path/same-kind discovery retains its identity.

Non-root IDs are canonical lowercase `i-<UUID>` values, independent of pathname
and type. Root remains Apple's `.rootContainer`; it has no artificial catalog
UUID. DATA List accepts a parent ID; Stat and Fetch accept an item ID. Only the
Agent resolves IDs to backend paths before calling the existing Go bridge.
Malformed, unknown, legacy path-derived and cross-domain IDs fail as `noSuchItem`.

Schema version 2 initializes a fresh database or migrates version 1 transactionally. A newer,
corrupt or structurally invalid catalog fails closed; it is not silently reset.
The catalog stores relative paths, metadata, stable parent IDs, optional backend
IDs, separate versions and created/last-seen timestamps—not selectors, credentials
or file content. A domain binding hashes its configured selector. Changing the
mapping retires old IDs; configuring the same selector preserves them.

The Agent serializes mapping/catalog work with configuration changes, but backend
I/O remains concurrent. Domain-generation snapshots are validated before catalog
commits and successful transfer replies, rejecting stale completions after remapping
or remove/re-add. Discovery of the same directory is ordered within a binding
generation so an older observation cannot retire IDs returned by a newer one;
unrelated directories and transfers remain concurrent. Configuration writes JSON
before rebinding SQLite; removal purges
SQLite before removing JSON. Every DATA operation validates the binding before
resolving an ID. A crash between these stores cannot apply old identities to a new remote;
an interrupted removal may retain a mapping but its old identities are gone.

Content versions hash kind/size/mtime, without pathname. Metadata versions also
hash filename and stable parent ID. They are best-effort metadata observations,
not content hashes: equal size/mtime can hide content changes. Backend IDs are
recorded only as optional evidence, never assumed globally unique or rename-stable.

Known-continuity catalog moves update paths and directory descendants atomically
while retaining IDs. This does not expose a File Provider rename/write operation.
External rename continuity is conservatively delete/create until demonstrated
backend IDs support it. SMB fixture entries provided no backend IDs.

Upgrade from the path-ID prototype requires development-domain recreation:
remove the old domain using its existing ID, update the app, and then use
`domain-add <display-name> <remote:path>` with the new app. Old IDs are never reinterpreted as
paths, and CloudMount never modifies Apple's private File Provider database.

## Persistent remote changes

The Agent owns a durable domain-wide revision, random binding epoch, bounded
journal and authoritative-directory snapshot table. A complete first listing
establishes a baseline; subsequent List/Stat transitions append updates and
subtree tombstones in the same SQLite transaction. No-op scans do not advance
revision. Directory existence alone does not mean its children were enumerated.
Migration restores observed parents evidenced by v1 child rows; previously empty
v1 directories become authoritative on their next enumeration.

An opaque anchor encodes only version, epoch and revision. Malformed, wrong-domain,
retired-epoch, future or pruned anchors report `syncAnchorExpired`; retained history
is never silently skipped. The journal retains 20,000 rows per domain. DATA change
pages are capped at 200 rows, with container filtering and final-state coalescing.
Cached Working Set initial pages also expire if the namespace changes mid-page.

Each domain has an independent Agent coordinator and Go-owned cancellable watch.
`fs.Features.ChangeNotify` is a hint, not the authority: OneDrive starts at a latest
in-memory Graph token and deletion notifications can be incomplete. Crypt handles
its own path decryption. Startup and periodic authoritative rescans recover missed
events, including Agent downtime, using only complete observed directory snapshots.
Unopened subtrees are not recursively crawled. Failed listings retain the old
snapshot and retry with bounded backoff; queue overflow requests a safe rescan.
Removal/remapping stops the old watcher and existing generation/discovery gates
reject stale completions.

Production defaults are a 60-second hint interval, 300-second safety interval and
one-second debounce. Narrow build settings `CLOUDMOUNT_SYNC_HINT_INTERVAL` and
`CLOUDMOUNT_SYNC_SAFETY_INTERVAL` may inject shorter acceptance intervals without
altering these defaults. Embedded backend diagnostic strings/attributes are withheld
because they can contain paths, selectors or tokens; severity and sanitized Agent
outcomes remain available.

After durable commit, the embedded Agent uses Apple's related-executable
`NSFileProviderManager` support to signal `.workingSet`. Replicated providers ignore
directory-specific signals. The working set is the observed catalog namespace;
it is not a recursive whole-drive listing. Real `currentSyncAnchor` and
`enumerateChanges` callbacks feed updates/deletions to fileproviderd. Catalog detection,
signal acceptance, system ingestion and content rehydration are asynchronous, not
one atomic user-visible event. See [Apple's replicated-provider sample](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions)
and the installed `NSFileProviderManager.h` / `NSFileProviderReplicatedExtension.h` contracts.

Live rclone configuration retargeting of a mounted domain is unsupported: remove
and reconfigure the domain before changing its backing configuration. Selector
binding is not a fingerprint of the underlying account/backend instance.

The deferred generic write substrate must address atomic no-clobber commits:
current generic Move/SMB rename can replace an external destination created after
the last absence check. No write capability or dependency fork is added here.

Run native identity/catalog, lifecycle, capability, range and domain-store tests with:

```sh
cmd/cloudmount/macos/Scripts/test-file-provider.sh
```

The capability test checks Objective-C protocol advertisement on the actual
extension class; compiling it also checks the retained partial implementation.

## OneDrive-backed domain characterization

OneDrive objects and directories expose Microsoft's driveItem IDs. The backend
normalizes available drive IDs with item IDs (`drive#item`) and handles remote
items using their referenced drive/item identity. The crypt backend forwards
wrapped object/directory identity. These are private Agent catalog evidence, not
Provider identifiers. Repeated read-only discovery can establish stability at a
path; it does not by itself test external rename/move. Microsoft's [ID addressing
contract](https://learn.microsoft.com/en-us/graph/onedrive-addressing-driveitems)
supports continuity within a drive across rename/move. Runtime rename/move proof
and safe generic reconciliation remain deferred to an authorized write fixture;
the current catalog does not globally merge entries by backend ID.

OneDrive exposes polling-based `ChangeNotify` using Graph delta, except in the
backend's documented China-region case. The optional `delta` configuration
advertises `ListR`; recursive delta works at drive root and may enumerate the
whole drive before filtering a subroot. Ordinary `List` uses children listings.
CloudMount starts neither change polling nor recursive delta enumeration.
Graph's [delta feed](https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-1.0)
provides continuation/deletion evidence, but File Provider still needs durable
anchors, catalog updates and working-set changes—not merely path notifications.

For future writes, Graph [upload sessions](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
offer conflict behavior and ETag/cTag preconditions. [Move](https://learn.microsoft.com/en-us/graph/api/driveitem-move?view=graph-rest-1.0)
and [delete](https://learn.microsoft.com/en-us/graph/api/driveitem-delete?view=graph-rest-1.0)
also document conditional requests. These API-specific guarantees must not be
assumed to exist in the generic rclone mutation contract. Current OneDrive
Move/DirMove PATCH item IDs within a drive; Remove DELETEs by ID, without a
caller-supplied base-version precondition in those helpers. Upload session
construction does not expose an explicit conflict-policy/precondition contract
to CloudMount. API response types contain ETag/cTag, but current CloudMount
versions still use kind/size/mtime. No OneDrive or generic write interface is
changed, and production capabilities remain read-only.

Inspect the unified log when validating List, Stat, and Fetch operations:

```sh
log show --last 5m --predicate 'subsystem == "org.rclone.cloudmount"' --style compact
```
