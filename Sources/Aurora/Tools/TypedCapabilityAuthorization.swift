import Foundation

/// Exact effect identity for a narrow typed capability. Realtime resolves the
/// intent; deterministic code binds that resolved effect to the current owner
/// turn without reparsing natural language.
public struct TypedCapabilityEffect: Codable, Sendable, Equatable {
    public let operation: String
    public let target: String
    public let parameters: [String: String]

    public init(operation: String, target: String, parameters: [String: String]) {
        self.operation = operation
        self.target = target
        self.parameters = parameters
    }
}

public struct TypedCapabilityAuthorizationEnvelope: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let requestID: String
    public let sourceTurnIDs: [String]
    public let sessionID: String
    public let speakerBinding: AuthorizationSpeakerBinding
    public let allowedEffect: TypedCapabilityEffect
    public let confirmationState: AuthorizationConfirmationState
    public let issuedAt: Date
    public let expiresAt: Date

    public func allows(
        effect: TypedCapabilityEffect,
        at date: Date = Date()
    ) -> Bool {
        confirmationState.permitsExecution
            && date >= issuedAt
            && date <= expiresAt
            && allowedEffect == effect
    }
}

public enum TypedCapabilityAuthorizationDenialReason: String, Codable, Sendable, Equatable {
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
    case effectMismatch = "effect_mismatch"
}

public enum TypedCapabilityAuthorizationDecision: Sendable, Equatable {
    case authorized(TypedCapabilityAuthorizationEnvelope)
    case denied(TypedCapabilityAuthorizationDenialReason)

    public var envelope: TypedCapabilityAuthorizationEnvelope? {
        guard case .authorized(let envelope) = self else { return nil }
        return envelope
    }

    public var denialReason: TypedCapabilityAuthorizationDenialReason? {
        guard case .denied(let reason) = self else { return nil }
        return reason
    }
}

public enum TypedCapabilityAuthorizationFactory {
    public static let lifetime: TimeInterval = 20
    private static let maximumIdentityCharacters = 256

    public static func issue(
        commitment: IntentCommitment,
        effect: TypedCapabilityEffect,
        context: ToolInvocationContext,
        confirmationState: AuthorizationConfirmationState = .notRequired,
        now: Date = Date(),
        authorizationID: String = UUID().uuidString
    ) -> TypedCapabilityAuthorizationDecision {
        guard validIdentity(context.callID), validIdentity(authorizationID) else {
            return .denied(.requestUnavailable)
        }
        guard let sessionID = context.sessionID, validIdentity(sessionID) else {
            return .denied(.sessionUnavailable)
        }
        guard let sourceTurnID = context.ownerAudioItemID,
              validIdentity(sourceTurnID) else {
            return .denied(.sourceTurnUnavailable)
        }
        guard context.participantIsOwner else {
            return .denied(.speakerUnverified)
        }
        guard context.sourceTurnFinalized else {
            return .denied(.turnUnfinalized)
        }
        guard context.authorizationSource == .directOwnerTurn else {
            return .denied(.indirectContinuation)
        }
        guard context.origin == ActionAuthorizationFactory.trustedVoiceOrigin,
              context.hasTrustedCurrentOwnerAudio else {
            return .denied(.untrustedOrigin)
        }
        switch commitment {
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

        return .authorized(TypedCapabilityAuthorizationEnvelope(
            authorizationID: authorizationID,
            requestID: context.callID,
            sourceTurnIDs: [sourceTurnID],
            sessionID: sessionID,
            speakerBinding: .configuredOwnerVoiceSession,
            allowedEffect: effect,
            confirmationState: confirmationState,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        ))
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
}
