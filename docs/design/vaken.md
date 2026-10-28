# Vaken system design

Status: Building. Application implementation is verified locally; public update delivery and release integration checks remain pending.

Size: Full. Native macOS application, privileged service and signed update integration.

## 1. Purpose and scope

Vaken keeps a Mac available for remote access and long-running work by controlling system sleep independently of display sleep and screen locking. The application presents observed state, collects user intent and delegates privileged writes to a narrowly scoped helper.

The system targets macOS 13 or later. It does not unlock the screen, simulate activity, change thermal protections or implement a general automation engine. An optional display assertion is session-scoped. Network availability and protection from every OS or hardware failure are outside its guarantees.

The current distribution is version 0.3.1. The code is MIT licensed. Public release hosting, signing-key provisioning and notarized old-to-new update validation are separate deployment gates, not consequences of a successful local build.

## 2. Requirements

The requirements below describe the current product contract. Implementation references and tests are the source of verification; historical conversation transcripts and machine diagnostics are not part of this design.

| IDs | Capability | Observable acceptance criteria |
|---|---|---|
| FR-1, FR-13 | Truthful state | Read back every privileged write; render the observed sleep flag or an explicit error, never an optimistic success |
| FR-2, FR-3, FR-16, FR-24, FR-31 | Consent and setup | Register the helper through the app; use native authentication for new sessions by default; authenticate once to opt out; restores remain prompt-free |
| FR-4, FR-5, FR-6, FR-17 | Modes and direct control | Support Manual, Follow power source and Manual + safety net; Off cancels the session and pauses Follow until a verified power transition or explicit On |
| FR-7, FR-25, FR-26, FR-29 | Timed sessions | Provide dropdown presets, custom duration/clock time, countdown and +15 minutes; expiry restores normal sleep without immediate Follow re-enabling |
| FR-8, FR-9 | Battery protection | On battery, restore at the configured cutoff or in Low Power Mode; apply the cutoff in every mode |
| FR-10, FR-15 | Lifecycle | Reconcile interrupted owned state and restore on normal quit; failed restore must not authorize termination |
| FR-11, FR-12, FR-14 | Preferences | Persist valid settings; expose actual login-item and notification status rather than assuming registration succeeded |
| FR-18, FR-19, FR-22, FR-23 | Native presentation | Separate dropdown controls from Settings; distinguish On, Off and attention states in both appearances; use outline sun and crescent moon |
| FR-20, FR-21 | App information | Resolve version from bundle metadata and provide author/project/support information |
| FR-27 | Shortcut | Route a configurable global shortcut through the same authentication and restore paths; report registration conflicts |
| FR-28 | Process lifetime | End a process-linked session on exit or start-identity mismatch, including PID reuse |
| FR-30 | Display assertion | Hold an opt-in display assertion only during a session and release it on termination |
| FR-32 | Repository documentation | Maintain user, development, security and release guides linked from README; describe current architecture without personal working history |
| FR-33 | Update discovery | Expose manual checks and Sparkle-owned automatic-check preferences; missing local configuration starts no updater network activity |
| FR-34 | Safe update installation | Checking must not restore sleep; an active/pending session blocks update offers; installation blocks new sessions and requires verified normal sleep before termination |
| FR-35 | Tag-driven release preparation | A canonical stable `vMAJOR.MINOR.PATCH` tag matching committed app metadata runs tests, Developer ID signing, notarization and Sparkle asset preparation; invalid/reused tags or non-increasing published versions/builds fail closed |
| FR-36 | Draft release handoff | Upload only verified distribution assets to a draft GitHub Release; publication remains a manual release-owner action |
| FR-37 | Drag-to-install disk image | Distribute a signed/notarized read-only `Vaken.dmg` containing the unchanged signed app and an `Applications` symbolic link to `/Applications`; retain the ZIP for Sparkle |
| FR-38 | Illustrated getting-started guide | README embeds current native app screenshots and explains DMG installation, helper approval, modes, timers and authentication; screenshots contain demo state rather than private desktop content |

