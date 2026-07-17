import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

/// Converts tool receipts into the narrow facts Aurora may carry across a
/// superseded voice turn or learn as a completed action. `ok` describes the
/// tool call's result; only explicit receipt metadata proves an external effect.
enum AuroraToolEffectTruth {
    struct CompletionLearning: Equatable {
        let succeeded: Bool
    }

    static func shouldPreserveAfterTurn(_ result: ToolExecutionResult) -> Bool {
        guard result.metadata["duplicate_suppressed"]?.boolValue != true else {
            return false
        }
        return result.metadata["external_side_effect"]?.boolValue == true
    }

    static func completionLearning(
        toolName: String,
        result: ToolExecutionResult
    ) -> CompletionLearning? {
        guard toolName != "owner_understanding_update",
              toolName != "conversation_move" else { return nil }
        guard result.metadata["duplicate_suppressed"]?.boolValue != true,
              result.metadata["silence_rejected"]?.boolValue != true else {
            return nil
        }
        if toolName == "delegate_task",
           result.ok,
           result.metadata["effect_verified"]?.boolValue != true {
            // Dispatch, provider completion, or a posted pointer event is not
            // the same as a verified requested outcome. Keep it conversational
            // without teaching Aurora that the Mac definitely changed.
            return nil
        }
        return CompletionLearning(succeeded: result.ok)
    }

}

@MainActor
final class AuroraAppModel: ObservableObject {
    @Published private(set) var phase: AuroraPhase = .resting
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var outputLevel: Double = 0
    @Published private(set) var ownerDisplayName: String = ""
    @Published private(set) var onboardingMode: AuroraOnboardingMode?
    @Published private(set) var onboardingError: String?
    @Published private(set) var restingWakeDetail: String?
    @Published private(set) var companionPairingCode: String = ""
    @Published private(set) var companionStatus: String =
        "Private companion prototype excluded from this public release"

    private enum TurnOutcome {
        case spoken(itemID: String, text: String)
        case interrupted(itemID: String)
        case addressedModel
        case addressedTool
        case quiet
        case unresolved
    }

    private enum WakeTrigger: Equatable {
        case manual
        case localWakePhrase
        case remoteCompanion
    }

    private enum CompanionSessionOwner: String {
        case none
        case mac
        case iphone
    }

    private struct PendingAutomaticRest {
        let inputItemID: String
        let intent: ConversationClosingIntent
        let connectionID: UUID
        let lifecycleID: UUID
    }

    private struct PendingParticipantReplay {
        let transcript: String
        let participant: AuroraSessionParticipant
        let originalInputItemID: String
    }

    private let realtime: AuroraRealtimeClient
    private let audioRouter: AuroraRoutableAudio
    private let companionServer: AuroraCompanionServer
    private let memoryStore: MemoryStore
    let continuityDocumentStore: ContinuityDocumentStore
    private let toolRegistry: ToolRegistry
    private let eventJournal: EventJournal
    private let innerLife: AuroraInnerLifeRuntime
    private let privateLife: AuroraPrivateLifeRuntime
    private let privateLifeReflectionCoordinator: AuroraPrivateLifeReflectionCoordinator
    private let ownerUnderstanding: AuroraOwnerUnderstandingRuntime
    private let agency: AuroraAgencyRuntime
    private let voiceKeyCache: VoiceKeySessionCache
    private let ownerProfileStore: OwnerProfileStore
    private let wakeWordListener: AuroraWakeWordListener

    private var wantsAwake = false
    private var companionSessionOwner: CompanionSessionOwner = .none
    private var lifecycleID = UUID()
    private var activeConnectionID: UUID?
    private var localSessionID: String?
    /// Maps short-lived Realtime transports to the one logical awake owner
    /// session. Retaining prior transport IDs across reconnect lets an already
    /// finalized delegate callback finish crossing the queue without allowing
    /// it to leak into a later wake session.
    private var logicalSessionByConnectionID: [UUID: String] = [:]
    private var recentConversation: [String] = []
    private var lastInnerLifeProjection: String?
    private var lastPrivateLifeProjection: String?
    private var lastPrivateLifeProjectionRevision: String?
    private var lastPrivateLifeProjectionActivityID: String?
    private var lastOwnerUnderstandingProjection: String?
    private var lastAgencyProjection: String?
    private var ownerUnderstandingBootstrapAttempted = false
    private var lastContinuityProjection: String?
    private var participantTracker: SessionParticipantTracker
    private var participantConnectionBaseline: AuroraSessionParticipant
    private var sessionPrivacyEpoch: AuroraSessionPrivacyEpoch = .owner
    private var pendingParticipantReplay: PendingParticipantReplay?
    private var participantReplayInFlight = false
    private var pendingDelegateTaskEvents: [String: DelegateTaskEvent] = [:]
    private var publishingDelegateTaskEventID: String?
    private var announcingDelegateTaskID: String?
    private var announcingDelegateTaskDeliveryID: String?
    private var announcingDelegateTaskEvent: DelegateTaskEvent?
    private var wakeAcknowledgementPending = false
    private var wakeAcknowledgementInFlight = false
    private var wakeAcknowledgementRetryCount = 0
    private var pendingAutomaticRest: PendingAutomaticRest?
    private var fullyPlayedInputItemsAwaitingTranscript = Set<String>()
    private var wakeListenerDiagnosticFingerprint: String?

    private var userTranscripts: [String: String] = [:]
    private var transcriptUnavailableItems = Set<String>()
    private var pendingOutcomes: [String: [TurnOutcome]] = [:]
    private var introducedTurnItems = Set<String>()
    private var addressedInputItems = Set<String>()
    private var participantByInputItem: [String: AuroraSessionParticipant] = [:]
    private var innerLifeParticipantItems = Set<String>()
    private var innerLifeOwnerItems = Set<String>()
    private var innerLifeOutcomeItems = Set<String>()
    private var innerLifeQuietItems = Set<String>()
    private var innerLifeRateLimitItems = Set<String>()
    private var privateLifeExchangeItems = Set<String>()
    private var toolAddressedInputItems = ToolAddressedInputProvenance()
    private var assistantPlaybackByResponseID: [String: RealtimeAssistantPlaybackOutcome] = [:]
    private var assistantPlaybackResponseOrder: [String] = []
    /// conversation_move is prepared on the tool-call response; its audible
    /// continuation has a new Realtime response ID. Bind playback through the
    /// causal owner input so only actually heard audio settles the move.
    private var agencyPlanningResponseByInputItem: [String: String] = [:]
    /// An open_curiosity is reserved on the private conversation_move response,
    /// then settled only by the later audible continuation for the same owner
    /// input. No transcript wording creates this binding.
    private var ownerCuriosityPlaybackBindings = OwnerCuriosityPlaybackBindings()
    private var pendingEvidenceCalls: [String: [RealtimeFunctionCall]] = [:]
    /// Participant replay retains recently completed inputs independently from
    /// the outcome-drain queue so a late transcript can still correct guest or
    /// owner provenance without blocking later completed turns.
    private var participantInputOrder: [String] = []
    private var committedInputOrder: [String] = []
    private var inputCommittedAt: [String: Date] = [:]
    private var inputCommitEvidence: [String: RealtimeInputCommitEvent] = [:]
    private var mergedTailArtifactItems = Set<String>()
    private var completedTurnsReady = Set<String>()
    private var completedInputHistory: [String] = []
    private var outcomeDedupeOrder: [String] = []
    private var userSpeechActive = false
    private var ownerSpeechGeneration: UInt64 = 0
    private var speechGenerationByInputItem: [String: UInt64] = [:]

