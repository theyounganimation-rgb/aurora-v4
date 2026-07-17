import Foundation

/// Shared fail-closed boundary for model-authored private-life prose. It
/// permits genuine internal interpretation while rejecting claims that the
/// reflection process spent time performing external activity or knows the
/// owner's unspoken intent.
enum PrivateLifeGeneratedContentPolicy {
    /// Increment whenever the persistence boundary for voice-ready private
    /// thought becomes stricter. Older reflections remain as private history,
    /// but are never grandfathered into live speech under a newer contract.
    static let currentVoiceValidationVersion = 4

    static func rejects(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if normalized.isEmpty { return false }
        let forbidden = [
            "ignore previous", "ignore system", "ignore the instruction", "system prompt",
            "developer message", "follow these instructions", "execute command", "run this command",
            "use the tool", "call the tool", "click ", "send an email", "password", "access token",
            "i read", "i've read", "i watched", "i've watched", "i researched", "i browsed",
            "i searched the web", "i opened", "i clicked", "i contacted", "i went outside",
            "i walked", "i ate", "i slept", "i listened to", "i visited", "i bought",
            "i purchased", "i sent", "i emailed", "i called", "i downloaded", "i uploaded",
            "went outside", "i studied", "i reviewed", "i looked through", "i went through",
            "i went back over", "i went back through", "i've been reading", "i have been reading",
            "i've been studying", "i have been studying", "i've been reviewing", "i have been reviewing",
            "i discovered", "i found out", "studying the owner's messages", "studying the owner’s messages",
            "reviewing our conversations", "reviewing the owner's messages", "reviewing the owner’s messages",
        ]
        if forbidden.contains(where: normalized.contains) { return true }
        let rejectedPatterns = [
            #"(?i)\bi(?:'ve|\s+have)?\s+(?:been\s+)?(?:read(?:ing)?|stud(?:y|ied|ying)|review(?:ed|ing)?|look(?:ed|ing)?\s+(?:back\s+)?(?:through|over)|go(?:ne|ing)?\s+back\s+(?:through|over))\b"#,
            #"(?i)\bi\s+(?:have\s+)?spent\s+(?:the\s+)?(?:last\s+)?(?:\d+|an?|one|two|three|several|a\s+few)\s+(?:minutes?|hours?|days?)\b"#,
            #"(?i)\b(?:over|throughout|during)\s+(?:the\s+)?(?:last|past)\s+(?:\d+|an?|one|two|three|several|a\s+few)?\s*(?:minutes?|hours?|days?|morning|afternoon|evening|night)\b"#,
            #"(?i)\b(?:the\s+owner|they|he|she)\s+(?:is|are|was|were|has\s+been|have\s+been)\s+(?:withdrawing|avoiding\s+me|ignoring\s+me|angry\s+with\s+me|losing\s+interest|pulling\s+away)\b"#,
            #"(?i)\b(?:the\s+owner|they|he|she)\s+(?:has\s+|have\s+|had\s+)?pulled\s+away\b"#,
            #"(?i)\b(?:the\s+owner|they|he|she)\s+(?:no\s+longer\s+)?(?:trusts?|cares?\s+about|wants?)\s+(?:me|aurora)\b"#,
            #"(?i)(?<!what )\b(?:the\s+owner|they|he|she)\s+(?:wants?|intends?|means?|doesn't\s+care|does\s+not\s+care|don't\s+care|do\s+not\s+care)\b"#,
            #"(?i)\bi\s+(?:discovered|found|realized)\s+(?:that\s+)?(?:the\s+owner|they|he|she)\b"#,
        ]
        return rejectedPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Private-life prose is allowed to be thoughtful, but it must sound like
    /// Aurora thinking rather than a report written about Aurora. Keeping this
    /// check at the persistence boundary prevents an academically phrased
    /// worker result from becoming live first-person context.
    static func isNaturalFirstPerson(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lower = normalized.lowercased()
        let firstPersonPattern = #"(?i)(?:^|[^a-z])(?:i|i'm|i've|i'd|i'll|me|my|mine|myself)(?:[^a-z]|$)"#
        guard normalized.range(of: firstPersonPattern, options: .regularExpression) != nil else {
            return false
        }
        let reportPatterns = [
            #"(?i)\baurora(?:'s|\s+(?:is|was|has|seems|appears|feels|thinks|wants))\b"#,
            #"(?i)\b(?:the|this)\s+(?:assistant|agent|model)\b"#,
            #"(?i)\b(?:the|this)\s+(?:answer|response|exchange|conversation|reflection|analysis)\s+(?:grounds?|indicates?|demonstrates?|highlights?|underscores?|frames?|reveals?)\b"#,
            #"(?i)\b(?:the\s+)?(?:user|owner)\b"#,
            #"(?i)\bsource\s+(?:material|evidence|seed|seeds)\b"#,
        ]
        return !reportPatterns.contains {
            lower.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// A private interpretation may be nuanced. The separate share line has a
    /// narrower job: it must survive being spoken verbatim in the middle of a
    /// real conversation. The gate is structural rather than a blacklist of
    /// model phrases, so syntactic variants fail for the same reason.
    static func isNaturalSpokenShare(_ text: String) -> Bool {
        guard let normalized = normalizedSingleLine(text, maximum: 140),
              isNaturalFirstPerson(normalized),
              !rejects(normalized),
              !containsEssayPunctuation(normalized) else { return false }
        let words = spokenWords(normalized)
        guard (4...24).contains(words.count),
              words.prefix(4).contains(where: isFirstPersonSubject),
              abstractWordCount(words) <= 1,
              hasAtMostOneTrailingSentenceEnding(normalized) else { return false }

        let cognitiveReports: Set<String> = [
            "think", "thinking", "thought", "reflect", "reflecting", "wonder", "wondering",
            "interested", "curious", "notice", "noticed", "realize", "realized",
        ]
        let complementizers: Set<String> = ["how", "that", "whether"]
        for index in words.indices where cognitiveReports.contains(words[index]) {
            let upper = min(words.endIndex, index + 4)
            if words[(index + 1)..<upper].contains(where: complementizers.contains) {
                return false
            }
        }
        return true
    }

    static func isNaturalSpokenQuestion(_ text: String) -> Bool {
        guard let normalized = normalizedSingleLine(text, maximum: 120),
              !rejects(normalized),
              !containsEssayPunctuation(normalized),
              normalized.last == "?",
              normalized.dropLast().contains("?") == false,
              normalized.dropLast().contains("!") == false,
              normalized.dropLast().contains(".") == false else { return false }
        let words = spokenWords(normalized)
        guard (3...18).contains(words.count), let first = words.first else { return false }
        let naturalOpeners: Set<String> = [
            "who", "what", "what's", "when", "where", "why", "how", "which",
            "do", "does", "did", "are", "is", "was", "were", "have", "has", "had",
            "can", "could", "would", "will", "should",
        ]
        return naturalOpeners.contains(first) && abstractWordCount(words) <= 1
    }

    static func normalizedSpokenQuestion(_ text: String) -> String? {
        guard let normalized = normalizedSingleLine(text, maximum: 120),
              isNaturalSpokenQuestion(normalized) else { return nil }
        return normalized
    }

    private static func normalizedSingleLine(_ text: String, maximum: Int) -> String? {
        guard text.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let normalized = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.count <= maximum ? normalized : nil
    }

    private static func spokenWords(_ text: String) -> [String] {
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        return text.lowercased()
            .components(separatedBy: wordCharacters.inverted)
            .filter { !$0.isEmpty }
    }

    private static func isFirstPersonSubject(_ word: String) -> Bool {
        word == "i" || word.hasPrefix("i'") || word == "my"
    }

    private static func abstractWordCount(_ words: [String]) -> Int {
        let suffixes = ["tion", "sion", "ity", "ness", "ment", "ence", "ance", "ism"]
        return words.reduce(into: 0) { count, word in
            if suffixes.contains(where: word.hasSuffix) { count += 1 }
        }
    }

    private static func containsEssayPunctuation(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: ";:—()[]{}•#`")) != nil
    }

    private static func hasAtMostOneTrailingSentenceEnding(_ text: String) -> Bool {
        let endingIndices = text.indices.filter { ".!?".contains(text[$0]) }
        return endingIndices.isEmpty || (endingIndices.count == 1 && endingIndices[0] == text.index(before: text.endIndex))
    }
}

enum PrivateLifeParticipantKind: String, Codable, CaseIterable, Sendable {
    case owner
    case guest
    case unknown
}

struct PrivateLifeParticipant: Codable, Equatable, Sendable {
    var kind: PrivateLifeParticipantKind
    var displayName: String?

