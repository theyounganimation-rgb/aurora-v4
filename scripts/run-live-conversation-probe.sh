#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="${TMPDIR:-/tmp}/aurora-live-conversation-probe"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  "$ROOT/Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift" \
  "$ROOT/Sources/Aurora/InnerLife/InnerLifeModels.swift" \
  "$ROOT/Sources/Aurora/InnerLife/InnerLifeEngine.swift" \
  "$ROOT/Sources/Aurora/InnerLife/InnerLifeStore.swift" \
  "$ROOT/Sources/Aurora/PrivateLife/PrivateLifeModels.swift" \
  "$ROOT/Sources/Aurora/PrivateLife/PrivateLifeEngine.swift" \
  "$ROOT/Sources/Aurora/PrivateLife/PrivateLifeStore.swift" \
  "$ROOT/Sources/Aurora/Understanding/OwnerUnderstandingModels.swift" \
  "$ROOT/Sources/Aurora/Understanding/OwnerUnderstandingEngine.swift" \
  "$ROOT/Sources/Aurora/Understanding/OwnerUnderstandingStore.swift" \
  "$ROOT/Sources/Aurora/Agency/AgencyModels.swift" \
  "$ROOT/Sources/Aurora/Agency/AgencyEngine.swift" \
  "$ROOT/Sources/Aurora/Agency/AgencyStore.swift" \
  "$ROOT/Sources/Aurora/Memory/MemoryStore.swift" \
  "$ROOT/Sources/Aurora/Infrastructure/AuroraPaths.swift" \
  "$ROOT/Sources/Aurora/Infrastructure/KeychainVoiceKey.swift" \
  "$ROOT/Sources/Aurora/App/AuroraVoiceInstructions.swift" \
  "$ROOT/scripts/probe-live-conversation.swift" \
  -framework Security \
  -o "$OUT"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
SIGNING_IDENTITY="$(print -r -- "$IDENTITIES" | awk -F '"' '
  /"Apple Development:/ && selected == "" { selected = $2 }
  END { print selected }
')"
[[ -n "$SIGNING_IDENTITY" ]] || {
  print -u2 -- "Aurora live conversation probe: no Apple Development identity is available."
  exit 1
}
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --identifier ai.aurora.voice \
  "$OUT" >/dev/null

# The probe has Aurora's stable identifier and signing requirement, then reads
# the existing Keychain item through the same read-only code path as the app.
# The key never enters argv, the environment, a file, or probe output.
"$OUT"
