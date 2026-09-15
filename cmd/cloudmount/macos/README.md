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
`Rclone CloudMount Test`. `domain-add-test` stores the selected rclone root in the
domain's `userInfo`; it does not store credentials or an rclone configuration.

The read-only data path is direct:

```text
File Provider -> authenticated XPC -> Agent -> fs/cache.Get
              -> fs.Fs.List / fs.Fs.NewObject -> fs.Object.Open
```

CloudMount does not import or instantiate `vfs.VFS`. Some registered backends may
use VFS internally as their own implementation detail. Phase 2A uses temporary
path-derived identifiers and full-directory `List`, and does not provide writes,
partial fetching, Go transfer cancellation, or remote-change synchronization.

Inspect the unified log when validating List, Stat, and Fetch operations:

```sh
log show --last 5m --predicate 'subsystem == "org.rclone.cloudmount"' --style compact
```
