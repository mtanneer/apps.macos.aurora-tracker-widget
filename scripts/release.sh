#!/bin/zsh
# Build, sign (Developer ID), notarize, staple and zip AuroraTracker for a GitHub release;
# prints the sha256 for the Homebrew cask.
# usage: scripts/release.sh            (version read from the project's MARKETING_VERSION)
#        SKIP_NOTARIZE=1 scripts/release.sh   (sign + verify only, for local testing)
# one-time setup (needs your Apple ID + an app-specific password, so run it yourself):
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id B768V573Z6
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="B768V573Z6"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Manas Tanneeru ($TEAM)}"
PROFILE="${NOTARY_PROFILE:-notary}"
OUT="tmp/release"

V=$(xcodebuild -project AuroraTracker.xcodeproj -scheme AuroraTracker -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
[[ -n "$V" ]] || { echo "could not read MARKETING_VERSION" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project AuroraTracker.xcodeproj -scheme AuroraTracker -configuration Release \
    -derivedDataPath "$OUT/dd" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    build | tail -3

APP="$OUT/AuroraTracker.app"
cp -R "$OUT/dd/Build/Products/Release/AuroraTracker.app" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# get-task-allow is a debug entitlement; notarization rejects it.
for b in "$APP" "$APP"/Contents/PlugIns/*.appex; do
    ! codesign -d --entitlements - "$b" 2>/dev/null | grep -q get-task-allow \
        || { echo "get-task-allow present: $b" >&2; exit 1; }
done
# Both the app and the embedded widget must carry the app group, or they won't share data.
for b in "$APP" "$APP"/Contents/PlugIns/*.appex; do
    codesign -d --entitlements - "$b" 2>/dev/null | grep -q "$TEAM.group.manas.projects.AuroraTracker" \
        || { echo "missing app group entitlement: $b" >&2; exit 1; }
done

ZIP="$OUT/AuroraTracker-$V.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
    spctl -a -vv "$APP"
fi
# Build copies register their widget extension under the same bundle ID and can shadow the installed one.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for a in "$OUT/dd/Build/Products/Release/AuroraTracker.app" "$APP"; do
    pluginkit -r "$a"/Contents/PlugIns/*.appex 2>/dev/null || true
    "$LSR" -u "$PWD/$a" 2>/dev/null || true
done
echo "version: $V"
echo "zip:     $ZIP"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
