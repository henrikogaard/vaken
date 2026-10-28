#!/bin/sh
# Builds and assembles the Developer ID signed Vaken.app bundle. Does not publish.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
VERSION=$(.build/release/vaken --version)
BUILD_NUMBER=$(.build/release/vaken --build-number)
export BUILD_NUMBER
printf '%s\n' "$VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'

APP=${VAKEN_APP_PATH:-build/Vaken.app}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Frameworks"
cp .build/release/vaken "$APP/Contents/MacOS/vaken"
cp .build/release/vaken-helper "$APP/Contents/MacOS/vaken-helper"
cp Resources/no.ogard.vaken.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp scripts/install-grant.sh "$APP/Contents/Resources/install-grant.sh"
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
/usr/bin/ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp -f .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp -f LICENSE "$APP/Contents/Resources/Vaken-LICENSE.txt"
.build/release/vaken --render-assets build/artwork
/usr/bin/iconutil -c icns build/artwork/Vaken.iconset -o "$APP/Contents/Resources/Vaken.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vaken</string>
    <key>CFBundleDisplayName</key><string>Vaken</string>
    <key>CFBundleIdentifier</key><string>no.ogard.vaken</string>
    <key>CFBundleExecutable</key><string>vaken</string>
    <key>CFBundleIconFile</key><string>Vaken</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
feed, key = os.environ.get('VAKEN_FEED_URL'), os.environ.get('VAKEN_PUBLIC_ED_KEY')
if os.environ.get('VAKEN_REQUIRE_UPDATES') == '1' and (not feed or not key):
    sys.exit('Release packaging requires VAKEN_FEED_URL and VAKEN_PUBLIC_ED_KEY.')
if feed is not None or key is not None:
    info['SUFeedURL'] = feed or ''
    info['SUPublicEDKey'] = key or ''
info['CFBundleVersion'] = os.environ.get('VAKEN_BUILD_NUMBER', os.environ['BUILD_NUMBER'])
info['SUAllowsAutomaticUpdates'] = False
info['SUEnableSystemProfiling'] = False
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
.build/release/vaken --validate-updates "$APP/Contents/Info.plist"

# A stable Developer ID is required by the mutually authenticated XPC channel.
# No ad-hoc fallback: it would produce a bundle that cannot use its own helper.
SIGNING_IDENTITY='Developer ID Application: Henrik Ogard (45AD7E7G5G)'
export SIGNING_IDENTITY
python3 - "$APP/Contents/Frameworks/Sparkle.framework" <<'PY'
import os, pathlib, subprocess, sys
framework = pathlib.Path(sys.argv[1])
version = framework / 'Versions' / 'B'
# Sign the executable and nested bundles before their enclosing framework.
targets = [version / 'Autoupdate', *sorted((version / 'XPCServices').glob('*.xpc')), version / 'Updater.app', framework]
for target in targets:
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp',
                    '--preserve-metadata=identifier,entitlements', '--sign', os.environ['SIGNING_IDENTITY'], str(target)], check=True)
PY
codesign --force --options runtime --timestamp --identifier no.ogard.vaken.helper --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/vaken-helper"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Bundle ready: $APP"
