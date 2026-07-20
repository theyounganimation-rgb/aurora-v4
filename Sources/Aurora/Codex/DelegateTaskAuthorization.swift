import Foundation

public enum AuthorizationSpeakerBinding: String, Codable, Sendable, Equatable {
    /// Session participant provenance identified this committed input as the
    /// configured owner. This is not biometric voice recognition.
    case configuredOwnerVoiceSession = "configured_owner_voice_session"
}

public enum AuthorizationConfirmationState: String, Codable, Sendable, Equatable {
    case notRequired = "not_required"
    case pending
    case confirmed
    case denied

    public var permitsExecution: Bool {
        self == .notRequired || self == .confirmed
    }
}

public struct DelegateTaskEffect: Codable, Sendable, Equatable {
    public let operation: DelegateTaskOperation
    public let targetReference: DelegateTaskTargetReference
    public let taskKind: DelegateTaskKind?
    public let executionClass: DelegateTaskExecutionClass?
    public let parameters: DelegateTaskParameters

    public init(proposal: DelegateTaskProposal) {
        operation = proposal.operation
        targetReference = proposal.targetReference
        taskKind = proposal.taskKind
        executionClass = proposal.executionClass
        parameters = proposal.parameters
    }
}

/// Trusted state for the exact active task to which a contextual reference was
/// resolved. Realtime can say `active_task`; it cannot manufacture this value.
public struct DelegateTaskAuthorizationBinding: Codable, Sendable, Equatable {
    public let taskID: String
    public let sessionID: String
    public let revision: UInt64
    public let rootAuthorizationID: String
    public let sourceTurnIDs: [String]
    public let taskKind: DelegateTaskKind

    public init(
        taskID: String,
        sessionID: String,
        revision: UInt64,
        rootAuthorizationID: String,
        sourceTurnIDs: [String],
        taskKind: DelegateTaskKind
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.revision = revision
        self.rootAuthorizationID = rootAuthorizationID
        self.sourceTurnIDs = sourceTurnIDs
        self.taskKind = taskKind
    }
}

public enum DelegateTaskAuthorizationDenialReason: String, Codable, Sendable, Equatable {
    case requestUnavailable = "request_unavailable"
    case sourceTurnUnavailable = "source_turn_unavailable"
    case sessionUnavailable = "session_unavailable"
    case speakerUnverified = "speaker_unverified"
    case turnUnfinalized = "turn_unfinalized"
    case untrustedOrigin = "untrusted_origin"
    case indirectContinuation = "indirect_continuation"
    case intentCancelled = "intent_cancelled"
    case intentConditional = "intent_conditional"
    case intentDelayed = "intent_delayed"
    case intentUncertain = "intent_uncertain"
    case confirmationRequired = "confirmation_required"
    case confirmationDenied = "confirmation_denied"
    case taskUnavailable = "task_unavailable"
    case staleActiveTask = "stale_active_task"
    case effectMismatch = "effect_mismatch"
    case invalidExpiration = "invalid_expiration"
}

public struct DelegateTaskAuthorizationEnvelope: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let requestID: String
    public let sourceTurnIDs: [String]
    public let sessionID: String
    public let speakerBinding: AuthorizationSpeakerBinding
    public let operation: DelegateTaskOperation
    public let allowedEffect: DelegateTaskEffect
    public let activeTaskBinding: DelegateTaskAuthorizationBinding?
    public let confirmationState: AuthorizationConfirmationState
    public let issuedAt: Date
    public let expiresAt: Date

    public func isActive(at date: Date = Date()) -> Bool {
        confirmationState.permitsExecution
            && date >= issuedAt
            && date <= expiresAt
    }

    public func allows(
        effect: DelegateTaskEffect,
        activeTaskBinding: DelegateTaskAuthorizationBinding?,
        at date: Date = Date()
    ) -> Bool {
        isActive(at: date)
            && operation == effect.operation
            && allowedEffect == effect
            && self.activeTaskBinding == activeTaskBinding
    }
}

public enum DelegateTaskAuthorizationDecision: Sendable, Equatable {
    case authorized(DelegateTaskAuthorizationEnvelope)
    case denied(DelegateTaskAuthorizationDenialReason)

    public var envelope: DelegateTaskAuthorizationEnvelope? {
        guard case .authorized(let envelope) = self else { return nil }
        return envelope
    }

    public var denialReason: DelegateTaskAuthorizationDenialReason? {
        guard case .denied(let reason) = self else { return nil }
        return reason
    }
}

