import Foundation

/// Broad areas are used only to balance attention over time. They contain no
/// canned questions and never interpret an owner's words deterministically.
enum OwnerUnderstandingDomain: String, Codable, CaseIterable, Sendable {
    case presentLife = "present_life"
    case tastes
    case personalHistory = "personal_history"
    case relationships
    case workAndCraft = "work_and_craft"
    case values
    case hopes
    case worries
    case humor
    case innerWorld = "inner_world"
    case identity
    case other
}

enum OwnerDirectStatementStatus: String, Codable, Sendable {
    case active
    case revised
    case retracted
}

/// Something the verified owner directly said. `exactQuote` is deliberately
/// kept alongside the compact meaning so an interpretation can never quietly
/// replace the original evidence.
struct OwnerDirectStatement: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let domain: OwnerUnderstandingDomain
    let subject: String
    let meaning: String
    let exactQuote: String
    let sourceSessionID: String
    let sourceTurnID: String
    let createdAt: Date
    var updatedAt: Date
    var importance: Double
    var status: OwnerDirectStatementStatus
    var supersedesStatementID: String?
    var supersededByStatementID: String?
    var revisionSourceSessionID: String?
    var revisionSourceTurnID: String?
    var revisionExactQuote: String?
}

enum OwnerTentativeInferenceStatus: String, Codable, Sendable {
    case active
    case revised
    case rejected
    case confirmed
}

/// A hypothesis about the owner is never promoted into direct knowledge merely
/// because a model produced it. Evidence IDs and confidence stay explicit.
struct OwnerTentativeInference: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let domain: OwnerUnderstandingDomain
    let inference: String
    let evidenceStatementIDs: [String]
    let sourceSessionID: String
    let sourceTurnIDs: [String]
    let createdAt: Date
    var updatedAt: Date
    var confidence: Double
    var status: OwnerTentativeInferenceStatus
    var supersedesInferenceID: String?
    var supersededByInferenceID: String?
    var resolutionSourceSessionID: String?
    var resolutionSourceTurnID: String?
    var resolutionExactQuote: String?
}

enum OwnerCuriosityStatus: String, Codable, CaseIterable, Sendable {
    case open
    case pendingAsk = "pending_ask"
    case asked
    case answered
    case deferred
    case declined
    case retired
}

/// A curiosity is model-authored, grounded, and individually lifecycle-bound.
/// It is not a questionnaire entry or a phrase-triggered rule.
struct OwnerCuriosity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let domain: OwnerUnderstandingDomain
    var question: String
    var reason: String
    var basedOnStatementIDs: [String]
    var originSourceIDs: [String]
    let createdAt: Date
    var updatedAt: Date
    var interest: Double
    var status: OwnerCuriosityStatus
    var askCount: Int
    var pendingResponseID: String?
    var pendingSourceSessionID: String?
    var pendingSourceTurnID: String?
    var lastAskedResponseID: String?
    var lastAskedAt: Date?
    var answerStatementIDs: [String]
    var deferUntil: Date?
    var resolutionSourceSessionID: String?
    var resolutionSourceTurnID: String?
    var resolutionExactQuote: String?
}

enum OwnerCuriosityPlaybackOutcome: String, Codable, Sendable {
    case fullyPlayed = "fully_played"
    case interrupted
}

/// A durable receipt prevents context presentation or response creation from
/// being confused with a question the owner actually heard.
struct OwnerCuriosityPlaybackReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let curiosityID: String
    let responseID: String
    let playbackEventID: String
    let outcome: OwnerCuriosityPlaybackOutcome
    let at: Date
}

/// Host-owned causal bridge between the function-call response that reserved a
/// curiosity and the later tools-disabled response whose audio can actually be
/// heard. Keys are committed owner input items, never transcript phrases.
struct OwnerCuriosityPlaybackBinding: Equatable, Sendable {
    let planningResponseID: String
    let exactQuestion: String
}

struct OwnerCuriosityPlaybackBindings: Equatable, Sendable {

    private var bindingByInputItem: [String: OwnerCuriosityPlaybackBinding] = [:]

    var isEmpty: Bool { bindingByInputItem.isEmpty }

    @discardableResult
    mutating func bind(
        inputItemID: String,
        planningResponseID: String,
        exactQuestion: String
    ) -> String? {
        let boundedQuestion = exactQuestion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !boundedQuestion.isEmpty, boundedQuestion.count <= 320 else {
            return bindingByInputItem[inputItemID]?.planningResponseID
        }
        return bindingByInputItem.updateValue(
            OwnerCuriosityPlaybackBinding(
                planningResponseID: planningResponseID,
                exactQuestion: boundedQuestion
            ),
            forKey: inputItemID
        )?.planningResponseID
    }

