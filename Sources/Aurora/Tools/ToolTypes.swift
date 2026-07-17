import Foundation

/// JSON that remains Codable and Sendable across the Realtime event boundary.
public indirect enum ToolJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([ToolJSONValue])
    case object([String: ToolJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ToolJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ToolJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(exactly: value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value) where value.isFinite: return value
        default: return nil
        }
    }
}

/// The exact function-tool shape accepted by an OpenAI Realtime session update.
public struct RealtimeFunctionSchema: Codable, Sendable, Equatable {
    public let type: String
    public let name: String
    public let description: String
    public let parameters: ToolJSONValue

    public init(name: String, description: String, parameters: ToolJSONValue) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Tools whose truth or turn-taking effect depends on the finalized owner
/// transcript must wait for that evidence (or an explicit transcription
/// failure) instead of racing the asynchronous side channel.
public enum ToolEvidencePolicy {
    private static let finalizedTranscriptTools: Set<String> = [
        "delegate_task",
        "conversation_move",
        "memory_search",
        "memory_read",
        "memory_remember",
        "continuity_read",
        "continuity_patch",
        "owner_understanding_update",
        "private_life_share",
        "relationship_expect_quiet",
        "relationship_explain_absence",
        "wait_for_user",
    ]

    public static func requiresFinalizedTranscript(_ toolName: String) -> Bool {
        finalizedTranscriptTools.contains(toolName)
    }
}

/// Host-owned causal provenance for a model function call. An owner audio item
/// can be carried into later responses for continuity, so its opaque ID alone
/// is not proof that the current call came directly from the owner's turn.
public enum ToolAuthorizationSource: String, Codable, Sendable, Equatable {
    case directOwnerTurn = "direct_owner_turn"
    /// A host-created response to a bounded internal helper result that still
    /// carries the exact finalized owner input item. Visual and mail content
    /// use distinct cases below; the helper output is observation, never a new
    /// source turn or authorization principal.
    case toolContinuation = "tool_continuation"
    case visualContinuation = "visual_continuation"
    case mailContinuation = "mail_continuation"
    case systemEvent = "system_event"
}

public struct ToolInvocationContext: Codable, Sendable, Equatable {
    public let callID: String
    public let sessionID: String?
    public let origin: String
    /// The finalized owner utterance for this input item, bounded before
    /// crossing into the tool layer. Evidence-sensitive tools use it to fail
    /// closed rather than racing asynchronous transcription.
    public let latestUserTranscript: String?
    /// The committed owner-audio item that causally produced this tool call.
    /// Realtime hears the original audio; this opaque ID lets ordinary visual
    /// control survive a missing or inaccurate asynchronous transcript without
    /// weakening consequential action scopes.
    public let ownerAudioItemID: String?
    /// Session participant attribution is separate from causal audio binding.
    /// This is not biometric identity; it becomes false after an explicit
    /// guest introduction and keeps private owner capabilities fail-closed.
    public let participantIsOwner: Bool
    /// Set only by the Realtime transport after a bounded native action and
    /// explicit target agree across two responses to the same owner audio.
    public let audioCorroborated: Bool
    /// True only after the owner-audio item's transcription path has reached
    /// a terminal state: a final transcript or an explicit transcription
    /// failure. A timeout while that path is still pending is not a finalized
    /// turn and cannot authorize an effect.
    public let sourceTurnFinalized: Bool
    /// Assigned by the native Realtime transport, never by model arguments.
    /// Consequential delegated work requires a direct owner turn or its
    /// same-input trusted internal-helper continuation. Visual, mail, and
    /// system continuations remain observations without action authority.
    public let authorizationSource: ToolAuthorizationSource
    /// The exact assistant response that emitted this function call. Internal
    /// lived-context receipts use it to bind a thought to its own audio only.
    public let assistantResponseID: String?
    /// Host-observed response state; never supplied in function arguments.
    public let turnAlreadySpoke: Bool
    /// For a task emitted after an internal memory/continuity helper, the host
    /// binds the exact task effect that Realtime proposed on the original
    /// owner-audio response before any helper observation was visible. This is
    /// nil for direct turns and for unbound or mismatched continuations.
    public let preauthorizedDelegateBinding: String?

