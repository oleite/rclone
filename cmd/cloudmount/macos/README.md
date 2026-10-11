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
"$APP/Contents/MacOS/RcloneCloudMount" domain-add-test /absolute/path/to/test/root
"$APP/Contents/MacOS/RcloneCloudMount" domain-list
```

The remaining commands are `domain-remove-test` and `agent-unregister`. Status may
be `notRegistered`, `enabled`, `requiresApproval`, or `notFound`. If registration
requires approval, enable Rclone CloudMount in **System Settings > General > Login
Items & Extensions** and run the status command again.

Debug builds request File Provider testing mode so the test domain is always
enabled. Release builds omit that entitlement and report the domain's real
`userEnabled` value; enable the provider under **System Settings > General > Login
Items & Extensions > File Providers** when needed.

Personal Teams cannot sign the testing-mode entitlement. For local development
with a Personal Team, set `CLOUDMOUNT_APP_DEBUG_ENTITLEMENTS` to
`App/RcloneCloudMount.entitlements` and clear
`CLOUDMOUNT_TESTING_MODE_SWIFT_CONDITION` in `Local.xcconfig`. This selects normal
user-enabled behavior without changing Release configuration.

The fixed development domain is `org.rclone.cloudmount.test`, displayed as
`Rclone CloudMount Test`. `domain-add-test` first stores the domain-to-remote
mapping in the LaunchAgent and then registers a plain File Provider domain. The
File Provider receives opaque item/parent identifiers and item metadata; it never
receives or stores backend-relative paths or the rclone remote selector.

The LaunchAgent persists its versioned mapping in
`~/Library/Application Support/Rclone CloudMount/domains.json`. The directory is
mode `0700`, the file is mode `0600`, and updates are atomic. Removing the test
domain removes the File Provider domain first and its Agent mapping second.

The Agent exposes two mutually authenticated Mach services in the same process.
The containing app alone can use the control service for ping and domain mapping;
the File Provider alone can use the data service for List, Stat, and Fetch. Each
listener enforces the exact same-team client identifier for its role.

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

Schema version 1 initializes a fresh empty database transactionally. A newer,
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
run `domain-remove-test` with the old installed app, update the app, and then
`domain-add-test <test-root>` with the new app. Old IDs are never reinterpreted as
paths, and CloudMount never modifies Apple's private File Provider database.

`enumerateChanges` remains a limited no-op with a constant anchor; signaling an
enumerator is not remote-change synchronization. A direct provider enumeration
reconciles the catalog, but cached Finder namespaces may require domain recreation
to discover external changes in this development phase. No polling/journal is added.
Before simultaneous CloudMount domains, data-plane authorization must also bind a
provider domain to the domain identifier it is permitted to submit; catalog lookup
isolation alone does not provide that authorization.

Run native identity/catalog, lifecycle, capability, range and domain-store tests with:

```sh
cmd/cloudmount/macos/Scripts/test-file-provider.sh
```

The capability test checks Objective-C protocol advertisement on the actual
extension class; compiling it also checks the retained partial implementation.

Inspect the unified log when validating List, Stat, and Fetch operations:

```sh
log show --last 5m --predicate 'subsystem == "org.rclone.cloudmount"' --style compact
```
