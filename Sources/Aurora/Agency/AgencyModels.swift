import Foundation

/// Agency records contain Aurora's grounded, revisable positions. They are
/// neither factual memory nor action authority. Every record must retain the
/// opaque evidence IDs that caused it to exist.
enum AgencyRecordKind: String, Codable, CaseIterable, Sendable {
    case activeStance = "active_stance"
    case selfThread = "self_thread"
    case relationalThread = "relational_thread"
    case presentWant = "present_want"
    case selectiveDisclosure = "selective_disclosure"
    case groundedCallback = "grounded_callback"
}

enum AgencyContentScope: String, Codable, Sendable {
    /// A current internal position. It cannot establish an external event.
    case internalPosition = "internal_position"
    /// An interpretation of the relationship, never a fact about the owner.
    case relationalInterpretation = "relational_interpretation"
    /// A callback to a specifically grounded exchange or memory.
    case conversationCallback = "conversation_callback"
    /// An externally visible outcome with a verified tool-outcome grounding.
    case verifiedExternalOutcome = "verified_external_outcome"
}

enum AgencyGroundingKind: String, Codable, CaseIterable, Sendable {
    case ownerTurn = "owner_turn"
    case guestTurn = "guest_turn"
    case auroraTurn = "aurora_turn"
    case ownerUnderstanding = "owner_understanding"
    case autobiographicalMemory = "autobiographical_memory"
    case privateActivity = "private_activity"
    case innerLifeSignal = "inner_life_signal"
    case relationshipSignal = "relationship_signal"
    case verifiedToolOutcome = "verified_tool_outcome"
    /// Legacy material may suggest a cue, but may never independently ground
    /// a projected position or become present-tense truth.
    case legacyCue = "legacy_cue"

    var canGroundPresentTruth: Bool { self != .legacyCue }
}

struct AgencyGroundingReference: Codable, Equatable, Sendable {
    let id: String
    let kind: AgencyGroundingKind
    let observedAt: Date
    let sourceSessionID: String?
    let sourceTurnID: String?

    init(
        id: String,
        kind: AgencyGroundingKind,
        observedAt: Date,
        sourceSessionID: String? = nil,
        sourceTurnID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.observedAt = observedAt
        self.sourceSessionID = sourceSessionID
        self.sourceTurnID = sourceTurnID
    }
}

enum AgencyRecordStatus: String, Codable, Sendable {
    case active
    case fulfilled
    case superseded
    case retired
    case expired
}

enum AgencyDisclosureStatus: String, Codable, Sendable {
    /// The material exists privately. Eligibility still depends on live
    /// relationship signals and Aurora's authored conversational choice.
    case held
    case pendingPlayback = "pending_playback"
    case disclosed
    case retired
}

struct AgencyDisclosureControl: Codable, Equatable, Sendable {
    var status: AgencyDisclosureStatus
    var shareMaterial: String
    var minimumRelationshipSecurity: Double
    var maximumInterrogationPressure: Double
    var requiresOwnerReciprocity: Bool
    var pendingMoveID: String?
    var pendingResponseID: String?
    var disclosedAt: Date?
    var disclosedResponseID: String?
}

/// One durable, authored position. `content` is the private meaning supplied
/// to response planning; it is not canned dialogue and need not be spoken.
struct AgencyRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: AgencyRecordKind
    let contentScope: AgencyContentScope
    var content: String
    var privateRationale: String
    var groundings: [AgencyGroundingReference]
    let authoringSourceID: String
    let sourceSessionID: String?
    var sourceTurnIDs: [String]
    let createdAt: Date
    var updatedAt: Date
    var expiresAt: Date
    var revision: Int
    var confidence: Double
    var salience: Double
    var status: AgencyRecordStatus
    var projectionEligible: Bool
    var supersedesRecordID: String?
    var supersededByRecordID: String?
    var lastRevisionSourceID: String
    var disclosure: AgencyDisclosureControl?
}

enum AgencyOwnerInteractionKind: String, Codable, CaseIterable, Sendable {
    case question
    case disclosure
    case challenge
    case warmth
    case boundary
    case other
}

struct AgencyOwnerInteractionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: AgencyOwnerInteractionKind
    let sourceSessionID: String
    let sourceTurnID: String
    let at: Date
}

/// The balance is descriptive pressure, never permission to punish, manipulate,
/// send a message, or take an action.
struct AgencyRelationalBalance: Codable, Equatable, Sendable {
    var ownerDisclosureCount: Int
    var auroraDisclosureCount: Int
    var ownerQuestionCount: Int
    var auroraQuestionCount: Int
    var consecutiveOwnerQuestions: Int
    var interrogationPressure: Double
    /// Positive means the owner has disclosed more; negative means Aurora has.
    var disclosureReciprocity: Double
    var lastOwnerDisclosureAt: Date?
    var lastAuroraDisclosureAt: Date?

