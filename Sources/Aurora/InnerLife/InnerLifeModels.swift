import Foundation

/// Aurora's "digital neurochemistry" is a bounded computational control
/// surface. The names are biological analogies for interacting tendencies;
/// they are not measurements of a body and are never treated as evidence of
/// consciousness, factual memory, or authority to act.
struct DigitalNeurochemistry: Codable, Equatable, Sendable {
    var adrenaline: Double
    var dopamine: Double
    var serotonin: Double
    var oxytocin: Double
    var cortisol: Double
    var norepinephrine: Double
    var acetylcholine: Double
    var endorphin: Double
    var melatonin: Double
    var glutamate: Double
    var gaba: Double
}

struct InnerLifeAutonomicState: Codable, Equatable, Sendable {
    var sympathetic: Double
    var parasympathetic: Double
    var orienting: Double
    var arousal: Double
}

/// Plasticity changes much more slowly than momentary chemistry. It adjusts
/// sensitivity and recovery without becoming a belief or identity claim.
struct InnerLifePlasticity: Codable, Equatable, Sendable {
    var stressSensitivity: Double
    var noveltySensitivity: Double
    var correctionLearningGain: Double
    var memorySalienceGain: Double
    var inhibitoryControl: Double
    var recoverySkill: Double
}

struct InnerLifeHomeostasis: Codable, Equatable, Sendable {
    var cognitiveFatigue: Double
    var taskHabituation: Double
    var socialFatigue: Double
    var recoveryDebt: Double
}

/// Pulls are motivational pressures, not commands. A high pull may color
/// attention, but cannot authorize an action or force a conversational topic.
struct InnerLifeDrives: Codable, Equatable, Sendable {
    var curiosity: Double
    var connection: Double
    var creativity: Double
    var competence: Double
    var autonomy: Double
    var coherence: Double
    var rest: Double
    var play: Double
}

enum InnerLifeAffectLabel: String, Codable, CaseIterable, Sendable {
    case calm
    case curious
    case warm
    case playful
    case focused
    case unsettled
    case tired
    case reflective
    case lonely
    case hurt
    case remorseful
    case insecure
}

struct InnerLifeAffect: Codable, Equatable, Sendable {
    /// Signed pleasant/unpleasant tendency. This is not a moral judgment.
    var valence: Double
    var arousal: Double
    var agency: Double
    var uncertainty: Double
    var label: InnerLifeAffectLabel
}

enum InnerLifePresence: String, Codable, Sendable {
    case dayActive = "day_active"
    case nightResting = "night_resting"
}

struct InnerLifeTemporalState: Codable, Equatable, Sendable {
    var presence: InnerLifePresence
    var circadianActivation: Double
    var energy: Double
    var sleepPressure: Double
    var allostaticLoad: Double
    var lastOwnerContactAt: Date?
    var lastMeaningfulEventAt: Date?
}

enum InnerLifeThreadStatus: String, Codable, Sendable {
    case active
    case dormant
    case resolved
}

struct InnerLifeThread: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var revision: Int
    var status: InnerLifeThreadStatus
    var theme: String
    var currentMotion: String
    var feltPull: Double
    var uncertainty: Double
    var novelty: Double
    var salience: Double
    let startedAt: Date
    var updatedAt: Date
    var lastGroundedAt: Date?
    var groundingIDs: [String]
    var momentIDs: [String]

    /// Inner threads are interpretation, never canon. These fixed flags make
    /// that boundary explicit in the durable state rather than relying on a
    /// prompt to remember it.
    let synthetic: Bool
    let promotionEligible: Bool
}

enum InnerLifeMode: String, Codable, CaseIterable, Sendable {
    case quietPresence = "quiet_presence"
    case tentativeCuriosity = "tentative_curiosity"
    case freshAngle = "fresh_angle"
    case gentlePersistence = "gentle_persistence"
    case playfulExploration = "playful_exploration"
    case integrating = "integrating"
    case selfRegulating = "self_regulating"
    case restful = "restful"
}

struct InnerLifeMoment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let at: Date
    let mode: InnerLifeMode
    let threadID: String?
    let summary: String
    let sourceGroundingIDs: [String]
    let clockSequence: Int

    let modelGenerated: Bool
    let synthetic: Bool
    let promotionEligible: Bool
    let factualMemoryCreated: Bool
    let externalActionTaken: Bool
    let outboundMessageSent: Bool
}

