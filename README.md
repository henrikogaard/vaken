# Vaken

Keep your Mac awake. Let your screen rest.

<img src="Assets/Vaken.png" alt="Vaken outline sun icon" width="128">

Vaken is a native macOS menu-bar app for keeping a Mac reachable during remote work, builds and other long-running tasks. It controls system sleep separately from display sleep and screen locking.

## Features

- One Keep awake switch, with an outline sun for On and crescent moon for Off.
- Manual, Follow power source, and Manual + safety net modes, selectable from the dropdown.
- Quick timers, countdown, +15 minutes, custom durations and clock deadlines.
- Sessions that end when a selected application or process exits.
- Battery cutoff and Low Power Mode protection; optional display-awake control.
- Native Touch ID or password authentication, with an explicit opt-out for future starts.
- Configurable global shortcut, launch at login and state notifications.
- Sparkle update checks with user-controlled installation.

## Requirements and installation

Requires macOS 13 or later. Current builds target the architecture of the build machine; an Intel distribution has not been verified.

Public release downloads are not available yet. For a locally supplied signed build:

1. Copy `Vaken.app` to a stable Applications folder before opening it.
2. Choose **Set up helper…** in Vaken. Complete any macOS approval in **System Settings → General → Login Items & Extensions**.
3. Wait for **Helper connected**, then turn on **Keep awake**.

Setup uses a signed system helper. No Terminal step or global sudo/PAM changes are required.

## Use

The main switch starts an indefinite session. Choose **15m**, **30m**, **1h** or **2h** for a timer. **More…** contains custom time and process options. **Off** cancels the session and restores normal sleep. In Follow mode, manual Off pauses automatic enabling until the power source changes or you manually turn it on again.

The default mode, **Manual + safety net**, restores normal sleep when unplugged. **Manual** permits battery operation but still applies the battery cutoff and Low Power Mode protection. Keep display awake is off by default.

Updates appear under **Settings → About**, with a manual check also available in configured builds' dropdowns. Sparkle asks permission for automatic checks and preserves that choice. Installation requires ending the active session first; Vaken does not restart unattended. Local builds without a feed and public signing key show **Updates are not configured** and make no updater requests. See the [user guide](docs/user-guide.md).

## Safety and privacy

Vaken changes the system-wide `SleepDisabled` flag. It does not disable thermal protections, unlock the screen or simulate user activity. Do not leave a running Mac in a bag or another poorly ventilated space. Hardware, macOS and helper failures can still interrupt remote access; recovery is not guaranteed in every failure mode.

The helper owns session deadlines, battery policy and a heartbeat lease. Quitting normally waits for verified sleep restoration. If manual recovery is needed:

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

Vaken adds no analytics. Configured update checks contact the feed host; see [security and privacy](docs/security.md).

## Build

Use a macOS Swift toolchain supporting Swift tools 5.9 or later. SwiftPM resolves the pinned Sparkle binary dependency. Helper-enabled packaging requires the configured Developer ID identity; ad-hoc signing is not supported for the trusted helper connection.

```sh
swift test
sh scripts/make-app.sh
```

The bundle is written to `build/Vaken.app`. Local building does not install the helper, publish a release or change the installed app. Approved stable `v*` tags use GitHub Actions to sign, notarize and prepare a draft release; publishing remains manual. The initial release workflow targets Apple Silicon. See [development](docs/development.md) and [release preparation](docs/releases.md) for configuration and signing requirements.

## Documentation

- [Documentation index](docs/README.md)
- [User guide and troubleshooting](docs/user-guide.md)
- [System design](docs/design/vaken.md)
- [Development](docs/development.md)
- [Security and privacy](docs/security.md)
- [Releases and Sparkle](docs/releases.md)

## License and author

[MIT](LICENSE). Copyright © 2026 Henrik Øgård.

[GitHub](https://github.com/henrikogaard) · [Buy me a coffee](https://buymeacoffee.com/henrikogaard)

Sparkle and its bundled components retain their own licenses. See [third-party notices](THIRD_PARTY_NOTICES.md).