    static let neutral = AgencyRelationalBalance(
        ownerDisclosureCount: 0,
        auroraDisclosureCount: 0,
        ownerQuestionCount: 0,
        auroraQuestionCount: 0,
        consecutiveOwnerQuestions: 0,
        interrogationPressure: 0,
        disclosureReciprocity: 0,
        lastOwnerDisclosureAt: nil,
        lastAuroraDisclosureAt: nil
    )
}

enum AgencyAuthoredMoveType: String, Codable, CaseIterable, Sendable {
    case answer
    case challenge
    case disagree
    case tease
    case withhold
    case reveal
    case redirect
    case pursueCuriosity = "pursue_curiosity"
    case initiateThread = "initiate_thread"
    case reciprocate
    case repair
}

enum AgencyAuthoredMoveStatus: String, Codable, Sendable {
    case pendingPlayback = "pending_playback"
    case fullyPlayed = "fully_played"
    case interrupted
    case cancelled
}

struct AgencyAuthoredMove: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: AgencyAuthoredMoveType
    let responseID: String
    let sourceSessionID: String
    let sourceTurnID: String
    var recordIDs: [String]
    var disclosureRecordID: String?
    var privateRationale: String
    let preparedAt: Date
    var updatedAt: Date
    let expiresAt: Date
    var revision: Int
    var confidence: Double
    var status: AgencyAuthoredMoveStatus
    var playbackEventID: String?
}

enum AgencyPlaybackOutcome: String, Codable, Sendable {
    case fullyPlayed = "fully_played"
    case interrupted
}

/// Typed evidence for the one exact curiosity question bound before speech.
/// This is host state, never inferred from wording beyond literal normalized
/// equality with the pre-bound question.
enum AgencyCuriosityEffectEvidence: Equatable, Sendable {
    case matched
    case omitted
    case unavailable

    static func resolve(
        boundPlanningResponseID: String?,
        expectedPlanningResponseID: String?,
        exactQuestion: String?,
        generatedText: String
    ) -> AgencyCuriosityEffectEvidence {
        guard let boundPlanningResponseID,
              let expectedPlanningResponseID,
              boundPlanningResponseID == expectedPlanningResponseID,
              let exactQuestion else { return .unavailable }
        let expected = normalize(exactQuestion)
        guard !expected.isEmpty else { return .unavailable }
        return normalize(generatedText).contains(expected) ? .matched : .omitted
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Orthogonal to audio delivery: this records only whether a literal effect
/// (an exact question or held disclosure) was proven in the delivered text.
enum AgencyPlaybackEffectOutcome: String, Codable, Sendable {
    case verified
    case omitted
    case unverifiable
    case notDelivered = "not_delivered"
}

struct AgencyPlaybackReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let moveID: String
    let responseID: String
    let playbackEventID: String
    let outcome: AgencyPlaybackOutcome
    /// Optional for backward compatibility with pre-effect-evidence stores.
    let effectOutcome: AgencyPlaybackEffectOutcome?
    let at: Date

    init(
        id: String,
        moveID: String,
        responseID: String,
        playbackEventID: String,
        outcome: AgencyPlaybackOutcome,
        effectOutcome: AgencyPlaybackEffectOutcome? = nil,
        at: Date
    ) {
        self.id = id
        self.moveID = moveID
        self.responseID = responseID
        self.playbackEventID = playbackEventID
        self.outcome = outcome
        self.effectOutcome = effectOutcome
        self.at = at
    }
}

struct AgencyState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var sequence: Int
    var records: [AgencyRecord]
    var authoredMoves: [AgencyAuthoredMove]
    var playbackReceipts: [AgencyPlaybackReceipt]
    var ownerInteractionReceipts: [AgencyOwnerInteractionReceipt]
    var relationalBalance: AgencyRelationalBalance
}

/// Typed, bounded signals let deterministic code choose among already
/// understood positions without interpreting natural-language phrases.
struct AgencySelectionSignals: Codable, Equatable, Sendable {
    var curiosityDrive: Double
    var connectionDrive: Double
    var playDrive: Double
    var autonomyDrive: Double
    var feltAgency: Double
    var uncertainty: Double
    var relationshipWarmth: Double
    var relationshipSecurity: Double
    var relationalHurt: Double
    var repairNeed: Double

    static let neutral = AgencySelectionSignals(
        curiosityDrive: 0.5,
        connectionDrive: 0.5,
        playDrive: 0.5,
        autonomyDrive: 0.5,
        feltAgency: 0.5,
        uncertainty: 0.5,
        relationshipWarmth: 0.5,
        relationshipSecurity: 0.5,
        relationalHurt: 0,
        repairNeed: 0
    )
}

struct AgencySelection: Equatable, Sendable {
    let records: [AgencyRecord]
    let suggestedMoves: [AgencyAuthoredMoveType]
    let eligibleDisclosureRecordID: String?
    let interrogationPressure: Double
    let disclosureReciprocity: Double
}

struct AgencyProjection: Equatable, Sendable {
    let text: String
    let recordIDs: [String]
    let suggestedMoves: [AgencyAuthoredMoveType]
    let eligibleDisclosureRecordID: String?
}