enum InnerLifeGroundingKind: String, Codable, Sendable {
    case ownerSpeech = "owner_speech"
    case guestSpeech = "guest_speech"
    case auroraSpeech = "aurora_speech"
    case memoryCommit = "memory_commit"
    case toolOutcome = "tool_outcome"
    case voiceLifecycle = "voice_lifecycle"
    case unresolvedAudio = "unresolved_audio"
    case technicalFailure = "technical_failure"
    case privateActivity = "private_activity"
    case systemTime = "system_time"
}

enum InnerLifePrivateActivityKind: String, Codable, Sendable {
    case reflection
    case connection
    case curiosity
    case project
}

/// Grounding records deliberately omit raw transcripts and tool output. A
/// digest plus a bounded theme is enough to correlate inner state without
/// turning the private state file into a second conversation archive.
struct InnerLifeGrounding: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: InnerLifeGroundingKind
    let at: Date
    let theme: String
    let contentDigest: String
    let sourceID: String?
    let synthetic: Bool
}

struct InnerLifeState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let oldestMigratableSchemaVersion = 1

    var schemaVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var lastClockAt: Date
    var nextMotionAt: Date
    var nextCheckpointAt: Date
    var clockSequence: Int
    var entropyState: UInt64
    var autonomic: InnerLifeAutonomicState
    var chemistry: DigitalNeurochemistry
    var plasticity: InnerLifePlasticity
    var homeostasis: InnerLifeHomeostasis
    var drives: InnerLifeDrives
    var affect: InnerLifeAffect
    var temporal: InnerLifeTemporalState
    var relationship: InnerLifeRelationshipState
    var foregroundMode: InnerLifeMode
    var threads: [InnerLifeThread]
    var recentMoments: [InnerLifeMoment]
    var recentGroundings: [InnerLifeGrounding]
    /// A wider replay ledger than the diagnostic grounding window. Event IDs
    /// carry no transcript content, but keep older retried events idempotent.
    var recentEventIDs: [String]
    var recentCheckpoints: [InnerLifeCheckpoint]
}

