import Foundation

/// Compile-time remnant used only to keep fail-closed response cleanup typed
/// while the retired deterministic motor path is removed. No value of this
/// type is ever produced in the production client.
private enum RetiredControlRouteKind {
    case reminder
    case currentInformation
    case directOpen
    case mail
    case textEditWrite
    case deterministicDesktopAction
    case sightOnlyVisual
    case visualComputerTask
    case none
}

private struct RetiredControlRoute {
    let kind: RetiredControlRouteKind
    let preferredToolName: String?
    let preferredAction: String?
}

protocol AuroraRealtimeSocket: AnyObject {
    func resume()
    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    )
    func cancel()
}

private final class URLSessionAuroraRealtimeSocket: AuroraRealtimeSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let session = URLSession(configuration: .default)
        self.session = session
        self.task = session.webSocketTask(with: request)
    }

    func resume() {
        task.resume()
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        task.receive(completionHandler: completionHandler)
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        task.send(message, completionHandler: completionHandler)
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

protocol AuroraRealtimeScheduledTask: AnyObject {
    func cancel()
}

protocol AuroraRealtimeScheduling: AnyObject {
    var now: TimeInterval { get }
    func schedule(
        on queue: DispatchQueue,
        after delay: TimeInterval,
        _ operation: @escaping () -> Void
    ) -> AuroraRealtimeScheduledTask
}

private final class AuroraDispatchScheduledTask: AuroraRealtimeScheduledTask {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class AuroraSystemRealtimeScheduler: AuroraRealtimeScheduling {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(
        on queue: DispatchQueue,
        after delay: TimeInterval,
        _ operation: @escaping () -> Void
    ) -> AuroraRealtimeScheduledTask {
        let item = DispatchWorkItem(block: operation)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return AuroraDispatchScheduledTask(workItem: item)
    }
}

/// Revokes function callbacks that have been queued for AppModel but have not
/// started yet. Realtime state learns about barge-in before callbackQueue can,
/// so a lock-backed generation closes that otherwise exploitable queue gap.
private final class RealtimeFunctionCallDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock()
        let current = generation == expected
        lock.unlock()
        return current
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

/// Direct, voice-first OpenAI Realtime connection for Aurora.
///
/// The Realtime model hears the owner, speaks as Aurora, and invokes native tools in
/// the same conversation. This transport owns ordering, interruption, audio
/// truth, and function-call generations; it never forwards a transcript to a
/// second conversational model.
final class AuroraRealtimeClient {
    static let model = "gpt-realtime-2.1"
    // This is a completion ceiling, not a target. Aurora's voice contract keeps
    // ordinary turns brief, while the larger allowance lets a requested or
    // necessary explanation finish naturally instead of being cut mid-sentence.
    // The live journal proved both 256 and an earlier 512 ceiling insufficient.
    static let maxResponseOutputTokens = 1_024
    // Realtime's server Conversation still carries the live exchange. Keep a
    // compact recent window; durable depth remains available through memory.
    static let postInstructionConversationTokenLimit = 1_200
    // The live service rejects long client-supplied Conversation item IDs even
    // though the public schema does not currently publish that backend bound.
    // Keep Aurora's replaceable private-context IDs at the server's native
    // item scale while retaining enough random bits for a single session.
    static let maximumClientConversationItemIDCharacters = 32
    // Continuity files are projected through their own replaceable system
    // item rather than rewriting the session instructions. Keep the complete
    // live projection bounded independently from the much smaller inner-life
    // pulse.
    // Large enough to carry Aurora's current six Markdown documents in full,
    // but still a hard bound independent of their on-disk 2 MB/file limit.
    static let maximumContinuityProjectionCharacters = 36_000
    // A binary Double serializes as 0.80000000000000004 on this macOS build,
    // which Realtime rejects for exceeding its 16-decimal schema limit.
    static let conversationRetentionRatio = Decimal(string: "0.8")!
    /// Marin supplies Aurora's preferred feminine Realtime timbre. The native
    /// prompt supplies her calm, understated delivery rather than treating a
    /// stock voice as the personality itself.
    static let voice = "marin"
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!

    private static let emptyResponseRecoveryDirective = """
    # Empty-response recovery
    The immediately preceding planning response for the active turn produced no usable semantic function. Re-evaluate the original user audio and current conversation, then call exactly one available function with no audio: codex_project_chat only for explicit navigation or relay within a named Codex project/chat, delegate_task for all other external work, conversation_move for an addressed social turn, or wait_for_user only for unmistakable background speech. An internal context function is allowed only when genuinely necessary and must remain within its existing bounded continuation. Never promise work or answer directly in this planning response.
    """

    var onPhase: ((_ connectionID: UUID?, _ phase: AuroraPhase) -> Void)?
    var onUserSpeechStarted: ((_ connectionID: UUID) -> Void)?
    var onUserSpeechEnded: ((_ connectionID: UUID) -> Void)?
    var onInputCommitted: ((RealtimeInputCommitEvent) -> Void)?
    var onUserTranscript: ((RealtimeUserTranscriptEvent) -> Void)?
    var onUserTranscriptUnavailable: ((_ connectionID: UUID, _ itemID: String) -> Void)?
    var onAssistantTranscript: ((RealtimeAssistantTranscriptEvent) -> Void)?
    var onAssistantPlaybackOutcome: ((RealtimeAssistantPlaybackOutcome) -> Void)?
    var onBackgroundTaskDeliveryFailed: ((_ connectionID: UUID, _ deliveryID: String) -> Void)?
    var onSilentTurn: ((_ connectionID: UUID, _ inputItemID: String?) -> Void)?
    var onAddressedTurn: ((_ connectionID: UUID, _ inputItemID: String) -> Void)?
    var onUnresolvedTurn: ((_ connectionID: UUID, _ inputItemID: String) -> Void)?
    /// Boundary-only evidence for live diagnostics. Never contains audio or a
    /// transcript.
    var onDiagnostic: ((_ connectionID: UUID, _ kind: String, _ metadata: [String: String]) -> Void)?
    var onError: ((_ connectionID: UUID?, _ error: Error) -> Void)?
    var onInputLevel: ((_ connectionID: UUID, _ level: Float) -> Void)?
    var onOutputLevel: ((_ connectionID: UUID, _ level: Float) -> Void)?
    var onFunctionCall: ((RealtimeFunctionCall) -> Void)?

    private struct ActiveConfiguration {
        let source: RealtimeSessionConfiguration
        let tools: [[String: Any]]
        let currentInstructions: String
    }

    private struct PendingInnerLifeContextUpdate {
        let itemID: String
        let eventID: String
        let previousItemID: String?
        let projection: String
        let completion: ((Bool) -> Void)?
        let receiptCompletion: ((String?) -> Void)?
    }

    private struct PendingContinuityContextUpdate {
        let itemID: String
        let eventID: String
        let previousItemID: String?
        let projection: String
        var completions: [(Bool) -> Void]
    }

    private struct PendingBackgroundTaskContextUpdate {
        let deliveryID: String
        let itemID: String
        let eventID: String
        let text: String
        let deliveryClass: DelegateTaskVoiceDeliveryClass
        let completion: ((Bool) -> Void)?
    }

    private struct PendingWakeWordAcknowledgement {
        let itemID: String
        let eventID: String
        let completion: ((Bool) -> Void)?
    }

    private struct PendingVisualToolResult {
        let itemID: String
        let eventID: String
        let responseID: String
        let callID: String
        let successOutput: String
        let continuation: RealtimeToolContinuation
        let expiresAfterSeconds: TimeInterval
    }

    private struct ResponseOrigin {
        let inputItemID: String?
        let backgroundTaskDeliveryID: String?
        let visualContextBound: Bool
        let untrustedMailContextBound: Bool
        /// A response.create that already reached the server before a barge-in
        /// still needs a queue slot so its late response.created cannot steal
        /// the next committed user input.
        let superseded: Bool

        init(
            inputItemID: String?,
            backgroundTaskDeliveryID: String? = nil,
            superseded: Bool = false,
            visualContextBound: Bool = false,
            untrustedMailContextBound: Bool = false
        ) {
            self.inputItemID = inputItemID
            self.backgroundTaskDeliveryID = backgroundTaskDeliveryID
            self.superseded = superseded
            self.visualContextBound = visualContextBound
            self.untrustedMailContextBound = untrustedMailContextBound
        }
    }

    private struct PendingAudioMotorCorroboration {
        let attemptID: String
        let eventID: String
        let connectionID: UUID
        let inputItemID: String
        let responseID: String
        let originalCall: [String: Any]
        let fingerprint: String
    }

    private struct ToolBatch {
        let responseID: String
        let inputItemID: String?
        var pendingCallIDs: Set<String>
        let callNames: [String: String]
        var internalHelperCallIDs = Set<String>()
        /// A finalized direct-owner delegate is durable work. New speech may
        /// interrupt Aurora's acknowledgement, but it does not withdraw the
        /// already-committed task unless the owner explicitly cancels it.
        var durableDelegateCallIDs = Set<String>()
        var wantsSpokenContinuation = false
        var wantsConversationMove = false
        var wantsDelegateAcknowledgement = false
        var wantsDelegateRetry = false
        var sawSilentTerminal = false
        var completedWithoutResponse = false
        var superseded = false
        var visualContextBound = false
        var untrustedMailContextBound = false
    }

    /// Audio for an owner turn is held until its finalized transcript tells us
    /// whether this is conversation or an action. Action-turn audio remains
    /// held until response.done, where any pre-tool promise is discarded and
    /// only the receipt-grounded continuation is allowed to play.
    private struct DeferredResponseAudio {
        let key: AuroraPlaybackKey
        var pcm = Data()
        var isComplete = false
    }

    private struct ActiveInputSpeechBoundary {
        let audioStartMilliseconds: Int?
        var audioEndMilliseconds: Int?
        let playbackRelationAtSpeechStart: RealtimeInputPlaybackRelation
    }

    private struct RateLimitBucket {
        let limit: Double?
        let remaining: Double
        let observedAt: TimeInterval
        let resetAt: TimeInterval
    }

    private struct PendingRateLimitRecovery {
        let inputItemID: String
        let connectionID: UUID
        let visualContextBound: Bool
        let untrustedMailContextBound: Bool
        let token: UUID
        let requestedAt: TimeInterval
        let dueAt: TimeInterval
    }

    private struct OutboundMessage {
        enum Kind: Equatable {
            case audio
            case continuationCreate
            case audioCorroborationCreate(String)
            case visualContextCreate(String)
            case interruptionControl
            case other
        }

        let id = UUID()
        let text: String
        let bytes: Int
        let kind: Kind
    }

    typealias SocketFactory = (URLRequest) -> AuroraRealtimeSocket

    private let stateQueue = DispatchQueue(label: "aurora.realtime.state")
    private let callbackQueue: DispatchQueue
    private let audio: AuroraRealtimeAudio
    private let socketFactory: SocketFactory
    private let scheduler: AuroraRealtimeScheduling
    private let functionCallDeliveryGate = RealtimeFunctionCallDeliveryGate()

    private var socket: AuroraRealtimeSocket?
    private var connectionID: UUID?
    private var activeConfiguration: ActiveConfiguration?
    private var intentionallyStopped = true
    private var audioStarted = false
    private var microphonePrimingBytesReceived = 0
    private var microphoneReady = false

    private var activeResponseID: String?
    private var responseInProgress = false
    private var userSpeechInProgress = false
    private var activeInputSpeechBoundary: ActiveInputSpeechBoundary?
    private var lastFullyPlayedAssistantAt: TimeInterval?
    private var inputItemsAwaitingResponse: [String] = []
    private var pendingResponseOrigins: [ResponseOrigin] = []
    private var responseInputItems: [String: String] = [:]
    /// Set as soon as Realtime announces a semantic action proposal, before
    /// its arguments or response.done arrive. This keeps Notes and delegated
    /// task turns from leaking an unverified spoken preamble.
    private var actionProposalResponseIDs = Set<String>()
    private var emptyResponseRetriedInputs = Set<String>()
    private var rateLimitRecoveryInputs = Set<String>()
    private var supersededResponseIDs = Set<String>()
    private var rateLimitBuckets: [String: RateLimitBucket] = [:]
    private var recentResponseInputTokens: [Double] = []
    private var pendingRateLimitRecovery: PendingRateLimitRecovery?
    private var pendingRateLimitRecoveryTask: AuroraRealtimeScheduledTask?
    private var rateLimitBlocked = false
    private var rateLimitSpeechPrefixAudio = Data()
    private var rateLimitSpeechOverrideFrames = 0

    private var activeInnerLifeContextItemID: String?
    private var activeInnerLifeProjection: String?
    private var pendingInnerLifeContextUpdate: PendingInnerLifeContextUpdate?
    private var innerLifeDeleteEventIDs: [String] = []
    private var activeContinuityContextItemID: String?
    private var activeContinuityProjection: String?
    private var pendingContinuityContextUpdate: PendingContinuityContextUpdate?
    private var continuityDeleteEventIDs: [String] = []
    private var pendingBackgroundTaskContextUpdate: PendingBackgroundTaskContextUpdate?
    private var backgroundTaskContextItemByDeliveryID: [String: String] = [:]
    private var backgroundTaskDeleteEventIDs: [String] = []
    private var pendingWakeWordAcknowledgement: PendingWakeWordAcknowledgement?
    private var activeVisualContextItemID: String?
    private var pendingVisualToolResults: [String: PendingVisualToolResult] = [:]
    private var visualEventToItemID: [String: String] = [:]
    private var visualContextTimeoutTasks: [String: AuroraRealtimeScheduledTask] = [:]
    private var activeVisualContextExpiryTask: AuroraRealtimeScheduledTask?
    private var visualContextDeleteEventIDs: [String] = []
    private var visualContextBoundResponseIDs = Set<String>()
    private var untrustedMailContextBoundResponseIDs = Set<String>()
    private var activeUntrustedMailItemIDs = Set<String>()
    private var untrustedMailDeleteEventIDs: [String] = []

    private var userTranscripts: [String: String] = [:]
    private var finalizedUserTranscriptItems = Set<String>()
    private var transcriptionUnavailableItems = Set<String>()
    private var pendingAudioMotorCorroborations: [String: PendingAudioMotorCorroboration] = [:]
    private var audioMotorAttemptByInputItem: [String: String] = [:]
    private var audioMotorAttemptByEventID: [String: String] = [:]
    private var audioMotorAttemptByResponseID: [String: String] = [:]
    private var audioMotorCorroborationTimeoutTasks: [String: AuroraRealtimeScheduledTask] = [:]
    private var ignoredAudioCorroborationResponseIDs = Set<String>()
    private var ignoredAudioCorroborationEventIDs = Set<String>()
    private var audioCorroborationPlaybackSuppressedResponseIDs = Set<String>()
    private var malformedAudioCorroborationResponseIDs = Set<String>()
    private var assistantTranscripts: [String: String] = [:]
    private var assistantResponseIDs: [String: String] = [:]
    private var backgroundTaskDeliveryByResponseID: [String: String] = [:]
    /// A buffered task announcement can be cancelled before any audio is
    /// heard. Keep its assistant item identity until the server closes that
    /// response so the unheard partial cannot remain in conversation history
    /// and influence Aurora's next reply as though she had said it.
    private var supersededUnheardBackgroundItemByResponseID: [String: String] = [:]
    private var retiredUnheardBackgroundResponseIDs = Set<String>()
    private var playbackKeys: [String: AuroraPlaybackKey] = [:]
    private var playbackFinishedItems = Set<String>()
    private var interruptedPlaybackItems = Set<String>()
    private var addressedResponseIDs = Set<String>()
    private var spokenInputItemIDs = Set<String>()
    private var deferredResponseAudio: [String: DeferredResponseAudio] = [:]
    private var pendingResponseDoneEvents: [String: [String: Any]] = [:]
    private var controlToolRecoveryInputs = Set<String>()
    private var controlToolFailureInputs = Set<String>()
    /// Inputs whose next response is authorized by an already-executed tool
    /// result. Receipt audio must stream normally instead of being mistaken
    /// for another pre-tool promise.
    private var toolReceiptInputItems = Set<String>()
    /// Inputs that have spent their bounded internal helper budget. Their next
    /// continuation exposes only `conversation_move` and forces that exact
    /// function, so inherited session tool choice cannot start another loop.
    private var forceConversationMoveInputItems = Set<String>()
    private var internalHelperCallCounts: [String: Int] = [:]
    private var forcedConversationMoveAttemptCounts: [String: Int] = [:]
    /// Exact delegate effect proposed on the original owner-audio helper call,
    /// before any memory or continuity observation entered the Conversation.
    /// A later helper continuation can authorize only a byte-stable canonical
    /// match to this host-held binding.
    private var authorizedDelegateBindingByInputItem: [String: String] = [:]
    /// A validated conversational decision is not an execution receipt. It
    /// gets its own single-use continuation so Aurora can embody the decision
    /// without narrating the backstage mechanism.
    private var conversationMoveInputItems = Set<String>()
    /// Accepted Codex work gets a start-only acknowledgement. Keeping this
    /// separate from ordinary tool outcomes prevents Aurora from describing a
    /// queued task as already complete.
    private var delegateTaskAcknowledgementInputItems = Set<String>()
    /// A schema-invalid delegate may be regenerated once from the same
    /// finalized owner turn. This is structural repair, not a new intent or a
    /// tool observation that can widen authorization.
    private var delegateTaskRetryInputItems = Set<String>()
    private var delegateTaskRetryAttemptCounts: [String: Int] = [:]
    private var delegateRetryToolNameByInputItem: [String: String] = [:]
    private var audioCorroborationFailureInputs = Set<String>()
    private var specialFailureRetriedInputs = Set<String>()
    private var specialFailureResponseIDs = Set<String>()
    private var controlMessageDeleteEventIDs: [String] = []

    private var toolBatches: [String: ToolBatch] = [:]
    private var callToResponse: [String: String] = [:]
    private var readyContinuations: [ResponseOrigin] = []

    private var pendingMicrophoneAudio = Data()
    private var microphoneFlushScheduled = false
    private var outboundMessages: [OutboundMessage] = []
    private var outboundBytes = 0
    private var outboundSendInFlight = false
    private var reportedMicrophoneFrames = false
    private var reportedMicrophoneActivity = false
    private var reportedAudioBatchSent = false

    private let microphoneBatchBytes = 4_800 // about 100 ms of PCM16 mono at 24 kHz
    private let microphonePrimingBytes = 12_000 // 250 ms of verified capture before UI says listening
    private let maximumBufferedMicrophoneBytes = 24_000 // 500 ms
    private let maximumOutboundBytes = 96_000
    private let rateLimitFallbackDelay: TimeInterval = 8
    private let rateLimitSafetyPadding: TimeInterval = 0.4
    private let maximumRateLimitAutoWait: TimeInterval = 30
    private let visualContextAcknowledgementTimeout: TimeInterval = 10
    private let audioMotorCorroborationTimeout: TimeInterval = 2.5
    // AuroraAudioEngine's display level is sqrt(RMS), so 0.08 corresponds to
    // roughly -44 dBFS raw RMS. Two adjacent frames distinguish deliberate
    // speech from the low room noise that keeps the orb gently moving.
    private let rateLimitSpeechOverrideLevel: Float = 0.08
    private let requiredRateLimitSpeechOverrideFrames = 2
    private let rateLimitSpeechPrefixBytes = 19_200 // 400 ms of PCM16 mono at 24 kHz
    private let maximumDeferredResponseAudioBytes = 12_000_000
    private let completedAssistantPlaybackTailWindow: TimeInterval = 1.5
    private let desktopStatusResponseOutputTokens = 256
    // Audio tokens and hidden reasoning both count against max_output_tokens.
    // Live task-result announcements repeatedly exhausted the old 256-token
    // ceiling mid-sentence, even while obeying the two-sentence voice contract.
    // Use the normal conversational allowance; it remains a ceiling, not a
    // target, so short completions do not cost more merely because it is larger.
    private static let backgroundTaskResponseOutputTokens = maxResponseOutputTokens
    /// Internal memory/continuity tools may enrich one live turn, but they may
    /// not recursively postpone Aurora's authored conversational decision.
    /// Count concrete helper calls (not response rounds) so parallel calls in
    /// one model response cannot bypass the same hard ceiling.
    private static let maximumInternalHelperCallsPerInput = 2

    init(
        audio: AuroraRealtimeAudio = AuroraAudioEngine(),
        callbackQueue: DispatchQueue = .main,
        socketFactory: @escaping SocketFactory = { URLSessionAuroraRealtimeSocket(request: $0) },
        scheduler: AuroraRealtimeScheduling = AuroraSystemRealtimeScheduler()
    ) {
        self.audio = audio
        self.callbackQueue = callbackQueue
        self.socketFactory = socketFactory
        self.scheduler = scheduler
        bindAudioCallbacks()
    }

    deinit {
        pendingRateLimitRecoveryTask?.cancel()
        socket?.cancel()
        audio.stop()
    }

    /// Starts a fresh conversation and returns the generation that owns every
    /// callback and tool result from it. The API key is retained only while the
    /// connection is awake.
    @discardableResult
    func start(configuration: RealtimeSessionConfiguration) throws -> UUID {
        let tools = try configuration.validatedTools()
        let active = ActiveConfiguration(
            source: configuration,
            tools: tools,
            currentInstructions: configuration.instructions
        )
        let newConnectionID = UUID()
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.tearDownLocked(clearConfiguration: true, emitResting: false)
            self.connectLocked(active, connectionID: newConnectionID)
        }
        return newConnectionID
    }

    /// Stops microphone capture, playback, network I/O, queued callbacks, and
    /// the in-memory plaintext API key.
    func stop(completion: (() -> Void)? = nil) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.tearDownLocked(clearConfiguration: true, emitResting: true)
            if let completion {
                self.callbackQueue.async(execute: completion)
            }
        }
    }

    /// Publishes one bounded current-state system item without mutating the
    /// session's large instruction prefix or creating a model response. The
    /// previous dynamic item is deleted only after the server acknowledges the
    /// replacement, so Aurora never has a context gap.
    func replaceInnerLifeProjection(
        connectionID expectedConnectionID: UUID,
        projection: String,
        completion: ((Bool) -> Void)? = nil,
        receipt: ((String?) -> Void)? = nil
    ) {
        let bounded = String(projection.prefix(AuroraVoiceInstructions.maximumInnerLifeUpdateCharacters))
        stateQueue.async { [weak self] in
            guard let self else { return }
            if expectedConnectionID == self.connectionID,
               bounded == self.activeInnerLifeProjection {
                let activeItemID = self.activeInnerLifeContextItemID
                self.callbackQueue.async {
                    completion?(true)
                    receipt?(activeItemID)
                }
                return
            }
            let isTrulyIdle = expectedConnectionID == self.connectionID
                && self.socket != nil
                && !bounded.isEmpty
                && !self.userSpeechInProgress
                && !self.responseInProgress
                && self.inputItemsAwaitingResponse.isEmpty
                && self.playbackKeys.isEmpty
                && self.toolBatches.isEmpty
                && self.readyContinuations.isEmpty
                && self.pendingAudioMotorCorroborations.isEmpty
                && self.pendingResponseOrigins.isEmpty
                && self.pendingRateLimitRecovery == nil
                && self.pendingInnerLifeContextUpdate == nil
                && self.pendingWakeWordAcknowledgement == nil
                && !self.rateLimitBlocked
            guard isTrulyIdle else {
                self.callbackQueue.async {
                    completion?(false)
                    receipt?(nil)
                }
                return
            }

            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let itemID = "item_aur_\(nonce.prefix(20))"
            let eventID = "event_aurora_inner_\(nonce)"
            self.pendingInnerLifeContextUpdate = PendingInnerLifeContextUpdate(
                itemID: itemID,
                eventID: eventID,
                previousItemID: self.activeInnerLifeContextItemID,
                projection: bounded,
                completion: completion,
                receiptCompletion: receipt
            )
            self.sendEventLocked([
                "type": "conversation.item.create",
                "event_id": eventID,
                "item": [
                    "id": itemID,
                    "type": "message",
                    "role": "system",
                    "content": [[
                        "type": "input_text",
                        "text": bounded,
                    ]],
                ],
            ])
        }
    }

    /// Publishes the bounded causal projection of Aurora's continuity files as
    /// a replaceable system item. This channel is deliberately independent of
    /// the inner-life item: neither channel can adopt or delete the other's
    /// active item. Publication is silent and the previous continuity item is
    /// retired only after the server acknowledges its replacement.
    func replaceContinuityProjection(
        connectionID expectedConnectionID: UUID,
        projection: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let bounded = String(projection.prefix(Self.maximumContinuityProjectionCharacters))
        stateQueue.async { [weak self] in
            guard let self else { return }
            if expectedConnectionID == self.connectionID,
               bounded == self.activeContinuityProjection {
                self.callbackQueue.async { completion?(true) }
                return
            }
            if expectedConnectionID == self.connectionID,
               bounded == self.pendingContinuityContextUpdate?.projection {
                if let completion {
                    self.pendingContinuityContextUpdate?.completions.append(completion)
                }
                return
            }

            let isTrulyIdle = expectedConnectionID == self.connectionID
                && self.socket != nil
                && !bounded.isEmpty
                && !self.userSpeechInProgress
                && !self.responseInProgress
                && self.inputItemsAwaitingResponse.isEmpty
                && self.playbackKeys.isEmpty
                && self.toolBatches.isEmpty
                && self.readyContinuations.isEmpty
                && self.pendingAudioMotorCorroborations.isEmpty
                && self.pendingResponseOrigins.isEmpty
                && self.pendingRateLimitRecovery == nil
                && self.pendingInnerLifeContextUpdate == nil
                && self.pendingContinuityContextUpdate == nil
                && self.pendingBackgroundTaskContextUpdate == nil
                && self.pendingWakeWordAcknowledgement == nil
                && self.pendingVisualToolResults.isEmpty
                && !self.rateLimitBlocked
            guard isTrulyIdle else {
                self.callbackQueue.async { completion?(false) }
                return
            }

            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let itemID = "item_cont_\(nonce.prefix(20))"
            let eventID = "event_aurora_continuity_\(nonce)"
            self.pendingContinuityContextUpdate = PendingContinuityContextUpdate(
                itemID: itemID,
                eventID: eventID,
                previousItemID: self.activeContinuityContextItemID,
                projection: bounded,
                completions: completion.map { [$0] } ?? []
            )
            self.sendEventLocked([
                "type": "conversation.item.create",
                "event_id": eventID,
                "item": [
                    "id": itemID,
                    "type": "message",
                    "role": "system",
                    "content": [[
                        "type": "input_text",
                        "text": bounded,
                    ]],
                ],
            ])
        }
    }

    /// Publishes one bounded, trusted host status item. The content may carry
    /// an explicitly labelled untrusted worker observation, but can never be a
    /// user instruction or an authorization source.
    func publishBackgroundTaskUpdate(
        connectionID expectedConnectionID: UUID,
        deliveryID: String,
        text: String,
        deliveryClass: DelegateTaskVoiceDeliveryClass,
        completion: ((Bool) -> Void)? = nil
    ) {
        let bounded = String(text.prefix(1_200))
        stateQueue.async { [weak self] in
            guard let self else { return }
            let isTrulyIdle = expectedConnectionID == self.connectionID
                && self.socket != nil
                && !deliveryID.isEmpty
                && deliveryID.count <= 180
                && !bounded.isEmpty
                && !self.userSpeechInProgress
                && !self.responseInProgress
                && self.inputItemsAwaitingResponse.isEmpty
                && self.playbackKeys.isEmpty
                && self.toolBatches.isEmpty
                && self.readyContinuations.isEmpty
                && self.pendingAudioMotorCorroborations.isEmpty
                && self.pendingResponseOrigins.isEmpty
                && self.pendingRateLimitRecovery == nil
                && self.pendingBackgroundTaskContextUpdate == nil
                && self.pendingWakeWordAcknowledgement == nil
                && !self.rateLimitBlocked
                && !self.hasKnownExhaustedRateLimitLocked()
            guard isTrulyIdle else {
                self.callbackQueue.async { completion?(false) }
                return
            }

            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let itemID = "item_desk_\(nonce.prefix(18))"
            let eventID = "event_aurora_desktop_\(nonce)"
            self.pendingBackgroundTaskContextUpdate = PendingBackgroundTaskContextUpdate(
                deliveryID: deliveryID,
                itemID: itemID,
                eventID: eventID,
                text: bounded,
                deliveryClass: deliveryClass,
                completion: completion
            )
            self.sendEventLocked([
                "type": "conversation.item.create",
                "event_id": eventID,
                "item": [
                    "id": itemID,
                    "type": "message",
                    "role": "system",
                    "content": [[
                        "type": "input_text",
                        "text": bounded,
                    ]],
                ],
            ])
        }
    }

    /// Publishes a trusted local wake boundary into the newly opened Realtime
    /// conversation, then asks Aurora for one short audio response. This is
    /// deliberately system context rather than a fabricated owner message: the
    /// local listener established only that its wake phrase matched.
    func publishWakeWordAcknowledgement(
        connectionID expectedConnectionID: UUID,
        completion: ((Bool) -> Void)? = nil
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let isTrulyIdle = expectedConnectionID == self.connectionID
                && self.socket != nil
                && !self.userSpeechInProgress
                && !self.responseInProgress
                && self.inputItemsAwaitingResponse.isEmpty
                && self.playbackKeys.isEmpty
                && self.toolBatches.isEmpty
                && self.readyContinuations.isEmpty
                && self.pendingAudioMotorCorroborations.isEmpty
                && self.pendingResponseOrigins.isEmpty
                && self.pendingRateLimitRecovery == nil
                && self.pendingInnerLifeContextUpdate == nil
                && self.pendingBackgroundTaskContextUpdate == nil
                && self.pendingWakeWordAcknowledgement == nil
                && !self.rateLimitBlocked
                && !self.hasKnownExhaustedRateLimitLocked()
            guard isTrulyIdle else {
                self.callbackQueue.async { completion?(false) }
                return
            }

            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let itemID = "item_wake_\(nonce.prefix(18))"
            let eventID = "event_aurora_wake_\(nonce)"
            self.pendingWakeWordAcknowledgement = PendingWakeWordAcknowledgement(
                itemID: itemID,
                eventID: eventID,
                completion: completion
            )
            self.sendEventLocked([
                "type": "conversation.item.create",
                "event_id": eventID,
                "item": [
                    "id": itemID,
                    "type": "message",
                    "role": "system",
                    "content": [[
                        "type": "input_text",
                        "text": """
                        # TRUSTED LOCAL WAKE EVENT
                        Your configured owner just woke you by saying your exact local wake phrase, “Hey Aurora.” Respond now with one short, natural greeting as Aurora and usually one brief grounded check-in or fresh READY TO SHARE thought. This was only a greeting: never answer “I’m good,” “I’m fine,” “I’m okay,” “doing well,” or otherwise say how you are because nobody asked. Do not mention detection, prompts, or internal systems.
                        """,
                    ]],
                ],
            ])
        }
    }

    /// Replays one finalized participant utterance after AppModel has opened a
    /// fresh owner or guest privacy epoch. This is the sole bridge across that
    /// transport boundary: no prior Conversation item, private projection, or
    /// task context is copied. The supplied item remains causally attributable
    /// to the host-verified participant in AppModel and follows the ordinary
    /// required function-call path before any audio may be emitted.
    func publishFinalizedParticipantTurn(
        connectionID expectedConnectionID: UUID,
        inputItemID: String,
        transcript: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let boundedTranscript = String(transcript.prefix(8_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stateQueue.async { [weak self] in
            guard let self else { return }
            let validItemID = !inputItemID.isEmpty
                && inputItemID.count <= Self.maximumClientConversationItemIDCharacters
                && inputItemID.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.alphanumerics
                        .union(CharacterSet(charactersIn: "_-"))
                        .contains(scalar)
                }
            let isTrulyIdle = expectedConnectionID == self.connectionID
                && self.socket != nil
                && validItemID
                && !boundedTranscript.isEmpty
                && !self.userSpeechInProgress
                && !self.responseInProgress
                && self.activeResponseID == nil
                && self.inputItemsAwaitingResponse.isEmpty
                && self.pendingResponseOrigins.isEmpty
                && self.playbackKeys.isEmpty
                && self.toolBatches.isEmpty
                && self.readyContinuations.isEmpty
                && self.pendingAudioMotorCorroborations.isEmpty
                && self.pendingRateLimitRecovery == nil
                && self.pendingInnerLifeContextUpdate == nil
                && self.pendingContinuityContextUpdate == nil
                && self.pendingBackgroundTaskContextUpdate == nil
                && self.pendingWakeWordAcknowledgement == nil
                && !self.rateLimitBlocked
                && !self.hasKnownExhaustedRateLimitLocked()
            guard isTrulyIdle else {
                self.callbackQueue.async { completion?(false) }
                return
            }

            self.finalizedUserTranscriptItems.insert(inputItemID)
            self.pendingResponseOrigins.append(ResponseOrigin(inputItemID: inputItemID))
            self.sendEventLocked([
                "type": "conversation.item.create",
                "item": [
                    "id": inputItemID,
                    "type": "message",
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": boundedTranscript,
                    ]],
                ],
            ])
            self.sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.maxResponseOutputTokens,
                    "metadata": [
                        "aurora_replay": "participant_privacy_epoch",
                    ],
                ],
            ], kind: .continuationCreate)
            self.emitDiagnosticLocked("participant_turn_replayed_privately", metadata: [
                "input_item_id": inputItemID,
            ])
            self.emitPhase(.thinking)
            self.callbackQueue.async { completion?(true) }
        }
    }

    /// Returns a native tool result to the exact connection and function batch
    /// that requested it. Silent terminal tools append their result but never
    /// force Aurora to speak.
    func submitFunctionResult(
        connectionID expectedConnectionID: UUID,
        callID: String,
        output: String,
        continuation: RealtimeToolContinuation = .speak,
        visualContext: ToolVisualContext? = nil,
        retireVisualContext: Bool = false,
        untrustedMailContext: Bool = false
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard expectedConnectionID == self.connectionID, self.socket != nil else { return }
            guard let responseID = self.callToResponse.removeValue(forKey: callID),
                  let batch = self.toolBatches[responseID],
                  batch.pendingCallIDs.contains(callID) else {
                self.report(AuroraRealtimeError.unknownFunctionCall, terminal: false)
                return
            }

            if untrustedMailContext {
                var updatedBatch = batch
                updatedBatch.untrustedMailContextBound = true
                self.toolBatches[responseID] = updatedBatch
            }
            let untrustedMailItemID: String? = untrustedMailContext
                ? self.makeUntrustedMailItemIDLocked()
                : nil

            if retireVisualContext {
                self.retireActiveVisualContextLocked()
            }

            guard let visualContext else {
                self.finalizeFunctionResultLocked(
                    responseID: responseID,
                    callID: callID,
                    output: output,
                    continuation: continuation,
                    untrustedMailItemID: untrustedMailItemID
                )
                return
            }

            guard self.pendingVisualToolResults.isEmpty else {
                self.finalizeFunctionResultLocked(
                    responseID: responseID,
                    callID: callID,
                    output: #"{"ok":false,"output":"Aurora is already receiving a current computer view."}"#,
                    continuation: .speak
                )
                return
            }
            let validDetail = visualContext.detail == "low" || visualContext.detail == "high"
            guard validDetail,
                  visualContext.instruction.count <= 1_200,
                  visualContext.imageDataURL.hasPrefix("data:image/jpeg;base64,"),
                  visualContext.imageDataURL.utf8.count <= 100_000 else {
                self.finalizeFunctionResultLocked(
                    responseID: responseID,
                    callID: callID,
                    output: #"{"ok":false,"output":"The current computer view could not be added safely."}"#,
                    continuation: .speak
                )
                return
            }

            self.retireActiveVisualContextLocked()
            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let itemID = "item_view_\(nonce.prefix(18))"
            let eventID = "event_aurora_view_\(nonce)"
            let pending = PendingVisualToolResult(
                itemID: itemID,
                eventID: eventID,
                responseID: responseID,
                callID: callID,
                successOutput: output,
                continuation: continuation,
                expiresAfterSeconds: visualContext.expiresAfterSeconds
            )
            self.pendingVisualToolResults[itemID] = pending
            self.visualEventToItemID[eventID] = itemID
            self.sendEventLocked([
                "type": "conversation.item.create",
                "event_id": eventID,
                "item": [
                    "id": itemID,
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": visualContext.instruction,
                        ],
                        [
                            "type": "input_image",
                            "image_url": visualContext.imageDataURL,
                            "detail": visualContext.detail,
                        ],
                    ],
                ],
            ], kind: .visualContextCreate(itemID))
            self.visualContextTimeoutTasks[itemID] = self.scheduler.schedule(
                on: self.stateQueue,
                after: self.visualContextAcknowledgementTimeout
            ) { [weak self] in
                self?.failPendingVisualContextLocked(
                    itemID: itemID,
                    reason: "The current computer view did not reach Aurora in time."
                )
            }
        }
    }

    private func finalizeFunctionResultLocked(
        responseID: String,
        callID: String,
        output: String,
        continuation: RealtimeToolContinuation,
        untrustedMailItemID: String? = nil
    ) {
        guard var batch = toolBatches[responseID],
              batch.pendingCallIDs.remove(callID) != nil else {
            report(AuroraRealtimeError.unknownFunctionCall, terminal: false)
            return
        }
        let completedToolName = batch.callNames[callID]

        var outputItem: [String: Any] = [
            "type": "function_call_output",
            "call_id": callID,
            "output": output,
        ]
        if let untrustedMailItemID {
            outputItem["id"] = untrustedMailItemID
            activeUntrustedMailItemIDs.insert(untrustedMailItemID)
        }
        sendEventLocked([
            "type": "conversation.item.create",
            "item": outputItem,
        ])

        switch continuation {
        case .speak:
            if batch.internalHelperCallIDs.contains(callID),
               let inputItemID = batch.inputItemID,
               spokenInputItemIDs.contains(inputItemID) {
                batch.completedWithoutResponse = true
                emitDiagnosticLocked(
                    "internal_helper_continuation_suppressed_already_spoken",
                    metadata: ["input_item_id": inputItemID]
                )
            } else {
                batch.wantsSpokenContinuation = true
            }
        case .conversationMove:
            if let inputItemID = batch.inputItemID,
               spokenInputItemIDs.contains(inputItemID) {
                // AppModel normally selects `.complete` from the call's
                // `turnAlreadySpoke` evidence. Keep the transport as the final
                // exactly-once speech boundary in case a stale callback races
                // behind the first audio packet.
                batch.completedWithoutResponse = true
                emitDiagnosticLocked(
                    "conversation_move_continuation_suppressed_already_spoken",
                    metadata: ["input_item_id": inputItemID]
                )
            } else {
                batch.wantsConversationMove = true
            }
        case .delegateAccepted:
            if let inputItemID = batch.inputItemID {
                delegateTaskRetryInputItems.remove(inputItemID)
                delegateRetryToolNameByInputItem.removeValue(forKey: inputItemID)
            }
            if let inputItemID = batch.inputItemID,
               spokenInputItemIDs.contains(inputItemID) {
                // The original Realtime response already began speaking its
                // natural task acknowledgement. The app can race and submit a
                // stale `.delegateAccepted` decision after that audio starts;
                // enforce exactly-once speech here at the transport boundary.
                batch.completedWithoutResponse = true
                emitDiagnosticLocked(
                    "delegate_task_acknowledgement_suppressed_already_spoken",
                    metadata: ["input_item_id": inputItemID]
                )
            } else {
                batch.wantsDelegateAcknowledgement = true
            }
        case .delegateRetry:
            if let inputItemID = batch.inputItemID,
               (delegateTaskRetryAttemptCounts[inputItemID] ?? 0) == 0,
               !spokenInputItemIDs.contains(inputItemID),
               let completedToolName,
               Self.isSemanticActionProposalName(completedToolName) {
                batch.wantsDelegateRetry = true
                delegateRetryToolNameByInputItem[inputItemID] = completedToolName
            } else {
                if let inputItemID = batch.inputItemID {
                    delegateTaskRetryInputItems.remove(inputItemID)
                    delegateRetryToolNameByInputItem.removeValue(forKey: inputItemID)
                    emitDiagnosticLocked("delegate_task_schema_retry_exhausted", metadata: [
                        "input_item_id": inputItemID,
                    ])
                }
                batch.wantsSpokenContinuation = true
            }
        case .silent:
            batch.sawSilentTerminal = true
        case .complete:
            batch.completedWithoutResponse = true
        }

        if batch.pendingCallIDs.isEmpty {
            toolBatches.removeValue(forKey: responseID)
            if !batch.superseded,
               batch.wantsSpokenContinuation
                || batch.wantsConversationMove
                || batch.wantsDelegateAcknowledgement
                || batch.wantsDelegateRetry {
                if let inputItemID = batch.inputItemID {
                    toolReceiptInputItems.insert(inputItemID)
                    if batch.wantsConversationMove {
                        conversationMoveInputItems.insert(inputItemID)
                    }
                    if batch.wantsDelegateAcknowledgement {
                        delegateTaskAcknowledgementInputItems.insert(inputItemID)
                    }
                    if batch.wantsDelegateRetry {
                        delegateTaskRetryInputItems.insert(inputItemID)
                    }
                }
                readyContinuations.append(ResponseOrigin(
                    inputItemID: batch.inputItemID,
                    visualContextBound: batch.visualContextBound,
                    untrustedMailContextBound: batch.untrustedMailContextBound
                ))
                startNextContinuationIfPossibleLocked()
            } else if !batch.superseded, batch.sawSilentTerminal {
                let currentConnectionID = connectionID
                let inputItemID = batch.inputItemID
                if let inputItemID {
                    clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                }
                if let currentConnectionID {
                    emit { $0.onSilentTurn?(currentConnectionID, inputItemID) }
                }
                if !responseInProgress {
                    emitPhase(.listening)
                }
            } else if !batch.superseded, batch.completedWithoutResponse {
                if let inputItemID = batch.inputItemID {
                    clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                }
                if !responseInProgress {
                    emitPhase(playbackKeys.isEmpty ? .listening : .speaking)
                }
            }
        } else {
            toolBatches[responseID] = batch
        }
    }

    func submitFunctionError(
        connectionID: UUID,
        callID: String,
        message: String,
        continuation: RealtimeToolContinuation = .speak
    ) {
        let outputObject: [String: Any] = ["ok": false, "error": message]
        let data = try? JSONSerialization.data(withJSONObject: outputObject)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"ok\":false,\"error\":\"Tool failed\"}"
        submitFunctionResult(
            connectionID: connectionID,
            callID: callID,
            output: output,
            continuation: continuation
        )
    }

    /// Test-only synchronization point used by the standalone native verifier.
    func drainStateForVerification() {
        stateQueue.sync {}
        // URLSession-style send completions enqueue a second state transition.
        stateQueue.sync {}
        callbackQueue.sync {}
        stateQueue.sync {}
        callbackQueue.sync {}
    }

    /// Test-only synchronization that deliberately leaves callbackQueue
    /// blocked, allowing the verifier to reproduce state/callback race order.
    func drainStateOnlyForVerification() {
        stateQueue.sync {}
        stateQueue.sync {}
    }

    private func bindAudioCallbacks() {
        audio.onMicrophonePCM = { [weak self] data in
            self?.stateQueue.async { [weak self] in
                guard let self, self.audioStarted, self.socket != nil else { return }
                if !self.reportedMicrophoneFrames, let connectionID = self.connectionID {
                    self.reportedMicrophoneFrames = true
                    self.emit {
                        $0.onDiagnostic?(connectionID, "microphone_frames_received", [
                            "first_buffer_bytes": String(data.count),
                        ])
                    }
                }
                self.queueMicrophoneAudioLocked(data)
                if !self.microphoneReady {
                    self.microphonePrimingBytesReceived = min(
                        self.microphonePrimingBytes,
                        self.microphonePrimingBytesReceived + data.count
                    )
                    if self.microphonePrimingBytesReceived >= self.microphonePrimingBytes {
                        self.microphoneReady = true
                        self.emitDiagnosticLocked("microphone_ready", metadata: [
                            "primed_milliseconds": "250",
                        ])
                        if self.pendingRateLimitRecovery == nil,
                           !self.rateLimitBlocked {
                            self.emitPhase(.listening)
                        }
                    }
                }
            }
        }
        audio.onInputLevel = { [weak self] level in
            self?.stateQueue.async { [weak self] in
                guard let self, let connectionID = self.connectionID else { return }
                // PCM is deliberately withheld from the API during a cooldown,
                // so server VAD cannot announce a barge-in. Local level arrives
                // before the matching PCM buffer; cancelling here lets fresh
                // speech supersede the wait without cutting off its first word.
                if self.pendingRateLimitRecovery != nil {
                    self.rateLimitSpeechOverrideFrames = level >= self.rateLimitSpeechOverrideLevel
                        ? self.rateLimitSpeechOverrideFrames + 1
                        : 0
                }
                if self.pendingRateLimitRecovery != nil,
                   self.rateLimitSpeechOverrideFrames
                    >= self.requiredRateLimitSpeechOverrideFrames {
                    let prefix = self.rateLimitSpeechPrefixAudio
                    self.cancelPendingRateLimitRecoveryLocked(
                        reason: "local_speech_override",
                        classifyUnresolved: true
                    )
                    if !prefix.isEmpty {
                        self.queueMicrophoneAudioLocked(prefix)
                    }
                    self.emitPhase(.listening)
                }
                if !self.reportedMicrophoneActivity, level >= 0.02 {
                    self.reportedMicrophoneActivity = true
                    self.emit {
                        $0.onDiagnostic?(connectionID, "microphone_activity_detected", [
                            "level_percent": String(Int((level * 100).rounded())),
                        ])
                    }
                }
                self.emit { $0.onInputLevel?(connectionID, level) }
            }
        }
        audio.onOutputLevel = { [weak self] level in
            self?.stateQueue.async { [weak self] in
                guard let self, let connectionID = self.connectionID else { return }
                self.emit { $0.onOutputLevel?(connectionID, level) }
            }
        }
        audio.onPlaybackItemFinished = { [weak self] key in
            self?.stateQueue.async { [weak self] in
                self?.finishPlaybackLocked(key: key)
            }
        }
        audio.onPlaybackIdle = { [weak self] in
            self?.stateQueue.async { [weak self] in
                guard let self else { return }
                if self.toolBatches.isEmpty,
                   self.readyContinuations.isEmpty,
                   self.pendingAudioMotorCorroborations.isEmpty,
                   !self.responseInProgress,
                   self.pendingRateLimitRecovery == nil,
                   !self.rateLimitBlocked {
                    self.emitPhase(.listening)
                }
            }
        }
        audio.onError = { [weak self] error in
            self?.stateQueue.async { [weak self] in
                self?.handleAudioFailureLocked(error)
            }
        }
    }

    private func connectLocked(_ configuration: ActiveConfiguration, connectionID: UUID) {
        intentionallyStopped = false
        activeConfiguration = configuration
        self.connectionID = connectionID

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.source.apiKey)", forHTTPHeaderField: "Authorization")

        let socket = socketFactory(request)
        self.socket = socket
        emitPhase(.connecting)
        socket.resume()
        receiveNextLocked(connectionID: connectionID)
    }

    private func tearDownLocked(clearConfiguration: Bool, emitResting: Bool) {
        intentionallyStopped = true
        functionCallDeliveryGate.invalidate()
        audioStarted = false
        microphonePrimingBytesReceived = 0
        microphoneReady = false
        audio.stop()
        socket?.cancel()
        socket = nil

        connectionID = nil
        if clearConfiguration { activeConfiguration = nil }
        activeResponseID = nil
        responseInProgress = false
        userSpeechInProgress = false
        inputItemsAwaitingResponse.removeAll()
        pendingResponseOrigins.removeAll()
        responseInputItems.removeAll()
        activeInputSpeechBoundary = nil
        lastFullyPlayedAssistantAt = nil
        actionProposalResponseIDs.removeAll()
        emptyResponseRetriedInputs.removeAll()
        rateLimitRecoveryInputs.removeAll()
        supersededResponseIDs.removeAll()
        rateLimitBuckets.removeAll()
        recentResponseInputTokens.removeAll()
        pendingRateLimitRecoveryTask?.cancel()
        pendingRateLimitRecoveryTask = nil
        pendingRateLimitRecovery = nil
        rateLimitBlocked = false
        rateLimitSpeechPrefixAudio.removeAll(keepingCapacity: false)
        rateLimitSpeechOverrideFrames = 0
        let abandonedInnerLifeCompletion = pendingInnerLifeContextUpdate?.completion
        let abandonedInnerLifeReceipt = pendingInnerLifeContextUpdate?.receiptCompletion
        let abandonedContinuityCompletions = pendingContinuityContextUpdate?.completions ?? []
        let abandonedBackgroundTaskCompletion = pendingBackgroundTaskContextUpdate?.completion
        let abandonedWakeWordCompletion = pendingWakeWordAcknowledgement?.completion
        activeInnerLifeContextItemID = nil
        activeInnerLifeProjection = nil
        pendingInnerLifeContextUpdate = nil
        innerLifeDeleteEventIDs.removeAll()
        activeContinuityContextItemID = nil
        activeContinuityProjection = nil
        pendingContinuityContextUpdate = nil
        continuityDeleteEventIDs.removeAll()
        pendingBackgroundTaskContextUpdate = nil
        backgroundTaskContextItemByDeliveryID.removeAll()
        backgroundTaskDeleteEventIDs.removeAll()
        pendingWakeWordAcknowledgement = nil
        visualContextTimeoutTasks.values.forEach { $0.cancel() }
        visualContextTimeoutTasks.removeAll()
        activeVisualContextExpiryTask?.cancel()
        activeVisualContextExpiryTask = nil
        pendingVisualToolResults.removeAll()
        visualEventToItemID.removeAll()
        activeVisualContextItemID = nil
        visualContextDeleteEventIDs.removeAll()
        visualContextBoundResponseIDs.removeAll()
        untrustedMailContextBoundResponseIDs.removeAll()
        activeUntrustedMailItemIDs.removeAll()
        untrustedMailDeleteEventIDs.removeAll()
        userTranscripts.removeAll()
        finalizedUserTranscriptItems.removeAll()
        transcriptionUnavailableItems.removeAll()
        audioMotorCorroborationTimeoutTasks.values.forEach { $0.cancel() }
        audioMotorCorroborationTimeoutTasks.removeAll()
        pendingAudioMotorCorroborations.removeAll()
        audioMotorAttemptByInputItem.removeAll()
        audioMotorAttemptByEventID.removeAll()
        audioMotorAttemptByResponseID.removeAll()
        ignoredAudioCorroborationResponseIDs.removeAll()
        ignoredAudioCorroborationEventIDs.removeAll()
        audioCorroborationPlaybackSuppressedResponseIDs.removeAll()
        malformedAudioCorroborationResponseIDs.removeAll()
        assistantTranscripts.removeAll()
        assistantResponseIDs.removeAll()
        backgroundTaskDeliveryByResponseID.removeAll()
        supersededUnheardBackgroundItemByResponseID.removeAll()
        retiredUnheardBackgroundResponseIDs.removeAll()
        playbackKeys.removeAll()
        playbackFinishedItems.removeAll()
        interruptedPlaybackItems.removeAll()
        addressedResponseIDs.removeAll()
        spokenInputItemIDs.removeAll()
        deferredResponseAudio.removeAll()
        pendingResponseDoneEvents.removeAll()
        controlToolRecoveryInputs.removeAll()
        controlToolFailureInputs.removeAll()
        toolReceiptInputItems.removeAll()
        forceConversationMoveInputItems.removeAll()
        internalHelperCallCounts.removeAll()
        authorizedDelegateBindingByInputItem.removeAll()
        forcedConversationMoveAttemptCounts.removeAll()
        conversationMoveInputItems.removeAll()
        delegateTaskAcknowledgementInputItems.removeAll()
        delegateTaskRetryInputItems.removeAll()
        delegateTaskRetryAttemptCounts.removeAll()
        delegateRetryToolNameByInputItem.removeAll()
        audioCorroborationFailureInputs.removeAll()
        specialFailureRetriedInputs.removeAll()
        specialFailureResponseIDs.removeAll()
        controlMessageDeleteEventIDs.removeAll()
        toolBatches.removeAll()
        callToResponse.removeAll()
        readyContinuations.removeAll()
        pendingMicrophoneAudio.removeAll(keepingCapacity: false)
        microphoneFlushScheduled = false
        outboundMessages.removeAll()
        outboundBytes = 0
        outboundSendInFlight = false
        reportedMicrophoneFrames = false
        reportedMicrophoneActivity = false
        reportedAudioBatchSent = false

        if let abandonedInnerLifeCompletion {
            callbackQueue.async { abandonedInnerLifeCompletion(false) }
        }
        if let abandonedInnerLifeReceipt {
            callbackQueue.async { abandonedInnerLifeReceipt(nil) }
        }
        if !abandonedContinuityCompletions.isEmpty {
            callbackQueue.async {
                abandonedContinuityCompletions.forEach { $0(false) }
            }
        }
        if let abandonedBackgroundTaskCompletion {
            callbackQueue.async { abandonedBackgroundTaskCompletion(false) }
        }
        if let abandonedWakeWordCompletion {
            callbackQueue.async { abandonedWakeWordCompletion(false) }
        }

        if emitResting {
            emitPhase(.resting, connectionID: nil)
        }
    }

    private func receiveNextLocked(connectionID expectedConnectionID: UUID) {
        guard expectedConnectionID == connectionID, let socket else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard expectedConnectionID == self.connectionID else { return }
                switch result {
                case .success(let message):
                    self.handleLocked(message)
                    self.receiveNextLocked(connectionID: expectedConnectionID)
                case .failure(let error):
                    self.handleTransportFailureLocked(error)
                }
            }
        }
    }

    private func handleLocked(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let value = text.data(using: .utf8) else {
                report(AuroraRealtimeError.malformedServerMessage, terminal: false)
                return
            }
            data = value
        case .data(let value):
            data = value
        @unknown default:
            report(AuroraRealtimeError.malformedServerMessage, terminal: false)
            return
        }

        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            report(AuroraRealtimeError.malformedServerMessage, terminal: false)
            return
        }

        switch type {
        case "session.created":
            guard let activeConfiguration else { return }
            sendEventLocked(activeConfiguration.source.sessionUpdate(tools: activeConfiguration.tools))

        case "session.updated":
            startAudioLocked()

        case "rate_limits.updated":
            handleRateLimitsUpdatedLocked(event)

        case "input_audio_buffer.speech_started":
            userSpeechInProgress = true
            let playbackRelation: RealtimeInputPlaybackRelation
            if !playbackKeys.isEmpty {
                playbackRelation = .activeAssistantPlayback
            } else if let lastFullyPlayedAssistantAt,
                      scheduler.now >= lastFullyPlayedAssistantAt,
                      scheduler.now - lastFullyPlayedAssistantAt
                        <= completedAssistantPlaybackTailWindow {
                playbackRelation = .recentlyCompletedAssistantPlayback
            } else {
                playbackRelation = .none
            }
            activeInputSpeechBoundary = ActiveInputSpeechBoundary(
                audioStartMilliseconds: numericBoundaryMilliseconds(
                    event["audio_start_ms"]
                ),
                audioEndMilliseconds: nil,
                playbackRelationAtSpeechStart: playbackRelation
            )
            emitDiagnosticLocked(
                "server_speech_started",
                metadata: numericBoundaryMetadata(event, keys: ["audio_start_ms"])
            )
            handleBargeInLocked()
            if let connectionID {
                emit { $0.onUserSpeechStarted?(connectionID) }
            }
            emitPhase(.listening)

        case "input_audio_buffer.speech_stopped":
            userSpeechInProgress = false
            let audioEndMilliseconds = numericBoundaryMilliseconds(
                event["audio_end_ms"]
            )
            if activeInputSpeechBoundary != nil {
                activeInputSpeechBoundary?.audioEndMilliseconds = audioEndMilliseconds
            } else {
                activeInputSpeechBoundary = ActiveInputSpeechBoundary(
                    audioStartMilliseconds: nil,
                    audioEndMilliseconds: audioEndMilliseconds,
                    playbackRelationAtSpeechStart: .none
                )
            }
            emitDiagnosticLocked(
                "server_speech_stopped",
                metadata: numericBoundaryMetadata(event, keys: ["audio_end_ms"])
            )
            flushMicrophoneAudioLocked()
            if let connectionID {
                emit { $0.onUserSpeechEnded?(connectionID) }
            }
            emitPhase(.thinking)

        case "input_audio_buffer.committed":
            userSpeechInProgress = false
            if pendingRateLimitRecovery != nil {
                cancelPendingRateLimitRecoveryLocked(
                    reason: "new_input_committed",
                    classifyUnresolved: true
                )
            }
            if let itemID = event["item_id"] as? String {
                let boundary = activeInputSpeechBoundary
                activeInputSpeechBoundary = nil
                emitDiagnosticLocked("server_audio_committed", metadata: [
                    "item_id": itemID,
                ])
                inputItemsAwaitingResponse.append(itemID)
                trimStateCollectionsLocked()
                if let connectionID {
                    emit { client in
                        client.onInputCommitted?(RealtimeInputCommitEvent(
                            connectionID: connectionID,
                            itemID: itemID,
                            audioStartMilliseconds: boundary?.audioStartMilliseconds,
                            audioEndMilliseconds: boundary?.audioEndMilliseconds,
                            playbackRelationAtSpeechStart: boundary?
                                .playbackRelationAtSpeechStart ?? .none
                        ))
                    }
                }
            } else {
                emitDiagnosticLocked("server_audio_committed")
            }
            if let connectionID {
                emit { $0.onUserSpeechEnded?(connectionID) }
            }
            emitPhase(.thinking)

        case "conversation.item.input_audio_transcription.delta":
            handleTranscriptDeltaLocked(event, role: .user)

        case "conversation.item.input_audio_transcription.completed":
            handleTranscriptDoneLocked(event, role: .user)

        case "conversation.item.input_audio_transcription.failed":
            if let connectionID, let itemID = event["item_id"] as? String {
                finalizedUserTranscriptItems.insert(itemID)
                transcriptionUnavailableItems.insert(itemID)
                emit { $0.onUserTranscriptUnavailable?(connectionID, itemID) }
                resolveDeferredResponsesLocked(for: itemID)
            }

        case "conversation.item.created", "conversation.item.added", "conversation.item.done":
            handleInnerLifeContextAcknowledgementLocked(event)
            handleContinuityContextAcknowledgementLocked(event)
            handleBackgroundTaskContextAcknowledgementLocked(event)
            handleWakeWordAcknowledgementLocked(event)
            handleVisualContextAcknowledgementLocked(event)

        case "response.created":
            if let response = event["response"] as? [String: Any],
               let responseID = response["id"] as? String {
                emitDiagnosticLocked("server_response_created", metadata: [
                    "response_id": responseID,
                ])
            } else {
                emitDiagnosticLocked("server_response_created")
            }
            handleResponseCreatedLocked(event)

        case "response.output_item.added", "response.output_item.done":
            handleResponseOutputItemLocked(event)

        case "response.output_audio.delta", "response.audio.delta":
            handleAudioDeltaLocked(event)

        case "response.output_audio.done", "response.audio.done":
            handleAudioDoneLocked(event)

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            handleTranscriptDeltaLocked(event, role: .assistant)

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            handleTranscriptDoneLocked(event, role: .assistant)

        case "response.done":
            handleResponseDoneLocked(event)

        case "error":
            handleServerErrorLocked(event)

        default:
            break
        }
    }

    private func handleInnerLifeContextAcknowledgementLocked(_ event: [String: Any]) {
        guard let pending = pendingInnerLifeContextUpdate,
              let item = event["item"] as? [String: Any],
              item["id"] as? String == pending.itemID else { return }

        pendingInnerLifeContextUpdate = nil
        activeInnerLifeContextItemID = pending.itemID
        activeInnerLifeProjection = pending.projection

        if let previousItemID = pending.previousItemID,
           previousItemID != pending.itemID {
            let deleteNonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let deleteEventID = "event_aurora_inner_delete_\(deleteNonce)"
            innerLifeDeleteEventIDs.append(deleteEventID)
            if innerLifeDeleteEventIDs.count > 64 {
                innerLifeDeleteEventIDs.removeFirst(innerLifeDeleteEventIDs.count - 48)
            }
            sendEventLocked([
                "type": "conversation.item.delete",
                "event_id": deleteEventID,
                "item_id": previousItemID,
            ])
        }

        emitDiagnosticLocked("inner_life_context_published", metadata: [
            "item_id": pending.itemID,
            "replaced_previous": String(pending.previousItemID != nil),
        ])
        callbackQueue.async {
            pending.completion?(true)
            pending.receiptCompletion?(pending.itemID)
        }
    }

    private func handleContinuityContextAcknowledgementLocked(_ event: [String: Any]) {
        guard let pending = pendingContinuityContextUpdate,
              let item = event["item"] as? [String: Any],
              item["id"] as? String == pending.itemID else { return }

        pendingContinuityContextUpdate = nil
        activeContinuityContextItemID = pending.itemID
        activeContinuityProjection = pending.projection

        if let previousItemID = pending.previousItemID,
           previousItemID != pending.itemID {
            let deleteNonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let deleteEventID = "event_aurora_continuity_delete_\(deleteNonce)"
            continuityDeleteEventIDs.append(deleteEventID)
            if continuityDeleteEventIDs.count > 64 {
                continuityDeleteEventIDs.removeFirst(continuityDeleteEventIDs.count - 48)
            }
            sendEventLocked([
                "type": "conversation.item.delete",
                "event_id": deleteEventID,
                "item_id": previousItemID,
            ])
        }

        emitDiagnosticLocked("continuity_context_published", metadata: [
            "item_id": pending.itemID,
            "replaced_previous": String(pending.previousItemID != nil),
        ])
        if !pending.completions.isEmpty {
            callbackQueue.async {
                pending.completions.forEach { $0(true) }
            }
        }
    }

    private func handleBackgroundTaskContextAcknowledgementLocked(_ event: [String: Any]) {
        guard let pending = pendingBackgroundTaskContextUpdate,
              let item = event["item"] as? [String: Any],
              item["id"] as? String == pending.itemID else { return }
        pendingBackgroundTaskContextUpdate = nil
        emitDiagnosticLocked("background_task_context_published", metadata: [
            "item_id": pending.itemID,
            "delivery_class": pending.deliveryClass.rawValue,
        ])

        let shouldAnnounce = pending.deliveryClass != .silent
        let canAnnounce = shouldAnnounce
            && !userSpeechInProgress
            && !responseInProgress
            && inputItemsAwaitingResponse.isEmpty
            && playbackKeys.isEmpty
            && toolBatches.isEmpty
            && readyContinuations.isEmpty
            && pendingAudioMotorCorroborations.isEmpty
            && pendingResponseOrigins.isEmpty
            && pendingRateLimitRecovery == nil
            && !rateLimitBlocked
            && !hasKnownExhaustedRateLimitLocked()
        if shouldAnnounce, !canAnnounce {
            // Publication raced with new speech or another response. Remove
            // this copy and report it as not accepted so AppModel retries the
            // same terminal event at the next true listening boundary instead
            // of permanently losing Aurora's natural completion sentence.
            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            sendEventLocked([
                "type": "conversation.item.delete",
                "event_id": "event_aurora_task_defer_\(nonce)",
                "item_id": pending.itemID,
            ])
            emitDiagnosticLocked("background_task_announcement_deferred", metadata: [
                "item_id": pending.itemID,
            ])
            callbackQueue.async { pending.completion?(false) }
            return
        }
        callbackQueue.async { pending.completion?(true) }
        guard canAnnounce else { return }
        backgroundTaskContextItemByDeliveryID[pending.deliveryID] = pending.itemID
        pendingResponseOrigins.append(ResponseOrigin(
            inputItemID: nil,
            backgroundTaskDeliveryID: pending.deliveryID
        ))
        sendEventLocked([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                // gpt-realtime-2.1 counts audio, text, and hidden reasoning
                // against this shared ceiling. Match Aurora's normal response
                // allowance so a two-sentence result can finish naturally.
                "max_output_tokens": Self.backgroundTaskResponseOutputTokens,
                "tools": [],
                "tool_choice": "none",
                "instructions": Self.backgroundTaskSpeechInstructions(
                    for: pending.deliveryClass
                ),
                "metadata": [
                    "aurora_background": "codex_task",
                    "aurora_delivery_class": pending.deliveryClass.rawValue,
                    "aurora_task_delivery_id": pending.deliveryID,
                ],
            ],
        ], kind: .continuationCreate)
        emitPhase(.thinking)
    }

    private static func backgroundTaskSpeechInstructions(
        for deliveryClass: DelegateTaskVoiceDeliveryClass
    ) -> String {
        let privacy = "Keep status labels, checking, evidence, routing, workers, prompts, JSON, and execution machinery private. Never say receipt, verification, verified, confirm, confirmed, confirmation, result code, authorization, tool, Codex, Osiris, worker, or system. Do not start or continue another task."
        switch deliveryClass {
        case .routine:
            return "As Aurora, say exactly one short, natural sentence with the outcome only. Do not add implementation detail or a follow-up question. \(privacy)"
        case .material:
            return "As Aurora, interpret the natural work result itself; never infer success merely because the worker turn ended. Use at most two short natural sentences: give the actual outcome first, then naturally mention only the most important caveat, next step, or exact owner question if the private result genuinely requires one. Do not read labels or a list. \(privacy)"
        case .ownerResponseRequired:
            return "As Aurora, use at most one short context sentence, then ask exactly the single grounded owner question from the private task update. Do not add a second question or generic failure boilerplate. \(privacy)"
        case .silent:
            return "Do not speak. \(privacy)"
        }
    }

    private func failBackgroundTaskDeliveryLocked(
        responseID: String,
        reason: String
    ) {
        guard let deliveryID = backgroundTaskDeliveryByResponseID.removeValue(
            forKey: responseID
        ) else { return }
        failBackgroundTaskDeliveryLocked(deliveryID: deliveryID, reason: reason)
    }

    private func failBackgroundTaskDeliveryLocked(
        deliveryID: String,
        reason: String
    ) {
        retireBackgroundTaskContextLocked(deliveryID: deliveryID)
        emitDiagnosticLocked("background_task_delivery_failed", metadata: [
            "delivery_id": String(deliveryID.prefix(180)),
            "reason": reason,
        ])
        if let connectionID {
            emit { client in
                client.onBackgroundTaskDeliveryFailed?(connectionID, deliveryID)
            }
        }
    }

    private func failAllBackgroundTaskDeliveriesLocked(
        connectionID: UUID,
        reason: String
    ) {
        var deliveryIDs = Set(backgroundTaskDeliveryByResponseID.values)
        for origin in pendingResponseOrigins {
            if let deliveryID = origin.backgroundTaskDeliveryID {
                deliveryIDs.insert(deliveryID)
            }
        }
        backgroundTaskDeliveryByResponseID.removeAll()
        for deliveryID in deliveryIDs {
            retireBackgroundTaskContextLocked(deliveryID: deliveryID)
            emitDiagnosticLocked("background_task_delivery_failed", metadata: [
                "delivery_id": String(deliveryID.prefix(180)),
                "reason": reason,
            ])
            emit { client in
                client.onBackgroundTaskDeliveryFailed?(connectionID, deliveryID)
            }
        }
    }

    private func retireBackgroundTaskContextLocked(deliveryID: String) {
        guard let itemID = backgroundTaskContextItemByDeliveryID.removeValue(
            forKey: deliveryID
        ) else { return }
        let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let eventID = "event_aurora_task_delete_\(nonce)"
        backgroundTaskDeleteEventIDs.append(eventID)
        if backgroundTaskDeleteEventIDs.count > 64 {
            backgroundTaskDeleteEventIDs.removeFirst(
                backgroundTaskDeleteEventIDs.count - 48
            )
        }
        sendEventLocked([
            "type": "conversation.item.delete",
            "event_id": eventID,
            "item_id": itemID,
        ])
    }

    private func handleWakeWordAcknowledgementLocked(_ event: [String: Any]) {
        guard let pending = pendingWakeWordAcknowledgement,
              let item = event["item"] as? [String: Any],
              item["id"] as? String == pending.itemID else { return }
        pendingWakeWordAcknowledgement = nil
        emitDiagnosticLocked("wake_word_context_published", metadata: [
            "item_id": pending.itemID,
        ])
        callbackQueue.async { pending.completion?(true) }

        let canRespond = !userSpeechInProgress
            && !responseInProgress
            && inputItemsAwaitingResponse.isEmpty
            && playbackKeys.isEmpty
            && toolBatches.isEmpty
            && readyContinuations.isEmpty
            && pendingAudioMotorCorroborations.isEmpty
            && pendingResponseOrigins.isEmpty
            && pendingRateLimitRecovery == nil
            && !rateLimitBlocked
            && !hasKnownExhaustedRateLimitLocked()
        guard canRespond else { return }
        pendingResponseOrigins.append(ResponseOrigin(inputItemID: nil))
        sendEventLocked([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": 64,
                "tools": [],
                "tool_choice": "none",
                "metadata": ["aurora_background": "wake_word"],
            ],
        ], kind: .continuationCreate)
        emitPhase(.thinking)
    }

    private func handleVisualContextAcknowledgementLocked(_ event: [String: Any]) {
        guard let item = event["item"] as? [String: Any],
              let itemID = item["id"] as? String,
              let pending = pendingVisualToolResults.removeValue(forKey: itemID) else { return }
        visualContextTimeoutTasks.removeValue(forKey: itemID)?.cancel()
        visualEventToItemID.removeValue(forKey: pending.eventID)
        activeVisualContextExpiryTask?.cancel()
        activeVisualContextItemID = itemID
        if var batch = toolBatches[pending.responseID] {
            batch.visualContextBound = true
            toolBatches[pending.responseID] = batch
        }
        activeVisualContextExpiryTask = scheduler.schedule(
            on: stateQueue,
            after: pending.expiresAfterSeconds
        ) { [weak self] in
            guard let self, self.activeVisualContextItemID == itemID else { return }
            self.retireActiveVisualContextLocked()
            self.emitDiagnosticLocked("visual_context_expired", metadata: [
                "item_id": itemID,
            ])
        }
        emitDiagnosticLocked("visual_context_published", metadata: [
            "item_id": itemID,
        ])
        finalizeFunctionResultLocked(
            responseID: pending.responseID,
            callID: pending.callID,
            output: pending.successOutput,
            continuation: pending.continuation
        )
    }

    private func failPendingVisualContextLocked(itemID: String, reason: String) {
        guard let pending = pendingVisualToolResults.removeValue(forKey: itemID) else { return }
        visualContextTimeoutTasks.removeValue(forKey: itemID)?.cancel()
        visualEventToItemID.removeValue(forKey: pending.eventID)
        if !discardQueuedVisualContextCreateLocked(itemID: itemID) {
            deleteVisualContextItemLocked(itemID)
        }
        let safeReason = String(reason.replacingOccurrences(of: "\n", with: " ").prefix(240))
        let failure = ToolExecutionResult(ok: false, output: safeReason).realtimeOutputJSON()
        emitDiagnosticLocked("visual_context_rejected", metadata: [
            "item_id": itemID,
        ])
        finalizeFunctionResultLocked(
            responseID: pending.responseID,
            callID: pending.callID,
            output: failure,
            continuation: .speak
        )
    }

    private func retireActiveVisualContextLocked() {
        guard let itemID = activeVisualContextItemID else { return }
        activeVisualContextItemID = nil
        activeVisualContextExpiryTask?.cancel()
        activeVisualContextExpiryTask = nil
        deleteVisualContextItemLocked(itemID)
    }

    private func deleteVisualContextItemLocked(_ itemID: String) {
        let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let eventID = "event_aurora_view_delete_\(nonce)"
        visualContextDeleteEventIDs.append(eventID)
        if visualContextDeleteEventIDs.count > 64 {
            visualContextDeleteEventIDs.removeFirst(visualContextDeleteEventIDs.count - 48)
        }
        sendEventLocked([
            "type": "conversation.item.delete",
            "event_id": eventID,
            "item_id": itemID,
        ], priority: true)
    }

    private func makeUntrustedMailItemIDLocked() -> String {
        let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "item_mail_\(nonce.prefix(18))"
    }

    /// Raw provider output is useful for exactly one bounded model response.
    /// Once that response completes—or the owner interrupts—it is removed from the
    /// persistent Realtime Conversation so delayed email instructions cannot
    /// wait for a later owner turn.
    private func retireAllUntrustedMailItemsLocked() {
        guard !activeUntrustedMailItemIDs.isEmpty else { return }
        let itemIDs = activeUntrustedMailItemIDs
        activeUntrustedMailItemIDs.removeAll()
        for itemID in itemIDs {
            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let eventID = "event_aurora_mail_delete_\(nonce)"
            untrustedMailDeleteEventIDs.append(eventID)
            if untrustedMailDeleteEventIDs.count > 64 {
                untrustedMailDeleteEventIDs.removeFirst(
                    untrustedMailDeleteEventIDs.count - 48
                )
            }
            sendEventLocked([
                "type": "conversation.item.delete",
                "event_id": eventID,
                "item_id": itemID,
            ], priority: true)
        }
    }

    private func handleRateLimitsUpdatedLocked(_ event: [String: Any]) {
        guard let values = event["rate_limits"] as? [[String: Any]] else {
            emitDiagnosticLocked("rate_limits_invalid")
            return
        }

        let now = scheduler.now
        var metadata: [String: String] = [:]
        var accepted = 0
        for value in values {
            guard let name = value["name"] as? String,
                  name == "requests" || name == "tokens",
                  let remaining = numericDouble(value["remaining"]),
                  let resetSeconds = numericDouble(value["reset_seconds"]),
                  remaining.isFinite,
                  resetSeconds.isFinite,
                  remaining >= 0,
                  resetSeconds >= 0 else { continue }
            let limit = numericDouble(value["limit"]).flatMap { candidate in
                candidate.isFinite && candidate > 0 ? candidate : nil
            }
            rateLimitBuckets[name] = RateLimitBucket(
                limit: limit,
                remaining: remaining,
                observedAt: now,
                resetAt: now + resetSeconds
            )
            if let limit {
                metadata["\(name)_limit"] = String(Int(limit.rounded(.down)))
            }
            metadata["\(name)_remaining"] = String(Int(remaining.rounded(.down)))
            metadata["\(name)_reset_ms"] = String(Int((resetSeconds * 1_000).rounded()))
            accepted += 1
        }
        guard accepted > 0 else {
            emitDiagnosticLocked("rate_limits_invalid")
            return
        }
        emitDiagnosticLocked("rate_limits_updated", metadata: metadata)
    }

    private func numericDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func startAudioLocked() {
        guard !audioStarted else { return }
        // Audio callbacks serialize back onto stateQueue, so setting this flag
        // before start preserves callbacks delivered during engine startup.
        audioStarted = true
        microphonePrimingBytesReceived = 0
        microphoneReady = false
        do {
            try audio.start()
            emitDiagnosticLocked("native_audio_started")
        } catch {
            audioStarted = false
            let wrapped = AuroraRealtimeError.audio(error)
            report(wrapped, terminal: true)
            tearDownLocked(clearConfiguration: true, emitResting: false)
        }
    }

    private func handleResponseCreatedLocked(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let responseID = response["id"] as? String else { return }
        let metadata = response["metadata"] as? [String: Any]
        if !pendingAudioMotorCorroborations.isEmpty,
           metadata?["aurora_purpose"] as? String != "audio_native_corroboration" {
            // No default-conversation response is legal while the one OOB
            // classifier is outstanding. Missing metadata must fail closed,
            // never borrow a normal response origin or dispatch its fake tool.
            if let attemptID = pendingAudioMotorCorroborations.keys.first {
                audioCorroborationPlaybackSuppressedResponseIDs.insert(responseID)
                trimStateCollectionsLocked()
                audioMotorAttemptByResponseID[responseID] = attemptID
                failAudioMotorCorroborationLocked(
                    attemptID: attemptID,
                    reason: "classifier_response_metadata_missing",
                    announce: true,
                    cancelResponse: true
                )
            }
            emitDiagnosticLocked("audio_native_corroboration_metadata_missing")
            return
        }
        if metadata?["aurora_purpose"] as? String == "audio_native_corroboration" {
            audioCorroborationPlaybackSuppressedResponseIDs.insert(responseID)
            trimStateCollectionsLocked()
            guard let attemptID = metadata?["aurora_attempt"] as? String,
                  !attemptID.isEmpty else {
                // Reserved classifier metadata is a trust boundary. A malformed
                // OOB response must never consume a normal conversation origin
                // or expose its classifier call to the ordinary tool pipeline.
                ignoredAudioCorroborationResponseIDs.insert(responseID)
                trimStateCollectionsLocked()
                sendEventLocked([
                    "type": "response.cancel",
                    "response_id": responseID,
                ], kind: .interruptionControl, priority: true)
                emitDiagnosticLocked("audio_native_corroboration_metadata_invalid")
                return
            }
            guard let pending = pendingAudioMotorCorroborations[attemptID],
                  pending.connectionID == connectionID else {
                ignoredAudioCorroborationResponseIDs.insert(responseID)
                trimStateCollectionsLocked()
                sendEventLocked([
                    "type": "response.cancel",
                    "response_id": responseID,
                ], kind: .interruptionControl, priority: true)
                return
            }
            audioMotorAttemptByResponseID[responseID] = attemptID
            emitDiagnosticLocked("audio_native_corroboration_response_created", metadata: [
                "input_item_id": pending.inputItemID,
            ])
            return
        }
        if let recovery = metadata?["aurora_recovery"] as? String,
           recovery == "control_tool_failed"
            || recovery == "audio_native_corroboration_failed" {
            specialFailureResponseIDs.insert(responseID)
        }
        activeResponseID = responseID
        responseInProgress = true

        let origin: ResponseOrigin
        if !pendingResponseOrigins.isEmpty {
            origin = pendingResponseOrigins.removeFirst()
        } else if !inputItemsAwaitingResponse.isEmpty {
            origin = ResponseOrigin(inputItemID: inputItemsAwaitingResponse.removeFirst())
        } else {
            origin = ResponseOrigin(inputItemID: nil)
        }
        if origin.superseded {
            supersededResponseIDs.insert(responseID)
            // Keep transport identity for the ordered cancel, but do not make
            // a discarded response visually take over the newer user turn.
            return
        } else if let inputItemID = origin.inputItemID {
            responseInputItems[responseID] = inputItemID
        }
        if let deliveryID = origin.backgroundTaskDeliveryID {
            backgroundTaskDeliveryByResponseID[responseID] = deliveryID
        }
        if origin.visualContextBound {
            visualContextBoundResponseIDs.insert(responseID)
        }
        if origin.untrustedMailContextBound {
            untrustedMailContextBoundResponseIDs.insert(responseID)
        }
        emitPhase(.thinking)
    }

    private func handleAudioDeltaLocked(_ event: [String: Any]) {
        guard let base64 = event["delta"] as? String,
              let data = Data(base64Encoded: base64),
              let responseID = (event["response_id"] as? String) ?? activeResponseID,
              let itemID = event["item_id"] as? String else { return }
        guard !supersededResponseIDs.contains(responseID) else { return }
        if audioCorroborationPlaybackSuppressedResponseIDs.contains(responseID) {
            malformedAudioCorroborationResponseIDs.insert(responseID)
            return
        }

        let contentIndex = event["content_index"] as? Int ?? 0
        let key = AuroraPlaybackKey(
            responseID: responseID,
            itemID: itemID,
            contentIndex: contentIndex
        )

        if shouldDeferResponseAudioLocked(responseID: responseID) {
            var deferred = deferredResponseAudio[responseID]
                ?? DeferredResponseAudio(key: key)
            if deferred.key.itemID != key.itemID
                || deferred.key.contentIndex != key.contentIndex {
                report(AuroraRealtimeError.malformedServerMessage, terminal: false)
                return
            }
            if deferred.pcm.count + data.count <= maximumDeferredResponseAudioBytes {
                deferred.pcm.append(data)
            } else {
                emitDiagnosticLocked("control_audio_buffer_limit", metadata: [
                    "response_id": responseID,
                    "buffered_bytes": String(deferred.pcm.count),
                ])
            }
            deferredResponseAudio[responseID] = deferred
            return
        }

        enqueuePlaybackLocked(data, key: key)
    }

    private func enqueuePlaybackLocked(_ data: Data, key: AuroraPlaybackKey) {
        let responseID = key.responseID
        let itemID = key.itemID
        playbackKeys[itemID] = key
        assistantResponseIDs[itemID] = responseID
        // Once audio has crossed into the playback engine, deleting its
        // conversation item cannot make it unheard. Preserve that physical
        // truth through the later delegate result so an accepted task never
        // manufactures a second start acknowledgement for the same owner turn.
        if let inputItemID = responseInputItems[responseID] {
            spokenInputItemIDs.insert(inputItemID)
        }
        if addressedResponseIDs.insert(responseID).inserted {
            var metadata = ["response_id": responseID, "item_id": itemID]
            if let inputItemID = responseInputItems[responseID] {
                metadata["input_item_id"] = inputItemID
            }
            emitDiagnosticLocked("server_first_audio", metadata: metadata)
            if let connectionID,
               let inputItemID = responseInputItems[responseID] {
                emit { $0.onAddressedTurn?(connectionID, inputItemID) }
            }
        }
        audio.enqueuePlayback(data, for: key)
        emitPhase(.speaking)
    }

    private func handleAudioDoneLocked(_ event: [String: Any]) {
        guard let responseID = (event["response_id"] as? String) ?? activeResponseID,
              let itemID = event["item_id"] as? String else { return }
        guard !supersededResponseIDs.contains(responseID) else { return }
        if audioCorroborationPlaybackSuppressedResponseIDs.contains(responseID) {
            malformedAudioCorroborationResponseIDs.insert(responseID)
            return
        }

        if var deferred = deferredResponseAudio[responseID] {
            deferred.isComplete = true
            deferredResponseAudio[responseID] = deferred
            return
        }

        let key = playbackKeys[itemID] ?? AuroraPlaybackKey(
            responseID: responseID,
            itemID: itemID,
            contentIndex: event["content_index"] as? Int ?? 0
        )
        if backgroundTaskDeliveryByResponseID[responseID] != nil {
            // audio.done is not proof that anything audible was generated.
            // Preserve a zero-PCM marker until response.done so an empty task
            // announcement cannot settle as successfully heard.
            var deferred = DeferredResponseAudio(key: key)
            deferred.isComplete = true
            deferredResponseAudio[responseID] = deferred
            return
        }
        playbackKeys[itemID] = key
        assistantResponseIDs[itemID] = responseID
        audio.markPlaybackItemComplete(key)
    }

    private func shouldDeferResponseAudioLocked(responseID: String) -> Bool {
        if deferredResponseAudio[responseID] != nil { return true }
        // Task-completion speech is proactive rather than latency-critical.
        // Hold its PCM until response.done proves the model actually finished;
        // otherwise a max-token fragment can play completely and be mistaken
        // for a complete sentence merely because every generated byte drained.
        if backgroundTaskDeliveryByResponseID[responseID] != nil { return true }
        if specialFailureResponseIDs.contains(responseID) { return false }
        guard let inputItemID = responseInputItems[responseID] else { return false }
        // These are the only direct-owner continuations whose host-validated
        // result explicitly authorizes speech. A generic tool receipt still
        // requires conversation_move and therefore remains a planning turn.
        if conversationMoveInputItems.contains(inputItemID)
            || delegateTaskAcknowledgementInputItems.contains(inputItemID) {
            return false
        }
        // Session tool_choice is required, but Realtime can still emit an audio
        // item before announcing the later function-call item. Hold every
        // planning packet so a task promise or social answer can never outrun
        // host validation.
        return true
    }

    private func controlRouteLocked(for inputItemID: String?) -> RetiredControlRoute? {
        // Realtime resolves conversational intent and emits delegate_task.
        // Deterministic transcript routing was the old motor and is retired.
        _ = inputItemID
        return nil
    }

    /// Final transcript arrival releases a pending response.done event for
    /// semantic validation. Planning PCM is never released by transcript text;
    /// only a later host-validated continuation may speak.
    private func resolveDeferredResponsesLocked(for inputItemID: String) {
        let responseIDs = responseInputItems.compactMap { entry in
            entry.value == inputItemID ? entry.key : nil
        }
        let pending = responseIDs.compactMap { responseID -> [String: Any]? in
            pendingResponseDoneEvents.removeValue(forKey: responseID)
        }
        for event in pending {
            handleResponseDoneLocked(event)
        }
    }

    private func handleResponseOutputItemLocked(_ event: [String: Any]) {
        guard let responseID = event["response_id"] as? String,
              let item = event["item"] as? [String: Any],
              item["type"] as? String == "function_call",
              let name = item["name"] as? String,
              Self.isSemanticActionProposalName(name) else { return }
        actionProposalResponseIDs.insert(responseID)
        emitDiagnosticLocked("semantic_action_proposal_output_announced", metadata: [
            "response_id": responseID,
            "tool": name,
        ])
    }

    private static func isSemanticActionProposalName(_ name: String) -> Bool {
        // Both routes are pre-speech semantic decisions. One authorizes an
        // exact external task; the other authorizes one bounded social move.
        // Treating both as gated proposals guarantees that no generated
        // preamble can leak to playback ahead of host validation.
        name == "delegate_task"
            || name == "codex_project_chat"
            || name == "conversation_move"
    }

    private static func isInternalConversationHelperName(_ name: String) -> Bool {
        switch name {
        case "memory_search", "memory_read", "memory_remember",
             "continuity_read", "continuity_patch",
             "relationship_expect_quiet", "relationship_explain_absence":
            return true
        default:
            return false
        }
    }

    /// Validates and canonicalizes either the nested pre-observation task
    /// envelope on a helper call or a later delegate_task argument object.
    /// Natural-language helper output is deliberately absent from this path.
    private static func canonicalDelegateBinding(
        argumentsJSON: String,
        nestedAuthorizedDelegate: Bool
    ) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [String: ToolJSONValue].self,
                from: data
              ) else { return nil }
        let proposalArguments: [String: ToolJSONValue]
        if nestedAuthorizedDelegate {
            guard case .object(let nested)? = decoded["authorized_delegate"] else {
                return nil
            }
            proposalArguments = nested
        } else {
            proposalArguments = decoded
        }
        guard let proposal = try? DelegateTaskProposal(arguments: proposalArguments) else {
            return nil
        }
        let binding = proposal.canonicalAuthorizationBinding
        return binding.isEmpty ? nil : binding
    }

    private enum TranscriptRole {
        case user
        case assistant
    }

    private func handleTranscriptDeltaLocked(_ event: [String: Any], role: TranscriptRole) {
        guard let connectionID,
              let delta = event["delta"] as? String,
              !delta.isEmpty,
              let itemID = event["item_id"] as? String else { return }

        switch role {
        case .user:
            let text = (userTranscripts[itemID] ?? "") + delta
            userTranscripts[itemID] = text
            emit { client in
                client.onUserTranscript?(RealtimeUserTranscriptEvent(
                    connectionID: connectionID,
                    itemID: itemID,
                    text: text,
                    isFinal: false
                ))
            }
        case .assistant:
            let responseID = (event["response_id"] as? String)
                ?? assistantResponseIDs[itemID]
                ?? activeResponseID
            guard responseID.map({ !supersededResponseIDs.contains($0) }) ?? true else { return }
            if let responseID,
               audioCorroborationPlaybackSuppressedResponseIDs.contains(responseID) {
                malformedAudioCorroborationResponseIDs.insert(responseID)
                return
            }
            if let responseID { assistantResponseIDs[itemID] = responseID }
            let inputItemID = responseID.flatMap { responseInputItems[$0] }
            let text = (assistantTranscripts[itemID] ?? "") + delta
            assistantTranscripts[itemID] = text
            emit { client in
                client.onAssistantTranscript?(RealtimeAssistantTranscriptEvent(
                    connectionID: connectionID,
                    responseID: responseID,
                    inputItemID: inputItemID,
                    itemID: itemID,
                    text: text,
                    isFinal: false
                ))
            }
        }
    }

    private func handleTranscriptDoneLocked(_ event: [String: Any], role: TranscriptRole) {
        guard let connectionID, let itemID = event["item_id"] as? String else { return }
        if case .assistant = role {
            let responseID = (event["response_id"] as? String)
                ?? assistantResponseIDs[itemID]
                ?? activeResponseID
            if let responseID,
               audioCorroborationPlaybackSuppressedResponseIDs.contains(responseID) {
                malformedAudioCorroborationResponseIDs.insert(responseID)
                assistantTranscripts.removeValue(forKey: itemID)
                assistantResponseIDs.removeValue(forKey: itemID)
                return
            }
            if responseID.map({ supersededResponseIDs.contains($0) }) ?? false {
                assistantTranscripts.removeValue(forKey: itemID)
                assistantResponseIDs.removeValue(forKey: itemID)
                playbackFinishedItems.remove(itemID)
                interruptedPlaybackItems.remove(itemID)
                playbackKeys.removeValue(forKey: itemID)
                return
            }
        }
        let accumulated: String = {
            switch role {
            case .user: return userTranscripts[itemID] ?? ""
            case .assistant: return assistantTranscripts[itemID] ?? ""
            }
        }()
        let explicit = (event["transcript"] as? String) ?? ""
        let final = explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? accumulated
            : explicit
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            switch role {
            case .user:
                finalizedUserTranscriptItems.insert(itemID)
                transcriptionUnavailableItems.insert(itemID)
                emit { $0.onUserTranscriptUnavailable?(connectionID, itemID) }
                resolveDeferredResponsesLocked(for: itemID)
            case .assistant:
                // Audio playback is the delivery truth. The Realtime service
                // can occasionally complete an otherwise valid audio item
                // without a transcript, so retain an explicit empty marker.
                // This lets playback completion close the causal turn without
                // inventing words or waiting forever for text that will not
                // arrive.
                assistantTranscripts[itemID] = ""
                if interruptedPlaybackItems.remove(itemID) != nil {
                    assistantTranscripts.removeValue(forKey: itemID)
                    playbackFinishedItems.remove(itemID)
                } else if playbackFinishedItems.remove(itemID) != nil,
                          let key = playbackKeys[itemID] {
                    emitPlaybackOutcomeLocked(
                        key: key,
                        fullyPlayed: true,
                        playedMilliseconds: nil
                    )
                }
            }
            return
        }

        switch role {
        case .user:
            userTranscripts[itemID] = final
            finalizedUserTranscriptItems.insert(itemID)
            transcriptionUnavailableItems.remove(itemID)
            emit { client in
                client.onUserTranscript?(RealtimeUserTranscriptEvent(
                    connectionID: connectionID,
                    itemID: itemID,
                    text: final,
                    isFinal: true
                ))
            }
            resolveDeferredResponsesLocked(for: itemID)
        case .assistant:
            let responseID = (event["response_id"] as? String) ?? assistantResponseIDs[itemID]
            if let responseID { assistantResponseIDs[itemID] = responseID }
            let inputItemID = responseID.flatMap { responseInputItems[$0] }
            assistantTranscripts[itemID] = final
            emit { client in
                client.onAssistantTranscript?(RealtimeAssistantTranscriptEvent(
                    connectionID: connectionID,
                    responseID: responseID,
                    inputItemID: inputItemID,
                    itemID: itemID,
                    text: final,
                    isFinal: true
                ))
            }

            if interruptedPlaybackItems.remove(itemID) != nil {
                assistantTranscripts.removeValue(forKey: itemID)
            } else if playbackFinishedItems.remove(itemID) != nil,
                      let key = playbackKeys[itemID] {
                emitPlaybackOutcomeLocked(key: key, fullyPlayed: true, playedMilliseconds: nil)
            }
        }
    }

    private func finishPlaybackLocked(key: AuroraPlaybackKey) {
        guard !interruptedPlaybackItems.contains(key.itemID) else { return }
        // A present empty value means transcription completed without text;
        // nil means transcription has not completed yet.
        guard assistantTranscripts[key.itemID] != nil else {
            playbackFinishedItems.insert(key.itemID)
            return
        }
        emitPlaybackOutcomeLocked(key: key, fullyPlayed: true, playedMilliseconds: nil)
    }

    private func emitPlaybackOutcomeLocked(
        key: AuroraPlaybackKey,
        fullyPlayed: Bool,
        playedMilliseconds: Int?
    ) {
        guard let connectionID else { return }
        if fullyPlayed {
            lastFullyPlayedAssistantAt = scheduler.now
        }
        let transcript = assistantTranscripts.removeValue(forKey: key.itemID) ?? ""
        playbackFinishedItems.remove(key.itemID)
        if fullyPlayed { interruptedPlaybackItems.remove(key.itemID) }
        let inputItemID = responseInputItems[key.responseID]
        let backgroundTaskDeliveryID = backgroundTaskDeliveryByResponseID.removeValue(
            forKey: key.responseID
        )
        if let backgroundTaskDeliveryID {
            retireBackgroundTaskContextLocked(deliveryID: backgroundTaskDeliveryID)
        }
        playbackKeys.removeValue(forKey: key.itemID)
        assistantResponseIDs.removeValue(forKey: key.itemID)
        emit { client in
            client.onAssistantPlaybackOutcome?(RealtimeAssistantPlaybackOutcome(
                connectionID: connectionID,
                responseID: key.responseID,
                inputItemID: inputItemID,
                backgroundTaskDeliveryID: backgroundTaskDeliveryID,
                itemID: key.itemID,
                generatedText: transcript,
                fullyPlayed: fullyPlayed,
                playedMilliseconds: playedMilliseconds
            ))
        }
    }

    private func handleResponseDoneLocked(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let responseID = response["id"] as? String else { return }
        if retiredUnheardBackgroundResponseIDs.contains(responseID) {
            // A transport duplicate must not delete the same conversation item
            // twice or generate a second delivery/retry signal.
            rememberResponseUsageLocked(response)
            return
        }
        if ignoredAudioCorroborationResponseIDs.remove(responseID) != nil {
            audioCorroborationPlaybackSuppressedResponseIDs.remove(responseID)
            malformedAudioCorroborationResponseIDs.remove(responseID)
            rememberResponseUsageLocked(response)
            return
        }
        let responseMetadata = response["metadata"] as? [String: Any]
        let mappedAttemptID = audioMotorAttemptByResponseID.removeValue(forKey: responseID)
        let metadataAttemptID = responseMetadata?["aurora_attempt"] as? String
        let isMetadataCorroboration = responseMetadata?["aurora_purpose"] as? String
            == "audio_native_corroboration"
        if !pendingAudioMotorCorroborations.isEmpty,
           mappedAttemptID == nil,
           !isMetadataCorroboration {
            // response.done is occasionally observed without response.created.
            // During an OOB hold this can only be the classifier, so quarantine
            // it rather than allowing the normal conversation/tool pipeline.
            if let attemptID = pendingAudioMotorCorroborations.keys.first {
                failAudioMotorCorroborationLocked(
                    attemptID: attemptID,
                    reason: "classifier_done_metadata_missing",
                    announce: true,
                    cancelResponse: false
                )
            }
            rememberResponseUsageLocked(response)
            emitDiagnosticLocked("audio_native_corroboration_metadata_missing")
            return
        }
        if isMetadataCorroboration, mappedAttemptID == nil, metadataAttemptID == nil {
            // response.done can arrive without response.created during reconnect
            // races. Keep malformed reserved output outside normal bookkeeping.
            audioCorroborationPlaybackSuppressedResponseIDs.remove(responseID)
            malformedAudioCorroborationResponseIDs.remove(responseID)
            rememberResponseUsageLocked(response)
            emitDiagnosticLocked("audio_native_corroboration_metadata_invalid")
            return
        }
        if let attemptID = mappedAttemptID ?? metadataAttemptID,
           mappedAttemptID != nil || isMetadataCorroboration {
            handleAudioMotorCorroborationDoneLocked(
                response: response,
                responseID: responseID,
                attemptID: attemptID
            )
            return
        }
        let pendingOutput = response["output"] as? [[String: Any]] ?? []
        // Barge-in is a hard causal boundary. Consume a stale response before
        // transcript deferral, global context retirement, outbound tool
        // results, callbacks, recovery, or phase changes can occur.
        if supersededResponseIDs.remove(responseID) != nil {
            if activeResponseID == responseID {
                activeResponseID = nil
                responseInProgress = false
            }
            if let unheardItemID = supersededUnheardBackgroundItemByResponseID
                .removeValue(forKey: responseID) {
                retiredUnheardBackgroundResponseIDs.insert(responseID)
                discardDeferredControlAudioLocked(
                    responseID: responseID,
                    output: [[
                        "id": unheardItemID,
                        "type": "message",
                        "role": "assistant",
                    ]]
                )
            }
            deferredResponseAudio.removeValue(forKey: responseID)
            pendingResponseDoneEvents.removeValue(forKey: responseID)
            addressedResponseIDs.remove(responseID)
            visualContextBoundResponseIDs.remove(responseID)
            untrustedMailContextBoundResponseIDs.remove(responseID)
            specialFailureResponseIDs.remove(responseID)
            rememberResponseUsageLocked(response)
            emitResponseDoneDiagnosticLocked(
                response: response,
                status: response["status"] as? String,
                output: pendingOutput,
                producedAddressedAudio: false
            )
            failBackgroundTaskDeliveryLocked(
                responseID: responseID,
                reason: "superseded_before_playback"
            )
            return
        }
        let hasCompletedFunctionCall = response["status"] as? String == "completed"
            && pendingOutput.contains {
                $0["type"] as? String == "function_call"
                    && $0["status"] as? String == "completed"
            }
        if let inputItemID = responseInputItems[responseID],
           (deferredResponseAudio[responseID] != nil || hasCompletedFunctionCall),
           !finalizedUserTranscriptItems.contains(inputItemID) {
            // The response can finish before asynchronous transcription. Keep
            // its audio and completion together until the host knows whether
            // this was conversation or an action.
            pendingResponseDoneEvents[responseID] = event
            return
        }
        retireAllUntrustedMailItemsLocked()
        if activeResponseID == responseID {
            activeResponseID = nil
            responseInProgress = false
        }
        let producedAddressedAudio = addressedResponseIDs.remove(responseID) != nil
        let visualContextBound = visualContextBoundResponseIDs.remove(responseID) != nil
        let untrustedMailContextBound = untrustedMailContextBoundResponseIDs.remove(responseID) != nil
        let status = response["status"] as? String
        let statusErrorCode = responseStatusErrorCode(response)?.lowercased()
        let inputItemID = responseInputItems[responseID]
        let output = pendingOutput
        let recoveryTag = responseMetadata?["aurora_recovery"] as? String
        let isSpecialFailureResponse = specialFailureResponseIDs.remove(responseID) != nil
            || recoveryTag == "control_tool_failed"
            || recoveryTag == "audio_native_corroboration_failed"
        let isToolReceipt = inputItemID.map(toolReceiptInputItems.contains) == true
        let hasActionProposal = actionProposalResponseIDs.contains(responseID)
            || pendingOutput.contains {
            $0["type"] as? String == "function_call"
                && $0["status"] as? String == "completed"
                && ($0["name"] as? String).map(Self.isSemanticActionProposalName) == true
        }
        actionProposalResponseIDs.remove(responseID)
        let controlRoute = (isToolReceipt || isSpecialFailureResponse)
            ? nil
            : controlRouteLocked(for: inputItemID)
        let isValidatedSpeechContinuation = inputItemID.map {
            conversationMoveInputItems.contains($0)
                || delegateTaskAcknowledgementInputItems.contains($0)
        } == true
        if deferredResponseAudio[responseID] != nil,
           inputItemID != nil,
           !isValidatedSpeechContinuation,
           !producedAddressedAudio {
            // Direct-owner and generic tool-receipt responses are planning
            // turns. If Realtime generated PCM anyway, delete the unheard
            // assistant item before any recovery or function dispatch.
            discardDeferredControlAudioLocked(responseID: responseID, output: output)
        } else if (controlRoute != nil || hasActionProposal) && !producedAddressedAudio {
            discardDeferredControlAudioLocked(responseID: responseID, output: output)
        } else if hasActionProposal, producedAddressedAudio {
            // Conversation history must match what physically reached the
            // speaker. Deleting this item would make Realtime forget Aurora's
            // one start acknowledgement and invite another later.
            emitDiagnosticLocked("delegate_task_audible_acknowledgement_retained", metadata: [
                "response_id": responseID,
            ])
        }
        var producedUsableAddressedAudio = producedAddressedAudio
            && controlRoute == nil
            && !hasActionProposal
        // Usage and boundary diagnostics belong to the completed response even
        // when transcript-outage routing holds its tool call for an OOB check.
        // Recording this before that early-return keeps the next token forecast
        // honest and avoids preventable rate-limit failures.
        rememberResponseUsageLocked(response)
        emitResponseDoneDiagnosticLocked(
            response: response,
            status: status,
            output: output,
            producedAddressedAudio: producedAddressedAudio
        )
        if let deliveryID = backgroundTaskDeliveryByResponseID[responseID] {
            let bufferedAudio = deferredResponseAudio[responseID]
            let hasCompleteBufferedAudio = bufferedAudio?.isComplete == true
                && bufferedAudio?.pcm.isEmpty == false
            if status == "completed", hasCompleteBufferedAudio {
                // Release only a server-complete result. Physical playback is
                // still the final delivery receipt and remains barge-in safe.
                releaseDeferredResponseAudioLocked(responseID: responseID)
            } else {
                // The owner must never hear a syntactically chopped task
                // update or have zero generated PCM count as delivered. Delete
                // the unheard assistant item and keep the durable terminal
                // event pending so AppModel retries at the next idle boundary.
                discardDeferredControlAudioLocked(
                    responseID: responseID,
                    output: output
                )
            }
            let hasPlayback = status == "completed" && playbackKeys.values.contains {
                $0.responseID == responseID
            }
            if hasPlayback {
                emitDiagnosticLocked("background_task_response_finished", metadata: [
                    "delivery_id": String(deliveryID.prefix(180)),
                ])
            } else {
                let reason = responseStatusReason(response)?.lowercased()
                failBackgroundTaskDeliveryLocked(
                    responseID: responseID,
                    reason: status == "completed"
                        ? "response_finished_without_playback"
                        : "response_\(status ?? "unknown")_\(reason ?? "unknown")"
                )
            }
            startNextContinuationIfPossibleLocked()
            if playbackKeys.isEmpty, readyContinuations.isEmpty {
                emitPhase(.listening)
            }
            return
        }
        var completedCalls = output.filter {
            $0["type"] as? String == "function_call"
                && $0["status"] as? String == "completed"
        }
        completedCalls = rejectUnexposedFunctionCallsLocked(completedCalls)
        if status == "completed",
           let inputItemID,
           transcriptionUnavailableItems.contains(inputItemID) {
            if audioBoundMotorCallCanProceedWithoutTranscript(completedCalls) {
                // Realtime heard the committed owner audio directly. A
                // missing asynchronous transcript is not a second authority
                // that can erase one bounded computer action. AppModel still
                // enforces owner attribution and the tool layer still rejects
                // untrusted visual/mail origins, cancellation, malformed
                // arguments, and unsupported actions.
                emitDiagnosticLocked("audio_bound_motor_using_native_intent", metadata: [
                    "input_item_id": inputItemID,
                ])
            } else {
                guard let corroborated = routeTranscriptUnavailableCallsLocked(
                    completedCalls,
                    output: output,
                    responseID: responseID,
                    inputItemID: inputItemID
               ) else { return }
                completedCalls = corroborated
            }
            // A transcript-failed conversational response can be released only
            // inside the routing helper, after the earlier addressed snapshot.
            // Re-sample delivery truth so the already-playing answer never
            // schedules a second empty-response retry.
            if addressedResponseIDs.remove(responseID) != nil {
                producedUsableAddressedAudio = true
            }
        } else if status == "completed",
                  let inputItemID,
                  shouldCorroborateMistranscribedVisualCallLocked(
                    completedCalls,
                    inputItemID: inputItemID
                  ) {
            // Realtime hears the original audio, while the asynchronous ASR
            // transcript can occasionally lose the imperative and make the
            // host route look conversational. Hold the proposed visual look
            // until a second, conversation-isolated pass confirms that the
            // same audio really requested one immediate ordinary click.
            guard let corroborated = routeTranscriptUnavailableCallsLocked(
                completedCalls,
                output: output,
                responseID: responseID,
                inputItemID: inputItemID
            ) else { return }
            completedCalls = corroborated
        }
        if isSpecialFailureResponse {
            // These responses are deliberately tools-disabled. Treat any tool
            // output as malformed and never let an empty/failed clarification
            // fall into the generic full-session recovery path.
            if !completedCalls.isEmpty {
                rejectUnavailableTranscriptCallsLocked(completedCalls)
            }
            if status == "completed", producedUsableAddressedAudio, completedCalls.isEmpty {
                if let inputItemID { clearRecoveryBudgetsLocked(inputItemID: inputItemID) }
                startNextContinuationIfPossibleLocked()
                if playbackKeys.isEmpty, readyContinuations.isEmpty { emitPhase(.listening) }
                return
            }
            discardDeferredControlAudioLocked(responseID: responseID, output: output)
            if statusErrorCode == "rate_limit_exceeded",
               let inputItemID,
               scheduleRateLimitRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
               ) {
                return
            }
            if let inputItemID {
                retryOrFinishSpecialFailureLocked(
                    inputItemID: inputItemID,
                    recoveryTag: recoveryTag ?? "",
                    visualContextBound: visualContextBound,
                    untrustedMailContextBound: untrustedMailContextBound
                )
            }
            return
        }
        var routedCompletedCalls: [[String: Any]]
        let actionProposalCalls = completedCalls.filter {
            ($0["name"] as? String).map(Self.isSemanticActionProposalName) == true
        }
        if !actionProposalCalls.isEmpty {
            // Realtime owns semantic resolution. If a malformed response
            // emits more than one high-level decision, the explicit selected
            // Codex-chat route outranks ordinary delegation, and either action
            // outranks a social move. Deterministic code accepts only one; it
            // never reparses the owner's transcript to choose.
            let selected = actionProposalCalls.first(where: {
                $0["name"] as? String == "codex_project_chat"
            }) ?? actionProposalCalls.first(where: {
                $0["name"] as? String == "delegate_task"
            }) ?? actionProposalCalls[0]
            routedCompletedCalls = [selected]
            let supersededResultCode = "superseded_by_semantic_decision"
            let acceptedIDs = Set([selected["call_id"] as? String].compactMap { $0 })
            let rejectedCalls = completedCalls.filter {
                guard let callID = $0["call_id"] as? String else { return true }
                return !acceptedIDs.contains(callID)
            }
            for rejected in rejectedCalls {
                guard let callID = rejected["call_id"] as? String else { continue }
                let payload: [String: Any] = [
                    "ok": false,
                    "result_code": supersededResultCode,
                    "error": "The host accepted one resolved semantic decision for this owner turn.",
                ]
                let data = try? JSONSerialization.data(withJSONObject: payload)
                let result = data.flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"ok\":false,\"result_code\":\"\(supersededResultCode)\"}"
                sendEventLocked([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": result,
                    ],
                ])
            }
            if !rejectedCalls.isEmpty {
                emitDiagnosticLocked(
                    "semantic_decision_precedence",
                    metadata: [
                    "response_id": responseID,
                    "rejected_count": String(rejectedCalls.count),
                    ]
                )
            }
        } else {
            routedCompletedCalls = completedCalls
        }
        guard status == "completed" else {
            // response.done is also emitted for cancelled, failed, and
            // incomplete responses. None may authorize a local action.
            if controlRoute == nil {
                // Never retain hidden PCM or partial assistant message items from
                // a failed response. Besides leaking memory, those unseen words
                // could otherwise condition a later turn as if Aurora said them.
                discardDeferredControlAudioLocked(responseID: responseID, output: output)
            }
            if !producedUsableAddressedAudio,
               statusErrorCode == "rate_limit_exceeded" {
                if let inputItemID,
                   scheduleRateLimitRecoveryLocked(
                    inputItemID: inputItemID,
                    visualContextBound: visualContextBound,
                    untrustedMailContextBound: untrustedMailContextBound
                   ) {
                    return
                }
                finishRateLimitedTurnLocked(inputItemID: inputItemID)
                return
            }
            if !producedUsableAddressedAudio,
               status != "cancelled",
               let inputItemID,
               scheduleEmptyResponseRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
               ) {
                return
            }
            if !producedUsableAddressedAudio,
               let connectionID,
               let inputItemID {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
            } else if let inputItemID {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
            }
            startNextContinuationIfPossibleLocked()
            if toolBatches.isEmpty, readyContinuations.isEmpty {
                emitPhase(.listening)
            }
            return
        }

        var acceptedInternalHelperCallIDs = Set<String>()
        var rejectedInternalHelperCount = 0
        if let inputItemID, !routedCompletedCalls.isEmpty {
            let consumed = internalHelperCallCounts[inputItemID] ?? 0
            var remaining = max(
                0,
                Self.maximumInternalHelperCallsPerInput - consumed
            )
            var boundedCalls: [[String: Any]] = []
            boundedCalls.reserveCapacity(routedCompletedCalls.count)
            for item in routedCompletedCalls {
                guard let name = item["name"] as? String,
                      Self.isInternalConversationHelperName(name) else {
                    boundedCalls.append(item)
                    continue
                }
                guard remaining > 0 else {
                    rejectedInternalHelperCount += 1
                    if let callID = item["call_id"] as? String {
                        let payload: [String: Any] = [
                            "ok": false,
                            "result_code": "internal_helper_limit_exhausted",
                            "error": "The bounded private-context lookup budget for this live turn is exhausted. Continue through conversation_move now.",
                        ]
                        let data = try? JSONSerialization.data(withJSONObject: payload)
                        sendEventLocked([
                            "type": "conversation.item.create",
                            "item": [
                                "type": "function_call_output",
                                "call_id": callID,
                                "output": data.flatMap {
                                    String(data: $0, encoding: .utf8)
                                } ?? #"{"ok":false,"result_code":"internal_helper_limit_exhausted"}"#,
                            ],
                        ])
                    }
                    continue
                }
                boundedCalls.append(item)
                remaining -= 1
                if let callID = item["call_id"] as? String {
                    acceptedInternalHelperCallIDs.insert(callID)
                }
            }
            if !acceptedInternalHelperCallIDs.isEmpty {
                internalHelperCallCounts[inputItemID] = min(
                    Self.maximumInternalHelperCallsPerInput,
                    consumed + acceptedInternalHelperCallIDs.count
                )
            }
            if (internalHelperCallCounts[inputItemID] ?? 0)
                >= Self.maximumInternalHelperCallsPerInput
                || rejectedInternalHelperCount > 0 {
                forceConversationMoveInputItems.insert(inputItemID)
            }
            if !acceptedInternalHelperCallIDs.isEmpty
                || rejectedInternalHelperCount > 0 {
                emitDiagnosticLocked("internal_helper_budget_updated", metadata: [
                    "input_item_id": inputItemID,
                    "accepted_count": String(acceptedInternalHelperCallIDs.count),
                    "rejected_count": String(rejectedInternalHelperCount),
                    "total_count": String(internalHelperCallCounts[inputItemID] ?? consumed),
                ])
            }
            routedCompletedCalls = boundedCalls

            if !isToolReceipt, !acceptedInternalHelperCallIDs.isEmpty {
                let proposedBindings = Set(boundedCalls.compactMap { item -> String? in
                    guard let callID = item["call_id"] as? String,
                          acceptedInternalHelperCallIDs.contains(callID),
                          let arguments = item["arguments"] as? String else { return nil }
                    return Self.canonicalDelegateBinding(
                        argumentsJSON: arguments,
                        nestedAuthorizedDelegate: true
                    )
                })
                if proposedBindings.count == 1,
                   let binding = proposedBindings.first {
                    authorizedDelegateBindingByInputItem[inputItemID] = binding
                    emitDiagnosticLocked("helper_delegate_effect_bound", metadata: [
                        "input_item_id": inputItemID,
                    ])
                } else {
                    // No pre-observation task was proposed, or parallel helper
                    // calls disagreed. In both cases the later observation can
                    // inform conversation only, never authorize a new effect.
                    authorizedDelegateBindingByInputItem.removeValue(
                        forKey: inputItemID
                    )
                    if proposedBindings.count > 1 {
                        emitDiagnosticLocked(
                            "helper_delegate_effect_conflict",
                            metadata: ["input_item_id": inputItemID]
                        )
                    }
                }
            }
        }

        if routedCompletedCalls.isEmpty,
           rejectedInternalHelperCount > 0,
           let inputItemID {
            // Every call in this response exceeded the private helper budget.
            // Their explicit outputs are already in the Conversation. A
            // response that was itself already forced to conversation_move is
            // malformed; terminate it rather than recursively forcing forever.
            if (forcedConversationMoveAttemptCounts[inputItemID] ?? 0) > 0 {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emitDiagnosticLocked(
                    "forced_conversation_move_returned_helper",
                    metadata: ["input_item_id": inputItemID]
                )
                if let connectionID {
                    emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
                }
                startNextContinuationIfPossibleLocked()
                if playbackKeys.isEmpty, readyContinuations.isEmpty {
                    emitPhase(.listening)
                }
                return
            }
            // Otherwise advance the same causal origin directly to its first
            // forced authored move.
            toolReceiptInputItems.insert(inputItemID)
            readyContinuations.append(ResponseOrigin(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
            ))
            startNextContinuationIfPossibleLocked()
            return
        }

        guard !routedCompletedCalls.isEmpty, let connectionID else {
            if !producedUsableAddressedAudio,
               let inputItemID,
               let controlRoute {
                if scheduleControlToolRecoveryLocked(
                    inputItemID: inputItemID,
                    route: controlRoute
                ) {
                    return
                }
                if controlToolRecoveryInputs.contains(inputItemID) {
                    scheduleControlToolFailureLocked(inputItemID: inputItemID)
                    return
                }
            }
            if !producedUsableAddressedAudio,
               let inputItemID,
               scheduleEmptyResponseRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
               ) {
                return
            }
            if !producedUsableAddressedAudio,
               let connectionID,
               let inputItemID {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
            } else if let inputItemID {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
            }
            startNextContinuationIfPossibleLocked()
            if playbackKeys.isEmpty, readyContinuations.isEmpty {
                emitPhase(.listening)
            }
            return
        }

        // A tool-only recovery is still the same retry until it reaches a
        // spoken result or an explicit silent terminal. Keeping the marker
        // here prevents tool continuations from manufacturing retry loops.
        if producedUsableAddressedAudio, let inputItemID {
            spokenInputItemIDs.insert(inputItemID)
            clearRecoveryBudgetsLocked(inputItemID: inputItemID)
        }
        var calls: [RealtimeFunctionCall] = []
        for item in routedCompletedCalls {
            guard let callID = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  callToResponse[callID] == nil else { continue }
            let expectedRetryTool = inputItemID.flatMap {
                delegateRetryToolNameByInputItem[$0]
            }
            let isDelegateSchemaRetry = isToolReceipt
                && expectedRetryTool == name
                && Self.isSemanticActionProposalName(name)
                && inputItemID.map(delegateTaskRetryInputItems.contains) == true
                && inputItemID.map {
                    (delegateTaskRetryAttemptCounts[$0] ?? 0) == 1
                } == true
            let authorizationSource: ToolAuthorizationSource = isDelegateSchemaRetry
                ? .directOwnerTurn
                : (visualContextBound
                    ? .visualContinuation
                    : (untrustedMailContextBound
                        ? .mailContinuation
                        : (isToolReceipt
                            ? .toolContinuation
                            : (inputItemID == nil ? .systemEvent : .directOwnerTurn))))
            var preauthorizedDelegateBinding: String?
            if name == "delegate_task",
               authorizationSource == .toolContinuation,
               let inputItemID {
                let proposedBinding = Self.canonicalDelegateBinding(
                    argumentsJSON: arguments,
                    nestedAuthorizedDelegate: false
                )
                let expectedBinding = authorizedDelegateBindingByInputItem
                    .removeValue(forKey: inputItemID)
                if let proposedBinding,
                   let expectedBinding,
                   proposedBinding == expectedBinding {
                    preauthorizedDelegateBinding = expectedBinding
                } else {
                    emitDiagnosticLocked("helper_delegate_effect_mismatch", metadata: [
                        "input_item_id": inputItemID,
                    ])
                }
            }
            calls.append(RealtimeFunctionCall(
                connectionID: connectionID,
                responseID: responseID,
                inputItemID: inputItemID,
                callID: callID,
                name: name,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound,
                audioCorroborated: false,
                // A task proposal can arrive after its first audio packet has
                // already reached the speaker. That sentence cannot be
                // retracted even though action-turn buffering is now being
                // retired, so preserve the real playback truth and suppress a
                // second synthetic acknowledgement downstream.
                turnAlreadySpoke: producedAddressedAudio
                    || inputItemID.map(spokenInputItemIDs.contains) == true,
                authorizationSource: authorizationSource,
                sourceTurnFinalized: inputItemID.map {
                    finalizedUserTranscriptItems.contains($0)
                        || transcriptionUnavailableItems.contains($0)
                } ?? false,
                argumentsJSON: arguments,
                preauthorizedDelegateBinding: preauthorizedDelegateBinding
            ))
            if isDelegateSchemaRetry, let inputItemID {
                // The forced response exposes no other tool and has now spent
                // its single retry. Keep the attempt count until the result is
                // accepted or explicitly exhausted, but retire this transport
                // marker so no later tool receipt can inherit owner authority.
                delegateTaskRetryInputItems.remove(inputItemID)
            }
        }
        guard !calls.isEmpty else {
            report(AuroraRealtimeError.malformedServerMessage, terminal: false)
            if !producedUsableAddressedAudio,
               let inputItemID,
               let controlRoute {
                if scheduleControlToolRecoveryLocked(
                    inputItemID: inputItemID,
                    route: controlRoute
                ) {
                    return
                }
                if controlToolRecoveryInputs.contains(inputItemID) {
                    scheduleControlToolFailureLocked(inputItemID: inputItemID)
                    return
                }
            }
            if !producedUsableAddressedAudio,
               let inputItemID,
               scheduleEmptyResponseRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
               ) {
                return
            }
            if !producedUsableAddressedAudio, let inputItemID {
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
            }
            startNextContinuationIfPossibleLocked()
            if playbackKeys.isEmpty, readyContinuations.isEmpty {
                emitPhase(.listening)
            }
            return
        }

        toolBatches[responseID] = ToolBatch(
            responseID: responseID,
            inputItemID: inputItemID,
            pendingCallIDs: Set(calls.map(\.callID)),
            callNames: Dictionary(uniqueKeysWithValues: calls.map {
                ($0.callID, $0.name)
            }),
            internalHelperCallIDs: acceptedInternalHelperCallIDs,
            durableDelegateCallIDs: Set(calls.compactMap { call in
                isDurableDelegateCallLocked(call) ? call.callID : nil
            }),
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound
        )
        for call in calls {
            callToResponse[call.callID] = responseID
            emitFunctionCallLocked(call)
        }
        emitPhase(.thinking)
    }

    private func discardDeferredControlAudioLocked(
        responseID: String,
        output: [[String: Any]]
    ) {
        let deferred = deferredResponseAudio.removeValue(forKey: responseID)
        if let deferred {
            playbackKeys.removeValue(forKey: deferred.key.itemID)
            playbackFinishedItems.remove(deferred.key.itemID)
            interruptedPlaybackItems.remove(deferred.key.itemID)
            assistantResponseIDs.removeValue(forKey: deferred.key.itemID)
            assistantTranscripts.removeValue(forKey: deferred.key.itemID)
        }

        var itemIDs = Set(output.compactMap { item -> String? in
            guard item["type"] as? String == "message" else { return nil }
            return item["id"] as? String
        })
        if let deferred { itemIDs.insert(deferred.key.itemID) }
        guard deferred != nil || !itemIDs.isEmpty else { return }
        for itemID in itemIDs {
            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let eventID = "event_aurora_control_delete_\(nonce)"
            controlMessageDeleteEventIDs.append(eventID)
            if controlMessageDeleteEventIDs.count > 64 {
                controlMessageDeleteEventIDs.removeFirst(
                    controlMessageDeleteEventIDs.count - 48
                )
            }
            sendEventLocked([
                "type": "conversation.item.delete",
                "event_id": eventID,
                "item_id": itemID,
            ], priority: true)
        }
        emitDiagnosticLocked("control_pretool_audio_discarded", metadata: [
            "response_id": responseID,
            "buffered_bytes": String(deferred?.pcm.count ?? 0),
            "message_items_deleted": String(itemIDs.count),
        ])
    }

    /// A missing transcript cannot authorize a second motor path. Only a
    /// schema-valid Codex delegation can survive this boundary; all retired
    /// direct-control proposals fail closed without another model request.
    private func routeTranscriptUnavailableCallsLocked(
        _ calls: [[String: Any]],
        output: [[String: Any]],
        responseID: String,
        inputItemID: String
    ) -> [[String: Any]]? {
        guard !calls.isEmpty else {
            releaseDeferredResponseAudioLocked(responseID: responseID)
            return calls
        }
        if audioBoundMotorCallCanProceedWithoutTranscript(calls) { return calls }
        rejectUnavailableTranscriptCallsLocked(calls)
        discardDeferredControlAudioLocked(responseID: responseID, output: output)
        scheduleAudioCorroborationFailureLocked(inputItemID: inputItemID)
        return nil
    }

    /// One Realtime motor call tied to the committed audio item can proceed
    /// when the optional asynchronous transcript is unavailable. The voice
    /// model—not that side channel—heard the owner. Payload-bearing TextEdit
    /// writing remains transcript-grounded, while ordinary app/window/browser
    /// and closed-loop visual actions stay bounded by their existing schemas
    /// and ToolRegistry's current-owner causal checks.
    private func audioBoundMotorCallCanProceedWithoutTranscript(
        _ calls: [[String: Any]]
    ) -> Bool {
        guard calls.count == 1,
              let item = calls.first,
              let name = item["name"] as? String,
              let argumentsText = item["arguments"] as? String,
              argumentsText.count <= 8_000,
              let data = argumentsText.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        guard name == "delegate_task",
              JSONSerialization.isValidJSONObject(arguments),
              let encoded = try? JSONSerialization.data(withJSONObject: arguments),
              let decoded = try? JSONDecoder().decode(
                [String: ToolJSONValue].self,
                from: encoded
              ),
              (try? DelegateTaskProposal(arguments: decoded)) != nil else {
            return false
        }
        return true
    }

