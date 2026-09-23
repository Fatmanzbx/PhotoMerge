#!/bin/bash
# Build PhotoMerge.app with the Command Line Tools only — no Xcode project.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PhotoMerge.app"
BIN="$APP/Contents/MacOS/PhotoMerge"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SwiftUI's @State/@StateObject are macros in recent SDKs, and the macro plugin
# (libSwiftUIMacros.dylib) ships with Xcode, not the Command Line Tools.
if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
else
    echo "error: Xcode is required (SwiftUI macro plugins are not in the CLT)." >&2
    exit 1
fi

# The version stamped into the bundle; make_dmg.sh passes the release tag.
VERSION="${VERSION:-1.0.0}"

# Built for macOS 14 (Sonoma) and newer. ARCHS=universal also builds for Intel
# Macs and joins the two with lipo; the default is this machine's architecture.
compile() {  # compile <arch> <out>
    xcrun swiftc -O -parse-as-library -swift-version 5 -target "$1-apple-macos14.0" \
        -framework SwiftUI -framework AppKit -framework ImageIO \
        -framework CoreGraphics -framework QuickLookThumbnailing \
        Sources/*.swift -o "$2"
}
echo "compiling…"
if [ "${ARCHS:-}" = "universal" ]; then
    compile arm64 "$BIN.arm64"; compile x86_64 "$BIN.x86_64"
    lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN" && rm "$BIN.arm64" "$BIN.x86_64"
else
    compile "$(uname -m)" "$BIN"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>PhotoMerge</string>
    <key>CFBundleDisplayName</key>       <string>PhotoMerge</string>
    <key>CFBundleIdentifier</key>        <string>local.photomerge.app</string>
    <key>CFBundleVersion</key>           <string>__VERSION__</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleExecutable</key>        <string>PhotoMerge</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Never modifies your photos — writes only new copies you ask for.</string>
</dict>
</plist>
PLIST
sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

# The icon: Tools/make_icon.swift draws it.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Place names, offline (GeoNames, CC BY 4.0): Tools/make_places.py rebuilds it.
[ -f Resources/places.tsv ] && cp Resources/places.tsv "$APP/Contents/Resources/places.tsv"

# Bundle exiftool: the only lossless writer of the full capture-date set (SPIKES §1).
# The script with its lib/ beside it, run by /usr/bin/perl as a separate process —
# exiftool is GPL/Artistic, so it is shipped alongside, never linked.
ET_HOME=""
for d in /opt/homebrew/Cellar/exiftool/*/libexec /usr/local/Cellar/exiftool/*/libexec; do
    if [ -f "$d/bin/exiftool" ] && [ -d "$d/lib/perl5/Image" ]; then ET_HOME="$d"; fi
done
if [ -n "$ET_HOME" ]; then
    # exiftool needs only its own modules; Homebrew nests them in lib/perl5 beside
    # unrelated ones, so copy just Image/ and File/ into the lib/ exiftool expects.
    mkdir -p "$APP/Contents/Resources/exiftool/lib"
    cp "$ET_HOME/bin/exiftool" "$APP/Contents/Resources/exiftool/exiftool"
    cp -R "$ET_HOME/lib/perl5/Image" "$ET_HOME/lib/perl5/File" "$APP/Contents/Resources/exiftool/lib/"
    cat > "$APP/Contents/Resources/exiftool/LICENSE" <<'LIC'
ExifTool by Phil Harvey — https://exiftool.org
This is free software; you can redistribute it and/or modify it under the same terms
as Perl itself (the GNU General Public License or the Artistic License). PhotoMerge runs
it as a separate program; its full source is this directory, unmodified.
LIC
    ET_VER=$(/usr/bin/perl "$APP/Contents/Resources/exiftool/exiftool" -ver 2>/dev/null)
    [ -n "$ET_VER" ] || { echo "BUILD FAILED: bundled exiftool does not run" >&2; exit 1; }
    echo "  exiftool $ET_VER bundled"
else
    echo "  WARNING: exiftool not found (brew install exiftool) — writing a merged copy will be unavailable"
fi

# Ad-hoc signature so the app can be launched locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

# Verify the artefact exists — not merely that nothing printed "error".
if [ ! -x "$BIN" ]; then
    echo "BUILD FAILED: no binary at $BIN" >&2
    exit 1
fi
# the screenshot helper lives outside build/ because this script wipes build/
if [ -f Tools/wid.swift ] && [ ! -x Tools/wid ]; then
    xcrun swiftc -O Tools/wid.swift -o Tools/wid 2>/dev/null || true
fi

echo "built: $APP  ($(du -h "$BIN" | cut -f1))"