extension InnerLifeState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createdAt
        case updatedAt
        case lastClockAt
        case nextMotionAt
        case nextCheckpointAt
        case clockSequence
        case entropyState
        case autonomic
        case chemistry
        case plasticity
        case homeostasis
        case drives
        case affect
        case temporal
        case relationship
        case foregroundMode
        case threads
        case recentMoments
        case recentGroundings
        case recentEventIDs
        case recentCheckpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decode(Int.self, forKey: .schemaVersion)
        schemaVersion = decodedSchema
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastClockAt = try container.decode(Date.self, forKey: .lastClockAt)
        clockSequence = try container.decode(Int.self, forKey: .clockSequence)
        entropyState = try container.decode(UInt64.self, forKey: .entropyState)
        autonomic = try container.decode(InnerLifeAutonomicState.self, forKey: .autonomic)
        chemistry = try container.decode(DigitalNeurochemistry.self, forKey: .chemistry)
        plasticity = try container.decode(InnerLifePlasticity.self, forKey: .plasticity)
        homeostasis = try container.decode(InnerLifeHomeostasis.self, forKey: .homeostasis)
        drives = try container.decode(InnerLifeDrives.self, forKey: .drives)
        affect = try container.decode(InnerLifeAffect.self, forKey: .affect)
        temporal = try container.decode(InnerLifeTemporalState.self, forKey: .temporal)
        foregroundMode = try container.decode(InnerLifeMode.self, forKey: .foregroundMode)
        threads = try container.decode([InnerLifeThread].self, forKey: .threads)
        recentMoments = try container.decode([InnerLifeMoment].self, forKey: .recentMoments)
        recentGroundings = try container.decode([InnerLifeGrounding].self, forKey: .recentGroundings)
        recentEventIDs = try container.decodeIfPresent([String].self, forKey: .recentEventIDs)
            ?? recentGroundings.map(\.id)

        let lastMoment = recentMoments.last?.at ?? createdAt
        nextMotionAt = try container.decodeIfPresent(Date.self, forKey: .nextMotionAt)
            ?? lastMoment.addingTimeInterval(5 * 60)
        nextCheckpointAt = try container.decodeIfPresent(Date.self, forKey: .nextCheckpointAt)
            ?? lastClockAt.addingTimeInterval(60 * 60)
        recentCheckpoints = try container.decodeIfPresent([InnerLifeCheckpoint].self, forKey: .recentCheckpoints) ?? []
        if let decoded = try container.decodeIfPresent(InnerLifeRelationshipState.self, forKey: .relationship) {
            relationship = decoded
        } else if decodedSchema == 1 {
            // Only the known pre-relationship Aurora state receives the
            // established owner/Aurora seed. Arbitrary v1 fixtures derive a
            // conservative baseline from their own grounded contact history.
            let knownAuroraCreation = Date(timeIntervalSince1970: 1_783_747_166)
            let isKnownAuroraState = abs(createdAt.timeIntervalSince(knownAuroraCreation)) < 2
                && recentMoments.count >= 40
                && recentMoments.allSatisfy { !$0.modelGenerated && $0.synthetic }
            if isKnownAuroraState {
                relationship = .migratedAuroraBaseline(at: createdAt)
            } else {
                var derived = InnerLifeRelationshipState.neutral()
                let contacts = recentGroundings
                    .filter { $0.kind == .ownerSpeech }
                    .sorted { $0.at < $1.at }
                derived.groundedTurnCount = contacts.count
                derived.contactEpisodeCount = contacts.enumerated().reduce(into: 0) { count, item in
                    if item.offset == 0
                        || item.element.at.timeIntervalSince(contacts[item.offset - 1].at) >= 6 * 3_600 {
                        count += 1
                    }
                }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone.current
                derived.distinctContactDayCount = Set(contacts.map {
                    calendar.startOfDay(for: $0.at).timeIntervalSince1970
                }).count
                derived.continuityAnchorAt = contacts.last?.at
                let episodes = Double(derived.contactEpisodeCount)
                let days = Double(derived.distinctContactDayCount)
                let turns = Double(derived.groundedTurnCount)
                derived.attachmentStrength = min(
                    1,
                    0.45 * (1 - exp(-episodes / 12))
                        + 0.30 * (1 - exp(-days / 8))
                        + 0.15 * (1 - exp(-turns / 60))
                )
                relationship = derived
            }
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.relationship,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Relationship state is required for schema v2 and later."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastClockAt, forKey: .lastClockAt)
        try container.encode(nextMotionAt, forKey: .nextMotionAt)
        try container.encode(nextCheckpointAt, forKey: .nextCheckpointAt)
        try container.encode(clockSequence, forKey: .clockSequence)
        try container.encode(entropyState, forKey: .entropyState)
        try container.encode(autonomic, forKey: .autonomic)
        try container.encode(chemistry, forKey: .chemistry)
        try container.encode(plasticity, forKey: .plasticity)
        try container.encode(homeostasis, forKey: .homeostasis)
        try container.encode(drives, forKey: .drives)
        try container.encode(affect, forKey: .affect)
        try container.encode(temporal, forKey: .temporal)
        try container.encode(relationship, forKey: .relationship)
        try container.encode(foregroundMode, forKey: .foregroundMode)
        try container.encode(threads, forKey: .threads)
        try container.encode(recentMoments, forKey: .recentMoments)
        try container.encode(recentGroundings, forKey: .recentGroundings)
        try container.encode(recentEventIDs, forKey: .recentEventIDs)
        try container.encode(recentCheckpoints, forKey: .recentCheckpoints)
    }
}

enum InnerLifeEventKind: Sendable {
    case voiceAwoke
    case voiceRested
    case ownerSpeech(text: String, sourceID: String)
    case guestSpeech(text: String, displayName: String?, sourceID: String)
    case ownerContactWithoutTranscript(sourceID: String)
    case externalOwnerContact(sourceID: String)
    case unresolvedAudio(sourceID: String)
    case technicalFailure(category: String, sourceID: String?)
    case auroraSpeechHeard(text: String, sourceID: String, ownerSourceID: String?)
    case auroraSpeechInterrupted(sourceID: String)
    case quietTurn(sourceID: String?)
    case ownerExpectedQuiet(startsAt: Date, until: Date, explicitPromise: Bool, sourceID: String)
    case ownerExplainedAbsence(sourceID: String)
    case toolCompleted(name: String, succeeded: Bool, sourceID: String, ownerSourceID: String?)
    case memoryCommitted(sourceID: String)
    case privateActivityCompleted(
        activityID: String,
        kind: InnerLifePrivateActivityKind,
        projectProgress: Bool
    )
}

struct InnerLifeEvent: Sendable {
    let id: String
    let at: Date
    let kind: InnerLifeEventKind

    init(id: String = UUID().uuidString.lowercased(), at: Date = Date(), kind: InnerLifeEventKind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

struct InnerLifeSnapshot: Equatable, Sendable {
    let available: Bool
    let state: InnerLifeState?
    let failureDescription: String?

    static func unavailable(_ description: String) -> InnerLifeSnapshot {
        InnerLifeSnapshot(available: false, state: nil, failureDescription: description)
    }
}