    func exactQuestion(forAudibleInputItemID inputItemID: String?) -> String? {
        guard let inputItemID else { return nil }
        return bindingByInputItem[inputItemID]?.exactQuestion
    }

    mutating func consumeBinding(
        forAudibleInputItemID inputItemID: String?
    ) -> OwnerCuriosityPlaybackBinding? {
        guard let inputItemID else { return nil }
        return bindingByInputItem.removeValue(forKey: inputItemID)
    }

    mutating func consumePlanningResponseID(
        forAudibleInputItemID inputItemID: String?
    ) -> String? {
        consumeBinding(
            forAudibleInputItemID: inputItemID
        )?.planningResponseID
    }

    mutating func drain() -> [(inputItemID: String, planningResponseID: String)] {
        let pending = bindingByInputItem.map {
            (inputItemID: $0.key, planningResponseID: $0.value.planningResponseID)
        }
        bindingByInputItem.removeAll()
        return pending.sorted { $0.inputItemID < $1.inputItemID }
    }
}

struct OwnerLegacyContinuityEvidence: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let section: String?
    let content: String
    let sourcePath: String
    let sourceRevision: String
    let importedAt: Date
}

struct OwnerLegacyGapCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let section: String?
    let content: String
    let sourcePath: String
    let sourceRevision: String
    let importedAt: Date
    var retiredAt: Date?
}

struct OwnerLegacyImportReceipt: Codable, Equatable, Identifiable, Sendable {
    var id: String { sourcePath }
    let sourcePath: String
    let sourceRevision: String
    let importedAt: Date
    let checkedCount: Int
    let uncheckedCount: Int
}

struct OwnerLegacyChecklistSource: Equatable, Sendable {
    let path: String
    let revision: String
}

struct OwnerLegacyChecklistImport: Equatable, Sendable {
    let evidence: [OwnerLegacyContinuityEvidence]
    let gapCandidates: [OwnerLegacyGapCandidate]
    let receipt: OwnerLegacyImportReceipt
}

struct OwnerDomainCadence: Codable, Equatable, Sendable {
    var directStatementCount: Int = 0
    var tentativeInferenceCount: Int = 0
    var openCuriosityCount: Int = 0
    var questionAskedCount: Int = 0
    var questionAnsweredCount: Int = 0
    var questionDeclinedCount: Int = 0
    var lastLearnedAt: Date?
    var lastQuestionAskedAt: Date?
    var lastQuestionAnsweredAt: Date?
    var questionCooldownUntil: Date?
}

struct OwnerConversationCadence: Codable, Equatable, Sendable {
    var lastDirectStatementAt: Date?
    var lastQuestionAskedAt: Date?
    var lastQuestionAnsweredAt: Date?
    var lastQuestionDeclinedAt: Date?
    var consecutiveQuestionsAsked: Int = 0
    var questionCooldownUntil: Date?
}

enum OwnerQuestionCadenceDirection: String, Codable, Sendable {
    case inviteOneSpecificQuestion = "invite_one_specific_question"
    case reciprocateBeforeAnotherQuestion = "reciprocate_before_another_question"
    case stayWithCurrentThread = "stay_with_current_thread"
    case giveSpace = "give_space"
    case waitForPlayback = "wait_for_playback"

    var voiceInstruction: String {
        switch self {
        case .inviteOneSpecificQuestion:
            return "one specific, naturally earned question is welcome"
        case .reciprocateBeforeAnotherQuestion:
            return "share or react first; do not turn this into an interview"
        case .stayWithCurrentThread:
            return "stay with what the owner just gave you; do not repeat the question"
        case .giveSpace:
            return "give the owner space and let curiosity wait"
        case .waitForPlayback:
            return "a question is awaiting playback; do not ask another"
        }
    }
}

struct OwnerUnderstandingState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var sequence: Int
    var directStatements: [OwnerDirectStatement]
    var tentativeInferences: [OwnerTentativeInference]
    var curiosities: [OwnerCuriosity]
    var playbackReceipts: [OwnerCuriosityPlaybackReceipt]
    var legacyContinuityEvidence: [OwnerLegacyContinuityEvidence]
    var legacyGapCandidates: [OwnerLegacyGapCandidate]
    var legacyImportReceipts: [OwnerLegacyImportReceipt]
    var domainCadence: [OwnerUnderstandingDomain: OwnerDomainCadence]
    var conversationCadence: OwnerConversationCadence
}

