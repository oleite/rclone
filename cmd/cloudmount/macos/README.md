# Rclone CloudMount macOS development shell

This optional Xcode project proves the native File Provider to LaunchAgent path for
CloudMount. It does not contain the rclone engine and is not part of normal Go builds.

## Local configuration

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, then set an Apple
development team, a unique bundle identifier, and an App Group owned by that team.
The local file is ignored by git. The macOS deployment target is 13.0.

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
"$APP/Contents/MacOS/RcloneCloudMount" domain-add-test
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

The fixed test domain is `org.rclone.cloudmount.synthetic-test`, displayed as
`Rclone CloudMount Test`. Its read-only `hello.txt` is populated by the agent with:

```text
Hello from rclone cloudmount agent
```

Inspect the agent's unified log when validating the writer:

```sh
log show --last 5m --predicate 'subsystem == "org.rclone.cloudmount"' --style compact
```
