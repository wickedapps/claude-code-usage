#!/bin/sh
# Build Claude Code Usage.app, sign it for Developer ID distribution, pack a
# disk image, and optionally notarize and staple it.
#
#   sh scripts/bundle.sh                      build and sign
#   NOTARY_PROFILE=<profile> sh scripts/bundle.sh   also notarize and staple
#
# Your own identifiers belong in scripts/release.env, which git ignores. Copy
# scripts/release.env.example to get started. Nothing here needs editing to
# build the project under your own developer account.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Per-developer settings. The file assigns with ${VAR:-default} so anything
# already exported still wins.
if [ -f scripts/release.env ]; then
    . ./scripts/release.env
fi

BINARY=claude-usage
APP_NAME="Claude Code Usage"
PLACEHOLDER_BUNDLE_ID=com.example.claude-usage
# Baked into the signature and remembered by macOS, so treat it as permanent.
BUNDLE_ID=${BUNDLE_ID:-$PLACEHOLDER_BUNDLE_ID}
MIN_MACOS=11.0
CATEGORY=public.app-category.developer-tools
VERSION=$(sed -n '/^\[package\]/,/^\[/s/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)

# Notarization requires a Developer ID Application certificate. An Apple
# Development certificate signs fine locally but Apple will reject the upload.
IDENTITY=${SIGN_IDENTITY:-$(
    security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1
)}
# Without a paid developer account the app can still be signed ad-hoc, which is
# enough to run it on the machine that built it.
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application certificate found, signing ad-hoc."
    echo "the app will run here but cannot be notarized or distributed."
    IDENTITY=-
fi

if [ "$IDENTITY" = "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "an ad-hoc signature cannot be notarized" >&2
    exit 1
fi

if [ "$BUNDLE_ID" = "$PLACEHOLDER_BUNDLE_ID" ]; then
    echo "warning: signing as $BUNDLE_ID. Set BUNDLE_ID in scripts/release.env" >&2
fi

OUT="$ROOT/target/bundle"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$BINARY-$VERSION.dmg"
ZIP="$OUT/$BINARY-$VERSION.zip"

echo "==> building $BINARY $VERSION"
# Compiled into the binary so GPUI's window id matches the bundle id.
APP_BUNDLE_ID="$BUNDLE_ID" cargo build --release

echo "==> assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "target/release/$BINARY" "$APP/Contents/MacOS/$BINARY"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# LSUIElement is what keeps the Dock tile from flashing before the app has a
# window to show. The binary sets the policy itself from then on, switching to
# regular while the window is up and back to accessory when it is parked, which
# is also what `cargo run` outside a bundle relies on.
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$BINARY</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>$CATEGORY</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# No entitlements file, and deliberately no App Sandbox. The app runs the claude
# CLI through a login shell and reads Claude Code's keychain item, and the
# sandbox has no entitlement that would allow either. The hardened runtime that
# notarization requires does not block spawning child processes.
echo "==> signing as $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
    # A timestamp needs a real certificate, so ad-hoc goes without one.
    codesign --force --options runtime --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> packing disk image"
STAGE="$OUT/dmg-stage"
RW_DMG="$OUT/.rw.dmg"
MOUNT="/Volumes/$APP_NAME"
DEVICE=

detach_rw() {
    [ -n "${DEVICE:-}" ] || return 0
    n=0
    while [ "$n" -lt 8 ]; do
        if hdiutil detach "$DEVICE" >/dev/null; then
            DEVICE=
            return 0
        fi
        n=$((n + 1))
        sleep 1
    done
    hdiutil detach "$DEVICE" -force >/dev/null || true
    DEVICE=
}

if [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
fi

rm -rf "$STAGE" "$DMG" "$RW_DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$RW_DMG"
rm -rf "$STAGE"

DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" |
    awk '/^\/dev\//{print $1; exit}')
if [ -z "$DEVICE" ]; then
    echo "failed to mount disk image" >&2
    exit 1
fi
trap 'detach_rw; rm -f "$RW_DMG"' EXIT
n=0
while [ ! -d "$MOUNT" ]; do
    n=$((n + 1))
    if [ "$n" -gt 15 ]; then
        echo "disk image did not appear at $MOUNT" >&2
        detach_rw
        exit 1
    fi
    sleep 1
done
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"

# Finder stores this window in .DS_Store on the volume. Without it, the image
# opens as a normal folder: toolbar, sidebar, whatever view the user last used.
# Close the window before unmounting so that file actually gets written.
osascript <<EOF
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 120, 1000, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        try
            set sidebar width of container window to 0
        end try
        set position of item "$APP_NAME.app" of container window to {160, 180}
        set position of item "Applications" of container window to {440, 180}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sleep 1
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
bless --folder "$MOUNT" --openfolder "$MOUNT" 2>/dev/null || true
detach_rw

rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW_DMG"

if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and resource forks.
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo
    echo "signed: $APP"
    echo "disk image: $DMG"
    echo "set NOTARY_PROFILE to notarize and staple. Until then Gatekeeper will"
    echo "warn on any Mac but this one."
    exit 0
fi

echo "==> notarizing"
# Submit the disk image so Gatekeeper accepts the file people actually download.
# Apple issues tickets for the DMG and the app nested inside it.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> verifying as Gatekeeper sees it"
spctl --assess --type exec -vv "$APP"
xcrun stapler validate "$DMG"

echo
echo "notarized: $DMG"