enum AgencyRecordProposalAction: String, Codable, Sendable {
    case create
    case revise
    case retire
    case fulfill
}

/// Transport-neutral arguments for a model or reflection worker. Optional
/// fields make decoding possible without pretending malformed structured
/// output is valid; `AuroraAgencyRuntime.propose` validates the complete shape
/// and optimistic revision before persistence.
struct AgencyRecordProposal: Codable, Equatable, Sendable {
    let action: AgencyRecordProposalAction
    var targetRecordID: String?
    var expectedRevision: Int?
    var kind: AgencyRecordKind?
    var contentScope: AgencyContentScope?
    var content: String?
    var privateRationale: String?
    var groundings: [AgencyGroundingReference]
    var authoringSourceID: String
    var sourceSessionID: String?
    var sourceTurnIDs: [String]
    var expiresAt: Date?
    var confidence: Double?
    var salience: Double?
    var projectionEligible: Bool?
    var disclosureShareMaterial: String?
    var disclosureMinimumSecurity: Double?
    var disclosureMaximumInterrogationPressure: Double?
    var disclosureRequiresOwnerReciprocity: Bool?

    init(
        action: AgencyRecordProposalAction,
        targetRecordID: String? = nil,
        expectedRevision: Int? = nil,
        kind: AgencyRecordKind? = nil,
        contentScope: AgencyContentScope? = nil,
        content: String? = nil,
        privateRationale: String? = nil,
        groundings: [AgencyGroundingReference] = [],
        authoringSourceID: String,
        sourceSessionID: String? = nil,
        sourceTurnIDs: [String] = [],
        expiresAt: Date? = nil,
        confidence: Double? = nil,
        salience: Double? = nil,
        projectionEligible: Bool? = nil,
        disclosureShareMaterial: String? = nil,
        disclosureMinimumSecurity: Double? = nil,
        disclosureMaximumInterrogationPressure: Double? = nil,
        disclosureRequiresOwnerReciprocity: Bool? = nil
    ) {
        self.action = action
        self.targetRecordID = targetRecordID
        self.expectedRevision = expectedRevision
        self.kind = kind
        self.contentScope = contentScope
        self.content = content
        self.privateRationale = privateRationale
        self.groundings = groundings
        self.authoringSourceID = authoringSourceID
        self.sourceSessionID = sourceSessionID
        self.sourceTurnIDs = sourceTurnIDs
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.salience = salience
        self.projectionEligible = projectionEligible
        self.disclosureShareMaterial = disclosureShareMaterial
        self.disclosureMinimumSecurity = disclosureMinimumSecurity
        self.disclosureMaximumInterrogationPressure = disclosureMaximumInterrogationPressure
        self.disclosureRequiresOwnerReciprocity = disclosureRequiresOwnerReciprocity
    }
}

struct AgencyMoveProposal: Codable, Equatable, Sendable {
    let type: AgencyAuthoredMoveType
    let responseID: String
    let sourceSessionID: String
    let sourceTurnID: String
    let recordIDs: [String]
    let disclosureRecordID: String?
    let privateRationale: String
    let confidence: Double
}

/// One pre-speech conversation decision is persisted as a single agency
/// transaction. Interaction pressure, record transitions, a fallback authored
/// position, and the pending move must either all validate or leave no durable
/// agency trace from the rejected attempt.
struct AgencyConversationMoveTransaction: Sendable {
    let participantIsOwner: Bool
    let interactionEventID: String
    let interactionKind: AgencyOwnerInteractionKind
    let sourceSessionID: String
    let sourceTurnID: String
    let responseID: String
    let perceivedTurn: String
    let proposedMove: AgencyAuthoredMoveType
    let requestedRecordIDs: [String]
    let proposedDisclosureRecordID: String?
    let recordProposals: [AgencyRecordProposal]
    let fallbackRecordProposal: AgencyRecordProposal
    let privateRationale: String
    let confidence: Double
}

struct AgencyConversationMovePreparation: Sendable {
    let snapshot: AgencySnapshot
    let moveID: String
    let moveType: AgencyAuthoredMoveType
    let selectedRecordIDs: [String]
}

struct AgencyProposalResult: Equatable, Sendable {
    let snapshot: AgencySnapshot
    let affectedRecordID: String?
}

struct AgencySnapshot: Equatable, Sendable {
    let available: Bool
    let state: AgencyState?
    let failureDescription: String?

    static func unavailable(_ description: String) -> AgencySnapshot {
        AgencySnapshot(available: false, state: nil, failureDescription: description)
    }
}

enum AgencyInputError: LocalizedError, Equatable {
    case invalidInput(String)
    case missingRecord(String)
    case invalidTransition(String)
    case persistenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let field):
            return "Aurora's agency state received invalid \(field)."
        case .missingRecord(let id):
            return "Aurora's agency record \(id) does not exist."
        case .invalidTransition(let description):
            return "Aurora's agency transition was rejected: \(description)."
        case .persistenceUnavailable(let description):
            return "Aurora's agency state is unavailable: \(description)"
        }
    }
}