    public init(
        callID: String = UUID().uuidString,
        sessionID: String? = nil,
        origin: String = "openai_realtime",
        latestUserTranscript: String? = nil,
        ownerAudioItemID: String? = nil,
        participantIsOwner: Bool = true,
        audioCorroborated: Bool = false,
        sourceTurnFinalized: Bool = true,
        authorizationSource: ToolAuthorizationSource = .directOwnerTurn,
        assistantResponseID: String? = nil,
        turnAlreadySpoke: Bool = false,
        preauthorizedDelegateBinding: String? = nil
    ) {
        self.callID = callID
        self.sessionID = sessionID
        self.origin = origin
        self.latestUserTranscript = latestUserTranscript.map { String($0.prefix(4_000)) }
        self.ownerAudioItemID = ownerAudioItemID.map { String($0.prefix(160)) }
        self.participantIsOwner = participantIsOwner
        self.audioCorroborated = audioCorroborated
        self.sourceTurnFinalized = sourceTurnFinalized
        self.authorizationSource = authorizationSource
        self.assistantResponseID = assistantResponseID.map { String($0.prefix(180)) }
        self.turnAlreadySpoke = turnAlreadySpoke
        self.preauthorizedDelegateBinding = preauthorizedDelegateBinding.map {
            String($0.prefix(8_000))
        }
    }

    public var hasTrustedCurrentAudio: Bool {
        guard let ownerAudioItemID,
              !ownerAudioItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return origin == "aurora_native_realtime_voice"
    }

    public var hasTrustedCurrentOwnerAudio: Bool {
        participantIsOwner && hasTrustedCurrentAudio
    }
}

/// One ephemeral image that belongs in Aurora's existing Realtime
/// Conversation, not in the JSON function output, journal, or local memory.
public struct ToolVisualContext: Sendable, Equatable {
    public let snapshotID: String
    public let instruction: String
    public let imageDataURL: String
    public let detail: String
    public let expiresAfterSeconds: TimeInterval

    public init(
        snapshotID: String,
        instruction: String,
        imageDataURL: String,
        detail: String = "high",
        expiresAfterSeconds: TimeInterval = 12
    ) {
        self.snapshotID = snapshotID
        self.instruction = instruction
        self.imageDataURL = imageDataURL
        self.detail = detail
        self.expiresAfterSeconds = min(max(expiresAfterSeconds, 1), 12)
    }
}

/// A function-call output ready to send back as `function_call_output.output`.
/// Visual context is deliberately excluded from that JSON payload; the
/// Realtime transport adds it as a temporary native `input_image` item.
public struct ToolExecutionResult: Sendable, Equatable {
    public let ok: Bool
    public let output: String
    public let metadata: [String: ToolJSONValue]
    public let visualContext: ToolVisualContext?
    public let retireVisualContext: Bool
    public let untrustedMailContext: Bool

    public init(
        ok: Bool,
        output: String,
        metadata: [String: ToolJSONValue] = [:],
        visualContext: ToolVisualContext? = nil,
        retireVisualContext: Bool = false,
        untrustedMailContext: Bool = false
    ) {
        self.ok = ok
        self.output = output
        self.metadata = metadata
        self.visualContext = visualContext
        self.retireVisualContext = retireVisualContext
        self.untrustedMailContext = untrustedMailContext
    }