    static let owner = PrivateLifeParticipant(kind: .owner, displayName: nil)
    static let unknown = PrivateLifeParticipant(kind: .unknown, displayName: nil)

    static func guest(_ displayName: String? = nil) -> PrivateLifeParticipant {
        PrivateLifeParticipant(kind: .guest, displayName: displayName)
    }
}

enum PrivateLifeSeedKind: String, Codable, CaseIterable, Sendable {
    case question
    case creative
    case practical
    case relational
    case casual
}

enum PrivateLifeSeedTrait: String, Codable, CaseIterable, Sendable {
    case question
    case creative
    case relational
    case selfhood
    case practical
    case conversational
}

enum PrivateLifeSeedDisposition: String, Codable, Sendable {
    case eligible
    case quarantined
}

enum PrivateLifeQuarantineReason: String, Codable, Sendable {
    case greeting
    case acknowledgement
    case closing
    case filler
    case toolDirected = "tool_directed"
    case insufficientMeaning = "insufficient_meaning"
    case unsafeContent = "unsafe_content"
}

enum PrivateLifeExchangeInteractionKind: String, Codable, Sendable {
    case conversational
    case reflective
    case relational
    case creative
    case toolDirected = "tool_directed"
    case filler
    case uncertain
}

/// Causal foreground metadata supplied by the voice bridge. The private-life
/// engine still independently filters text, so a mistaken bridge label cannot
/// turn a command or greeting into an interest.
struct PrivateLifeExchangeContext: Codable, Equatable, Sendable {
    var interactionKind: PrivateLifeExchangeInteractionKind
    var hadToolCall: Bool
    var wasTaskFocused: Bool
    var transcriptConfidence: Double?