enum OwnerUnderstandingUpdateAction: String, Codable, Sendable {
    case recordDirectStatement = "record_direct_statement"
    case reviseDirectStatement = "revise_direct_statement"
    case retractDirectStatement = "retract_direct_statement"
    case recordTentativeInference = "record_tentative_inference"
    case reviseTentativeInference = "revise_tentative_inference"
    case rejectTentativeInference = "reject_tentative_inference"
    case confirmTentativeInference = "confirm_tentative_inference"
    case openCuriosity = "open_curiosity"
    case prepareCuriosityAsk = "prepare_curiosity_ask"
    case answerCuriosity = "answer_curiosity"
    case deferCuriosity = "defer_curiosity"
    case declineCuriosity = "decline_curiosity"
    case retireCuriosity = "retire_curiosity"
}

/// Transport-neutral proposal used by Realtime function calls or other trusted
/// callers. Every field remains untrusted until the runtime validates it.
struct OwnerUnderstandingUpdate: Codable, Equatable, Sendable {
    let action: OwnerUnderstandingUpdateAction
    var domain: OwnerUnderstandingDomain?
    var subject: String?
    var content: String?
    var sourceQuote: String?
    var confidence: Double?
    var curiosityID: String?
    var question: String?
    var reason: String?
    var targetID: String?
    var evidenceStatementIDs: [String]?
    var originSourceIDs: [String]?
    var resolvesWithStatementIDs: [String]?
    var deferUntil: Date?
    var importance: Double?
    /// True only when this exact model-authored question was audibly included
    /// in the same Realtime response. The host still verifies response
    /// provenance and completed playback before it counts as asked.
    var spokenInThisResponse: Bool?

    init(
        action: OwnerUnderstandingUpdateAction,
        domain: OwnerUnderstandingDomain? = nil,
        subject: String? = nil,
        content: String? = nil,
        sourceQuote: String? = nil,
        confidence: Double? = nil,
        curiosityID: String? = nil,
        question: String? = nil,
        reason: String? = nil,
        targetID: String? = nil,
        evidenceStatementIDs: [String]? = nil,
        originSourceIDs: [String]? = nil,
        resolvesWithStatementIDs: [String]? = nil,
        deferUntil: Date? = nil,
        importance: Double? = nil,
        spokenInThisResponse: Bool? = nil
    ) {
        self.action = action
        self.domain = domain
        self.subject = subject
        self.content = content
        self.sourceQuote = sourceQuote
        self.confidence = confidence
        self.curiosityID = curiosityID
        self.question = question
        self.reason = reason
        self.targetID = targetID
        self.evidenceStatementIDs = evidenceStatementIDs
        self.originSourceIDs = originSourceIDs
        self.resolvesWithStatementIDs = resolvesWithStatementIDs
        self.deferUntil = deferUntil
        self.importance = importance
        self.spokenInThisResponse = spokenInThisResponse
    }
}

struct OwnerUnderstandingProjection: Equatable, Sendable {
    let text: String
    let directStatementIDs: [String]
    let tentativeInferenceID: String?
    let curiosityID: String?
    let cadenceDirection: OwnerQuestionCadenceDirection
}

struct OwnerUnderstandingApplyResult: Equatable, Sendable {
    let snapshot: OwnerUnderstandingSnapshot
    let affectedID: String?
}

struct OwnerUnderstandingSnapshot: Equatable, Sendable {
    let available: Bool
    let state: OwnerUnderstandingState?
    let failureDescription: String?

    static func unavailable(_ description: String) -> OwnerUnderstandingSnapshot {
        OwnerUnderstandingSnapshot(available: false, state: nil, failureDescription: description)
    }
}

enum OwnerUnderstandingInputError: LocalizedError, Equatable {
    case invalidInput(String)
    case missingStatement(String)
    case missingInference(String)
    case missingCuriosity(String)
    case invalidTransition(String)
    case persistenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let field):
            return "Owner understanding received invalid \(field)."
        case .missingStatement(let id):
            return "Owner statement \(id) does not exist."
        case .missingInference(let id):
            return "Owner inference \(id) does not exist."
        case .missingCuriosity(let id):
            return "Owner curiosity \(id) does not exist."
        case .invalidTransition(let description):
            return "Owner curiosity transition was rejected: \(description)."
        case .persistenceUnavailable(let description):
            return "Owner understanding is unavailable: \(description)"
        }
    }
}