| IDs | Constraint or non-functional requirement | Mechanism |
|---|---|---|
| NFR-1, NFR-2, NFR-5, NFR-9 | Bounded, noninteractive policy handling | Five-second helper tick, bounded child processes, independent helper deadlines and prompt-free restoration; actual device timing requires integration verification |
| NFR-3, NFR-10 | Restricted privilege boundary | Mutually verified signed peers, active console user and fixed XPC operations |
| NFR-4 | Small idle footprint | Accessory application, timer-driven reads, no continuously rendered main window; footprint is a measurement target, not inferred from source structure |
| NFR-6 | Single state authority | Kernel sleep flag is authoritative; user intent and helper ownership are separate state |
| NFR-7 | Preserve unrelated system behavior | No persistent display, lock or thermal configuration changes |
| NFR-8 | Recover owned sessions | Heartbeat lease, disconnect restore and persistent recovery marker; no universal fail-safe claim |
| NFR-11 | Authenticate update archives | HTTPS, embedded Ed25519 public key, Developer ID signing and release artifact verification |
| CON-1, CON-3 | System-wide sleep control | Fixed `pmset -a disablesleep` operations; power-source scoping is application policy |
| CON-2 | Native consent | LocalAuthentication and Authorization Services; no custom password collection |
| CON-4 | Signed, unsandboxed distribution | Stable Developer ID app/helper identities; no ad-hoc fallback for privileged functionality |
| CON-5 | Sparkle updater | Official Sparkle 2.10.1 binary dependency pinned through SwiftPM |

## 3. Architecture

```text
User
  | controls and native authentication
  v
Vaken UI / AppModel ---- AppUpdater ---- HTTPS feed and archive host
  |                         |                    untrusted network
  | restricted XPC          v
  |                   Sparkle verification and installation
  v
Signed root helper ---- macOS power management
  |                     SleepDisabled, power state, assertions
  +---- root-owned policy and recovery state
```

The app/helper connection crosses a privilege boundary. The update connection crosses an untrusted-network boundary. A feed entry is data, not authority to execute arbitrary helper operations.

| Module | Responsibility |
|---|---|
| `Vaken` | AppKit lifecycle, SwiftUI views, session intent, native authentication, XPC client, global shortcut, artwork and updater |
| `VakenCore` | Session configuration, power policy, process identity, authentication-policy persistence and update configuration validation |
| `VakenService` | Shared XPC interface, response schema and signing requirements |
| `VakenHelper` | Privileged sleep writes, observed state, lease/deadline/power/process checks and display assertion |
| Release scripts | Self-contained signed bundles, pinned updater tooling, local archive/appcast generation and verification |

Legacy command-based grant utilities remain for compatibility and regression coverage. They are not the current application's privileged execution path.

## 4. State ownership and persistence

| Datum | Authoritative owner | Readers |
|---|---|---|
| `SleepDisabled` | macOS kernel | Helper and unprivileged state reader |
| Power source, charge, Low Power Mode | macOS | Policy and presentation |
| Mode, battery cutoff, display preference, shortcut | User settings store | AppModel and session configuration builder |
| Active session, deadline, process identity, lease | Root helper | AppModel via replies |
| Manual pause, pending user action | AppModel | UI and update integration |
| Authentication requirement and revision per UID | Root helper | Trusted app through status replies |
| Update preferences, schedule and download state | Sparkle | AppUpdater and Settings |
| Feed URL, public update key, version/build | Bundle/release configuration | Sparkle and verification tools |

App settings live at `~/Library/Application Support/no.ogard.vaken/settings.json`. Root-owned files are `/var/db/no.ogard.vaken/authentication.json` and `/var/db/no.ogard.vaken/owned`. Private update-signing keys are never app data and must not be embedded or committed.

The authentication-policy file is keyed by UID. Missing, corrupt, wrong-owner or group/world-writable state defaults to authentication required. Private temporary-file replacement is atomic. Policy revisions reject stale changes and stale new-session requests. Failed persistence does not optimistically change the UI preference.

## 5. Privileged service contract

`SleepControlProtocol` exposes only status, begin, update, heartbeat, restore and authentication-policy changes. Configuration and replies use bounded Codable payloads. No endpoint accepts shell text, arbitrary executable paths or arbitrary power-setting arguments.

Both peers require expected Developer ID identifiers and team, with no debug or disabled-library-validation entitlements. The helper accepts a non-root active console user. Each connection has a unique owner, and update/heartbeat operations require its session identifier.

Protocol version 2 adds authentication policy and revision metadata. Legacy, incomplete and unsupported-version replies conservatively require authentication. The trusted signed app enforces successful native authentication before policy-required starts and before opting out. The helper does not accept an untrusted `authenticated` flag or independently prove each biometric result.

Example lifecycle:

