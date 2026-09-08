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
WIDGET_NAME=ClaudeUsageWidget
PLACEHOLDER_BUNDLE_ID=com.example.claude-usage
# Baked into the signature and remembered by macOS, so treat it as permanent.
BUNDLE_ID=${BUNDLE_ID:-$PLACEHOLDER_BUNDLE_ID}
MIN_MACOS=13.0
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

# A WidgetKit extension cannot share the host's snapshot under an ad-hoc
# signature because that signature has no developer team identity. Keep the
# useful local bundle in that case, but leave out the nonworking extension.
INCLUDE_WIDGET=1
APP_GROUP_ID=
if [ "$IDENTITY" = "-" ]; then
    INCLUDE_WIDGET=0
    echo "widget omitted: an ad-hoc signature has no App Group identity."
else
    TEAM_ID=${TEAM_ID:-$(
        printf '%s\n' "$IDENTITY" |
            sed -n 's/.*(\([A-Za-z0-9]*\))$/\1/p'
    )}
    if [ -z "$TEAM_ID" ]; then
        echo "could not derive TEAM_ID from SIGN_IDENTITY; set TEAM_ID in scripts/release.env" >&2
        exit 1
    fi
    APP_GROUP_ID="$TEAM_ID.$BUNDLE_ID"
fi

if [ "$BUNDLE_ID" = "$PLACEHOLDER_BUNDLE_ID" ]; then
    echo "warning: signing as $BUNDLE_ID. Set BUNDLE_ID in scripts/release.env" >&2
fi

OUT="$ROOT/target/bundle"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$BINARY-$VERSION.dmg"
ZIP="$OUT/$BINARY-$VERSION.zip"
NOTARY_APP_ZIP="$OUT/.notary-app.zip"
WIDGET_DERIVED="$OUT/widget-build"
WIDGET_PRODUCT="$WIDGET_DERIVED/Build/Products/Release/$WIDGET_NAME.appex"
APP_ENTITLEMENTS="$OUT/.app.entitlements"
WIDGET_ENTITLEMENTS="$OUT/.widget.entitlements"

echo "==> building $BINARY $VERSION"
# Compiled into the binary so GPUI's window id matches the bundle id.
if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    APP_BUNDLE_ID="$BUNDLE_ID" APP_GROUP_ID="$APP_GROUP_ID" cargo build --release
else
    APP_BUNDLE_ID="$BUNDLE_ID" cargo build --release
fi

if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    echo "==> building widget"
    xcodebuild \
        -project widget/ClaudeUsageWidget.xcodeproj \
        -scheme "$WIDGET_NAME" \
        -configuration Release \
        -derivedDataPath "$WIDGET_DERIVED" \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=YES \
        HOST_BUNDLE_ID="$BUNDLE_ID" \
        APP_GROUP_ID="$APP_GROUP_ID" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$VERSION" \
        build
fi

echo "==> assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "target/release/$BINARY" "$APP/Contents/MacOS/$BINARY"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    mkdir -p "$APP/Contents/PlugIns"
    ditto "$WIDGET_PRODUCT" "$APP/Contents/PlugIns/$WIDGET_NAME.appex"
fi

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
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>$BUNDLE_ID</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>$BUNDLE_ID</string>
			</array>
		</dict>
	</array>
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

# The main app stays outside App Sandbox because it runs the claude CLI and
# reads Claude Code's keychain item. A signed widget build gives it only the App
# Group entitlement used for the snapshot. The extension itself is sandboxed.
if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    cat >"$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP_ID</string>
	</array>
</dict>
</plist>
PLIST
    cat >"$WIDGET_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$APP_GROUP_ID</string>
	</array>
</dict>
</plist>
PLIST
    plutil -lint "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS" >/dev/null
fi

echo "==> signing as $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
    # A timestamp needs a real certificate, so ad-hoc goes without one.
    codesign --force --options runtime --sign - "$APP"
else
    codesign \
        --force --options runtime --timestamp \
        --entitlements "$WIDGET_ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$APP/Contents/PlugIns/$WIDGET_NAME.appex"
    codesign \
        --force --options runtime --timestamp \
        --entitlements "$APP_ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# Staple the app before copying it into the disk image. Stapling only $APP
# after the DMG exists would leave the app inside the DMG without its ticket.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> notarizing app"
    rm -f "$NOTARY_APP_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARY_APP_ZIP"
    xcrun notarytool submit "$NOTARY_APP_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$NOTARY_APP_ZIP"
fi

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

# ditto, not zip: it preserves the bundle's symlinks and resource forks. When
# notarizing, $APP already has its ticket at this point.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo
    echo "signed: $APP"
    echo "disk image: $DMG"
    echo "set NOTARY_PROFILE to notarize and staple. Until then Gatekeeper will"
    echo "warn on any Mac but this one."
    exit 0
fi

echo "==> notarizing disk image"
# The app inside already carries its ticket. Submit and staple the finished
# disk image as a separate distribution artifact.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

xcrun stapler staple "$DMG"

echo "==> verifying as Gatekeeper sees it"
spctl --assess --type exec -vv "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo
echo "notarized: $DMG"
