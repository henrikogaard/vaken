#!/bin/sh
# Prepare one local, signed update. Never publishes or increments a version.
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 3 ]; then
    echo 'Usage: sh scripts/prepare-update.sh Vaken.app https://host/download-prefix/ new-output-directory' >&2
    exit 1
fi
APP=$1
PREFIX=$2
OUTPUT=$3
: "${VAKEN_SPARKLE_KEY_FILE:?Provide a private temporary key file from 1Password. Do not pass the key value.}"
test -r "$VAKEN_SPARKLE_KEY_FILE"
test ! -e "$OUTPUT" || { echo 'Output directory must not already exist.' >&2; exit 1; }
python3 - "$APP" "$PREFIX" "$VAKEN_SPARKLE_KEY_FILE" <<'PY'
import os, pathlib, plistlib, stat, sys, urllib.parse
app, prefix, key = sys.argv[1:]
url = urllib.parse.urlsplit(prefix)
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment or url.query or not prefix.endswith('/'):
    sys.exit('Download prefix must be an HTTPS directory URL without credentials, query or fragment.')
permissions = os.lstat(key)
if not stat.S_ISREG(permissions.st_mode) or permissions.st_uid != os.geteuid() or stat.S_IMODE(permissions.st_mode) & 0o077:
    sys.exit('Key file must be a private regular file owned by the invoking user, mode 0600 or stricter.')
with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as f:
    info = plistlib.load(f)
if not info.get('SUFeedURL') or not info.get('SUPublicEDKey'):
    sys.exit('Update delivery is not configured in this bundle.')
PY
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/vaken" --validate-updates "$APP/Contents/Info.plist"
# Public distribution requires a notarized, stapled app before archiving.
scripts/retry.sh xcrun stapler validate "$APP"
TOOLS=$(sh scripts/sparkle-tools.sh)
mkdir -p "$OUTPUT"
ARCHIVE="$OUTPUT/Vaken.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
"$TOOLS/generate_appcast" --ed-key-file "$VAKEN_SPARKLE_KEY_FILE" \
    --maximum-deltas 0 --download-url-prefix "$PREFIX" -o "$OUTPUT/appcast.xml" "$OUTPUT"
swift scripts/verify-appcast.swift "$OUTPUT/appcast.xml" "$ARCHIVE" "$APP"
echo "Local update prepared in $OUTPUT. Nothing was uploaded."
