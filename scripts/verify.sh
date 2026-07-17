#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PRIVATE_OUT="$ROOT/.build/aurora-private-life-verifier"
OWNER_UNDERSTANDING_OUT="$ROOT/.build/aurora-owner-understanding-verifier"
AGENCY_STATE_OUT="$ROOT/.build/aurora-agency-state-verifier"
CONVERSATION_AGENCY_OUT="$ROOT/.build/aurora-conversation-agency-verifier"
CODEX_REFLECTION_OUT="$ROOT/.build/aurora-codex-reflection-verifier"
CODEX_TASK_RUNTIME_OUT="$ROOT/.build/aurora-codex-task-runtime-verifier"
DELEGATE_TASK_OUT="$ROOT/.build/aurora-delegate-task-verifier"
DELEGATE_TRANSPORT_OUT="$ROOT/.build/aurora-delegate-transport-verifier"
PERSONHOOD_FOCUSED_OUT="$ROOT/.build/aurora-personhood-focused-verifier"
REALTIME_EXCLUSIVE_OUT="$ROOT/.build/aurora-realtime-exclusive-routing-verifier"
REALTIME_BACKGROUND_OUT="$ROOT/.build/aurora-realtime-background-task-verifier"
RETAINED_RUNTIME_OUT="$ROOT/.build/aurora-retained-personhood-runtime-verifier"
TURN_TOOL_PROVENANCE_OUT="$ROOT/.build/aurora-turn-tool-provenance-verifier"
SESSION_PARTICIPANT_PROVENANCE_OUT="$ROOT/.build/aurora-session-participant-provenance-verifier"
CONTINUITY_STORE_OUT="$ROOT/.build/aurora-continuity-store-verifier"
COMPANION_OUT="$ROOT/.build/aurora-companion-verifier"
COMPANION_SERVER_OUT="$ROOT/.build/aurora-companion-server-verifier"
VERIFIED_SOURCE_STAMP="$ROOT/.build/aurora-verified-source-fingerprint"

cd "$ROOT"
swift build
"$ROOT/scripts/verify-reconnect-agency-boundary.sh"
"$ROOT/scripts/verify-exclusive-codex-routing.sh"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/Infrastructure/AuroraPaths.swift \
  Sources/Aurora/Infrastructure/ContinuityDocumentStore.swift \
  Sources/Aurora/Memory/MemoryStore.swift \
  Sources/Aurora/Memory/ContinuityVoiceProjection.swift \
  scripts/verify-continuity-document-store.swift \
  -o "$CONTINUITY_STORE_OUT"
"$CONTINUITY_STORE_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/Companion/AuroraCompanionProtocol.swift \
  scripts/verify-companion.swift \
  -framework Security \
  -o "$COMPANION_OUT"
"$COMPANION_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Companion/AuroraCompanionProtocol.swift \
  Sources/Aurora/Companion/AuroraCompanionPairingStore.swift \
  Sources/Aurora/Companion/AuroraCompanionServer.swift \
  Sources/Aurora/Audio/AuroraRoutableAudio.swift \
  scripts/verify-companion-server.swift \
  -framework Network \
  -framework Security \
  -o "$COMPANION_SERVER_OUT"
# Public source intentionally has no private peer allow-list. Supply an
# isolated verifier-only peer so the trusted PROXY-header path remains covered.
AURORA_COMPANION_ALLOWED_PEERS="192.0.2.10,2001:db8::10" \
  "$COMPANION_SERVER_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift \
  Sources/Aurora/InnerLife/InnerLifeModels.swift \
  Sources/Aurora/PrivateLife/PrivateLifeModels.swift \
  Sources/Aurora/PrivateLife/PrivateLifeEngine.swift \
  Sources/Aurora/PrivateLife/PrivateLifeStore.swift \
  Sources/Aurora/PrivateLife/AuroraPrivateLifeRuntime.swift \
  Sources/Aurora/PrivateLife/CodexReflectionBridge.swift \
  Sources/Aurora/PrivateLife/PrivateLifeReflectionAdapter.swift \
  Sources/Aurora/Infrastructure/AuroraPaths.swift \
  Sources/Aurora/Infrastructure/EventJournal.swift \
  Sources/Aurora/Memory/MemoryStore.swift \
  Sources/Aurora/PrivateLife/AuroraPrivateLifeReflectionCoordinator.swift \
  scripts/verify-private-life.swift \
  -framework Security \
  -o "$PRIVATE_OUT"
"$PRIVATE_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Understanding/OwnerUnderstandingModels.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingEngine.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingStore.swift \
  Sources/Aurora/Understanding/AuroraOwnerUnderstandingRuntime.swift \
  scripts/verify-owner-understanding.swift \
  -o "$OWNER_UNDERSTANDING_OUT"
"$OWNER_UNDERSTANDING_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Agency/AgencyEngine.swift \
  Sources/Aurora/Agency/AgencyStore.swift \
  Sources/Aurora/Agency/AuroraAgencyRuntime.swift \
  scripts/verify-agency-state.swift \
  -o "$AGENCY_STATE_OUT"