public enum DelegateTaskAuthorizationFactory {
    public static let lifetime: TimeInterval = 20
    public static let trustedVoiceOrigin = "aurora_native_realtime_voice"
    private static let maximumIdentityCharacters = 256
    private static let maximumSourceTurns = 16

    public static func issue(
        proposal: DelegateTaskProposal,
        context: ToolInvocationContext,
        activeTaskBinding: DelegateTaskAuthorizationBinding?,
        confirmationState: AuthorizationConfirmationState = .notRequired,
        now: Date = Date(),
        authorizationID: String = UUID().uuidString
    ) -> DelegateTaskAuthorizationDecision {
        guard validIdentity(context.callID), validIdentity(authorizationID) else {
            return .denied(.requestUnavailable)
        }
        guard let sessionID = context.sessionID, validIdentity(sessionID) else {
            return .denied(.sessionUnavailable)
        }
        guard context.participantIsOwner else {
            return .denied(.speakerUnverified)
        }
        guard context.sourceTurnFinalized else {
            return .denied(.turnUnfinalized)
        }
        // A bounded internal helper may finish before Realtime can resolve the
        // owner's external goal. Its continuation remains authorized only by
        // the same finalized owner-audio item below; the helper result itself
        // is never added to sourceTurnIDs or treated as a permission source.
        // Visual and mail continuations have distinct provenance and stay
        // denied here even when they carry the same input item identifier.
        guard context.authorizationSource == .directOwnerTurn
                || context.authorizationSource == .toolContinuation else {
            return .denied(.indirectContinuation)
        }
        guard context.origin == trustedVoiceOrigin,
              context.hasTrustedCurrentOwnerAudio else {
            return .denied(.untrustedOrigin)
        }
        if context.authorizationSource == .toolContinuation {
            let expectedBinding = proposal.canonicalAuthorizationBinding
            guard !expectedBinding.isEmpty,
                  context.preauthorizedDelegateBinding == expectedBinding else {
                return .denied(.effectMismatch)
            }
        }
        guard let sourceTurnID = context.ownerAudioItemID,
              validIdentity(sourceTurnID) else {
            return .denied(.sourceTurnUnavailable)
        }
        switch proposal.commitment {
        case .execute:
            break
        case .cancel:
            return .denied(.intentCancelled)
        case .conditional:
            return .denied(.intentConditional)
        case .delayed:
            return .denied(.intentDelayed)
        case .uncertain:
            return .denied(.intentUncertain)
        }
        switch confirmationState {
        case .notRequired, .confirmed:
            break
        case .pending:
            return .denied(.confirmationRequired)
        case .denied:
            return .denied(.confirmationDenied)
        }

        if proposal.targetReference == .activeTask {
            guard let activeTaskBinding else { return .denied(.taskUnavailable) }
            guard activeTaskBinding.sessionID == sessionID,
                  validBinding(activeTaskBinding) else {
                return .denied(.staleActiveTask)
            }
        } else if activeTaskBinding != nil {
            return .denied(.effectMismatch)
        }

        var sourceTurnIDs = activeTaskBinding?.sourceTurnIDs ?? []
        sourceTurnIDs.append(sourceTurnID)
        sourceTurnIDs = Array(deduplicated(sourceTurnIDs).suffix(maximumSourceTurns))
        guard !sourceTurnIDs.isEmpty,
              sourceTurnIDs.allSatisfy(validIdentity) else {
            return .denied(.sourceTurnUnavailable)
        }

        let expiresAt = now.addingTimeInterval(lifetime)
        guard expiresAt > now else { return .denied(.invalidExpiration) }
        return .authorized(DelegateTaskAuthorizationEnvelope(
            authorizationID: authorizationID,
            requestID: context.callID,
            sourceTurnIDs: sourceTurnIDs,
            sessionID: sessionID,
            speakerBinding: .configuredOwnerVoiceSession,
            operation: proposal.operation,
            allowedEffect: DelegateTaskEffect(proposal: proposal),
            activeTaskBinding: activeTaskBinding,
            confirmationState: confirmationState,
            issuedAt: now,
            expiresAt: expiresAt
        ))
    }

    private static func validBinding(_ binding: DelegateTaskAuthorizationBinding) -> Bool {
        validIdentity(binding.taskID)
            && validIdentity(binding.sessionID)
            && validIdentity(binding.rootAuthorizationID)
            && !binding.sourceTurnIDs.isEmpty
            && binding.sourceTurnIDs.count <= maximumSourceTurns
            && binding.sourceTurnIDs.allSatisfy(validIdentity)
    }

