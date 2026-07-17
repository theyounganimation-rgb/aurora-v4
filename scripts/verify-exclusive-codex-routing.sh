#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE_JSON="$(mktemp "${TMPDIR:-/private/tmp}/aurora-package.XXXXXX")"
DESCRIPTION_JSON="$(mktemp "${TMPDIR:-/private/tmp}/aurora-description.XXXXXX")"
LIVE_VIEW_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/aurora-live-source.XXXXXX")"

cleanup() {
  rm -f "$PACKAGE_JSON" "$DESCRIPTION_JSON"
  rm -rf "$LIVE_VIEW_DIR"
}
trap cleanup EXIT INT TERM HUP

fail() {
  print -u2 -- "Exclusive Codex routing verification failed: $*"
  exit 1
}

for command in swift jq rg strings; do
  command -v "$command" >/dev/null 2>&1 || fail "required command '$command' was not found"
done

cd "$ROOT"
swift package dump-package > "$PACKAGE_JSON"
swift package describe --type json > "$DESCRIPTION_JSON"

TARGET_COUNT="$(jq '[.targets[] | select(.name == "Aurora")] | length' "$PACKAGE_JSON")"
[[ "$TARGET_COUNT" == "1" ]] || fail "Package.swift must contain exactly one Aurora production target"

TARGET_PATH="$(jq -r '.targets[] | select(.name == "Aurora") | .path // empty' "$PACKAGE_JSON")"
[[ "$TARGET_PATH" == "Sources/Aurora" ]] || fail "Aurora production target moved away from Sources/Aurora"

typeset -a COMPILED_SOURCES MANIFEST_EXCLUDES
COMPILED_SOURCES=("${(@f)$(jq -r '.targets[] | select(.name == "Aurora") | .sources[]' "$DESCRIPTION_JSON")}")
MANIFEST_EXCLUDES=("${(@f)$(jq -r '.targets[] | select(.name == "Aurora") | (.exclude // [])[]' "$PACKAGE_JSON")}")

is_compiled() {
  local candidate="${1#./}"
  local source
  for source in "${COMPILED_SOURCES[@]}"; do
    [[ "${source#./}" == "$candidate" ]] && return 0
  done
  return 1
}

is_explicitly_excluded() {
  local candidate="${1#./}"
  local excluded normalized
  for excluded in "${MANIFEST_EXCLUDES[@]}"; do
    normalized="${excluded#./}"
    [[ "$candidate" == "$normalized" || "$candidate" == "$normalized/"* ]] && return 0
  done
  return 1
}

# These are the former API, native-control, and direct-application executors.
# They may remain in the repository as historical test fixtures, but SwiftPM
# must prove that none can enter Aurora's production module.
typeset -a BANNED_PRODUCTION_SOURCES
BANNED_PRODUCTION_SOURCES=(
  ComputerUse/ComputerUseClient.swift
  ComputerUse/DesktopTaskCoordinator.swift
  ComputerUse/DesktopTaskTypes.swift
  ComputerUse/InstalledComputerUseAPISelfTest.swift
  ComputerUse/InstalledComputerUseEndToEndSelfTest.swift
  ComputerUse/InstalledWallpaperClearSelfTest.swift
  ComputerUse/MacDesktopEnvironment.swift
  Infrastructure/ApprovalCenter.swift
  Research/WebResearchClient.swift
  Tools/ActionAuthorization.swift
  Tools/AppleMailService.swift
  Tools/AppleNotesService.swift
  Tools/CalendarEventService.swift
  Tools/ConnectedMailService.swift
  Tools/InstalledScreenControlSelfTest.swift
  Tools/IntentProposal.swift
  Tools/NativeCapabilityRouter.swift
  Tools/NativeDesktopControl.swift
  Tools/NativeScreenControl.swift
  Tools/NotesCapabilityBroker.swift
  Tools/ReminderService.swift
  Tools/SafeComputerAccess.swift
  Tools/TypedCapabilityAuthorization.swift
  Tools/YouTubeSearchService.swift
)

# Future files added beneath an old executor directory are retired by default,
# rather than silently joining the app because this verifier knew only today's
# filenames.
for source in ${(f)"$(find Sources/Aurora/ComputerUse Sources/Aurora/Research -type f -name '*.swift' -print 2>/dev/null | sort)"}; do
  BANNED_PRODUCTION_SOURCES+=("${source#Sources/Aurora/}")
