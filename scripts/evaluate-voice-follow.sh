#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release --product VoiceFollowEvaluation -debug-info-format none
swift run --disable-sandbox --skip-build -c release VoiceFollowEvaluation "$@"
