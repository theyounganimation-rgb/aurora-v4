import Foundation

/// A concrete host-resolved target. Realtime can ask for `active_note`, but it
/// cannot supply the private Notes identifier carried by `.note`.
public enum AuthorizedActionTarget: Sendable, Equatable {
    case notesApplication
    case newNote
    case note(identifier: String)
}

extension AuthorizedActionTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }

    private enum Kind: String, Codable {
        case notesApplication = "notes_application"
        case newNote = "new_note"
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notesApplication:
            guard !container.contains(.identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .identifier,
                    in: container,
                    debugDescription: "A Notes application target cannot carry an identifier."
                )
            }
            self = .notesApplication
        case .newNote:
            guard !container.contains(.identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .identifier,
                    in: container,
                    debugDescription: "A new-note target cannot carry an identifier."
                )
            }
            self = .newNote
        case .note:
            let identifier = try container.decode(String.self, forKey: .identifier)
            guard ActionAuthorizationFactory.isValidOpaqueIdentifier(identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .identifier,
                    in: container,
                    debugDescription: "The Notes identifier is outside the authorization boundary."
                )
            }
            self = .note(identifier: identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notesApplication:
            try container.encode(Kind.notesApplication, forKey: .kind)
        case .newNote:
            try container.encode(Kind.newNote, forKey: .kind)
        case .note(let identifier):
            guard ActionAuthorizationFactory.isValidOpaqueIdentifier(identifier) else {
                throw EncodingError.invalidValue(
                    identifier,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "The Notes identifier is outside the authorization boundary."
                    )
                )
            }
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

/// The exact effect authorized by one owner turn. Equality is deliberately
/// structural and case-sensitive: a plan may change its execution route, but
/// not its operation, target, title, item order, or item content.
public struct AuthorizedActionEffect: Codable, Sendable, Equatable {
    public let operation: IntentOperation
    public let target: AuthorizedActionTarget
    public let parameters: IntentParameters

    public init(
        operation: IntentOperation,
        target: AuthorizedActionTarget,
        parameters: IntentParameters
    ) {
        self.operation = operation
        self.target = target
        self.parameters = parameters
    }
}

public enum AuthorizationSpeakerBinding: String, Codable, Sendable, Equatable {
    /// Session participant provenance identified this committed input as the
    /// configured owner. This is not a claim of biometric voice recognition.
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

public struct ActionAuthorizationEnvelope: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let requestID: String
    public let sourceTurnIDs: [String]
    public let sessionID: String
    public let speakerBinding: AuthorizationSpeakerBinding
    public let operation: IntentOperation
    public let allowedEffect: AuthorizedActionEffect
    public let confirmationState: AuthorizationConfirmationState
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        authorizationID: String,
        requestID: String,
        sourceTurnIDs: [String],
        sessionID: String,
        speakerBinding: AuthorizationSpeakerBinding,
        operation: IntentOperation,
        allowedEffect: AuthorizedActionEffect,
        confirmationState: AuthorizationConfirmationState,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.authorizationID = authorizationID
        self.requestID = requestID
        self.sourceTurnIDs = sourceTurnIDs
        self.sessionID = sessionID
        self.speakerBinding = speakerBinding
        self.operation = operation
        self.allowedEffect = allowedEffect
        self.confirmationState = confirmationState
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        confirmationState.permitsExecution
            && date >= issuedAt
            && date <= expiresAt
    }

    /// The sole plan-scope comparison. No transcript text, phrase list, route
    /// name, or executor preference participates in this decision.
    public func allows(
        effect proposedEffect: AuthorizedActionEffect,
        at date: Date = Date()
    ) -> Bool {
        isActive(at: date)
            && operation == proposedEffect.operation
            && allowedEffect == proposedEffect
    }
}

public enum ActionAuthorizationDenialReason: String, Codable, Sendable, Equatable {
    case requestUnavailable = "request_unavailable"
    case sourceTurnUnavailable = "source_turn_unavailable"
    case sessionUnavailable = "session_unavailable"
    case speakerUnverified = "speaker_unverified"
    case turnUnfinalized = "turn_unfinalized"
    case untrustedOrigin = "untrusted_origin"
    case intentCancelled = "intent_cancelled"
    case intentConditional = "intent_conditional"
    case intentDelayed = "intent_delayed"
    case intentUncertain = "intent_uncertain"
    case confirmationRequired = "confirmation_required"
    case confirmationDenied = "confirmation_denied"
    case targetUnavailable = "target_unavailable"
    case effectMismatch = "effect_mismatch"
    case invalidExpiration = "invalid_expiration"
}