done
BANNED_PRODUCTION_SOURCES=("${(@u)BANNED_PRODUCTION_SOURCES}")

for source in "${BANNED_PRODUCTION_SOURCES[@]}"; do
  is_compiled "$source" && fail "$source is still compiled into Aurora"
  if [[ -e "$ROOT/Sources/Aurora/$source" ]] && ! is_explicitly_excluded "$source"; then
    fail "$source remains in the repository without an explicit Package.swift exclusion"
  fi
done

typeset -a REQUIRED_PRODUCTION_SOURCES
REQUIRED_PRODUCTION_SOURCES=(
  App/AuroraApp.swift
  App/AuroraAppDelegate.swift
  App/AuroraAppModel.swift
  App/AuroraVoiceInstructions.swift
  Codex/CodexTaskRuntime.swift
  Codex/DelegateTaskAuthorization.swift
  Codex/DelegateTaskCoordinator.swift
  Codex/DelegateTaskProposal.swift
  Codex/FoundationCodexAppServerTransport.swift
  Codex/SharedCodexAppServerTransport.swift
  InnerLife/AuroraInnerLifeRuntime.swift
  Infrastructure/ContinuityDocumentStore.swift
  Memory/MemoryStore.swift
  Memory/ContinuityVoiceProjection.swift
  PrivateLife/AuroraPrivateLifeRuntime.swift
  PrivateLife/CodexReflectionBridge.swift
  Realtime/AuroraRealtimeClient.swift
  Realtime/RealtimeModels.swift
  Tools/ToolRegistry.swift
  Tools/ToolTypes.swift
  UI/AuroraContinuitySettingsView.swift
)
for source in "${REQUIRED_PRODUCTION_SOURCES[@]}"; do
  is_compiled "$source" || fail "required retained source $source is not compiled into Aurora"
done

typeset -a LIVE_BOUNDARY_FILES
LIVE_BOUNDARY_FILES=(
  Sources/Aurora/App/AuroraAppDelegate.swift
  Sources/Aurora/App/AuroraAppModel.swift
  Sources/Aurora/Realtime/AuroraRealtimeClient.swift
  Sources/Aurora/Tools/ToolRegistry.swift
)

# ToolRegistry deliberately keeps its retired implementation under a disabled
# compile condition for historical tests. Inspect the same branch SwiftPM sees
# in production, not the fixture text hidden behind AURORA_LEGACY_MOTOR.
typeset -a LIVE_BOUNDARY_VIEWS
write_production_view() {
  local source="$1"
  local destination="$2"
  awk '
    /^#if AURORA_LEGACY_MOTOR[[:space:]]*$/ { legacy = 1; include = 0; next }
    legacy && /^#else[[:space:]]*$/ { include = 1; next }
    legacy && /^#endif[[:space:]]*$/ { legacy = 0; include = 1; next }
    !legacy || include { print }
  ' "$source" > "$destination"
}

for source in "${LIVE_BOUNDARY_FILES[@]}"; do
  view="$LIVE_VIEW_DIR/${source:t}"
  write_production_view "$source" "$view"
  LIVE_BOUNDARY_VIEWS+=("$view")
done

LEGACY_IDENTIFIER_PATTERN='DesktopTask|ComputerUse|MacDesktopEnvironment|NativeCapabilityRouter|NativeDesktopAction|NativeDesktopControl|NativeScreen|SafeComputerAccess|NotesCapabilityBroker|AppleNotesService|ConnectedMailService|CalendarEvent|ReminderService|YouTubeSearch|WebResearch|IntentProposal|TypedCapabilityAuthorization|publishDesktopTaskUpdate|configureResearchAPIKey'
if rg -n "$LEGACY_IDENTIFIER_PATTERN" "${LIVE_BOUNDARY_VIEWS[@]}"; then
  fail "a live production boundary still references the retired executor stack"
fi

LEGACY_TOOL_LITERAL_PATTERN='"(intent_proposal|research|youtube_search|calendar_action|personal_action|computer_list|computer_read|computer_open|computer_action|computer_task|computer_visual|computer_run|mail)"'
if rg -n "$LEGACY_TOOL_LITERAL_PATTERN" "${LIVE_BOUNDARY_VIEWS[@]}"; then
  fail "a live production boundary still names a retired Realtime tool"
