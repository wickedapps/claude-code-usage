#!/bin/sh
# Build Claude Code Usage.app, sign it, and pack a zip and a disk image.
#
#   sh scripts/bundle.sh
#
# Your own identifiers belong in scripts/release.env, which git ignores. Copy
# scripts/release.env.example to start. Exported variables override the file.
#
# The first Developer ID Application certificate in your keychain signs the
# app and the widget, and TEAM_ID is read from its name. Without one the app is
# signed ad-hoc and the widget is left out. NOTARY_PROFILE notarizes and staples
# the app and the disk image. PACK_DMG=0 skips the disk image.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Per-developer settings. The file assigns with ${VAR:-default}, so anything
# already exported still wins.
if [ -f scripts/release.env ]; then
    . ./scripts/release.env
fi

BINARY=ClaudeUsage
APP_NAME="Claude Code Usage"
WIDGET_NAME=ClaudeUsageWidget
PLACEHOLDER_BUNDLE_ID=com.example.claude-usage
BUNDLE_ID=${BUNDLE_ID:-$PLACEHOLDER_BUNDLE_ID}
MIN_MACOS=13.0
CATEGORY=public.app-category.developer-tools
VERSION=${VERSION:-$(cat "$ROOT/native/VERSION")}
if [ -z "$VERSION" ]; then
    VERSION=0.4
fi

# Notarization needs a Developer ID Application certificate. An Apple
# Development certificate signs locally, but Apple rejects the upload.
SIGN_IDENTITY=${SIGN_IDENTITY:-$(
    security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1
)}
TEAM_ID=${TEAM_ID:-$(printf '%s\n' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Za-z0-9]*\))$/\1/p')}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
INCLUDE_WIDGET=0
APP_GROUP_ID=

if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_IDENTITY="-"
    echo "ad-hoc signature; widget omitted"
else
    if [ -z "$TEAM_ID" ]; then
        echo "TEAM_ID is required when SIGN_IDENTITY is set" >&2
        exit 1
    fi
    case "$TEAM_ID" in
        *[!A-Za-z0-9]*)
            echo "TEAM_ID must be an Apple team identifier" >&2
            exit 1
            ;;
    esac
    INCLUDE_WIDGET=1
    APP_GROUP_ID="$TEAM_ID.$BUNDLE_ID"
fi

if [ "$SIGN_IDENTITY" = "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "an ad-hoc signature cannot be notarized" >&2
    exit 1
fi

if [ "$INCLUDE_WIDGET" -eq 1 ] && [ "$BUNDLE_ID" = "$PLACEHOLDER_BUNDLE_ID" ]; then
    echo "warning: signing as $BUNDLE_ID. Set BUNDLE_ID to an identifier you own." >&2
fi

OUT="$ROOT/target/native"
APP="$OUT/$APP_NAME.app"
ZIP="$OUT/claude-usage-$VERSION.zip"
DMG="$OUT/claude-usage-$VERSION.dmg"
WIDGET_DERIVED="$OUT/widget-build"
WIDGET_PRODUCT="$WIDGET_DERIVED/Build/Products/Release/$WIDGET_NAME.appex"
APP_ENTITLEMENTS="$OUT/.app.entitlements"
WIDGET_ENTITLEMENTS="$OUT/.widget.entitlements"

echo "==> building $BINARY $VERSION"
swift build -c release --package-path "$ROOT/native" --product ClaudeUsage
BIN_DIR=$(swift build -c release --package-path "$ROOT/native" --product ClaudeUsage --show-bin-path)
BIN="$BIN_DIR/$BINARY"
if [ ! -x "$BIN" ]; then
    echo "missing executable at $BIN" >&2
    exit 1
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
cp "$BIN" "$APP/Contents/MacOS/$BINARY"
chmod +x "$APP/Contents/MacOS/$BINARY"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    mkdir -p "$APP/Contents/PlugIns"
    ditto "$WIDGET_PRODUCT" "$APP/Contents/PlugIns/$WIDGET_NAME.appex"
fi

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
PLIST

if [ "$INCLUDE_WIDGET" -eq 1 ]; then
    cat >>"$APP/Contents/Info.plist" <<PLIST
	<key>AppGroupIdentifier</key>
	<string>$APP_GROUP_ID</string>
PLIST
fi

cat >>"$APP/Contents/Info.plist" <<PLIST
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

echo "==> signing as $SIGN_IDENTITY"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --options runtime --sign - "$APP"
else
    codesign \
        --force --options runtime --timestamp \
        --entitlements "$WIDGET_ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/PlugIns/$WIDGET_NAME.appex"
    codesign \
        --force --options runtime --timestamp \
        --entitlements "$APP_ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> notarizing app"
    NOTARY_ZIP="$OUT/.notary-app.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$NOTARY_ZIP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${PACK_DMG:-1}" = "1" ]; then
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
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"
    rm -rf "$STAGE"

    DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/^\/dev\//{print $1; exit}')
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
            exit 1
        fi
        sleep 1
    done
    rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"

    # Finder writes this layout to the volume's .DS_Store when the window closes.
    # Without it the image opens as an ordinary folder window. Scripting Finder
    # needs Automation permission for the calling app; without it the image
    # keeps its Applications link but opens with Finder's default view.
    osascript <<APPLESCRIPT || echo "warning: Finder layout skipped (allow Automation of Finder for this terminal to keep it)" >&2
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
APPLESCRIPT

    sleep 1
    rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
    detach_rw
    hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -f "$RW_DMG"
    trap - EXIT

    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
        codesign --verify --verbose=2 "$DMG"
    fi
    if [ -n "$NOTARY_PROFILE" ]; then
        # The app inside already carries its ticket; the image is a separate artifact.
        echo "==> notarizing disk image"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
fi

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> verifying as Gatekeeper sees it"
    spctl --assess --type exec -vv "$APP"
fi

echo
echo "signed: $APP"
echo "zip: $ZIP"
if [ "${PACK_DMG:-1}" = "1" ]; then
    echo "disk image: $DMG"
fi