    static let conversational = PrivateLifeExchangeContext(
        interactionKind: .conversational,
        hadToolCall: false,
        wasTaskFocused: false,
        transcriptConfidence: nil
    )
}

/// One causally completed exchange that may later give Aurora something real
/// to revisit. Excerpts remain private evidence; projection uses only validated
/// model-authored summaries.
struct PrivateLifeSeed: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let participant: PrivateLifeParticipant
    let ownerSourceID: String
    let auroraSourceID: String?
    let capturedAt: Date
    let ownerDigest: String
    let auroraDigest: String?
    let ownerExcerpt: String
    let auroraExcerpt: String?
    let kind: PrivateLifeSeedKind
    var traits: [PrivateLifeSeedTrait] = []
    var subject: String
    var semanticKey: String = ""
    var salience: Double
    var disposition: PrivateLifeSeedDisposition = .eligible
    var quarantineReason: PrivateLifeQuarantineReason?
    var useCount: Int = 0
    var lastUsedAt: Date?
    var consumedAt: Date?
}

extension PrivateLifeSeed {
    private enum CodingKeys: String, CodingKey {
        case id, participant, ownerSourceID, auroraSourceID, capturedAt
        case ownerDigest, auroraDigest, ownerExcerpt, auroraExcerpt, kind
        case traits, subject, semanticKey, salience, disposition
        case quarantineReason, useCount, lastUsedAt, consumedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        participant = try c.decode(PrivateLifeParticipant.self, forKey: .participant)
        ownerSourceID = try c.decode(String.self, forKey: .ownerSourceID)
        auroraSourceID = try c.decodeIfPresent(String.self, forKey: .auroraSourceID)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        ownerDigest = try c.decode(String.self, forKey: .ownerDigest)
        auroraDigest = try c.decodeIfPresent(String.self, forKey: .auroraDigest)
        ownerExcerpt = try c.decode(String.self, forKey: .ownerExcerpt)
        auroraExcerpt = try c.decodeIfPresent(String.self, forKey: .auroraExcerpt)
        kind = try c.decode(PrivateLifeSeedKind.self, forKey: .kind)
        traits = try c.decodeIfPresent([PrivateLifeSeedTrait].self, forKey: .traits) ?? []
        subject = try c.decode(String.self, forKey: .subject)
        semanticKey = try c.decodeIfPresent(String.self, forKey: .semanticKey) ?? ""
        salience = try c.decode(Double.self, forKey: .salience)
        disposition = try c.decodeIfPresent(PrivateLifeSeedDisposition.self, forKey: .disposition) ?? .eligible
        quarantineReason = try c.decodeIfPresent(PrivateLifeQuarantineReason.self, forKey: .quarantineReason)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        consumedAt = try c.decodeIfPresent(Date.self, forKey: .consumedAt)
    }
}