fi

if rg -n 'desktopTaskCoordinator[[:space:]]*\.[[:space:]]*configure[[:space:]]*\(|configureResearchAPIKey[[:space:]]*\(' \
    "${LIVE_BOUNDARY_VIEWS[@]}"; then
  fail "the voice API key can still be handed to a retired task or research route"
fi

# App termination is an asynchronous boundary: direct computer work must
# finish cancellation before Aurora detaches its Codex runtime, while durable
# coding/research/general work remains owned by the shared Codex service. Keep
# this proof close to the production-routing verifier so packaging cannot ship
# a regression that only appears when the user presses Command-Q.
APP_DELEGATE_SOURCE="$ROOT/Sources/Aurora/App/AuroraAppDelegate.swift"
APP_SOURCE="$ROOT/Sources/Aurora/App/AuroraApp.swift"
APP_MODEL_SOURCE="$ROOT/Sources/Aurora/App/AuroraAppModel.swift"

require_source_literal() {
  local source="$1"
  local literal="$2"
  local failure="$3"
  rg -q -F -- "$literal" "$source" || fail "$failure"
}

source_line() {
  local source="$1"
  local literal="$2"
  rg -n -F -- "$literal" "$source" | head -n 1 | cut -d: -f1
}

require_source_literal "$APP_DELEGATE_SOURCE" \
  'func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply' \
  'AuroraAppDelegate no longer owns the asynchronous application-termination boundary'
require_source_literal "$APP_DELEGATE_SOURCE" 'return .terminateLater' \
  'application termination no longer waits for model cleanup'
require_source_literal "$APP_DELEGATE_SOURCE" 'sender?.reply(toApplicationShouldTerminate: true)' \
  'application termination never releases AppKit after cleanup'
require_source_literal "$APP_DELEGATE_SOURCE" 'case .waitingForCleanup:' \
  'application termination no longer prevents duplicate cleanup tasks'
require_source_literal "$APP_SOURCE" 'appDelegate.installTerminationHandler' \
  'SwiftUI no longer installs the model-owned application-termination handler'
require_source_literal "$APP_SOURCE" 'await model?.prepareForApplicationTermination()' \
  'the installed application-termination handler no longer awaits AuroraAppModel'
require_source_literal "$APP_MODEL_SOURCE" 'private var sessionCancellationTask: Task<Void, Never>?' \
  'direct-session cancellation is no longer awaitable'
require_source_literal "$APP_MODEL_SOURCE" 'func prepareForApplicationTermination() async' \
  'AuroraAppModel no longer exposes an asynchronous termination barrier'
require_source_literal "$APP_MODEL_SOURCE" 'let committedDelegateHandoffs = durableDelegateToolCallIDs.compactMap' \
  'application termination can drop a finalized delegate before it is persisted'
require_source_literal "$APP_MODEL_SOURCE" 'await handoff.value' \
  'application termination no longer waits for finalized delegate handoffs to persist'
require_source_literal "$APP_MODEL_SOURCE" 'await directSessionCancellation?.value' \
  'application termination no longer drains direct-session cancellation'
require_source_literal "$APP_MODEL_SOURCE" 'await toolRegistry.shutdownDelegateTaskRuntime()' \
  'application termination no longer detaches the delegate runtime'
require_source_literal "$APP_MODEL_SOURCE" 'await priorCancellation?.value' \
  'successive Rest/quit cancellation requests can race each other'
require_source_literal "$APP_MODEL_SOURCE" 'preemptPrivateLifeReflectionForForeground()' \
  'foreground wake no longer preempts subscription-backed private reflection'
require_source_literal "$APP_MODEL_SOURCE" \
  '.sink { [weak self] _ in self?.rest() }' \
  'window-close no longer preserves Aurora Rest behavior'

