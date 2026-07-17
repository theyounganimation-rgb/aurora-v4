#!/bin/zsh
set -euo pipefail

ROOT="$(cd "${0:A:h:h}" && pwd -P)"
CONFIGURATION="${1:-release}"
DIST_DIR="${AURORA_DIST_DIR:-$ROOT/dist}"
# Keep one unambiguous installed copy in the standard per-user Applications
# directory. AURORA_PRODUCTS_DIR remains available for an intentional isolated
# build, but the normal install, LaunchServices choice, TCC identity, receipt,
# and dist link now converge on the app the configured owner actually launches.
PRODUCTS_DIR="${AURORA_PRODUCTS_DIR:-$HOME/Applications}"
FINAL_APP="$PRODUCTS_DIR/Aurora.app"
DIST_APP_LINK="$DIST_DIR/Aurora.app"
DIST_ARCHIVE="$DIST_DIR/Aurora.app.zip"
INFO_PLIST="$ROOT/Resources/Info.plist"
ENTITLEMENTS="${AURORA_ENTITLEMENTS_PATH:-$ROOT/Resources/Aurora.entitlements}"
SOURCE_FINGERPRINT_HELPER="$ROOT/scripts/source-fingerprint.sh"
VERIFICATION_SCRIPT="$ROOT/scripts/verify.sh"
VERIFIED_SOURCE_STAMP="$ROOT/.build/aurora-verified-source-fingerprint"
SIGNING_IDENTITY="${AURORA_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${AURORA_NOTARY_PROFILE:-}"
BUILD_ROOT="${AURORA_BUILD_ROOT:-/private/tmp}"

fail() {
    print -u2 -- "Aurora packaging failed: $*"
    exit 1
}

case "$CONFIGURATION" in
    debug|release) ;;
    *) fail "configuration must be 'debug' or 'release'" ;;
esac

for command in swift iconutil plutil codesign ditto xattr shasum awk grep security pgrep ps osascript open zip unzip; do
    command -v "$command" >/dev/null 2>&1 || fail "required tool '$command' was not found"
done

[[ -f "$INFO_PLIST" ]] || fail "missing Resources/Info.plist"
[[ -f "$ENTITLEMENTS" ]] || fail "missing signing entitlements at $ENTITLEMENTS"
[[ -f "$SOURCE_FINGERPRINT_HELPER" ]] || fail "missing scripts/source-fingerprint.sh"
[[ -x "$VERIFICATION_SCRIPT" ]] || fail "missing executable scripts/verify.sh"
plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

require_usage_description() {
    local key value
    key="$1"
    value="$(plutil -extract "$key" raw -o - "$INFO_PLIST" 2>/dev/null || true)"
    [[ -n "${value//[[:space:]]/}" ]] || \
        fail "Resources/Info.plist is missing the required non-empty $key string"
}

# macOS terminates the process immediately when a protected capability is
# requested without its matching usage string. Keep that packaging failure out
# of users' hands by rejecting an incomplete bundle before compilation.
require_usage_description NSMicrophoneUsageDescription
require_usage_description NSSpeechRecognitionUsageDescription