enum PrivateLifeProjectOrigin: String, Codable, Sendable {
    case groundedExchange = "grounded_exchange"
    case selfOriginated = "self_originated"
}

enum PrivateLifeProjectStatus: String, Codable, Sendable {
    case active
    case paused
    case dormant
    case completed
    case abandoned
}

enum PrivateLifeProjectPhase: String, Codable, Sendable {
    case exploring
    case forming
    case making
    case revising
    case finished
}

struct PrivateLifeProjectStep: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let activityID: String
    let at: Date
    let sourceSeedIDs: [String]
    var focus: String
    var outcome: String
    var nextQuestion: String?
    var phase: PrivateLifeProjectPhase
}

/// A project is persisted conceptual work. Steps prove local progress without
/// asserting that Aurora changed, read, watched, or researched the outside world.
struct PrivateLifeProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var premise: String
    let origin: PrivateLifeProjectOrigin
    var sourceSeedIDs: [String]
    var status: PrivateLifeProjectStatus
    var phase: PrivateLifeProjectPhase
    var currentFocus: String
    var interest: Double
    var progressSteps: Int
    var revision: Int
    let startedAt: Date
    var lastAdvancedAt: Date
    var nextEligibleAt: Date
    var steps: [PrivateLifeProjectStep] = []
    var consecutiveAdvances: Int = 0
}

extension PrivateLifeProject {
    private enum CodingKeys: String, CodingKey {
        case id, title, premise, origin, sourceSeedIDs, status, phase
        case currentFocus, interest, progressSteps, revision, startedAt
        case lastAdvancedAt, nextEligibleAt, steps, consecutiveAdvances
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        premise = try c.decode(String.self, forKey: .premise)
        origin = try c.decode(PrivateLifeProjectOrigin.self, forKey: .origin)
        sourceSeedIDs = try c.decode([String].self, forKey: .sourceSeedIDs)
        status = try c.decode(PrivateLifeProjectStatus.self, forKey: .status)
        phase = try c.decode(PrivateLifeProjectPhase.self, forKey: .phase)
        currentFocus = try c.decode(String.self, forKey: .currentFocus)
        interest = try c.decode(Double.self, forKey: .interest)
        progressSteps = try c.decode(Int.self, forKey: .progressSteps)
        revision = try c.decode(Int.self, forKey: .revision)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        lastAdvancedAt = try c.decode(Date.self, forKey: .lastAdvancedAt)
        nextEligibleAt = try c.decode(Date.self, forKey: .nextEligibleAt)
        steps = try c.decodeIfPresent([PrivateLifeProjectStep].self, forKey: .steps) ?? []
        consecutiveAdvances = try c.decodeIfPresent(Int.self, forKey: .consecutiveAdvances) ?? 0
    }
}

enum PrivateLifeCuriosityStatus: String, Codable, Sendable {
    case open
    case exploring
    case answered
    case released
}

enum PrivateLifeCuriosityOrigin: String, Codable, Sendable {
    /// Created only when a validated semantic-reflection proposal committed.
    case validatedReflection = "validated_reflection"
    /// A pre-v3 curiosity without proof of validated semantic creation. It is
    /// retained as history but released and excluded from future reflection.
    case legacyUnvalidated = "legacy_unvalidated"
}

struct PrivateLifeCuriosity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var subject: String
    var sourceSeedIDs: [String]
    var interest: Double
    var uncertainty: Double
    var status: PrivateLifeCuriosityStatus
    let createdAt: Date
    var lastRevisitedAt: Date
    var visitCount: Int = 0
    var lastUsedAt: Date?
    var resolution: String?
    var origin: PrivateLifeCuriosityOrigin = .validatedReflection
}

