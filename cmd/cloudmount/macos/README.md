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
`CLOUDMOUNT_TEAM_ID` to `DEVELOPMENT_TEAM`. The Mach service appends `.agent` to
the resulting App Group identifier.

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
File Provider receives only the domain identifier and relative paths; it never
receives or stores the rclone remote selector.

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
use VFS internally as their own implementation detail. The prototype uses temporary
path-derived identifiers and full-directory `List`, and does not provide writes
or remote-change synchronization.

Run the native capability, range-alignment, and domain-store tests with:

```sh
cmd/cloudmount/macos/Scripts/test-file-provider.sh
```

The capability test checks Objective-C protocol advertisement on the actual
extension class; compiling it also checks the retained partial implementation.

Inspect the unified log when validating List, Stat, and Fetch operations:

```sh
log show --last 5m --predicate 'subsystem == "org.rclone.cloudmount"' --style compact
```