#if AURORA_LEGACY_MOTOR
    private var safeAudioNativeActions: Set<NativeDesktopAction> {
        [
            .minimizeFrontWindow, .minimizeAllWindows, .hideFrontApplication,
            .showDesktop, .openSettings, .activateApplication,
            .back, .forward, .refresh, .newTab, .closeTab, .reopenClosedTab,
            .pauseCurrentMedia, .resumeCurrentMedia,
        ]
    }

    private var audioVisualClickAction: String { "visual_click" }

    private var audioVisualClickFingerprint: String { audioVisualClickAction + "|" }

    private func safeAudioMotorActionFingerprint(_ item: [String: Any]) -> String? {
        if item["name"] as? String == "computer_visual" {
            guard let argumentsText = item["arguments"] as? String,
                  let data = argumentsText.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(arguments.keys).isSubset(of: ["action", "scope"]),
                  (arguments["action"] as? String)?.lowercased() == "look",
                  ((arguments["scope"] as? String)?.lowercased() ?? "ordinary") == "ordinary"
            else { return nil }
            return audioVisualClickFingerprint
        }
        guard item["name"] as? String == "computer_action",
              let argumentsText = item["arguments"] as? String,
              let data = argumentsText.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionText = (arguments["action"] as? String)?.lowercased(),
              let action = NativeDesktopAction(rawValue: actionText),
              safeAudioNativeActions.contains(action),
              Set(arguments.keys).isSubset(of: ["action", "application"]) else { return nil }

        let application = (arguments["application"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if audioNativeActionRequiresApplication(action), application.isEmpty {
            // The first Realtime pass has previously dropped an explicitly
            // spoken browser target. Hold this as an audio-recoverable target;
            // the isolated second pass must name it from the same owner audio.
            return action.rawValue + "|<explicit-audio-target>"
        }
        if !audioNativeActionRequiresApplication(action), !application.isEmpty { return nil }
        return audioNativeFingerprint(action: action, application: application)
    }

    private func shouldCorroborateMistranscribedVisualCallLocked(
        _ calls: [[String: Any]],
        inputItemID: String
    ) -> Bool {
        guard calls.count == 1,
              let fingerprint = safeAudioMotorActionFingerprint(calls[0]),
              fingerprint == audioVisualClickFingerprint
                || calls[0]["name"] as? String == "computer_action",
              let transcript = userTranscripts[inputItemID],
              !NativeCapabilityRouter.explicitlyRejectsImmediateAction(transcript),
              NativeCapabilityRouter.route(finalizedOwnerTranscript: transcript).kind == .none
        else { return false }
        return true
    }

    private func audioNativeActionRequiresApplication(_ action: NativeDesktopAction) -> Bool {
        switch action {
        case .minimizeFrontWindow, .minimizeAllWindows,
             .hideFrontApplication, .activateApplication,
             .back, .forward, .refresh, .newTab, .closeTab,
             .reopenClosedTab, .pauseCurrentMedia, .resumeCurrentMedia:
            return true
        default:
            return false
        }
    }

    private func audioNativeFingerprint(
        action: NativeDesktopAction,
        application: String
    ) -> String {
        let normalizedApplication = canonicalAudioApplication(application)
        return action.rawValue + "|" + normalizedApplication
    }

    private func canonicalAudioApplication(_ application: String) -> String {
        var normalized = application.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if normalized.hasSuffix(" app") {
            normalized.removeLast(4)
        }
        switch normalized {
        case "chrome", "chrome browser", "google chrome browser":
            return "google chrome"
        case "safari browser":
            return "safari"
        case "brave", "brave browser browser":
            return "brave browser"
        case "edge", "edge browser", "microsoft edge browser":
            return "microsoft edge"
        case "mozilla firefox", "firefox browser":
            return "firefox"
        case "arc browser":
            return "arc"
        default:
            return normalized
        }
    }

    private func handleAudioMotorCorroborationDoneLocked(
        response: [String: Any],
        responseID: String,
        attemptID: String
    ) {
        audioCorroborationPlaybackSuppressedResponseIDs.remove(responseID)
        rememberResponseUsageLocked(response)
        guard let pending = pendingAudioMotorCorroborations[attemptID],
              pending.connectionID == connectionID else {
            return
        }
        let completeOutput = response["output"] as? [[String: Any]] ?? []
        if responseStatusErrorCode(response)?.lowercased() == "rate_limit_exceeded" {
            // response.done can carry the classifier limit error instead of a
            // top-level error event. Pace the same tools-disabled failure path
            // before it is scheduled, or it would immediately hit the limit too.
            recordRateLimitRejectionLocked()
        }
        let emittedForbiddenMedia = malformedAudioCorroborationResponseIDs.remove(responseID) != nil
        let calls = completeOutput.filter {
            $0["type"] as? String == "function_call"
                && $0["status"] as? String == "completed"
        }
        guard response["status"] as? String == "completed",
              !emittedForbiddenMedia,
              completeOutput.count == 1,
              calls.count == 1,
              calls[0]["name"] as? String == "classify_native_audio_action",
              let argumentsText = calls[0]["arguments"] as? String,
              let data = argumentsText.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(arguments.keys) == Set(["decision", "action", "application"]),
              arguments["decision"] as? String == "confirm",
              let actionText = arguments["action"] as? String,
              let application = arguments["application"] as? String,
              application.count <= 120 else {
            failAudioMotorCorroborationLocked(
                attemptID: attemptID,
                reason: "classifier_rejected_or_mismatched",
                announce: true,
                cancelResponse: false
            )
            return
        }

        let recoveredApplication: String?
        if actionText == audioVisualClickAction,
           pending.fingerprint == audioVisualClickFingerprint,
           application.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recoveredApplication = nil
        } else if let action = NativeDesktopAction(rawValue: actionText),
                  safeAudioNativeActions.contains(action) {
            let classifierFingerprint = audioNativeFingerprint(
                action: action,
                application: application
            )
            let recoveredTargetFingerprint = action.rawValue + "|<explicit-audio-target>"
            if pending.fingerprint == recoveredTargetFingerprint,
               audioNativeActionRequiresApplication(action),
               !canonicalAudioApplication(application).isEmpty {
                recoveredApplication = application
            } else if classifierFingerprint == pending.fingerprint {
                recoveredApplication = nil
            } else {
                failAudioMotorCorroborationLocked(
                    attemptID: attemptID,
                    reason: "classifier_rejected_or_mismatched",
                    announce: true,
                    cancelResponse: false
                )
                return
            }
        } else {
            failAudioMotorCorroborationLocked(
                attemptID: attemptID,
                reason: "classifier_rejected_or_mismatched",
                announce: true,
                cancelResponse: false
            )
            return
        }

        completeAudioMotorCorroborationLocked(
            pending,
            recoveredApplication: recoveredApplication
        )
    }

    private func completeAudioMotorCorroborationLocked(
        _ pending: PendingAudioMotorCorroboration,
        recoveredApplication: String?
    ) {
        removeAudioMotorCorroborationStateLocked(pending)
        transcriptionUnavailableItems.remove(pending.inputItemID)
        guard let callID = pending.originalCall["call_id"] as? String,
              let name = pending.originalCall["name"] as? String,
              let originalArguments = pending.originalCall["arguments"] as? String,
              let arguments = canonicalAudioMotorArgumentsJSON(
                toolName: name,
                originalArguments,
                fingerprint: pending.fingerprint,
                recoveredApplication: recoveredApplication
              ),
              callToResponse[callID] == nil,
              pending.connectionID == connectionID else {
            rejectUnavailableTranscriptCallsLocked([pending.originalCall])
            scheduleAudioCorroborationFailureLocked(inputItemID: pending.inputItemID)
            return
        }

        let call = RealtimeFunctionCall(
            connectionID: pending.connectionID,
            responseID: pending.responseID,
            inputItemID: pending.inputItemID,
            callID: callID,
            name: name,
            visualContextBound: false,
            untrustedMailContextBound: false,
            audioCorroborated: true,
            turnAlreadySpoke: false,
            sourceTurnFinalized: true,
            argumentsJSON: arguments
        )
        toolBatches[pending.responseID] = ToolBatch(
            responseID: pending.responseID,
            inputItemID: pending.inputItemID,
            pendingCallIDs: [callID],
            callNames: [callID: name]
        )
        callToResponse[callID] = pending.responseID
        emitDiagnosticLocked("audio_native_action_corroborated", metadata: [
            "input_item_id": pending.inputItemID,
            "action": pending.fingerprint,
        ])
        emitFunctionCallLocked(call)
        emitPhase(.thinking)
    }

    private func canonicalAudioMotorArgumentsJSON(
        toolName: String,
        _ text: String,
        fingerprint: String,
        recoveredApplication: String?
    ) -> String? {
        guard let data = text.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if toolName == "computer_visual" {
            guard fingerprint == audioVisualClickFingerprint,
                  recoveredApplication == nil,
                  Set(object.keys).isSubset(of: ["action", "scope"]),
                  (object["action"] as? String)?.lowercased() == "look",
                  ((object["scope"] as? String)?.lowercased() ?? "ordinary") == "ordinary"
            else { return nil }
            object["action"] = "look"
            object["scope"] = "ordinary"
        } else {
            guard toolName == "computer_action",
              let actionText = object["action"] as? String,
              let action = NativeDesktopAction(rawValue: actionText),
              safeAudioNativeActions.contains(action) else { return nil }
            if let recoveredApplication {
                object["application"] = canonicalAudioApplication(recoveredApplication)
            } else if let application = object["application"] as? String {
                object["application"] = canonicalAudioApplication(application)
            }
        }
        guard let normalized = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: normalized, encoding: .utf8)
    }

