#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
configuration="${1:-release}"
case "$configuration" in
  release) product_directory=Release ;;
  debug) product_directory=Debug ;;
  *) print -u2 "Usage: ./build-app.sh [release|debug]"; exit 2 ;;
esac
mkdir -p .build-cache/clang .build-cache/swiftpm dist
cp Assets/CameraCueIcon.png Sources/TeleprompterApp/Resources/CameraCueLogo.png
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache/swiftpm"
if [[ "$configuration" == release ]]; then
  # This local app does not package dSYMs; avoid SwiftPM's sandboxed dSYM step.
  swift build --disable-sandbox --scratch-path "$PWD/.build" -c "$configuration" -debug-info-format none
else
  swift build --disable-sandbox --scratch-path "$PWD/.build" -c "$configuration"
fi
app="$PWD/dist/CameraCue.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary_directory="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
cp "$binary_directory/Teleprompter" "$app/Contents/MacOS/CameraCue"
ditto "$binary_directory/Teleprompter_TeleprompterApp.bundle" "$app/Contents/Resources/Teleprompter_TeleprompterApp.bundle"
python3 scripts/package-app-icon.py Assets/CameraCueIcon.png Assets/CameraCue.icns
cp Assets/CameraCue.icns "$app/Contents/Resources/CameraCue.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CameraCue</string>
<key>CFBundleDisplayName</key><string>CameraCue</string>
<key>CFBundleIdentifier</key><string>com.joshuacole.cameracue</string>
<key>CFBundleExecutable</key><string>CameraCue</string>
<key>CFBundleIconFile</key><string>CameraCue.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrefersDisplaySafeAreaCompatibilityMode</key><false/>
<key>NSCameraUsageDescription</key><string>CameraCue records your camera video when you start a take or shows a preview when you request one.</string>
<key>NSMicrophoneUsageDescription</key><string>CameraCue records audio with your camera video and listens to keep the script following your voice.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>CameraCue recognizes your spoken words locally when supported to keep your place in the script.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null
print "Built $app"