# Symptom-level patches previously reached the installed app without proving
# that Aurora's other control paths still worked. Release packaging now has a
# hard source-graph gate: stale or missing proof triggers the entire suite,
# and a failure stops before any installed bundle is touched.
if [[ "$CONFIGURATION" == "release" ]]; then
    CURRENT_SOURCE_FINGERPRINT="$(zsh "$SOURCE_FINGERPRINT_HELPER" "$ROOT")"
    VERIFIED_SOURCE_FINGERPRINT=""
    [[ -f "$VERIFIED_SOURCE_STAMP" ]] && \
        VERIFIED_SOURCE_FINGERPRINT="$(<"$VERIFIED_SOURCE_STAMP")"
    if [[ "$VERIFIED_SOURCE_FINGERPRINT" != "$CURRENT_SOURCE_FINGERPRINT" ]]; then
        print -- "Aurora source changed since the last complete verification; running the full suite."
        "$VERIFICATION_SCRIPT"
        [[ -f "$VERIFIED_SOURCE_STAMP" ]] && \
            VERIFIED_SOURCE_FINGERPRINT="$(<"$VERIFIED_SOURCE_STAMP")"
    fi
    [[ "$VERIFIED_SOURCE_FINGERPRINT" == "$CURRENT_SOURCE_FINGERPRINT" ]] || \
        fail "the current source graph did not complete the full verification suite"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
    SIGNING_IDENTITY="$(print -r -- "$VALID_IDENTITIES" | awk -F '"' '
        /"Developer ID Application:/ && selected == "" { selected = $2 }
        END { print selected }
    ')"
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(print -r -- "$VALID_IDENTITIES" | awk -F '"' '
            /"Apple Development:/ && selected == "" { selected = $2 }
            END { print selected }
        ')"
    fi
    [[ -n "$SIGNING_IDENTITY" ]] || fail \
        "no stable code-signing identity was found; set AURORA_SIGNING_IDENTITY=- explicitly only for a disposable build"
fi

if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    fail "AURORA_NOTARY_PROFILE requires a Developer ID Application identity"
fi

# SwiftPM's default .build directory inherits FileProvider metadata when this
# checkout lives in a synced folder. Keep every compiler and bundle staging
# output on a local temporary volume, then copy only the completed app back.
mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"
case "$BUILD_ROOT/" in
    "$ROOT/"|"$ROOT/"*) fail "AURORA_BUILD_ROOT must be outside the source repository" ;;
esac