public enum ActionAuthorizationDecision: Sendable, Equatable {
    case authorized(ActionAuthorizationEnvelope)
    case denied(ActionAuthorizationDenialReason)

    public var envelope: ActionAuthorizationEnvelope? {
        guard case .authorized(let envelope) = self else { return nil }
        return envelope
    }

    public var denialReason: ActionAuthorizationDenialReason? {
        guard case .denied(let reason) = self else { return nil }
        return reason
    }
}

/// A cancellation is itself an action. It receives a fresh, short-lived
/// authorization bound to the exact running task and exact effect that the
/// owner referred to; it is never represented by a loose boolean.
public struct ActionCancellationAuthorizationEnvelope: Codable, Sendable, Equatable {
    public let authorizationID: String
    public let requestID: String
    public let sourceTurnIDs: [String]
    public let sessionID: String
    public let speakerBinding: AuthorizationSpeakerBinding
    public let taskID: String
    public let cancelledEffect: AuthorizedActionEffect
    public let confirmationState: AuthorizationConfirmationState
    public let issuedAt: Date
    public let expiresAt: Date

    public func allows(
        taskID proposedTaskID: String,
        effect proposedEffect: AuthorizedActionEffect,
        at date: Date = Date()
    ) -> Bool {
        confirmationState.permitsExecution
            && date >= issuedAt
            && date <= expiresAt
            && taskID == proposedTaskID
            && cancelledEffect == proposedEffect
    }
}

public enum ActionCancellationAuthorizationDecision: Sendable, Equatable {
    case authorized(ActionCancellationAuthorizationEnvelope)
    case denied(ActionAuthorizationDenialReason)

    public var denialReason: ActionAuthorizationDenialReason? {
        guard case .denied(let reason) = self else { return nil }
        return reason
    }
}

/// Issues one short-lived authorization from host provenance plus a validated
/// proposal. The proposal never supplies its request ID, turn IDs, speaker,
/// session, concrete target, confirmation state, or expiration.
public enum ActionAuthorizationFactory {
    public static let trustedVoiceOrigin = "aurora_native_realtime_voice"
    public static let defaultLifetime: TimeInterval = 20
    public static let maximumLifetime: TimeInterval = 60
    public static let maximumIdentityCharacters = 256
    public static let maximumSourceTurns = 16
    public static let maximumResourceIdentifierCharacters = 2_048