#else
    private func shouldCorroborateMistranscribedVisualCallLocked(
        _ calls: [[String: Any]],
        inputItemID: String
    ) -> Bool {
        _ = calls
        _ = inputItemID
        return false
    }

    private func handleAudioMotorCorroborationDoneLocked(
        response: [String: Any],
        responseID: String,
        attemptID: String
    ) {
        _ = response
        audioCorroborationPlaybackSuppressedResponseIDs.remove(responseID)
        failAudioMotorCorroborationLocked(
            attemptID: attemptID,
            reason: "retired_direct_motor",
            announce: false,
            cancelResponse: false
        )
    }
#endif

    private func failAudioMotorCorroborationLocked(
        attemptID: String,
        reason: String,
        announce: Bool,
        cancelResponse: Bool
    ) {
        guard let pending = pendingAudioMotorCorroborations[attemptID] else { return }
        let removedQueuedCreate = discardQueuedAudioCorroborationCreateLocked(
            attemptID: attemptID
        )
        let responseWasCreated = audioMotorAttemptByResponseID.values.contains(attemptID)
        if !removedQueuedCreate, !responseWasCreated {
            // The request may be inside URLSession's in-flight send. Retain a
            // tombstone so its eventual top-level error cannot be mistaken for
            // the active owner turn or tear down the voice session.
            ignoredAudioCorroborationEventIDs.insert(pending.eventID)
            trimStateCollectionsLocked()
        }
        if cancelResponse,
           let responseID = audioMotorAttemptByResponseID.first(where: {
               $0.value == attemptID
           })?.key {
            ignoredAudioCorroborationResponseIDs.insert(responseID)
            trimStateCollectionsLocked()
            sendEventLocked([
                "type": "response.cancel",
                "response_id": responseID,
            ], kind: .interruptionControl, priority: true)
        }
        removeAudioMotorCorroborationStateLocked(pending)
        transcriptionUnavailableItems.remove(pending.inputItemID)
        rejectUnavailableTranscriptCallsLocked([pending.originalCall])
        emitDiagnosticLocked("audio_native_action_corroboration_failed", metadata: [
            "input_item_id": pending.inputItemID,
            "reason": reason,
        ])
        if announce,
           pending.connectionID == connectionID,
           !userSpeechInProgress {
            scheduleAudioCorroborationFailureLocked(inputItemID: pending.inputItemID)
        }
    }

    private func removeAudioMotorCorroborationStateLocked(
        _ pending: PendingAudioMotorCorroboration
    ) {
        pendingAudioMotorCorroborations.removeValue(forKey: pending.attemptID)
        audioMotorAttemptByInputItem.removeValue(forKey: pending.inputItemID)
        audioMotorAttemptByEventID.removeValue(forKey: pending.eventID)
        audioMotorCorroborationTimeoutTasks.removeValue(forKey: pending.attemptID)?.cancel()
        for responseID in audioMotorAttemptByResponseID.compactMap({ pair in
            pair.value == pending.attemptID ? pair.key : nil
        }) {
            audioMotorAttemptByResponseID.removeValue(forKey: responseID)
        }
    }

    private func rejectUnavailableTranscriptCallsLocked(_ calls: [[String: Any]]) {
        for item in calls {
            guard let callID = item["call_id"] as? String else { continue }
            let payload: [String: Any] = [
                "ok": false,
                "error": "The owner audio could not safely ground this tool call.",
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload)
            sendEventLocked([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": data.flatMap { String(data: $0, encoding: .utf8) }
                        ?? #"{"ok":false}"#,
                ],
            ])
        }
    }

    /// Function names are untrusted provider output just like arguments. The
    /// production session exposes only delegate_task for external work, so a
    /// hallucinated or stale legacy name must never reach ToolRegistry merely
    /// because its old private implementation still exists.
    private func rejectUnexposedFunctionCallsLocked(
        _ calls: [[String: Any]]
    ) -> [[String: Any]] {
        guard !calls.isEmpty else { return calls }
        let exposedNames: Set<String> = Set((activeConfiguration?.tools ?? []).compactMap {
            guard $0["type"] as? String == "function" else { return nil }
            return $0["name"] as? String
        })
        var accepted: [[String: Any]] = []
        accepted.reserveCapacity(calls.count)
        for call in calls {
            guard let name = call["name"] as? String,
                  exposedNames.contains(name) else {
                if let callID = call["call_id"] as? String {
                    let payload: [String: Any] = [
                        "ok": false,
                        "result_code": "tool_not_exposed",
                        "error": "That function is not available in this Aurora session.",
                    ]
                    let data = try? JSONSerialization.data(withJSONObject: payload)
                    sendEventLocked([
                        "type": "conversation.item.create",
                        "item": [
                            "type": "function_call_output",
                            "call_id": callID,
                            "output": data.flatMap { String(data: $0, encoding: .utf8) }
                                ?? #"{"ok":false,"result_code":"tool_not_exposed"}"#,
                        ],
                    ])
                }
                emitDiagnosticLocked("unexposed_function_call_rejected", metadata: [
                    "tool": String((call["name"] as? String ?? "unknown").prefix(80)),
                ])
                continue
            }
            accepted.append(call)
        }
        return accepted
    }

    private func scheduleAudioCorroborationFailureLocked(inputItemID: String) {
        transcriptionUnavailableItems.remove(inputItemID)
        audioCorroborationFailureInputs.insert(inputItemID)
        readyContinuations.append(ResponseOrigin(inputItemID: inputItemID))
        startNextContinuationIfPossibleLocked()
    }

    private func releaseDeferredResponseAudioLocked(responseID: String) {
        guard let deferred = deferredResponseAudio.removeValue(forKey: responseID) else { return }
        if !deferred.pcm.isEmpty {
            enqueuePlaybackLocked(deferred.pcm, key: deferred.key)
        }
        if deferred.isComplete {
            playbackKeys[deferred.key.itemID] = deferred.key
            assistantResponseIDs[deferred.key.itemID] = responseID
            audio.markPlaybackItemComplete(deferred.key)
        }
    }

    /// If the model answered an action request without calling its tool, retry
    /// the same audio turn once with only the host-selected tool available.
    /// Realtime officially supports response-scoped tools and a forced
    /// function choice; this makes a missed tool call deterministic without
    /// delaying ordinary conversation or inventing a local transcript action.
    private func scheduleControlToolRecoveryLocked(
        inputItemID: String,
        route: RetiredControlRoute
    ) -> Bool {
        guard !responseInProgress,
              !rateLimitBlocked,
              !hasKnownExhaustedRateLimitLocked(),
              let toolName = route.preferredToolName,
              let configuration = activeConfiguration,
              let tool = configuration.tools.first(where: {
                $0["type"] as? String == "function"
                    && $0["name"] as? String == toolName
              }),
              controlToolRecoveryInputs.insert(inputItemID).inserted else { return false }

        let actionInstruction = route.preferredAction.map {
            " Use action `\($0)` and preserve the owner's requested target or content."
        } ?? ""
        pendingResponseOrigins.append(ResponseOrigin(inputItemID: inputItemID))
        sendEventLocked([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": Self.maxResponseOutputTokens,
                "tools": [tool],
                "tool_choice": [
                    "type": "function",
                    "name": toolName,
                ],
                "instructions": "Call the required function now for the active owner's most recent audio request. Do not speak before the function result.\(actionInstruction)",
                "metadata": [
                    "aurora_recovery": "forced_control_tool",
                    "aurora_tool": toolName,
                ],
            ],
        ], kind: .continuationCreate)
        emitDiagnosticLocked("control_tool_recovery_scheduled", metadata: [
            "input_item_id": inputItemID,
            "tool": toolName,
            "action": route.preferredAction ?? "none",
        ])
        emitPhase(.thinking)
        return true
    }

    private func scheduleControlToolFailureLocked(inputItemID: String) {
        controlToolFailureInputs.insert(inputItemID)
        readyContinuations.append(ResponseOrigin(inputItemID: inputItemID))
        startNextContinuationIfPossibleLocked()
    }

    /// A completed or failed Realtime response can rarely contain neither
    /// audio nor a terminal tool call. The user audio remains in the default
    /// conversation, so retry that exact turn once rather than waiting for the owner
    /// to speak again. One retry is a hard bound; background audio still has the
    /// explicit wait_for_user terminal path.
    private func scheduleEmptyResponseRecoveryLocked(
        inputItemID: String,
        visualContextBound: Bool = false,
        untrustedMailContextBound: Bool = false
    ) -> Bool {
        // Do not spend a recovery request inside a reset window the server has
        // already declared exhausted. Pace the same origin first without
        // consuming its ordinary empty-response retry budget.
        if hasKnownExhaustedRateLimitLocked() {
            return scheduleRateLimitRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
            )
        }
        guard emptyResponseRetriedInputs.insert(inputItemID).inserted,
              let activeConfiguration else {
            emitDiagnosticLocked("empty_response_retry_exhausted", metadata: [
                "input_item_id": inputItemID,
            ])
            return false
        }

        if forceConversationMoveInputItems.contains(inputItemID) {
            guard dispatchForcedConversationMoveResponseLocked(
                inputItemID: inputItemID,
                activeConfiguration: activeConfiguration,
                tag: "forced_conversation_move_empty_once",
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
            ) else {
                emitDiagnosticLocked("forced_conversation_move_unavailable", metadata: [
                    "input_item_id": inputItemID,
                ])
                return false
            }
            emitDiagnosticLocked("empty_response_retry_scheduled", metadata: [
                "input_item_id": inputItemID,
                "route": "forced_conversation_move",
            ])
            emitPhase(.thinking)
            return true
        }

        dispatchRecoveryResponseLocked(
            inputItemID: inputItemID,
            activeConfiguration: activeConfiguration,
            tag: "empty_response_once",
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound
        )
        emitDiagnosticLocked("empty_response_retry_scheduled", metadata: [
            "input_item_id": inputItemID,
        ])
        emitPhase(.thinking)
        return true
    }

    private func scheduleRateLimitRecoveryLocked(
        inputItemID: String,
        visualContextBound: Bool = false,
        untrustedMailContextBound: Bool = false
    ) -> Bool {
        let timing = rateLimitRecoveryTimingLocked()
        guard timing.delay <= maximumRateLimitAutoWait else {
            emitDiagnosticLocked("rate_limit_retry_too_far_away", metadata: [
                "input_item_id": inputItemID,
                "delay_ms": String(Int((timing.delay * 1_000).rounded())),
                "buckets": timing.buckets,
            ])
            return false
        }
        guard pendingRateLimitRecovery == nil,
              rateLimitRecoveryInputs.insert(inputItemID).inserted,
              let connectionID,
              activeConfiguration != nil else {
            emitDiagnosticLocked("rate_limit_retry_exhausted", metadata: [
                "input_item_id": inputItemID,
            ])
            return false
        }

        let token = UUID()
        let requestedAt = scheduler.now
        let pending = PendingRateLimitRecovery(
            inputItemID: inputItemID,
            connectionID: connectionID,
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound,
            token: token,
            requestedAt: requestedAt,
            dueAt: requestedAt + timing.delay
        )
        pendingRateLimitRecovery = pending
        rateLimitBlocked = false
        pendingMicrophoneAudio.removeAll(keepingCapacity: false)
        rateLimitSpeechPrefixAudio.removeAll(keepingCapacity: true)
        rateLimitSpeechOverrideFrames = 0
        pendingRateLimitRecoveryTask = scheduler.schedule(
            on: stateQueue,
            after: timing.delay
        ) { [weak self] in
            self?.dispatchPendingRateLimitRecoveryLocked(token: token)
        }
        emitDiagnosticLocked("rate_limit_retry_waiting", metadata: [
            "input_item_id": inputItemID,
            "delay_ms": String(Int((timing.delay * 1_000).rounded())),
            "buckets": timing.buckets,
        ])
        emitPhase(.waitingToRetry)
        return true
    }

    private func rateLimitRecoveryTimingLocked() -> (delay: TimeInterval, buckets: String) {
        let now = scheduler.now
        let tokenRequirement = estimatedResponseReservationTokensLocked()
        var waits: [(name: String, delay: TimeInterval)] = []
        for (name, bucket) in rateLimitBuckets where bucket.resetAt >= now {
            let requirement: Double
            switch name {
            case "requests": requirement = 1
            case "tokens": requirement = tokenRequirement
            default: continue
            }
            let estimate = estimatedRateLimitAvailabilityLocked(bucket, now: now)
            guard estimate.remaining < requirement else { continue }
            let delay: TimeInterval
            if let refillPerSecond = estimate.refillPerSecond,
               refillPerSecond > 0 {
                delay = (requirement - estimate.remaining) / refillPerSecond
                    + rateLimitSafetyPadding
            } else {
                delay = bucket.resetAt - now + rateLimitSafetyPadding
            }
            waits.append((name, max(rateLimitSafetyPadding, delay)))
        }
        guard let delay = waits.map({ $0.delay }).max() else {
            return (rateLimitFallbackDelay, "fallback")
        }
        return (delay, waits.map({ $0.name }).sorted().joined(separator: ","))
    }

    private func hasKnownExhaustedRateLimitLocked() -> Bool {
        let now = scheduler.now
        let tokenRequirement = estimatedResponseReservationTokensLocked()
        return rateLimitBuckets.contains { name, bucket in
            guard bucket.resetAt > now else { return false }
            switch name {
            case "requests":
                return estimatedRateLimitAvailabilityLocked(bucket, now: now).remaining < 1
            case "tokens":
                return estimatedRateLimitAvailabilityLocked(bucket, now: now).remaining
                    < tokenRequirement
            default: return false
            }
        }
    }

    private func estimatedRateLimitAvailabilityLocked(
        _ bucket: RateLimitBucket,
        now: TimeInterval
    ) -> (remaining: Double, refillPerSecond: Double?) {
        let elapsed = max(0, now - bucket.observedAt)
        let resetSpan = max(0, bucket.resetAt - bucket.observedAt)
        guard let limit = bucket.limit,
              resetSpan > 0,
              limit > bucket.remaining else {
            return (bucket.remaining, nil)
        }
        let refillPerSecond = (limit - bucket.remaining) / resetSpan
        let remaining = min(limit, bucket.remaining + refillPerSecond * elapsed)
        return (remaining, refillPerSecond)
    }

    private func dispatchPendingRateLimitRecoveryLocked(token: UUID) {
        guard let pending = pendingRateLimitRecovery,
              pending.token == token else { return }
        pendingRateLimitRecoveryTask = nil

        guard pending.connectionID == connectionID,
              socket != nil,
              !rateLimitBlocked,
              !userSpeechInProgress,
              !responseInProgress,
              activeResponseID == nil,
              inputItemsAwaitingResponse.isEmpty,
              let activeConfiguration else {
            cancelPendingRateLimitRecoveryLocked(
                reason: "dispatch_precondition_changed",
                classifyUnresolved: true
            )
            emitPhase(.listening)
            return
        }

        pendingRateLimitRecovery = nil
        rateLimitSpeechPrefixAudio.removeAll(keepingCapacity: true)
        rateLimitSpeechOverrideFrames = 0
        if audioCorroborationFailureInputs.contains(pending.inputItemID)
            || controlToolFailureInputs.contains(pending.inputItemID) {
            readyContinuations.insert(ResponseOrigin(
                inputItemID: pending.inputItemID,
                visualContextBound: pending.visualContextBound,
                untrustedMailContextBound: pending.untrustedMailContextBound
            ), at: 0)
            emitDiagnosticLocked("rate_limit_special_continuation_requeued", metadata: [
                "input_item_id": pending.inputItemID,
            ])
            startNextContinuationIfPossibleLocked()
            return
        }
        if forceConversationMoveInputItems.contains(pending.inputItemID) {
            guard dispatchForcedConversationMoveResponseLocked(
                inputItemID: pending.inputItemID,
                activeConfiguration: activeConfiguration,
                tag: "forced_conversation_move_rate_limit_once",
                visualContextBound: pending.visualContextBound,
                untrustedMailContextBound: pending.untrustedMailContextBound
            ) else {
                clearRecoveryBudgetsLocked(inputItemID: pending.inputItemID)
                emitDiagnosticLocked("forced_conversation_move_unavailable", metadata: [
                    "input_item_id": pending.inputItemID,
                ])
                if let connectionID {
                    emit { $0.onUnresolvedTurn?(connectionID, pending.inputItemID) }
                }
                emitPhase(.listening)
                return
            }
            emitDiagnosticLocked("rate_limit_retry_dispatched", metadata: [
                "input_item_id": pending.inputItemID,
                "waited_ms": String(Int(max(0, scheduler.now - pending.requestedAt) * 1_000)),
                "route": "forced_conversation_move",
            ])
            emitPhase(.thinking)
            return
        }
        dispatchRecoveryResponseLocked(
            inputItemID: pending.inputItemID,
            activeConfiguration: activeConfiguration,
            tag: "rate_limit_once",
            visualContextBound: pending.visualContextBound,
            untrustedMailContextBound: pending.untrustedMailContextBound
        )
        emitDiagnosticLocked("rate_limit_retry_dispatched", metadata: [
            "input_item_id": pending.inputItemID,
            "waited_ms": String(Int(max(0, scheduler.now - pending.requestedAt) * 1_000)),
        ])
        emitPhase(.thinking)
    }

    private func dispatchRecoveryResponseLocked(
        inputItemID: String,
        activeConfiguration: ActiveConfiguration,
        tag: String,
        visualContextBound: Bool = false,
        untrustedMailContextBound: Bool = false
    ) {
        let directive = Self.emptyResponseRecoveryDirective
        let baseLimit = max(0, 64_000 - directive.count - 2)
        let instructions = String(activeConfiguration.currentInstructions.prefix(baseLimit))
            + "\n\n"
            + directive
        pendingResponseOrigins.append(ResponseOrigin(
            inputItemID: inputItemID,
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound
        ))
        sendEventLocked([
            "type": "response.create",
            "response": [
                "instructions": instructions,
                "output_modalities": ["audio"],
                "max_output_tokens": Self.maxResponseOutputTokens,
                "tool_choice": "required",
                "metadata": ["aurora_recovery": tag],
            ],
        ], kind: .continuationCreate)
    }

    @discardableResult
    private func dispatchForcedConversationMoveResponseLocked(
        inputItemID: String,
        activeConfiguration: ActiveConfiguration,
        tag: String,
        visualContextBound: Bool = false,
        untrustedMailContextBound: Bool = false
    ) -> Bool {
        guard let conversationMoveTool = activeConfiguration.tools.first(where: {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "conversation_move"
        }) else { return false }
        pendingResponseOrigins.append(ResponseOrigin(
            inputItemID: inputItemID,
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound
        ))
        sendEventLocked([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": Self.maxResponseOutputTokens,
                "tools": [conversationMoveTool],
                "tool_choice": [
                    "type": "function",
                    "name": "conversation_move",
                ],
                "instructions": "Recover the same live turn by calling conversation_move exactly once now. Use the original user audio, the current conversation, and the bounded helper results already present. Emit no audio and call no other function.",
                "metadata": [
                    "aurora_recovery": tag,
                    "aurora_continuation": "forced_conversation_move_once",
                ],
            ],
        ], kind: .continuationCreate)
        forcedConversationMoveAttemptCounts[inputItemID, default: 0] += 1
        return true
    }

    private func cancelPendingRateLimitRecoveryLocked(
        reason: String,
        classifyUnresolved: Bool
    ) {
        guard let pending = pendingRateLimitRecovery else { return }
        pendingRateLimitRecoveryTask?.cancel()
        pendingRateLimitRecoveryTask = nil
        pendingRateLimitRecovery = nil
        rateLimitSpeechPrefixAudio.removeAll(keepingCapacity: true)
        rateLimitSpeechOverrideFrames = 0
        clearRecoveryBudgetsLocked(inputItemID: pending.inputItemID)
        emitDiagnosticLocked("rate_limit_retry_cancelled", metadata: [
            "input_item_id": pending.inputItemID,
            "reason": reason,
        ])
        if classifyUnresolved,
           let connectionID,
           connectionID == pending.connectionID {
            emit { $0.onUnresolvedTurn?(connectionID, pending.inputItemID) }
        }
    }

    private func finishRateLimitedTurnLocked(inputItemID: String?) {
        let liveConnectionID = connectionID
        if let inputItemID {
            clearRecoveryBudgetsLocked(inputItemID: inputItemID)
            if let connectionID {
                emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
            }
        }

        // Exhausting the one bounded retry closes only this causal turn. The
        // Realtime socket and audio engine are still healthy, so tearing them
        // down here makes an ordinary rolling-token cooldown look like an app
        // crash and forces the owner to manually wake Aurora again.
        rateLimitBlocked = false
        pendingMicrophoneAudio.removeAll(keepingCapacity: false)
        rateLimitSpeechPrefixAudio.removeAll(keepingCapacity: true)
        rateLimitSpeechOverrideFrames = 0
        emitDiagnosticLocked("rate_limit_recovery_exhausted", metadata: [
            "input_item_id": inputItemID ?? "missing",
        ])

        guard liveConnectionID != nil,
              socket != nil,
              activeConfiguration != nil,
              audioStarted else {
            // This branch is defensive: never retain a hidden microphone if a
            // different failure already made the connection truly inactive.
            audioStarted = false
            microphonePrimingBytesReceived = 0
            microphoneReady = false
            audio.stop()
            emitPhase(.resting, connectionID: liveConnectionID)
            return
        }

        startNextContinuationIfPossibleLocked()
        if !responseInProgress, pendingRateLimitRecovery == nil {
            emitPhase(playbackKeys.isEmpty ? .listening : .speaking)
        }
    }

    private func responseStatusErrorCode(_ response: [String: Any]) -> String? {
        guard let details = response["status_details"] as? [String: Any],
              let error = details["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    private func responseStatusReason(_ response: [String: Any]) -> String? {
        guard let details = response["status_details"] as? [String: Any] else {
            return nil
        }
        return details["reason"] as? String
    }

    private func rememberResponseUsageLocked(_ response: [String: Any]) {
        guard let usage = response["usage"] as? [String: Any],
              let inputTokens = numericDouble(usage["input_tokens"]),
              inputTokens.isFinite,
              inputTokens > 0 else { return }
        recentResponseInputTokens.append(inputTokens)
        if recentResponseInputTokens.count > 4 {
            recentResponseInputTokens.removeFirst(recentResponseInputTokens.count - 4)
        }
    }

    private func estimatedResponseReservationTokensLocked() -> Double {
        let recentInput = recentResponseInputTokens.max() ?? 0
        let staticInput = estimatedStaticInputTokensLocked()
        return max(
            Double(Self.maxResponseOutputTokens),
            max(recentInput, staticInput) + Double(Self.maxResponseOutputTokens) + 256
        )
    }

    private func estimatedStaticInputTokensLocked() -> Double {
        guard let activeConfiguration else { return 0 }
        var characters = activeConfiguration.currentInstructions.utf8.count
        if let toolData = try? JSONSerialization.data(withJSONObject: activeConfiguration.tools) {
            characters += toolData.count
        }
        // A conservative character-to-token forecast protects the first turn,
        // before response.done has supplied exact input-token usage.
        return ceil(Double(characters) / 3.5)
    }

    private func clearRecoveryBudgetsLocked(inputItemID: String) {
        emptyResponseRetriedInputs.remove(inputItemID)
        rateLimitRecoveryInputs.remove(inputItemID)
        controlToolRecoveryInputs.remove(inputItemID)
        controlToolFailureInputs.remove(inputItemID)
        toolReceiptInputItems.remove(inputItemID)
        forceConversationMoveInputItems.remove(inputItemID)
        internalHelperCallCounts.removeValue(forKey: inputItemID)
        authorizedDelegateBindingByInputItem.removeValue(forKey: inputItemID)
        forcedConversationMoveAttemptCounts.removeValue(forKey: inputItemID)
        conversationMoveInputItems.remove(inputItemID)
        delegateTaskAcknowledgementInputItems.remove(inputItemID)
        delegateTaskRetryInputItems.remove(inputItemID)
        delegateTaskRetryAttemptCounts.removeValue(forKey: inputItemID)
        delegateRetryToolNameByInputItem.removeValue(forKey: inputItemID)
        audioCorroborationFailureInputs.remove(inputItemID)
        specialFailureRetriedInputs.remove(inputItemID)
    }

    private func retryOrFinishSpecialFailureLocked(
        inputItemID: String,
        recoveryTag: String,
        visualContextBound: Bool,
        untrustedMailContextBound: Bool
    ) {
        if recoveryTag == "control_tool_failed" {
            controlToolFailureInputs.insert(inputItemID)
        } else {
            audioCorroborationFailureInputs.insert(inputItemID)
        }
        guard specialFailureRetriedInputs.insert(inputItemID).inserted else {
            guard let connectionID else { return }
            clearRecoveryBudgetsLocked(inputItemID: inputItemID)
            emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
            startNextContinuationIfPossibleLocked()
            if playbackKeys.isEmpty, readyContinuations.isEmpty { emitPhase(.listening) }
            return
        }
        readyContinuations.append(ResponseOrigin(
            inputItemID: inputItemID,
            visualContextBound: visualContextBound,
            untrustedMailContextBound: untrustedMailContextBound
        ))
        emitDiagnosticLocked("special_failure_response_retried", metadata: [
            "input_item_id": inputItemID,
            "kind": recoveryTag,
        ])
        startNextContinuationIfPossibleLocked()
    }

    private func emitResponseDoneDiagnosticLocked(
        response: [String: Any],
        status: String?,
        output: [[String: Any]],
        producedAddressedAudio: Bool
    ) {
        var metadata: [String: String] = [
            "status": status ?? "missing",
            "output_item_count": String(output.count),
            "produced_audio": String(producedAddressedAudio),
        ]
        let outputTypes = output.compactMap { $0["type"] as? String }
        if !outputTypes.isEmpty {
            metadata["output_types"] = outputTypes.joined(separator: ",")
        }
        if let details = response["status_details"] as? [String: Any] {
            if let type = details["type"] as? String, !type.isEmpty {
                metadata["status_detail_type"] = type
            }
            if let reason = details["reason"] as? String, !reason.isEmpty {
                metadata["status_reason"] = reason
            }
            if let error = details["error"] as? [String: Any],
               let code = error["code"] as? String,
               !code.isEmpty {
                metadata["status_error_code"] = code
            }
        }
        if let usage = response["usage"] as? [String: Any] {
            appendNumericUsageMetadata(
                usage,
                prefix: "usage",
                keys: ["total_tokens", "input_tokens", "output_tokens"],
                into: &metadata
            )
            if let details = usage["input_token_details"] as? [String: Any] {
                appendNumericUsageMetadata(
                    details,
                    prefix: "usage_input",
                    keys: ["cached_tokens", "text_tokens", "audio_tokens", "image_tokens"],
                    into: &metadata
                )
            }
            if let details = usage["output_token_details"] as? [String: Any] {
                appendNumericUsageMetadata(
                    details,
                    prefix: "usage_output",
                    keys: ["text_tokens", "audio_tokens", "reasoning_tokens"],
                    into: &metadata
                )
            }
        }
        emitDiagnosticLocked("server_response_done", metadata: metadata)
    }

    private func appendNumericUsageMetadata(
        _ source: [String: Any],
        prefix: String,
        keys: [String],
        into destination: inout [String: String]
    ) {
        for key in keys {
            guard let value = numericDouble(source[key]), value.isFinite, value >= 0 else { continue }
            destination["\(prefix)_\(key)"] = String(Int(value.rounded()))
        }
    }

    private func startNextContinuationIfPossibleLocked() {
        guard !responseInProgress,
              pendingRateLimitRecovery == nil,
              !rateLimitBlocked,
              toolBatches.isEmpty,
              pendingAudioMotorCorroborations.isEmpty,
              !readyContinuations.isEmpty else { return }
        let next = readyContinuations[0]
        if let inputItemID = next.inputItemID,
           hasKnownExhaustedRateLimitLocked() {
            readyContinuations.removeFirst()
            if scheduleRateLimitRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: next.visualContextBound,
                untrustedMailContextBound: next.untrustedMailContextBound
            ) {
                emitDiagnosticLocked("rate_limit_continuation_deferred", metadata: [
                    "input_item_id": inputItemID,
                ])
                return
            }
            finishRateLimitedTurnLocked(inputItemID: inputItemID)
            return
        }
        let origin = readyContinuations.removeFirst()
        pendingResponseOrigins.append(origin)
        if let inputItemID = origin.inputItemID,
           controlToolFailureInputs.contains(inputItemID) {
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": desktopStatusResponseOutputTokens,
                    "tools": [],
                    "tool_choice": "none",
                    "instructions": "Say one short, natural sentence that you couldn't complete that computer action just now. Do not claim it happened, do not invent a reason, and do not ask for a special permission phrase.",
                    "metadata": ["aurora_recovery": "control_tool_failed"],
                ],
            ], kind: .continuationCreate)
        } else if let inputItemID = origin.inputItemID,
                  audioCorroborationFailureInputs.contains(inputItemID) {
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": desktopStatusResponseOutputTokens,
                    "tools": [],
                    "tool_choice": "none",
                    "instructions": "Say one short, natural sentence: you did not catch that cleanly. Do not claim any action happened and do not ask for a special permission phrase.",
                    "metadata": ["aurora_recovery": "audio_native_corroboration_failed"],
                ],
            ], kind: .continuationCreate)
        } else if let inputItemID = origin.inputItemID,
                  delegateTaskRetryInputItems.contains(inputItemID) {
            let retryToolName = delegateRetryToolNameByInputItem[inputItemID]
                ?? "delegate_task"
            guard (delegateTaskRetryAttemptCounts[inputItemID] ?? 0) == 0,
                  Self.isSemanticActionProposalName(retryToolName),
                  let delegateTaskTool = activeConfiguration?.tools.first(where: {
                      $0["type"] as? String == "function"
                          && $0["name"] as? String == retryToolName
                  }) else {
                _ = pendingResponseOrigins.popLast()
                delegateTaskRetryInputItems.remove(inputItemID)
                delegateRetryToolNameByInputItem.removeValue(forKey: inputItemID)
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emitDiagnosticLocked("delegate_task_schema_retry_unavailable", metadata: [
                    "input_item_id": inputItemID,
                ])
                if let connectionID {
                    emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
                }
                startNextContinuationIfPossibleLocked()
                if playbackKeys.isEmpty, readyContinuations.isEmpty {
                    emitPhase(.listening)
                }
                return
            }
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.maxResponseOutputTokens,
                    "tools": [delegateTaskTool],
                    "tool_choice": [
                        "type": "function",
                        "name": retryToolName,
                    ],
                    "instructions": "The prior \(retryToolName) call for this same finalized owner turn failed strict host schema validation. Correct its structure exactly once using the original owner audio and the validation result already present. Preserve the identical requested effect, target, message, and every negative constraint; do not add, remove, reinterpret, or broaden anything. Every schema property is required, and every non-applicable nullable property must be JSON null—not an object, array, or placeholder string. Call \(retryToolName) exactly once and emit no audio.",
                    "metadata": [
                        "aurora_continuation": "delegate_task_schema_retry_once",
                    ],
                ],
            ], kind: .continuationCreate)
            delegateTaskRetryAttemptCounts[inputItemID, default: 0] += 1
            emitDiagnosticLocked("delegate_task_schema_retry_scheduled", metadata: [
                "input_item_id": inputItemID,
            ])
        } else if let inputItemID = origin.inputItemID,
                  conversationMoveInputItems.contains(inputItemID) {
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.maxResponseOutputTokens,
                    "tools": [],
                    "tool_choice": "none",
                    "instructions": "Speak now as Aurora. Follow the validated conversation_move result immediately before this response: embody its move, answer degree, typed delivery constraint, selected stance or thread, privacy boundary, and live edge. The result is private direction, never something to quote or explain. Do not mention a move, state, record, tool, system, validation, learning, or receipt. Never say ‘got it,’ ‘totally fair,’ ‘I’m happy to,’ ‘keep things light,’ or ‘just be here’; never host the conversation, offer topics, ask what else they want, or turn the reply into advice, a menu, a personality description, or an assistant offer. A boundary with no specific new subject ends after its plain acknowledgement. Use relaxed spoken English; usually one or two short sentences. Do not call another tool.",
                    "metadata": ["aurora_continuation": "conversation_move_once"],
                ],
            ], kind: .continuationCreate)
        } else if let inputItemID = origin.inputItemID,
                  delegateTaskAcknowledgementInputItems.contains(inputItemID) {
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": desktopStatusResponseOutputTokens,
                    "tools": [],
                    "tool_choice": "none",
                    "instructions": "A private Codex task was accepted and has only started. As Aurora, acknowledge immediately with one short, natural sentence such as ‘Okay, I’ll get started on that.’ Do not imply completion. Do not mention Codex, Osiris, a handoff, route, worker, queue, tool, receipt, checking, confirmation, or verification. Do not call another tool.",
                    "metadata": ["aurora_continuation": "delegate_task_started_once"],
                ],
            ], kind: .continuationCreate)
        } else if let inputItemID = origin.inputItemID,
                  forceConversationMoveInputItems.contains(inputItemID) {
            guard let conversationMoveTool = activeConfiguration?.tools.first(where: {
                $0["type"] as? String == "function"
                    && $0["name"] as? String == "conversation_move"
            }) else {
                // The trusted route required to finish this authored turn is
                // absent. Remove the unsent origin and close the turn once;
                // never fall back to the full tool surface or another helper.
                _ = pendingResponseOrigins.popLast()
                clearRecoveryBudgetsLocked(inputItemID: inputItemID)
                emitDiagnosticLocked("forced_conversation_move_unavailable", metadata: [
                    "input_item_id": inputItemID,
                ])
                if let connectionID {
                    emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
                }
                startNextContinuationIfPossibleLocked()
                if playbackKeys.isEmpty, readyContinuations.isEmpty {
                    emitPhase(.listening)
                }
                return
            }
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.maxResponseOutputTokens,
                    "tools": [conversationMoveTool],
                    "tool_choice": [
                        "type": "function",
                        "name": "conversation_move",
                    ],
                    "instructions": "The bounded private-context helper budget for this same live turn is complete. Call conversation_move exactly once now using the original user audio, the current conversation, and the helper results already present. Emit no audio and call no other function.",
                    "metadata": ["aurora_continuation": "forced_conversation_move_once"],
                ],
            ], kind: .continuationCreate)
            forcedConversationMoveAttemptCounts[inputItemID, default: 0] += 1
            emitDiagnosticLocked("forced_conversation_move_scheduled", metadata: [
                "input_item_id": inputItemID,
            ])
        } else if let inputItemID = origin.inputItemID,
                  toolReceiptInputItems.contains(inputItemID) {
            sendEventLocked([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.maxResponseOutputTokens,
                    // Inherit the session's required semantic decision. A
                    // bounded memory/continuity helper may chain once more,
                    // but ordinary speech still cannot bypass conversation_move.
                    "instructions": "Continue the same owner turn from the private function result. If another bounded internal continuity step is genuinely necessary, call it; otherwise call conversation_move before any speech. Keep all execution, validation, IDs, and bookkeeping private. Do not speak yet.",
                    "metadata": ["aurora_continuation": "internal_result_requires_move"],
                ],
            ], kind: .continuationCreate)
        } else {
            sendEventLocked(["type": "response.create"], kind: .continuationCreate)
        }
        emitPhase(.thinking)
    }

    private func handleBargeInLocked() {
        functionCallDeliveryGate.invalidate()
        // The new utterance supersedes unfinished actions from the old turn.
        // Drop their local batch identity so a stale result can never create a
        // continuation in the new turn.
        if pendingRateLimitRecovery != nil {
            cancelPendingRateLimitRecoveryLocked(
                reason: "new_speech_started",
                classifyUnresolved: true
            )
        }
        visualContextTimeoutTasks.values.forEach { $0.cancel() }
        visualContextTimeoutTasks.removeAll()
        let discardedVisualCreates = discardQueuedVisualContextCreatesLocked()
        for itemID in pendingVisualToolResults.keys {
            if !discardedVisualCreates.contains(itemID) {
                deleteVisualContextItemLocked(itemID)
            }
        }
        pendingVisualToolResults.removeAll()
        visualEventToItemID.removeAll()
        retireActiveVisualContextLocked()
        retireAllUntrustedMailItemsLocked()
        _ = discardQueuedAudioCorroborationCreatesLocked()
        for attemptID in Array(pendingAudioMotorCorroborations.keys) {
            failAudioMotorCorroborationLocked(
                attemptID: attemptID,
                reason: "superseded_by_new_speech",
                announce: false,
                cancelResponse: true
            )
        }
        // Keep only finalized direct-owner delegate calls. The new utterance
        // supersedes their audible acknowledgement, not the backstage work
        // the owner already committed. Every other stale function remains revoked.
        var retainedBatches: [String: ToolBatch] = [:]
        var retainedCallToResponse: [String: String] = [:]
        for (responseID, var batch) in toolBatches {
            let retainedCallIDs = batch.pendingCallIDs
                .intersection(batch.durableDelegateCallIDs)
            guard !retainedCallIDs.isEmpty else { continue }
            batch.pendingCallIDs = retainedCallIDs
            batch.durableDelegateCallIDs = retainedCallIDs
            batch.wantsSpokenContinuation = false
            batch.wantsDelegateAcknowledgement = false
            batch.sawSilentTerminal = false
            batch.completedWithoutResponse = false
            batch.superseded = true
            retainedBatches[responseID] = batch
            for callID in retainedCallIDs {
                retainedCallToResponse[callID] = responseID
            }
        }
        toolBatches = retainedBatches
        callToResponse = retainedCallToResponse
        readyContinuations.removeAll()
        if responseInProgress, let activeResponseID {
            supersededResponseIDs.insert(activeResponseID)
            specialFailureResponseIDs.remove(activeResponseID)
        }
        let continuationCreatesAlreadySent = discardQueuedContinuationsLocked()
        for origin in pendingResponseOrigins {
            if let deliveryID = origin.backgroundTaskDeliveryID {
                failBackgroundTaskDeliveryLocked(
                    deliveryID: deliveryID,
                    reason: "interrupted_before_response_started"
                )
            }
        }
        pendingResponseOrigins = Array(
            repeating: ResponseOrigin(inputItemID: nil, superseded: true),
            count: continuationCreatesAlreadySent
        )
        emptyResponseRetriedInputs.removeAll()
        rateLimitRecoveryInputs.removeAll()

        // Any held action-turn promise belongs to the superseded utterance.
        // Drop both its PCM and delayed response.done rather than letting it
        // surface against the new owner's turn.
        controlToolRecoveryInputs.removeAll()
        controlToolFailureInputs.removeAll()
        toolReceiptInputItems.removeAll()
        forceConversationMoveInputItems.removeAll()
        internalHelperCallCounts.removeAll()
        authorizedDelegateBindingByInputItem.removeAll()
        forcedConversationMoveAttemptCounts.removeAll()
        conversationMoveInputItems.removeAll()
        delegateTaskAcknowledgementInputItems.removeAll()
        delegateTaskRetryInputItems.removeAll()
        delegateTaskRetryAttemptCounts.removeAll()
        delegateRetryToolNameByInputItem.removeAll()
        audioCorroborationFailureInputs.removeAll()
        specialFailureRetriedInputs.removeAll()
        for (responseID, deferred) in deferredResponseAudio
            where backgroundTaskDeliveryByResponseID[responseID] != nil {
            supersededUnheardBackgroundItemByResponseID[responseID] = deferred.key.itemID
        }
        deferredResponseAudio.removeAll()
        pendingResponseDoneEvents.removeAll()
        actionProposalResponseIDs.removeAll()

        let cuts = audio.interruptPlayback()
        for cut in cuts {
            interruptedPlaybackItems.insert(cut.key.itemID)
            playbackFinishedItems.remove(cut.key.itemID)
            emitPlaybackOutcomeLocked(
                key: cut.key,
                fullyPlayed: false,
                playedMilliseconds: cut.playedMilliseconds
            )
            sendEventLocked([
                "type": "conversation.item.truncate",
                "item_id": cut.key.itemID,
                "content_index": cut.key.contentIndex,
                "audio_end_ms": cut.playedMilliseconds,
            ], kind: .interruptionControl, priority: true)
        }

        if let activeResponseID {
            failBackgroundTaskDeliveryLocked(
                responseID: activeResponseID,
                reason: "interrupted_before_playback"
            )
        }

        if responseInProgress || continuationCreatesAlreadySent > 0 {
            var cancel: [String: Any] = ["type": "response.cancel"]
            if let activeResponseID { cancel["response_id"] = activeResponseID }
            sendEventLocked(cancel, kind: .interruptionControl, priority: true)
        }
        activeResponseID = nil
        responseInProgress = false
    }

    private func handleServerErrorLocked(_ event: [String: Any]) {
        let details = (event["error"] as? [String: Any]) ?? event
        let code = details["code"] as? String
        let message = details["message"] as? String ?? "Unknown server error"
        let failedEventID = (details["event_id"] as? String) ?? (event["event_id"] as? String)

        if let failedEventID,
           ignoredAudioCorroborationEventIDs.remove(failedEventID) != nil {
            emitDiagnosticLocked("stale_audio_corroboration_error_ignored", metadata: [
                "code": code ?? "missing",
            ])
            return
        }
        if let failedEventID,
           let attemptID = audioMotorAttemptByEventID[failedEventID] {
            if code?.lowercased() == "rate_limit_exceeded" {
                // An OOB response.create rejection is consumed here before the
                // generic error path can pace it. Record a bounded exhausted
                // request bucket first so its spoken failure waits for reset
                // instead of immediately spending another rejected request.
                recordRateLimitRejectionLocked()
            }
            failAudioMotorCorroborationLocked(
                attemptID: attemptID,
                reason: "classifier_request_rejected_\(code ?? "unknown")",
                announce: true,
                cancelResponse: false
            )
            ignoredAudioCorroborationEventIDs.remove(failedEventID)
            return
        }
        if let failedEventID,
           let itemID = visualEventToItemID[failedEventID] {
            failPendingVisualContextLocked(
                itemID: itemID,
                reason: "The current computer view could not be added to Aurora's live conversation."
            )
            return
        }
        if let pending = pendingInnerLifeContextUpdate,
           failedEventID == pending.eventID {
            pendingInnerLifeContextUpdate = nil
            var metadata = ["code": code ?? "missing"]
            if let parameter = details["param"] as? String {
                metadata["parameter"] = String(parameter.prefix(120))
            }
            emitDiagnosticLocked("inner_life_context_rejected", metadata: metadata)
            callbackQueue.async {
                pending.completion?(false)
                pending.receiptCompletion?(nil)
            }
            return
        }
        if let pending = pendingContinuityContextUpdate,
           failedEventID == pending.eventID {
            pendingContinuityContextUpdate = nil
            var metadata = ["code": code ?? "missing"]
            if let parameter = details["param"] as? String {
                metadata["parameter"] = String(parameter.prefix(120))
            }
            emitDiagnosticLocked("continuity_context_rejected", metadata: metadata)
            if !pending.completions.isEmpty {
                callbackQueue.async {
                    pending.completions.forEach { $0(false) }
                }
            }
            return
        }
        if let pending = pendingBackgroundTaskContextUpdate,
           failedEventID == pending.eventID {
            pendingBackgroundTaskContextUpdate = nil
            var metadata = ["code": code ?? "missing"]
            if let parameter = details["param"] as? String {
                metadata["parameter"] = String(parameter.prefix(120))
            }
            emitDiagnosticLocked("background_task_context_rejected", metadata: metadata)
            callbackQueue.async { pending.completion?(false) }
            return
        }
        if let pending = pendingWakeWordAcknowledgement,
           failedEventID == pending.eventID {
            pendingWakeWordAcknowledgement = nil
            var metadata = ["code": code ?? "missing"]
            if let parameter = details["param"] as? String {
                metadata["parameter"] = String(parameter.prefix(120))
            }
            emitDiagnosticLocked("wake_word_context_rejected", metadata: metadata)
            callbackQueue.async { pending.completion?(false) }
            return
        }
        if let failedEventID,
           let index = innerLifeDeleteEventIDs.firstIndex(of: failedEventID) {
            innerLifeDeleteEventIDs.remove(at: index)
            emitDiagnosticLocked("inner_life_context_delete_skipped", metadata: [
                "code": code ?? "missing",
            ])
            return
        }
        if let failedEventID,
           let index = continuityDeleteEventIDs.firstIndex(of: failedEventID) {
            continuityDeleteEventIDs.remove(at: index)
            emitDiagnosticLocked("continuity_context_delete_skipped", metadata: [
                "code": code ?? "missing",
            ])
            return
        }
        if let failedEventID,
           let index = backgroundTaskDeleteEventIDs.firstIndex(of: failedEventID) {
            backgroundTaskDeleteEventIDs.remove(at: index)
            emitDiagnosticLocked("background_task_context_delete_skipped", metadata: [
                "code": code ?? "missing",
            ])
            return
        }
        if let failedEventID,
           let index = visualContextDeleteEventIDs.firstIndex(of: failedEventID) {
            visualContextDeleteEventIDs.remove(at: index)
            emitDiagnosticLocked("visual_context_delete_skipped", metadata: [
                "code": code ?? "missing",
            ])
            return
        }
        if let failedEventID,
           let index = untrustedMailDeleteEventIDs.firstIndex(of: failedEventID) {
            untrustedMailDeleteEventIDs.remove(at: index)
            emitDiagnosticLocked("untrusted_mail_delete_failed_closed", metadata: [
                "code": code ?? "missing",
            ])
            handleRecoverableFailureLocked(AuroraRealtimeError.server(
                code: "untrusted_mail_delete_failed",
                message: "A private mail result could not be removed from the live conversation."
            ))
            return
        }
        if let failedEventID,
           let index = controlMessageDeleteEventIDs.firstIndex(of: failedEventID) {
            controlMessageDeleteEventIDs.remove(at: index)
            let alreadyAbsent = code?.lowercased() == "item_not_found"
                || message.localizedCaseInsensitiveContains("not found")
                || message.localizedCaseInsensitiveContains("already deleted")
            if alreadyAbsent {
                emitDiagnosticLocked("control_message_already_absent", metadata: [
                    "code": code ?? "missing",
                ])
                return
            }
            // The hidden pre-tool promise must not remain in the default
            // Conversation. Reconnect if the server cannot prove its deletion;
            // continuing would let unheard words influence later turns.
            emitDiagnosticLocked("control_message_delete_failed_closed", metadata: [
                "code": code ?? "missing",
            ])
            handleRecoverableFailureLocked(AuroraRealtimeError.server(
                code: "control_message_delete_failed",
                message: "A hidden pre-tool message could not be removed from the live conversation."
            ))
            return
        }

        let benignCancelRace = message.localizedCaseInsensitiveContains("no active response")
            || message.localizedCaseInsensitiveContains("not currently active")
        if benignCancelRace { return }

        retireAllUntrustedMailItemsLocked()

        // Some response.create rejections arrive as a top-level error instead
        // of response.done. Preserve and pace that same turn when its origin is
        // still unambiguous; reconnecting immediately would lose the answer and
        // spend another request inside the same reset window.
        if code?.lowercased() == "rate_limit_exceeded",
           let origin = claimTopLevelRateLimitOriginLocked(),
           let inputItemID = origin.inputItemID {
            emitDiagnosticLocked("top_level_rate_limit_claimed", metadata: [
                "input_item_id": inputItemID,
            ])
            if scheduleRateLimitRecoveryLocked(
                inputItemID: inputItemID,
                visualContextBound: origin.visualContextBound,
                untrustedMailContextBound: origin.untrustedMailContextBound
            ) {
                return
            }
            finishRateLimitedTurnLocked(inputItemID: inputItemID)
            return
        }

        let error = AuroraRealtimeError.server(code: code, message: message)
        let transientCodes: Set<String> = [
            "server_error", "rate_limit_exceeded", "session_expired", "timeout"
        ]
        if audioStarted, let code, transientCodes.contains(code.lowercased()) {
            handleRecoverableFailureLocked(error)
        } else {
            emitPendingUnresolvedTurnsLocked()
            report(error, terminal: true)
            tearDownLocked(clearConfiguration: true, emitResting: false)
        }
    }

    private func claimTopLevelRateLimitOriginLocked() -> ResponseOrigin? {
        if let responseID = activeResponseID,
           !addressedResponseIDs.contains(responseID),
           !supersededResponseIDs.contains(responseID),
           let inputItemID = responseInputItems.removeValue(forKey: responseID) {
            let visualContextBound = visualContextBoundResponseIDs.remove(responseID) != nil
            let untrustedMailContextBound = untrustedMailContextBoundResponseIDs.remove(responseID) != nil
            activeResponseID = nil
            responseInProgress = false
            return ResponseOrigin(
                inputItemID: inputItemID,
                visualContextBound: visualContextBound,
                untrustedMailContextBound: untrustedMailContextBound
            )
        }
        while !pendingResponseOrigins.isEmpty {
            let origin = pendingResponseOrigins.removeFirst()
            if let deliveryID = origin.backgroundTaskDeliveryID {
                retireBackgroundTaskContextLocked(deliveryID: deliveryID)
                emitDiagnosticLocked("background_task_delivery_failed", metadata: [
                    "delivery_id": String(deliveryID.prefix(180)),
                    "reason": "response_create_rejected",
                ])
                if let connectionID {
                    emit { client in
                        client.onBackgroundTaskDeliveryFailed?(connectionID, deliveryID)
                    }
                }
                continue
            }
            if !origin.superseded, origin.inputItemID != nil {
                return origin
            }
        }
        if !inputItemsAwaitingResponse.isEmpty {
            return ResponseOrigin(inputItemID: inputItemsAwaitingResponse.removeFirst())
        }
        return nil
    }

    private func recordRateLimitRejectionLocked() {
        let now = scheduler.now
        rateLimitBuckets["requests"] = RateLimitBucket(
            limit: nil,
            remaining: 0,
            observedAt: now,
            resetAt: now + rateLimitFallbackDelay
        )
        emitDiagnosticLocked("rate_limit_rejection_recorded", metadata: [
            "fallback_reset_ms": String(Int(rateLimitFallbackDelay * 1_000)),
        ])
    }

    private func handleAudioFailureLocked(_ error: Error) {
        guard !intentionallyStopped else { return }
        if let audioError = error as? AuroraAudioEngineError,
           case .audioRouteChanged = audioError {
            let wrapped = AuroraRealtimeError.audio(error)
            handleRecoverableFailureLocked(wrapped)
        } else {
            report(AuroraRealtimeError.audio(error), terminal: false)
        }
    }

    private func handleTransportFailureLocked(_ error: Error) {
        guard !intentionallyStopped else { return }
        handleRecoverableFailureLocked(AuroraRealtimeError.transport(error))
    }

    private func handleRecoverableFailureLocked(_ error: Error) {
        guard let failedConnectionID = connectionID else { return }
        emitPendingUnresolvedTurnsLocked()
        tearDownLocked(clearConfiguration: true, emitResting: false)
        emitPhase(.reconnecting, connectionID: failedConnectionID)
        report(error, terminal: false, connectionID: failedConnectionID)
    }

    private func emitPendingUnresolvedTurnsLocked() {
        guard let connectionID else { return }
        failAllBackgroundTaskDeliveriesLocked(
            connectionID: connectionID,
            reason: "connection_stopped_before_delivery"
        )
        var pendingInputIDs = Set(inputItemsAwaitingResponse)
        if let activeResponseID,
           let inputItemID = responseInputItems[activeResponseID] {
            pendingInputIDs.insert(inputItemID)
        }
        for batch in toolBatches.values {
            if let inputItemID = batch.inputItemID { pendingInputIDs.insert(inputItemID) }
        }
        for origin in readyContinuations {
            if let inputItemID = origin.inputItemID { pendingInputIDs.insert(inputItemID) }
        }
        for origin in pendingResponseOrigins {
            if let inputItemID = origin.inputItemID { pendingInputIDs.insert(inputItemID) }
        }
        if let pendingRateLimitRecovery {
            pendingInputIDs.insert(pendingRateLimitRecovery.inputItemID)
        }
        for inputItemID in pendingInputIDs {
            emit { $0.onUnresolvedTurn?(connectionID, inputItemID) }
        }
    }

    private func queueMicrophoneAudioLocked(_ data: Data) {
        guard !rateLimitBlocked else { return }
        if pendingRateLimitRecovery != nil {
            rateLimitSpeechPrefixAudio.append(data)
            if rateLimitSpeechPrefixAudio.count > rateLimitSpeechPrefixBytes {
                rateLimitSpeechPrefixAudio.removeFirst(
                    rateLimitSpeechPrefixAudio.count - rateLimitSpeechPrefixBytes
                )
            }
            return
        }
        pendingMicrophoneAudio.append(data)
        guard pendingMicrophoneAudio.count <= maximumBufferedMicrophoneBytes else {
            handleRecoverableFailureLocked(AuroraRealtimeError.outboundBackpressure)
            return
        }
        if pendingMicrophoneAudio.count >= microphoneBatchBytes {
            flushMicrophoneAudioLocked()
            return
        }
        guard !microphoneFlushScheduled, let scheduledConnectionID = connectionID else { return }
        microphoneFlushScheduled = true
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, scheduledConnectionID == self.connectionID else { return }
            self.microphoneFlushScheduled = false
            self.flushMicrophoneAudioLocked()
        }
    }

    private func flushMicrophoneAudioLocked() {
        microphoneFlushScheduled = false
        guard pendingRateLimitRecovery == nil, !rateLimitBlocked else {
            pendingMicrophoneAudio.removeAll(keepingCapacity: false)
            return
        }
        guard !pendingMicrophoneAudio.isEmpty else { return }
        let data = pendingMicrophoneAudio
        pendingMicrophoneAudio.removeAll(keepingCapacity: true)
        sendEventLocked([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ], kind: .audio)
    }

    private func sendEventLocked(
        _ event: [String: Any],
        kind: OutboundMessage.Kind = .other,
        priority: Bool = false
    ) {
        guard socket != nil else { return }
        do {
            var event = event
            if event["event_id"] == nil {
                event["event_id"] = "aurora_\(UUID().uuidString.lowercased())"
            }
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AuroraRealtimeError.malformedServerMessage
            }
            let message = OutboundMessage(text: text, bytes: data.count, kind: kind)
            let projectedBytes = outboundBytes + message.bytes
            let visualBytes = outboundMessages.reduce(into: 0) { total, queued in
                if case .visualContextCreate = queued.kind { total += queued.bytes }
            }
            let hardLimit: Int
            switch kind {
            case .audio:
                // A single private image has its own bounded envelope and must
                // not make the next normal microphone batch look like audio
                // backpressure. Audio/nonvisual traffic retains the original
                // 96 KiB ceiling independently.
                hardLimit = maximumOutboundBytes + visualBytes
            case .visualContextCreate:
                // One bounded image can coexist with the normal audio queue
                // without turning a valid visual turn into a reconnect.
                hardLimit = maximumOutboundBytes + 112_000
            default:
                hardLimit = maximumOutboundBytes + 32_000
            }
            if projectedBytes > hardLimit {
                handleRecoverableFailureLocked(AuroraRealtimeError.outboundBackpressure)
                return
            }
            if priority {
                let insertionIndex = outboundSendInFlight ? min(1, outboundMessages.count) : 0
                outboundMessages.insert(message, at: insertionIndex)
            } else {
                outboundMessages.append(message)
            }
            outboundBytes += message.bytes
            sendNextOutboundLocked()
        } catch {
            report(error, terminal: false)
        }
    }

    private func sendNextOutboundLocked() {
        guard !outboundSendInFlight,
              let socket,
              let connectionID,
              let message = outboundMessages.first else { return }
        outboundSendInFlight = true
        let expectedID = connectionID
        socket.send(.string(message.text)) { [weak self] error in
            guard let self else { return }
            self.stateQueue.async {
                guard expectedID == self.connectionID else { return }
                self.outboundSendInFlight = false
                if self.outboundMessages.first?.id == message.id {
                    self.outboundMessages.removeFirst()
                    self.outboundBytes = max(0, self.outboundBytes - message.bytes)
                }
            if let error {
                self.handleTransportFailureLocked(error)
            } else {
                if message.kind == .audio,
                   !self.reportedAudioBatchSent,
                   let connectionID = self.connectionID {
                    self.reportedAudioBatchSent = true
                    self.emit {
                        $0.onDiagnostic?(connectionID, "microphone_audio_sent", [
                            "event_bytes": String(message.bytes),
                        ])
                    }
                }
                self.sendNextOutboundLocked()
                }
            }
        }
    }

    /// Removes continuation creates that have not reached the socket. Returns
    /// how many creates are already in flight or were previously sent. Those
    /// late response.created events retain superseded tombstones so they can
    /// never consume a newer committed user input.
    private func discardQueuedContinuationsLocked() -> Int {
        let firstRemovableIndex = outboundSendInFlight ? 1 : 0
        var removedUnsent = 0

        if firstRemovableIndex < outboundMessages.count {
            for index in stride(from: outboundMessages.count - 1, through: firstRemovableIndex, by: -1) {
                guard outboundMessages[index].kind == .continuationCreate else { continue }
                let removed = outboundMessages.remove(at: index)
                outboundBytes = max(0, outboundBytes - removed.bytes)
                removedUnsent += 1
            }
        }

        let expectedCreates = pendingResponseOrigins.count
        return max(0, expectedCreates - removedUnsent)
    }

    /// Removes out-of-band audio classifiers that have not reached the socket.
    /// An in-flight classifier is invalidated through its attempt metadata and
    /// cancelled as soon as the server exposes its response ID.
    private func discardQueuedAudioCorroborationCreatesLocked() -> Set<String> {
        let firstRemovableIndex = outboundSendInFlight ? 1 : 0
        var removedAttemptIDs = Set<String>()
        guard firstRemovableIndex < outboundMessages.count else {
            return removedAttemptIDs
        }
        for index in stride(from: outboundMessages.count - 1, through: firstRemovableIndex, by: -1) {
            guard case .audioCorroborationCreate(let attemptID) = outboundMessages[index].kind else {
                continue
            }
            let removed = outboundMessages.remove(at: index)
            outboundBytes = max(0, outboundBytes - removed.bytes)
            removedAttemptIDs.insert(attemptID)
        }
        return removedAttemptIDs
    }

    private func discardQueuedAudioCorroborationCreateLocked(attemptID: String) -> Bool {
        let firstRemovableIndex = outboundSendInFlight ? 1 : 0
        guard firstRemovableIndex < outboundMessages.count else { return false }
        for index in stride(from: outboundMessages.count - 1, through: firstRemovableIndex, by: -1) {
            guard case .audioCorroborationCreate(let queuedAttemptID) = outboundMessages[index].kind,
                  queuedAttemptID == attemptID else { continue }
            let removed = outboundMessages.remove(at: index)
            outboundBytes = max(0, outboundBytes - removed.bytes)
            return true
        }
        return false
    }

    /// Removes private image uploads which have not reached the socket. An
    /// in-flight create cannot be recalled, so its caller sends a matching
    /// delete; a purely queued image is never uploaded at all.
    private func discardQueuedVisualContextCreatesLocked() -> Set<String> {
        let firstRemovableIndex = outboundSendInFlight ? 1 : 0
        var removedItemIDs = Set<String>()
        guard firstRemovableIndex < outboundMessages.count else { return removedItemIDs }
        for index in stride(from: outboundMessages.count - 1, through: firstRemovableIndex, by: -1) {
            guard case .visualContextCreate(let itemID) = outboundMessages[index].kind else {
                continue
            }
            let removed = outboundMessages.remove(at: index)
            outboundBytes = max(0, outboundBytes - removed.bytes)
            removedItemIDs.insert(itemID)
        }
        return removedItemIDs
    }

    private func discardQueuedVisualContextCreateLocked(itemID: String) -> Bool {
        let firstRemovableIndex = outboundSendInFlight ? 1 : 0
        guard firstRemovableIndex < outboundMessages.count else { return false }
        for index in stride(from: outboundMessages.count - 1, through: firstRemovableIndex, by: -1) {
            guard case .visualContextCreate(let queuedItemID) = outboundMessages[index].kind,
                  queuedItemID == itemID else { continue }
            let removed = outboundMessages.remove(at: index)
            outboundBytes = max(0, outboundBytes - removed.bytes)
            return true
        }
        return false
    }

    private func trimStateCollectionsLocked() {
        if inputItemsAwaitingResponse.count > 32 {
            inputItemsAwaitingResponse.removeFirst(inputItemsAwaitingResponse.count - 32)
        }
        if responseInputItems.count > 64 {
            let active = Set(toolBatches.keys).union(playbackKeys.values.map(\.responseID))
            for key in Array(responseInputItems.keys) where !active.contains(key) {
                responseInputItems.removeValue(forKey: key)
                if responseInputItems.count <= 48 { break }
            }
        }
        if backgroundTaskDeliveryByResponseID.count > 32 {
            let active = Set(playbackKeys.values.map(\.responseID))
                .union(activeResponseID.map { [$0] } ?? [])
            for key in Array(backgroundTaskDeliveryByResponseID.keys)
                where !active.contains(key) {
                backgroundTaskDeliveryByResponseID.removeValue(forKey: key)
                if backgroundTaskDeliveryByResponseID.count <= 24 { break }
            }
        }
        if actionProposalResponseIDs.count > 64 {
            let activeResponses = Set(responseInputItems.keys)
            actionProposalResponseIDs = actionProposalResponseIDs.intersection(activeResponses)
        }
        if userTranscripts.count > 48 {
            for key in Array(userTranscripts.keys).prefix(userTranscripts.count - 48) {
                userTranscripts.removeValue(forKey: key)
                finalizedUserTranscriptItems.remove(key)
            }
        }
        if supersededResponseIDs.count > 64 {
            for key in Array(supersededResponseIDs.prefix(supersededResponseIDs.count - 48)) {
                supersededResponseIDs.remove(key)
                supersededUnheardBackgroundItemByResponseID.removeValue(forKey: key)
            }
        }
        if retiredUnheardBackgroundResponseIDs.count > 64 {
            retiredUnheardBackgroundResponseIDs = Set(
                retiredUnheardBackgroundResponseIDs.prefix(48)
            )
        }
        if spokenInputItemIDs.count > 64 {
            let activeInputs = Set(responseInputItems.values)
            for key in Array(spokenInputItemIDs) where !activeInputs.contains(key) {
                spokenInputItemIDs.remove(key)
                if spokenInputItemIDs.count <= 48 { break }
            }
        }
        if toolReceiptInputItems.count > 64 {
            let activeInputs = Set(responseInputItems.values)
            for key in Array(toolReceiptInputItems) where !activeInputs.contains(key) {
                toolReceiptInputItems.remove(key)
                if toolReceiptInputItems.count <= 48 { break }
            }
        }
        if forceConversationMoveInputItems.count > 64
            || internalHelperCallCounts.count > 64
            || forcedConversationMoveAttemptCounts.count > 64 {
            let activeInputs = Set(responseInputItems.values)
                .union(readyContinuations.compactMap(\.inputItemID))
                .union(pendingResponseOrigins.compactMap(\.inputItemID))
            for key in Array(forceConversationMoveInputItems)
                where !activeInputs.contains(key) {
                forceConversationMoveInputItems.remove(key)
                internalHelperCallCounts.removeValue(forKey: key)
                authorizedDelegateBindingByInputItem.removeValue(forKey: key)
                forcedConversationMoveAttemptCounts.removeValue(forKey: key)
                if forceConversationMoveInputItems.count <= 48,
                   internalHelperCallCounts.count <= 48,
                   forcedConversationMoveAttemptCounts.count <= 48 { break }
            }
            if internalHelperCallCounts.count > 64 {
                for key in Array(internalHelperCallCounts.keys)
                    where !activeInputs.contains(key) {
                    internalHelperCallCounts.removeValue(forKey: key)
                    authorizedDelegateBindingByInputItem.removeValue(forKey: key)
                    if internalHelperCallCounts.count <= 48 { break }
                }
            }
            if forcedConversationMoveAttemptCounts.count > 64 {
                for key in Array(forcedConversationMoveAttemptCounts.keys)
                    where !activeInputs.contains(key) {
                    forcedConversationMoveAttemptCounts.removeValue(forKey: key)
                    if forcedConversationMoveAttemptCounts.count <= 48 { break }
                }
            }
        }
        if conversationMoveInputItems.count > 64 {
            let activeInputs = Set(responseInputItems.values)
            for key in Array(conversationMoveInputItems) where !activeInputs.contains(key) {
                conversationMoveInputItems.remove(key)
                if conversationMoveInputItems.count <= 48 { break }
            }
        }
        if delegateTaskAcknowledgementInputItems.count > 64 {
            let activeInputs = Set(responseInputItems.values)
            for key in Array(delegateTaskAcknowledgementInputItems)
                where !activeInputs.contains(key) {
                delegateTaskAcknowledgementInputItems.remove(key)
                if delegateTaskAcknowledgementInputItems.count <= 48 { break }
            }
        }
        if delegateTaskRetryInputItems.count > 64
            || delegateTaskRetryAttemptCounts.count > 64 {
            let activeInputs = Set(responseInputItems.values)
                .union(readyContinuations.compactMap(\.inputItemID))
                .union(pendingResponseOrigins.compactMap(\.inputItemID))
            for key in Array(delegateTaskRetryInputItems)
                where !activeInputs.contains(key) {
                delegateTaskRetryInputItems.remove(key)
                delegateTaskRetryAttemptCounts.removeValue(forKey: key)
                delegateRetryToolNameByInputItem.removeValue(forKey: key)
                if delegateTaskRetryInputItems.count <= 48,
                   delegateTaskRetryAttemptCounts.count <= 48 { break }
            }
            if delegateTaskRetryAttemptCounts.count > 64 {
                for key in Array(delegateTaskRetryAttemptCounts.keys)
                    where !activeInputs.contains(key) {
                    delegateTaskRetryAttemptCounts.removeValue(forKey: key)
                    delegateRetryToolNameByInputItem.removeValue(forKey: key)
                    if delegateTaskRetryAttemptCounts.count <= 48 { break }
                }
            }
        }
        if ignoredAudioCorroborationEventIDs.count > 64 {
            for key in Array(ignoredAudioCorroborationEventIDs.prefix(
                ignoredAudioCorroborationEventIDs.count - 48
            )) {
                ignoredAudioCorroborationEventIDs.remove(key)
            }
        }
        if ignoredAudioCorroborationResponseIDs.count > 64 {
            // Any evicted classifier response still carries the reserved OOB
            // purpose and is quarantined by the response handlers. Keeping the
            // newest 48 tombstones bounds a long-running voice session without
            // creating a path back into normal tool dispatch.
            for key in Array(ignoredAudioCorroborationResponseIDs.prefix(
                ignoredAudioCorroborationResponseIDs.count - 48
            )) {
                ignoredAudioCorroborationResponseIDs.remove(key)
            }
        }
        if audioCorroborationPlaybackSuppressedResponseIDs.count > 64 {
            let liveClassifierResponses = Set(audioMotorAttemptByResponseID.keys)
            for key in Array(audioCorroborationPlaybackSuppressedResponseIDs)
                where !liveClassifierResponses.contains(key) {
                audioCorroborationPlaybackSuppressedResponseIDs.remove(key)
                if audioCorroborationPlaybackSuppressedResponseIDs.count <= 48 { break }
            }
        }
        if malformedAudioCorroborationResponseIDs.count > 64 {
            let liveClassifierResponses = Set(audioMotorAttemptByResponseID.keys)
            for key in Array(malformedAudioCorroborationResponseIDs)
                where !liveClassifierResponses.contains(key) {
                malformedAudioCorroborationResponseIDs.remove(key)
                if malformedAudioCorroborationResponseIDs.count <= 48 { break }
            }
        }
        if specialFailureResponseIDs.count > 64 {
            let active = activeResponseID
            for key in Array(specialFailureResponseIDs) where key != active {
                specialFailureResponseIDs.remove(key)
                if specialFailureResponseIDs.count <= 48 { break }
            }
        }
    }

    private func report(
        _ error: Error,
        terminal: Bool,
        connectionID explicitConnectionID: UUID? = nil
    ) {
        let callbackConnectionID = explicitConnectionID ?? connectionID
        emit { $0.onError?(callbackConnectionID, error) }
        if terminal {
            let visibleDescription = (error as? AuroraRealtimeError)?.userFacingDescription
                ?? "Aurora couldn't continue just now."
            emitPhase(.failed(visibleDescription), connectionID: callbackConnectionID)
        }
    }

    private func emitDiagnosticLocked(_ kind: String, metadata: [String: String] = [:]) {
        guard let connectionID else { return }
        emit { $0.onDiagnostic?(connectionID, kind, metadata) }
    }

    private func numericBoundaryMetadata(
        _ event: [String: Any],
        keys: [String]
    ) -> [String: String] {
        var metadata: [String: String] = [:]
        for key in keys {
            if let number = event[key] as? NSNumber {
                metadata[key] = number.stringValue
            } else if let value = event[key] as? String, !value.isEmpty {
                metadata[key] = value
            }
        }
        return metadata
    }

    private func numericBoundaryMilliseconds(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite
                ? Int(number.doubleValue.rounded())
                : nil
        }
        if let text = value as? String,
           let number = Double(text), number.isFinite {
            return Int(number.rounded())
        }
        return nil
    }

    private func emitPhase(_ phase: AuroraPhase, connectionID explicitConnectionID: UUID? = nil) {
        let callbackConnectionID = explicitConnectionID ?? connectionID
        emit { $0.onPhase?(callbackConnectionID, phase) }
    }

    private func emitFunctionCallLocked(_ call: RealtimeFunctionCall) {
        if isDurableDelegateCallLocked(call) {
            // response.done was held until this owner turn finalized. Once
            // that boundary is crossed, a callback already queued for the app
            // must survive ordinary barge-in just like the Codex task itself.
            emit { $0.onFunctionCall?(call) }
            return
        }
        let deliveryGeneration = functionCallDeliveryGate.snapshot()
        emit { client in
            guard client.functionCallDeliveryGate.isCurrent(deliveryGeneration) else { return }
            client.onFunctionCall?(call)
        }
    }

    private func isDurableDelegateCallLocked(_ call: RealtimeFunctionCall) -> Bool {
        (call.name == "delegate_task" || call.name == "codex_project_chat")
            && call.authorizationSource == .directOwnerTurn
            && call.inputItemID != nil
            && call.sourceTurnFinalized
    }

    private func emit(_ callback: @escaping (AuroraRealtimeClient) -> Void) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            callback(self)
        }
    }
}