# A bare signed .app cannot remain valid inside this FileProvider-backed
# Documents checkout: the provider repeatedly restores a disallowed FinderInfo
# xattr. Keep the canonical runnable product outside the synced tree. dist gets
# a local convenience link plus a portable ZIP whose contents are re-verified.
[[ "$PRODUCTS_DIR" == /* ]] || fail "AURORA_PRODUCTS_DIR must be an absolute path"
[[ "$DIST_DIR" == /* ]] || fail "AURORA_DIST_DIR must be an absolute path"
mkdir -p "$PRODUCTS_DIR" "$DIST_DIR"
PRODUCTS_DIR="$(cd "$PRODUCTS_DIR" && pwd -P)"
DIST_DIR="$(cd "$DIST_DIR" && pwd -P)"
FINAL_APP="$PRODUCTS_DIR/Aurora.app"
DIST_APP_LINK="$DIST_DIR/Aurora.app"
DIST_ARCHIVE="$DIST_DIR/Aurora.app.zip"
BUILD_RECEIPT="$PRODUCTS_DIR/Aurora.build-receipt.plist"
case "$PRODUCTS_DIR/" in
    "$ROOT/"|"$ROOT/"*) fail "AURORA_PRODUCTS_DIR must be outside the source repository" ;;
esac
[[ "$PRODUCTS_DIR" != "$DIST_DIR" ]] || \
    fail "AURORA_PRODUCTS_DIR and AURORA_DIST_DIR must be different directories"

WORK_ROOT="$(mktemp -d "$BUILD_ROOT/aurora-package.XXXXXX")"
SOURCE_SNAPSHOT="$WORK_ROOT/source"
SCRATCH_PATH="$WORK_ROOT/swift-build"
STAGED_APP="$WORK_ROOT/Aurora.app"
ICONSET="$WORK_ROOT/Aurora.iconset"
NOTARY_ARCHIVE="$WORK_ROOT/Aurora-notarization.zip"
PORTABLE_ARCHIVE="$WORK_ROOT/Aurora.app.zip"
ARCHIVE_CHECK_ROOT="$WORK_ROOT/archive-check"
INCOMING_RECEIPT="$PRODUCTS_DIR/.Aurora.build-receipt.incoming.$$"
RELAUNCH_PENDING=0

cleanup() {
    rm -rf "$WORK_ROOT"
    rm -f "$INCOMING_RECEIPT"
    # If packaging failed after stopping a live installed copy, restore the
    # user's previous experience instead of leaving Aurora closed.
    if [[ "$RELAUNCH_PENDING" == 1 && -d "$FINAL_APP" ]]; then
        launch_aurora_with_clean_environment "$FINAL_APP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM HUP

aurora_executable_for_pid() {
    local pid command_line executable app bundle_identifier launchservices_identity
    pid="$1"
    command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
        *.app/Contents/MacOS/Aurora|*.app/Contents/MacOS/Aurora\ *)
            executable="${command_line%.app/Contents/MacOS/Aurora*}.app/Contents/MacOS/Aurora"
            app="${executable%/Contents/MacOS/Aurora}"
            launchservices_identity="$(/usr/bin/lsappinfo info -only bundleID \
                "$pid" 2>/dev/null || true)"
            if [[ "$launchservices_identity" == '"CFBundleIdentifier"="ai.aurora.voice"' ]]; then
                bundle_identifier="ai.aurora.voice"
            else
                bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
                    "$app/Contents/Info.plist" 2>/dev/null || true)"
            fi
            [[ "$bundle_identifier" == "ai.aurora.voice" ]] && print -r -- "$executable"
            ;;
    esac
    return 0
}

running_aurora_pids() {
    local pid executable
    for pid in ${(f)"$(pgrep -x Aurora 2>/dev/null || true)"}; do
        [[ -n "$pid" ]] || continue
        executable="$(aurora_executable_for_pid "$pid")"
        [[ -n "$executable" ]] && print -- "$pid"
    done
    return 0
}

running_final_app_pids() {
    local pid executable final_executable
    final_executable="$FINAL_APP/Contents/MacOS/Aurora"
    for pid in ${(f)"$(running_aurora_pids)"}; do
        executable="$(aurora_executable_for_pid "$pid")"
        [[ "$executable" == "$final_executable" ]] && print -- "$pid"
    done
    return 0
}

launch_aurora_with_clean_environment() {
    local app launch_user
    app="$1"
    launch_user="${USER:-$(/usr/bin/id -un)}"
    /usr/bin/env -i \
        HOME="$HOME" \
        USER="$launch_user" \
        LOGNAME="$launch_user" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="${TMPDIR:-/private/tmp}" \
        LANG="${LANG:-en_US.UTF-8}" \
        /usr/bin/open "$app"
}

stop_running_aurora_for_install() {
    local running_pids pid attempt still_running
    running_pids="$(running_aurora_pids)"
    [[ -n "$running_pids" ]] || return 0

    RELAUNCH_PENDING=1
    # Quit every running ai.aurora.voice bundle, including an older copy from a
    # previous install directory. Otherwise LaunchServices can keep serving the
    # stale process after the new signed bundle and receipt are published.
    osascript -e 'tell application id "ai.aurora.voice" to quit' >/dev/null 2>&1 || true
    for attempt in {1..40}; do
        still_running="$(running_aurora_pids)"
        [[ -z "$still_running" ]] && return 0
        sleep 0.1
    done

    for pid in ${(f)"$(running_aurora_pids)"}; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    for attempt in {1..20}; do
        still_running="$(running_aurora_pids)"
        [[ -z "$still_running" ]] && return 0
        sleep 0.1
    done
    fail "a running ai.aurora.voice copy did not quit; close Aurora before packaging"
}

relaunch_verified_installed_aurora() {
    local attempt running_pids final_pids
    launch_aurora_with_clean_environment "$FINAL_APP"
    for attempt in {1..100}; do
        running_pids="$(running_aurora_pids)"
        final_pids="$(running_final_app_pids)"
        if [[ -n "$running_pids" && "$running_pids" == "$final_pids" ]]; then
            return 0
        fi
        sleep 0.1
    done
    fail "Aurora did not relaunch exclusively from the newly installed bundle"
}

# Freeze only the files required to compile and package Aurora. This keeps the
# compiler fully off FileProvider storage, avoids a mixed build if an editor
# saves while compilation is running, and never sweeps dotfiles or credentials
# from the checkout into a release staging directory.
mkdir -p "$SOURCE_SNAPSHOT/Resources" "$SOURCE_SNAPSHOT/scripts"
install -m 644 "$ROOT/Package.swift" "$SOURCE_SNAPSHOT/Package.swift"
ditto --norsrc --noextattr --noacl --noqtn \
    "$ROOT/Sources" "$SOURCE_SNAPSHOT/Sources"
install -m 644 "$INFO_PLIST" "$SOURCE_SNAPSHOT/Resources/Info.plist"
install -m 644 "$ENTITLEMENTS" "$SOURCE_SNAPSHOT/Resources/Aurora.entitlements"
install -m 644 "$ROOT/scripts/render-icon.swift" "$SOURCE_SNAPSHOT/scripts/render-icon.swift"
install -m 644 "$SOURCE_FINGERPRINT_HELPER" "$SOURCE_SNAPSHOT/scripts/source-fingerprint.sh"
xattr -cr "$SOURCE_SNAPSHOT"
plutil -lint "$SOURCE_SNAPSHOT/Resources/Info.plist" >/dev/null
plutil -lint "$SOURCE_SNAPSHOT/Resources/Aurora.entitlements" >/dev/null
SOURCE_FINGERPRINT="$(zsh "$SOURCE_SNAPSHOT/scripts/source-fingerprint.sh" "$SOURCE_SNAPSHOT")"
print -r -- "$SOURCE_FINGERPRINT" | grep -Eq '^[0-9a-f]{64}$' || \
    fail "source fingerprint helper returned an invalid digest"
if [[ "$CONFIGURATION" == "release" ]]; then
    [[ "$SOURCE_FINGERPRINT" == "$VERIFIED_SOURCE_FINGERPRINT" ]] || \
        fail "the source changed after verification and before the release snapshot"
fi

swift build \
    --package-path "$SOURCE_SNAPSHOT" \
    --scratch-path "$SCRATCH_PATH" \
    -c "$CONFIGURATION"
BIN_DIR="$(swift build \
    --package-path "$SOURCE_SNAPSHOT" \
    --scratch-path "$SCRATCH_PATH" \
    -c "$CONFIGURATION" \
    --show-bin-path)"

[[ -x "$BIN_DIR/Aurora" ]] || fail "SwiftPM did not produce the Aurora executable"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 755 "$BIN_DIR/Aurora" "$STAGED_APP/Contents/MacOS/Aurora"
install -m 644 "$SOURCE_SNAPSHOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
swift "$SOURCE_SNAPSHOT/scripts/render-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/Aurora.icns"
UNSIGNED_EXECUTABLE_SHA256="$(shasum -a 256 "$STAGED_APP/Contents/MacOS/Aurora" | awk '{print $1}')"
plutil -replace AuroraSourceFingerprint -string "$SOURCE_FINGERPRINT" \
    "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

# Resource forks and FileProvider/Finder metadata can make an otherwise valid
# bundle fail codesign verification. Remove them before signing.
xattr -cr "$STAGED_APP"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_DESCRIPTION="explicit ad-hoc disposable signature"
    codesign \
        --force \
        --sign - \
        --entitlements "$SOURCE_SNAPSHOT/Resources/Aurora.entitlements" \
        "$STAGED_APP"
elif [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
    SIGNING_DESCRIPTION="stable hardened Developer ID signature: $SIGNING_IDENTITY"
    codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$SOURCE_SNAPSHOT/Resources/Aurora.entitlements" \
        "$STAGED_APP"
else
    SIGNING_DESCRIPTION="stable local development signature: $SIGNING_IDENTITY"
    codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements "$SOURCE_SNAPSHOT/Resources/Aurora.entitlements" \
        "$STAGED_APP"
fi

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    DESIGNATED_REQUIREMENT="$(codesign --display --requirements - "$STAGED_APP" 2>&1)"
    print -r -- "$DESIGNATED_REQUIREMENT" | grep -q 'cdhash H' && \
        fail "the stable signing identity unexpectedly produced a build-specific cdhash requirement"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for notarization"
    xcrun --find notarytool >/dev/null 2>&1 || \
        fail "notarytool was not found in the active Apple developer tools"
    xcrun --find stapler >/dev/null 2>&1 || \
        fail "stapler was not found in the active Apple developer tools"

    SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$STAGED_APP" 2>&1)"
    print -r -- "$SIGNATURE_DETAILS" | grep -q '^Authority=Developer ID Application:' || \
        fail "notarization requires a Developer ID Application signature"

    # The profile name is not a credential. notarytool retrieves the Apple ID
    # or App Store Connect secret from Keychain without exposing it here.
    ditto -c -k --keepParent "$STAGED_APP" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$STAGED_APP"
    xcrun stapler validate "$STAGED_APP"
    codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
fi

INCOMING_APP="$PRODUCTS_DIR/.Aurora.app.incoming.$$"
PREVIOUS_APP="$PRODUCTS_DIR/.Aurora.app.previous.$$"
rm -rf "$INCOMING_APP" "$PREVIOUS_APP"

# Do not copy source-volume xattrs, ACLs, quarantine state, or resource forks
# into the canonical release bundle.
ditto --norsrc --noextattr --noacl --noqtn "$STAGED_APP" "$INCOMING_APP"
xattr -cr "$INCOMING_APP"
codesign --verify --deep --strict --verbose=2 "$INCOMING_APP"

stop_running_aurora_for_install

if [[ -e "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$PREVIOUS_APP"
fi

if ! mv "$INCOMING_APP" "$FINAL_APP"; then
    [[ -e "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$FINAL_APP"
    fail "could not install the completed bundle into AURORA_PRODUCTS_DIR"
fi

if ! codesign --verify --deep --strict --verbose=2 "$FINAL_APP"; then
    rm -rf "$FINAL_APP"
    [[ -e "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$FINAL_APP"
    fail "the signature changed during the final copy"
fi

# Confirm that the destination itself is not an asynchronous metadata source.
# A FileProvider output directory usually reattaches FinderInfo within a second.
sleep 1
if ! codesign --verify --deep --strict --verbose=2 "$FINAL_APP"; then
    rm -rf "$FINAL_APP"
    [[ -e "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$FINAL_APP"
    fail "AURORA_PRODUCTS_DIR modifies signed bundles; choose a non-synced directory"
fi
rm -rf "$PREVIOUS_APP"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun stapler validate "$FINAL_APP"
    spctl --assess --type execute --verbose=4 "$FINAL_APP"
fi

# The archive is the portable artifact copied back into the synced repository.
# It is created only after stapling, so a notarized release retains its ticket.
# COPYFILE_DISABLE and zip -X prevent Finder/resource-fork AppleDouble files
# from leaking into the public download while preserving executable modes.
rm -f "$PORTABLE_ARCHIVE"
(
    cd "$PRODUCTS_DIR"
    COPYFILE_DISABLE=1 zip -q -r -X "$PORTABLE_ARCHIVE" "Aurora.app"
)
if unzip -Z1 "$PORTABLE_ARCHIVE" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    fail "the portable archive contains AppleDouble metadata"
fi

mkdir -p "$DIST_DIR"
INCOMING_ARCHIVE="$DIST_DIR/.Aurora.app.zip.incoming.$$"
PREVIOUS_ARCHIVE="$DIST_DIR/.Aurora.app.zip.previous.$$"
rm -f "$INCOMING_ARCHIVE" "$PREVIOUS_ARCHIVE"
install -m 644 "$PORTABLE_ARCHIVE" "$INCOMING_ARCHIVE"

SOURCE_SHA="$(shasum -a 256 "$PORTABLE_ARCHIVE" | awk '{print $1}')"
COPIED_SHA="$(shasum -a 256 "$INCOMING_ARCHIVE" | awk '{print $1}')"
[[ "$SOURCE_SHA" == "$COPIED_SHA" ]] || fail "the portable archive changed during the final copy"

if [[ -e "$DIST_ARCHIVE" ]]; then
    mv "$DIST_ARCHIVE" "$PREVIOUS_ARCHIVE"
fi
if ! mv "$INCOMING_ARCHIVE" "$DIST_ARCHIVE"; then
    [[ -e "$PREVIOUS_ARCHIVE" ]] && mv "$PREVIOUS_ARCHIVE" "$DIST_ARCHIVE"
    fail "could not install the portable archive into dist"
fi

# Verify the signature from the bytes that actually arrived in dist, not from
# the pre-copy staging bundle.
mkdir -p "$ARCHIVE_CHECK_ROOT"
ditto -x -k "$DIST_ARCHIVE" "$ARCHIVE_CHECK_ROOT"
xattr -cr "$ARCHIVE_CHECK_ROOT/Aurora.app"
if ! codesign --verify --deep --strict --verbose=2 "$ARCHIVE_CHECK_ROOT/Aurora.app"; then
    rm -f "$DIST_ARCHIVE"
    [[ -e "$PREVIOUS_ARCHIVE" ]] && mv "$PREVIOUS_ARCHIVE" "$DIST_ARCHIVE"
    fail "the app extracted from the final archive has an invalid signature"
fi
rm -f "$PREVIOUS_ARCHIVE"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun stapler validate "$ARCHIVE_CHECK_ROOT/Aurora.app"
    spctl --assess --type execute --verbose=4 "$ARCHIVE_CHECK_ROOT/Aurora.app"
fi

# Preserve the familiar dist/Aurora.app path for this Mac without putting the
# bundle itself under FileProvider. The ZIP, not this absolute link, is what can
# be moved to another Mac.
INCOMING_LINK="$DIST_DIR/.Aurora.app.link.$$"
rm -f "$INCOMING_LINK"
ln -s "$FINAL_APP" "$INCOMING_LINK"
rm -rf "$DIST_APP_LINK"
mv "$INCOMING_LINK" "$DIST_APP_LINK"
codesign --verify --deep --strict --verbose=2 "$DIST_APP_LINK"

# Publish an external receipt only after the exact signed executable, installed
# bundle, and portable archive have passed verification. codesign changes the
# Mach-O bytes, so the final executable hash is deliberately computed here and
# never embedded back into the bundle (which would create a signing/hash cycle).
# Installed self-tests require this receipt, so a stale app cannot validate
# itself using only metadata embedded in that same stale bundle.
FINAL_EXECUTABLE_SHA256="$(shasum -a 256 "$FINAL_APP/Contents/MacOS/Aurora" | awk '{print $1}')"
EMBEDDED_SOURCE_FINGERPRINT="$(plutil -extract AuroraSourceFingerprint raw -o - \
    "$FINAL_APP/Contents/Info.plist")"
[[ "$EMBEDDED_SOURCE_FINGERPRINT" == "$SOURCE_FINGERPRINT" ]] || \
    fail "the installed bundle reports the wrong source fingerprint"

rm -f "$INCOMING_RECEIPT"
print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' | \
    plutil -convert xml1 -o "$INCOMING_RECEIPT" -
plutil -insert app_path -string "$FINAL_APP" "$INCOMING_RECEIPT"
plutil -insert executable_sha256 -string "$FINAL_EXECUTABLE_SHA256" "$INCOMING_RECEIPT"
plutil -insert unsigned_executable_sha256 -string "$UNSIGNED_EXECUTABLE_SHA256" "$INCOMING_RECEIPT"
plutil -insert source_fingerprint -string "$SOURCE_FINGERPRINT" "$INCOMING_RECEIPT"
plutil -insert archive_sha256 -string "$COPIED_SHA" "$INCOMING_RECEIPT"
plutil -insert configuration -string "$CONFIGURATION" "$INCOMING_RECEIPT"
plutil -lint "$INCOMING_RECEIPT" >/dev/null
mv "$INCOMING_RECEIPT" "$BUILD_RECEIPT"

if [[ "$RELAUNCH_PENDING" == 1 ]]; then
    relaunch_verified_installed_aurora
    RELAUNCH_PENDING=0
fi

print -- "Aurora packaged successfully"
print -- "  Runnable app: $FINAL_APP"
print -- "  Local link: $DIST_APP_LINK"
print -- "  Portable archive: $DIST_ARCHIVE"
print -- "  Build receipt: $BUILD_RECEIPT"
print -- "  Executable SHA-256: $FINAL_EXECUTABLE_SHA256"
print -- "  Source fingerprint: $SOURCE_FINGERPRINT"
print -- "  Archive SHA-256: $COPIED_SHA"
print -- "  Configuration: $CONFIGURATION"
print -- "  Signing: $SIGNING_DESCRIPTION"
if [[ -n "$NOTARY_PROFILE" ]]; then
    print -- "  Notarization: accepted and stapled (Keychain profile: $NOTARY_PROFILE)"
else
    print -- "  Notarization: not requested"
fi
