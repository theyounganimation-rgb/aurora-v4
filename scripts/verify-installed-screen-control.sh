#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
if [[ $# -lt 1 ]]
then
  print -u2 -- "usage: verify-installed-screen-control.sh /absolute/path/Aurora.app [close-tab|screen-control|media|textedit|computer-use-api|computer-use-e2e] [build-receipt.plist]"
  exit 64
fi

APP="${1:A}"
MODE="${2:-close-tab}"
RECEIPT_INPUT="${3:-${AURORA_BUILD_RECEIPT:-${APP:h}/Aurora.build-receipt.plist}}"
RECEIPT="${RECEIPT_INPUT:A}"
EXECUTABLE="$APP/Contents/MacOS/Aurora"
INFO_PLIST="$APP/Contents/Info.plist"
REPORT="$(mktemp "${TMPDIR:-/private/tmp}/aurora-installed-control-report.XXXXXX")"

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && -s "$REPORT" ]]
  then
    print -u2 -- "Installed self-test report:"
    cat "$REPORT" >&2
  fi
  rm -f "$REPORT"
  return $exit_code
}
trap cleanup EXIT

[[ "$APP" == /* && -d "$APP" ]] || {
  print -u2 -- "Aurora app must be an existing absolute bundle path"
  exit 66
}
[[ -x "$EXECUTABLE" && -f "$INFO_PLIST" ]] || {
  print -u2 -- "Aurora bundle is missing its executable or Info.plist"
  exit 66
}
[[ -f "$RECEIPT" ]] || {
  print -u2 -- "build receipt is missing: $RECEIPT"
  exit 66
}
case "$MODE" in
  close-tab) SELF_TEST_FLAG="--close-tab-effect-self-test" ;;
  screen-control) SELF_TEST_FLAG="--screen-control-self-test" ;;
  media) SELF_TEST_FLAG="--media-control-self-test" ;;
  textedit) SELF_TEST_FLAG="--textedit-write-self-test" ;;
  computer-use-api) SELF_TEST_FLAG="--computer-use-api-self-test" ;;
  computer-use-e2e) SELF_TEST_FLAG="--computer-use-end-to-end-self-test" ;;
  *)
    print -u2 -- "unsupported installed self-test mode: $MODE"
    exit 64
    ;;
esac

codesign --verify --deep --strict "$APP"
RECEIPT_APP="$(plutil -extract app_path raw -o - "$RECEIPT")"
RECEIPT_EXECUTABLE_SHA256="$(plutil -extract executable_sha256 raw -o - "$RECEIPT")"
RECEIPT_SOURCE_FINGERPRINT="$(plutil -extract source_fingerprint raw -o - "$RECEIPT")"
CURRENT_EXECUTABLE_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
EMBEDDED_SOURCE_FINGERPRINT="$(plutil -extract AuroraSourceFingerprint raw -o - "$INFO_PLIST")"
CURRENT_SOURCE_FINGERPRINT="$(zsh "$ROOT/scripts/source-fingerprint.sh" "$ROOT")"

[[ "${RECEIPT_APP:A}" == "$APP" ]] || {
  print -u2 -- "build receipt belongs to a different app: $RECEIPT_APP"
  exit 65
}
[[ "$RECEIPT_EXECUTABLE_SHA256" == "$CURRENT_EXECUTABLE_SHA256" ]] || {
  print -u2 -- "installed executable does not match this build receipt"
  exit 65
}
[[ "$RECEIPT_SOURCE_FINGERPRINT" == "$EMBEDDED_SOURCE_FINGERPRINT" ]] || {
  print -u2 -- "installed source fingerprint does not match this build receipt"
  exit 65
}
[[ "$RECEIPT_SOURCE_FINGERPRINT" == "$CURRENT_SOURCE_FINGERPRINT" ]] || {
  print -u2 -- "installed bundle was not built from the current source tree"
  exit 65
}

# Run the exact executable named by the receipt. This intentionally does not
# quit or relaunch the configured owner's normal Aurora process. The close-tab mode creates and
# controls only its own disposable Chrome process/profile. Start the test app
# with an explicit allowlist so API keys, agent permissions, and development
# shell state cannot enter Aurora or the fixture processes it launches.
SELF_TEST_USER="${USER:-$(/usr/bin/id -un)}"
/usr/bin/env -i \
  HOME="$HOME" \
  USER="$SELF_TEST_USER" \
  LOGNAME="$SELF_TEST_USER" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="${TMPDIR:-/private/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" \
  AURORA_EXPECTED_EXECUTABLE_SHA256="$CURRENT_EXECUTABLE_SHA256" \
  AURORA_EXPECTED_SOURCE_FINGERPRINT="$CURRENT_SOURCE_FINGERPRINT" \
  "$EXECUTABLE" "$SELF_TEST_FLAG" > "$REPORT"

case "$MODE" in
close-tab)
  REPORTED_EXECUTABLE="$(jq -r '.installedExecutable // empty' "$REPORT")"
  [[ -n "$REPORTED_EXECUTABLE" && "${REPORTED_EXECUTABLE:A}" == "${EXECUTABLE:A}" ]] || {
    print -u2 -- "self-test ran from a different executable path"
    exit 65
  }
  jq -e \
    --arg executable_sha "$CURRENT_EXECUTABLE_SHA256" \
    --arg source_fingerprint "$CURRENT_SOURCE_FINGERPRINT" '
      .ok == true
      and .executableSHA256 == $executable_sha
      and .sourceFingerprint == $source_fingerprint
      and .fixtureProfileIsolated == true
      and .preconditionTabCount == 2
      and .postconditionTabCount == 1
      and .closeTargetRemoved == true
      and .keepTargetPreserved == true
      and .toolReportedSuccess == true
      and .toolReportedEffectVerified == true
    ' "$REPORT" >/dev/null
  ;;
screen-control)
  jq -e '
    .ok == true
    and .screenCaptureAllowed == true
    and .accessibilityAllowed == true
    and .pointerControlAllowed == true
    and ([.cases[] | .passed] | all)
    and ([.cases[] | select(.name != "current_youtube_selection" and .name != "direct_minimize_everything") | (.clickMethod == "core_graphics_pointer" or .clickMethod == "accessibility_press" or .clickMethod == "accessibility_resolved_pointer")] | all)
    and ([.cases[] | select(.name == "direct_minimize_everything") | .clickMethod == "native_desktop_action"] | all)
    and ([.cases[] | select(.name == "youtube_semantic_title") | .clickMethod == "accessibility_resolved_pointer"] | all)
    and ([.cases[] | select(.name == "current_youtube_selection") | .clickMethod == "selection_only"] | all)
  ' "$REPORT" >/dev/null
  ;;
media)
  jq -e '
    .ok == true
    and .fixtureProfileIsolated == true
    and .resumeVerified == true
    and .pauseVerified == true
    and .desktopTaskStarted == false
    and .durationMilliseconds < 4000
    and .failure == null
  ' "$REPORT" >/dev/null
  ;;
textedit)
  jq -e '
    .ok == true
    and .effectVerified == true
    and .desktopTaskStarted == false
    and .durationMilliseconds < 3000
    and .failure == null
  ' "$REPORT" >/dev/null
  ;;
computer-use-api)
  jq -e '
    .ok == true
    and .model == "gpt-5.6"
    and .receivedComputerCall == true
    and .actionTypes == ["screenshot"]
    and .failure == null
  ' "$REPORT" >/dev/null
  ;;
computer-use-e2e)
  jq -e '
    .ok == true
    and .status == "completed"
    and .steps > 0
    and .visibleEffectObserved == true
    and .failure == null
  ' "$REPORT" >/dev/null
  ;;
esac

jq \
  --arg app "$APP" \
  --arg receipt "$RECEIPT" \
  --arg executable_sha256 "$CURRENT_EXECUTABLE_SHA256" \
  --arg source_fingerprint "$CURRENT_SOURCE_FINGERPRINT" \
  --arg mode "$MODE" '{
    verifiedApp: $app,
    buildReceipt: $receipt,
    executableSHA256: $executable_sha256,
    sourceFingerprint: $source_fingerprint,
    mode: $mode,
    selfTest: .
  }' "$REPORT"