1. App reads status and the helper-owned authentication policy.
2. App authenticates if required, retaining an intent generation.
3. If still current, it sends a validated session and expected policy revision.
4. Helper validates peer, owner, configuration, policy revision and current power constraints.
5. Helper writes its recovery marker, sets the sleep flag and verifies the result.
6. A successful reply supplies the session ID and authoritative configuration.

A late authentication result cannot override an intervening Off, quit or power-policy cancellation. A failed heartbeat is not permission to start a replacement session.

## 6. Session policy and lifecycle

The main switch creates an indefinite session. Presets and More controls create optional deadline/process constraints. Updating an existing authorized session changes its end conditions without another authentication prompt or an off/on cycle.

Manual mode permits battery sessions. Follow and Manual + safety net require AC. All modes restore at the battery cutoff or in Low Power Mode on battery. The default cutoff is 15%, configurable between 5% and 50%.

Process tracking records PID and start time. Exit or replacement ends the session. An application remaining open is not a signal that a background task is active.

The helper uses a 30-second monotonic lease and a five-second policy tick. End conditions include deadline, process exit/replacement, power policy, battery/LPM, console-user change, disconnect and lease expiry. Bounded `pmset` subprocesses prevent an indefinitely hung utility from permanently occupying the state queue.

The recovery marker records ownership, not a general instruction to overwrite unrelated external state. After helper restart, an owned interrupted flag is reconciled. Failed restoration remains visible and is retried. Display assertions are held only for active sessions and released on restoration.

Normal termination waits for verified sleep restoration. AppKit termination requests use `terminateLater` followed by an explicit success/failure reply. This preserves Sparkle's shutdown transaction rather than cancelling it and starting an unrelated termination request. A failed restore leaves the application running.

## 7. Update subsystem

`AppUpdater` owns one `SPUStandardUpdaterController`. Sparkle owns networking, update selection, scheduling, user-default preferences, downloads and archive verification. The application observes check availability and automatic-check preference rather than duplicating those stores or timers.

About exposes manual checks and automatic-check consent. Configured dropdowns also expose manual checks. The default Sparkle consent/schedule applies: permission is normally requested on the second launch, and approved checks run approximately daily. Automatic installation and system profiling are disabled by bundle configuration.

`UpdateConfiguration` validates an HTTPS feed without embedded credentials or fragment, a base64 32-byte public key and a positive numeric build identifier. No feed/key pair means a local unconfigured build and no updater startup. Partial or invalid release configuration fails packaging. No placeholder endpoint is silently activated.

### Update state transitions

1. Checking or a network error does not alter the awake session.
2. Before accepting an update offer, the controller requires a known sleep state and no pending operation or quit. An active session may continue; installation quits through the verified restore path, which keeps the app's resume note, and the relaunched app resumes the session.
3. Accepting an offer holds an interaction lock and pauses Follow. Starting a new session is blocked until the update is finished or dismissed.
4. Resumed downloads can bypass the initial offer callback, so installation/relaunch checks the session guard again.
5. Actual termination still verifies restoration. A failed restore cancels termination.
6. Completed or aborted cycles release the interaction lock. Helper compatibility is checked after the new app starts.

The updater does not automatically register, replace or reauthorize a privileged helper. Older helpers remain conservative and Settings exposes an explicit supported update/setup flow. A failed registration may require retrying Setup; seamless helper migration is not assumed.

### Release artifacts

The app embeds Sparkle.framework with preserved framework links and runtime search path. Nested executable code is signed inside-out before the enclosing app. Packaging uses Developer ID with secure timestamps and verifies the completed bundle. The upstream license is included.

Update preparation requires a configured, signed and stapled app, a private signing-key file, an HTTPS archive prefix and a new output directory. It creates a full archive and a single-entry appcast without publishing. Verification checks archive Ed25519 signature against the embedded public key, length, HTTPS URL and build identifier. The feed itself is not independently signed in this version.

Public distribution requires notarization and an increasing approved build identifier. Existing non-Sparkle builds require manual installation of their first Sparkle-enabled successor. See [release procedures](../releases.md).

### Tag workflow implementation

The approved release flow uses a tag-only GitHub Actions workflow on the public repository. Scope is FR-35/36 and NFR-11; it does not create the repository, configure secrets/environments, push a tag, change the current version/build or publish a release during development. A stable tag such as `v0.1.0` must match `AppInfo.releaseVersion`; `AppInfo.releaseBuild` owns the existing build value 1 without changing it. Packaging reads that value through a non-GUI CLI option. Prerelease tags are not supported by the initial stable feed.