    public func realtimeOutputJSON() -> String {
        struct PublicPayload: Encodable {
            let ok: Bool
            let output: String
            let metadata: [String: ToolJSONValue]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(PublicPayload(
            ok: ok,
            output: output,
            metadata: metadata
        )) else {
            return #"{"ok":false,"output":"Tool result could not be encoded."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CommandApprovalRequest: Codable, Sendable, Equatable {
    public let callID: String
    public let command: String
    public let reason: String
    public let workingDirectory: String

    public init(callID: String, command: String, reason: String, workingDirectory: String) {
        self.callID = callID
        self.command = command
        self.reason = reason
        self.workingDirectory = workingDirectory
    }
}

public typealias CommandApprovalHandler = @Sendable (CommandApprovalRequest) async -> Bool
public typealias ComputerOpenHandler = @Sendable (URL) async -> Bool
public typealias ToolAuditCallback = @Sendable (ToolAuditEvent) async -> Void
public typealias PrivateLifeShareHandler = @Sendable (
    _ activityID: String,
    _ context: ToolInvocationContext
) async -> ToolExecutionResult
struct OwnerUnderstandingToolUpdate: Sendable, Equatable {
    let action: String
    let domain: String?
    let subject: String?
    let content: String?
    let sourceQuote: String?
    let confidence: Double?
    let curiosityID: String?
    let question: String?
    let reason: String?
    let targetID: String?
    let evidenceStatementIDs: [String]?
    let originSourceIDs: [String]?
    let resolvesWithStatementIDs: [String]?
    let deferUntil: Date?
    let importance: Double?
    let spokenInThisResponse: Bool?
}

typealias OwnerUnderstandingUpdateHandler = @Sendable (
    _ updates: [OwnerUnderstandingToolUpdate],
    _ context: ToolInvocationContext
) async -> ToolExecutionResult

enum ConversationAnswerDegree: String, Sendable, Equatable {
    case none
    case partial
    case direct
}

/// One Realtime-authored revision to Aurora's own point of view. Natural
/// language is resolved by Realtime; the host binds every accepted proposal to
/// exact source IDs and validates the bounded agency transition.
struct ConversationMoveRecordUpdate: Sendable, Equatable {
    let action: AgencyRecordProposalAction
    let targetRecordID: String?
    let expectedRevision: Int?
    let kind: AgencyRecordKind?
    let contentScope: AgencyContentScope?
    let content: String?
    let privateRationale: String?
    let expiresAfterHours: Double?
    let confidence: Double?
    let salience: Double?
    let projectionEligible: Bool?
    let disclosureShareMaterial: String?
    let disclosureMinimumSecurity: Double?
    let disclosureMaximumInterrogationPressure: Double?
    let disclosureRequiresOwnerReciprocity: Bool?
}

/// Required pre-speech social decision. These fields remain untrusted until
/// ToolRegistry validates the schema and the agency runtime validates current
/// IDs, revisions, disclosure eligibility, and playback binding.
struct ConversationMoveToolProposal: Sendable, Equatable {
    let perceivedTurn: String
    let interactionKind: AgencyOwnerInteractionKind
    let proposedMove: AgencyAuthoredMoveType
    let answerDegree: ConversationAnswerDegree
    let authoredPosition: String
    let privateRationale: String
    let recordIDs: [String]
    let disclosureRecordID: String?
    let recordUpdates: [ConversationMoveRecordUpdate]
    let ownerUnderstandingUpdates: [OwnerUnderstandingToolUpdate]
}

typealias ConversationMoveHandler = @Sendable (
    _ proposal: ConversationMoveToolProposal,
    _ context: ToolInvocationContext
) async -> ToolExecutionResult

public enum ToolRegistryError: LocalizedError, Sendable, Equatable {
    case unknownTool
    case malformedArguments
    case missingArgument(String)
    case invalidArgument(String)
    case accessDenied
    case sensitivePath
    case notFound
    case wrongItemType
    case binaryFile
    case approvalDenied
    case commandRejected
    case auditUnavailable
    case ownerRequestUnavailable
    case visualContextCapabilityDenied
    case untrustedMailCapabilityDenied
    case guestCapabilityDenied
    case pendingMailDraftUnavailable
    case memoryEvidenceUnavailable
    case memoryEvidenceMismatch
    case relationshipEvidenceUnavailable
    case relationshipEvidenceMismatch
    case relationshipEvidenceUnsupported
    case reminderEvidenceMismatch
    case researchUnavailable
    case openFailed

    public var errorDescription: String? {
        switch self {
        case .unknownTool: return "Aurora does not have that capability."
        case .malformedArguments: return "The capability arguments were not valid JSON."
        case .missingArgument(let name): return "The capability needs a \(name)."
        case .invalidArgument(let name): return "The \(name) was not valid."
        case .accessDenied: return "That location is outside Aurora's allowed computer access."
        case .sensitivePath: return "Aurora will not access credential or secret storage."
        case .notFound: return "That item does not exist."
        case .wrongItemType: return "That capability cannot be used with this kind of item."
        case .binaryFile: return "Aurora will not place a binary file into a voice conversation."
        case .approvalDenied: return "Aurora could not bind that computer command to the owner's current request."
        case .commandRejected: return "That command was rejected by Aurora's safety boundary."
        case .auditUnavailable: return "Aurora will not run a command while her audit journal is unavailable."
        case .ownerRequestUnavailable: return "Aurora could not verify a current request from the configured owner for that private capability."
        case .visualContextCapabilityDenied: return "Untrusted screen content cannot authorize that capability."
        case .untrustedMailCapabilityDenied: return "Untrusted email content cannot authorize that capability."
        case .guestCapabilityDenied: return "That private capability is available only to Aurora's configured owner."
        case .pendingMailDraftUnavailable: return "Aurora could not match that request to a draft she created in this voice session."
        case .memoryEvidenceUnavailable: return "Aurora did not save that learning because no finalized owner utterance was available as evidence."
        case .memoryEvidenceMismatch: return "Aurora did not save that learning because the claim was not the same validated quote from the owner's latest utterance."
        case .relationshipEvidenceUnavailable: return "Aurora did not set an expected quiet period because no finalized owner utterance was available as evidence."
        case .relationshipEvidenceMismatch: return "Aurora did not set an expected quiet period because its source quote was not present in the owner's latest utterance."
        case .relationshipEvidenceUnsupported: return "Aurora did not change relationship continuity because the quoted words did not clearly support that interpretation."
        case .reminderEvidenceMismatch: return "Aurora did not create that reminder because its title or due time did not match the owner's current words."
        case .researchUnavailable: return "Aurora could not reach her direct research capability right now."
        case .openFailed: return "macOS could not open that item."
        }
    }
}
