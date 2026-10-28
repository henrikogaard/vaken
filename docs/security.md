# Security and privacy

## Privilege boundary

Vaken changes `pmset -a disablesleep` through a dedicated root helper. Its XPC API exposes fixed session operations only, not shell text, executable paths or arbitrary power-management arguments.

The app and helper enforce Developer ID signatures for expected identifiers and team. Debug and disabled-library-validation entitlements are rejected. The helper accepts only a non-root active console user's verified app. A connection-owned session identifier prevents another connection from updating or renewing that session.

The signed app is the authentication enforcement point. It uses LocalAuthentication or Authorization Services before a new session when required. The helper trusts this restricted signed client, not an arbitrary `authenticated=true` request field. This is not an independent cryptographic proof of each biometric result at the helper.

The authentication requirement is helper-owned per user, defaults to On and is revision checked. Missing, corrupt or untrusted policy state requires authentication. Opting out requires one native confirmation. Keep the signing identity and release pipeline protected; a compromised trusted app undermines this boundary.

## Session recovery and limits

The helper owns deadlines, process identity, battery policy and display assertions. A 30-second monotonic lease is renewed by the UI, and a five-second helper tick checks end conditions. Disconnection and failed heartbeats lead to restoration. An ownership marker enables reconciliation after helper restart. Privileged utility invocations are bounded by termination and kill timeouts.

Every write is read back. Failed restoration stays visible and is retried. These mechanisms do not guarantee recovery after every OS, hardware, service-removal or filesystem failure. Thermal protections remain outside Vaken's control. A powered, awake computer must remain adequately ventilated.

## Update trust

Sparkle verifies update archives using an Ed25519 public key embedded in the app. Feed and download URLs use HTTPS. Release preparation requires a signed, notarized and stapled app, checks the generated archive signature against the embedded public key, and verifies appcast version and length metadata.

The feed is not independently signed in this initial integration. HTTPS protects transport; Ed25519 protects archive authenticity. A compromised feed host can still withhold releases or alter unsigned feed descriptions. Do not put secrets in release notes and do not treat release-note links as privileged instructions.

The private update key belongs in 1Password, never the repository, app bundle, command line, chat or logs. Release tooling takes a private temporary file owned by the invoking user. Remove that temporary file after use. Code-signing and notarization credentials remain outside the repository too.

Automatic installation is disabled. Active or pending sessions block update offers and installation. Resumed updates are checked again before installation. Termination waits for verified normal sleep and is cancelled on failed restoration.

## Data and network access

| Data | Location or destination | Owner |
|---|---|---|
| App preferences | `~/Library/Application Support/no.ogard.vaken/settings.json` | User |
| Authentication requirement | `/var/db/no.ogard.vaken/authentication.json` | Root helper, keyed by UID |
| Recovery marker | `/var/db/no.ogard.vaken/owned` | Root helper |
| Update preferences | App-domain macOS user defaults managed by Sparkle | User |
| Update requests | Configured appcast and archive hosts | Sparkle |

Vaken adds no analytics or custom system-profile parameters. Sparkle system profiling is disabled in bundled configuration. A configured feed host can observe normal HTTP metadata such as IP address and request timing. Local builds without update configuration do not start Sparkle's network activity. App/PID session selection remains local.

## Reporting a vulnerability

Do not include passwords, private keys or sensitive logs in a public issue. Use a private security advisory on the repository once private reporting has been enabled. Until that channel is available, contact the maintainer through the public profile without sending sensitive details first.