A standard-library Python validator checks canonical tags, source metadata, repository format, reuse of an existing release, and increasing marketing/build values against the latest published appcast. Unexpected API errors, missing existing appcast or malformed metadata fail closed; only a genuine 404 means no previous published stable release. Tests cover first release, matching/mismatching tags, unsafe input, API failures and non-increasing versions/builds without network credentials.

The tag workflow uses commit-pinned checkout/artifact actions. The tag commit must be on `main`. The packaging job has read-only repository permissions, runs tests before accessing signing secrets, and uses the `release` environment. That environment requires maintainer-configured reviewers and tag restrictions before activation. Hosted Apple Silicon macOS builds produce the initial arm64 archive; Intel/universal support is outside this workflow and must not be implied by release notes.

Only the signing step receives certificate, notarization and Sparkle private-key secrets. It creates a private temporary directory and disposable keychain on a GitHub-hosted runner, imports the existing Developer ID certificate, builds, submits to Apple's notarization service, requires Accepted status, staples/verifies and prepares the Sparkle archive/appcast. An exit/signal cleanup removes only that step's temporary credentials/keychain. The script refuses non-hosted execution to avoid changing a developer's keychain configuration. The `release` environment is the approval boundary; exports from 1Password and GitHub secret configuration are separate authorized setup actions.

The draft job receives only the distribution files `Vaken.dmg`, `Vaken.dmg.sha256`, `Vaken.zip`, `appcast.xml` and `SHA256SUMS` through a same-run artifact, verifies checksums and has `contents: write` solely to create a new draft for the existing tag. It never publishes, overwrites assets, creates/moves a tag or updates a published feed. Documentation lists secret names and activation steps without values. Verification consists of validator tests, shell syntax, mocked signing/notarization/cleanup orchestration and actionlint. The original v0.1.0 hosted ZIP workflow passed; the added DMG stage requires its own verification before claiming a hosted DMG pass.

### Disk image and illustrated guide

Scope: FR-37/38 is approved for the first release. `scripts/make-dmg.sh` creates a new compressed read-only HFS+ image from a staging copy of the already signed/stapled app. The image root contains only `Vaken.app` and an `Applications -> /Applications` symbolic link. It does not install or launch the app. Refuse an existing output path rather than overwriting it, preserve bundle/framework symlinks with ditto, and sign the image using the existing Developer ID. No new packaging dependency or custom Finder background is needed.

The CI signing step retains its private notarization file until both app and image submissions are Accepted. Staple and validate the image after signing/notarization. Future draft jobs attach the DMG and a `Vaken.dmg.sha256` sidecar in addition to the existing ZIP/appcast/checksum assets. Keeping the disk-image sidecar separate permits the initial draft to gain the DMG without replacing its existing ZIP, appcast, checksum file, tag or version. Publication of the first release is authorized once the requested artifacts and documentation are ready; repository merge approval remains a separate delivery gate.

Verification: mount the image read-only with `-nobrowse` at an explicit temporary mountpoint; inspect root contents, symlink target, app version/signature and image format; detach only that mounted image. Tests cover refusal to overwrite and mocked image failure/notarization cleanup. README screenshots are fresh native demo-view exports from the exact v0.1.0 app, covering the dropdown, Settings and custom session options. Inspect images before committing, use relative image links and explain that authentication/helper setup is user-approved. The release remains unpublished until installation/update verification and documentation review gates are reconciled.

## 8. Security and failure handling

| Boundary or failure | Response and limit |
|---|---|
| Wrong signed client or console user | Reject connection/request; no privileged general-command API |
| Cancelled or stale authentication | No new enable; retain observed state and manual pause |
| Invalid/missing policy | Require authentication; never trust editable app settings as opt-out authority |
| Failed write/readback | Show error; do not infer success from process exit alone |
| App disconnect or expired lease | Attempt owned restore; retry failures; hardware/OS/service removal can defeat recovery |
| Invalid archive signature | Reject update; do not disable verification to recover |
| Feed unavailable or compromised | Preserve installed app/session; HTTPS and archive signatures do not prevent update withholding |
| Private signing key unavailable | Release preparation blocked; local unconfigured builds remain usable |
| Helper registration failure | Surface error and Setup retry; preserve root-owned policy |

Update-signing credentials belong in an external secret store. Only the public key is build metadata. Vaken adds no analytics; configured update hosts can observe normal HTTP metadata. Thermal behavior, network failures and every possible sleep condition are not under application control. See [security and privacy](../security.md).

## 9. Design decisions