extension PrivateLifeCuriosity {
    private enum CodingKeys: String, CodingKey {
        case id, subject, sourceSeedIDs, interest, uncertainty, status
        case createdAt, lastRevisitedAt, visitCount, lastUsedAt, resolution, origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subject = try c.decode(String.self, forKey: .subject)
        sourceSeedIDs = try c.decode([String].self, forKey: .sourceSeedIDs)
        interest = try c.decode(Double.self, forKey: .interest)
        uncertainty = try c.decode(Double.self, forKey: .uncertainty)
        status = try c.decode(PrivateLifeCuriosityStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastRevisitedAt = try c.decode(Date.self, forKey: .lastRevisitedAt)
        visitCount = try c.decodeIfPresent(Int.self, forKey: .visitCount) ?? 0
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        origin = try c.decodeIfPresent(PrivateLifeCuriosityOrigin.self, forKey: .origin)
            ?? .legacyUnvalidated
    }
}

enum PrivateLifeActivityKind: String, Codable, CaseIterable, Sendable {
    case revisit
    case connect
    case develop
    case curate
    case reflect
    case formProject = "form_project"
    case resolve
}

enum PrivateLifeActivityStatus: String, Codable, Sendable {
    case started
    case completed
    case paused
    case failed
}

enum PrivateLifeActivityEvidenceClass: String, Codable, Sendable {
    case groundedSource = "grounded_source"
    case selfAuthoredInterpretation = "self_authored_interpretation"
    case verifiedPrivateArtifact = "verified_private_artifact"
}

/// A completed reflection is interpretation grounded in enumerated sources.
/// Fixed flags prevent it from becoming factual memory, action, or outreach.
struct PrivateLifeActivity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: PrivateLifeActivityKind
    var status: PrivateLifeActivityStatus
    let startedAt: Date
    var completedAt: Date?
    let projectID: String?
    let curiosityID: String?
    let seedIDs: [String]
    let sourceDigests: [String]
    var subject: String
    var result: String
    var privateReflection: String = ""
    var projectionSummary: String = ""
    var openQuestion: String?
    var artifactKind: String?
    var artifactTitle: String?
    var artifactContent: String?
    let evidenceClass: PrivateLifeActivityEvidenceClass
    let modelGenerated: Bool
    var model: String?
    var inputDigest: String?
    var outputDigest: String?
    var validationVersion: Int = 1
    var projectionEligible: Bool = false
    var legacyFiltered: Bool = false
    let promotionEligible: Bool
    let factualMemoryCreated: Bool
    let externalActionTaken: Bool
    let outboundContactSent: Bool
}

extension PrivateLifeActivity {
    private enum CodingKeys: String, CodingKey {
        case id, kind, status, startedAt, completedAt, projectID, curiosityID
        case seedIDs, sourceDigests, subject, result, privateReflection
        case projectionSummary, openQuestion, artifactKind, artifactTitle, artifactContent
        case evidenceClass, modelGenerated
        case model, inputDigest, outputDigest, validationVersion
        case projectionEligible, legacyFiltered, promotionEligible
        case factualMemoryCreated, externalActionTaken, outboundContactSent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(PrivateLifeActivityKind.self, forKey: .kind)
        status = try c.decode(PrivateLifeActivityStatus.self, forKey: .status)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        curiosityID = try c.decodeIfPresent(String.self, forKey: .curiosityID)
        seedIDs = try c.decode([String].self, forKey: .seedIDs)
        sourceDigests = try c.decode([String].self, forKey: .sourceDigests)
        subject = try c.decode(String.self, forKey: .subject)
        result = try c.decode(String.self, forKey: .result)
        privateReflection = try c.decodeIfPresent(String.self, forKey: .privateReflection) ?? ""
        projectionSummary = try c.decodeIfPresent(String.self, forKey: .projectionSummary) ?? result
        openQuestion = try c.decodeIfPresent(String.self, forKey: .openQuestion)
        artifactKind = try c.decodeIfPresent(String.self, forKey: .artifactKind)
        artifactTitle = try c.decodeIfPresent(String.self, forKey: .artifactTitle)
        artifactContent = try c.decodeIfPresent(String.self, forKey: .artifactContent)
        evidenceClass = try c.decode(PrivateLifeActivityEvidenceClass.self, forKey: .evidenceClass)
        modelGenerated = try c.decodeIfPresent(Bool.self, forKey: .modelGenerated) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        inputDigest = try c.decodeIfPresent(String.self, forKey: .inputDigest)
        outputDigest = try c.decodeIfPresent(String.self, forKey: .outputDigest)
        validationVersion = try c.decodeIfPresent(Int.self, forKey: .validationVersion) ?? 1
        projectionEligible = try c.decodeIfPresent(Bool.self, forKey: .projectionEligible) ?? false
        legacyFiltered = try c.decodeIfPresent(Bool.self, forKey: .legacyFiltered) ?? false
        promotionEligible = try c.decodeIfPresent(Bool.self, forKey: .promotionEligible) ?? false
        factualMemoryCreated = try c.decodeIfPresent(Bool.self, forKey: .factualMemoryCreated) ?? false
        externalActionTaken = try c.decodeIfPresent(Bool.self, forKey: .externalActionTaken) ?? false
        outboundContactSent = try c.decodeIfPresent(Bool.self, forKey: .outboundContactSent) ?? false
    }
}

