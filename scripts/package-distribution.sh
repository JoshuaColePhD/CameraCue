#!/bin/zsh
# This command uses a signing key only when invoked explicitly by its owner.
# Notarization uploads the app binary to Apple, never the user's library or media.
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:---prepare}"
case "$mode" in
  --prepare|--notarize) ;;
  *) print -u2 'Usage: package-distribution.sh [--prepare|--notarize]'; exit 2 ;;
esac
: "${CAMERACUE_DEVELOPER_ID:?Set an authorized Developer ID Application signing identity}"
if [[ "$mode" == --notarize ]]; then
  : "${CAMERACUE_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
fi
CAMERACUE_SIGNING_IDENTITY=- ./build-app.sh release
app="$PWD/dist/CameraCue Studio.app"
codesign --force --options runtime --timestamp --entitlements Assets/CameraCue.entitlements --sign "$CAMERACUE_DEVELOPER_ID" "$app"
codesign --verify --deep --strict "$app"
# A personal/local certificate cannot produce a customer distribution artifact.
signature="$(codesign --display --verbose=2 "$app" 2>&1)"
if [[ "$signature" != *'Authority=Developer ID Application:'* ]]; then
  print -u2 'A Developer ID Application certificate is required. No archive or upload was produced.'
  exit 1
fi
archive="$PWD/dist/CameraCue-Studio-submission.zip"
ditto -c -k --keepParent "$app" "$archive"
if [[ "$mode" == --prepare ]]; then
  print "Prepared Developer ID archive: $archive"
  print 'Not notarized; do not label this artifact a verified customer release.'
  exit 0
fi
result="$PWD/dist/notarization-result.json"
xcrun notarytool submit "$archive" --keychain-profile "$CAMERACUE_NOTARY_PROFILE" --wait --output-format json > "$result"
python3 - "$result" <<'PY_ACCEPTED'
import json, sys
with open(sys.argv[1]) as handle:
    result = json.load(handle)
if result.get("status") != "Accepted":
    raise SystemExit("Apple did not accept the notarization submission; inspect dist/notarization-result.json")
PY_ACCEPTED
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
# Repackage after stapling so customers receive the notarization ticket.
ditto -c -k --keepParent "$app" "$PWD/dist/CameraCue-Studio.zip"
print "Verified notarized archive: $PWD/dist/CameraCue-Studio.zip"