"$AGENCY_STATE_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Agency/AgencyEngine.swift \
  Sources/Aurora/Agency/AgencyStore.swift \
  Sources/Aurora/Agency/AuroraAgencyRuntime.swift \
  Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift \
  Sources/Aurora/InnerLife/InnerLifeModels.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingModels.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingEngine.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingStore.swift \
  Sources/Aurora/Understanding/AuroraOwnerUnderstandingRuntime.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingToolAdapter.swift \
  Sources/Aurora/Codex/DelegateTaskProposal.swift \
  Sources/Aurora/Tools/ToolAuditJournal.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  Sources/Aurora/Tools/ConversationMoveAdapter.swift \
  scripts/verify-conversation-agency.swift \
  -o "$CONVERSATION_AGENCY_OUT"
"$CONVERSATION_AGENCY_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/PrivateLife/PrivateLifeModels.swift \
  Sources/Aurora/App/ToolAddressedInputProvenance.swift \
  scripts/verify-turn-tool-provenance.swift \
  -o "$TURN_TOOL_PROVENANCE_OUT"
"$TURN_TOOL_PROVENANCE_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Realtime/RealtimeInputCommitEvidence.swift \
  Sources/Aurora/App/SessionParticipantTracker.swift \
  Sources/Aurora/App/SessionParticipantProvenance.swift \
  scripts/verify-session-participant-provenance.swift \
  -o "$SESSION_PARTICIPANT_PROVENANCE_OUT"
"$SESSION_PARTICIPANT_PROVENANCE_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/PrivateLife/PrivateLifeModels.swift \
  Sources/Aurora/PrivateLife/CodexReflectionBridge.swift \
  scripts/verify-codex-reflection.swift \
  -framework Security \
  -o "$CODEX_REFLECTION_OUT"
"$CODEX_REFLECTION_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/Codex/CodexTaskReconciliation.swift \
  Sources/Aurora/Codex/CodexTaskRuntime.swift \
  Sources/Aurora/Codex/FoundationCodexAppServerTransport.swift \
  Sources/Aurora/Codex/SharedCodexAppServerTransport.swift \
  scripts/verify-codex-task-runtime.swift \
  -o "$CODEX_TASK_RUNTIME_OUT"
if [[ "${AURORA_VERIFY_LIVE_CODEX_ACCOUNT:-1}" == "1" ]]; then
  AURORA_VERIFY_LIVE_CODEX_ACCOUNT=1 "$CODEX_TASK_RUNTIME_OUT"
else
  "$CODEX_TASK_RUNTIME_OUT"
fi
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  Sources/Aurora/Codex/CodexTaskReconciliation.swift \
  Sources/Aurora/Codex/DelegateTaskProposal.swift \
  Sources/Aurora/Codex/DelegateTaskAuthorization.swift \
  Sources/Aurora/Codex/DelegateTaskStore.swift \
  Sources/Aurora/Codex/DelegateTaskLegacyRecovery.swift \
  Sources/Aurora/Codex/DelegateTaskCoordinator.swift \
  Sources/Aurora/App/DelegateTaskVoiceDeliveryClass.swift \
  Sources/Aurora/App/DelegateTaskVoiceDeliveryPolicy.swift \
  scripts/verify-delegate-task.swift \
  -o "$DELEGATE_TASK_OUT"
"$DELEGATE_TASK_OUT"
swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  Sources/Aurora/App/DelegateTaskTransportPolicy.swift \
  scripts/verify-delegate-transport.swift \
  -o "$DELEGATE_TRANSPORT_OUT"
"$DELEGATE_TRANSPORT_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift \
  Sources/Aurora/InnerLife/InnerLifeModels.swift \
  Sources/Aurora/InnerLife/InnerLifeEngine.swift \
  Sources/Aurora/PrivateLife/PrivateLifeModels.swift \
  Sources/Aurora/PrivateLife/PrivateLifeEngine.swift \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Agency/AgencyEngine.swift \
  Sources/Aurora/Memory/MemoryStore.swift \
  Sources/Aurora/Infrastructure/AuroraPaths.swift \
  Sources/Aurora/Infrastructure/EventJournal.swift \
  Sources/Aurora/App/AuroraVoiceInstructions.swift \
  scripts/verify-personhood-focused.swift \
  -o "$PERSONHOOD_FOCUSED_OUT"
"$PERSONHOOD_FOCUSED_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/App/AuroraPhase.swift \
  Sources/Aurora/App/DelegateTaskVoiceDeliveryClass.swift \
  Sources/Aurora/Audio/AuroraAudioEngine.swift \
  Sources/Aurora/Realtime/AuroraRealtimeClient.swift \
  Sources/Aurora/Realtime/RealtimeInputCommitEvidence.swift \
  Sources/Aurora/Realtime/RealtimeModels.swift \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Codex/DelegateTaskProposal.swift \
  Sources/Aurora/Tools/ToolAuditJournal.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  scripts/verify-realtime-exclusive-routing.swift \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework Security \
  -framework Speech \
  -o "$REALTIME_EXCLUSIVE_OUT"
