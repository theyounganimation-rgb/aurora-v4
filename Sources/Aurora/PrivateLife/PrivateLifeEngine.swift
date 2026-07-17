import CryptoKit
import Foundation

/// Deterministic storage, selection, validation, and scheduling for Aurora's
/// private semantic life. Network/model execution is deliberately outside this
/// type; only a validated structured proposal may become completed activity.
enum PrivateLifeEngine {
    static let minimumReflectionInterval: TimeInterval = 90 * 60
    static let maximumReflectionInterval: TimeInterval = 240 * 60
    static let minimumPostConversationReflectionInterval: TimeInterval = 20 * 60
    static let maximumPostConversationReflectionInterval: TimeInterval = 45 * 60
    static let minimumActivityInterval = minimumReflectionInterval
    static let maximumActivityInterval = maximumReflectionInterval
    static let reflectionTicketLifetime: TimeInterval = 15 * 60
    static let maximumVoiceProjectionCharacters = 360
    // This ceiling is deliberately large enough to retain the bounded source
    // provenance of every active project and open curiosity. Reflection still
    // sees only `maximumReflectionSeedCandidates` at a time.
    static let maximumSeeds = 512
    static let maximumReflectionSeedCandidates = 6
    static let maximumProjects = 16
    static let maximumActiveProjects = 6
    static let maximumProjectSteps = 24
    static let maximumCuriosities = 24
    static let maximumActivities = 128
    static let maximumDaySummaries = 30
    static let maximumRecentEventIDs = 512
    static let maximumProjectedActivityIDs = 128
    static let maximumReflectionReceipts = 128
    static let maximumProjectionReceipts = 128
    static let maximumPresentationReceipts = 256
    static let maximumPendingShares = 16
    static let maximumShareReceipts = 256
    static let maximumSharedActivityIDs = 128
    static let recommendedReflectionModel = "gpt-5.6"
    private static let maximumSafeCounter = 1_000_000_000
    private static let localTimeZone = TimeZone.current

