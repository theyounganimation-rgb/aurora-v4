#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Sources/Aurora/App/AuroraAppModel.swift"

typeset -a REGEX_SEARCH
if command -v rg >/dev/null 2>&1; then
  REGEX_SEARCH=(rg)
else
  REGEX_SEARCH=(grep -E)
fi

schedule_start=$("${REGEX_SEARCH[@]}" -n '^[[:space:]]*private func scheduleReconnect\(after error: Error\)' "$SOURCE" | cut -d: -f1)
schedule_end=$("${REGEX_SEARCH[@]}" -n '^[[:space:]]*private func scheduleSessionRefresh\(' "$SOURCE" | cut -d: -f1)
reconnect_interrupt=$(awk -v start="$schedule_start" -v end="$schedule_end" '
  NR > start && NR < end && /interruptPendingAgencyMoves\(reason: "reconnect"\)/ { print NR; exit }
' "$SOURCE")
reconnect_stop=$(awk -v start="$schedule_start" -v end="$schedule_end" '
  NR > start && NR < end && /realtime\.stop\(\)/ { print NR; exit }
' "$SOURCE")

clear_start=$("${REGEX_SEARCH[@]}" -n '^[[:space:]]*private func clearPerConnectionTurnState\(\)' "$SOURCE" | cut -d: -f1)
clear_end=$(awk -v start="$clear_start" '
  NR > start && /^[[:space:]]*private func / { print NR; exit }
' "$SOURCE")
clear_mapping=$(awk -v start="$clear_start" -v end="$clear_end" '
  NR > start && NR < end && /agencyPlanningResponseByInputItem\.removeAll\(\)/ { print NR; exit }
' "$SOURCE")

if [[ -z "$reconnect_interrupt" || -z "$reconnect_stop" || "$reconnect_interrupt" -ge "$reconnect_stop" ]]; then
  print -u2 "Reconnect can replace the voice transport before pending agency playback is interrupted."
  exit 1
fi

if [[ -z "$clear_mapping" ]]; then
  print -u2 "Per-connection cleanup retains stale agency planning-response mappings."
  exit 1
fi

print '{"ok":true,"checks":{"reconnectInterruptsAgencyBeforeTransportReplacement":true,"connectionCleanupClearsAgencyMappings":true}}'
