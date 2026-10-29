# Development

## Toolchain

- macOS 13+ deployment target; a toolchain supporting Swift tools 5.9+.
- Swift Package Manager, AppKit, SwiftUI, ServiceManagement and LocalAuthentication.
- Sparkle 2.10.1, pinned exactly in `Package.swift` and `Package.resolved`.
- Python 3 for packaging metadata and release preflight.
- Developer ID signing for helper-enabled bundles.

## Layout

| Location | Responsibility |
|---|---|
| `Sources/Vaken` | Native UI, session controller, authentication, XPC client, updater and artwork |
| `Sources/VakenCore` | Configuration, power/session policy, process identity, authentication-policy storage and legacy gate utilities |
| `Sources/VakenService` | Fixed XPC protocol, replies and peer signing requirements |
| `Sources/VakenHelper` | Privileged writes, session lease, deadline/power/process checks and display assertion |
| `Tests/VakenTests` | Controller, configuration, policy, process and trust regressions |
| `Resources` | Bundled LaunchDaemon declaration |
| `Assets` | Editable SVG artwork and README images |
| `scripts` | Bundle assembly, legacy grant maintenance and local update preparation |

Legacy grant utilities remain for existing installations and regression coverage. The live app uses the signed helper, not those utilities.

## Build and test

```sh
swift package resolve
swift test
python3 -m unittest discover -s Tests/ReleaseToolsTests -v
sh scripts/make-app.sh
```

The build script writes `build/Vaken.app` unless `VAKEN_APP_PATH` names another staging bundle. It preserves Sparkle framework symlinks, signs nested executables inside-out, signs the sleep helper and enclosing app, and verifies the final signature. It does not register any service, install into Applications, increment a version or publish artifacts.

`scripts/make-dmg.sh <stapled-app> <new-output.dmg>` stages the signed app and an Applications shortcut, creates a read-only image and signs it. Image notarization is separate. The release workflow notarizes both containers and attaches the DMG with its own checksum sidecar while retaining the Sparkle ZIP.

The current signing identity is configured in `scripts/make-app.sh`; the expected team is in `ServiceIdentity`. A fork needs its own consistent app/helper identifiers, team requirements, signing identity and update keys. Changing only the outer app signature is insufficient. Never disable library validation or add a debug entitlement to bypass helper verification.

Version 0.3.2 and build number 5 are owned by `AppInfo.swift`, exposed by `--version` and `--build-number`. Release owners must approve changes to both fields separately. The tag workflow validates the committed values and creates a draft, never a published release; see [releases](releases.md).

## Native previews

```sh
build/Vaken.app/Contents/MacOS/vaken --render-previews build/previews
build/Vaken.app/Contents/MacOS/vaken --render-assets build/artwork
```

These commands use isolated view models and do not install the helper, request authentication, write live preferences or start the updater. The preview set includes configured and unconfigured update states in both appearances. Render fixtures in an isolated macOS environment when working alongside an installed app.

## Verification

Automated tests exercise injected authentication/service outcomes, policy persistence, stale revisions, process exit/PID reuse, configuration validation, update interaction locks and quit cancellation. Some tests retain coverage for the earlier command-based gate; those do not prove current privileged XPC behavior.

For UI changes, inspect rendered light/dark fixtures. For packaging changes, run strict deep code-signature verification, check nested framework symlinks and inspect `otool -L` and `otool -l` for the app executable. Never treat a successful compile as proof that the framework loads in a self-contained bundle.

Real Touch ID, SMAppService approval, helper replacement, physical unplug, display assertion release, crashes, locked-screen operation and signed old-to-new Sparkle installation require separate integration checks. Do not run them against an active remote session without coordinating the interruption.

## Contributing

Keep changes focused, add a regression test for behavior changes and document observable limitations. Do not commit signing keys, private diagnostics, machine-specific paths or build output. Follow the current [system design](design/vaken.md), and include verification evidence with the proposed change.
