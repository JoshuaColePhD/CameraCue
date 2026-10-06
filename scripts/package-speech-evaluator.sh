#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-cache/swiftpm"
swift build --disable-sandbox --product SpeechEvaluation
binary_directory="$(swift build --disable-sandbox --show-bin-path)"
app="$PWD/ReviewArtifacts/MLCorpus/CameraCue Speech Evaluation.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_directory/SpeechEvaluation" "$app/Contents/MacOS/SpeechEvaluation"
cp Sources/SpeechEvaluation/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
print "$app"
