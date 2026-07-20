#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="${TMPDIR:-/tmp}/aurora-live-codex-app-bridge-verifier"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  "$ROOT/Sources/Aurora/Codex/CodexTaskReconciliation.swift" \
  "$ROOT/Sources/Aurora/Codex/CodexTaskRuntime.swift" \
  "$ROOT/Sources/Aurora/Codex/FoundationCodexAppServerTransport.swift" \
  "$ROOT/Sources/Aurora/Codex/SharedCodexAppServerTransport.swift" \
  "$ROOT/scripts/verify-live-codex-app-bridge.swift" \
  -framework Security \
  -o "$OUT"

# The verifier itself requires the same opt-in. It creates one read-only,
# no-external-effect Codex turn, verifies visibility/recovery, and archives it.
AURORA_VERIFY_LIVE_CODEX_APP_BRIDGE=1 "$OUT"