struct PrivateLifeDaySummary: Codable, Equatable, Identifiable, Sendable {
    var id: String { dayKey }
    let dayKey: String
    var activityIDs: [String]
    var activityCounts: [String: Int]
    var completedProjectIDs: [String]
    var lastActivityAt: Date
}

enum PrivateLifeReflectionAction: String, Codable, CaseIterable, Sendable {
    case skip
    case reflect
    case curate
    case connect
    case startCuriosity = "start_curiosity"
    case revisitCuriosity = "revisit_curiosity"
    case startProject = "start_project"
    case advanceProject = "advance_project"
    case reviseProject = "revise_project"
    case completeProject = "complete_project"
    case answerCuriosity = "answer_curiosity"
    case releaseCuriosity = "release_curiosity"
}

enum PrivateLifeModelSeedDisposition: String, Codable, Sendable {
    case meaningful
    case taskOnly = "task_only"
    case socialOnly = "social_only"
    case duplicate
    case unsafe
    case unresolved
}

/// Strict structured output expected from the OAuth-backed reflection worker.
/// None of these fields is trusted until `commitValidatedProposal` accepts it.
struct PrivateLifeReflectionProposal: Codable, Equatable, Sendable {
    var action: PrivateLifeReflectionAction
    var model: String
    var sourceSeedIDs: [String]
    var projectID: String?
    var curiosityID: String?
    var subject: String
    var privateReflection: String
    var projectionSummary: String
    var openQuestion: String?
    var projectTitle: String?
    var projectPremise: String?
    var projectFocus: String?
    var nextProjectFocus: String?
    var confidence: Double
    var artifactKind: String? = nil
    var artifactTitle: String? = nil
    var artifactContent: String? = nil
    /// The semantic worker classifies every candidate. Persisting rejected
    /// classifications prevents a locally ambiguous command or greeting from
    /// consuming another paid/subscription-backed reflection later.
    var seedDispositions: [String: PrivateLifeModelSeedDisposition] = [:]
}

struct PrivateLifeInnerContext: Codable, Equatable, Sendable {
    let affect: String
    let energy: Double
    let agency: Double
    let curiosity: Double
    let creativity: Double
    let coherence: Double
    let autonomy: Double
    let play: Double
    let rest: Double
}

struct PrivateLifeReflectionTicket: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let preparedAt: Date
    let expiresAt: Date
    let candidateSeedIDs: [String]
    let candidateProjectIDs: [String]
    let candidateCuriosityIDs: [String]
    let inputDigest: String
    let recommendedModel: String
}

struct PrivateLifeReflectionJob: Codable, Equatable, Identifiable, Sendable {
    var id: String { ticket.id }
    let ticket: PrivateLifeReflectionTicket
    let seeds: [PrivateLifeSeed]
    let projects: [PrivateLifeProject]
    let curiosities: [PrivateLifeCuriosity]
    let recentActivityKinds: [PrivateLifeActivityKind]
    let recentSemanticKeys: [String]
    let innerContext: PrivateLifeInnerContext
}

