# July 15 working baseline → Build Week production diff

The working computer-control baseline was frozen on July 15, 2026 before the
new personhood pass. Its source archive has SHA-256:

```text
7da4467a059a7254df735896c2296c5eff15166b0519524d26bac0042eb0bbd0
```

The archive itself remains private because that historical snapshot contains
developer-machine identifiers. Its sanitized manifest and source fingerprint
are in [the baseline record](2026-07-15-working-computer-control.md). A
`git diff --no-index --no-renames --numstat` comparison against the current
production `Sources/` tree yields **15,135 insertions, 507 deletions, and 56
changed files**:

| Added | Deleted | Production file |
| ---: | ---: | --- |
| 1324 | 0 | `Sources/Aurora/Agency/AgencyEngine.swift` |
| 481 | 0 | `Sources/Aurora/Agency/AgencyModels.swift` |
| 330 | 0 | `Sources/Aurora/Agency/AgencyStore.swift` |
| 514 | 0 | `Sources/Aurora/Agency/AuroraAgencyRuntime.swift` |
| 16 | 0 | `Sources/Aurora/App/AuroraApp.swift` |
| 1338 | 82 | `Sources/Aurora/App/AuroraAppModel.swift` |
| 112 | 74 | `Sources/Aurora/App/AuroraVoiceInstructions.swift` |
| 25 | 3 | `Sources/Aurora/App/DelegateTaskVoiceDeliveryPolicy.swift` |
| 140 | 0 | `Sources/Aurora/App/SessionParticipantProvenance.swift` |
| 34 | 0 | `Sources/Aurora/App/SessionParticipantTracker.swift` |
| 57 | 0 | `Sources/Aurora/App/ToolAddressedInputProvenance.swift` |
| 1 | 1 | `Sources/Aurora/Audio/AuroraAudioEngine.swift` |
| 261 | 0 | `Sources/Aurora/Audio/AuroraRoutableAudio.swift` |
| 37 | 1 | `Sources/Aurora/Codex/CodexTaskReconciliation.swift` |
| 397 | 5 | `Sources/Aurora/Codex/CodexTaskRuntime.swift` |
| 15 | 1 | `Sources/Aurora/Codex/DelegateTaskAuthorization.swift` |
| 1069 | 81 | `Sources/Aurora/Codex/DelegateTaskCoordinator.swift` |
| 0 | 2 | `Sources/Aurora/Codex/DelegateTaskLegacyRecovery.swift` |
| 11 | 0 | `Sources/Aurora/Codex/DelegateTaskProposal.swift` |
| 39 | 0 | `Sources/Aurora/Codex/DelegateTaskStore.swift` |
| 79 | 0 | `Sources/Aurora/Companion/AuroraCompanionPairingStore.swift` |
| 287 | 0 | `Sources/Aurora/Companion/AuroraCompanionProtocol.swift` |
| 873 | 0 | `Sources/Aurora/Companion/AuroraCompanionServer.swift` |
| 1 | 1 | `Sources/Aurora/ComputerUse/DesktopTaskCoordinator.swift` |
| 696 | 0 | `Sources/Aurora/Infrastructure/ContinuityDocumentStore.swift` |
| 1 | 1 | `Sources/Aurora/Infrastructure/KeychainVoiceKey.swift` |
| 94 | 11 | `Sources/Aurora/InnerLife/InnerLifeEngine.swift` |
| 1 | 1 | `Sources/Aurora/InnerLife/InnerLifeModels.swift` |
| 2 | 2 | `Sources/Aurora/InnerLife/InnerLifeRelationshipModels.swift` |
| 136 | 0 | `Sources/Aurora/Memory/ContinuityVoiceProjection.swift` |
| 1 | 1 | `Sources/Aurora/Memory/MemoryStore.swift` |
| 62 | 1 | `Sources/Aurora/PrivateLife/AuroraPrivateLifeReflectionCoordinator.swift` |
| 218 | 6 | `Sources/Aurora/PrivateLife/AuroraPrivateLifeRuntime.swift` |
| 238 | 26 | `Sources/Aurora/PrivateLife/CodexReflectionBridge.swift` |
| 588 | 101 | `Sources/Aurora/PrivateLife/PrivateLifeEngine.swift` |
| 188 | 10 | `Sources/Aurora/PrivateLife/PrivateLifeModels.swift` |
| 33 | 20 | `Sources/Aurora/PrivateLife/PrivateLifeReflectionAdapter.swift` |
| 17 | 4 | `Sources/Aurora/PrivateLife/PrivateLifeStore.swift` |
| 822 | 43 | `Sources/Aurora/Realtime/AuroraRealtimeClient.swift` |
| 24 | 0 | `Sources/Aurora/Realtime/RealtimeInputCommitEvidence.swift` |
| 18 | 3 | `Sources/Aurora/Realtime/RealtimeModels.swift` |
| 1 | 1 | `Sources/Aurora/Research/WebResearchClient.swift` |
| 1 | 1 | `Sources/Aurora/Tools/ConnectedMailService.swift` |
| 392 | 0 | `Sources/Aurora/Tools/ConversationMoveAdapter.swift` |
| 1 | 1 | `Sources/Aurora/Tools/InstalledScreenControlSelfTest.swift` |
| 2 | 2 | `Sources/Aurora/Tools/NativeCapabilityRouter.swift` |
| 4 | 4 | `Sources/Aurora/Tools/NativeScreenControl.swift` |
| 1087 | 12 | `Sources/Aurora/Tools/ToolRegistry.swift` |
| 112 | 5 | `Sources/Aurora/Tools/ToolTypes.swift` |
| 420 | 0 | `Sources/Aurora/UI/AuroraContinuitySettingsView.swift` |
| 141 | 0 | `Sources/Aurora/UI/AuroraHomeView.swift` |
| 263 | 0 | `Sources/Aurora/Understanding/AuroraOwnerUnderstandingRuntime.swift` |
| 1286 | 0 | `Sources/Aurora/Understanding/OwnerUnderstandingEngine.swift` |
| 416 | 0 | `Sources/Aurora/Understanding/OwnerUnderstandingModels.swift` |
| 326 | 0 | `Sources/Aurora/Understanding/OwnerUnderstandingStore.swift` |
| 103 | 0 | `Sources/Aurora/Understanding/OwnerUnderstandingToolAdapter.swift` |

This table is eligibility evidence, not a claim that every line has equal
importance. The feature-level mapping and verification references are in
[the Build Week record](../BUILD_WEEK.md).
