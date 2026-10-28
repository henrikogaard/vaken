#!/bin/bash
# Create and sign a drag-to-Applications image from an already stapled app.
# Notarization/stapling of the image is performed by the release caller.
set -euo pipefail
if [[ "$#" -ne 2 ]]; then
    echo 'Usage: bash scripts/make-dmg.sh Vaken.app new-output.dmg' >&2
    exit 1
fi
APP=$1
OUTPUT=$2
if [[ ! -d "$APP" || "$OUTPUT" != *.dmg || -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo 'Supply an existing app and a new .dmg output path; existing images are never overwritten.' >&2
    exit 1
fi
python3 - "$APP" "$OUTPUT" <<'PY'
import pathlib, sys
app, output = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:])
if output.is_relative_to(app):
    raise SystemExit('Disk-image output must not be inside the app bundle.')
PY
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
mkdir -p "$(dirname "$OUTPUT")"
STAGING=$(mktemp -d "$(dirname "$OUTPUT")/.vaken-dmg-XXXXXX")
cleanup() {
    # Only the staging directory created by this invocation is removed.
    python3 - "$STAGING" <<'PY'
import pathlib, shutil, sys
path = pathlib.Path(sys.argv[1])
if not path.name.startswith('.vaken-dmg-'):
    raise SystemExit('Unexpected staging path.')
shutil.rmtree(path)
PY
}
trap cleanup EXIT
ditto "$APP" "$STAGING/Vaken.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Vaken -srcfolder "$STAGING" -fs HFS+ -format UDZO "$OUTPUT"
codesign --force --timestamp --identifier no.ogard.vaken.diskimage \
    --sign 'Developer ID Application: Henrik Ogard (45AD7E7G5G)' "$OUTPUT"
codesign --verify --strict "$OUTPUT"
echo "Signed disk image ready: $OUTPUT"