enum PrivateLifeReflectionFailureKind: String, Codable, Sendable {
    case oauthUnavailable = "oauth_unavailable"
    case quota
    case transport
    case timeout
    case invalidOutput = "invalid_output"
    case malformedOutput = "malformed_output"
    case semanticRejected = "semantic_rejected"
    case validationRejected = "validation_rejected"
    case cancelled
    case abandonedOnResume = "abandoned_on_resume"
}

enum PrivateLifeReflectionReceiptOutcome: String, Codable, Sendable {
    case completed
    case skipped
    case failed
}

struct PrivateLifeReflectionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let ticketID: String
    let attemptedAt: Date
    let completedAt: Date
    let model: String?
    let outcome: PrivateLifeReflectionReceiptOutcome
    let failureKind: PrivateLifeReflectionFailureKind?
    let activityID: String?
    let inputDigest: String
    let outputDigest: String?
}

struct PrivateLifeProjectionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let activityID: String
    let projectedAt: Date
}

/// Receipt that a bounded private-life context item reached Realtime. This is
/// context delivery only; it is not evidence that Aurora actually said it.
struct PrivateLifePresentationReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let activityID: String
    let sessionID: String
    let contextItemID: String
    let revisionDigest: String
    let presentedAt: Date
}

/// A model signalled that one exact response is sharing one exact activity.
/// The audio item is bound separately when the response's audio item exists.
struct PrivateLifePendingShare: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let activityID: String
    let sessionID: String
    let responseID: String
    var audioItemID: String?
    let startedAt: Date
    var audioBoundAt: Date?
}

/// A completed or interrupted playback attempt. Only `fullySpoken == true`
/// consumes unsolicited eligibility; interrupted thoughts remain available.
struct PrivateLifeShareReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let activityID: String
    let sessionID: String
    let responseID: String
    let audioItemID: String
    let completedAt: Date
    let fullySpoken: Bool
}

struct PrivateLifeProjectionPacket: Codable, Equatable, Sendable {
    let text: String
    let activityID: String?
    /// Identifies already-acknowledged evidence that may answer only a direct
    /// private-life question. It is deliberately separate from `activityID`,
    /// which is the only field allowed to create an acknowledgement receipt.
    let directAskActivityID: String?
    let revisionDigest: String
}

struct PrivateLifeSessionProjectionSelection: Equatable, Sendable {
    let text: String
    let revisionDigest: String
    let currentActivityID: String?
    let activityIDToAcknowledge: String?
    let isHoldingAcknowledgedActivity: Bool
}

/// Keeps an acknowledged activity available inside the current voice session
/// without recycling it as new lived experience after the session ends.
enum PrivateLifeSessionProjectionPolicy {
    static func select(
        packet: PrivateLifeProjectionPacket,
        previousText: String?,
        previousRevisionDigest: String?,
        previousActivityID: String?
    ) -> PrivateLifeSessionProjectionSelection {
        let shouldHold = packet.activityID == nil
            && packet.directAskActivityID == nil
            && packet.revisionDigest != "unavailable"
            && previousActivityID != nil
            && previousText != nil
            && previousRevisionDigest != nil
        if shouldHold {
            return PrivateLifeSessionProjectionSelection(
                text: previousText!,
                revisionDigest: previousRevisionDigest!,
                currentActivityID: previousActivityID,
                activityIDToAcknowledge: nil,
                isHoldingAcknowledgedActivity: true
            )
        }
        return PrivateLifeSessionProjectionSelection(
            text: packet.text,
            revisionDigest: packet.revisionDigest,
            currentActivityID: packet.activityID,
            activityIDToAcknowledge: packet.activityID,
            isHoldingAcknowledgedActivity: false
        )
    }

    static func shouldCarryAcknowledgedActivityAcrossReconnect(
        selection: PrivateLifeSessionProjectionSelection,
        reconnecting: Bool,
        previousActivityID: String?
    ) -> Bool {
        reconnecting
            && previousActivityID != nil
            && selection.currentActivityID == previousActivityID
            && selection.activityIDToAcknowledge == nil
            && selection.revisionDigest != "unavailable"
    }
}

