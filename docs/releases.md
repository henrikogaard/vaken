# Releases and Sparkle

## Current state

Sparkle 2.10.1 is integrated, but public update delivery is not activated. The public repository is [henrikogaard/vaken](https://github.com/henrikogaard/vaken). Its release environment requires maintainer approval and permits `v*` tags. Signing credentials, the update-signing key and a published appcast are still required before distributing an update-enabled release. An unconfigured local bundle does not start update checks.

The tag-triggered [release workflow](../.github/workflows/release.yml) tests, signs, submits notarization and prepares a **draft** GitHub Release. It never publishes that draft. Local packaging does not submit notarization or upload assets. No script changes a release version or generates production signing credentials.

## Tag-triggered workflow

The initial workflow runs only for `v*` tag pushes to the intended public repository. It accepts stable tags such as `v0.1.0`, not prerelease tags. The tag must match the committed `AppInfo.releaseVersion`, and its commit must be reachable from `main`. Commit the approved `releaseBuild` increase in `AppInfo.swift` before tagging subsequent releases; the workflow does not derive versions from run numbers or silently edit source.

Before signing, validation rejects an existing release for the same tag, a non-increasing version/build compared with the latest published stable appcast, or an unexpected GitHub/API/feed failure. Only a genuine missing previous release permits first-release preparation without a baseline appcast. An existing draft is not overwritten on rerun. Tags must not be moved to recover a failed run.

The workflow has two jobs:

1. **Package**, on a GitHub-hosted Apple Silicon `macos-15` runner with Xcode 26.2. It requires the `release` environment, tests without signing credentials, imports the existing Developer ID certificate into a disposable keychain, builds and notarizes the app, then creates and separately notarizes the DMG. Both submissions must be Accepted before assets are uploaded. It staples/assesses and verifies the signed Sparkle archive. This initial distribution supports **arm64 only**. The app, sleep helper, Sparkle components and disk image use the configured Developer ID signing identity.
2. **Draft**, on a separate runner without signing secrets. It downloads only this run's `Vaken.dmg`, `Vaken.dmg.sha256`, `Vaken.zip`, `appcast.xml` and `SHA256SUMS`, checks both checksum files and creates a draft for the existing tag using `--verify-tag`. Repository-write permission is limited to this job. Publication and the stable feed stay unchanged until the release owner publishes the draft manually.

All referenced third-party actions are pinned to reviewed commit IDs. Checkout does not retain a Git credential. Signing secrets are scoped to the signing step, and only distribution files are uploaded as seven-day workflow artifacts. Private key files, certificate archives, temporary keychain and notarization submission files are cleaned up on exit or handled signals; GitHub-hosted runner disposal remains the backstop for abrupt termination. `scripts/ci-release.sh` refuses ordinary local and self-hosted execution to avoid changing a developer's keychain configuration.

### Required environment setup

Before the first tag, a repository administrator must create the **release** environment with required reviewers and deployment restrictions allowing only approved `v*` tags. Protect `main`, the release workflow and release-tag creation appropriately. The workflow file does not provision these account/security settings. An environment name alone does not enforce approval; configure and verify protections before adding credentials.

Populate these environment secrets directly from their 1Password source records, never through chat, committed files or logged shell values:

| Secret | Format and purpose |
|---|---|
| `APPLE_CERTIFICATE_P12` | Single-line base64 of a password-protected export of the existing Developer ID Application certificate **and private key** |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that P12 export |
| `APPLE_NOTARY_KEY_P8` | Single-line base64 of an authorized App Store Connect API private key usable with notarytool |
| `APPLE_NOTARY_KEY_ID` | Associated Apple API key identifier |
| `APPLE_NOTARY_ISSUER_ID` | Associated issuer identifier |
| `SPARKLE_PRIVATE_KEY` | Sparkle private key text as accepted by `generate_appcast --ed-key-file`; not an additional base64 wrapping |

Set the environment variable **SPARKLE_PUBLIC_KEY** to the matching base64 Ed25519 public key. It is public metadata. Feed and immutable download URLs are derived from the repository and validated tag. The environment must contain the Developer ID identity expected by `scripts/make-app.sh`; arbitrary imported certificates do not select a different signer.

Exporting a signing certificate, generating an update key, configuring GitHub secrets/environment rules, pushing a tag and publishing a draft each require their own authorization. Implementing the workflow does not perform any of those actions. A real credentialed workflow run and signed old-to-new update test remain activation gates.

## Release configuration

| Input | Meaning |
|---|---|
| `VAKEN_APP_PATH` | Bundle staging path, default `build/Vaken.app` |
| `VAKEN_FEED_URL` | Stable HTTPS appcast URL |
| `VAKEN_PUBLIC_ED_KEY` | Base64 Sparkle Ed25519 public key, exactly 32 decoded bytes |
| `VAKEN_BUILD_NUMBER` | Positive numeric `CFBundleVersion`, defaults to committed `AppInfo.releaseBuild`; workflow requires that committed value |
| `VAKEN_REQUIRE_UPDATES=1` | Reject packaging unless the feed and key are configured |
| `VAKEN_SPARKLE_KEY_FILE` | Private temporary signing-key file used only by update preparation |

The intended feed is `https://github.com/henrikogaard/vaken/releases/latest/download/appcast.xml`. That endpoint is not assumed to exist. Immutable archive downloads should use the corresponding tagged release path, never a mutable latest-version archive URL.

`CFBundleShortVersionString` and the default `CFBundleVersion` are controlled by `AppInfo.swift`; they currently report 0.1.0 and 1. Sparkle compares the numeric build identifier, not just the displayed marketing version. Never reuse a published build identifier for different binaries. This integration does not increment either field on its own.

## One-time activation

1. Verify the public repository and protected release environment above. Import only reviewed source and documentation; do not publish private development history. Retain development history separately when creating a clean public snapshot.
2. Generate a dedicated Sparkle Ed25519 key only when explicitly authorized. The official `generate_keys` tool normally stores its key in the login Keychain. Transfer/retain the private key in the approved 1Password item without displaying it in chat or logs. Embed only the public key in builds. Losing this key complicates future updates and rotation.
3. Set signing/notarization secrets and the public update key in the protected release environment. Verify that the derived feed URL is under maintainer control before distributing a build that trusts it. Local packaging still accepts an explicit feed URL/public-key pair.
4. Prepare a signed old-to-new installation test in an isolated macOS environment. Approve the test build identifiers and key use separately. Include an active-session deferral, failed restore, cancelled install, invalid signature, relaunch and helper compatibility check.

The first Sparkle-enabled build must be installed manually because existing builds without Sparkle cannot discover it automatically.

## Build and notarization

After the release owner approves the version/build and configuration:

```sh
# Set VAKEN_FEED_URL, VAKEN_PUBLIC_ED_KEY and the approved VAKEN_BUILD_NUMBER first.
VAKEN_REQUIRE_UPDATES=1 sh scripts/make-app.sh
codesign --verify --deep --strict build/Vaken.app
```

The script embeds Sparkle.framework, preserves symlinks, signs nested code inside-out with secure timestamps, signs the sleep helper and app, and verifies the bundle. It includes Sparkle's upstream license. It does not notarize.

For a public release, submit the signed app to Apple's notarization service using an approved credential profile, inspect the result, then staple and validate the ticket. Keep credentials outside Git. Packaging requires notarization before preparing the final update archive:

```sh
xcrun stapler validate build/Vaken.app
spctl --assess --type execute --verbose build/Vaken.app
```

Do not weaken signature checks or ship an ad-hoc helper build to bypass notarization failures. A code-signature pass is not a notarization pass.

## Prepare local update assets

The primary installer is `Vaken.dmg`. Its read-only image contains `Vaken.app` and an `Applications` symbolic link targeting `/Applications`. The app is copied with bundle/framework links preserved, not rebuilt inside the image. Users drag it to Applications and eject the image before first launch. `Vaken.zip` remains the Sparkle update archive, so adding the DMG does not change updater URLs or existing signatures.

Create the image only from a signed, stapled app:

```sh
bash scripts/make-dmg.sh build/Vaken.app build/Vaken.dmg
```

This refuses to overwrite an existing image, stages only the app and shortcut, creates a compressed read-only HFS+ image and signs it. Submit the DMG to notarization separately, require Accepted status, then staple/validate and verify it before distribution. The release workflow performs these steps with the protected environment credentials. Local notarization requires explicit release-owner authorization.

For an installation check, mount with `hdiutil attach -readonly -nobrowse` at an explicit temporary mountpoint. Verify `Applications -> /Applications`, the app's signature/version and the image signature/ticket; detach only that mounted image. Do not install or launch a helper as part of the image-layout check.

`scripts/sparkle-tools.sh` downloads the pinned official tooling archive, verifies its SHA-256 checksum and extracts it under ignored build output. It neither generates nor reads signing keys.

`scripts/prepare-update.sh` requires a configured, signed and stapled bundle; a private signing-key file owned by the invoking user with mode 0600 or stricter; an immutable HTTPS download prefix; and a new output directory. It creates one full archive, no deltas, and a one-entry appcast. This keeps update preparation separate from publication and avoids pruning an existing release directory.

```sh
# The private file must be populated directly from 1Password, not pasted into a command.
# Set VAKEN_SPARKLE_KEY_FILE to that file's path, never its value.
sh scripts/prepare-update.sh \
  build/Vaken.app \
  https://github.com/henrikogaard/vaken/releases/download/APPROVED_TAG/ \
  build/update-APPROVED_TAG
```

Replace `APPROVED_TAG` only after approving a release version. Output contains `Vaken.zip` and `appcast.xml`. The archive contains only the app bundle and preserves framework links and permissions. The script verifies the archive length, build identifier, HTTPS enclosure URL and Ed25519 signature against the public key inside the app. A mismatched private key fails verification rather than producing publishable assets. The XML feed itself is not signed in this initial integration.

After the DMG is notarized/stapled, copy it into the release-assets directory. `SHA256SUMS` covers the ZIP and appcast; `Vaken.dmg.sha256` covers the final stapled image. The separate sidecar allows an existing draft to gain an installer without replacing its original Sparkle archive, appcast or checksum file. Never use `--clobber` or move an existing tag to make this addition. A published release still needs explicit approval before changing its assets.

The caller owns the temporary key file's lifecycle and must remove it after signing, including on failure. Never store the key under the repository, release-output directory or app bundle. Tools may report public signatures; private key values must never enter stdout, shell tracing or a PR.

## Publication checklist

- [ ] Explicit approval for this release/version/build and publication.
- [ ] Tag matches the committed version, build increases, and the release commit is on `main`.
- [ ] Protected release environment, required reviewers and tag restrictions verified.
- [ ] Focused tests, full suite and native UI verification recorded.
- [ ] Developer ID signatures, nested framework integrity and notarization verified.
- [ ] App/helper identifiers and team remain compatible with installed clients.
- [ ] Settings and helper-owned authentication policy survive the update test.
- [ ] Signed old-to-new Sparkle test passes, including restart/restore failure paths.
- [ ] Appcast signature, version, size, minimum macOS and architecture metadata checked.
- [ ] DMG signature/notarization, read-only mount, app contents and Applications shortcut checked.
- [ ] Immutable archive URL and stable appcast URL verified after upload.
- [ ] Release notes list changes, supported architectures and unresolved limitations.
- [ ] Third-party notices and MIT license included appropriately.
- [ ] Public repository history reviewed for secrets and personal diagnostics.
- [ ] Private temporary signing files removed.

Once prepared, review the draft's notes and assets. Edit its notes to describe the actual changes and verification, then publish manually only after the checklist passes. For a public stable release, make sure it becomes the latest release so the configured `/releases/latest/download/appcast.xml` endpoint resolves to the intended feed. Never publish an older draft over a newer stable release.

Only publish after those gates pass. Updating a feed or GitHub release is a deployment action, not a side effect of building or committing.

## Recovery and key rotation

A failed download or signature check must leave the installed app unchanged. After a failed helper registration, the app shows setup/update status; retry supported in-app setup rather than deleting policy files. Keep a known-good signed bundle for manual recovery.

For a bad public release, stop offering it in the appcast and prepare a corrected build with a higher build identifier. Sparkle does not provide a general automatic downgrade path. Feed changes and redistribution still require release-owner approval. Follow [Sparkle's key-rotation guidance](https://sparkle-project.org/documentation/#rotating-signing-keys) if a signing credential must change; do not rotate both trust mechanisms blindly.
