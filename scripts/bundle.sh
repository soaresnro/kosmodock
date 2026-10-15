#!/usr/bin/env bash
# Builds Kosmodock and packages it as a signed Kosmodock.app in the repo root.
#
#   bash scripts/bundle.sh                 # release build
#   CONFIGURATION=debug bash scripts/bundle.sh
#   SIGN_IDENTITY="Developer ID Application: …" bash scripts/bundle.sh
#
# Signing: uses "Kosmodock Local Signing" (created by scripts/setup-signing.sh)
# when present, so the Accessibility grant survives rebuilds; otherwise falls
# back to an ad-hoc signature, which macOS treats as a new app on every build.
# The release workflow sets SIGN_IDENTITY to a Developer ID or to the SHA-1 of
# the release certificate (scripts/create-release-certificate.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Kosmodock"
BUNDLE_ID="${BUNDLE_ID:-dev.kosmodock.Kosmodock}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
CONFIGURATION="${CONFIGURATION:-release}"
LOCAL_IDENTITY="Kosmodock Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-certificate -c "$LOCAL_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
        echo "⚠︎ Ad-hoc signing: macOS will ask for Accessibility again after every rebuild."
        echo "  Run 'bash scripts/setup-signing.sh' once to keep the permission across builds."
    fi
fi
APP="$ROOT/$APP_NAME.app"

cd "$ROOT"

echo "▸ Building $APP_NAME ($CONFIGURATION, arm64)…"
swift build -c "$CONFIGURATION" --arch arm64
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"

ICON="$ROOT/Assets/AppIcon.icns"
ICON_SCRIPT="$ROOT/scripts/generate_icon.swift"
if [[ ! -f "$ICON" || "$ICON_SCRIPT" -nt "$ICON" ]]; then
    echo "▸ Rendering AppIcon.icns…"
    swift "$ICON_SCRIPT" "$ICON"
fi

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Interface translations (en, pt-BR, es), read by SwiftUI and L10n at runtime.
cp -R "$ROOT"/Localization/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>pt-BR</string>
        <string>es</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Kosmodock uses Accessibility to move and resize the windows of your app groups for one-click tiling layouts.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Signing (identity: $SIGN_IDENTITY)…"
CODESIGN_FLAGS=(--force --deep --sign "$SIGN_IDENTITY")
# Notarization requires the hardened runtime and a secure timestamp.
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "  Identity: $(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"

# Refresh Finder / System Settings' cached icon for the rebuilt bundle.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
echo "  Launch with: open \"$APP\""