    private static func validIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !trimmed.isEmpty
            && trimmed.count <= maximumIdentityCharacters
            && trimmed.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Exact effect authorized for one explicit Codex project/chat operation.
/// `relayText` is host-finalized transcript evidence for staged relay, or the
/// tightly extracted message for the explicit one-shot relay operation.
public struct CodexProjectChatResolvedTarget: Codable, Sendable, Equatable {
    /// Monotonic host-owned generation of the selected project/chat state.
    /// This makes an authorization stale if another call switches or leaves
    /// focus before execution reaches the dispatch boundary.
    public let focusGeneration: UInt64
    public let mode: CodexProjectChatFocusMode?
    public let projectDisplayName: String?
    /// Registered/local project root used for Desktop grouping and new chats.
    public let workspacePath: String?
    /// Exact existing thread cwd used by app-server security validation. It
    /// may be a descendant of the project root.
    public let threadWorkingDirectoryPath: String?
    public let threadDisplayName: String?
    public let threadID: String?

    public init(
        focusGeneration: UInt64,
        mode: CodexProjectChatFocusMode?,
        projectDisplayName: String?,
        workspacePath: String?,
        threadWorkingDirectoryPath: String?,
        threadDisplayName: String?,
        threadID: String?
    ) {
        self.focusGeneration = focusGeneration
        self.mode = mode
        self.projectDisplayName = projectDisplayName
        self.workspacePath = workspacePath
        self.threadWorkingDirectoryPath = threadWorkingDirectoryPath
        self.threadDisplayName = threadDisplayName
        self.threadID = threadID
    }
}

public struct CodexProjectChatEffect: Codable, Sendable, Equatable {
    public let operation: CodexProjectChatOperation
    public let projectName: String?
    public let chatName: String?
    public let threadID: String?
    public let relayText: String?
    public let resolvedTarget: CodexProjectChatResolvedTarget

    public init(
        proposal: CodexProjectChatProposal,
        relayText: String?,
        resolvedTarget: CodexProjectChatResolvedTarget
    ) {
        operation = proposal.operation
        projectName = proposal.projectName
        chatName = proposal.chatName
        threadID = proposal.threadID
        self.relayText = relayText
        self.resolvedTarget = resolvedTarget
    }
}

public struct CodexProjectChatAuthorizationEnvelope: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let requestID: String
    public let sourceTurnID: String
    public let sessionID: String
    public let speakerBinding: AuthorizationSpeakerBinding
    public let allowedEffect: CodexProjectChatEffect
    public let confirmationState: AuthorizationConfirmationState
    public let issuedAt: Date
    public let expiresAt: Date

    public func allows(
        _ effect: CodexProjectChatEffect,
        at date: Date = Date()
    ) -> Bool {
        confirmationState.permitsExecution
            && date >= issuedAt
            && date <= expiresAt
            && effect == allowedEffect
    }

    public var isActiveForProjectChat: Bool {
        confirmationState.permitsExecution
            && Date() >= issuedAt
            && Date() <= expiresAt
    }
}

public enum CodexProjectChatAuthorizationFactory {
    public static let lifetime: TimeInterval = 20

