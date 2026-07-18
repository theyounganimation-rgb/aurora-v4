#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

# GitHub runners have no signed-in ChatGPT account, paired companion, audio
# device, or interactive desktop. The shared verifier already uses in-process
# fakes for every runtime boundary; this switch skips only the signed Codex
# account handshake while retaining the complete deterministic source suite.
export AURORA_VERIFY_LIVE_CODEX_ACCOUNT=0

"$ROOT/scripts/verify-public-release.sh"
"$ROOT/scripts/verify-public-release-regressions.sh"

exec "$ROOT/scripts/verify.sh"
