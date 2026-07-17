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