| Decision | Rationale and consequence |
|---|---|
| Native accessory app with SwiftPM modules | AppKit lifecycle and SwiftUI controls without an Xcode project; signing and framework embedding need explicit packaging |
| Kernel flag as state authority | Reflect external changes and failed writes instead of only user intent |
| Signed fixed-operation helper | Native authentication without global PAM/sudo changes; requires stable signing and service approval |
| Helper-owned session and authentication policy | Deadlines and battery behavior outlive UI responsiveness; opt-out cannot be enabled by editing user settings |
| Manual pause separate from selected mode | Off and timer completion remain effective without silently changing the saved mode |
| Outline sun and crescent moon | Distinguishable monochrome On/Off presentation at menu-bar size |
| Sparkle 2.10.1 with controlled installation | Reuse standard update verification and scheduling while protecting active remote sessions |
| Inactive updater when unconfigured | Avoid shipping a fake feed or pretending a signing key exists |
| MIT application license | Permit reuse while retaining copyright and separate dependency notices |
| Tag-triggered draft release, accepted | Build and verify tagged stable versions with the existing Developer ID; isolate credentials from the write-token job and retain manual publication |

## 10. Verification and release gates

| Surface | Local evidence | Limit |
|---|---|---|
| Session/authentication/policy | Controller and core tests cover cancellation, late results, stale policy revisions, helper compatibility, process lifetime and quit failure | Injected outcomes are not live biometric or service-approval proof |
| Update configuration and interaction | UpdateTests cover HTTPS/key/build validation, active/pending session refusal, new-session lock and failed-termination cancellation | Actual signed old-to-new installation remains a release gate |
| Appcast verification | Public RFC 8032 vector and tampering/version/URL/length rejection tests | Cryptographic fixtures are not a notarized application update |
| Bundle | Signed release bundle verifies; framework resolves from its embedded runtime path and runs native previews in isolated macOS | Public notarization and distribution are separate |
| UI | Configured and unconfigured update controls rendered in native light/dark fixtures | Does not prove a production feed exists |
| Documentation | README and linked guides describe current behavior; design excludes personal diagnostics and working transcripts | Earlier local Git history still needs review before public import |
| DMG and README extension | Full 25-test release-tool suite passed before the final source-app path guard; the final four image tests pass, with actionlint and shell syntax checks. A real signed UDZO image mounts read-only with the unchanged signed/stapled v0.1.0 app from public commit 473dce2 and correct Applications link; four native release-app screenshots inspected | Disk-image notarization and upload currently wait for renewed 1Password CLI approval; README/pipeline changes require repository review before publication |
| Tag metadata | Ten validator tests cover canonical tags, metadata, first release, duplicate releases, increasing published versions/builds and HTTP failure handling | API responses are mocked; no remote repository is configured locally |
| Release orchestration | Four mocked-tool tests cover success, notarization rejection, import failure, credential cleanup and refusal of local execution; actionlint and shell syntax pass | Does not prove a real certificate import, notarization or hosted job |

Local verification for this change: the full Swift suite passed 73 tests before the final install-time guard and callback-bridge test were added; the final affected UpdateTests suite passed all six tests. Seven release-verifier tests pass, including the current generated appcast version-element format. Shell syntax and relative documentation links pass. The signed bundle rendered 26 native fixtures in an isolated macOS environment; configured light and unconfigured dark About views were inspected. Version/build remain 0.1.0/1. No production signing key was generated, no feed or release was published, and no signed old-to-new installation was performed.

Tag-workflow verification: the release-tool suite passed all 20 tests before the final HTTP-adapter case was added; the final ten metadata tests pass, alongside the earlier seven cryptographic/appcast and four mocked-orchestration passes. The updated bundle builds and passes strict signature verification with version/build 0.1.0/1; the non-GUI build-number output and bundled MIT license were checked. This is local implementation evidence, not a hosted release run. No tags, repository settings, credential exports, notarization submissions or releases were created during implementation.

The following remain deployment/integration gates:

- Provision the production repository/feed and protected update-signing key with explicit authorization.
- Approve release version/build changes and notarization/publication actions separately.
- Exercise signed old-to-new installation, cancellation, invalid archive, restart and helper compatibility in an isolated macOS environment.
- Complete relevant physical power, locked-screen, display assertion and crash-recovery checks on supported hardware.
- Review historical commits before importing them into a public repository. Rewriting this file does not scrub Git history.

## 11. References

- [Sparkle setup](https://sparkle-project.org/documentation/)
- [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Apple LocalAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Development guide](../development.md)