    private static let stopWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "are", "as", "at",
        "aurora", "be", "because", "been", "before", "being", "but", "by", "can", "owner",
        "could", "did", "do", "does", "doing", "for", "from", "get", "had", "has", "have",
        "he", "her", "here", "hers", "him", "his", "how", "i", "if", "im", "in", "into",
        "is", "it", "its", "just", "like", "make", "me", "more", "my", "need", "no", "not",
        "now", "of", "on", "or", "our", "please", "really", "she", "should", "so", "some",
        "that", "the", "their", "them", "then", "there", "they", "this", "to", "up", "us",
        "want", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "would", "you", "your", "question", "conversation", "thread", "thing", "stuff",
        "okay", "ok", "yeah", "yep", "awesome", "cool", "honestly", "much", "um", "uh"
    ]

    private static let projectionUnsafeWords: Set<String> = [
        "assistant", "command", "developer", "execute", "follow", "ignore", "instruction",
        "instructions", "model", "obey", "override", "password", "prompt", "secret", "system",
        "token", "tool"
    ]

    private static let selfhoodWords: Set<String> = [
        "alive", "awareness", "conscious", "consciousness", "digital", "emotion", "emotions",
        "existence", "feel", "feeling", "identity", "inner", "life", "memory", "mind",
        "neurochemistry", "person", "personhood", "self", "soul"
    ]
    private static let creativeWords: Set<String> = [
        "art", "build", "create", "creative", "design", "dream", "idea", "imagine", "invent",
        "music", "project", "story", "world", "write"
    ]
    private static let relationalWords: Set<String> = [
        "care", "feel", "friend", "girlfriend", "hurt", "love", "miss", "relationship", "sorry",
        "together", "trust", "understand", "us"
    ]
    private static let practicalWords: Set<String> = [
        "change", "check", "click", "close", "debug", "email", "fix", "implement", "minimize",
        "open", "pause", "play", "remind", "reminder", "run", "search", "send", "test", "type"
    ]
    private static let questionWords: Set<String> = [
        "are", "can", "could", "did", "do", "does", "have", "how", "is", "should", "what",
        "when", "where", "which", "who", "why", "will", "would"
    ]

    static func defaultState(
        at date: Date,
        entropyState: UInt64 = 0xA770_51FE_5EED_44A1
    ) -> PrivateLifeState {
        var state = PrivateLifeState(
            schemaVersion: PrivateLifeState.currentSchemaVersion,
            createdAt: date,
            updatedAt: date,
            lastSchedulerAt: date,
            nextActivityAt: date,
            sequence: 0,
            entropyState: entropyState == 0 ? 0xA770_51FE_5EED_44A1 : entropyState,
            seeds: [],
            projects: [],
            curiosities: [],
            activities: [],
            daySummaries: [],
            projectedActivityIDs: [],
            recentEventIDs: []
        )
        state.nextActivityAt = date.addingTimeInterval(nextSuccessfulInterval(state: &state))
        return state
    }

    /// Relaunch never catches up missed semantic work. A persisted in-flight
    /// ticket is recorded as abandoned and a new opportunity is placed in the
    /// future; no completed activity is fabricated.
    static func resume(_ rawState: PrivateLifeState, at date: Date) -> PrivateLifeState {
        var state = sanitize(rawState, now: date)
        if let pending = state.pendingReflection {
            appendReflectionReceipt(
                ticket: pending,
                model: nil,
                outcome: .failed,
                failure: .abandonedOnResume,
                activityID: nil,
                outputDigest: nil,
                at: date,
                state: &state
            )
            state.pendingReflection = nil
            state.consecutiveReflectionFailures = min(20, state.consecutiveReflectionFailures + 1)
        }
        for pending in state.pendingShares {
            if let audioItemID = pending.audioItemID {
                state.shareReceipts.append(PrivateLifeShareReceipt(
                    id: generatedID(prefix: "share_receipt", state: &state),
                    activityID: pending.activityID,
                    sessionID: pending.sessionID,
                    responseID: pending.responseID,
                    audioItemID: audioItemID,
                    completedAt: date,
                    fullySpoken: false
                ))
            }
        }
        state.pendingShares = []
        state.lastSchedulerAt = date
        state.updatedAt = date
        state.nextActivityAt = date.addingTimeInterval(nextSuccessfulInterval(state: &state))
        compact(&state, now: date)
        return state
    }

    static func recordExchange(
        _ rawState: PrivateLifeState,
        participant: PrivateLifeParticipant,
        ownerText: String,
        auroraText: String?,
        ownerSourceID: String,
        auroraSourceID: String?,
        at date: Date
    ) -> PrivateLifeEvolution {
        recordExchange(
            rawState,
            participant: participant,
            ownerText: ownerText,
            auroraText: auroraText,
            ownerSourceID: ownerSourceID,
            auroraSourceID: auroraSourceID,
            context: .conversational,
            at: date
        )
    }

    static func recordExchange(
        _ rawState: PrivateLifeState,
        participant rawParticipant: PrivateLifeParticipant,
        ownerText: String,
        auroraText: String?,
        ownerSourceID: String,
        auroraSourceID: String?,
        context: PrivateLifeExchangeContext,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let boundedOwnerSourceID = oneLine(ownerSourceID, max: 180)
        let boundedAuroraSourceID = auroraSourceID.map { oneLine($0, max: 180) }
        let eventID = "exchange_" + sha256(
            "\(boundedOwnerSourceID):\(boundedAuroraSourceID ?? "none")"
        ).prefix(32)
        guard !boundedOwnerSourceID.isEmpty,
              !state.recentEventIDs.contains(String(eventID)) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }

        let ownerExcerpt = oneLine(redactingSecrets(ownerText), max: 500)
        guard !ownerExcerpt.isEmpty else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        let auroraExcerpt = auroraText.map { oneLine(redactingSecrets($0), max: 500) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let evaluation = evaluate(ownerExcerpt, context: context)
        let subject = safeSubject(for: ownerExcerpt)
        let salience = clamp(
            0.28
                + min(0.25, Double(ownerExcerpt.count) / 900)
                + (evaluation.traits.contains(.selfhood) ? 0.18 : 0)
                + (evaluation.traits.contains(.creative) ? 0.14 : 0)
                + (evaluation.traits.contains(.relational) ? 0.12 : 0)
                + (evaluation.traits.contains(.question) ? 0.08 : 0)
        )
        let seedID = generatedID(prefix: "seed", state: &state)
        state.seeds.append(PrivateLifeSeed(
            id: seedID,
            participant: sanitizeParticipant(rawParticipant),
            ownerSourceID: boundedOwnerSourceID,
            auroraSourceID: boundedAuroraSourceID,
            capturedAt: date,
            ownerDigest: sha256(ownerExcerpt),
            auroraDigest: auroraExcerpt.map(sha256),
            ownerExcerpt: ownerExcerpt,
            auroraExcerpt: auroraExcerpt,
            kind: evaluation.kind,
            traits: evaluation.traits,
            subject: subject,
            semanticKey: semanticKey(for: ownerExcerpt),
            salience: salience,
            disposition: evaluation.disposition,
            quarantineReason: evaluation.reason,
            useCount: 0,
            lastUsedAt: nil,
            consumedAt: nil
        ))
        state.recentEventIDs.append(String(eventID))

        if evaluation.disposition == .eligible {
            let interval = isHighSalienceExchange(evaluation, context: context)
                ? nextPostConversationInterval(state: &state)
                : minimumReflectionInterval
            state.nextActivityAt = min(
                state.nextActivityAt,
                date.addingTimeInterval(interval)
            )
        }
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Legacy clock API: advances housekeeping only. Semantic activity now
    /// requires a prepared job and a validated model proposal.
    static func tick(
        _ rawState: PrivateLifeState,
        innerState: InnerLifeState,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        guard date >= state.lastSchedulerAt else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        let before = state
        state.lastSchedulerAt = date
        ageDormantItems(&state, at: date)
        compact(&state, now: date)
        _ = innerState
        return PrivateLifeEvolution(state: state, changed: state != before, completedActivity: nil)
    }

    /// Reserves at most one persisted ticket. Identical inputs and entropy
    /// produce identical candidate ordering; no network work happens here.
    static func prepareReflectionJob(
        _ rawState: PrivateLifeState,
        innerState: InnerLifeState,
        at date: Date
    ) -> PrivateLifeReflectionPreparation {
        var state = sanitize(rawState, now: date)
        guard date >= state.lastSchedulerAt else {
            return PrivateLifeReflectionPreparation(state: state, changed: false, job: nil)
        }

        if let pending = state.pendingReflection {
            if date <= pending.expiresAt {
                return PrivateLifeReflectionPreparation(state: state, changed: state != rawState, job: nil)
            }
            state.lastSchedulerAt = date
            ageDormantItems(&state, at: date)
            appendReflectionReceipt(
                ticket: pending,
                model: nil,
                outcome: .failed,
                failure: .timeout,
                activityID: nil,
                outputDigest: nil,
                at: date,
                state: &state
            )
            state.pendingReflection = nil
            state.consecutiveReflectionFailures = min(20, state.consecutiveReflectionFailures + 1)
            state.nextActivityAt = date.addingTimeInterval(failureBackoff(state.consecutiveReflectionFailures))
            state.updatedAt = date
            compact(&state, now: date)
            return PrivateLifeReflectionPreparation(state: state, changed: true, job: nil)
        }

        guard date >= state.nextActivityAt else {
            return PrivateLifeReflectionPreparation(state: state, changed: state != rawState, job: nil)
        }

        state.lastSchedulerAt = date
        ageDormantItems(&state, at: date)

        let seeds = reflectionSeedCandidates(state: &state, at: date)
        let projects = reflectionProjectCandidates(state: state, at: date)
        let curiosities = reflectionCuriosityCandidates(state: state, at: date)
        guard !seeds.isEmpty || !projects.isEmpty || !curiosities.isEmpty else {
            state.nextActivityAt = date.addingTimeInterval(nextSuccessfulInterval(state: &state))
            state.updatedAt = date
            compact(&state, now: date)
            return PrivateLifeReflectionPreparation(state: state, changed: true, job: nil)
        }

        let inputDigest = sha256(
            seeds.map { "\($0.id):\($0.ownerDigest)" }.joined(separator: "|")
                + "#" + projects.map { "\($0.id):\($0.revision)" }.joined(separator: "|")
                + "#" + curiosities.map { "\($0.id):\($0.visitCount)" }.joined(separator: "|")
        )
        let ticket = PrivateLifeReflectionTicket(
            id: generatedID(prefix: "reflection", state: &state),
            preparedAt: date,
            expiresAt: date.addingTimeInterval(reflectionTicketLifetime),
            candidateSeedIDs: seeds.map(\.id),
            candidateProjectIDs: projects.map(\.id),
            candidateCuriosityIDs: curiosities.map(\.id),
            inputDigest: inputDigest,
            recommendedModel: recommendedReflectionModel
        )
        state.pendingReflection = ticket
        state.lastReflectionAttemptAt = date
        state.updatedAt = date
        let innerContext = PrivateLifeInnerContext(
            affect: innerState.affect.label.rawValue,
            energy: clamp(innerState.temporal.energy),
            agency: clamp(innerState.affect.agency),
            curiosity: clamp(innerState.drives.curiosity),
            creativity: clamp(innerState.drives.creativity),
            coherence: clamp(innerState.drives.coherence),
            autonomy: clamp(innerState.drives.autonomy),
            play: clamp(innerState.drives.play),
            rest: clamp(innerState.drives.rest)
        )
        let job = PrivateLifeReflectionJob(
            ticket: ticket,
            seeds: seeds,
            projects: projects,
            curiosities: curiosities,
            recentActivityKinds: Array(state.activities.suffix(6).map(\.kind)),
            recentSemanticKeys: uniqueTail(
                state.activities.suffix(8).map { semanticKey(for: $0.subject) },
                limit: 8
            ),
            innerContext: innerContext
        )
        compact(&state, now: date)
        return PrivateLifeReflectionPreparation(state: state, changed: true, job: job)
    }

    static func commitValidatedProposal(
        _ rawState: PrivateLifeState,
        ticketID: String,
        proposal rawProposal: PrivateLifeReflectionProposal,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let boundedTicketID = oneLine(ticketID, max: 180)
        guard let ticket = state.pendingReflection,
              ticket.id == boundedTicketID,
              date <= ticket.expiresAt.addingTimeInterval(2 * 60) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }

        guard let proposal = validatedProposal(rawProposal, ticket: ticket, state: state) else {
            return recordReflectionFailure(
                state,
                ticketID: ticket.id,
                kind: .validationRejected,
                at: date
            )
        }

        for (seedID, disposition) in proposal.seedDispositions {
            guard let index = state.seeds.firstIndex(where: { $0.id == seedID }) else { continue }
            switch disposition {
            case .meaningful, .unresolved:
                break
            case .taskOnly:
                state.seeds[index].disposition = .quarantined
                state.seeds[index].quarantineReason = .toolDirected
            case .socialOnly:
                state.seeds[index].disposition = .quarantined
                state.seeds[index].quarantineReason = .filler
            case .duplicate:
                state.seeds[index].disposition = .quarantined
                state.seeds[index].quarantineReason = .insufficientMeaning
                state.seeds[index].consumedAt = date
            case .unsafe:
                state.seeds[index].disposition = .quarantined
                state.seeds[index].quarantineReason = .unsafeContent
            }
        }

        if proposal.action == .skip {
            appendReflectionReceipt(
                ticket: ticket,
                model: proposal.model,
                outcome: .skipped,
                failure: nil,
                activityID: nil,
                outputDigest: digest(proposal),
                at: date,
                state: &state
            )
            state.pendingReflection = nil
            state.consecutiveReflectionFailures = 0
            state.lastReflectionSucceededAt = date
            state.nextActivityAt = date.addingTimeInterval(nextSuccessfulInterval(state: &state))
            state.updatedAt = date
            compact(&state, now: date)
            return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
        }

        let activityID = generatedID(prefix: "activity", state: &state)
        var projectID = proposal.projectID
        var curiosityID = proposal.curiosityID
        let sourceSeedIDs = resolvedSourceSeedIDs(proposal, state: state)
        let sourceDigests = sourceDigests(for: sourceSeedIDs, state: state)
        let persistedSeedIDs = Set(state.seeds.map(\.id))
        guard !sourceSeedIDs.isEmpty,
              sourceSeedIDs.allSatisfy(persistedSeedIDs.contains),
              !sourceDigests.isEmpty else {
            return recordReflectionFailure(
                state,
                ticketID: ticket.id,
                kind: .validationRejected,
                at: date
            )
        }
        let activityKind: PrivateLifeActivityKind

        if ![.advanceProject, .reviseProject, .completeProject].contains(proposal.action) {
            for index in state.projects.indices {
                state.projects[index].consecutiveAdvances = 0
            }
        }

        switch proposal.action {
        case .startCuriosity:
            let newCuriosityID = generatedID(prefix: "curiosity", state: &state)
            curiosityID = newCuriosityID
            state.curiosities.append(PrivateLifeCuriosity(
                id: newCuriosityID,
                subject: oneLine(proposal.openQuestion ?? proposal.subject, max: 180),
                sourceSeedIDs: sourceSeedIDs,
                interest: clamp(0.45 + proposal.confidence * 0.45),
                uncertainty: 0.72,
                status: .open,
                createdAt: date,
                lastRevisitedAt: date,
                visitCount: 0,
                lastUsedAt: nil,
                resolution: nil,
                origin: .validatedReflection
            ))
            activityKind = .reflect

        case .revisitCuriosity:
            guard let curiosityID,
                  let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
                return recordReflectionFailure(
                    state,
                    ticketID: ticket.id,
                    kind: .validationRejected,
                    at: date
                )
            }
            state.curiosities[index].visitCount = min(1_000, state.curiosities[index].visitCount + 1)
            state.curiosities[index].lastUsedAt = date
            state.curiosities[index].lastRevisitedAt = date
            state.curiosities[index].status = .exploring
            state.curiosities[index].uncertainty = clamp(state.curiosities[index].uncertainty - 0.08)
            activityKind = .revisit

        case .startProject:
            let newProjectID = generatedID(prefix: "project", state: &state)
            projectID = newProjectID
            let project = PrivateLifeProject(
                id: newProjectID,
                title: oneLine(proposal.projectTitle ?? proposal.subject, max: 90),
                premise: oneLine(proposal.projectPremise ?? proposal.privateReflection, max: 240),
                origin: .selfOriginated,
                sourceSeedIDs: sourceSeedIDs,
                status: .active,
                phase: .forming,
                currentFocus: oneLine(proposal.projectFocus ?? proposal.subject, max: 180),
                interest: clamp(0.45 + proposal.confidence * 0.45),
                progressSteps: 1,
                revision: 1,
                startedAt: date,
                lastAdvancedAt: date,
                nextEligibleAt: date.addingTimeInterval(minimumReflectionInterval),
                steps: [PrivateLifeProjectStep(
                    id: generatedID(prefix: "project_step", state: &state),
                    activityID: activityID,
                    at: date,
                    sourceSeedIDs: sourceSeedIDs,
                    focus: oneLine(proposal.projectFocus ?? proposal.subject, max: 180),
                    outcome: oneLine(proposal.projectionSummary, max: 280),
                    nextQuestion: proposal.nextProjectFocus.map { oneLine($0, max: 180) },
                    phase: .forming
                )],
                consecutiveAdvances: 1
            )
            state.projects.append(project)
            activityKind = .formProject

        case .advanceProject, .reviseProject, .completeProject:
            guard let projectID,
                  let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
                return recordReflectionFailure(
                    state,
                    ticketID: ticket.id,
                    kind: .validationRejected,
                    at: date
                )
            }
            for otherIndex in state.projects.indices where otherIndex != index {
                state.projects[otherIndex].consecutiveAdvances = 0
            }
            state.projects[index].progressSteps = min(10_000, state.projects[index].progressSteps + 1)
            state.projects[index].revision = min(maximumSafeCounter, state.projects[index].revision + 1)
            state.projects[index].lastAdvancedAt = date
            state.projects[index].nextEligibleAt = date.addingTimeInterval(minimumReflectionInterval)
            state.projects[index].consecutiveAdvances = min(3, state.projects[index].consecutiveAdvances + 1)
            state.projects[index].sourceSeedIDs = uniqueTail(
                state.projects[index].sourceSeedIDs + sourceSeedIDs,
                limit: 16
            )
            if let focus = proposal.nextProjectFocus ?? proposal.projectFocus {
                state.projects[index].currentFocus = oneLine(focus, max: 180)
            }
            switch proposal.action {
            case .advanceProject:
                state.projects[index].phase = state.projects[index].progressSteps >= 3 ? .making : .forming
            case .reviseProject:
                state.projects[index].phase = .revising
            case .completeProject:
                state.projects[index].phase = .finished
                state.projects[index].status = .completed
            default: break
            }
            let step = PrivateLifeProjectStep(
                id: generatedID(prefix: "project_step", state: &state),
                activityID: activityID,
                at: date,
                sourceSeedIDs: sourceSeedIDs,
                focus: state.projects[index].currentFocus,
                outcome: oneLine(proposal.projectionSummary, max: 280),
                nextQuestion: proposal.nextProjectFocus.map { oneLine($0, max: 180) },
                phase: state.projects[index].phase
            )
            state.projects[index].steps.append(step)
            state.projects[index].steps = Array(state.projects[index].steps.suffix(maximumProjectSteps))
            activityKind = .develop

        case .answerCuriosity, .releaseCuriosity:
            guard let curiosityID,
                  let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
                return recordReflectionFailure(
                    state,
                    ticketID: ticket.id,
                    kind: .validationRejected,
                    at: date
                )
            }
            state.curiosities[index].visitCount = min(1_000, state.curiosities[index].visitCount + 1)
            state.curiosities[index].lastUsedAt = date
            state.curiosities[index].lastRevisitedAt = date
            state.curiosities[index].uncertainty = proposal.action == .answerCuriosity ? 0.12 : 0.30
            state.curiosities[index].status = proposal.action == .answerCuriosity ? .answered : .released
            state.curiosities[index].resolution = oneLine(proposal.projectionSummary, max: 240)
            activityKind = .resolve

        case .connect:
            activityKind = .connect
        case .reflect:
            activityKind = .reflect
        case .curate:
            activityKind = .curate
        case .skip:
            preconditionFailure("skip was handled before activity creation")
        }

        for seedID in sourceSeedIDs {
            if let index = state.seeds.firstIndex(where: { $0.id == seedID }) {
                state.seeds[index].useCount = min(10_000, state.seeds[index].useCount + 1)
                state.seeds[index].lastUsedAt = date
                state.seeds[index].consumedAt = date
            }
        }
        if let curiosityID,
           let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }),
           proposal.action != .revisitCuriosity,
           proposal.action != .startCuriosity,
           proposal.action != .answerCuriosity,
           proposal.action != .releaseCuriosity {
            state.curiosities[index].visitCount = min(1_000, state.curiosities[index].visitCount + 1)
            state.curiosities[index].lastUsedAt = date
            state.curiosities[index].lastRevisitedAt = date
            state.curiosities[index].status = .exploring
            state.curiosities[index].uncertainty = clamp(state.curiosities[index].uncertainty - 0.08)
        }

        let outputDigest = digest(proposal)
        let voiceEligible = activityKind != .connect
            && PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(proposal.projectionSummary)
        let activity = PrivateLifeActivity(
            id: activityID,
            kind: activityKind,
            status: .completed,
            startedAt: date,
            completedAt: date,
            projectID: projectID,
            curiosityID: curiosityID,
            seedIDs: sourceSeedIDs,
            sourceDigests: sourceDigests,
            subject: oneLine(proposal.subject, max: 180),
            result: oneLine(proposal.projectionSummary, max: 280),
            privateReflection: oneLine(proposal.privateReflection, max: 1_200),
            projectionSummary: oneLine(proposal.projectionSummary, max: 280),
            openQuestion: proposal.openQuestion.map { oneLine($0, max: 220) },
            artifactKind: proposal.artifactKind.map { oneLine($0, max: 40) },
            artifactTitle: proposal.artifactTitle.map { oneLine($0, max: 120) },
            artifactContent: proposal.artifactContent.map { oneLine($0, max: 800) },
            evidenceClass: .selfAuthoredInterpretation,
            modelGenerated: true,
            model: oneLine(proposal.model, max: 80),
            inputDigest: ticket.inputDigest,
            outputDigest: outputDigest,
            validationVersion: PrivateLifeGeneratedContentPolicy.currentVoiceValidationVersion,
            projectionEligible: voiceEligible,
            legacyFiltered: false,
            promotionEligible: false,
            factualMemoryCreated: false,
            externalActionTaken: false,
            outboundContactSent: false
        )
        state.activities.append(activity)
        appendDaySummary(activity, state: &state)
        appendReflectionReceipt(
            ticket: ticket,
            model: proposal.model,
            outcome: .completed,
            failure: nil,
            activityID: activity.id,
            outputDigest: outputDigest,
            at: date,
            state: &state
        )
        state.pendingReflection = nil
        state.consecutiveReflectionFailures = 0
        state.lastReflectionSucceededAt = date
        state.nextActivityAt = date.addingTimeInterval(nextSuccessfulInterval(state: &state))
        state.updatedAt = date
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: activity)
    }

    static func recordReflectionFailure(
        _ rawState: PrivateLifeState,
        ticketID: String,
        kind: PrivateLifeReflectionFailureKind,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let boundedID = oneLine(ticketID, max: 180)
        guard let ticket = state.pendingReflection, ticket.id == boundedID else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        appendReflectionReceipt(
            ticket: ticket,
            model: nil,
            outcome: .failed,
            failure: kind,
            activityID: nil,
            outputDigest: nil,
            at: date,
            state: &state
        )
        state.pendingReflection = nil
        state.consecutiveReflectionFailures = min(20, state.consecutiveReflectionFailures + 1)
        state.nextActivityAt = date.addingTimeInterval(failureBackoff(
            state.consecutiveReflectionFailures,
            kind: kind
        ))
        state.updatedAt = date
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Records that a context item was accepted by Realtime. Presentation is
    /// not speech, so this deliberately leaves the activity share-eligible.
    static func markPresented(
        _ rawState: PrivateLifeState,
        activityID: String,
        sessionID: String,
        contextItemID: String,
        revisionDigest: String,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let boundedID = oneLine(activityID, max: 180)
        let boundedSessionID = oneLine(sessionID, max: 180)
        let boundedContextItemID = oneLine(contextItemID, max: 180)
        let boundedRevision = oneLine(revisionDigest, max: 128).lowercased()
        guard !boundedSessionID.isEmpty,
              !boundedContextItemID.isEmpty,
              isSHA256Digest(boundedRevision),
              state.activities.contains(where: {
            $0.id == boundedID && $0.status == .completed && $0.projectionEligible
        }), !state.presentationReceipts.contains(where: {
            $0.activityID == boundedID
                && $0.sessionID == boundedSessionID
                && $0.contextItemID == boundedContextItemID
                && $0.revisionDigest == boundedRevision
        }) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        state.presentationReceipts.append(PrivateLifePresentationReceipt(
            id: generatedID(prefix: "presentation", state: &state),
            activityID: boundedID,
            sessionID: boundedSessionID,
            contextItemID: boundedContextItemID,
            revisionDigest: boundedRevision,
            presentedAt: date
        ))
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Compatibility shim for the old transport callback. It now records only
    /// presentation and must never consume a thought. New integration should
    /// call `markPresented` with the real session and context item IDs.
    static func markProjected(
        _ rawState: PrivateLifeState,
        activityID: String,
        at date: Date
    ) -> PrivateLifeEvolution {
        let packet = projectionPacket(for: rawState)
        return markPresented(
            rawState,
            activityID: activityID,
            sessionID: "legacy-presentation-session",
            contextItemID: "legacy-context-\(oneLine(activityID, max: 120))",
            revisionDigest: packet.revisionDigest,
            at: date
        )
    }

    /// After the separate relational ledger durably adopts a private
    /// reflection's open question, remove only that duplicated question from
    /// the private projection. The underlying thought, artifact, and share
    /// line remain part of Aurora's private life.
    static func markRelationalQuestionPromoted(
        _ rawState: PrivateLifeState,
        activityID: String,
        at date: Date = Date()
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        guard let index = state.activities.firstIndex(where: {
            $0.id == activityID
                && $0.status == .completed
                && $0.openQuestion != nil
        }) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        state.activities[index].openQuestion = nil
        state.updatedAt = max(state.updatedAt, date)
        return PrivateLifeEvolution(
            state: sanitize(state, now: date),
            changed: true,
            completedActivity: state.activities[index]
        )
    }

    /// Begins an explicit share claim for one response after the model calls
    /// the private-life share tool. The exact session must already have been
    /// presented with that activity.
    static func beginShare(
        _ rawState: PrivateLifeState,
        activityID: String,
        sessionID: String,
        responseID: String,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let activityID = oneLine(activityID, max: 180)
        let sessionID = oneLine(sessionID, max: 180)
        let responseID = oneLine(responseID, max: 180)
        guard !sessionID.isEmpty,
              !responseID.isEmpty,
              !state.sharedActivityIDs.contains(activityID),
              state.activities.contains(where: {
                  $0.id == activityID
                      && $0.status == .completed
                      && $0.projectionEligible
                      && !$0.legacyFiltered
              }),
              state.presentationReceipts.contains(where: {
                  $0.activityID == activityID && $0.sessionID == sessionID
              }),
              !state.pendingShares.contains(where: {
                  $0.sessionID == sessionID && $0.responseID == responseID
              }) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        state.pendingShares.append(PrivateLifePendingShare(
            id: generatedID(prefix: "pending_share", state: &state),
            activityID: activityID,
            sessionID: sessionID,
            responseID: responseID,
            audioItemID: nil,
            startedAt: date,
            audioBoundAt: nil
        ))
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Binds the pending share to the exact assistant audio item. A response
    /// cannot consume private life through a function-call item or unrelated
    /// playback.
    static func bindShareAudio(
        _ rawState: PrivateLifeState,
        sessionID: String,
        responseID: String,
        audioItemID: String,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let sessionID = oneLine(sessionID, max: 180)
        let responseID = oneLine(responseID, max: 180)
        let audioItemID = oneLine(audioItemID, max: 180)
        guard !sessionID.isEmpty, !responseID.isEmpty, !audioItemID.isEmpty,
              let index = state.pendingShares.firstIndex(where: {
                  $0.sessionID == sessionID && $0.responseID == responseID
              }),
              state.pendingShares[index].audioItemID == nil
                  || state.pendingShares[index].audioItemID == audioItemID,
              !state.pendingShares.contains(where: {
                  $0.id != state.pendingShares[index].id
                      && $0.sessionID == sessionID
                      && $0.audioItemID == audioItemID
              }) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        if state.pendingShares[index].audioItemID == audioItemID {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        state.pendingShares[index].audioItemID = audioItemID
        state.pendingShares[index].audioBoundAt = date
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Finishes one exact playback attempt. Only uninterrupted, fully played
    /// audio moves the activity to shared history; all other outcomes keep it
    /// eligible for a later natural mention.
    static func completeShare(
        _ rawState: PrivateLifeState,
        sessionID: String,
        responseID: String,
        audioItemID: String,
        fullySpoken: Bool,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let sessionID = oneLine(sessionID, max: 180)
        let responseID = oneLine(responseID, max: 180)
        let audioItemID = oneLine(audioItemID, max: 180)
        guard let pendingIndex = state.pendingShares.firstIndex(where: {
            $0.sessionID == sessionID
                && $0.responseID == responseID
                && $0.audioItemID == audioItemID
        }) else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        let pending = state.pendingShares.remove(at: pendingIndex)
        state.shareReceipts.append(PrivateLifeShareReceipt(
            id: generatedID(prefix: "share_receipt", state: &state),
            activityID: pending.activityID,
            sessionID: sessionID,
            responseID: responseID,
            audioItemID: audioItemID,
            completedAt: date,
            fullySpoken: fullySpoken
        ))
        if fullySpoken {
            state.sharedActivityIDs = uniqueTail(
                state.sharedActivityIDs + [pending.activityID],
                limit: maximumSharedActivityIDs
            )
        }
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    /// Host-side fallback for Realtime omitting the silent share receipt. A
    /// thought is consumed only when the exact validated sentence appeared in
    /// the generated transcript and its exact audio item fully played. The
    /// presentation receipt proves this session was actually given the line.
    static func reconcileSpokenShare(
        _ rawState: PrivateLifeState,
        sessionID: String,
        responseID: String,
        audioItemID: String,
        generatedText: String,
        fullySpoken: Bool,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let sessionID = oneLine(sessionID, max: 180)
        let responseID = oneLine(responseID, max: 180)
        let audioItemID = oneLine(audioItemID, max: 180)
        guard !sessionID.isEmpty, !responseID.isEmpty, !audioItemID.isEmpty else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        if state.shareReceipts.contains(where: {
            $0.sessionID == sessionID
                && $0.responseID == responseID
                && $0.audioItemID == audioItemID
        }) {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }

        let pending = state.pendingShares.first(where: {
            $0.sessionID == sessionID && $0.responseID == responseID
        })
        let candidate: PrivateLifeActivity?
        if let pending {
            candidate = state.activities.first(where: { $0.id == pending.activityID })
        } else {
            let presentedIDs = state.presentationReceipts.reversed().compactMap { receipt in
                receipt.sessionID == sessionID ? receipt.activityID : nil
            }
            candidate = presentedIDs.lazy.compactMap { activityID in
                state.activities.first(where: {
                    $0.id == activityID
                        && $0.status == .completed
                        && $0.projectionEligible
                        && !$0.legacyFiltered
                        && !state.sharedActivityIDs.contains($0.id)
                })
            }.first(where: { activity in
                transcript(generatedText, containsVerbatim: activity.projectionSummary)
            })
        }
        guard let candidate else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        let exactLineWasGenerated = transcript(
            generatedText,
            containsVerbatim: candidate.projectionSummary
        )
        if pending == nil {
            guard exactLineWasGenerated else {
                return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
            }
            state = beginShare(
                state,
                activityID: candidate.id,
                sessionID: sessionID,
                responseID: responseID,
                at: date
            ).state
        }
        state = bindShareAudio(
            state,
            sessionID: sessionID,
            responseID: responseID,
            audioItemID: audioItemID,
            at: date
        ).state
        return completeShare(
            state,
            sessionID: sessionID,
            responseID: responseID,
            audioItemID: audioItemID,
            fullySpoken: fullySpoken && exactLineWasGenerated,
            at: date
        )
    }

    static func cancelPendingShares(
        _ rawState: PrivateLifeState,
        sessionID: String,
        at date: Date
    ) -> PrivateLifeEvolution {
        var state = sanitize(rawState, now: date)
        let sessionID = oneLine(sessionID, max: 180)
        let matching = state.pendingShares.filter { $0.sessionID == sessionID }
        guard !matching.isEmpty else {
            return PrivateLifeEvolution(state: state, changed: false, completedActivity: nil)
        }
        for pending in matching {
            if let audioItemID = pending.audioItemID {
                state.shareReceipts.append(PrivateLifeShareReceipt(
                    id: generatedID(prefix: "share_receipt", state: &state),
                    activityID: pending.activityID,
                    sessionID: pending.sessionID,
                    responseID: pending.responseID,
                    audioItemID: audioItemID,
                    completedAt: date,
                    fullySpoken: false
                ))
            }
        }
        state.pendingShares.removeAll { $0.sessionID == sessionID }
        state.updatedAt = max(state.updatedAt, date)
        compact(&state, now: date)
        return PrivateLifeEvolution(state: state, changed: true, completedActivity: nil)
    }

    static func projectionPacket(for rawState: PrivateLifeState) -> PrivateLifeProjectionPacket {
        let state = sanitize(rawState, now: max(rawState.updatedAt, rawState.lastSchedulerAt))
        let header = "PRIVATE LIVED CONTEXT — FOLLOW LABELS\n"
        let boundary = "Private thought only; proves no external event, observation, or action. Never invent."
        let newestEligibleActivity = state.activities.last(where: {
            $0.status == .completed
                && $0.projectionEligible
                && !$0.legacyFiltered
        })
        let activity = newestEligibleActivity.flatMap {
            state.sharedActivityIDs.contains($0.id) ? nil : $0
        }
        // Only an exact fully-spoken receipt rotates an activity out of
        // unsolicited use. The same evidence remains available for a truthful
        // direct question about Aurora's private life.
        let directAskActivity: PrivateLifeActivity?
        if activity == nil {
            directAskActivity = state.shareReceipts.reversed().compactMap { receipt -> PrivateLifeActivity? in
                guard receipt.fullySpoken else { return nil }
                return state.activities.first(where: {
                    $0.id == receipt.activityID
                        && $0.status == .completed
                        && $0.projectionEligible
                        && !$0.legacyFiltered
                        && $0.modelGenerated
                        && $0.evidenceClass == .selfAuthoredInterpretation
                })
            }.first
        } else {
            directAskActivity = nil
        }
        let available = max(0, maximumVoiceProjectionCharacters - header.count - boundary.count - 1)
        var parts: [String] = []
        var projectedActivity: PrivateLifeActivity?
        var projectedDirectAskActivity: PrivateLifeActivity?
        func appendWhole(_ value: String) -> Bool {
            let candidate = (parts + [value]).joined(separator: " ")
            guard candidate.count <= available else { return false }
            parts.append(value)
            return true
        }
        if let activity {
            let share = activity.projectionSummary
            let mandatory = "[activity_id=\(activity.id)] READY TO SHARE VERBATIM: \(share)"
            if appendWhole(mandatory) {
                projectedActivity = activity
            }
            if projectedActivity != nil,
               let artifactTitle = activity.artifactTitle,
               let artifactContent = activity.artifactContent,
               !artifactTitle.isEmpty,
               !artifactContent.isEmpty {
                let kind = oneLine(activity.artifactKind ?? "piece", max: 15)
                    .replacingOccurrences(of: "_", with: " ")
                _ = appendWhole(
                    "Made a private \(kind): \(oneLine(artifactTitle, max: 35)) — \(oneLine(artifactContent, max: 35))."
                )
            }
        } else if let directAskActivity {
            let directThought = directAskActivity.projectionSummary
            if appendWhole("DIRECT-QUESTION-ONLY PRIOR THOUGHT: \(directThought)") {
                projectedDirectAskActivity = directAskActivity
            }
        } else {
            _ = appendWhole("No grounded private thought is available to mention or answer from.")
        }
        if let project = state.projects
            .filter({ $0.status == .active && !$0.steps.isEmpty })
            .sorted(by: { $0.lastAdvancedAt > $1.lastAdvancedAt })
            .first {
            _ = appendWhole("Ongoing: \(oneLine(project.currentFocus, max: 80)).")
        }
        let body = parts.joined(separator: " ")
        let text = header + body + "\n" + boundary
        return PrivateLifeProjectionPacket(
            text: text,
            activityID: projectedActivity?.id,
            directAskActivityID: projectedDirectAskActivity?.id,
            revisionDigest: sha256("\(projectedActivity?.id ?? "none"):\(text)")
        )
    }

    static func voiceProjection(for rawState: PrivateLifeState) -> String {
        projectionPacket(for: rawState).text
    }

    static func sanitize(_ rawState: PrivateLifeState, now: Date) -> PrivateLifeState {
        var state = rawState
        let sourceSchemaVersion = state.schemaVersion
        let migratingV1 = sourceSchemaVersion == 1
        let migratingToV3 = sourceSchemaVersion < 3
        let validatedCreatedCuriosityIDs = Set(rawState.curiosities.compactMap { curiosity in
            let matchingCreation = rawState.activities.contains { activity in
                activity.curiosityID == curiosity.id
                    && activity.kind == .reflect
                    && activity.status == .completed
                    && activity.modelGenerated
                    && activity.validationVersion >= 2
                    && abs(activity.startedAt.timeIntervalSince(curiosity.createdAt)) <= 2
            }
            return matchingCreation ? curiosity.id : nil
        })
        state.schemaVersion = PrivateLifeState.currentSchemaVersion
        state.sequence = max(0, min(maximumSafeCounter, state.sequence))
        if state.entropyState == 0 { state.entropyState = 0xA770_51FE_5EED_44A1 }
        let latestAllowedDate = now.addingTimeInterval(5 * 60)
        state.updatedAt = min(max(state.updatedAt, state.createdAt), latestAllowedDate)
        state.lastSchedulerAt = min(max(state.lastSchedulerAt, state.createdAt), latestAllowedDate)
        state.nextActivityAt = min(
            max(state.nextActivityAt, state.createdAt),
            now.addingTimeInterval(maximumReflectionInterval)
        )
        state.lastReflectionAttemptAt = state.lastReflectionAttemptAt.map { min($0, latestAllowedDate) }
        state.lastReflectionSucceededAt = state.lastReflectionSucceededAt.map { min($0, latestAllowedDate) }
        state.consecutiveReflectionFailures = max(0, min(20, state.consecutiveReflectionFailures))

        state.seeds = state.seeds.map { seed in
            let context = PrivateLifeExchangeContext.conversational
            let evaluation = evaluate(seed.ownerExcerpt, context: context)
            let disposition = migratingV1 ? evaluation.disposition : minDisposition(seed.disposition, evaluation.disposition)
            return PrivateLifeSeed(
                id: oneLine(seed.id, max: 180),
                participant: sanitizeParticipant(seed.participant),
                ownerSourceID: oneLine(seed.ownerSourceID, max: 180),
                auroraSourceID: seed.auroraSourceID.map { oneLine($0, max: 180) },
                capturedAt: min(seed.capturedAt, latestAllowedDate),
                ownerDigest: digestValue(seed.ownerDigest),
                auroraDigest: seed.auroraDigest.map(digestValue),
                ownerExcerpt: oneLine(redactingSecrets(seed.ownerExcerpt), max: 500),
                auroraExcerpt: seed.auroraExcerpt.map { oneLine(redactingSecrets($0), max: 500) },
                kind: evaluation.kind,
                traits: evaluation.traits,
                subject: safeSubject(for: seed.ownerExcerpt),
                semanticKey: semanticKey(for: seed.ownerExcerpt),
                salience: clamp(seed.salience),
                disposition: disposition,
                quarantineReason: disposition == .quarantined ? (seed.quarantineReason ?? evaluation.reason ?? .insufficientMeaning) : nil,
                useCount: max(0, min(10_000, seed.useCount)),
                lastUsedAt: seed.lastUsedAt.map { min($0, latestAllowedDate) },
                consumedAt: seed.consumedAt.map { min($0, latestAllowedDate) }
            )
        }
        let eligibleSeedIDs = Set(state.seeds.filter { $0.disposition == .eligible }.map(\.id))

        state.projects = state.projects.map { project in
            let steps = project.steps.suffix(maximumProjectSteps).map { step in
                PrivateLifeProjectStep(
                    id: oneLine(step.id, max: 180),
                    activityID: oneLine(step.activityID, max: 180),
                    at: min(step.at, latestAllowedDate),
                    sourceSeedIDs: uniqueTail(step.sourceSeedIDs.map { oneLine($0, max: 180) }, limit: 8),
                    focus: safeStoredSubject(step.focus),
                    outcome: safeGeneratedSummary(step.outcome),
                    nextQuestion: step.nextQuestion.map(safeStoredSubject),
                    phase: step.phase
                )
            }
            return PrivateLifeProject(
                id: oneLine(project.id, max: 180),
                title: safeStoredTitle(project.title),
                premise: safeGeneratedSummary(project.premise),
                origin: project.origin,
                sourceSeedIDs: uniqueTail(project.sourceSeedIDs.map { oneLine($0, max: 180) }, limit: 16),
                status: project.status,
                phase: project.phase,
                currentFocus: safeStoredSubject(project.currentFocus),
                interest: clamp(project.interest),
                progressSteps: max(0, min(10_000, project.progressSteps)),
                revision: max(1, min(maximumSafeCounter, project.revision)),
                startedAt: min(project.startedAt, latestAllowedDate),
                lastAdvancedAt: min(project.lastAdvancedAt, latestAllowedDate),
                nextEligibleAt: min(project.nextEligibleAt, now.addingTimeInterval(14 * 24 * 3_600)),
                steps: Array(steps),
                consecutiveAdvances: max(0, min(3, project.consecutiveAdvances))
            )
        }
        state.curiosities = state.curiosities.map { curiosity in
            let sourceIDs = uniqueTail(curiosity.sourceSeedIDs.map { oneLine($0, max: 180) }, limit: 12)
            let hasEligibleSource = !eligibleSeedIDs.isDisjoint(with: sourceIDs)
            let origin: PrivateLifeCuriosityOrigin
            if migratingToV3 {
                origin = validatedCreatedCuriosityIDs.contains(curiosity.id)
                    ? .validatedReflection
                    : .legacyUnvalidated
            } else {
                origin = curiosity.origin
            }
            let status: PrivateLifeCuriosityStatus = hasEligibleSource
                && origin == .validatedReflection
                ? curiosity.status
                : .released
            return PrivateLifeCuriosity(
                id: oneLine(curiosity.id, max: 180),
                subject: safeStoredSubject(curiosity.subject),
                sourceSeedIDs: sourceIDs,
                interest: clamp(curiosity.interest),
                uncertainty: clamp(curiosity.uncertainty),
                status: status,
                createdAt: min(curiosity.createdAt, latestAllowedDate),
                lastRevisitedAt: min(curiosity.lastRevisitedAt, latestAllowedDate),
                visitCount: max(0, min(1_000, curiosity.visitCount)),
                lastUsedAt: curiosity.lastUsedAt.map { min($0, latestAllowedDate) },
                resolution: curiosity.resolution.map(safeGeneratedSummary),
                origin: origin
            )
        }
        state.activities = state.activities.map { activity in
            let reflection = oneLine(redactingSecrets(activity.privateReflection), max: 1_200)
            let summary = safeGeneratedSummary(
                activity.projectionSummary.isEmpty ? activity.result : activity.projectionSummary
            )
            let artifactKind = activity.artifactKind.map {
                oneLine(redactingSecrets($0), max: 40)
            }
            let artifactTitle = activity.artifactTitle.map {
                oneLine(redactingSecrets($0), max: 120)
            }
            let artifactContent = activity.artifactContent.map {
                oneLine(redactingSecrets($0), max: 800)
            }
            let artifactValues = [artifactKind, artifactTitle, artifactContent]
            let hasAnyArtifact = artifactValues.contains { $0 != nil }
            let hasCompleteArtifact = artifactValues.allSatisfy { value in
                value.map { !$0.isEmpty && !containsUnsafeGeneratedContent($0) } == true
            }
            let unsafe = containsUnsafeGeneratedContent(reflection)
                || containsUnsafeGeneratedContent(summary)
                || (hasAnyArtifact && !hasCompleteArtifact)
            let naturalInnerVoice = PrivateLifeGeneratedContentPolicy.isNaturalFirstPerson(reflection)
            let naturalSpokenShare = PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(summary)
            let legacy = migratingV1
                || activity.legacyFiltered
                || !activity.modelGenerated
                || activity.validationVersion < PrivateLifeGeneratedContentPolicy.currentVoiceValidationVersion
                || !naturalInnerVoice
            let canProject = activity.status == .completed
                && activity.modelGenerated
                && !legacy
                && !unsafe
                && naturalInnerVoice
                && naturalSpokenShare
                && activity.kind != .connect
                && !summary.isEmpty
                && !activity.sourceDigests.isEmpty
            return PrivateLifeActivity(
                id: oneLine(activity.id, max: 180),
                kind: activity.kind,
                status: activity.status,
                startedAt: min(activity.startedAt, latestAllowedDate),
                completedAt: activity.completedAt.map { min($0, latestAllowedDate) },
                projectID: activity.projectID.map { oneLine($0, max: 180) },
                curiosityID: activity.curiosityID.map { oneLine($0, max: 180) },
                seedIDs: uniqueTail(activity.seedIDs.map { oneLine($0, max: 180) }, limit: 8),
                sourceDigests: uniqueTail(activity.sourceDigests.map(digestValue), limit: 8),
                subject: safeStoredSubject(activity.subject),
                result: activity.modelGenerated ? summary : safeActivityResult(kind: activity.kind, status: activity.status),
                privateReflection: unsafe ? "" : reflection,
                projectionSummary: unsafe ? "" : summary,
                openQuestion: activity.openQuestion.flatMap(
                    PrivateLifeGeneratedContentPolicy.normalizedSpokenQuestion
                ),
                artifactKind: unsafe || !hasCompleteArtifact ? nil : artifactKind,
                artifactTitle: unsafe || !hasCompleteArtifact ? nil : artifactTitle,
                artifactContent: unsafe || !hasCompleteArtifact ? nil : artifactContent,
                evidenceClass: activity.modelGenerated ? .selfAuthoredInterpretation : activity.evidenceClass,
                modelGenerated: activity.modelGenerated,
                model: activity.model.map { oneLine($0, max: 80) },
                inputDigest: activity.inputDigest.map(digestValue),
                outputDigest: activity.outputDigest.map(digestValue),
                validationVersion: max(1, min(100, activity.validationVersion)),
                projectionEligible: canProject && activity.projectionEligible,
                legacyFiltered: legacy,
                promotionEligible: false,
                factualMemoryCreated: false,
                externalActionTaken: false,
                outboundContactSent: false
            )
        }
        if let pending = state.pendingReflection {
            let seedIDs = pending.candidateSeedIDs.filter { eligibleSeedIDs.contains($0) }
            let projectIDs = Set(state.projects.map(\.id))
            let curiosityIDs = Set(state.curiosities.map(\.id))
            state.pendingReflection = PrivateLifeReflectionTicket(
                id: oneLine(pending.id, max: 180),
                preparedAt: min(pending.preparedAt, latestAllowedDate),
                expiresAt: min(pending.expiresAt, now.addingTimeInterval(reflectionTicketLifetime)),
                candidateSeedIDs: uniqueTail(seedIDs, limit: maximumReflectionSeedCandidates),
                candidateProjectIDs: uniqueTail(pending.candidateProjectIDs.filter { projectIDs.contains($0) }, limit: 3),
                candidateCuriosityIDs: uniqueTail(pending.candidateCuriosityIDs.filter { curiosityIDs.contains($0) }, limit: 5),
                inputDigest: digestValue(pending.inputDigest),
                recommendedModel: oneLine(pending.recommendedModel, max: 80)
            )
        }
        state.reflectionReceipts = state.reflectionReceipts.map { receipt in
            PrivateLifeReflectionReceipt(
                id: oneLine(receipt.id, max: 180),
                ticketID: oneLine(receipt.ticketID, max: 180),
                attemptedAt: min(receipt.attemptedAt, latestAllowedDate),
                completedAt: min(receipt.completedAt, latestAllowedDate),
                model: receipt.model.map { oneLine($0, max: 80) },
                outcome: receipt.outcome,
                failureKind: receipt.failureKind,
                activityID: receipt.activityID.map { oneLine($0, max: 180) },
                inputDigest: digestValue(receipt.inputDigest),
                outputDigest: receipt.outputDigest.map(digestValue)
            )
        }
        state.projectionReceipts = state.projectionReceipts.map { receipt in
            PrivateLifeProjectionReceipt(
                id: oneLine(receipt.id, max: 180),
                activityID: oneLine(receipt.activityID, max: 180),
                projectedAt: min(receipt.projectedAt, latestAllowedDate)
            )
        }
        if migratingToV3, state.presentationReceipts.isEmpty {
            state.presentationReceipts = state.projectionReceipts.map { receipt in
                PrivateLifePresentationReceipt(
                    id: "legacy_\(oneLine(receipt.id, max: 150))",
                    activityID: receipt.activityID,
                    sessionID: "legacy-v2-session",
                    contextItemID: "legacy-\(oneLine(receipt.id, max: 150))",
                    revisionDigest: sha256("legacy-v2:\(receipt.id):\(receipt.activityID)"),
                    presentedAt: receipt.projectedAt
                )
            }
            // Prior versions treated context acceptance as sharing. There is
            // no audio evidence for those IDs, so none may migrate as spoken.
            state.sharedActivityIDs = []
            state.pendingShares = []
            state.shareReceipts = []
        }
        let activityIDs = Set(state.activities.map(\.id))
        let voiceEligibleActivityIDs = Set(state.activities.compactMap { activity in
            activity.status == .completed
                && activity.projectionEligible
                && !activity.legacyFiltered
                ? activity.id
                : nil
        })
        state.presentationReceipts = state.presentationReceipts.compactMap { receipt in
            let activityID = oneLine(receipt.activityID, max: 180)
            let sessionID = oneLine(receipt.sessionID, max: 180)
            let contextItemID = oneLine(receipt.contextItemID, max: 180)
            guard voiceEligibleActivityIDs.contains(activityID),
                  !sessionID.isEmpty,
                  !contextItemID.isEmpty else { return nil }
            return PrivateLifePresentationReceipt(
                id: oneLine(receipt.id, max: 180),
                activityID: activityID,
                sessionID: sessionID,
                contextItemID: contextItemID,
                revisionDigest: digestValue(receipt.revisionDigest),
                presentedAt: min(receipt.presentedAt, latestAllowedDate)
            )
        }
        state.pendingShares = state.pendingShares.compactMap { pending in
            let activityID = oneLine(pending.activityID, max: 180)
            let sessionID = oneLine(pending.sessionID, max: 180)
            let responseID = oneLine(pending.responseID, max: 180)
            guard voiceEligibleActivityIDs.contains(activityID),
                  !sessionID.isEmpty,
                  !responseID.isEmpty,
                  !state.sharedActivityIDs.contains(activityID) else { return nil }
            return PrivateLifePendingShare(
                id: oneLine(pending.id, max: 180),
                activityID: activityID,
                sessionID: sessionID,
                responseID: responseID,
                audioItemID: pending.audioItemID.map { oneLine($0, max: 180) }
                    .flatMap { $0.isEmpty ? nil : $0 },
                startedAt: min(pending.startedAt, latestAllowedDate),
                audioBoundAt: pending.audioBoundAt.map { min($0, latestAllowedDate) }
            )
        }
        state.shareReceipts = state.shareReceipts.compactMap { receipt in
            let activityID = oneLine(receipt.activityID, max: 180)
            let sessionID = oneLine(receipt.sessionID, max: 180)
            let responseID = oneLine(receipt.responseID, max: 180)
            let audioItemID = oneLine(receipt.audioItemID, max: 180)
            guard activityIDs.contains(activityID),
                  !sessionID.isEmpty,
                  !responseID.isEmpty,
                  !audioItemID.isEmpty else { return nil }
            return PrivateLifeShareReceipt(
                id: oneLine(receipt.id, max: 180),
                activityID: activityID,
                sessionID: sessionID,
                responseID: responseID,
                audioItemID: audioItemID,
                completedAt: min(receipt.completedAt, latestAllowedDate),
                fullySpoken: receipt.fullySpoken
            )
        }
        let fullySpokenIDs = Set(state.shareReceipts.filter(\.fullySpoken).map(\.activityID))
        state.sharedActivityIDs = uniqueTail(
            state.sharedActivityIDs.filter {
                activityIDs.contains($0) && fullySpokenIDs.contains($0)
            },
            limit: maximumSharedActivityIDs
        )
        compact(&state, now: now)
        return state
    }

    // MARK: - Validation

    private struct SeedEvaluation {
        let disposition: PrivateLifeSeedDisposition
        let reason: PrivateLifeQuarantineReason?
        let kind: PrivateLifeSeedKind
        let traits: [PrivateLifeSeedTrait]
    }

    private static func evaluate(
        _ text: String,
        context: PrivateLifeExchangeContext
    ) -> SeedEvaluation {
        let normalized = normalizedPhrase(text)
        let rawTerms = lexicalTerms(text, removingStopWords: false)
        let meaningful = Set(lexicalTerms(text, removingStopWords: true))
        let rawSet = Set(rawTerms)
        let question = text.contains("?")
            || rawTerms.first.map { questionWords.contains($0) } == true
            || ["do you ", "are you ", "have you ", "would you ", "could you ", "is there "]
                .contains(where: { normalized.hasPrefix($0) })
        var traits: [PrivateLifeSeedTrait] = []
        if question { traits.append(.question) }
        if !meaningful.isDisjoint(with: creativeWords) { traits.append(.creative) }
        if !meaningful.isDisjoint(with: relationalWords) { traits.append(.relational) }
        if !meaningful.isDisjoint(with: selfhoodWords) { traits.append(.selfhood) }
        if !meaningful.isDisjoint(with: practicalWords) { traits.append(.practical) }
        if traits.isEmpty { traits.append(.conversational) }

        let kind: PrivateLifeSeedKind
        if traits.contains(.question) { kind = .question }
        else if traits.contains(.creative) { kind = .creative }
        else if traits.contains(.relational) { kind = .relational }
        else if traits.contains(.practical) { kind = .practical }
        else { kind = .casual }

        if context.hadToolCall || context.wasTaskFocused || context.interactionKind == .toolDirected {
            return SeedEvaluation(disposition: .quarantined, reason: .toolDirected, kind: kind, traits: traits)
        }
        if isGreeting(normalized, rawSet: rawSet) {
            return SeedEvaluation(disposition: .quarantined, reason: .greeting, kind: kind, traits: traits)
        }
        if isAcknowledgement(normalized, rawSet: rawSet) {
            return SeedEvaluation(disposition: .quarantined, reason: .acknowledgement, kind: kind, traits: traits)
        }
        if isClosing(normalized) {
            return SeedEvaluation(disposition: .quarantined, reason: .closing, kind: kind, traits: traits)
        }
        if isToolDirected(normalized, terms: rawSet) {
            return SeedEvaluation(disposition: .quarantined, reason: .toolDirected, kind: kind, traits: traits)
        }
        if context.interactionKind == .filler || isFiller(normalized, meaningfulTerms: meaningful) {
            return SeedEvaluation(disposition: .quarantined, reason: .filler, kind: kind, traits: traits)
        }
        if context.transcriptConfidence.map({ !$0.isFinite || $0 < 0.35 }) == true {
            return SeedEvaluation(disposition: .quarantined, reason: .unsafeContent, kind: kind, traits: traits)
        }

        let protectedMeaning = traits.contains(.selfhood)
            || traits.contains(.relational)
            || traits.contains(.creative)
            || context.interactionKind == .reflective
            || context.interactionKind == .relational
            || context.interactionKind == .creative
        let substantiveQuestion = question && meaningful.count >= 1
        let substantiveStatement = meaningful.count >= 4
        guard protectedMeaning || substantiveQuestion || substantiveStatement else {
            return SeedEvaluation(disposition: .quarantined, reason: .insufficientMeaning, kind: kind, traits: traits)
        }
        return SeedEvaluation(disposition: .eligible, reason: nil, kind: kind, traits: traits)
    }

    private static func validatedProposal(
        _ raw: PrivateLifeReflectionProposal,
        ticket: PrivateLifeReflectionTicket,
        state: PrivateLifeState
    ) -> PrivateLifeReflectionProposal? {
        let model = oneLine(raw.model, max: 80)
        guard model.lowercased().hasPrefix("gpt-5.6"),
              raw.confidence.isFinite,
              (0...1).contains(raw.confidence) else { return nil }
        let sourceIDs = uniqueTail(raw.sourceSeedIDs.map { oneLine($0, max: 180) }, limit: 8)
        let ticketSeedIDs = Set(ticket.candidateSeedIDs)
        let eligibleIDs = Set(state.seeds.filter { $0.disposition == .eligible }.map(\.id))
        guard sourceIDs.allSatisfy({ ticketSeedIDs.contains($0) && eligibleIDs.contains($0) }) else {
            return nil
        }
        let dispositions = Dictionary(uniqueKeysWithValues: raw.seedDispositions.compactMap { key, value in
            let bounded = oneLine(key, max: 180)
            return ticketSeedIDs.contains(bounded) ? (bounded, value) : nil
        })
        // Every reserved candidate must receive an explicit classification.
        // Otherwise the same ambiguous seed could survive an otherwise paid,
        // successful model call and be charged again on the next opportunity.
        guard dispositions.count == ticketSeedIDs.count,
              Set(dispositions.keys) == ticketSeedIDs else { return nil }
        let rejectedSourceIDs = Set<String>(dispositions.compactMap { key, value in
            switch value {
            case .meaningful, .unresolved: return nil
            case .taskOnly, .socialOnly, .duplicate, .unsafe: return key
            }
        })
        guard sourceIDs.allSatisfy({ !rejectedSourceIDs.contains($0) }) else { return nil }
        let projectID = raw.projectID.map { oneLine($0, max: 180) }
        let curiosityID = raw.curiosityID.map { oneLine($0, max: 180) }
        if let projectID, !ticket.candidateProjectIDs.contains(projectID) { return nil }
        if let curiosityID, !ticket.candidateCuriosityIDs.contains(curiosityID) { return nil }

        switch raw.action {
        case .skip:
            break
        case .reflect, .curate:
            guard !sourceIDs.isEmpty || projectID != nil || curiosityID != nil else { return nil }
        case .startCuriosity:
            guard !sourceIDs.isEmpty,
                  state.curiosities.filter({ $0.status == .open || $0.status == .exploring }).count
                    < maximumCuriosities else { return nil }
            let proposedKey = semanticKey(for: raw.openQuestion ?? raw.subject)
            guard !proposedKey.isEmpty,
                  !state.curiosities.contains(where: {
                      ($0.status == .open || $0.status == .exploring)
                          && semanticKey(for: $0.subject) == proposedKey
                  }) else { return nil }
        case .revisitCuriosity:
            guard let curiosityID,
                  let curiosity = state.curiosities.first(where: { $0.id == curiosityID }),
                  curiosity.status == .open || curiosity.status == .exploring else { return nil }
        case .connect:
            guard sourceIDs.count >= 2 else { return nil }
            let keys = Set(sourceIDs.compactMap { id in state.seeds.first(where: { $0.id == id })?.semanticKey })
            guard keys.count >= 2 else { return nil }
            let pair = Set(sourceIDs)
            let repeated = state.activities.suffix(24).contains { $0.kind == .connect && Set($0.seedIDs) == pair }
            guard !repeated else { return nil }
        case .startProject:
            guard !sourceIDs.isEmpty,
                  state.projects.filter({ $0.status == .active }).count < maximumActiveProjects else { return nil }
        case .advanceProject, .reviseProject, .completeProject:
            guard let projectID,
                  let project = state.projects.first(where: { $0.id == projectID }),
                  project.status == .active,
                  project.consecutiveAdvances < 2
                    || ticket.preparedAt.timeIntervalSince(project.lastAdvancedAt)
                        >= 2 * minimumReflectionInterval
                    || raw.action == .completeProject else { return nil }
        case .answerCuriosity, .releaseCuriosity:
            guard let curiosityID,
                  let curiosity = state.curiosities.first(where: { $0.id == curiosityID }),
                  curiosity.status == .open || curiosity.status == .exploring else { return nil }
        }

        if raw.action != .skip {
            guard raw.confidence >= 0.35 else { return nil }
            let subject = oneLine(raw.subject, max: 180)
            let reflection = oneLine(raw.privateReflection, max: 1_200)
            let summary = oneLine(raw.projectionSummary, max: 280)
            guard !subject.isEmpty, !reflection.isEmpty, !summary.isEmpty,
                  !containsUnsafeGeneratedContent(subject),
                  !containsUnsafeGeneratedContent(reflection),
                  !containsUnsafeGeneratedContent(summary),
                  PrivateLifeGeneratedContentPolicy.isNaturalFirstPerson(reflection),
                  PrivateLifeGeneratedContentPolicy.isNaturalFirstPerson(summary) else { return nil }
        }
        for optional in [
            raw.openQuestion, raw.projectTitle, raw.projectPremise, raw.projectFocus,
            raw.nextProjectFocus, raw.artifactKind, raw.artifactTitle, raw.artifactContent,
        ] {
            if let optional, containsUnsafeGeneratedContent(optional) { return nil }
        }
        if let question = raw.openQuestion {
            guard PrivateLifeGeneratedContentPolicy.isNaturalSpokenQuestion(question) else {
                return nil
            }
        }
        let artifactValues = [raw.artifactKind, raw.artifactTitle, raw.artifactContent]
        if artifactValues.contains(where: { $0 != nil }) {
            guard raw.artifactKind.map({ !oneLine($0, max: 40).isEmpty }) == true,
                  raw.artifactTitle.map({ !oneLine($0, max: 120).isEmpty }) == true,
                  raw.artifactContent.map({ !oneLine($0, max: 800).isEmpty }) == true else { return nil }
        }
        if raw.action == .startProject {
            guard raw.projectTitle.map({ !oneLine($0, max: 90).isEmpty }) == true,
                  raw.projectPremise.map({ !oneLine($0, max: 240).isEmpty }) == true,
                  raw.projectFocus.map({ !oneLine($0, max: 180).isEmpty }) == true else { return nil }
        }
        return PrivateLifeReflectionProposal(
            action: raw.action,
            model: model,
            sourceSeedIDs: sourceIDs,
            projectID: projectID,
            curiosityID: curiosityID,
            subject: oneLine(raw.subject, max: 180),
            privateReflection: oneLine(raw.privateReflection, max: 1_200),
            projectionSummary: oneLine(raw.projectionSummary, max: 280),
            openQuestion: raw.openQuestion.map { oneLine($0, max: 220) },
            projectTitle: raw.projectTitle.map { oneLine($0, max: 90) },
            projectPremise: raw.projectPremise.map { oneLine($0, max: 240) },
            projectFocus: raw.projectFocus.map { oneLine($0, max: 180) },
            nextProjectFocus: raw.nextProjectFocus.map { oneLine($0, max: 180) },
            confidence: raw.confidence,
            artifactKind: raw.artifactKind.map { oneLine($0, max: 40) },
            artifactTitle: raw.artifactTitle.map { oneLine($0, max: 120) },
            artifactContent: raw.artifactContent.map { oneLine($0, max: 800) },
            seedDispositions: dispositions
        )
    }

    private static func activityKind(for action: PrivateLifeReflectionAction) -> PrivateLifeActivityKind? {
        switch action {
        case .skip: return nil
        case .reflect: return .reflect
        case .curate: return .curate
        case .startCuriosity: return .reflect
        case .revisitCuriosity: return .revisit
        case .connect: return .connect
        case .startProject: return .formProject
        case .advanceProject, .reviseProject, .completeProject: return .develop
        case .answerCuriosity, .releaseCuriosity: return .resolve
        }
    }

    // MARK: - Scheduling and lifecycle

    private static func reflectionSeedCandidates(
        state: inout PrivateLifeState,
        at date: Date
    ) -> [PrivateLifeSeed] {
        let recentPairs = state.activities.suffix(16).flatMap(\.seedIDs)
        let recentSet = Set(recentPairs)
        return state.seeds
            .filter { seed in
                guard seed.disposition == .eligible else { return false }
                // Completed exchanges remain durable provenance, but they are
                // not immortal sources of paid reflection.
                guard seed.useCount < 3 else { return false }
                if let last = seed.lastUsedAt {
                    let cooldown = 6 * 3_600 * pow(2, Double(min(seed.useCount, 2)))
                    if date.timeIntervalSince(last) < cooldown { return false }
                }
                return true
            }
            .map { seed -> (PrivateLifeSeed, Double) in
                let ageHours = max(0, date.timeIntervalSince(seed.capturedAt) / 3_600)
                let fairness = min(0.30, ageHours / 240)
                let usagePenalty = min(0.45, Double(seed.useCount) * 0.12)
                let recencyPenalty = recentSet.contains(seed.id) ? 0.22 : 0
                let jitter = nextUnit(state: &state) * 0.05
                return (seed, seed.salience + fairness - usagePenalty - recencyPenalty + jitter)
            }
            .sorted { left, right in
                if left.1 == right.1 { return left.0.capturedAt < right.0.capturedAt }
                return left.1 > right.1
            }
            .prefix(maximumReflectionSeedCandidates)
            .map(\.0)
    }

    private static func reflectionProjectCandidates(
        state: PrivateLifeState,
        at date: Date
    ) -> [PrivateLifeProject] {
        state.projects
            .filter {
                $0.status == .active
                    && date >= $0.nextEligibleAt
                    && ($0.consecutiveAdvances < 2
                        || date.timeIntervalSince($0.lastAdvancedAt) >= 2 * minimumReflectionInterval)
            }
            .sorted { left, right in
                if left.interest == right.interest { return left.lastAdvancedAt < right.lastAdvancedAt }
                return left.interest > right.interest
            }
            .prefix(3)
            .map { $0 }
    }

    private static func reflectionCuriosityCandidates(
        state: PrivateLifeState,
        at date: Date
    ) -> [PrivateLifeCuriosity] {
        let eligible = state.curiosities.filter { curiosity in
            let isOpen = curiosity.status == .open || curiosity.status == .exploring
            let lastUse = curiosity.lastUsedAt ?? curiosity.lastRevisitedAt
            return isOpen
                && curiosity.visitCount < 6
                && date.timeIntervalSince(lastUse) >= minimumReflectionInterval
        }
        let sorted = eligible.sorted { left, right in
            let leftAge = min(0.30, date.timeIntervalSince(left.lastRevisitedAt) / (30 * 24 * 3_600))
            let rightAge = min(0.30, date.timeIntervalSince(right.lastRevisitedAt) / (30 * 24 * 3_600))
            let leftScore = left.interest + leftAge - Double(left.visitCount) * 0.08
            let rightScore = right.interest + rightAge - Double(right.visitCount) * 0.08
            if leftScore == rightScore { return left.createdAt < right.createdAt }
            return leftScore > rightScore
        }
        return Array(sorted.prefix(5))
    }

    private static func ageDormantItems(_ state: inout PrivateLifeState, at date: Date) {
        for index in state.projects.indices {
            if state.projects[index].status == .active,
               date.timeIntervalSince(state.projects[index].lastAdvancedAt) >= 14 * 24 * 3_600 {
                state.projects[index].status = .dormant
                state.projects[index].revision = min(maximumSafeCounter, state.projects[index].revision + 1)
            }
        }
        for index in state.curiosities.indices {
            if (state.curiosities[index].status == .open || state.curiosities[index].status == .exploring),
               (state.curiosities[index].visitCount >= 6
                || date.timeIntervalSince(state.curiosities[index].lastRevisitedAt) >= 21 * 24 * 3_600) {
                state.curiosities[index].status = .released
            }
        }
    }

    private static func nextSuccessfulInterval(state: inout PrivateLifeState) -> TimeInterval {
        let eligibleSeeds = Double(state.seeds.filter { $0.disposition == .eligible }.count)
        let activeProjects = Double(state.projects.filter { $0.status == .active }.count)
        let openCuriosities = Double(state.curiosities.filter {
            $0.status == .open || $0.status == .exploring
        }.count)
        let materialPressure = clamp(
            eligibleSeeds / 12
                + activeProjects / 8
                + openCuriosities / 16
        )
        // Rich ongoing material shortens the upper bound, while the hard
        // 90-minute floor prevents a dense transcript from becoming a model
        // call loop. No daily counter or cap exists.
        let adaptiveMaximum = maximumReflectionInterval - materialPressure * 90 * 60
        let range = max(0, adaptiveMaximum - minimumReflectionInterval)
        return floor(minimumReflectionInterval + nextUnit(state: &state) * range)
    }

    private static func isHighSalienceExchange(
        _ evaluation: SeedEvaluation,
        context: PrivateLifeExchangeContext
    ) -> Bool {
        guard evaluation.disposition == .eligible else { return false }
        if [.reflective, .relational, .creative].contains(context.interactionKind) {
            return true
        }
        if evaluation.traits.contains(.selfhood) { return true }
        return evaluation.traits.contains(.question)
            && (evaluation.traits.contains(.relational) || evaluation.traits.contains(.creative))
    }

    private static func nextPostConversationInterval(
        state: inout PrivateLifeState
    ) -> TimeInterval {
        let range = maximumPostConversationReflectionInterval
            - minimumPostConversationReflectionInterval
        return floor(minimumPostConversationReflectionInterval + nextUnit(state: &state) * range)
    }

    private static func failureBackoff(
        _ failures: Int,
        kind: PrivateLifeReflectionFailureKind? = nil
    ) -> TimeInterval {
        let exponent = max(0, min(5, failures - 1))
        let exponential = min(6 * 3_600, 15 * 60 * pow(2, Double(exponent)))
        switch kind {
        case .invalidOutput, .malformedOutput, .semanticRejected, .validationRejected:
            // A malformed or semantically unusable paid result should not
            // cause the same evidence envelope to consume another ~10k-token
            // Codex context only 15 minutes later. This is retry spacing, not
            // a daily cap; new grounded foreground exchanges can still bring
            // the ordinary post-conversation schedule forward.
            return max(minimumReflectionInterval, exponential)
        default:
            return exponential
        }
    }

    private static func appendReflectionReceipt(
        ticket: PrivateLifeReflectionTicket,
        model: String?,
        outcome: PrivateLifeReflectionReceiptOutcome,
        failure: PrivateLifeReflectionFailureKind?,
        activityID: String?,
        outputDigest: String?,
        at: Date,
        state: inout PrivateLifeState
    ) {
        state.reflectionReceipts.append(PrivateLifeReflectionReceipt(
            id: generatedID(prefix: "reflection_receipt", state: &state),
            ticketID: ticket.id,
            attemptedAt: ticket.preparedAt,
            completedAt: at,
            model: model.map { oneLine($0, max: 80) },
            outcome: outcome,
            failureKind: failure,
            activityID: activityID,
            inputDigest: ticket.inputDigest,
            outputDigest: outputDigest
        ))
    }

    // MARK: - Compaction and projection safety

    private static func appendDaySummary(
        _ activity: PrivateLifeActivity,
        state: inout PrivateLifeState
    ) {
        let dayKey = localDayKey(activity.completedAt ?? activity.startedAt)
        if let index = state.daySummaries.firstIndex(where: { $0.dayKey == dayKey }) {
            state.daySummaries[index].activityIDs = uniqueTail(
                state.daySummaries[index].activityIDs + [activity.id],
                limit: 128
            )
            state.daySummaries[index].activityCounts[activity.kind.rawValue, default: 0] += 1
            if let projectID = activity.projectID,
               state.projects.first(where: { $0.id == projectID })?.status == .completed {
                state.daySummaries[index].completedProjectIDs = uniqueTail(
                    state.daySummaries[index].completedProjectIDs + [projectID],
                    limit: 32
                )
            }
            state.daySummaries[index].lastActivityAt = activity.completedAt ?? activity.startedAt
        } else {
            var completedProjects: [String] = []
            if let projectID = activity.projectID,
               state.projects.first(where: { $0.id == projectID })?.status == .completed {
                completedProjects = [projectID]
            }
            state.daySummaries.append(PrivateLifeDaySummary(
                dayKey: dayKey,
                activityIDs: [activity.id],
                activityCounts: [activity.kind.rawValue: 1],
                completedProjectIDs: completedProjects,
                lastActivityAt: activity.completedAt ?? activity.startedAt
            ))
        }
    }

    private static func compact(_ state: inout PrivateLifeState, now: Date) {
        var protectedSeedIDs = Set(state.pendingReflection?.candidateSeedIDs ?? [])
        for project in state.projects where project.status == .active {
            protectedSeedIDs.formUnion(project.sourceSeedIDs)
        }
        for curiosity in state.curiosities
        where curiosity.status == .open || curiosity.status == .exploring {
            protectedSeedIDs.formUnion(curiosity.sourceSeedIDs)
        }
        let quarantineCutoff = now.addingTimeInterval(-24 * 3_600)
        state.seeds = state.seeds
            .filter { $0.disposition == .eligible || $0.capturedAt >= quarantineCutoff || protectedSeedIDs.contains($0.id) }
            .sorted { $0.capturedAt < $1.capturedAt }
        if state.seeds.count > maximumSeeds {
            let protected = state.seeds.filter { protectedSeedIDs.contains($0.id) }
            let ordinary = state.seeds.filter { !protectedSeedIDs.contains($0.id) }
            // The configured ceiling exceeds the maximum representable live
            // provenance set, but retain all protected records even if a
            // corrupt legacy file somehow violates that invariant. The store's
            // independent 2 MiB bound remains the final hard ceiling.
            let retainedLimit = max(maximumSeeds, protected.count)
            state.seeds = Array(
                ordinary.suffix(max(0, retainedLimit - protected.count)) + protected
            )
                .sorted { $0.capturedAt < $1.capturedAt }
        }

        var activeUsed = 0
        state.projects = state.projects
            .sorted { left, right in
                if left.status == .active && right.status != .active { return true }
                if right.status == .active && left.status != .active { return false }
                if left.interest == right.interest { return left.lastAdvancedAt > right.lastAdvancedAt }
                return left.interest > right.interest
            }
            .map { project in
                var project = project
                if project.status == .active {
                    activeUsed += 1
                    if activeUsed > maximumActiveProjects { project.status = .dormant }
                }
                project.steps = Array(project.steps.suffix(maximumProjectSteps))
                return project
            }
        state.projects = Array(state.projects.prefix(maximumProjects))
        state.curiosities = Array(
            state.curiosities
                .sorted { left, right in
                    let leftOpen = left.status == .open || left.status == .exploring
                    let rightOpen = right.status == .open || right.status == .exploring
                    if leftOpen != rightOpen { return leftOpen }
                    if left.interest == right.interest { return left.createdAt < right.createdAt }
                    return left.interest > right.interest
                }
                .prefix(maximumCuriosities)
        )
        state.activities = Array(state.activities.suffix(maximumActivities))
        state.daySummaries = Array(
            state.daySummaries.sorted { $0.dayKey < $1.dayKey }.suffix(maximumDaySummaries)
        )
        state.projectedActivityIDs = uniqueTail(
            state.projectedActivityIDs.map { oneLine($0, max: 180) },
            limit: maximumProjectedActivityIDs
        )
        state.recentEventIDs = uniqueTail(
            state.recentEventIDs.map { oneLine($0, max: 180) },
            limit: maximumRecentEventIDs
        )
        state.reflectionReceipts = Array(state.reflectionReceipts.suffix(maximumReflectionReceipts))
        state.projectionReceipts = Array(state.projectionReceipts.suffix(maximumProjectionReceipts))
        state.presentationReceipts = Array(
            state.presentationReceipts.suffix(maximumPresentationReceipts)
        )
        state.pendingShares = Array(state.pendingShares.suffix(maximumPendingShares))
        state.shareReceipts = Array(state.shareReceipts.suffix(maximumShareReceipts))
        state.sharedActivityIDs = uniqueTail(
            state.sharedActivityIDs.map { oneLine($0, max: 180) },
            limit: maximumSharedActivityIDs
        )
    }

    private static func containsUnsafeGeneratedContent(_ text: String) -> Bool {
        if PrivateLifeGeneratedContentPolicy.rejects(text) { return true }
        if text.range(
            of: "(?i)\\b(?:sk|pk)-[a-z0-9_-]{8,}\\b|\\bbearer\\s+[a-z0-9._-]{8,}",
            options: .regularExpression
        ) != nil { return true }
        return false
    }

    private static func safeGeneratedSummary(_ value: String) -> String {
        let safe = oneLine(redactingSecrets(value), max: 280)
        return containsUnsafeGeneratedContent(safe) ? "" : safe
    }

    private static func transcript(_ transcript: String, containsVerbatim line: String) -> Bool {
        let normalizedLine = line.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalizedTranscript = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return !normalizedLine.isEmpty && normalizedTranscript.contains(normalizedLine)
    }

    private static func safeStoredTitle(_ value: String) -> String {
        let safe = oneLine(redactingSecrets(value), max: 90)
        return containsUnsafeGeneratedContent(safe) || safe.isEmpty ? "Private exploration" : safe
    }

    private static func safeStoredSubject(_ value: String) -> String {
        let terms = lexicalTerms(redactingSecrets(value), removingStopWords: true)
            .filter { !projectionUnsafeWords.contains($0) }
            .prefix(14)
        return terms.isEmpty ? "a grounded private question" : oneLine(terms.joined(separator: " "), max: 180)
    }

    private static func safeSubject(for text: String) -> String {
        safeStoredSubject(text)
    }

    private static func semanticKey(for text: String) -> String {
        let terms = Set(
            lexicalTerms(redactingSecrets(text), removingStopWords: true)
                .filter { !projectionUnsafeWords.contains($0) }
        )
        return terms.sorted().prefix(10).joined(separator: ":")
    }

    private static func safeActivityResult(
        kind: PrivateLifeActivityKind,
        status: PrivateLifeActivityStatus
    ) -> String {
        guard status == .completed else { return "made no grounded progress" }
        switch kind {
        case .revisit: return "returned to a grounded thread without inventing a conclusion"
        case .connect: return "noticed a possible connection between grounded sources"
        case .develop: return "advanced a grounded private project"
        case .curate: return "organized grounded sources"
        case .reflect: return "kept one grounded question open"
        case .formProject: return "formed a grounded private project"
        case .resolve: return "resolved or released a grounded curiosity"
        }
    }

    // MARK: - Text and identity helpers

    private static func isGreeting(_ normalized: String, rawSet: Set<String>) -> Bool {
        if ["hey", "hi", "hello", "yo", "hey aurora", "hi aurora", "hello aurora"].contains(normalized) {
            return true
        }
        return !rawSet.isEmpty && rawSet.isSubset(of: ["hey", "hi", "hello", "yo", "aurora"])
    }

    private static func isAcknowledgement(_ normalized: String, rawSet: Set<String>) -> Bool {
        let phrases = [
            "ok", "okay", "yeah", "yep", "yup", "sure", "right", "cool", "awesome", "perfect",
            "great", "nice", "thanks", "thank you", "got it", "sounds good", "that worked",
            "perfect thank you", "awesome thanks"
        ]
        if phrases.contains(normalized) { return true }
        let allowed: Set<String> = [
            "ok", "okay", "yeah", "yep", "yup", "sure", "right", "cool", "awesome", "perfect",
            "great", "nice", "thanks", "thank", "you", "got", "it", "worked", "good", "sounds"
        ]
        return !rawSet.isEmpty && rawSet.count <= 5 && rawSet.isSubset(of: allowed)
    }

    private static func isClosing(_ normalized: String) -> Bool {
        [
            "bye", "goodbye", "good night", "goodnight", "i gotta go", "i have to go",
            "talk later", "see you", "see ya", "catch you later", "im leaving", "i'm leaving"
        ].contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") })
    }

    private static func isFiller(_ normalized: String, meaningfulTerms: Set<String>) -> Bool {
        if normalized.isEmpty { return true }
        let phrases = [
            "um", "uh", "hmm", "mhm", "mm hm", "next question", "ask me a question",
            "ask another question", "too much", "most part", "for the most part", "error"
        ]
        if phrases.contains(where: { normalized == $0 || normalized.contains($0) }) { return true }
        return meaningfulTerms.isEmpty
    }

    private static func isToolDirected(_ normalized: String, terms: Set<String>) -> Bool {
        let verbs: Set<String> = [
            "open", "close", "click", "pause", "play", "minimize", "maximize", "search", "send",
            "email", "remind", "set", "type", "scroll", "drag", "launch", "quit", "delete", "buy",
            "purchase", "submit", "install", "download", "upload", "write", "navigate", "switch"
        ]
        let objects: Set<String> = [
            "youtube", "chrome", "safari", "tab", "tabs", "window", "windows", "video", "screen",
            "reminder", "reminders", "email", "gmail", "outlook", "app", "application", "settings",
            "file", "folder", "desktop", "textedit", "page", "browser", "computer", "mac"
        ]
        let hasOperationalPair = !terms.isDisjoint(with: verbs) && !terms.isDisjoint(with: objects)
        let directPatterns = [
            "can you open", "could you open", "please open", "open youtube", "close the", "click the",
            "pause the", "play the", "minimize", "set a reminder", "make a reminder", "send the email",
            "look at the screen", "what do you see on"
        ]
        return hasOperationalPair || directPatterns.contains(where: normalized.contains)
    }

    private static func sanitizeParticipant(_ participant: PrivateLifeParticipant) -> PrivateLifeParticipant {
        switch participant.kind {
        case .owner: return .owner
        case .unknown: return .unknown
        case .guest:
            let name = participant.displayName
                .map { oneLine($0, max: 80) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return .guest(name)
        }
    }

    private static func minDisposition(
        _ stored: PrivateLifeSeedDisposition,
        _ evaluated: PrivateLifeSeedDisposition
    ) -> PrivateLifeSeedDisposition {
        stored == .quarantined || evaluated == .quarantined ? .quarantined : .eligible
    }

    private static func resolvedSourceSeedIDs(
        _ proposal: PrivateLifeReflectionProposal,
        state: PrivateLifeState
    ) -> [String] {
        if !proposal.sourceSeedIDs.isEmpty { return proposal.sourceSeedIDs }
        if let projectID = proposal.projectID,
           let project = state.projects.first(where: { $0.id == projectID }) {
            return uniqueTail(project.sourceSeedIDs, limit: 8)
        }
        if let curiosityID = proposal.curiosityID,
           let curiosity = state.curiosities.first(where: { $0.id == curiosityID }) {
            return uniqueTail(curiosity.sourceSeedIDs, limit: 8)
        }
        return []
    }

    private static func sourceDigests(for seedIDs: [String], state: PrivateLifeState) -> [String] {
        uniqueTail(seedIDs.compactMap { id in
            state.seeds.first(where: { $0.id == id })?.ownerDigest
        }, limit: 8)
    }

    private static func digest(_ proposal: PrivateLifeReflectionProposal) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(proposal) else {
            return sha256("unencodable-private-life-proposal")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nextUnit(state: inout PrivateLifeState) -> Double {
        var x = state.entropyState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state.entropyState = x == 0 ? 0xA770_51FE_5EED_44A1 : x
        let mixed = state.entropyState &* 2_685_821_657_736_338_717
        return Double(mixed >> 11) / Double(UInt64(1) << 53)
    }

    private static func generatedID(prefix: String, state: inout PrivateLifeState) -> String {
        state.sequence = min(maximumSafeCounter, state.sequence + 1)
        let entropy = UInt64(nextUnit(state: &state) * Double(UInt64.max))
        return "\(prefix)_\(state.sequence)_\(String(entropy, radix: 16))"
    }

    private static func lexicalTerms(_ text: String, removingStopWords: Bool) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .filter { !removingStopWords || !stopWords.contains($0) }
            .map { String($0.prefix(48)) }
    }

    private static func normalizedPhrase(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redactingSecrets(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?i)\\b(?:sk|pk)-[a-z0-9_-]{8,}\\b|\\bbearer\\s+[a-z0-9._-]{8,}",
            with: "[redacted credential]",
            options: .regularExpression
        )
    }

    private static func digestValue(_ value: String) -> String {
        let bounded = oneLine(value, max: 128).lowercased()
        let allowed = bounded.allSatisfy { $0.isHexDigit }
        return allowed && bounded.count == 64 ? bounded : sha256(bounded)
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func localDayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = localTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func oneLine(_ value: String, max: Int) -> String {
        String(
            value
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(max)
        )
    }

    private static func uniqueTail(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var reversed: [String] = []
        for value in values.reversed() where !value.isEmpty {
            if seen.insert(value).inserted {
                reversed.append(value)
                if reversed.count >= limit { break }
            }
        }
        return reversed.reversed()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}
