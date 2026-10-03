#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DELTARUNE Mod Installer"
BUILD="$ROOT/.build"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
STAGING="$BUILD/pkgroot"
SCRIPTS="$BUILD/pkg-scripts"
INSTALLER_RESOURCES="$BUILD/installer-resources"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
COMPONENT_PKG="$BUILD/DELTARUNE-Mod-Installer-component.pkg"

XDELTA="/opt/homebrew/Cellar/xdelta/3.2.0/bin/xdelta3"
LZMA="/opt/homebrew/opt/xz/lib/liblzma.5.dylib"
BLAKE3="/opt/homebrew/opt/blake3/lib/libblake3.1.8.7.dylib"

for dependency in "$XDELTA" "$LZMA" "$BLAKE3"; do
    if [[ ! -f "$dependency" ]]; then
        printf 'Missing build dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done

rm -rf "$APP" "$STAGING" "$SCRIPTS" "$INSTALLER_RESOURCES" "$COMPONENT_PKG" \
    "$BUILD/AppIcon.png" "$BUILD/AppIcon.iconset"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES" "$FRAMEWORKS" "$STAGING" "$SCRIPTS" "$INSTALLER_RESOURCES"

swiftc -parse-as-library -swift-version 5 -O \
    -framework AppKit -framework UniformTypeIdentifiers \
    "$ROOT/DeltaruneModInstaller.swift" \
    -o "$CONTENTS/MacOS/DeltaruneModInstaller"

swift "$ROOT/create-app-icon.swift" "$ROOT/AppIconArtwork.png" "$BUILD/AppIcon.png"
mkdir -p "$BUILD/AppIcon.iconset"
for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$BUILD/AppIcon.png" \
        --out "$BUILD/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$BUILD/AppIcon.png" \
        --out "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"

cp "$XDELTA" "$RESOURCES/xdelta3"
cp "$LZMA" "$FRAMEWORKS/liblzma.5.dylib"
cp "$BLAKE3" "$FRAMEWORKS/libblake3.0.dylib"

install_name_tool -change /opt/homebrew/opt/xz/lib/liblzma.5.dylib \
    @executable_path/../Frameworks/liblzma.5.dylib "$RESOURCES/xdelta3"
install_name_tool -change /opt/homebrew/opt/blake3/lib/libblake3.0.dylib \
    @executable_path/../Frameworks/libblake3.0.dylib "$RESOURCES/xdelta3"
install_name_tool -id @executable_path/../Frameworks/liblzma.5.dylib "$FRAMEWORKS/liblzma.5.dylib"
install_name_tool -id @executable_path/../Frameworks/libblake3.0.dylib "$FRAMEWORKS/libblake3.0.dylib"

codesign --force --sign - --timestamp=none "$FRAMEWORKS/liblzma.5.dylib"
codesign --force --sign - --timestamp=none "$FRAMEWORKS/libblake3.0.dylib"
codesign --force --sign - --timestamp=none "$RESOURCES/xdelta3"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DeltaruneModInstaller</string>
    <key>CFBundleIdentifier</key>
    <string>com.deltarune.mod-installer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DELTARUNE Mod Installer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cp "$ROOT/THIRD-PARTY-NOTICES.txt" "$RESOURCES/"
codesign --force --deep --sign - --timestamp=none "$APP"
ditto --noextattr --noqtn --norsrc "$APP" "$STAGING/$APP_NAME.app"
dot_clean -m "$STAGING"
cp "$ROOT/package-scripts/preinstall" "$SCRIPTS/preinstall"
chmod 755 "$SCRIPTS/preinstall"

pkgbuild \
    --root "$STAGING" \
    --scripts "$SCRIPTS" \
    --identifier com.deltarune.mod-installer \
    --version 1.0 \
    --install-location /Applications \
    "$COMPONENT_PKG"

{
    cat "$ROOT/README.md"
    printf '\n\n--- THIRD-PARTY NOTICES ---\n\n'
    cat "$ROOT/THIRD-PARTY-NOTICES.txt"
} > "$INSTALLER_RESOURCES/Installer-ReadMe.txt"

productbuild \
    --distribution "$ROOT/package-scripts/distribution.xml" \
    --package-path "$BUILD" \
    --resources "$INSTALLER_RESOURCES" \
    "$ROOT/DELTARUNE-Mod-Installer.pkg"

printf 'Created %s\n' "$ROOT/DELTARUNE-Mod-Installer.pkg"