HANDOFF_DRAIN_LINE="$(source_line "$APP_MODEL_SOURCE" 'await handoff.value')"
CANCEL_DRAIN_LINE="$(source_line "$APP_MODEL_SOURCE" 'await directSessionCancellation?.value')"
RUNTIME_SHUTDOWN_LINE="$(source_line "$APP_MODEL_SOURCE" 'await toolRegistry.shutdownDelegateTaskRuntime()')"
[[ -n "$HANDOFF_DRAIN_LINE" && -n "$CANCEL_DRAIN_LINE" && -n "$RUNTIME_SHUTDOWN_LINE" \
   && "$HANDOFF_DRAIN_LINE" -lt "$CANCEL_DRAIN_LINE" \
   && "$CANCEL_DRAIN_LINE" -lt "$RUNTIME_SHUTDOWN_LINE" ]] \
  || fail 'termination ordering no longer persists handoffs, drains direct work, then detaches the runtime'

[[ "$(rg -c -F 'shutdownDelegateTaskRuntime()' "$APP_MODEL_SOURCE")" == "1" ]] \
  || fail 'delegate runtime shutdown escaped the single model-owned termination boundary'

typeset -a LEGACY_SELF_TEST_FLAGS
LEGACY_SELF_TEST_FLAGS=(
  --screen-control-self-test
  --computer-use-api-self-test
  --computer-use-end-to-end-self-test
  --chrome-tab-control-self-test
  --youtube-live-computer-use-self-test
  --wallpaper-clear-self-test
  --textedit-write-self-test
  --media-control-self-test
  --close-tab-effect-self-test
)

for source in "${COMPILED_SOURCES[@]}"; do
  absolute="$ROOT/Sources/Aurora/$source"
  [[ -f "$absolute" ]] || fail "SwiftPM described a missing production source: $source"
  scan_source="$absolute"
  if rg -q '^#if AURORA_LEGACY_MOTOR[[:space:]]*$' "$absolute"; then
    scan_source="$LIVE_VIEW_DIR/${source//\//_}"
    write_production_view "$absolute" "$scan_source"
  fi
  if rg -n -F 'https://api.openai.com/v1/responses' "$scan_source"; then
    fail "the direct Responses API endpoint is present in compiled source $source"
  fi
  for flag in "${LEGACY_SELF_TEST_FLAGS[@]}"; do
    if rg -n -F -- "$flag" "$scan_source"; then
      fail "legacy launch flag $flag is present in compiled source $source"
    fi
  done
done

# Build the same optimized product class that packaging ships, then inspect its
# actual strings. Source exclusions are the primary proof; this catches an
# accidental generated or linked route that source inspection alone missed.
if [[ -n "${AURORA_EXCLUSIVE_ROUTING_BINARY:-}" ]]; then
  RELEASE_BINARY="${AURORA_EXCLUSIVE_ROUTING_BINARY:A}"
else
  swift build -c release
  RELEASE_BIN_DIR="$(swift build -c release --show-bin-path)"
  RELEASE_BINARY="$RELEASE_BIN_DIR/Aurora"
fi
[[ -x "$RELEASE_BINARY" ]] || fail "release Aurora executable was not found at $RELEASE_BINARY"

STRINGS_FILE="$(mktemp "${TMPDIR:-/private/tmp}/aurora-release-strings.XXXXXX")"
strings -a "$RELEASE_BINARY" > "$STRINGS_FILE"
if rg -n -F 'https://api.openai.com/v1/responses' "$STRINGS_FILE"; then
  rm -f "$STRINGS_FILE"
  fail "release executable still contains the direct Responses API endpoint"
fi
for flag in "${LEGACY_SELF_TEST_FLAGS[@]}"; do
  if rg -n -F -- "$flag" "$STRINGS_FILE"; then
    rm -f "$STRINGS_FILE"
    fail "release executable still contains legacy launch flag $flag"
  fi
done
rm -f "$STRINGS_FILE"

jq -n \
  --arg releaseBinary "$RELEASE_BINARY" \
  --argjson compiledSourceCount "${#COMPILED_SOURCES[@]}" \
  --argjson retiredSourceCount "${#BANNED_PRODUCTION_SOURCES[@]}" \
  '{
    ok: true,
    productionRoute: "Realtime delegate_task -> visible Codex app task",
    compiledSourceCount: $compiledSourceCount,
    retiredSourceCount: $retiredSourceCount,
    releaseBinary: $releaseBinary,
    checks: {
      retiredSourcesExcluded: true,
      liveReferencesRemoved: true,
      directResponsesEndpointAbsent: true,
      legacyLaunchFlagsAbsent: true,
      retainedPersonhoodSourcesCompiled: true,
      asynchronousTerminationBarrierPresent: true
    }
  }'