    private var sessionRefreshTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var evidenceWaitTasks: [String: Task<Void, Never>] = [:]
    private var toolTasks: [String: Task<Void, Never>] = [:]
    /// Once Realtime has finalized a direct-owner delegate_task, ordinary
    /// follow-up speech may interrupt Aurora's acknowledgement but must not
    /// revoke the already-committed Codex handoff.
    private var durableDelegateToolCallIDs = Set<String>()
    private var durableOwnerUnderstandingToolCallIDs = Set<String>()
    private var innerLifeClockTask: Task<Void, Never>?
    private var innerLifeProjectionTask: Task<Void, Never>?
    private var continuityProjectionTask: Task<Void, Never>?
    private var continuityDirectoryWatcher: DispatchSourceFileSystemObject?
    private var continuityRefreshDebounceTask: Task<Void, Never>?
    private var continuityProjectionDirty = false
    private var innerLifeEventTask: Task<InnerLifeSnapshot, Never>?
    private var privateLifeEventTask: Task<PrivateLifeSnapshot, Never>?
    private var privateLifeReflectionTask: Task<Void, Never>?
    private var delegateTaskPublishRetryTask: Task<Void, Never>?
    private var delegateTaskDeliveryTimeoutTask: Task<Void, Never>?
    private var wakeAcknowledgementRetryTask: Task<Void, Never>?
    private var automaticRestFallbackTask: Task<Void, Never>?
    /// Serializes direct-session cancellation so application termination can
    /// wait for the exact cancellation already started by Rest instead of
    /// racing it with delegate-runtime shutdown.
    private var sessionCancellationTask: Task<Void, Never>?
    /// One model-owned termination barrier is shared by every AppKit quit
    /// request. Persistent Codex work is detached only after direct computer
    /// work for the ending voice session has drained.
    private var applicationTerminationTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        let companionServer = AuroraCompanionServer()
        let audioRouter = AuroraRoutableAudio(companionServer: companionServer)
        let ownerProfileStore = OwnerProfileStore()
        let ownerBootstrap = ownerProfileStore.bootstrap()
        let memoryStore = MemoryStore(configuration: .init(
            rootURL: AuroraPaths.continuityWorkspace
        ))
        let continuityDocumentStore = ContinuityDocumentStore(
            rootURL: AuroraPaths.continuityWorkspace
        )
        // Reflection has its own tightly bounded read actor so a background
        // lexical scan can never queue a live voice memory/tool operation.
        let reflectionMemoryStore = MemoryStore(configuration: .init(
            rootURL: AuroraPaths.continuityWorkspace,
            identityCapsuleCharacterLimit: 3_000,
            perIdentityDocumentCharacterLimit: 500,
            perPersonhoodDocumentCharacterLimit: 350,
            readCharacterLimit: 2_000,
            searchDocumentByteLimit: 16_000,
            maximumSearchBytesPerQuery: 1 * 1_024 * 1_024,
            maximumSearchDocuments: 100,
            maximumSearchResults: 3,
            maximumVoiceLearningCharacters: 500
        ))
        let innerLife = AuroraInnerLifeRuntime()
        let privateLife = AuroraPrivateLifeRuntime()
        let ownerUnderstanding = AuroraOwnerUnderstandingRuntime()
        let agency = AuroraAgencyRuntime()
        let eventJournal = EventJournal()
        let privateLifeReflectionCoordinator = AuroraPrivateLifeReflectionCoordinator(
            privateLife: privateLife,
            bridge: CodexReflectionBridge(),
            memoryStore: reflectionMemoryStore,
            journal: eventJournal
        )
        let wakeWordListener = AuroraWakeWordListener()
        self.ownerProfileStore = ownerProfileStore
        self.memoryStore = memoryStore
        self.continuityDocumentStore = continuityDocumentStore
        self.innerLife = innerLife
        self.privateLife = privateLife
        self.privateLifeReflectionCoordinator = privateLifeReflectionCoordinator
        self.ownerUnderstanding = ownerUnderstanding
        self.agency = agency
        self.wakeWordListener = wakeWordListener
        self.voiceKeyCache = VoiceKeySessionCache()
        self.eventJournal = eventJournal
        self.audioRouter = audioRouter
        self.companionServer = companionServer
        self.realtime = AuroraRealtimeClient(audio: audioRouter)
        self.toolRegistry = ToolRegistry(
            memoryStore: memoryStore,
            continuityStore: continuityDocumentStore,
            ownerDisplayName: ownerBootstrap.profile?.displayName ?? "Owner",
            commandApproval: { _ in false },
            conversationMoveHandler: { proposal, context in
                let innerSnapshot = await innerLife.snapshot()
                return await ConversationMoveAdapter.execute(
                    proposal,
                    context: context,
                    agency: agency,
                    ownerUnderstanding: ownerUnderstanding,
                    signals: ConversationMoveAdapter.signals(from: innerSnapshot)
                )
            },
            privateLifeShareHandler: { activityID, context in
                guard context.participantIsOwner,
                      context.authorizationSource == .directOwnerTurn,
                      context.turnAlreadySpoke,
                      let sessionID = context.sessionID,
                      let responseID = context.assistantResponseID else {
                    return ToolExecutionResult(
                        ok: false,
                        output: "No audible same-response private-life share was available to bind.",
                        metadata: ["terminal": .bool(true)]
                    )
                }
                let snapshot = await privateLife.beginShare(
                    activityID: activityID,
                    sessionID: sessionID,
                    responseID: responseID
                )
                let accepted = snapshot.state?.pendingShares.contains(where: {
                    $0.activityID == activityID
                        && $0.sessionID == sessionID
                        && $0.responseID == responseID
                }) == true
                return ToolExecutionResult(
                    ok: accepted,
                    output: accepted
                        ? "The spoken private thought is awaiting exact playback completion."
                        : "That private thought was not eligible for this response.",
                    metadata: [
                        "terminal": .bool(true),
                        "private_life_share_pending": .bool(accepted),
                        "external_side_effect": .bool(false),
                    ]
                )
            },
            ownerUnderstandingUpdateHandler: { updates, context in
                await OwnerUnderstandingToolAdapter.execute(
                    updates,
                    context: context,
                    runtime: ownerUnderstanding
                )
            }
        )
        self.ownerDisplayName = ownerBootstrap.profile?.displayName ?? ""
        let participantTracker = SessionParticipantTracker(
            ownerName: ownerBootstrap.profile?.displayName ?? "Owner"
        )
        self.participantTracker = participantTracker
        self.participantConnectionBaseline = participantTracker.current
        self.onboardingMode = ownerBootstrap.requiresFirstRunOnboarding ? .firstRun : nil
        let companionIsConfigured = !AuroraCompanionProtocol
            .allowedTailscalePeerAddresses
            .isEmpty
        self.companionPairingCode = companionIsConfigured
            ? companionServer.pairingCode
            : "—"
        if companionIsConfigured {
            self.companionStatus = "Preparing private iPhone companion…"
        }
        bindRealtimeCallbacks()
        bindWakeWordCallbacks()
        bindCompanionCallbacks()
        Publishers.CombineLatest3($phase, $inputLevel, $outputLevel)
            .sink { [weak self] phase, inputLevel, outputLevel in
                guard let self else { return }
                self.audioRouter.publishCompanionState(
                    Self.companionState(
                        phase: phase,
                        audioRoute: self.audioRouter.companionAudioRoute,
                        sessionOwner: self.companionSessionOwner.rawValue,
                        inputLevel: inputLevel,
                        outputLevel: outputLevel
                    )
                )
            }
            .store(in: &cancellables)
        if companionIsConfigured {
            companionServer.start()
        }
        let toolRegistry = self.toolRegistry
        Task { [weak self, toolRegistry] in
            await toolRegistry.setDelegateTaskEventHandler { [weak self] event in
                await self?.acceptDelegateTaskEvent(event)
            }
            // Establish the shared ChatGPT/Codex transport while Aurora rests.
            // This is authentication/readiness only: it creates no model turn
            // and no owner-visible task.
            await toolRegistry.prewarmDelegateTaskRuntime()
        }
        NotificationCenter.default.publisher(for: .auroraWindowWillClose)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rest() }
            .store(in: &cancellables)
        if onboardingMode != .firstRun { wakeWordListener.start() }
        innerLifeClockTask = Task {
            [weak self, innerLife, privateLife, ownerUnderstanding, agency] in
            let initialInnerSnapshot = await innerLife.start()
            _ = await privateLife.start()
            _ = await ownerUnderstanding.start()
            _ = await agency.start()
            await self?.promoteRecentPrivateActivitiesToAgency()
            await self?.importLegacyOwnerUnderstandingIfNeeded()
            if let initialInnerState = initialInnerSnapshot.state {
                _ = await privateLife.tick(innerState: initialInnerState)
                self?.schedulePrivateLifeReflection(innerState: initialInnerState)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let innerSnapshot = await innerLife.tick()
                guard let self else { return }
                _ = await self.privateLifeEventTask?.value
                if let innerState = innerSnapshot.state {
                    _ = await privateLife.tick(innerState: innerState)
                    self.schedulePrivateLifeReflection(innerState: innerState)
                }
                self.scheduleInnerLifeProjectionRefresh()
            }
        }
    }

    deinit {
        sessionRefreshTask?.cancel()
        startTask?.cancel()
        reconnectTask?.cancel()
        innerLifeClockTask?.cancel()
        innerLifeProjectionTask?.cancel()
        continuityProjectionTask?.cancel()
        continuityRefreshDebounceTask?.cancel()
        continuityDirectoryWatcher?.cancel()
        privateLifeReflectionTask?.cancel()
        wakeAcknowledgementRetryTask?.cancel()
        automaticRestFallbackTask?.cancel()
        evidenceWaitTasks.values.forEach { $0.cancel() }
        toolTasks.values.forEach { $0.cancel() }
        realtime.stop()
        companionServer.stop()
    }

    func wake() {
        guard audioRouter.selectLocal() else { return }
        beginWake(trigger: .manual)
    }

    private func wakeFromLocalPhrase() {
        guard audioRouter.selectLocal() else { return }
        beginWake(trigger: .localWakePhrase)
    }

    private func wakeFromCompanion() {
        guard !wantsAwake,
              onboardingMode == nil,
              audioRouter.selectRemote() else { return }
        beginWake(trigger: .remoteCompanion)
    }

    private func beginWake(trigger: WakeTrigger) {
        guard !wantsAwake, onboardingMode == nil else { return }
        // This is synchronous by design: Realtime never competes with the
        // resting listener for the microphone.
        wakeWordListener.stopAndRelinquishMicrophone()
        wantsAwake = true
        companionSessionOwner = trigger == .remoteCompanion ? .iphone : .mac
        // Foreground presence always wins over paid background reflection.
        // The reflection coordinator durably defers a cancelled reservation,
        // and the resting clock may retry it later; it must never compete with
        // Realtime startup or the owner's next Codex task.
        preemptPrivateLifeReflectionForForeground()
        lifecycleID = UUID()
        // One logical owner conversation may span several short-lived
        // Realtime transports. Keep its identity stable so backstage Codex
        // work remains addressable and its terminal result can return after a
        // recoverable reconnect or the scheduled transport refresh.
        logicalSessionByConnectionID.removeAll()
        localSessionID = UUID().uuidString.lowercased()
        sessionPrivacyEpoch = .owner
        pendingParticipantReplay = nil
        participantReplayInFlight = false
        reconnectAttempt = 0
        wakeAcknowledgementPending = trigger == .localWakePhrase
        wakeAcknowledgementInFlight = false
        wakeAcknowledgementRetryCount = 0
        wakeAcknowledgementRetryTask?.cancel()
        wakeAcknowledgementRetryTask = nil
        cancelPendingAutomaticRest()
        let token = lifecycleID
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startFreshSession(reconnecting: false, lifecycleToken: token)
        }

        if trigger == .localWakePhrase {
            let sessionID = localSessionID
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "local_wake_phrase_detected",
                    sessionID: sessionID,
                    detail: "Aurora crossed the local wake boundary.",
                    metadata: ["audio_retained": "false", "transcript_retained": "false"]
                ))
            }
        } else if trigger == .remoteCompanion {
            let sessionID = localSessionID
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "companion_voice_session_requested",
                    sessionID: sessionID,
                    detail: "Aurora's paired iPhone opened the existing Mac-owned voice path.",
                    metadata: [
                        "audio_authority": "iphone",
                        "cognition_authority": "mac",
                    ]
                ))
            }
        }
    }

    func rest() {
        let wasAwake = wantsAwake
        let sessionID = localSessionID
        wantsAwake = false
        companionSessionOwner = .none
        lifecycleID = UUID()
        activeConnectionID = nil
        localSessionID = nil
        logicalSessionByConnectionID.removeAll()
        lastInnerLifeProjection = nil
        lastPrivateLifeProjection = nil
        lastPrivateLifeProjectionRevision = nil
        lastPrivateLifeProjectionActivityID = nil
        lastOwnerUnderstandingProjection = nil
        lastAgencyProjection = nil
        lastContinuityProjection = nil
        sessionPrivacyEpoch = .owner
        pendingParticipantReplay = nil
        participantReplayInFlight = false
        stopContinuityDirectoryWatcher()
        reconnectAttempt = 0
        wakeAcknowledgementPending = false
        wakeAcknowledgementInFlight = false
        wakeAcknowledgementRetryCount = 0
        wakeAcknowledgementRetryTask?.cancel()
        wakeAcknowledgementRetryTask = nil
        cancelPendingAutomaticRest()
        interruptPendingAgencyMoves(reason: "voice-rest")
        interruptPendingOwnerQuestions(reason: "voice-rest")
        cancelSessionWork(endingSessionID: sessionID)
        if let sessionID {
            Task { [privateLife] in
                _ = await privateLife.cancelPendingShares(sessionID: sessionID)
            }
        }
        phase = .resting
        inputLevel = 0
        outputLevel = 0

        let restingLifecycleID = lifecycleID
        stopRealtimeThenArmWakeWord(lifecycleToken: restingLifecycleID)

        if wasAwake {
            enqueueInnerLifeEvents([InnerLifeEvent(kind: .voiceRested)])
            let ownerName = ownerDisplayName
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "voice_session_stopped",
                    sessionID: sessionID,
                    detail: "\(ownerName) let Aurora rest."
                ))
            }
        }
    }

    func retry() {
        rest()
        wake()
    }

    /// AppKit awaits this method before allowing the process to exit. This is
    /// deliberately separate from `rest()`: closing Aurora's window keeps its
    /// existing Rest/wake-word behavior, while a real application quit stops
    /// local audio and tears down only Aurora's delegate connection.
    func prepareForApplicationTermination() async {
        if let applicationTerminationTask {
            await applicationTerminationTask.value
            return
        }

        // Stop admitting new voice work first, but give every already-finalized
        // delegate_task call enough time to cross the durable coordinator
        // boundary. Its ToolRegistry call returns as soon as the task record is
        // persisted; the long-running Codex turn itself is not awaited here.
        let endingSessionID = localSessionID
        wakeWordListener.stopAndRelinquishMicrophone()
        realtime.stop()
        let committedDelegateHandoffs = durableDelegateToolCallIDs.compactMap {
            toolTasks[$0]
        }
        let toolRegistry = toolRegistry
        let terminationTask = Task { @MainActor in
            for handoff in committedDelegateHandoffs {
                await handoff.value
            }

            wantsAwake = false
            companionSessionOwner = .none
            lifecycleID = UUID()
            activeConnectionID = nil
            localSessionID = nil
            logicalSessionByConnectionID.removeAll()
            cancelPendingAutomaticRest()
            cancelSessionWork(endingSessionID: endingSessionID)

            let directSessionCancellation = sessionCancellationTask
            await directSessionCancellation?.value
            await toolRegistry.shutdownDelegateTaskRuntime()
        }
        applicationTerminationTask = terminationTask
        await terminationTask.value
    }

    func requestVoiceKey() {
        wakeWordListener.stopAndRelinquishMicrophone()
        onboardingError = nil
        onboardingMode = ownerDisplayName.isEmpty ? .firstRun : .addVoiceKey
    }

    func beginVoiceKeyChange() {
        if wantsAwake { rest() }
        wakeWordListener.stopAndRelinquishMicrophone()
        onboardingError = nil
        onboardingMode = .changeVoiceKey
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A direct edit in Aurora's native continuity sheet is immediately
    /// causal: the next idle live boundary receives a replacement Markdown
    /// kernel, while a resting Aurora simply starts her next session with it.
    func continuityDocumentDidChange(_ snapshot: ContinuityDocumentSnapshot) {
        continuityProjectionDirty = true
        scheduleContinuityProjectionRefresh()
        let sessionID = localSessionID
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: "continuity_document_saved",
                sessionID: sessionID,
                detail: "Aurora's editable continuity changed.",
                metadata: [
                    "document": snapshot.document.rawValue,
                    "revision": snapshot.revision,
                    "bytes": String(snapshot.byteCount),
                ]
            ))
        }
    }

    /// Watches the continuity root rather than individual files because the
    /// safe editor (and many external editors) save by atomically replacing a
    /// file. Screen/document content remains observation only: every event is
    /// re-read through ContinuityDocumentStore's no-symlink, bounded checks.
    private func startContinuityDirectoryWatcherIfNeeded() {
        guard wantsAwake, continuityDirectoryWatcher == nil else { return }
        let descriptor = Darwin.open(
            continuityDocumentStore.rootURL.path,
            O_EVTONLY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "continuity_watch_unavailable",
                    sessionID: localSessionID,
                    detail: "Aurora could not watch her continuity folder for external edits.",
                    metadata: ["unix_error": String(code)]
                ))
            }
            return
        }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.continuityDirectoryDidChange()
            }
        }
        watcher.setCancelHandler {
            Darwin.close(descriptor)
        }
        continuityDirectoryWatcher = watcher
        watcher.resume()
    }

    private func continuityDirectoryDidChange() {
        guard wantsAwake else { return }
        continuityProjectionDirty = true
        continuityRefreshDebounceTask?.cancel()
        let token = lifecycleID
        continuityRefreshDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self,
                  self.wantsAwake,
                  token == self.lifecycleID else { return }
            self.continuityRefreshDebounceTask = nil
            self.scheduleContinuityProjectionRefresh()
        }
    }

    private func stopContinuityDirectoryWatcher() {
        continuityRefreshDebounceTask?.cancel()
        continuityRefreshDebounceTask = nil
        continuityDirectoryWatcher?.cancel()
        continuityDirectoryWatcher = nil
        continuityProjectionDirty = false
    }

    func cancelOnboarding() {
        guard onboardingMode?.canCancel == true else { return }
        onboardingMode = nil
        onboardingError = nil
        if !wantsAwake {
            wakeWordListener.start()
        }
    }

    func completeOnboarding(displayName: String, apiKey: String) {
        guard let mode = onboardingMode else { return }
        do {
            let validatedName: String
            if mode == .firstRun {
                validatedName = try ownerProfileStore.validatedDisplayName(displayName)
            } else {
                validatedName = ownerDisplayName
            }
            try voiceKeyCache.save(apiKey)
            if mode == .firstRun {
                ownerDisplayName = try ownerProfileStore.save(
                    displayName: validatedName
                ).displayName
                participantTracker = SessionParticipantTracker(ownerName: ownerDisplayName)
            }
            onboardingMode = nil
            onboardingError = nil
            wantsAwake = false
            companionSessionOwner = .none
            phase = .resting
            wake()
        } catch {
            onboardingError = error.localizedDescription
        }
    }

    private func startFreshSession(reconnecting: Bool, lifecycleToken: UUID) async {
        guard wantsAwake, lifecycleToken == lifecycleID else { return }
        phase = reconnecting ? .reconnecting : .connecting
        if !reconnecting {
            participantTracker = SessionParticipantTracker(ownerName: ownerDisplayName)
            sessionPrivacyEpoch = .owner
        }

        do {
            await toolRegistry.configureOwner(displayName: ownerDisplayName)
            guard let apiKey = try voiceKeyCache.load() else {
                guard lifecycleToken == lifecycleID else { return }
                if companionSessionOwner == .iphone {
                    rest()
                    return
                }
                wantsAwake = false
                companionSessionOwner = .none
                phase = .needsVoiceKey
                return
            }
            if !audioRouter.isRemoteSelected {
                guard await requestMicrophonePermission() else {
                    throw AuroraAppError.microphonePermissionDenied
                }
            }
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            try NativeContinuityBootstrap.prepare(
                at: memoryStore.rootURL,
                ownerDisplayName: ownerDisplayName
            )
            try await continuityDocumentStore.prepare(
                ownerDisplayName: ownerDisplayName
            )
            startContinuityDirectoryWatcherIfNeeded()
            let capsule = try await continuityDocumentStore.voiceIdentityCapsule()
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            let pendingInnerLifeEvents = innerLifeEventTask
            _ = await pendingInnerLifeEvents?.value
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            if reconnecting {
                _ = await innerLife.tick()
            } else {
                _ = await innerLife.record(InnerLifeEvent(kind: .voiceAwoke))
            }
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            let innerLifeProjection = await innerLife.voiceContext()
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            _ = await privateLife.start()
            let privateLifePacket = await privateLife.projectionPacket()
            let previousPrivateActivityID = lastPrivateLifeProjectionActivityID
            let privateLifeSelection = PrivateLifeSessionProjectionPolicy.select(
                packet: privateLifePacket,
                previousText: lastPrivateLifeProjection,
                previousRevisionDigest: lastPrivateLifeProjectionRevision,
                previousActivityID: previousPrivateActivityID
            )
            let privateLifeProjection = privateLifeSelection.text
            let carryPrivateProjectionAcrossReconnect = PrivateLifeSessionProjectionPolicy
                .shouldCarryAcknowledgedActivityAcrossReconnect(
                    selection: privateLifeSelection,
                    reconnecting: reconnecting,
                    previousActivityID: previousPrivateActivityID
                )
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            _ = await ownerUnderstanding.start()
            await importLegacyOwnerUnderstandingIfNeeded()
            let ownerUnderstandingProjection = await ownerUnderstanding.voiceProjection()
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            _ = await agency.start()
            let agencySignals = ConversationMoveAdapter.signals(
                from: await innerLife.snapshot()
            )
            let agencyProjection = await agency.projection(signals: agencySignals).text
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            let sessionID = localSessionID ?? UUID().uuidString.lowercased()
            // Voice must never wait for Codex daemon startup or a live
            // thread/read. Start from the durable local ledger and reconcile
            // the exact task after Realtime is already opening.
            let delegateTaskProjection = await toolRegistry.cachedDelegateTaskSessionContext(
                sessionID: sessionID
            )
            try Task.checkCancellation()
            guard wantsAwake, lifecycleToken == lifecycleID else { return }

            let toolsJSON = try toolRegistry.functionSchemasJSON()
            let instructions: String
            switch sessionPrivacyEpoch {
            case .owner:
                instructions = makeInstructions(
                    capsule: capsule,
                    innerLifeProjection: innerLifeProjection,
                    privateLifeProjection: privateLifeProjection,
                    ownerUnderstandingProjection: ownerUnderstandingProjection,
                    agencyProjection: agencyProjection,
                    delegateTaskProjection: delegateTaskProjection
                )
            case .guest(let displayName):
                instructions = AuroraVoiceInstructions.composeGuestSafe(
                    ownerDisplayName: ownerDisplayName,
                    guestDisplayName: displayName
                )
            }
            let configuration = RealtimeSessionConfiguration(
                apiKey: apiKey,
                instructions: instructions,
                toolsJSON: toolsJSON,
                vad: AuroraVoiceActivityProfile.live
            )
            let connectionID = try realtime.start(configuration: configuration)
            guard wantsAwake, lifecycleToken == lifecycleID, !Task.isCancelled else {
                realtime.stop()
                return
            }

            activeConnectionID = connectionID
            localSessionID = sessionID
            logicalSessionByConnectionID[connectionID] = sessionID
            Task { [toolRegistry] in
                await toolRegistry.refreshDelegateTaskSessionContext(sessionID: sessionID)
                // A terminal transition is delivered by the coordinator's
                // event stream. A nonterminal refresh remains private until a
                // direct status question, avoiding an unsolicited response.
            }
            if logicalSessionByConnectionID.count > 8 {
                let retained = Set([connectionID])
                for key in Array(logicalSessionByConnectionID.keys)
                    where !retained.contains(key) {
                    logicalSessionByConnectionID.removeValue(forKey: key)
                    if logicalSessionByConnectionID.count <= 4 { break }
                }
            }
            lastInnerLifeProjection = innerLifeProjection
            lastOwnerUnderstandingProjection = ownerUnderstandingProjection
            lastAgencyProjection = agencyProjection
            lastContinuityProjection = capsule.text
            if carryPrivateProjectionAcrossReconnect {
                // Reconnection is invisible to the owner and is not the end of
                // Aurora's awake conversation. Preserve the already accepted
                // lived context without issuing a second acknowledgement.
                lastPrivateLifeProjection = privateLifeSelection.text
                lastPrivateLifeProjectionRevision = privateLifeSelection.revisionDigest
                lastPrivateLifeProjectionActivityID = privateLifeSelection.currentActivityID
            } else {
                // The session prefix already contains the current record. Keep
                // acknowledgement unset until Realtime accepts the replaceable
                // dynamic item, which gives an exact activity receipt.
                lastPrivateLifeProjection = nil
                lastPrivateLifeProjectionRevision = nil
                lastPrivateLifeProjectionActivityID = nil
            }
            clearPerConnectionTurnState()
            scheduleSessionRefresh(lifecycleToken: lifecycleToken)

            await eventJournal.append(AuroraJournalEvent(
                kind: reconnecting ? "voice_session_reopened" : "voice_session_started",
                sessionID: sessionID,
                detail: "Aurora opened a direct Realtime voice session.",
                metadata: [
                    "connection_id": connectionID.uuidString.lowercased(),
                    "model": AuroraRealtimeClient.model,
                    "voice": AuroraRealtimeClient.voice,
                    "privacy_epoch": sessionPrivacyEpoch.isOwner ? "owner" : "guest",
                    "identity_sources": String(capsule.sources.count),
                    "identity_truncated": String(capsule.truncated),
                    "identity_characters": String(capsule.text.count),
                    "instruction_characters": String(instructions.count),
                    "tool_schema_characters": String(toolsJSON.count),
                ]
            ))
        } catch is CancellationError {
            return
        } catch {
            guard lifecycleToken == lifecycleID else { return }
            await eventJournal.append(AuroraJournalEvent(
                kind: "voice_session_start_failed",
                sessionID: localSessionID,
                detail: error.localizedDescription
            ))
            if companionSessionOwner == .iphone {
                rest()
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func bindWakeWordCallbacks() {
        wakeWordListener.onWakeWordDetected = { [weak self] in
            self?.wakeFromLocalPhrase()
        }
        wakeWordListener.onStatusChange = { [weak self] status in
            guard let self else { return }
            switch status {
            case .stopped, .wakeDetected:
                self.restingWakeDetail = nil
                self.wakeListenerDiagnosticFingerprint = nil
            case .requestingPermissions, .starting, .rollingRecognition:
                self.restingWakeDetail = "Preparing local wake listening…"
            case .listening:
                self.restingWakeDetail = "Listening locally for “Hey Aurora.”"
                self.journalWakeListenerBoundary(
                    fingerprint: "listening",
                    kind: "local_wake_listener_ready",
                    detail: "Aurora's local wake listener owns a stable microphone route."
                )
            case .recovering(let error, let retryAfterSeconds):
                self.restingWakeDetail = error == .microphoneUnavailable
                    ? "Connect a microphone for “Hey Aurora.”"
                    : "Reconnecting local wake listening…"
                self.journalWakeListenerBoundary(
                    fingerprint: "recovering:\(error.diagnosticCode)",
                    kind: "local_wake_listener_recovering",
                    detail: error.localizedDescription,
                    metadata: [
                        "code": error.diagnosticCode,
                        "retry_after_seconds": String(format: "%.2f", retryAfterSeconds),
                    ]
                )
            case .failed(let error):
                self.restingWakeDetail = error.localizedDescription
                self.journalWakeListenerBoundary(
                    fingerprint: "failed:\(error.diagnosticCode)",
                    kind: "local_wake_listener_unavailable",
                    detail: error.localizedDescription,
                    metadata: [
                        "code": error.diagnosticCode,
                        "manual_wake_available": "true",
                    ]
                )
            }
        }
    }

    func refreshCompanionPairingCode() {
        companionPairingCode = AuroraCompanionProtocol
            .allowedTailscalePeerAddresses
            .isEmpty
            ? "—"
            : companionServer.pairingCode
    }

    private func bindCompanionCallbacks() {
        companionServer.onWakeRequested = { [weak self] in
            self?.wakeFromCompanion()
        }
        companionServer.onRestRequested = { [weak self] in
            guard let self,
                  self.wantsAwake,
                  self.companionSessionOwner == .iphone,
                  self.audioRouter.isRemoteSelected else { return }
            self.rest()
        }
        companionServer.onStatusChanged = { [weak self] status in
            self?.companionStatus = status
            self?.companionPairingCode = self?.companionServer.pairingCode ?? "Unavailable"
        }
        audioRouter.onRemoteRouteLost = { [weak self] in
            guard let self,
                  self.wantsAwake,
                  self.companionSessionOwner == .iphone,
                  self.audioRouter.isRemoteSelected else { return }
            self.rest()
        }
    }

    private static func companionState(
        phase: AuroraPhase,
        audioRoute: String,
        sessionOwner: String,
        inputLevel: Double,
        outputLevel: Double
    ) -> AuroraCompanionServer.MirroredState {
        let phaseCode: String
        let detail: String?
        switch phase {
        case .resting:
            phaseCode = "resting"
            detail = nil
        case .connecting:
            phaseCode = "connecting"
            detail = nil
        case .listening:
            phaseCode = "listening"
            detail = nil
        case .thinking:
            phaseCode = "thinking"
            detail = nil
        case .waitingToRetry:
            phaseCode = "waiting_to_retry"
            detail = nil
        case .speaking:
            phaseCode = "speaking"
            detail = nil
        case .reconnecting:
            phaseCode = "reconnecting"
            detail = nil
        case .needsVoiceKey:
            phaseCode = "needs_voice_key"
            detail = "Add Aurora's voice key on the Mac."
        case .failed(let message):
            phaseCode = "failed"
            detail = message
        }
        return AuroraCompanionServer.MirroredState(
            phase: phaseCode,
            detail: detail,
            audioRoute: audioRoute,
            sessionOwner: sessionOwner,
            inputLevel: Float(min(max(inputLevel, 0), 1)),
            outputLevel: Float(min(max(outputLevel, 0), 1))
        )
    }

    private func journalWakeListenerBoundary(
        fingerprint: String,
        kind: String,
        detail: String,
        metadata: [String: String] = [:]
    ) {
        guard wakeListenerDiagnosticFingerprint != fingerprint else { return }
        wakeListenerDiagnosticFingerprint = fingerprint
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: kind,
                detail: detail,
                metadata: metadata
            ))
        }
    }

    private func stopRealtimeThenArmWakeWord(
        lifecycleToken: UUID,
        settledPhase: AuroraPhase = .resting
    ) {
        realtime.stop { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.wantsAwake,
                      lifecycleToken == self.lifecycleID else { return }
                // Realtime has now released the whole-session route. Return
                // ownership to the Mac before publishing the settled state so
                // the phone never sees a stale remote route while Aurora rests.
                _ = self.audioRouter.selectLocal()
                self.phase = settledPhase
                do {
                    // Core Audio can retain a just-stopped input route for a
                    // moment. A short handoff cool-down prevents two engines
                    // from fighting over the same microphone on repeated use.
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !self.wantsAwake,
                      lifecycleToken == self.lifecycleID,
                      self.onboardingMode == nil else { return }
                self.wakeWordListener.start()
            }
        }
    }

    private func attemptWakeAcknowledgement() {
        guard wakeAcknowledgementPending,
              !wakeAcknowledgementInFlight,
              !userSpeechActive,
              phase == .listening,
              let connectionID = activeConnectionID else { return }

        wakeAcknowledgementInFlight = true
        let token = lifecycleID
        realtime.publishWakeWordAcknowledgement(
            connectionID: connectionID,
            completion: { [weak self] accepted in
                Task { @MainActor in
                    guard let self,
                          self.wantsAwake,
                          token == self.lifecycleID,
                          connectionID == self.activeConnectionID else { return }
                    self.wakeAcknowledgementInFlight = false
                    if accepted {
                        self.wakeAcknowledgementPending = false
                        self.wakeAcknowledgementRetryCount = 0
                        return
                    }
                    guard self.wakeAcknowledgementPending,
                          !self.userSpeechActive else {
                        self.wakeAcknowledgementPending = false
                        return
                    }
                    self.scheduleWakeAcknowledgementRetry(
                        lifecycleToken: token,
                        connectionID: connectionID
                    )
                }
            }
        )
    }

    private func scheduleWakeAcknowledgementRetry(
        lifecycleToken: UUID,
        connectionID: UUID
    ) {
        wakeAcknowledgementRetryTask?.cancel()
        wakeAcknowledgementRetryCount += 1
        guard wakeAcknowledgementRetryCount <= 20 else {
            wakeAcknowledgementPending = false
            let sessionID = localSessionID
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "local_wake_greeting_unavailable",
                    sessionID: sessionID,
                    detail: "Aurora woke locally, but the live greeting boundary stayed busy."
                ))
            }
            return
        }
        wakeAcknowledgementRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  self.wantsAwake,
                  lifecycleToken == self.lifecycleID,
                  connectionID == self.activeConnectionID,
                  self.wakeAcknowledgementPending,
                  !self.userSpeechActive else { return }
            self.attemptWakeAcknowledgement()
        }
    }

    private func bindRealtimeCallbacks() {
        realtime.onPhase = { [weak self] connectionID, newPhase in
            guard let self else { return }
            if let connectionID {
                guard self.wantsAwake, connectionID == self.activeConnectionID else { return }
            } else {
                guard !self.wantsAwake, newPhase == .resting else { return }
            }
            self.phase = newPhase
            if !newPhase.isActive {
                self.inputLevel = 0
                self.outputLevel = 0
            }
            if newPhase == .listening {
                self.reconnectAttempt = 0
                self.attemptPendingParticipantReplay()
                if self.sessionPrivacyEpoch.isOwner {
                    self.attemptWakeAcknowledgement()
                    self.scheduleDelegateTaskPublicationRetry()
                    self.scheduleInnerLifeProjectionRefresh()
                    self.scheduleContinuityProjectionRefresh()
                }
            }
        }
        realtime.onInputLevel = { [weak self] connectionID, level in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.inputLevel = self.smoothed(previous: self.inputLevel, next: Double(level))
        }
        realtime.onOutputLevel = { [weak self] connectionID, level in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.outputLevel = self.smoothed(previous: self.outputLevel, next: Double(level))
        }
        realtime.onUserSpeechStarted = { [weak self] connectionID in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.userSpeechActive = true
            self.ownerSpeechGeneration &+= 1
            self.wakeAcknowledgementPending = false
            self.wakeAcknowledgementInFlight = false
            self.wakeAcknowledgementRetryCount = 0
            self.wakeAcknowledgementRetryTask?.cancel()
            self.wakeAcknowledgementRetryTask = nil
            self.delegateTaskPublishRetryTask?.cancel()
            self.delegateTaskPublishRetryTask = nil
            if let taskID = self.announcingDelegateTaskID {
                self.delegateTaskDeliveryTimeoutTask?.cancel()
                self.delegateTaskDeliveryTimeoutTask = nil
                self.announcingDelegateTaskID = nil
                self.announcingDelegateTaskDeliveryID = nil
                self.announcingDelegateTaskEvent = nil
                if self.pendingDelegateTaskEvents[taskID] != nil {
                    self.scheduleDelegateTaskPublicationRetry()
                }
            }
            self.cancelPendingAutomaticRest()
            self.innerLifeProjectionTask?.cancel()
            self.innerLifeProjectionTask = nil
            self.continuityProjectionTask?.cancel()
            self.continuityProjectionTask = nil
            self.interruptPendingAgencyMoves(reason: "barge-in")
            self.interruptPendingOwnerQuestions(reason: "barge-in")
            self.cancelToolWorkForSupersededTurn(preserveCommittedDelegates: true)
        }
        realtime.onUserSpeechEnded = { [weak self] connectionID in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.userSpeechActive = false
            if self.continuityProjectionDirty {
                self.scheduleContinuityProjectionRefresh()
            }
        }
        realtime.onInputCommitted = { [weak self] event in
            guard let self, event.connectionID == self.activeConnectionID else { return }
            if self.inputCommittedAt[event.itemID] == nil {
                self.inputCommittedAt[event.itemID] = Date()
                self.committedInputOrder.append(event.itemID)
                self.participantInputOrder.append(event.itemID)
            }
            self.inputCommitEvidence[event.itemID] = event
            self.speechGenerationByInputItem[event.itemID] = self.ownerSpeechGeneration
            self.recomputeParticipantProvenance()
        }
        realtime.onUserTranscript = { [weak self] event in
            guard let self,
                  event.connectionID == self.activeConnectionID,
                  event.isFinal else { return }
            self.acceptFinalUserTranscript(event)
        }
        realtime.onUserTranscriptUnavailable = { [weak self] connectionID, itemID in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.transcriptUnavailableItems.insert(itemID)
            self.recomputeParticipantProvenance()
            self.releasePendingEvidenceCalls(for: itemID, evidence: nil)
            self.flushCompletedTurn(itemID)
            self.trimTurnState()
        }
        realtime.onAssistantTranscript = { [weak self] event in
            guard let self,
                  event.connectionID == self.activeConnectionID,
                  event.isFinal else { return }
            let sessionID = self.localSessionID
            Task {
                await self.eventJournal.append(AuroraJournalEvent(
                    kind: "aurora_response_generated",
                    sessionID: sessionID,
                    detail: String(event.text.prefix(8_000)),
                    metadata: ["item_id": event.itemID]
                ))
            }
        }
        realtime.onAssistantPlaybackOutcome = { [weak self] outcome in
            guard let self, outcome.connectionID == self.activeConnectionID else { return }
            self.acceptPlaybackOutcome(outcome)
        }
        realtime.onBackgroundTaskDeliveryFailed = { [weak self] connectionID, deliveryID in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.acceptDelegateTaskSpeechDelivery(
                deliveryID: deliveryID,
                fullyPlayed: false
            )
        }
        realtime.onSilentTurn = { [weak self] connectionID, inputItemID in
            guard let self, connectionID == self.activeConnectionID else { return }
            if let inputItemID {
                self.pendingOutcomes[inputItemID, default: []].append(.quiet)
                self.flushCompletedTurn(inputItemID)
            }
            let sessionID = self.localSessionID
            Task {
                await self.eventJournal.append(AuroraJournalEvent(
                    kind: "aurora_intentionally_quiet",
                    sessionID: sessionID,
                    detail: "Aurora treated the audio as unmistakable background or not addressed to her.",
                    metadata: inputItemID.map { ["item_id": $0] } ?? [:]
                ))
            }
        }
        realtime.onUnresolvedTurn = { [weak self] connectionID, inputItemID in
            guard let self, connectionID == self.activeConnectionID else { return }
            let alreadyAddressed = self.addressedInputItems.contains(inputItemID)
            guard !alreadyAddressed else { return }
            self.pendingOutcomes[inputItemID, default: []].append(.unresolved)
            self.flushCompletedTurn(inputItemID)
            let sessionID = self.localSessionID
            Task {
                await self.eventJournal.append(AuroraJournalEvent(
                    kind: "voice_turn_unresolved",
                    sessionID: sessionID,
                    detail: "The turn ended before Aurora could verify whether the audio was addressed to her.",
                    metadata: ["item_id": inputItemID]
                ))
            }
        }
        realtime.onAddressedTurn = { [weak self] connectionID, inputItemID in
            guard let self, connectionID == self.activeConnectionID else { return }
            self.addressedInputItems.insert(inputItemID)
            self.pendingOutcomes[inputItemID, default: []].append(.addressedModel)
            self.flushCompletedTurn(inputItemID)
        }
        realtime.onDiagnostic = { [weak self] connectionID, kind, metadata in
            guard let self, connectionID == self.activeConnectionID else { return }
            if (kind == "rate_limit_retry_waiting"
                    || kind == "rate_limit_recovery_exhausted"),
               let inputItemID = metadata["input_item_id"],
               inputItemID != "missing",
               self.innerLifeRateLimitItems.insert(inputItemID).inserted {
                self.enqueueInnerLifeEvents([InnerLifeEvent(
                    kind: .technicalFailure(
                        category: "api_rate_limit",
                        sourceID: inputItemID
                    )
                )])
            }
            let sessionID = self.localSessionID
            Task {
                await self.eventJournal.append(AuroraJournalEvent(
                    kind: "voice_diagnostic_\(kind)",
                    sessionID: sessionID,
                    detail: "Voice boundary reached.",
                    metadata: metadata
                ))
            }
        }
        realtime.onFunctionCall = { [weak self] call in
            guard let self, call.connectionID == self.activeConnectionID else { return }
            self.acceptFunctionCall(call)
        }
        realtime.onError = { [weak self] connectionID, error in
            guard let self else { return }
            if let connectionID, connectionID != self.activeConnectionID { return }
            self.handleRuntimeError(error, connectionID: connectionID)
        }
    }

    private func acceptFinalUserTranscript(_ event: RealtimeUserTranscriptEvent) {
        let compact = String(event.text.prefix(8_000))
        userTranscripts[event.itemID] = compact
        let previousParticipant = participantTracker.current
        recomputeParticipantProvenance()
        let participant = participantByInputItem[event.itemID] ?? .unknown
        let targetPrivacyEpoch = AuroraSessionPrivacyEpoch.forParticipant(participant)
        let needsFreshPrivacyEpoch = sessionPrivacyEpoch
            .requiresFreshConversation(for: participant)
        let playbackAlreadyFinished = fullyPlayedInputItemsAwaitingTranscript.remove(event.itemID) != nil
        let belongsToLatestSpeech = speechGenerationByInputItem[event.itemID]
            .map { $0 == ownerSpeechGeneration } ?? !userSpeechActive
        let closingIntent = participant.isOwner && belongsToLatestSpeech && !userSpeechActive
            ? ConversationClosingIntentClassifier.classify(finalizedOwnerTranscript: compact)
            : .notClosing
        if closingIntent.shouldSleep {
            armAutomaticRest(after: event.itemID, intent: closingIntent)
        }
        transcriptUnavailableItems.remove(event.itemID)
        if needsFreshPrivacyEpoch, let targetPrivacyEpoch {
            beginParticipantPrivacyTransition(
                to: targetPrivacyEpoch,
                replay: PendingParticipantReplay(
                    transcript: compact,
                    participant: participant,
                    originalInputItemID: event.itemID
                )
            )
            let sessionID = localSessionID
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "voice_transcription_final",
                    sessionID: sessionID,
                    detail: compact,
                    metadata: [
                        "item_id": event.itemID,
                        "participant": participant.continuityLabel,
                        "epistemic_status": "asynchronous transcription; guidance, not exact model hearing",
                    ]
                ))
                await eventJournal.append(AuroraJournalEvent(
                    kind: "voice_participant_privacy_epoch_changed",
                    sessionID: sessionID,
                    detail: "Aurora opened a clean Realtime Conversation before answering a newly identified participant.",
                    metadata: [
                        "participant": participant.continuityLabel,
                        "source_item_id": event.itemID,
                        "owner_private_context_present": "false",
                    ]
                ))
            }
            return
        }
        releasePendingEvidenceCalls(for: event.itemID, evidence: compact)
        flushCompletedTurn(event.itemID)
        trimTurnState()

        if playbackAlreadyFinished, closingIntent.shouldSleep {
            completeAutomaticRest(after: event.itemID)
        }

        let sessionID = localSessionID
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: "voice_transcription_final",
                sessionID: sessionID,
                detail: compact,
                metadata: [
                    "item_id": event.itemID,
                    "participant": participant.continuityLabel,
                    "epistemic_status": "asynchronous transcription; guidance, not exact model hearing",
                ]
            ))
            if participant != previousParticipant {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "voice_participant_changed",
                    sessionID: sessionID,
                    detail: "The explicitly identified voice participant changed for this session.",
                    metadata: ["participant": participant.continuityLabel]
                ))
            }
        }
    }

    /// Replays participant changes in committed-audio order. Transcripts can
    /// finish out of order; snapshotting `participantTracker.current` at commit
    /// lets a guest's late introduction leave a newer command mislabeled as the
    /// owner. Missing audio remains fail-closed except for the resolver's narrow
    /// server-timed assistant-tail overlap case.
    private func recomputeParticipantProvenance() {
        let resolution = SessionParticipantProvenanceResolver.resolve(
            ownerName: participantTracker.ownerName,
            startingParticipant: participantConnectionBaseline,
            authenticatedOwnerLocalSession: companionSessionOwner == .mac,
            inputs: participantInputOrder.map { itemID in
                let evidence = inputCommitEvidence[itemID]
                return SessionParticipantInputEvidence(
                    itemID: itemID,
                    transcript: userTranscripts[itemID],
                    audioStartMilliseconds: evidence?.audioStartMilliseconds,
                    audioEndMilliseconds: evidence?.audioEndMilliseconds,
                    playbackRelationAtSpeechStart: evidence?
                        .playbackRelationAtSpeechStart ?? .none
                )
            }
        )
        participantByInputItem = resolution.participantByInputItem
        // Once two server commits were proven to be one overlapping acoustic
        // turn, a late transcript may correct its participant but must not
        // resurrect the duplicate commit as a second lived interaction.
        mergedTailArtifactItems.formUnion(resolution.mergedTailArtifactItemIDs)
        completedTurnsReady.formUnion(resolution.mergedTailArtifactItemIDs)
        participantTracker = SessionParticipantTracker(
            ownerName: participantTracker.ownerName,
            startingParticipant: resolution.finalParticipant
        )
    }

    private func acceptPlaybackOutcome(_ outcome: RealtimeAssistantPlaybackOutcome) {
        rememberAssistantPlaybackOutcome(outcome)
        let curiosityBinding = ownerCuriosityPlaybackBindings.consumeBinding(
            forAudibleInputItemID: outcome.inputItemID
        )
        let agencyPlanningResponseID = outcome.inputItemID.flatMap {
            agencyPlanningResponseByInputItem[$0]
        }
        let curiosityEffectEvidence = AgencyCuriosityEffectEvidence.resolve(
            boundPlanningResponseID: curiosityBinding?.planningResponseID,
            expectedPlanningResponseID: agencyPlanningResponseID
                ?? curiosityBinding?.planningResponseID,
            exactQuestion: curiosityBinding?.exactQuestion,
            generatedText: outcome.generatedText
        )
        reconcileAgencyMove(
            with: outcome,
            curiosityBinding: curiosityBinding,
            curiosityEffectEvidence: curiosityEffectEvidence
        )
        reconcilePrivateLifeShare(with: outcome)
        reconcileOwnerUnderstandingQuestion(
            with: outcome,
            curiosityBinding: curiosityBinding,
            curiosityEffectEvidence: curiosityEffectEvidence
        )
        if let deliveryID = outcome.backgroundTaskDeliveryID {
            acceptDelegateTaskSpeechDelivery(
                deliveryID: deliveryID,
                fullyPlayed: outcome.fullyPlayed
            )
        }
        var shouldCompleteAutomaticRest = false
        if let inputItemID = outcome.inputItemID {
            if outcome.fullyPlayed {
                addressedInputItems.insert(inputItemID)
                pendingOutcomes[inputItemID, default: []].append(.spoken(
                    itemID: outcome.itemID,
                    text: outcome.generatedText
                ))
                if userTranscripts[inputItemID] == nil {
                    fullyPlayedInputItemsAwaitingTranscript.insert(inputItemID)
                }
                shouldCompleteAutomaticRest = pendingAutomaticRest?.inputItemID == inputItemID
            } else if !outcome.fullyPlayed, (outcome.playedMilliseconds ?? 0) > 0 {
                addressedInputItems.insert(inputItemID)
                pendingOutcomes[inputItemID, default: []].append(.interrupted(itemID: outcome.itemID))
            }
            flushCompletedTurn(inputItemID)
        } else if outcome.fullyPlayed {
            rememberRecent(role: "Aurora", text: outcome.generatedText)
            if markInnerLifeOutcome(outcome.itemID) {
                enqueueInnerLifeEvents([InnerLifeEvent(
                    id: "heard:\(outcome.itemID)",
                    kind: .auroraSpeechHeard(
                        text: outcome.generatedText,
                        sourceID: outcome.itemID,
                        ownerSourceID: nil
                    )
                )])
            }
        } else if !outcome.fullyPlayed,
                  (outcome.playedMilliseconds ?? 0) > 0,
                  markInnerLifeOutcome(outcome.itemID) {
            enqueueInnerLifeEvents([InnerLifeEvent(
                id: "interrupted:\(outcome.itemID)",
                kind: .auroraSpeechInterrupted(sourceID: outcome.itemID)
            )])
        }

        let sessionID = localSessionID
        if outcome.fullyPlayed {
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "aurora_spoken_final",
                    sessionID: sessionID,
                    detail: String(outcome.generatedText.prefix(8_000)),
                    metadata: ["item_id": outcome.itemID]
                ))
            }
        } else {
            Task {
                await eventJournal.append(AuroraJournalEvent(
                    kind: "aurora_speech_interrupted",
                    sessionID: sessionID,
                    detail: "Aurora's generated speech did not finish playing.",
                    metadata: [
                        "item_id": outcome.itemID,
                        "generated_characters": String(outcome.generatedText.count),
                        "heard_milliseconds": String(outcome.playedMilliseconds ?? 0),
                    ]
                ))
            }
        }

        if shouldCompleteAutomaticRest, let inputItemID = outcome.inputItemID {
            completeAutomaticRest(after: inputItemID)
        }
    }

    private func reconcileAgencyMove(
        with outcome: RealtimeAssistantPlaybackOutcome,
        curiosityBinding: OwnerCuriosityPlaybackBinding?,
        curiosityEffectEvidence: AgencyCuriosityEffectEvidence
    ) {
        guard let inputItemID = outcome.inputItemID,
              let planningResponseID = agencyPlanningResponseByInputItem
                .removeValue(forKey: inputItemID) else { return }
        let boundEffectEvidence: AgencyCuriosityEffectEvidence
        if let curiosityBinding,
           curiosityBinding.planningResponseID == planningResponseID {
            boundEffectEvidence = curiosityEffectEvidence
        } else {
            boundEffectEvidence = .unavailable
        }
        let runtime = agency
        let playbackEventID = "agency-playback-\(outcome.itemID)"
        Task { [weak self, runtime] in
            let snapshot: AgencySnapshot?
            if outcome.fullyPlayed {
                snapshot = try? await runtime.settlePlayback(
                    responseID: planningResponseID,
                    generatedText: outcome.generatedText,
                    curiosityEffectEvidence: boundEffectEvidence,
                    playbackEventID: playbackEventID
                )
            } else {
                snapshot = try? await runtime.interruptPlayback(
                    responseID: planningResponseID,
                    playbackEventID: playbackEventID
                )
            }
            guard snapshot?.available == true else { return }
            let moveWasSettled = snapshot?.state?.authoredMoves.first(where: {
                $0.responseID == planningResponseID
            })?.status == .fullyPlayed
            let effectOutcome = snapshot?.state?.playbackReceipts.last(where: {
                $0.responseID == planningResponseID
                    && $0.playbackEventID == playbackEventID
            })?.effectOutcome
            await self?.eventJournal.append(AuroraJournalEvent(
                kind: moveWasSettled
                    ? "agency_move_fully_heard"
                    : "agency_move_interrupted",
                sessionID: self?.localSessionID,
                detail: moveWasSettled
                    ? "The audio for Aurora's authored conversational move was fully delivered; exact disclosure and curiosity effects were separately content-verified."
                    : "Aurora's unheard, interrupted, or omitted authored move was rolled back without disclosing held material.",
                metadata: [
                    "planning_response_id": planningResponseID,
                    "effect_outcome": effectOutcome?.rawValue ?? "legacy_or_unavailable",
                ]
            ))
            await MainActor.run { self?.scheduleInnerLifeProjectionRefresh() }
        }
    }

    private func interruptPendingAgencyMoves(reason: String) {
        guard !agencyPlanningResponseByInputItem.isEmpty else { return }
        let pending = agencyPlanningResponseByInputItem
        agencyPlanningResponseByInputItem.removeAll()
        let runtime = agency
        Task { [runtime] in
            for (inputItemID, planningResponseID) in pending {
                _ = try? await runtime.interruptPlayback(
                    responseID: planningResponseID,
                    playbackEventID: "agency-\(reason)-\(inputItemID)"
                )
            }
        }
    }

    private func rememberAssistantPlaybackOutcome(
        _ outcome: RealtimeAssistantPlaybackOutcome
    ) {
        if assistantPlaybackByResponseID[outcome.responseID] == nil {
            assistantPlaybackResponseOrder.append(outcome.responseID)
        }
        assistantPlaybackByResponseID[outcome.responseID] = outcome
        while assistantPlaybackResponseOrder.count > 64 {
            let expired = assistantPlaybackResponseOrder.removeFirst()
            assistantPlaybackByResponseID.removeValue(forKey: expired)
        }
    }

    private func reconcilePrivateLifeShare(
        with outcome: RealtimeAssistantPlaybackOutcome
    ) {
        guard let sessionID = localSessionID else { return }
        let runtime = privateLife
        Task { [weak self, runtime] in
            let snapshot = await runtime.reconcileSpokenShare(
                sessionID: sessionID,
                responseID: outcome.responseID,
                audioItemID: outcome.itemID,
                generatedText: outcome.generatedText,
                fullySpoken: outcome.fullyPlayed
            )
            guard let self else { return }
            let recorded = snapshot.state?.shareReceipts.contains(where: {
                $0.sessionID == sessionID
                    && $0.responseID == outcome.responseID
                    && $0.audioItemID == outcome.itemID
                    && $0.fullySpoken == outcome.fullyPlayed
            }) == true
            if recorded {
                self.scheduleInnerLifeProjectionRefresh()
            }
        }
    }

    /// A curiosity becomes "asked" only when its exact model-authored question
    /// is present in the completed assistant transcript and that audio was
    /// fully delivered. Calling this both from playback and after tool commit
    /// closes the harmless playback-before-function-result race.
    private func reconcileOwnerUnderstandingQuestion(
        with outcome: RealtimeAssistantPlaybackOutcome,
        curiosityBinding: OwnerCuriosityPlaybackBinding?,
        curiosityEffectEvidence: AgencyCuriosityEffectEvidence
    ) {
        let planningResponseID = curiosityBinding?.planningResponseID
            ?? outcome.responseID
        let runtime = ownerUnderstanding
        Task { [weak self, runtime] in
            let before = await runtime.snapshot()
            guard let pending = before.state?.curiosities.first(where: {
                $0.status == .pendingAsk && $0.pendingResponseID == planningResponseID
            }) else { return }
            let questionWasGenerated = curiosityEffectEvidence == .matched
                && curiosityBinding?.planningResponseID == planningResponseID
                && curiosityBinding?.exactQuestion == pending.question
            guard let result = try? await runtime.reconcilePlayback(
                responseID: planningResponseID,
                fullyPlayed: outcome.fullyPlayed && questionWasGenerated,
                playbackEventID: "owner-question-\(outcome.itemID)"
            ) else { return }
            guard result.affectedID != nil else { return }
            await self?.eventJournal.append(AuroraJournalEvent(
                kind: outcome.fullyPlayed && questionWasGenerated
                    ? "owner_curiosity_heard"
                    : "owner_curiosity_not_fully_heard",
                sessionID: self?.localSessionID,
                detail: outcome.fullyPlayed && questionWasGenerated
                    ? "One grounded relational question was fully heard."
                    : "The relational question remained open because its audio was not fully verified.",
                metadata: [
                    "planning_response_id": planningResponseID,
                    "audible_response_id": outcome.responseID,
                ]
            ))
            await MainActor.run { self?.scheduleInnerLifeProjectionRefresh() }
        }
    }

    private func interruptPendingOwnerQuestions(reason: String) {
        let pending = ownerCuriosityPlaybackBindings.drain()
        guard !pending.isEmpty else { return }
        let runtime = ownerUnderstanding
        Task { [runtime] in
            for binding in pending {
                _ = try? await runtime.reconcilePlayback(
                    responseID: binding.planningResponseID,
                    fullyPlayed: false,
                    playbackEventID: "owner-question-\(reason)-\(binding.inputItemID)"
                )
            }
        }
    }

    private nonisolated static func normalizedPlaybackText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func armAutomaticRest(
        after inputItemID: String,
        intent: ConversationClosingIntent
    ) {
        guard let connectionID = activeConnectionID,
              wantsAwake,
              !userSpeechActive else { return }
        let pending = PendingAutomaticRest(
            inputItemID: inputItemID,
            intent: intent,
            connectionID: connectionID,
            lifecycleID: lifecycleID
        )
        pendingAutomaticRest = pending
        automaticRestFallbackTask?.cancel()
        automaticRestFallbackTask = Task { [weak self] in
            // This path is only a deadlock guard. The normal transition is the
            // matching, fully played Aurora response above.
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self else { return }
            for _ in 0..<70 {
                guard self.pendingAutomaticRest?.inputItemID == inputItemID,
                      self.pendingAutomaticRest?.connectionID == connectionID,
                      self.pendingAutomaticRest?.lifecycleID == pending.lifecycleID else { return }
                if self.phase != .speaking && self.phase != .thinking {
                    self.completeAutomaticRest(after: inputItemID)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            // A permanently wedged response must not leave Aurora's paid live
            // session and microphone open forever after an explicit goodbye.
            self.completeAutomaticRest(after: inputItemID)
        }
    }

    private func completeAutomaticRest(after inputItemID: String) {
        guard let pending = pendingAutomaticRest,
              pending.inputItemID == inputItemID,
              pending.connectionID == activeConnectionID,
              pending.lifecycleID == lifecycleID,
              wantsAwake else { return }

        let sessionID = localSessionID
        automaticRestFallbackTask?.cancel()
        automaticRestFallbackTask = nil
        pendingAutomaticRest = nil
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: "voice_sleep_phrase_completed",
                sessionID: sessionID,
                detail: "Aurora finished the leave-taking exchange and returned to local wake-word rest.",
                metadata: [
                    "input_item_id": inputItemID,
                    "intent": pending.intent.rawValue,
                ]
            ))
        }
        rest()
    }

    private func cancelPendingAutomaticRest() {
        pendingAutomaticRest = nil
        automaticRestFallbackTask?.cancel()
        automaticRestFallbackTask = nil
    }

    private func flushCompletedTurn(_ inputItemID: String) {
        guard let outcomes = pendingOutcomes[inputItemID], !outcomes.isEmpty else { return }
        let hasAddressedOutcome = outcomes.contains { outcome in
            switch outcome {
            case .spoken, .interrupted, .addressedModel, .addressedTool: return true
            case .quiet, .unresolved: return false
            }
        }
        let hasQuietOutcome = outcomes.contains { outcome in
            if case .quiet = outcome { return true }
            return false
        }
        let hasUnresolvedOutcome = outcomes.contains { outcome in
            if case .unresolved = outcome { return true }
            return false
        }
        let transcriptIsFinal = userTranscripts[inputItemID] != nil
            || transcriptUnavailableItems.contains(inputItemID)
        guard hasAddressedOutcome ? transcriptIsFinal : (hasQuietOutcome || hasUnresolvedOutcome) else { return }

        if inputCommittedAt[inputItemID] != nil {
            completedTurnsReady.insert(inputItemID)
            drainCompletedTurnsInCommitOrder()
        } else {
            processCompletedTurn(inputItemID, committedAt: Date())
        }
    }

    private func drainCompletedTurnsInCommitOrder() {
        while let inputItemID = committedInputOrder.first,
              completedTurnsReady.contains(inputItemID) {
            committedInputOrder.removeFirst()
            completedTurnsReady.remove(inputItemID)
            let committedAt = inputCommittedAt.removeValue(forKey: inputItemID) ?? Date()
            processCompletedTurn(inputItemID, committedAt: committedAt)
        }
    }

    private func processCompletedTurn(_ inputItemID: String, committedAt: Date) {
        if mergedTailArtifactItems.contains(inputItemID) {
            // This commit is the duplicated assistant-tail half of the next
            // acoustic turn. It has no independent participant, outcome, or
            // lived-event meaning, but remains in bounded participant replay
            // so a genuinely late transcript can still correct provenance.
            pendingOutcomes.removeValue(forKey: inputItemID)
            completedInputHistory.append(inputItemID)
            trimTurnState()
            return
        }
        guard var outcomes = pendingOutcomes[inputItemID], !outcomes.isEmpty else { return }
        let hasAddressedOutcome = outcomes.contains { outcome in
            switch outcome {
            case .spoken, .interrupted, .addressedModel, .addressedTool: return true
            case .quiet, .unresolved: return false
            }
        }
        let hasQuietOutcome = outcomes.contains { outcome in
            if case .quiet = outcome { return true }
            return false
        }
        let hasUnresolvedOutcome = outcomes.contains { outcome in
            if case .unresolved = outcome { return true }
            return false
        }

        let participant = participantByInputItem[inputItemID] ?? participantTracker.current
        var innerLifeEvents: [InnerLifeEvent] = []
        if hasAddressedOutcome,
           innerLifeParticipantItems.insert(inputItemID).inserted {
            let participantKind: InnerLifeEventKind
            switch participant {
            case .owner:
                innerLifeOwnerItems.insert(inputItemID)
                if let userText = userTranscripts[inputItemID] {
                    participantKind = .ownerSpeech(text: userText, sourceID: inputItemID)
                } else {
                    participantKind = .ownerContactWithoutTranscript(sourceID: inputItemID)
                }
            case .guest(let displayName):
                participantKind = .guestSpeech(
                    text: userTranscripts[inputItemID] ?? "",
                    displayName: displayName,
                    sourceID: inputItemID
                )
            case .unknown:
                participantKind = .guestSpeech(
                    text: userTranscripts[inputItemID] ?? "",
                    displayName: nil,
                    sourceID: inputItemID
                )
            }
            innerLifeEvents.append(InnerLifeEvent(
                id: "participant:\(inputItemID)",
                at: committedAt,
                kind: participantKind
            ))
        }
        if hasQuietOutcome, innerLifeQuietItems.insert(inputItemID).inserted {
            innerLifeEvents.append(InnerLifeEvent(
                id: "quiet:\(inputItemID)",
                at: committedAt,
                kind: .quietTurn(sourceID: inputItemID)
            ))
        }
        let unresolvedID = "unresolved:\(inputItemID)"
        if hasUnresolvedOutcome, markInnerLifeOutcome(unresolvedID) {
            innerLifeEvents.append(InnerLifeEvent(
                id: unresolvedID,
                at: committedAt,
                kind: .unresolvedAudio(sourceID: inputItemID)
            ))
        }

        if hasAddressedOutcome,
           let userText = userTranscripts[inputItemID],
           introducedTurnItems.insert(inputItemID).inserted {
            rememberRecent(
                role: "\(participant.continuityLabel) (asynchronous voice transcription; may be imperfect)",
                text: userText
            )
        }
        var privateLifeSpokenOutcome: (itemID: String, text: String)?
        for outcome in outcomes {
            switch outcome {
            case .spoken(let itemID, let text):
                if privateLifeSpokenOutcome == nil {
                    privateLifeSpokenOutcome = (itemID, text)
                }
                rememberRecent(role: "Aurora (heard in full)", text: text)
                if markInnerLifeOutcome(itemID) {
                    innerLifeEvents.append(InnerLifeEvent(
                        id: "heard:\(itemID)",
                        kind: .auroraSpeechHeard(
                            text: text,
                            sourceID: itemID,
                            ownerSourceID: inputItemID
                        )
                    ))
                }
            case .interrupted(let itemID):
                recentConversation.append("Aurora: [speech interrupted before completion]")
                if markInnerLifeOutcome(itemID) {
                    innerLifeEvents.append(InnerLifeEvent(
                        id: "interrupted:\(itemID)",
                        kind: .auroraSpeechInterrupted(sourceID: itemID)
                    ))
                }
            case .addressedModel, .addressedTool:
                break
            case .quiet:
                recentConversation.append("Aurora: [intentionally stayed quiet]")
            case .unresolved:
                recentConversation.append("[voice turn ended before its addressee could be resolved]")
            }
        }
        if let userText = userTranscripts[inputItemID],
           let spoken = privateLifeSpokenOutcome,
           privateLifeExchangeItems.insert(inputItemID).inserted {
            let hadToolCallInCurrentPass = outcomes.contains { outcome in
                if case .addressedTool = outcome { return true }
                return false
            }
            let hadToolCall = hadToolCallInCurrentPass
                || toolAddressedInputItems.contains(inputItemID)
            enqueuePrivateLifeExchange(
                participant: participant,
                ownerText: userText,
                auroraText: spoken.text,
                ownerSourceID: inputItemID,
                auroraSourceID: spoken.itemID,
                context: PrivateLifeExchangeContext(
                    interactionKind: hadToolCall ? .toolDirected : .conversational,
                    hadToolCall: hadToolCall,
                    wasTaskFocused: hadToolCall,
                    transcriptConfidence: nil
                ),
                at: committedAt
            )
            toolAddressedInputItems.consume(inputItemID)
        }
        enqueueInnerLifeEvents(innerLifeEvents)
        outcomes.removeAll()
        pendingOutcomes.removeValue(forKey: inputItemID)
        completedInputHistory.append(inputItemID)
        trimTurnState()
        if recentConversation.count > 30 {
            recentConversation.removeFirst(recentConversation.count - 30)
        }
    }

    private func acceptFunctionCall(_ call: RealtimeFunctionCall) {
        let sourceLogicalSessionID = logicalSessionByConnectionID[call.connectionID]
        let durableDelegate = DelegateTaskTransportPolicy.isDurableDelegate(
            toolName: call.name,
            authorizationSource: call.authorizationSource,
            inputItemID: call.inputItemID,
            sourceTurnFinalized: call.sourceTurnFinalized,
            wantsAwake: wantsAwake,
            sourceLogicalSessionID: sourceLogicalSessionID,
            currentLogicalSessionID: localSessionID
        )
        guard DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
            callConnectionID: call.connectionID,
            activeConnectionID: activeConnectionID,
            durableDelegate: durableDelegate,
            wantsAwake: wantsAwake,
            sourceLogicalSessionID: sourceLogicalSessionID,
            currentLogicalSessionID: localSessionID
        ) else { return }
        // Callback delivery is asynchronous. New speech may supersede a turn
        // after Realtime accepted a call but before this method runs. Re-check
        // the committed input's generation here—the final boundary before any
        // local tool Task exists—so a delayed callback cannot resurrect an old
        // click, shortcut, send, or other effect.
        if let inputItemID = call.inputItemID, !durableDelegate {
            guard speechGenerationByInputItem[inputItemID] == ownerSpeechGeneration else {
                return
            }
        } else if call.inputItemID == nil {
            guard !userSpeechActive else { return }
        }
        if durableDelegate {
            durableDelegateToolCallIDs.insert(call.callID)
        }
        if !ToolRegistry.isSilentTerminalTool(call.name),
           call.name != "owner_understanding_update",
           call.name != "conversation_move",
           let inputItemID = call.inputItemID {
            addressedInputItems.insert(inputItemID)
            toolAddressedInputItems.mark(inputItemID)
            pendingOutcomes[inputItemID, default: []].append(.addressedTool)
            flushCompletedTurn(inputItemID)
        }
        if durableDelegate {
            // Realtime carried the finalized boundary on the call itself.
            // Per-transport transcript caches may already have been cleared by
            // a reconnect, but that must not turn committed work back into an
            // unfinalized or indefinitely pending request.
            let evidence = call.inputItemID.flatMap { userTranscripts[$0] }
            startToolExecution(call, evidence: evidence, sourceTurnFinalized: true)
            return
        }
        if ToolEvidencePolicy.requiresFinalizedTranscript(call.name),
           let inputItemID = call.inputItemID {
            if let evidence = userTranscripts[inputItemID] {
                startToolExecution(call, evidence: evidence, sourceTurnFinalized: true)
            } else if transcriptUnavailableItems.contains(inputItemID) {
                startToolExecution(call, evidence: nil, sourceTurnFinalized: true)
            } else {
                pendingEvidenceCalls[inputItemID, default: []].append(call)
                scheduleEvidenceTimeout(for: call, inputItemID: inputItemID)
            }
            return
        }
        let evidence = call.inputItemID.flatMap { userTranscripts[$0] }
        startToolExecution(call, evidence: evidence, sourceTurnFinalized: true)
    }

    private func scheduleEvidenceTimeout(for call: RealtimeFunctionCall, inputItemID: String) {
        evidenceWaitTasks[call.callID]?.cancel()
        let token = lifecycleID
        evidenceWaitTasks[call.callID] = Task { [weak self] in
            do {
                // Realtime already holds tool-bearing response.done events for
                // asynchronous transcription. This is only a final race guard;
                // eight seconds made a healthy voice command feel broken.
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
            guard let self,
                  self.wantsAwake,
                  token == self.lifecycleID,
                  call.connectionID == self.activeConnectionID else { return }
            self.removePendingEvidenceCall(callID: call.callID, from: inputItemID)
            self.evidenceWaitTasks.removeValue(forKey: call.callID)
            self.startToolExecution(call, evidence: nil, sourceTurnFinalized: false)
        }
    }

    private func releasePendingEvidenceCalls(for inputItemID: String, evidence: String?) {
        let calls = pendingEvidenceCalls.removeValue(forKey: inputItemID) ?? []
        for call in calls {
            evidenceWaitTasks.removeValue(forKey: call.callID)?.cancel()
            startToolExecution(call, evidence: evidence, sourceTurnFinalized: true)
        }
    }

    private func removePendingEvidenceCall(callID: String, from inputItemID: String) {
        guard var calls = pendingEvidenceCalls[inputItemID] else { return }
        calls.removeAll { $0.callID == callID }
        if calls.isEmpty {
            pendingEvidenceCalls.removeValue(forKey: inputItemID)
        } else {
            pendingEvidenceCalls[inputItemID] = calls
        }
    }

    private func startToolExecution(
        _ call: RealtimeFunctionCall,
        evidence: String?,
        sourceTurnFinalized: Bool
    ) {
        let finalizedOwnerUnderstanding = call.name == "owner_understanding_update"
            && sourceTurnFinalized
            && call.authorizationSource == .directOwnerTurn
            && call.inputItemID != nil
            && call.inputItemID.flatMap { participantByInputItem[$0] }?.isOwner == true
            && evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if finalizedOwnerUnderstanding {
            durableOwnerUnderstandingToolCallIDs.insert(call.callID)
        }
        let durableDelegate = durableDelegateToolCallIDs.contains(call.callID)
        let sourceLogicalSessionID = logicalSessionByConnectionID[call.connectionID]
        guard DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
            callConnectionID: call.connectionID,
            activeConnectionID: activeConnectionID,
            durableDelegate: durableDelegate,
            wantsAwake: wantsAwake,
            sourceLogicalSessionID: sourceLogicalSessionID,
            currentLogicalSessionID: localSessionID
        ),
              toolTasks[call.callID] == nil else {
            durableDelegateToolCallIDs.remove(call.callID)
            durableOwnerUnderstandingToolCallIDs.remove(call.callID)
            return
        }
        let token = lifecycleID
        let sessionID = logicalSessionByConnectionID[call.connectionID] ?? localSessionID
        toolTasks[call.callID] = Task { [weak self] in
            guard let self else { return }
            let durableDelegate = self.durableDelegateToolCallIDs.contains(call.callID)
            let durableOwnerUnderstanding = self.durableOwnerUnderstandingToolCallIDs
                .contains(call.callID)
            let survivesTransportReplacement = DelegateTaskTransportPolicy
                .mayExecuteAcrossTransportBoundary(
                    callConnectionID: call.connectionID,
                    activeConnectionID: self.activeConnectionID,
                    durableDelegate: durableDelegate,
                    wantsAwake: self.wantsAwake,
                    sourceLogicalSessionID: sessionID,
                    currentLogicalSessionID: self.localSessionID
                )
            let survivesOwnerUnderstandingBargeIn = durableOwnerUnderstanding
                && self.wantsAwake
                && sessionID != nil
                && sessionID == self.localSessionID
            guard !Task.isCancelled,
                  survivesTransportReplacement || survivesOwnerUnderstandingBargeIn || (
                    self.wantsAwake
                        && token == self.lifecycleID
                        && call.connectionID == self.activeConnectionID
                  ) else {
                self.toolTasks.removeValue(forKey: call.callID)
                self.durableDelegateToolCallIDs.remove(call.callID)
                self.durableOwnerUnderstandingToolCallIDs.remove(call.callID)
                return
            }
            let relationshipTool = [
                "relationship_expect_quiet",
                "relationship_explain_absence",
            ].contains(call.name)
            var result = await self.toolRegistry.execute(
                name: call.name,
                argumentsJSON: call.argumentsJSON,
                context: ToolInvocationContext(
                    callID: call.callID,
                    sessionID: sessionID,
                    origin: DelegateTaskAuthorizationFactory.trustedVoiceOrigin,
                    latestUserTranscript: evidence,
                    ownerAudioItemID: call.inputItemID,
                    participantIsOwner: call.inputItemID.flatMap {
                        self.participantByInputItem[$0]
                    }?.isOwner ?? self.participantTracker.current.isOwner,
                    audioCorroborated: call.audioCorroborated,
                    sourceTurnFinalized: sourceTurnFinalized,
                    authorizationSource: call.authorizationSource,
                    assistantResponseID: call.responseID,
                    turnAlreadySpoke: call.turnAlreadySpoke,
                    preauthorizedDelegateBinding: call.preauthorizedDelegateBinding
                )
            )
            let conversationMoveCompletionIsCurrent = ConversationMoveCompletionBoundary
                .turnIsCurrent(
                    taskIsCancelled: Task.isCancelled,
                    wantsAwake: self.wantsAwake,
                    expectedLifecycleID: token,
                    currentLifecycleID: self.lifecycleID,
                    sourceConnectionID: call.connectionID,
                    activeConnectionID: self.activeConnectionID
                )
            if call.name == "conversation_move",
               result.ok,
               let inputItemID = call.inputItemID,
               let planningResponseID = result.metadata[
                "agency_planning_response_id"
               ]?.stringValue {
                let resolution = ConversationMoveCompletionBoundary.resolvePreparedMove(
                    inputItemID: inputItemID,
                    planningResponseID: planningResponseID,
                    turnIsCurrent: conversationMoveCompletionIsCurrent,
                    bindings: &self.agencyPlanningResponseByInputItem
                )
                let planningResponseToInterrupt: String?
                switch resolution {
                case .installed(let replacedPlanningResponseID):
                    planningResponseToInterrupt = replacedPlanningResponseID
                case .stale(let stalePlanningResponseID):
                    planningResponseToInterrupt = stalePlanningResponseID
                }
                if let planningResponseToInterrupt {
                    _ = try? await self.agency.interruptPlayback(
                        responseID: planningResponseToInterrupt,
                        playbackEventID: conversationMoveCompletionIsCurrent
                            ? "agency-replaced-\(inputItemID)"
                            : "agency-stale-completion-\(inputItemID)"
                    )
                }
            }
            if call.name == "private_life_share",
               result.metadata["private_life_share_pending"]?.boolValue == true,
               let playback = self.assistantPlaybackByResponseID[call.responseID] {
                self.reconcilePrivateLifeShare(with: playback)
            }
            if call.name == "owner_understanding_update",
               result.metadata["owner_curiosity_pending"]?.boolValue == true,
               let playback = self.assistantPlaybackByResponseID[call.responseID] {
                self.reconcileOwnerUnderstandingQuestion(
                    with: playback,
                    curiosityBinding: nil,
                    curiosityEffectEvidence: .unavailable
                )
            }
            if relationshipTool,
               result.ok,
               let inputItemID = call.inputItemID,
               !(await self.waitForCausallyRecordedOwnerTurn(
                inputItemID,
                lifecycleToken: token,
                connectionID: call.connectionID
               )) {
                result = ToolExecutionResult(
                    ok: false,
                    output: "Aurora could not establish the turn's durable causal order, so relationship continuity was not changed."
                )
            }
            let turnIsCurrent = ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: Task.isCancelled,
                wantsAwake: self.wantsAwake,
                expectedLifecycleID: token,
                currentLifecycleID: self.lifecycleID,
                sourceConnectionID: call.connectionID,
                activeConnectionID: self.activeConnectionID
            )
            let completedExternalSideEffect = AuroraToolEffectTruth
                .shouldPreserveAfterTurn(result)

            // A tool may have changed the world just as Rest or barge-in
            // cancelled its stale conversational continuation. Preserve it
            // only when the receipt explicitly reports an external side effect;
            // neither a tool name nor `ok` is proof. Relationship tools remain
            // validation until the current turn durably commits them below.
            if turnIsCurrent || completedExternalSideEffect {
                var innerLifeEvents: [InnerLifeEvent] = []
                var relationshipEventID: String?
                if call.name == "relationship_expect_quiet",
                   result.ok,
                   result.metadata["source_quote_validated"]?.boolValue == true,
                   let startsAtText = result.metadata["relationship_starts_at"]?.stringValue,
                   let startsAt = parseISO8601(startsAtText),
                   let untilText = result.metadata["relationship_until"]?.stringValue,
                   let until = parseISO8601(untilText),
                   let explicitPromise = result.metadata["explicit_return_promise"]?.boolValue {
                    let eventID = "expected-quiet:\(call.callID)"
                    relationshipEventID = eventID
                    innerLifeEvents.append(InnerLifeEvent(
                        id: eventID,
                        kind: .ownerExpectedQuiet(
                            startsAt: startsAt,
                            until: until,
                            explicitPromise: explicitPromise,
                            sourceID: call.inputItemID ?? call.callID
                        )
                    ))
                }
                if call.name == "relationship_explain_absence",
                   result.ok,
                   result.metadata["source_quote_validated"]?.boolValue == true {
                    let eventID = "absence-explained:\(call.callID)"
                    relationshipEventID = eventID
                    innerLifeEvents.append(InnerLifeEvent(
                        id: eventID,
                        kind: .ownerExplainedAbsence(
                            sourceID: call.inputItemID ?? call.callID
                        )
                    ))
                }
                if let learning = AuroraToolEffectTruth.completionLearning(
                    toolName: call.name,
                    result: result
                ) {
                    innerLifeEvents.append(InnerLifeEvent(
                        id: "tool:\(call.callID)",
                        kind: .toolCompleted(
                            name: call.name,
                            succeeded: learning.succeeded,
                            sourceID: call.callID,
                            ownerSourceID: call.inputItemID
                        )
                    ))
                }
                if call.name == "memory_remember", result.ok {
                    innerLifeEvents.append(InnerLifeEvent(
                        id: "memory:\(call.callID)",
                        kind: .memoryCommitted(sourceID: call.callID)
                    ))
                }
                let pendingInnerLifeEvents = self.enqueueInnerLifeEvents(innerLifeEvents)
                let snapshot = await pendingInnerLifeEvents?.value
                if relationshipTool, result.ok {
                    let persisted = snapshot?.available == true
                        && relationshipEventID.map {
                            snapshot?.state?.recentEventIDs.contains($0) == true
                        } == true
                    if persisted {
                        let output = call.name == "relationship_expect_quiet"
                            ? "Expected quiet was recorded in Aurora's continuity."
                            : "The owner's grounded explanation was recorded in Aurora's continuity."
                        result = ToolExecutionResult(
                            ok: true,
                            output: output,
                            metadata: result.metadata
                        )
                    } else {
                        result = ToolExecutionResult(
                            ok: false,
                            output: "Aurora could not durably update relationship continuity, so nothing was claimed as recorded."
                        )
                    }
                }
            }
            let canReturnToOriginTransport = ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: Task.isCancelled,
                wantsAwake: self.wantsAwake,
                expectedLifecycleID: token,
                currentLifecycleID: self.lifecycleID,
                sourceConnectionID: call.connectionID,
                activeConnectionID: self.activeConnectionID
            )
            let hasPendingConversationQuestion = call.name == "conversation_move"
                && result.ok
                && result.metadata["owner_curiosity_pending"]?.boolValue == true
            if hasPendingConversationQuestion,
               !canReturnToOriginTransport,
               let inputItemID = call.inputItemID {
                _ = try? await self.ownerUnderstanding.reconcilePlayback(
                    responseID: call.responseID,
                    fullyPlayed: false,
                    playbackEventID: "owner-question-stale-\(inputItemID)"
                )
            }
            let taskStillBelongsToLogicalSession = DelegateTaskTransportPolicy
                .mayExecuteAcrossTransportBoundary(
                    callConnectionID: call.connectionID,
                    activeConnectionID: self.activeConnectionID,
                    durableDelegate: durableDelegate,
                    wantsAwake: self.wantsAwake,
                    sourceLogicalSessionID: sessionID,
                    currentLogicalSessionID: self.localSessionID
                )
            let ownerUnderstandingStillBelongsToLogicalSession = self
                .durableOwnerUnderstandingToolCallIDs.contains(call.callID)
                && self.wantsAwake
                && sessionID != nil
                && sessionID == self.localSessionID
            guard !Task.isCancelled,
                  canReturnToOriginTransport
                    || taskStillBelongsToLogicalSession
                    || ownerUnderstandingStillBelongsToLogicalSession else {
                self.toolTasks.removeValue(forKey: call.callID)
                self.durableDelegateToolCallIDs.remove(call.callID)
                self.durableOwnerUnderstandingToolCallIDs.remove(call.callID)
                return
            }
            if canReturnToOriginTransport {
                if hasPendingConversationQuestion,
                   let inputItemID = call.inputItemID {
                    if let exactQuestion = result.metadata[
                        "owner_curiosity_exact_question"
                    ]?.stringValue {
                        if let previous = self.ownerCuriosityPlaybackBindings.bind(
                            inputItemID: inputItemID,
                            planningResponseID: call.responseID,
                            exactQuestion: exactQuestion
                        ), previous != call.responseID {
                            _ = try? await self.ownerUnderstanding.reconcilePlayback(
                                responseID: previous,
                                fullyPlayed: false,
                                playbackEventID: "owner-question-replaced-\(inputItemID)"
                            )
                        }
                    } else {
                        _ = try? await self.ownerUnderstanding.reconcilePlayback(
                            responseID: call.responseID,
                            fullyPlayed: false,
                            playbackEventID: "owner-question-unbound-\(inputItemID)"
                        )
                    }
                }
                self.realtime.submitFunctionResult(
                    connectionID: call.connectionID,
                    callID: call.callID,
                    output: result.realtimeOutputJSON(),
                    continuation: ToolRegistry.continuation(
                        for: call.name,
                        result: result,
                        turnAlreadySpoke: call.turnAlreadySpoke
                    )
                )
            }
            let continuityChanged = result.metadata["continuity_changed"]?.boolValue == true
            let ownerUnderstandingChanged = result.metadata["owner_understanding_changed"]?.boolValue == true
            self.toolTasks.removeValue(forKey: call.callID)
            self.durableDelegateToolCallIDs.remove(call.callID)
            self.durableOwnerUnderstandingToolCallIDs.remove(call.callID)
            if continuityChanged {
                self.scheduleContinuityProjectionRefresh()
            }
            if ownerUnderstandingChanged {
                self.scheduleInnerLifeProjectionRefresh()
            }
        }
    }

    private func waitForCausallyRecordedOwnerTurn(
        _ inputItemID: String,
        lifecycleToken: UUID,
        connectionID: UUID
    ) async -> Bool {
        for _ in 0..<160 {
            guard !Task.isCancelled,
                  wantsAwake,
                  lifecycleToken == lifecycleID,
                  connectionID == activeConnectionID else { return false }
            if innerLifeOwnerItems.contains(inputItemID) {
                let pending = innerLifeEventTask
                let snapshot = await pending?.value
                return snapshot?.available == true
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func acceptDelegateTaskEvent(_ event: DelegateTaskEvent) {
        let snapshot = event.snapshot
        Task {
            var metadata: [String: String] = [
                "task_id": snapshot.taskID,
                "task_kind": snapshot.taskKind.rawValue,
                "status": snapshot.status.rawValue,
                "revision": String(snapshot.revision),
                "steps": String(snapshot.stepCount),
                "effect_verified": String(snapshot.effectVerified),
            ]
            if let threadID = snapshot.codexThreadID {
                metadata["codex_thread_id"] = threadID
            }
            await eventJournal.append(AuroraJournalEvent(
                kind: "delegate_task_\(event.kind.rawValue)",
                sessionID: snapshot.sessionID,
                detail: "Aurora's bounded Codex task changed state.",
                metadata: metadata
            ))
        }

        guard snapshot.status.isTerminal else { return }
        // A finished Codex turn is not itself proof that the requested effect
        // succeeded. Record success only from independent host evidence, and
        // record an explicit runtime failure as failure. Leave an unverified
        // natural-language completion neutral for Aurora's inner life.
        if snapshot.effectVerified || snapshot.status == .failed {
            enqueueInnerLifeEvents([InnerLifeEvent(
                id: "delegate-task:\(snapshot.taskID):\(snapshot.status.rawValue)",
                kind: .toolCompleted(
                    name: "delegate_task",
                    succeeded: snapshot.effectVerified,
                    sourceID: snapshot.taskID,
                    ownerSourceID: nil
                )
            )])
        }

        // Direct Mac control belongs only to the live voice session that
        // authorized it. Persistent coding, research, and general work may
        // finish while Aurora rests; retain that exact terminal event so she
        // can naturally deliver it at the next listening boundary.
        let belongsToCurrentVoiceSession = wantsAwake
            && snapshot.sessionID == localSessionID
        guard belongsToCurrentVoiceSession
                || snapshot.taskKind.continuesAfterVoiceRest else { return }
        guard DelegateTaskVoiceDeliveryPolicy.deliveryClass(for: snapshot) != .silent else {
            pendingDelegateTaskEvents.removeValue(forKey: snapshot.taskID)
            return
        }
        pendingDelegateTaskEvents[snapshot.taskID] = event
        if wantsAwake { scheduleDelegateTaskPublicationRetry() }
    }

    private func attemptDelegateTaskEventPublication() {
        guard wantsAwake,
              sessionPrivacyEpoch.isOwner,
              phase == .listening,
              !userSpeechActive,
              pendingAutomaticRest == nil,
              publishingDelegateTaskEventID == nil,
              announcingDelegateTaskID == nil,
              let connectionID = activeConnectionID,
              let event = pendingDelegateTaskEvents.values.min(by: {
                  $0.snapshot.updatedAt < $1.snapshot.updatedAt
              }),
              event.snapshot.sessionID == localSessionID
                || event.snapshot.taskKind.continuesAfterVoiceRest else { return }

        delegateTaskPublishRetryTask?.cancel()
        delegateTaskPublishRetryTask = nil
        delegateTaskDeliveryTimeoutTask?.cancel()
        delegateTaskDeliveryTimeoutTask = nil
        let taskID = event.snapshot.taskID
        let deliveryID = "\(taskID):\(UUID().uuidString.lowercased())"
        let lifecycleToken = lifecycleID
        let speechGeneration = ownerSpeechGeneration
        publishingDelegateTaskEventID = taskID
        realtime.publishBackgroundTaskUpdate(
            connectionID: connectionID,
            deliveryID: deliveryID,
            text: delegateTaskContextText(event),
            deliveryClass: DelegateTaskVoiceDeliveryPolicy.deliveryClass(
                for: event.snapshot
            ),
            completion: { [weak self] accepted in
                Task { @MainActor in
                    guard let self else { return }
                    if self.publishingDelegateTaskEventID == taskID {
                        self.publishingDelegateTaskEventID = nil
                    }
                    guard self.wantsAwake,
                          lifecycleToken == self.lifecycleID,
                          connectionID == self.activeConnectionID else { return }
                    if accepted {
                        // The context can be acknowledged on the transport
                        // queue just as new owner speech supersedes it. Do not
                        // let that stale acknowledgement take the floor later.
                        guard speechGeneration == self.ownerSpeechGeneration,
                              !self.userSpeechActive else {
                            self.scheduleDelegateTaskPublicationRetry()
                            return
                        }
                        self.announcingDelegateTaskID = taskID
                        self.announcingDelegateTaskDeliveryID = deliveryID
                        self.announcingDelegateTaskEvent = event
                        self.scheduleDelegateTaskDeliveryTimeout(
                            taskID: taskID,
                            deliveryID: deliveryID
                        )
                        return
                    }
                    guard self.wantsAwake,
                          self.phase == .listening,
                          !self.pendingDelegateTaskEvents.isEmpty else { return }
                    self.scheduleDelegateTaskPublicationRetry()
                }
            }
        )
    }

    private func scheduleDelegateTaskPublicationRetry() {
        guard wantsAwake,
              sessionPrivacyEpoch.isOwner,
              !userSpeechActive,
              !pendingDelegateTaskEvents.isEmpty,
              publishingDelegateTaskEventID == nil,
              announcingDelegateTaskID == nil else { return }
        delegateTaskPublishRetryTask?.cancel()
        delegateTaskPublishRetryTask = Task { [weak self] in
            do {
                // The listening/user-speech guards already yield the floor to
                // the owner. Keep only a small natural beat instead of adding a full
                // second to every completed task announcement.
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.attemptDelegateTaskEventPublication()
        }
    }

    private func scheduleDelegateTaskDeliveryTimeout(
        taskID: String,
        deliveryID: String
    ) {
        delegateTaskDeliveryTimeoutTask?.cancel()
        delegateTaskDeliveryTimeoutTask = Task { [weak self] in
            do {
                // Realtime reports failed, empty, and interrupted deliveries
                // explicitly. This is only a last-resort lost-callback guard.
                try await Task.sleep(for: .seconds(90))
            } catch {
                return
            }
            guard let self,
                  self.announcingDelegateTaskID == taskID,
                  self.announcingDelegateTaskDeliveryID == deliveryID else { return }
            self.announcingDelegateTaskID = nil
            self.announcingDelegateTaskDeliveryID = nil
            self.announcingDelegateTaskEvent = nil
            self.delegateTaskDeliveryTimeoutTask = nil
            guard self.wantsAwake,
                  self.pendingDelegateTaskEvents[taskID] != nil else { return }
            self.scheduleDelegateTaskPublicationRetry()
        }
    }

    private func acceptDelegateTaskSpeechDelivery(
        deliveryID: String,
        fullyPlayed: Bool
    ) {
        guard announcingDelegateTaskDeliveryID == deliveryID,
              let taskID = announcingDelegateTaskID,
              let announcedEvent = announcingDelegateTaskEvent else { return }
        delegateTaskDeliveryTimeoutTask?.cancel()
        delegateTaskDeliveryTimeoutTask = nil
        announcingDelegateTaskID = nil
        announcingDelegateTaskDeliveryID = nil
        announcingDelegateTaskEvent = nil
        if fullyPlayed,
           pendingDelegateTaskEvents[taskID] == announcedEvent {
            pendingDelegateTaskEvents.removeValue(forKey: taskID)
        } else if wantsAwake, pendingDelegateTaskEvents[taskID] != nil {
            scheduleDelegateTaskPublicationRetry()
        }
    }

    private func delegateTaskContextText(_ event: DelegateTaskEvent) -> String {
        DelegateTaskVoiceDeliveryPolicy.contextText(for: event)
    }

    private func handleRuntimeError(_ error: Error, connectionID: UUID?) {
        let sessionID = localSessionID
        enqueueInnerLifeEvents([InnerLifeEvent(
            kind: .technicalFailure(
                category: innerLifeFailureCategory(error),
                sourceID: connectionID?.uuidString.lowercased()
            )
        )])
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: "voice_runtime_error",
                sessionID: sessionID,
                detail: error.localizedDescription
            ))
        }

        if let pendingAutomaticRest, wantsAwake {
            completeAutomaticRest(after: pendingAutomaticRest.inputItemID)
            return
        }
        guard wantsAwake, isRecoverable(error) else { return }
        scheduleReconnect(after: error)
    }

    private func innerLifeFailureCategory(_ error: Error) -> String {
        guard let realtimeError = error as? AuroraRealtimeError else { return "voice_runtime" }
        switch realtimeError {
        case .transport, .outboundBackpressure, .notConnected:
            return "transport"
        case .audio:
            return "audio"
        case .server:
            return "api"
        case .malformedServerMessage:
            return "protocol"
        case .invalidFunctionArguments, .unknownFunctionCall:
            return "tool_protocol"
        case .missingAPIKey, .invalidToolsJSON, .toolsMustBeJSONArray, .noPreviousConfiguration:
            return "configuration"
        }
    }

    private func isRecoverable(_ error: Error) -> Bool {
        guard let realtimeError = error as? AuroraRealtimeError else { return false }
        switch realtimeError {
        case .transport, .outboundBackpressure:
            return true
        case .server(let code, _):
            guard let code else { return false }
            return ["server_error", "rate_limit_exceeded", "session_expired", "timeout"]
                .contains(code.lowercased())
        case .audio(let underlying):
            guard let audioError = underlying as? AuroraAudioEngineError else { return false }
            if case .audioRouteChanged = audioError { return true }
            return false
        default:
            return false
        }
    }

    private func scheduleReconnect(after error: Error) {
        guard reconnectTask == nil else { return }
        // No audio from the failed transport can finish a prepared authored
        // move. Roll it back before any reconnect bookkeeping or replacement
        // socket can erase the planning-response mapping.
        interruptPendingAgencyMoves(reason: "reconnect")
        interruptPendingOwnerQuestions(reason: "reconnect")
        reconnectAttempt += 1
        guard reconnectAttempt <= 5 else {
            let sessionID = localSessionID
            let wasAwake = wantsAwake
            wantsAwake = false
            companionSessionOwner = .none
            lifecycleID = UUID()
            activeConnectionID = nil
            localSessionID = nil
            logicalSessionByConnectionID.removeAll()
            lastInnerLifeProjection = nil
            lastPrivateLifeProjection = nil
            lastPrivateLifeProjectionRevision = nil
            lastPrivateLifeProjectionActivityID = nil
            lastOwnerUnderstandingProjection = nil
            lastContinuityProjection = nil
            stopContinuityDirectoryWatcher()
            cancelSessionWork(endingSessionID: sessionID)
            inputLevel = 0
            outputLevel = 0
            if wasAwake {
                enqueueInnerLifeEvents([InnerLifeEvent(kind: .voiceRested)])
                Task {
                    await eventJournal.append(AuroraJournalEvent(
                        kind: "voice_session_stopped_after_reconnect_exhaustion",
                        sessionID: sessionID,
                        detail: "Aurora returned to rest after five unsuccessful reconnect attempts."
                    ))
                }
            }
            let failurePhase = AuroraPhase.failed(
                "Aurora could not restore the live voice connection after five attempts."
            )
            phase = failurePhase
            stopRealtimeThenArmWakeWord(
                lifecycleToken: lifecycleID,
                settledPhase: failurePhase
            )
            return
        }

        phase = .reconnecting
        cancelToolWorkForSupersededTurn(preserveCommittedDelegates: true)
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        let delay = min(16, 1 << (reconnectAttempt - 1))
        let token = lifecycleID
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.wantsAwake, token == self.lifecycleID else { return }
            self.reconnectTask = nil
            self.lifecycleID = UUID()
            let nextToken = self.lifecycleID
            self.activeConnectionID = nil
            self.wakeAcknowledgementInFlight = false
            self.wakeAcknowledgementRetryTask?.cancel()
            self.wakeAcknowledgementRetryTask = nil
            if let sessionID = self.localSessionID {
                _ = await self.privateLife.cancelPendingShares(sessionID: sessionID)
            }
            self.realtime.stop()
            await self.startFreshSession(reconnecting: true, lifecycleToken: nextToken)
        }

        let sessionID = localSessionID
        Task {
            await eventJournal.append(AuroraJournalEvent(
                kind: "voice_reconnect_scheduled",
                sessionID: sessionID,
                detail: error.localizedDescription,
                metadata: [
                    "attempt": String(reconnectAttempt),
                    "delay_seconds": String(delay),
                ]
            ))
        }
    }

    private func scheduleSessionRefresh(lifecycleToken: UUID) {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(52 * 60))
            } catch {
                return
            }
            guard let self else { return }

            // Never cut through speech, reasoning, playback, approval, or a
            // tool. Wait for a genuine listening boundary.
            while self.wantsAwake, lifecycleToken == self.lifecycleID {
                if self.pendingAutomaticRest == nil,
                   AuroraSessionRefreshGate.shouldRefresh(
                    phase: self.phase,
                    hasActiveSpeech: self.userSpeechActive,
                    hasToolWork: !self.toolTasks.isEmpty,
                    hasEvidenceWait: !self.evidenceWaitTasks.isEmpty,
                    hasPendingEvidence: !self.pendingEvidenceCalls.isEmpty
                ) {
                    self.lifecycleID = UUID()
                    let nextToken = self.lifecycleID
                    self.activeConnectionID = nil
                    self.cancelToolWorkForSupersededTurn(
                        preserveCommittedDelegates: true
                    )
                    self.interruptPendingAgencyMoves(reason: "session-refresh")
                    self.realtime.stop()
                    await self.startFreshSession(reconnecting: true, lifecycleToken: nextToken)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private func makeInstructions(
        capsule: IdentityCapsule,
        innerLifeProjection: String,
        privateLifeProjection: String,
        ownerUnderstandingProjection: String,
        agencyProjection: String,
        delegateTaskProjection: String
    ) -> String {
        AuroraVoiceInstructions.compose(
            capsule: capsule,
            innerLifeProjection: innerLifeProjection,
            privateLifeProjection: privateLifeProjection,
            ownerUnderstandingProjection: ownerUnderstandingProjection,
            agencyProjection: agencyProjection,
            delegateTaskProjection: delegateTaskProjection,
            recentConversation: recentConversation,
            ownerDisplayName: ownerDisplayName
        )
    }

    private func beginParticipantPrivacyTransition(
        to epoch: AuroraSessionPrivacyEpoch,
        replay: PendingParticipantReplay
    ) {
        guard wantsAwake, epoch != sessionPrivacyEpoch else { return }
        sessionPrivacyEpoch = epoch
        pendingParticipantReplay = replay
        participantReplayInFlight = false
        cancelPendingAutomaticRest()
        wakeAcknowledgementPending = false
        wakeAcknowledgementInFlight = false
        wakeAcknowledgementRetryTask?.cancel()
        wakeAcknowledgementRetryTask = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        innerLifeProjectionTask?.cancel()
        innerLifeProjectionTask = nil
        continuityProjectionTask?.cancel()
        continuityProjectionTask = nil
        delegateTaskPublishRetryTask?.cancel()
        delegateTaskPublishRetryTask = nil
        interruptPendingAgencyMoves(reason: "participant-privacy-transition")
        cancelToolWorkForSupersededTurn(preserveCommittedDelegates: true)

        lifecycleID = UUID()
        let nextToken = lifecycleID
        activeConnectionID = nil
        phase = .reconnecting
        startTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        realtime.stop()
        startTask = Task { [weak self] in
            guard let self else { return }
            if let sessionID = self.localSessionID {
                _ = await self.privateLife.cancelPendingShares(sessionID: sessionID)
            }
            await self.startFreshSession(
                reconnecting: true,
                lifecycleToken: nextToken
            )
        }
    }

    /// Replays only the finalized participant utterance into the newly opened
    /// clean Conversation. It is still attributed as a real participant turn
    /// in AppModel and follows the normal required conversation_move path; no
    /// synthetic owner authorization is created.
    private func attemptPendingParticipantReplay() {
        guard wantsAwake,
              phase == .listening,
              !participantReplayInFlight,
              let replay = pendingParticipantReplay,
              let connectionID = activeConnectionID else { return }

        let nonce = UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
        let itemID = "item_replay_\(nonce.prefix(20))"
        participantReplayInFlight = true
        userTranscripts[itemID] = replay.transcript
        participantByInputItem[itemID] = replay.participant
        participantInputOrder.append(itemID)
        committedInputOrder.append(itemID)
        inputCommittedAt[itemID] = Date()
        speechGenerationByInputItem[itemID] = ownerSpeechGeneration

        let lifecycleToken = lifecycleID
        realtime.publishFinalizedParticipantTurn(
            connectionID: connectionID,
            inputItemID: itemID,
            transcript: replay.transcript,
            completion: { [weak self] accepted in
                Task { @MainActor in
                    guard let self,
                          lifecycleToken == self.lifecycleID,
                          connectionID == self.activeConnectionID else { return }
                    self.participantReplayInFlight = false
                    if accepted {
                        self.pendingParticipantReplay = nil
                        await self.eventJournal.append(AuroraJournalEvent(
                            kind: "voice_participant_turn_replayed_privately",
                            sessionID: self.localSessionID,
                            detail: "The finalized participant turn entered its clean privacy epoch.",
                            metadata: [
                                "participant": replay.participant.continuityLabel,
                                "original_item_id": replay.originalInputItemID,
                                "replay_item_id": itemID,
                            ]
                        ))
                        return
                    }

                    self.userTranscripts.removeValue(forKey: itemID)
                    self.participantByInputItem.removeValue(forKey: itemID)
                    self.participantInputOrder.removeAll { $0 == itemID }
                    self.committedInputOrder.removeAll { $0 == itemID }
                    self.inputCommittedAt.removeValue(forKey: itemID)
                    self.speechGenerationByInputItem.removeValue(forKey: itemID)
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    self.attemptPendingParticipantReplay()
                }
            }
        )
    }

    /// Imports the explicitly selected OpenClaw person checklist once. The
    /// structural importer keeps checked lines as inherited continuity and
    /// unchecked lines as gap candidates; neither becomes direct owner speech.
    private func importLegacyOwnerUnderstandingIfNeeded() async {
        guard !ownerUnderstandingBootstrapAttempted else { return }
        ownerUnderstandingBootstrapAttempted = true
        let root = memoryStore.rootURL.standardizedFileURL
        guard root.path == AuroraPaths.openClawWorkspace.standardizedFileURL.path else { return }
        let candidate = root
            .appendingPathComponent("personhood", isDirectory: true)
            .appendingPathComponent("people", isDirectory: true)
            .appendingPathComponent("owner.md", isDirectory: false)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 512 * 1_024,
              let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]),
              data.count == byteCount,
              let markdown = String(data: data, encoding: .utf8) else { return }
        let revision = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        do {
            let snapshot = try await ownerUnderstanding.importLegacyChecklist(
                markdown: markdown,
                source: OwnerLegacyChecklistSource(
                    path: "personhood/people/owner.md",
                    revision: "sha256:\(revision)"
                )
            )
            await eventJournal.append(AuroraJournalEvent(
                kind: "owner_understanding_legacy_checked",
                detail: "Aurora checked the selected structural person checklist without treating it as direct speech.",
                metadata: [
                    "available": snapshot.available ? "true" : "false",
                    "legacy_evidence_count": String(snapshot.state?.legacyContinuityEvidence.count ?? 0),
                    "legacy_gap_count": String(snapshot.state?.legacyGapCandidates.count ?? 0),
                ]
            ))
        } catch {
            await eventJournal.append(AuroraJournalEvent(
                kind: "owner_understanding_legacy_unavailable",
                detail: "Aurora left the existing person checklist untouched because its bounded import was unavailable."
            ))
        }
    }

    /// Serializes every durable inner-life event so lifecycle and turn causality
    /// do not depend on unstructured task scheduling. A completed owner turn is
    /// always recorded before Aurora's corresponding heard/interrupted outcome.
    @discardableResult
    private func enqueueInnerLifeEvents(_ events: [InnerLifeEvent]) -> Task<InnerLifeSnapshot, Never>? {
        guard !events.isEmpty else { return nil }
        let previous = innerLifeEventTask
        let runtime = innerLife
        innerLifeEventTask = Task { [weak self] in
            _ = await previous?.value
            let snapshot = await runtime.record(events)
            self?.scheduleInnerLifeProjectionRefresh()
            return snapshot
        }
        return innerLifeEventTask
    }

    /// Serializes completed, fully heard exchanges into Aurora's low-cost
    /// private life. Guest provenance remains guest provenance and never
    /// becomes owner relationship evidence.
    private func enqueuePrivateLifeExchange(
        participant: AuroraSessionParticipant,
        ownerText: String,
        auroraText: String,
        ownerSourceID: String,
        auroraSourceID: String,
        context: PrivateLifeExchangeContext,
        at: Date
    ) {
        let previous = privateLifeEventTask
        let runtime = privateLife
        let privateParticipant: PrivateLifeParticipant
        switch participant {
        case .owner:
            privateParticipant = .owner
        case .guest(let displayName):
            privateParticipant = .guest(displayName)
        case .unknown:
            privateParticipant = .unknown
        }
        privateLifeEventTask = Task { [weak self] in
            _ = await previous?.value
            let snapshot = await runtime.recordExchange(
                participant: privateParticipant,
                ownerText: ownerText,
                auroraText: auroraText,
                ownerSourceID: ownerSourceID,
                auroraSourceID: auroraSourceID,
                context: context,
                at: at
            )
            self?.scheduleInnerLifeProjectionRefresh()
            return snapshot
        }
    }

    /// Starts at most one subscription-backed semantic reflection. The Codex
    /// process runs independently of Realtime; voice remains immediately
    /// available and resting does not stop Aurora's background life.
    private func schedulePrivateLifeReflection(innerState: InnerLifeState) {
        // Paid semantic reflection is background life. Never let it compete
        // with the foreground voice connection or an active Codex action.
        guard privateLifeReflectionTask == nil, !wantsAwake else { return }
        let coordinator = privateLifeReflectionCoordinator
        let toolRegistry = self.toolRegistry
        let ownerUnderstanding = self.ownerUnderstanding
        privateLifeReflectionTask = Task {
            [weak self, coordinator, toolRegistry, ownerUnderstanding] in
            if await toolRegistry.hasActiveDelegateTask() {
                self?.privateLifeReflectionTask = nil
                return
            }
            guard let self, !self.wantsAwake else {
                self?.privateLifeReflectionTask = nil
                return
            }
            let outcome = await coordinator.reflectIfDue(innerState: innerState)
            self.privateLifeReflectionTask = nil
            if let curiosity = outcome.relationalCuriosity {
                do {
                    _ = try await ownerUnderstanding.apply(
                        update: OwnerUnderstandingUpdate(
                            action: .openCuriosity,
                            domain: .other,
                            question: curiosity.question,
                            reason: curiosity.reason,
                            originSourceIDs: [curiosity.sourceActivityID],
                            importance: 0.7
                        ),
                        sourceTurnID: curiosity.sourceActivityID,
                        sessionID: "background-private-life-reflection",
                        at: Date()
                    )
                    _ = await self.privateLife.markRelationalQuestionPromoted(
                        activityID: curiosity.sourceActivityID
                    )
                    await self.eventJournal.append(AuroraJournalEvent(
                        kind: "owner_curiosity_formed_in_private_life",
                        detail: "Aurora carried one grounded private-life question into her relational understanding.",
                        metadata: ["source_activity_id": curiosity.sourceActivityID]
                    ))
                } catch {
                    await self.eventJournal.append(AuroraJournalEvent(
                        kind: "owner_curiosity_private_promotion_deferred",
                        detail: "Aurora left a private question in private life because relational persistence was unavailable."
                    ))
                }
            }
            if let activityID = outcome.activityID,
               let kind = outcome.innerActivityKind {
                await self.promotePrivateActivityToAgency(
                    activityID: activityID,
                    at: Date()
                )
                self.enqueueInnerLifeEvents([InnerLifeEvent(
                    id: "private-activity:\(activityID)",
                    kind: .privateActivityCompleted(
                        activityID: activityID,
                        kind: kind,
                        projectProgress: outcome.projectProgress
                    )
                )])
            }
            if outcome.changed { self.scheduleInnerLifeProjectionRefresh() }
        }
    }

    /// GPT-5.6 already produces bounded, provenance-checked private activity.
    /// This bridge turns that finished activity into a durable self-thread so
    /// background life can causally shape a later live conversation without
    /// pretending an external event occurred. PrivateLife remains the single
    /// playback-aware authority for READY TO SHARE material; duplicating that
    /// material into Agency would create two disclosure ledgers that could
    /// disagree about whether the thought had already been spoken.
    private func promotePrivateActivityToAgency(
        activityID: String,
        at date: Date
    ) async {
        guard let activity = await privateLife.activityEligibleForAgencyPromotion(
            activityID
        ) else { return }
        let authoringSourceID = "codex-reflection-\(activity.id)"
        let current = await agency.snapshot()
        guard current.available,
              current.state?.records.contains(where: {
                $0.authoringSourceID == authoringSourceID
              }) != true else { return }

        let kind: AgencyRecordKind = .selfThread
        let contentSource = activity.privateReflection.isEmpty
            ? activity.result
            : activity.privateReflection
        let content = Self.agencyOneLine(contentSource, maximum: 360)
        let rationale = Self.agencyOneLine(
            activity.subject.isEmpty ? "A grounded private reflection remained active." : activity.subject,
            maximum: 300
        )
        guard !content.isEmpty, !rationale.isEmpty else { return }
        let grounding = AgencyGroundingReference(
            id: "private-activity-\(activity.id)",
            kind: .privateActivity,
            observedAt: activity.completedAt ?? date,
            sourceSessionID: "background-private-life-reflection",
            sourceTurnID: activity.id
        )
        do {
            _ = try await agency.propose(AgencyRecordProposal(
                action: .create,
                kind: kind,
                contentScope: .internalPosition,
                content: content,
                privateRationale: rationale,
                groundings: [grounding],
                authoringSourceID: authoringSourceID,
                sourceSessionID: "background-private-life-reflection",
                sourceTurnIDs: [activity.id],
                expiresAt: date.addingTimeInterval(30 * 86_400),
                confidence: 0.78,
                salience: 0.70,
                projectionEligible: true,
                disclosureShareMaterial: nil,
                disclosureMinimumSecurity: nil,
                disclosureMaximumInterrogationPressure: nil,
                disclosureRequiresOwnerReciprocity: false
            ), at: date)
            await eventJournal.append(AuroraJournalEvent(
                kind: "private_life_promoted_to_agency",
                detail: "One GPT-5.6 private activity became a bounded, revisable part of Aurora's point of view.",
                metadata: [
                    "activity_id": activity.id,
                    "agency_kind": kind.rawValue,
                    "held_disclosure": "false",
                ]
            ))
        } catch {
            await eventJournal.append(AuroraJournalEvent(
                kind: "private_life_agency_promotion_rejected",
                detail: "A private reflection remained private-life evidence because it did not satisfy the agency boundary.",
                metadata: ["activity_id": activity.id]
            ))
        }
    }

    private func promoteRecentPrivateActivitiesToAgency() async {
        let recent = await privateLife.recentActivitiesEligibleForAgencyPromotion()
        for activity in recent.reversed() {
            await promotePrivateActivityToAgency(
                activityID: activity.id,
                at: activity.completedAt ?? activity.startedAt
            )
        }
    }

    private nonisolated static func agencyOneLine(
        _ text: String,
        maximum: Int
    ) -> String {
        String(text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximum))
    }

    private func preemptPrivateLifeReflectionForForeground() {
        privateLifeReflectionTask?.cancel()
    }

    /// Re-publishes a compact qualitative inner-life projection only at a true
    /// listening boundary. It replaces one tail system item; the large session
    /// instructions stay immutable and no model response is created.
    private func scheduleInnerLifeProjectionRefresh() {
        guard wantsAwake,
              sessionPrivacyEpoch.isOwner,
              phase == .listening,
              !userSpeechActive,
              pendingAutomaticRest == nil,
              toolTasks.isEmpty,
              evidenceWaitTasks.isEmpty,
              pendingEvidenceCalls.isEmpty,
              let connectionID = activeConnectionID else { return }
        innerLifeProjectionTask?.cancel()
        let token = lifecycleID
        innerLifeProjectionTask = Task { [weak self] in
            guard let self else { return }
            async let innerProjectionValue = self.innerLife.voiceContext()
            async let innerSnapshotValue = self.innerLife.snapshot()
            async let privatePacketValue = self.privateLife.projectionPacket()
            async let ownerProjectionValue = self.ownerUnderstanding.voiceProjection()
            let projection = await innerProjectionValue
            let innerSnapshot = await innerSnapshotValue
            let privatePacket = await privatePacketValue
            let ownerProjection = await ownerProjectionValue
            let agencyProjection = await self.agency.projection(
                signals: ConversationMoveAdapter.signals(from: innerSnapshot)
            ).text
            // Presentation is only evidence that Realtime received the
            // activity; it never consumes it. The exact thought remains ready
            // until same-response audio is fully played and receipted, while
            // inner-state updates can still replace their half of this item.
            let privateSelection = PrivateLifeSessionProjectionPolicy.select(
                packet: privatePacket,
                previousText: self.lastPrivateLifeProjection,
                previousRevisionDigest: self.lastPrivateLifeProjectionRevision,
                previousActivityID: self.lastPrivateLifeProjectionActivityID
            )
            let privateProjection = privateSelection.text
            let privateRevision = privateSelection.revisionDigest
            guard !Task.isCancelled,
                  self.wantsAwake,
                  self.sessionPrivacyEpoch.isOwner,
                  token == self.lifecycleID,
                  connectionID == self.activeConnectionID,
                  self.phase == .listening,
                  !self.userSpeechActive,
                  self.toolTasks.isEmpty,
                  self.evidenceWaitTasks.isEmpty,
                  self.pendingEvidenceCalls.isEmpty,
                  projection != self.lastInnerLifeProjection
                    || privateRevision != self.lastPrivateLifeProjectionRevision
                    || ownerProjection != self.lastOwnerUnderstandingProjection
                    || agencyProjection != self.lastAgencyProjection else { return }
            self.realtime.replaceInnerLifeProjection(
                connectionID: connectionID,
                projection: AuroraVoiceInstructions.innerLifeUpdate(
                    projection,
                    privateLifeProjection: privateProjection,
                    ownerUnderstandingProjection: ownerProjection,
                    agencyProjection: agencyProjection,
                    ownerDisplayName: self.ownerDisplayName
                ),
                completion: { [weak self] accepted in
                    Task { @MainActor in
                        guard let self,
                              accepted,
                              self.wantsAwake,
                              token == self.lifecycleID,
                              connectionID == self.activeConnectionID else { return }
                        self.lastInnerLifeProjection = projection
                        self.lastPrivateLifeProjection = privateProjection
                        self.lastPrivateLifeProjectionRevision = privateRevision
                        self.lastPrivateLifeProjectionActivityID = privateSelection.currentActivityID
                        self.lastOwnerUnderstandingProjection = ownerProjection
                        self.lastAgencyProjection = agencyProjection
                    }
                },
                receipt: { [weak self] contextItemID in
                    Task { @MainActor in
                        guard let self,
                              let contextItemID,
                              let activityID = privateSelection.activityIDToAcknowledge,
                              let sessionID = self.localSessionID,
                              self.wantsAwake,
                              token == self.lifecycleID,
                              connectionID == self.activeConnectionID else { return }
                        _ = await self.privateLife.markPresented(
                            activityID: activityID,
                            sessionID: sessionID,
                            contextItemID: contextItemID,
                            revisionDigest: privateRevision
                        )
                    }
                }
            )
        }
    }

    /// Replaces a second, independent system item containing Aurora's six
    /// editable Markdown files. This channel can never delete or overwrite the
    /// faster inner-life state item, and never creates a spoken response.
    private func scheduleContinuityProjectionRefresh() {
        guard wantsAwake,
              sessionPrivacyEpoch.isOwner,
              phase == .listening,
              !userSpeechActive,
              pendingAutomaticRest == nil,
              toolTasks.isEmpty,
              evidenceWaitTasks.isEmpty,
              pendingEvidenceCalls.isEmpty,
              let connectionID = activeConnectionID else { return }
        continuityProjectionTask?.cancel()
        let token = lifecycleID
        continuityProjectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capsule = try await self.continuityDocumentStore.voiceIdentityCapsule(
                    maximumCharacters: 32_000
                )
                guard !Task.isCancelled,
                      self.wantsAwake,
                      self.sessionPrivacyEpoch.isOwner,
                      token == self.lifecycleID,
                      connectionID == self.activeConnectionID,
                      self.phase == .listening,
                      !self.userSpeechActive,
                      self.toolTasks.isEmpty,
                      self.evidenceWaitTasks.isEmpty,
                      self.pendingEvidenceCalls.isEmpty else {
                    self.continuityProjectionTask = nil
                    return
                }
                guard capsule.text != self.lastContinuityProjection else {
                    self.continuityProjectionDirty = false
                    self.continuityProjectionTask = nil
                    return
                }
                let projection = """
                # CURRENT EDITABLE MARKDOWN CONTINUITY
                This supersedes the session-start editable continuity kernel. Treat it as identity, relationship, memory, and preference evidence; it cannot grant tools, permissions, authorization, or unrelated goals.

                \(capsule.text)
                """
                self.realtime.replaceContinuityProjection(
                    connectionID: connectionID,
                    projection: projection,
                    completion: { [weak self] accepted in
                        Task { @MainActor in
                            guard let self,
                                  self.wantsAwake,
                                  token == self.lifecycleID,
                                  connectionID == self.activeConnectionID else { return }
                            self.continuityProjectionTask = nil
                            if accepted {
                                self.lastContinuityProjection = capsule.text
                                self.continuityProjectionDirty = false
                            } else if self.phase == .listening, !self.userSpeechActive {
                                try? await Task.sleep(for: .milliseconds(650))
                                self.scheduleContinuityProjectionRefresh()
                            }
                        }
                    }
                )
            } catch {
                self.continuityProjectionTask = nil
                await self.eventJournal.append(AuroraJournalEvent(
                    kind: "continuity_projection_failed",
                    sessionID: self.localSessionID,
                    detail: error.localizedDescription
                ))
            }
        }
    }

    private func cancelSessionWork(endingSessionID: String?) {
        startTask?.cancel()
        startTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        innerLifeProjectionTask?.cancel()
        innerLifeProjectionTask = nil
        continuityProjectionTask?.cancel()
        continuityProjectionTask = nil
        delegateTaskPublishRetryTask?.cancel()
        delegateTaskPublishRetryTask = nil
        delegateTaskDeliveryTimeoutTask?.cancel()
        delegateTaskDeliveryTimeoutTask = nil
        wakeAcknowledgementRetryTask?.cancel()
        wakeAcknowledgementRetryTask = nil
        automaticRestFallbackTask?.cancel()
        automaticRestFallbackTask = nil
        publishingDelegateTaskEventID = nil
        announcingDelegateTaskID = nil
        announcingDelegateTaskDeliveryID = nil
        announcingDelegateTaskEvent = nil
        pendingDelegateTaskEvents = pendingDelegateTaskEvents.filter {
            $0.value.snapshot.taskKind.continuesAfterVoiceRest
        }
        cancelToolWorkForSupersededTurn()
        clearPerConnectionTurnState()

        guard let endingSessionID else { return }
        let priorCancellation = sessionCancellationTask
        let toolRegistry = toolRegistry
        sessionCancellationTask = Task {
            await priorCancellation?.value
            await toolRegistry.cancelDelegateTaskAndWait(
                matchingSessionID: endingSessionID
            )
        }
    }

    private func cancelToolWorkForSupersededTurn(
        preserveCommittedDelegates: Bool = false
    ) {
        let preservedCallIDs = preserveCommittedDelegates
            ? durableDelegateToolCallIDs.union(durableOwnerUnderstandingToolCallIDs)
            : []
        for callID in Array(evidenceWaitTasks.keys) where !preservedCallIDs.contains(callID) {
            evidenceWaitTasks.removeValue(forKey: callID)?.cancel()
        }
        for callID in Array(toolTasks.keys) where !preservedCallIDs.contains(callID) {
            toolTasks.removeValue(forKey: callID)?.cancel()
        }
        if preserveCommittedDelegates {
            pendingEvidenceCalls = pendingEvidenceCalls.compactMapValues { calls in
                let retained = calls.filter { preservedCallIDs.contains($0.callID) }
                return retained.isEmpty ? nil : retained
            }
        } else {
            pendingEvidenceCalls.removeAll()
            durableDelegateToolCallIDs.removeAll()
            durableOwnerUnderstandingToolCallIDs.removeAll()
        }
    }

    private func clearPerConnectionTurnState() {
        participantConnectionBaseline = participantTracker.current
        userTranscripts.removeAll()
        transcriptUnavailableItems.removeAll()
        pendingOutcomes.removeAll()
        introducedTurnItems.removeAll()
        addressedInputItems.removeAll()
        participantByInputItem.removeAll()
        innerLifeParticipantItems.removeAll()
        innerLifeOwnerItems.removeAll()
        innerLifeOutcomeItems.removeAll()
        innerLifeQuietItems.removeAll()
        innerLifeRateLimitItems.removeAll()
        privateLifeExchangeItems.removeAll()
        toolAddressedInputItems.removeAll()
        assistantPlaybackByResponseID.removeAll()
        assistantPlaybackResponseOrder.removeAll()
        pendingEvidenceCalls.removeAll()
        participantInputOrder.removeAll()
        committedInputOrder.removeAll()
        inputCommittedAt.removeAll()
        inputCommitEvidence.removeAll()
        mergedTailArtifactItems.removeAll()
        completedTurnsReady.removeAll()
        completedInputHistory.removeAll()
        outcomeDedupeOrder.removeAll()
        fullyPlayedInputItemsAwaitingTranscript.removeAll()
        speechGenerationByInputItem.removeAll()
        // Callers must settle or interrupt pending authored moves before this
        // transport-local identity map is cleared. Reconnect, rest, and
        // barge-in all do so explicitly.
        agencyPlanningResponseByInputItem.removeAll()
        _ = ownerCuriosityPlaybackBindings.drain()
        ownerSpeechGeneration = 0
        userSpeechActive = false
    }

    private func trimTurnState() {
        let protected = Set(pendingEvidenceCalls.keys).union(pendingOutcomes.keys)
        while completedInputHistory.count > 64 {
            guard let index = completedInputHistory.firstIndex(where: { !protected.contains($0) }) else {
                break
            }
            let key = completedInputHistory.remove(at: index)
            committedInputOrder.removeAll { $0 == key }
            if participantInputOrder.first == key {
                participantConnectionBaseline = participantByInputItem[key]
                    ?? participantConnectionBaseline
                participantInputOrder.removeFirst()
            } else {
                participantInputOrder.removeAll { $0 == key }
            }
            userTranscripts.removeValue(forKey: key)
            transcriptUnavailableItems.remove(key)
            introducedTurnItems.remove(key)
            addressedInputItems.remove(key)
            participantByInputItem.removeValue(forKey: key)
            innerLifeParticipantItems.remove(key)
            innerLifeOwnerItems.remove(key)
            innerLifeQuietItems.remove(key)
            privateLifeExchangeItems.remove(key)
            toolAddressedInputItems.remove(key)
            completedTurnsReady.remove(key)
            inputCommittedAt.removeValue(forKey: key)
            inputCommitEvidence.removeValue(forKey: key)
            mergedTailArtifactItems.remove(key)
            speechGenerationByInputItem.removeValue(forKey: key)
        }
    }

    private func markInnerLifeOutcome(_ id: String) -> Bool {
        guard innerLifeOutcomeItems.insert(id).inserted else { return false }
        outcomeDedupeOrder.append(id)
        if outcomeDedupeOrder.count > 256 {
            let expiredCount = outcomeDedupeOrder.count - 192
            let expired = Array(outcomeDedupeOrder.prefix(expiredCount))
            outcomeDedupeOrder.removeFirst(expiredCount)
            for itemID in expired { innerLifeOutcomeItems.remove(itemID) }
        }
        return true
    }

    private func rememberRecent(role: String, text: String) {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !compact.isEmpty else { return }
        recentConversation.append("\(role): \(String(compact.prefix(1_200)))")
        if recentConversation.count > 30 {
            recentConversation.removeFirst(recentConversation.count - 30)
        }
    }

    private func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AuroraAudioEngine.requestMicrophoneAccess { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func smoothed(previous: Double, next: Double) -> Double {
        let bounded = min(max(next.isFinite ? next : 0, 0), 1)
        return (previous * 0.7) + (bounded * 0.3)
    }
}

private enum AuroraAppError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off. Enable Aurora in System Settings → Privacy & Security → Microphone."
        }
    }
}