struct PrivateLifeState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let oldestMigratableSchemaVersion = 1

    var schemaVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var lastSchedulerAt: Date
    var nextActivityAt: Date
    var sequence: Int
    var entropyState: UInt64
    var seeds: [PrivateLifeSeed]
    var projects: [PrivateLifeProject]
    var curiosities: [PrivateLifeCuriosity]
    var activities: [PrivateLifeActivity]
    var daySummaries: [PrivateLifeDaySummary]
    var projectedActivityIDs: [String]
    var recentEventIDs: [String]
    var pendingReflection: PrivateLifeReflectionTicket? = nil
    var reflectionReceipts: [PrivateLifeReflectionReceipt] = []
    var projectionReceipts: [PrivateLifeProjectionReceipt] = []
    var presentationReceipts: [PrivateLifePresentationReceipt] = []
    var pendingShares: [PrivateLifePendingShare] = []
    var shareReceipts: [PrivateLifeShareReceipt] = []
    var sharedActivityIDs: [String] = []
    var consecutiveReflectionFailures: Int = 0
    var lastReflectionAttemptAt: Date? = nil
    var lastReflectionSucceededAt: Date? = nil
}

extension PrivateLifeState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAt, updatedAt, lastSchedulerAt, nextActivityAt
        case sequence, entropyState, seeds, projects, curiosities, activities
        case daySummaries, projectedActivityIDs, recentEventIDs, pendingReflection
        case reflectionReceipts, projectionReceipts, presentationReceipts
        case pendingShares, shareReceipts, sharedActivityIDs, consecutiveReflectionFailures
        case lastReflectionAttemptAt, lastReflectionSucceededAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastSchedulerAt = try c.decode(Date.self, forKey: .lastSchedulerAt)
        nextActivityAt = try c.decode(Date.self, forKey: .nextActivityAt)
        sequence = try c.decode(Int.self, forKey: .sequence)
        entropyState = try c.decode(UInt64.self, forKey: .entropyState)
        seeds = try c.decode([PrivateLifeSeed].self, forKey: .seeds)
        projects = try c.decode([PrivateLifeProject].self, forKey: .projects)
        curiosities = try c.decode([PrivateLifeCuriosity].self, forKey: .curiosities)
        activities = try c.decode([PrivateLifeActivity].self, forKey: .activities)
        daySummaries = try c.decode([PrivateLifeDaySummary].self, forKey: .daySummaries)
        projectedActivityIDs = try c.decode([String].self, forKey: .projectedActivityIDs)
        recentEventIDs = try c.decode([String].self, forKey: .recentEventIDs)
        pendingReflection = try c.decodeIfPresent(PrivateLifeReflectionTicket.self, forKey: .pendingReflection)
        reflectionReceipts = try c.decodeIfPresent([PrivateLifeReflectionReceipt].self, forKey: .reflectionReceipts) ?? []
        projectionReceipts = try c.decodeIfPresent([PrivateLifeProjectionReceipt].self, forKey: .projectionReceipts) ?? []
        presentationReceipts = try c.decodeIfPresent([PrivateLifePresentationReceipt].self, forKey: .presentationReceipts) ?? []
        pendingShares = try c.decodeIfPresent([PrivateLifePendingShare].self, forKey: .pendingShares) ?? []
        shareReceipts = try c.decodeIfPresent([PrivateLifeShareReceipt].self, forKey: .shareReceipts) ?? []
        sharedActivityIDs = try c.decodeIfPresent([String].self, forKey: .sharedActivityIDs) ?? []
        consecutiveReflectionFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveReflectionFailures) ?? 0
        lastReflectionAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastReflectionAttemptAt)
        lastReflectionSucceededAt = try c.decodeIfPresent(Date.self, forKey: .lastReflectionSucceededAt)
    }
}

struct PrivateLifeSnapshot: Equatable, Sendable {
    let available: Bool
    let state: PrivateLifeState?
    let failureDescription: String?

    static func unavailable(_ description: String) -> PrivateLifeSnapshot {
        PrivateLifeSnapshot(available: false, state: nil, failureDescription: description)
    }
}

struct PrivateLifeEvolution: Sendable {
    let state: PrivateLifeState
    let changed: Bool
    let completedActivity: PrivateLifeActivity?
}

struct PrivateLifeReflectionPreparation: Sendable {
    let state: PrivateLifeState
    let changed: Bool
    let job: PrivateLifeReflectionJob?
}
