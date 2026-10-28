#!/bin/bash
# GitHub-hosted signing/notarization only. Never publishes or creates a tag.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
    echo 'Release signing must run on a disposable GitHub-hosted runner.' >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'This release workflow currently requires an Apple Silicon runner.' >&2
    exit 1
fi
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?}"
: "${APPLE_CERTIFICATE_P12:?}"
: "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_NOTARY_KEY_P8:?}"
: "${APPLE_NOTARY_KEY_ID:?}"
: "${APPLE_NOTARY_ISSUER_ID:?}"
: "${SPARKLE_PRIVATE_KEY:?}"
: "${VAKEN_PUBLIC_ED_KEY:?}"
: "${VAKEN_FEED_URL:?}"
: "${VAKEN_BUILD_NUMBER:?}"
: "${VAKEN_VERSION:?}"
: "${VAKEN_DOWNLOAD_PREFIX:?}"

PRIVATE_DIR=$(mktemp -d "$RUNNER_TEMP/vaken-release.XXXXXX")
chmod 700 "$PRIVATE_DIR"
KEYCHAIN="$PRIVATE_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
export PRIVATE_DIR
cleanup() {
    status=$?
    trap - EXIT
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -f "$PRIVATE_DIR/certificate.p12" "$PRIVATE_DIR/notary.p8" "$PRIVATE_DIR/sparkle.key" \
        "$PRIVATE_DIR/notarization.zip" "$PRIVATE_DIR/notarization.json" "$PRIVATE_DIR/dmg-notarization.json"
    rmdir "$PRIVATE_DIR" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
python3 - <<'PY'
import base64, os, pathlib
root = pathlib.Path(os.environ['PRIVATE_DIR'])
for name, variable in [('certificate.p12', 'APPLE_CERTIFICATE_P12'), ('notary.p8', 'APPLE_NOTARY_KEY_P8')]:
    try:
        data = base64.b64decode(os.environ[variable], validate=True)
        if not data:
            raise ValueError()
    except ValueError:
        raise SystemExit('Invalid base64 release credential: ' + variable)
    (root / name).write_bytes(data)
(root / 'sparkle.key').write_text(os.environ['SPARKLE_PRIVATE_KEY'])
PY
# Child build tools do not need private-key values in their environment.
unset APPLE_CERTIFICATE_P12 APPLE_NOTARY_KEY_P8 SPARKLE_PRIVATE_KEY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$PRIVATE_DIR/certificate.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
unset APPLE_CERTIFICATE_PASSWORD
rm -f "$PRIVATE_DIR/certificate.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F 'Developer ID Application: Henrik Ogard (45AD7E7G5G)' >/dev/null

export VAKEN_APP_PATH=build/Vaken.app
export VAKEN_REQUIRE_UPDATES=1
bash scripts/make-app.sh
test "$("$VAKEN_APP_PATH/Contents/MacOS/vaken" --version)" = "$VAKEN_VERSION"
test "$("$VAKEN_APP_PATH/Contents/MacOS/vaken" --build-number)" = "$VAKEN_BUILD_NUMBER"
codesign --verify --deep --strict "$VAKEN_APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$VAKEN_APP_PATH" "$PRIVATE_DIR/notarization.zip"
notarize() {
    xcrun notarytool submit "$1" --key "$PRIVATE_DIR/notary.p8" \
    --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json > "$2"
    python3 - "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as result:
    if json.load(result).get('status') != 'Accepted':
        sys.exit('Notarization was not Accepted; no release artifacts will be produced.')
PY
}
# The ticket server can drop the runner's connection briefly; retry, then fail with the original status.
retry() {
    local attempt=1 status=0
    while true; do
        status=0
        "$@" || status=$?
        [[ $status -eq 0 ]] && return 0
        [[ $attempt -ge 3 ]] && return "$status"
        echo "Command failed with status $status (attempt $attempt of 3); retrying: $*" >&2
        sleep $((attempt * ${VAKEN_RETRY_DELAY:-5}))
        attempt=$((attempt + 1))
    done
}
notarize "$PRIVATE_DIR/notarization.zip" "$PRIVATE_DIR/notarization.json"
retry xcrun stapler staple "$VAKEN_APP_PATH"
retry xcrun stapler validate "$VAKEN_APP_PATH"
spctl --assess --type execute --verbose=2 "$VAKEN_APP_PATH"
bash scripts/make-dmg.sh "$VAKEN_APP_PATH" build/Vaken.dmg
notarize build/Vaken.dmg "$PRIVATE_DIR/dmg-notarization.json"
retry xcrun stapler staple build/Vaken.dmg
retry xcrun stapler validate build/Vaken.dmg
codesign --verify --strict build/Vaken.dmg
rm -f "$PRIVATE_DIR/notary.p8"
unset APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID
export VAKEN_SPARKLE_KEY_FILE="$PRIVATE_DIR/sparkle.key"
bash scripts/prepare-update.sh "$VAKEN_APP_PATH" "$VAKEN_DOWNLOAD_PREFIX" build/release-assets
mv build/Vaken.dmg build/release-assets/Vaken.dmg
(
    cd build/release-assets
    shasum -a 256 Vaken.zip appcast.xml > SHA256SUMS
    shasum -a 256 Vaken.dmg > Vaken.dmg.sha256
)
echo 'Signed, notarized release assets prepared. Publication is not performed by this script.'