    public static func issue(
        proposal: IntentProposal,
        requestID: String,
        sourceTurnIDs: [String],
        sessionID: String?,
        origin: String,
        participantIsOwner: Bool,
        turnFinalized: Bool,
        resolvedTarget: AuthorizedActionTarget,
        confirmationState: AuthorizationConfirmationState = .notRequired,
        now: Date = Date(),
        lifetime: TimeInterval = defaultLifetime,
        authorizationID: String = UUID().uuidString
    ) -> ActionAuthorizationDecision {
        guard isValidIdentity(requestID),
              isValidIdentity(authorizationID) else {
            return .denied(.requestUnavailable)
        }
        guard let sessionID, isValidIdentity(sessionID) else {
            return .denied(.sessionUnavailable)
        }
        guard sourceTurnIDs.count > 0,
              sourceTurnIDs.count <= maximumSourceTurns,
              Set(sourceTurnIDs).count == sourceTurnIDs.count,
              sourceTurnIDs.allSatisfy(isValidIdentity) else {
            return .denied(.sourceTurnUnavailable)
        }
        guard origin == trustedVoiceOrigin else {
            return .denied(.untrustedOrigin)
        }
        guard participantIsOwner else {
            return .denied(.speakerUnverified)
        }
        guard turnFinalized else {
            return .denied(.turnUnfinalized)
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

        guard lifetime.isFinite,
              lifetime > 0,
              lifetime <= maximumLifetime else {
            return .denied(.invalidExpiration)
        }
        guard targetMatchesProposal(
            resolvedTarget,
            targetReference: proposal.targetReference,
            operation: proposal.operation
        ) else {
            return .denied(.targetUnavailable)
        }

        let effect = AuthorizedActionEffect(
            operation: proposal.operation,
            target: resolvedTarget,
            parameters: proposal.parameters
        )
        let expiresAt = now.addingTimeInterval(lifetime)
        guard expiresAt > now else {
            return .denied(.invalidExpiration)
        }
        return .authorized(ActionAuthorizationEnvelope(
            authorizationID: authorizationID,
            requestID: requestID,
            sourceTurnIDs: sourceTurnIDs,
            sessionID: sessionID,
            speakerBinding: .configuredOwnerVoiceSession,
            operation: proposal.operation,
            allowedEffect: effect,
            confirmationState: confirmationState,
            issuedAt: now,
            expiresAt: expiresAt
        ))
    }

    public static func effect(
        for proposal: IntentProposal,
        resolvedTarget: AuthorizedActionTarget
    ) -> AuthorizedActionEffect? {
        guard targetMatchesProposal(
            resolvedTarget,
            targetReference: proposal.targetReference,
            operation: proposal.operation
        ) else { return nil }
        return AuthorizedActionEffect(
            operation: proposal.operation,
            target: resolvedTarget,
            parameters: proposal.parameters
        )
    }

    /// Issues authority to stop one already-authorized running task. The
    /// current cancel proposal must resolve structurally to that task's exact
    /// operation, target, and parameters; a generic or unrelated negation may
    /// not cancel whatever happens to be running.
    public static func issueCancellation(
        proposal: IntentProposal,
        requestID: String,
        sourceTurnIDs: [String],
        sessionID: String?,
        origin: String,
        participantIsOwner: Bool,
        turnFinalized: Bool,
        activeTaskID: String,
        activeAuthorization: ActionAuthorizationEnvelope,
        confirmationState: AuthorizationConfirmationState = .notRequired,
        now: Date = Date(),
        lifetime: TimeInterval = defaultLifetime,
        authorizationID: String = UUID().uuidString
    ) -> ActionCancellationAuthorizationDecision {
        guard proposal.commitment == .cancel else {
            return .denied(.effectMismatch)
        }
        guard isValidIdentity(requestID),
              isValidIdentity(authorizationID),
              isValidIdentity(activeTaskID) else {
            return .denied(.requestUnavailable)
        }
        guard let sessionID,
              isValidIdentity(sessionID),
              sessionID == activeAuthorization.sessionID else {
            return .denied(.sessionUnavailable)
        }
        guard sourceTurnIDs.count > 0,
              sourceTurnIDs.count <= maximumSourceTurns,
              Set(sourceTurnIDs).count == sourceTurnIDs.count,
              sourceTurnIDs.allSatisfy(isValidIdentity) else {
            return .denied(.sourceTurnUnavailable)
        }
        guard origin == trustedVoiceOrigin else {
            return .denied(.untrustedOrigin)
        }
        guard participantIsOwner else {
            return .denied(.speakerUnverified)
        }
        guard turnFinalized else {
            return .denied(.turnUnfinalized)
        }
        switch confirmationState {
        case .notRequired, .confirmed:
            break
        case .pending:
            return .denied(.confirmationRequired)
        case .denied:
            return .denied(.confirmationDenied)
        }
        guard lifetime.isFinite,
              lifetime > 0,
              lifetime <= maximumLifetime else {
            return .denied(.invalidExpiration)
        }
        guard let proposedEffect = effect(
            for: proposal,
            resolvedTarget: activeAuthorization.allowedEffect.target
        ), proposedEffect == activeAuthorization.allowedEffect else {
            return .denied(.effectMismatch)
        }
        let expiresAt = now.addingTimeInterval(lifetime)
        guard expiresAt > now else {
            return .denied(.invalidExpiration)
        }
        return .authorized(ActionCancellationAuthorizationEnvelope(
            authorizationID: authorizationID,
            requestID: requestID,
            sourceTurnIDs: sourceTurnIDs,
            sessionID: sessionID,
            speakerBinding: .configuredOwnerVoiceSession,
            taskID: activeTaskID,
            cancelledEffect: proposedEffect,
            confirmationState: confirmationState,
            issuedAt: now,
            expiresAt: expiresAt
        ))
    }

    static func isValidOpaqueIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.count <= maximumResourceIdentifierCharacters
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.count <= maximumIdentityCharacters
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func targetMatchesProposal(
        _ target: AuthorizedActionTarget,
        targetReference: IntentTargetReference,
        operation: IntentOperation
    ) -> Bool {
        switch (operation, targetReference, target) {
        case (.notesOpenApplication, .notesApplication, .notesApplication):
            return true
        case (.notesCreate, .newNote, .newNote):
            return true
        case (.notesSetTitle, .activeNote, .note(let identifier)),
             (.notesAddItems, .activeNote, .note(let identifier)),
             (.notesRemoveItems, .activeNote, .note(let identifier)),
             (.notesOpen, .activeNote, .note(let identifier)):
            return isValidOpaqueIdentifier(identifier)
        default:
            return false
        }
    }
}