    public static func issue(
        proposal: CodexProjectChatProposal,
        relayText: String?,
        resolvedTarget: CodexProjectChatResolvedTarget,
        sourceTranscript: String?,
        context: ToolInvocationContext,
        confirmationState: AuthorizationConfirmationState = .notRequired,
        now: Date = Date(),
        authorizationID: String = UUID().uuidString
    ) -> Result<CodexProjectChatAuthorizationEnvelope, DelegateTaskAuthorizationDenialReason> {
        guard validIdentity(context.callID), validIdentity(authorizationID) else {
            return .failure(.requestUnavailable)
        }
        guard let sessionID = context.sessionID, validIdentity(sessionID) else {
            return .failure(.sessionUnavailable)
        }
        guard context.participantIsOwner else { return .failure(.speakerUnverified) }
        guard context.sourceTurnFinalized else { return .failure(.turnUnfinalized) }
        guard context.authorizationSource == .directOwnerTurn else {
            return .failure(.indirectContinuation)
        }
        guard context.origin == DelegateTaskAuthorizationFactory.trustedVoiceOrigin,
              context.hasTrustedCurrentOwnerAudio else {
            return .failure(.untrustedOrigin)
        }
        guard let sourceTurnID = context.ownerAudioItemID,
              validIdentity(sourceTurnID) else {
            return .failure(.sourceTurnUnavailable)
        }
        switch proposal.commitment {
        case .execute: break
        case .cancel: return .failure(.intentCancelled)
        case .conditional: return .failure(.intentConditional)
        case .delayed: return .failure(.intentDelayed)
        case .uncertain: return .failure(.intentUncertain)
        }
        switch confirmationState {
        case .notRequired, .confirmed: break
        case .pending: return .failure(.confirmationRequired)
        case .denied: return .failure(.confirmationDenied)
        }
        let effect = CodexProjectChatEffect(
            proposal: proposal,
            relayText: relayText,
            resolvedTarget: resolvedTarget
        )
        switch proposal.operation {
        case .relay, .relayToChat:
            guard let relayText,
                  relayText == relayText.trimmingCharacters(in: .whitespacesAndNewlines),
                  !relayText.isEmpty,
                  relayText.count <= CodexProjectChatProposal.maximumMessageCharacters,
                  relayText.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters
                          .subtracting(.newlines)
                          .contains($0)
                  }) else {
                return .failure(.effectMismatch)
            }
            if proposal.operation == .relayToChat {
                guard sourceTranscript?.contains(relayText) == true else {
                    // The one-shot message must be an exact owner-audio span.
                    // Realtime may locate it, but may never paraphrase or add
                    // instructions at this authorization boundary.
                    return .failure(.effectMismatch)
                }
            }
        default:
            guard relayText == nil else { return .failure(.effectMismatch) }
        }
        guard validResolvedTarget(resolvedTarget, for: proposal.operation) else {
            return .failure(.effectMismatch)
        }
        let expiresAt = now.addingTimeInterval(lifetime)
        guard expiresAt > now else { return .failure(.invalidExpiration) }
        return .success(CodexProjectChatAuthorizationEnvelope(
            authorizationID: authorizationID,
            requestID: context.callID,
            sourceTurnID: sourceTurnID,
            sessionID: sessionID,
            speakerBinding: .configuredOwnerVoiceSession,
            allowedEffect: effect,
            confirmationState: confirmationState,
            issuedAt: now,
            expiresAt: expiresAt
        ))
    }

    private static func validIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !trimmed.isEmpty
            && trimmed.count <= 256
            && trimmed.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func validResolvedTarget(
        _ target: CodexProjectChatResolvedTarget,
        for operation: CodexProjectChatOperation
    ) -> Bool {
        let workspaceValid = target.workspacePath.map {
            !$0.isEmpty && $0.hasPrefix("/") && $0.count <= 4_096
        } ?? true
        let threadValid = target.threadID.map(validIdentity) ?? true
        let threadWorkspaceValid = target.threadWorkingDirectoryPath.map {
            !$0.isEmpty && $0.hasPrefix("/") && $0.count <= 4_096
        } ?? true
        guard workspaceValid, threadWorkspaceValid, threadValid else { return false }
        switch operation {
        case .listProjects:
            return target.mode == nil
                && target.workspacePath == nil
                && target.threadWorkingDirectoryPath == nil
                && target.threadID == nil
        case .focusProject:
            return target.mode == .projectSelected
                && target.workspacePath != nil
                && target.threadWorkingDirectoryPath == nil
                && target.threadID == nil
        case .focusChat, .relayToChat:
            return target.mode == .threadSelected
                && target.workspacePath != nil
                && target.threadWorkingDirectoryPath != nil
                && target.threadID != nil
        case .prepareNewChat:
            return target.mode == .newThreadPending
                && target.workspacePath != nil
                && target.threadWorkingDirectoryPath == nil
                && target.threadID == nil
        case .relay:
            return target.workspacePath != nil
                && (
                    (target.mode == .threadSelected
                        && target.threadID != nil
                        && target.threadWorkingDirectoryPath != nil)
                        || (target.mode == .newThreadPending
                            && target.threadID == nil
                            && target.threadWorkingDirectoryPath == nil)
                )
        case .leaveFocus, .status:
            if target.mode == nil {
                return target.workspacePath == nil
                    && target.threadWorkingDirectoryPath == nil
                    && target.threadID == nil
            }
            return target.workspacePath != nil
                && (target.mode == .threadSelected) == (target.threadID != nil)
        }
    }
}

extension DelegateTaskAuthorizationDenialReason: Error {}
