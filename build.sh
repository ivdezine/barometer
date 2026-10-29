#!/bin/bash
# Builds Barometer.app from Barometer.swift with swiftc (no Xcode project).
#   bash build.sh            -> build/Barometer.app
#   bash build.sh --install  -> also copies it to ~/Applications
# OUT_DIR overrides the output folder (the test builds into a temp folder this way). ARCH overrides
# the architecture, which is otherwise this Mac's own (arm64 or x86_64).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT_DIR:-$here/build}"
arch="${ARCH:-$(uname -m)}"
version="1.0.0"
build="$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$here" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$here" status --porcelain -- . 2>/dev/null)" ]; then commit="$commit-dirty"; fi

app="$out/Barometer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

# macOS 14 is the floor: the hover layer needs Charts' plotFrame and the panel uses NSApp.activate().
swiftc -O -target "$arch-apple-macos14" -o "$app/Contents/MacOS/Barometer" "$here/Barometer.swift" \
  -framework AppKit -framework SwiftUI -framework Charts

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ivdezine.barometer</string>
  <key>CFBundleName</key><string>Barometer</string>
  <key>CFBundleExecutable</key><string>Barometer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>GitCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed; the app still runs" >&2

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Barometer.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed: $HOME/Applications/Barometer.app (Version $version · build $build ($commit), $arch)"
else
  echo "Built: $app (Version $version · build $build ($commit), $arch)"
fi