"$REALTIME_EXCLUSIVE_OUT"
swiftc \
  -swift-version 5 \
  -D REALTIME_FOCUSED \
  -parse-as-library \
  Sources/Aurora/App/AuroraPhase.swift \
  Sources/Aurora/App/DelegateTaskVoiceDeliveryClass.swift \
  Sources/Aurora/Audio/AuroraAudioEngine.swift \
  Sources/Aurora/Realtime/AuroraRealtimeClient.swift \
  Sources/Aurora/Realtime/RealtimeInputCommitEvidence.swift \
  Sources/Aurora/Realtime/RealtimeModels.swift \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Codex/DelegateTaskProposal.swift \
  Sources/Aurora/Tools/ToolAuditJournal.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  Sources/Aurora/Tools/NativeCapabilityRouter.swift \
  scripts/verify-realtime.swift \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework Security \
  -framework Speech \
  -o "$REALTIME_BACKGROUND_OUT"
AURORA_VERIFY_INPUT_COMMIT_EVIDENCE_ONLY=1 "$REALTIME_BACKGROUND_OUT"
AURORA_VERIFY_BACKGROUND_TASK_ONLY=1 "$REALTIME_BACKGROUND_OUT"
AURORA_VERIFY_CAUSAL_CONTINUATIONS_ONLY=1 "$REALTIME_BACKGROUND_OUT"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift \
  Sources/Aurora/InnerLife/InnerLifeModels.swift \
  Sources/Aurora/InnerLife/InnerLifeEngine.swift \
  Sources/Aurora/InnerLife/InnerLifeStore.swift \
  Sources/Aurora/InnerLife/ExternalOwnerContactBridge.swift \
  Sources/Aurora/InnerLife/AuroraInnerLifeRuntime.swift \
  Sources/Aurora/PrivateLife/PrivateLifeModels.swift \
  Sources/Aurora/PrivateLife/PrivateLifeEngine.swift \
  Sources/Aurora/PrivateLife/CodexReflectionBridge.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingModels.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingEngine.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingStore.swift \
  Sources/Aurora/Understanding/AuroraOwnerUnderstandingRuntime.swift \
  Sources/Aurora/Understanding/OwnerUnderstandingToolAdapter.swift \
  Sources/Aurora/Memory/MemoryStore.swift \
  Sources/Aurora/Infrastructure/AuroraPaths.swift \
  Sources/Aurora/Infrastructure/ContinuityDocumentStore.swift \
  Sources/Aurora/Infrastructure/NativeContinuityBootstrap.swift \
  Sources/Aurora/Infrastructure/EventJournal.swift \
  Sources/Aurora/Agency/AgencyModels.swift \
  Sources/Aurora/Agency/AgencyEngine.swift \
  Sources/Aurora/App/AuroraVoiceInstructions.swift \
  Sources/Aurora/Tools/ToolTypes.swift \
  Sources/Aurora/Tools/ToolAuditJournal.swift \
  Sources/Aurora/Codex/CodexTaskReconciliation.swift \
  Sources/Aurora/Codex/CodexTaskRuntime.swift \
  Sources/Aurora/Codex/FoundationCodexAppServerTransport.swift \
  Sources/Aurora/Codex/SharedCodexAppServerTransport.swift \
  Sources/Aurora/Codex/DelegateTaskProposal.swift \
  Sources/Aurora/Codex/DelegateTaskAuthorization.swift \
  Sources/Aurora/Codex/DelegateTaskStore.swift \
  Sources/Aurora/Codex/DelegateTaskLegacyRecovery.swift \
  Sources/Aurora/Codex/DelegateTaskCoordinator.swift \
  Sources/Aurora/Tools/ToolRegistry.swift \
  scripts/verify-inner-life.swift \
  scripts/verify-personhood.swift \
  scripts/verify-retained-personhood-runtime.swift \
  -framework Security \
  -o "$RETAINED_RUNTIME_OUT"
AURORA_VERIFY_CONTINUATION_POLICY_ONLY=1 "$RETAINED_RUNTIME_OUT"
"$RETAINED_RUNTIME_OUT"

# A release is allowed to package only this exact verified source graph. The
# stamp is private, local build state and is replaced atomically only after
# every verifier above exits successfully.
VERIFIED_FINGERPRINT="$(zsh "$ROOT/scripts/source-fingerprint.sh" "$ROOT")"
STAMP_TMP="$VERIFIED_SOURCE_STAMP.tmp.$$"
umask 077
print -r -- "$VERIFIED_FINGERPRINT" > "$STAMP_TMP"
mv "$STAMP_TMP" "$VERIFIED_SOURCE_STAMP"
