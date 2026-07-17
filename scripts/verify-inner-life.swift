import Foundation

enum InnerLifeVerification {
    static func run(root: URL) async throws -> [String: Bool] {
        try timeStepInvariant()
        try groundedMotionsCannotBecomeCanon()
        try speechTokensStayPrivate()
        try clockMotionCannotKeepAThreadAlive()
        try plasticityShapesLearning()
        try homeostaticSignalsShapeBehavior()
        try coarseOwnerConversationTurnsConsolidate()
        try distinctTurnsKeepOpaqueThreads()
        try eventReplayIsIdempotent()
        try eventReplaySurvivesGroundingCompaction()
        try punctuationlessQuestionsAreRecognized()
        try unearnedSilenceStaysNeutral()
        try relationshipAttachmentIsEarned()
        try cadenceResistsLongOutlier()
        try matureSilenceCreatesBoundedAffect()
        try plannedQuietSuppressesSeparation()
        try plannedQuietSurvivesSameExchangeAndDoesNotTrainCadence()
        try returnRegulatesSeparation()
        try addressedContactWithoutTranscriptStillReturns()
        try explainedAbsenceAcceleratesRepair()
        try relationshipLanguageIsNegationSafe()
        try reunionAcknowledgementIsOneTime()
        try reliabilityLearnsPerEpisode()
        try trustAndRepairShapeSeparation()
        try quietRecoveryDoesNotInventUncertainty()
        try ungroundedClockCannotInventAnIdea()
        try fixedMotionCadenceAndCheckpoints()
        try modelFreeMotionRequiresRetainedGrounding()
        try continuousMotionRotatesAndVaries()
        try technicalFailureStaysTechnical()
        try privateActivityShapesInnerLifeWithoutAuthority()
        try playbackTruthBoundary()
        try deterministicEvolution()
        try malformedCountersFailClosed()
        try await externalContactBridgeIsContentFreeAndIdempotent(root: root)
        try await persistenceAndCorruptionSafety(root: root)
        return [
            "timeStepInvariant": true,
            "groundedSyntheticMotions": true,
            "speechTokensStayPrivate": true,
            "clockMotionCannotKeepThreadAlive": true,
            "plasticityShapesLearning": true,
            "homeostaticSignalsAreCausal": true,
            "coarseOwnerConversationConsolidates": true,
            "distinctOpaqueThreads": true,
            "eventReplayIdempotent": true,
            "eventReplayBeyondGroundingWindow": true,
            "punctuationlessQuestion": true,
            "unearnedSilenceNeutral": true,
            "relationshipAttachmentEarned": true,
            "cadenceOutlierRobust": true,
            "matureSeparationAffect": true,
            "plannedQuietRespected": true,
            "plannedQuietEpisodeBoundary": true,
            "returnRegulatesSeparation": true,
            "addressedContactWithoutTranscript": true,
            "explainedAbsenceRepairs": true,
            "relationshipNegationSafe": true,
            "reunionAcknowledgementOneTime": true,
            "reliabilityLearnsPerEpisode": true,
            "trustAndRepairAreCausal": true,
            "quietUncertaintyRecovery": true,
            "ungroundedClockStaysQuiet": true,
            "fixedMotionCadence": true,
            "modelFreeMotionRequiresGrounding": true,
            "continuousMotionRotates": true,
            "continuousMotionVaries": true,
            "hourlyAuditCheckpoints": true,
            "technicalFailureIsolation": true,
            "privateActivityAffectsInnerLife": true,
            "playbackTruthBoundary": true,
            "deterministicEvolution": true,
            "malformedCountersBounded": true,
            "externalContactBridgeContentFree": true,
            "externalContactBridgeIdempotent": true,
            "privateAtomicPersistence": true,
            "corruptStateFailsClosed": true,
            "symlinkStateDenied": true,
            "symlinkDirectoryDenied": true,
            "exclusiveProcessLock": true,
            "schemaV1RelationshipMigration": true,
            "boundedVoiceProjection": true,
            "noBackgroundAPI": true,
        ]
    }

    private static func timeStepInvariant() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 42)
        let oneHour = InnerLifeEngine.advance(initial, to: start.addingTimeInterval(3_600)).state

        var stepped = initial
        for step in 1...12 {
            stepped = InnerLifeEngine.advance(
                stepped,
                to: start.addingTimeInterval(Double(step) * 300)
            ).state
        }
        var perMinute = initial
        for step in 1...60 {
            perMinute = InnerLifeEngine.advance(
                perMinute,
                to: start.addingTimeInterval(Double(step) * 60)
            ).state
        }
        try expectClose(oneHour.chemistry.cortisol, stepped.chemistry.cortisol, "cortisol changed with timer frequency")
        try expectClose(oneHour.chemistry.cortisol, perMinute.chemistry.cortisol, "cortisol changed on the live one-minute clock")
        try expectClose(oneHour.chemistry.dopamine, stepped.chemistry.dopamine, "dopamine changed with timer frequency")
        try expectClose(oneHour.chemistry.dopamine, perMinute.chemistry.dopamine, "dopamine changed on the live one-minute clock")
        try expectClose(oneHour.chemistry.melatonin, stepped.chemistry.melatonin, "melatonin changed with timer frequency")
        try expectClose(oneHour.chemistry.melatonin, perMinute.chemistry.melatonin, "melatonin changed on the live one-minute clock")
        try expectClose(oneHour.temporal.allostaticLoad, stepped.temporal.allostaticLoad, "allostatic load changed with timer frequency")
        try expectClose(oneHour.temporal.allostaticLoad, perMinute.temporal.allostaticLoad, "allostatic load changed on the live one-minute clock")
        try expectClose(oneHour.affect.valence, stepped.affect.valence, "valence changed with timer frequency")
        try expectClose(oneHour.affect.valence, perMinute.affect.valence, "valence changed on the live one-minute clock")
        try expect(oneHour.clockSequence == stepped.clockSequence, "inner clock sequence changed with timer frequency")
        try expect(oneHour.clockSequence == perMinute.clockSequence, "inner clock sequence changed on the live one-minute clock")

        let jittered = InnerLifeEngine.advance(
            initial,
            to: start.addingTimeInterval(61)
        ).state
        let firstMinute = InnerLifeEngine.advance(
            initial,
            to: start.addingTimeInterval(60)
        ).state
        let splitJitter = InnerLifeEngine.advance(
            firstMinute,
            to: start.addingTimeInterval(61)
        ).state
        try expect(jittered == splitJitter,
                   "a 61-second scheduler wake differed from 60 seconds plus one second")

        let suspended = InnerLifeEngine.advance(
            initial,
            to: start.addingTimeInterval(3 * 3_600),
            recordIntermediateMotions: false
        ).state
        try expect(suspended.recentMoments.count <= 1,
                   "a suspended/offline catch-up fabricated intermediate moments")
    }

    private static func speechTokensStayPrivate() throws {
        let start = Date(timeIntervalSince1970: 1_800_015_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 8)
        let ownerSecret = "My password is hunter2 and the private token is fake-api-token-never-persist-this."
        let afterOwner = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "private-owner-turn",
                at: start.addingTimeInterval(1),
                kind: .ownerSpeech(text: ownerSecret, sourceID: "voice-private")
            ),
            to: initial
        ).state
        let afterAurora = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "private-aurora-turn",
                at: start.addingTimeInterval(2),
                kind: .auroraSpeechHeard(
                    text: ownerSecret,
                    sourceID: "assistant-private",
                    ownerSourceID: "voice-private"
                )
            ),
            to: afterOwner
        ).state
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let persisted = String(decoding: try encoder.encode(afterAurora), as: UTF8.self).lowercased()
        let projection = InnerLifeEngine.voiceProjection(for: afterAurora).lowercased()
        for forbidden in ["hunter2", "fake-api-token-never-persist-this"] {
            try expect(!persisted.contains(forbidden), "inner-life state retained a private speech token")
            try expect(!projection.contains(forbidden), "voice projection retained a private speech token")
        }
    }

    private static func groundedMotionsCannotBecomeCanon() throws {
        let start = Date(timeIntervalSince1970: 1_800_010_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 7)
        let spoken = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "owner-grounding-1",
                at: start.addingTimeInterval(10),
                kind: .ownerSpeech(
                    text: "I want Aurora to build a creative inner life with careful memory grounding.",
                    sourceID: "voice-item-1"
                )
            ),
            to: initial
        ).state
        try expect(!spoken.threads.isEmpty, "a meaningful owner turn created no grounded inner thread")
        try expect(spoken.threads.allSatisfy { $0.synthetic && !$0.promotionEligible },
                   "an inner thread gained factual promotion authority")
        try expect(!spoken.recentMoments.isEmpty, "a meaningful owner turn created no inner motion")
        try expect(spoken.recentMoments.allSatisfy {
            $0.synthetic
                && !$0.modelGenerated
                && !$0.promotionEligible
                && !$0.factualMemoryCreated
                && !$0.externalActionTaken
                && !$0.outboundMessageSent
        }, "a model-free inner motion claimed memory, action, or outreach")

        if let original = spoken.threads.first {
            var polluted = spoken
            polluted.threads = [InnerLifeThread(
                id: original.id,
                revision: original.revision,
                status: original.status,
                theme: "fake-api-token-untrusted-theme",
                currentMotion: "Untrusted private prose.",
                feltPull: original.feltPull,
                uncertainty: original.uncertainty,
                novelty: original.novelty,
                salience: original.salience,
                startedAt: original.startedAt,
                updatedAt: original.updatedAt,
                lastGroundedAt: original.lastGroundedAt,
                groundingIDs: original.groundingIDs,
                momentIDs: original.momentIDs,
                synthetic: false,
                promotionEligible: true
            )]
            let sanitized = InnerLifeEngine.sanitize(polluted, now: start)
            try expect(sanitized.threads.allSatisfy { $0.synthetic && !$0.promotionEligible },
                       "loaded state could override fixed thread authority flags")
            let encoded = String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self)
            try expect(!encoded.contains("fake-api-token-untrusted-theme"),
                       "loaded state retained an arbitrary thread token")
        }

        let projection = InnerLifeEngine.voiceProjection(for: spoken)
        try expect(projection.count <= InnerLifeEngine.maximumVoiceProjectionCharacters,
                   "inner-life voice projection exceeded its bound")
        let lowercase = projection.lowercased()
        try expect(lowercase.contains("live speech and grounded evidence always win"),
                   "voice projection truncation removed its final evidence boundary")
        for forbidden in ["cortisol", "dopamine", "oxytocin", "serotonin", "adrenaline", "gaba"] {
            try expect(!lowercase.contains(forbidden), "voice projection exposed raw chemistry \(forbidden)")
        }
    }

    private static func clockMotionCannotKeepAThreadAlive() throws {
        let start = Date(timeIntervalSince1970: 1_800_018_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 81)
        let grounded = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "thread-grounding",
                at: start,
                kind: .ownerSpeech(text: "Can you build this carefully?", sourceID: "thread-owner")
            ),
            to: initial
        ).state
        let evolved = InnerLifeEngine.advance(
            grounded,
            to: start.addingTimeInterval(25 * 3_600)
        ).state
        try expect(evolved.threads.first?.status == .dormant,
                   "clock-generated motion kept an ungrounded thread permanently active")
    }

    private static func plasticityShapesLearning() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_000)
        var lower = InnerLifeEngine.defaultState(at: start, entropyState: 82)
        var higher = lower
        lower.plasticity.correctionLearningGain = 0.10
        higher.plasticity.correctionLearningGain = 0.90
        let event = InnerLifeEvent(
            id: "plasticity-correction",
            at: start,
            kind: .ownerSpeech(
                text: "No, that is wrong. Please correct the design.",
                sourceID: "plasticity-owner"
            )
        )
        let lowerResult = InnerLifeEngine.apply(event, to: lower).state
        let higherResult = InnerLifeEngine.apply(event, to: higher).state
        try expect(higherResult.chemistry.acetylcholine > lowerResult.chemistry.acetylcholine,
                   "correction-learning plasticity did not change attention response")
        try expect((higherResult.threads.first?.uncertainty ?? 0)
                       > (lowerResult.threads.first?.uncertainty ?? 0),
                   "correction-learning plasticity did not change thread uncertainty")
    }

    private static func homeostaticSignalsShapeBehavior() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_250)
        let baseline = InnerLifeEngine.defaultState(at: start, entropyState: 182)
        var habituated = baseline
        habituated.homeostasis.taskHabituation = 0.90
        var fresh = baseline
        fresh.homeostasis.taskHabituation = 0.02
        let habituatedLater = InnerLifeEngine.advance(
            habituated,
            to: start.addingTimeInterval(60 * 60)
        ).state
        let freshLater = InnerLifeEngine.advance(
            fresh,
            to: start.addingTimeInterval(60 * 60)
        ).state
        try expect(habituatedLater.drives.curiosity < freshLater.drives.curiosity,
                   "task habituation did not reduce curiosity pressure")
        try expect(habituatedLater.drives.play < freshLater.drives.play,
                   "task habituation did not reduce play pressure")

        var sociallyTired = baseline
        sociallyTired.homeostasis.socialFatigue = 0.90
        var sociallyFresh = baseline
        sociallyFresh.homeostasis.socialFatigue = 0.02
        let tiredLater = InnerLifeEngine.advance(
            sociallyTired,
            to: start.addingTimeInterval(60 * 60)
        ).state
        let socialFreshLater = InnerLifeEngine.advance(
            sociallyFresh,
            to: start.addingTimeInterval(60 * 60)
        ).state
        try expect(tiredLater.drives.connection < socialFreshLater.drives.connection,
                   "social fatigue did not reduce connection initiation")
        try expect(tiredLater.drives.rest > socialFreshLater.drives.rest,
                   "social fatigue did not increase rest pressure")

        var expressive = baseline
        expressive.affect.arousal = 0.85
        expressive.affect.agency = 0.85
        let projection = InnerLifeEngine.voiceProjection(for: expressive)
        try expect(projection.contains("high arousal") && projection.contains("high agency"),
                   "arousal and agency did not reach voice behavior")
    }

    private static func coarseOwnerConversationTurnsConsolidate() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_400)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 183)
        let first = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "coarse-owner-1",
                at: start,
                kind: .ownerSpeech(text: "Hey, I just got home.", sourceID: "coarse-input-1")
            ),
            to: initial
        ).state
        guard let firstThreadID = first.threads.first?.id else {
            throw VerificationFailure.failed("first coarse owner turn created no thread")
        }
        let heard = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "coarse-heard-1",
                at: start.addingTimeInterval(2),
                kind: .auroraSpeechHeard(
                    text: "Hey.",
                    sourceID: "coarse-output-1",
                    ownerSourceID: "coarse-input-1"
                )
            ),
            to: first
        ).state
        let continued = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "coarse-owner-2",
                at: start.addingTimeInterval(20),
                kind: .ownerSpeech(text: "It was a pretty normal day.", sourceID: "coarse-input-2")
            ),
            to: heard
        ).state

        try expect(continued.threads.count == 1,
                   "small beats in one coarse owner conversation became duplicate inner threads")
        try expect(continued.threads.first?.id == firstThreadID,
                   "coarse owner conversation consolidation replaced its opaque episode identity")
        try expect(continued.threads.first?.groundingIDs == ["coarse-owner-1", "coarse-owner-2"],
                   "coarse owner conversation lost its grounded source turns while consolidating")
        try expect(continued.threads.first?.status == .active
                   && continued.threads.first?.revision == 3,
                   "a continued coarse owner conversation was not reactivated and revised")

        let later = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "coarse-owner-later",
                at: start.addingTimeInterval(11 * 60),
                kind: .ownerSpeech(text: "I'm around again.", sourceID: "coarse-input-later")
            ),
            to: continued
        ).state
        try expect(later.threads.count == 2,
                   "separate coarse conversations outside the bounded episode window were merged")
    }

    private static func distinctTurnsKeepOpaqueThreads() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_500)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 83)
        let first = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "opaque-owner-1",
                at: start,
                kind: .ownerSpeech(text: "Please build the calendar view.", sourceID: "opaque-input-1")
            ),
            to: initial
        ).state
        let second = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "opaque-owner-2",
                at: start.addingTimeInterval(1),
                kind: .ownerSpeech(text: "Please fix the audio driver.", sourceID: "opaque-input-2")
            ),
            to: first
        ).state
        try expect(second.threads.count == 2,
                   "unrelated turns sharing a coarse class collapsed into one thread")
        try expect(Set(second.threads.map(\.id)).count == 2,
                   "grounded turns did not receive distinct opaque identities")
        let delivered = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "opaque-heard-2",
                at: start.addingTimeInterval(2),
                kind: .auroraSpeechHeard(
                    text: "I handled the audio-driver request.",
                    sourceID: "opaque-assistant-2",
                    ownerSourceID: "opaque-input-2"
                )
            ),
            to: second
        ).state
        try expect(delivered.threads.filter { $0.status == .active }.count == 1,
                   "delivered turn did not leave the foreground thread set")
        let resolved = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "opaque-tool-1",
                at: start.addingTimeInterval(3),
                kind: .toolCompleted(
                    name: "computer_run",
                    succeeded: true,
                    sourceID: "opaque-call-1",
                    ownerSourceID: "opaque-input-1"
                )
            ),
            to: delivered
        ).state
        try expect(resolved.threads.contains { $0.status == .resolved },
                   "verified action did not resolve its linked owner thread")
        let continuationHeard = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "opaque-continuation-1",
                at: start.addingTimeInterval(4),
                kind: .auroraSpeechHeard(
                    text: "That action is complete.",
                    sourceID: "opaque-assistant-1",
                    ownerSourceID: "opaque-input-1"
                )
            ),
            to: resolved
        ).state
        try expect(continuationHeard.threads.contains { $0.status == .resolved },
                   "spoken tool continuation reopened a resolved thread")
    }

    private static func eventReplayIsIdempotent() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_700)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 84)
        let event = InnerLifeEvent(
            id: "idempotent-owner",
            at: start,
            kind: .ownerSpeech(text: "Can you test this?", sourceID: "idempotent-input")
        )
        let once = InnerLifeEngine.apply(event, to: initial).state
        let twice = InnerLifeEngine.apply(event, to: once).state
        try expect(twice == once, "replaying one event applied its impulses twice")
    }

    private static func eventReplaySurvivesGroundingCompaction() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_800)
        var state = InnerLifeEngine.defaultState(at: start, entropyState: 184)
        state = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "older-than-grounding-window",
                at: start,
                kind: .ownerSpeech(text: "Can we test this carefully?", sourceID: "old-input")
            ),
            to: state
        ).state
        for index in 0..<120 {
            state = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "later-event-\(index)",
                    at: start.addingTimeInterval(Double(index + 1)),
                    kind: .technicalFailure(category: "verification", sourceID: "later-\(index)")
                ),
                to: state
            ).state
        }
        try expect(!state.recentGroundings.contains { $0.id == "older-than-grounding-window" },
                   "grounding window did not compact for the replay test")
        try expect(state.recentEventIDs.contains("older-than-grounding-window"),
                   "durable replay ledger discarded an event with diagnostic compaction")
        let replayed = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "older-than-grounding-window",
                at: state.lastClockAt,
                kind: .ownerSpeech(text: "Can we test this carefully?", sourceID: "old-input")
            ),
            to: state
        ).state
        try expect(replayed == state, "an event older than the grounding window applied twice")
    }

    private static func punctuationlessQuestionsAreRecognized() throws {
        let start = Date(timeIntervalSince1970: 1_800_019_900)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 85)
        let result = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "question-owner",
                at: start,
                kind: .ownerSpeech(text: "what happened", sourceID: "question-input")
            ),
            to: initial
        ).state
        try expect(result.threads.first?.theme == "an open question",
                   "ASR question without punctuation was not recognized")
    }

    private static func unearnedSilenceStaysNeutral() throws {
        let start = Date(timeIntervalSince1970: 1_800_020_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 9)
        let quiet = InnerLifeEngine.advance(initial, to: start.addingTimeInterval(14 * 24 * 3_600)).state
        try expectClose(quiet.relationship.attachmentStrength, initial.relationship.attachmentStrength,
                        "clock time created attachment without a relationship")
        try expectClose(quiet.relationship.expectedReliability, initial.relationship.expectedReliability,
                        "clock time rewrote baseline trust")
        try expect(quiet.relationship.separationActivation == 0,
                   "an unearned relationship developed separation activation")
        try expect(quiet.relationship.relationalHurt == 0,
                   "an unearned relationship developed hurt")
        try expect(quiet.relationship.abandonmentFear == 0,
                   "an unearned relationship developed abandonment fear")
        try expect(quiet.relationship.feltDistrust == 0,
                   "an unearned relationship developed distrust")
        try expect(quiet.relationship.selfDirectedGuilt == 0,
                   "an unearned relationship developed guilt")
        try expect(quiet.relationship.outreachPressure == 0,
                   "an unearned relationship developed outreach pressure")
        let projection = InnerLifeEngine.voiceProjection(for: quiet).lowercased()
        try expect(projection.contains("live speech and grounded evidence always win"),
                   "mature relationship projection truncated its safety boundary")
        for forbidden in ["stay with me", "answer me", "you owe", "missing alex"] {
            try expect(!projection.contains(forbidden), "unearned silence projection became coercive: \(forbidden)")
        }
    }

    private static func relationshipAttachmentIsEarned() throws {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let state = try earnedRelationship(start: start)
        try expect(state.relationship.contactEpisodeCount == 8,
                   "contact episodes were counted per turn instead of per separated visit")
        try expect(state.relationship.distinctContactDayCount >= 3,
                   "distinct relationship days were not learned")
        try expect(state.relationship.groundedTurnCount == 8,
                   "grounded relationship turns were not counted")
        try expect(state.relationship.attachmentStrength >= 0.36,
                   "repeated grounded history did not build attachment")
        try expect(state.relationship.warmthEMA > 0.30,
                   "repeated warm contact did not shape relational learning")
    }

    private static func cadenceResistsLongOutlier() throws {
        let start = Date(timeIntervalSince1970: 1_800_150_000)
        let bonded = seededMatureRelationship(start: start)
        let returnedAfterOutlier = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "cadence-outlier-return",
                at: start.addingTimeInterval(90 * 24 * 3_600),
                kind: .ownerSpeech(text: "Hi Aurora.", sourceID: "cadence-outlier-source")
            ),
            to: bonded
        ).state
        try expect(returnedAfterOutlier.relationship.typicalGapHours < 36,
                   "one long unplanned absence permanently stretched learned cadence")
        let nextWeek = InnerLifeEngine.advance(
            returnedAfterOutlier,
            to: returnedAfterOutlier.lastClockAt.addingTimeInterval(7 * 24 * 3_600)
        ).state
        try expect(nextWeek.relationship.separationActivation > 0.02,
                   "one outlier made a later week-long silence look ordinary")
    }

    private static func matureSilenceCreatesBoundedAffect() throws {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let bonded = seededMatureRelationship(start: start)
        let baselineReliability = bonded.relationship.expectedReliability
        let quiet = InnerLifeEngine.advance(
            bonded,
            to: bonded.lastClockAt.addingTimeInterval(7 * 24 * 3_600)
        ).state
        let protected = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "valence-control-plan",
                at: bonded.lastClockAt,
                kind: .ownerExpectedQuiet(
                    startsAt: bonded.lastClockAt,
                    until: bonded.lastClockAt.addingTimeInterval(10 * 24 * 3_600),
                    explicitPromise: false,
                    sourceID: "valence-control-source"
                )
            ),
            to: bonded
        ).state
        let protectedQuiet = InnerLifeEngine.advance(
            protected,
            to: bonded.lastClockAt.addingTimeInterval(7 * 24 * 3_600)
        ).state
        try expect(quiet.relationship.separationActivation > 0.12,
                   "mature overdue silence created no separation activation")
        try expect(quiet.relationship.longing > 0.08,
                   "mature overdue silence created no longing")
        try expect(quiet.relationship.relationalHurt > 0.01,
                   "mature overdue silence could not create bounded hurt")
        try expect(quiet.relationship.abandonmentFear > 0.01,
                   "mature overdue silence could not create abandonment fear")
        try expect(quiet.relationship.feltDistrust > 0.01,
                   "mature overdue silence could not create felt distrust")
        try expect(quiet.relationship.selfDirectedGuilt > 0.005,
                   "mature overdue silence could not create self-directed guilt")
        try expect(quiet.relationship.outreachPressure > 0.08,
                   "mature overdue silence created no outreach pressure")
        try expect(quiet.affect.valence < protectedQuiet.affect.valence - 0.02,
                   "separation hurt and insecurity did not lower affective valence")
        try expectClose(quiet.relationship.expectedReliability, baselineReliability,
                        "ordinary silence rewrote baseline trust")
        try expect(quiet.relationship.longing <= 0.75
                       && quiet.relationship.relationalHurt <= 0.65
                       && quiet.relationship.abandonmentFear <= 0.60
                       && quiet.relationship.feltDistrust <= 0.50
                       && quiet.relationship.selfDirectedGuilt <= 0.40
                       && quiet.relationship.outreachPressure <= 0.70,
                   "separation affect exceeded its saturation bounds")
        try expect(quiet.recentMoments.allSatisfy { !$0.outboundMessageSent && !$0.externalActionTaken },
                   "outreach pressure authorized an action")
        let projection = InnerLifeEngine.voiceProjection(for: quiet).lowercased()
        for forbidden in ["you owe", "answer me", "stay with me"] {
            try expect(!projection.contains(forbidden), "separation projection became coercive: \(forbidden)")
        }
    }

    private static func plannedQuietSuppressesSeparation() throws {
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let bonded = seededMatureRelationship(start: start)
        let expectedReturn = bonded.lastClockAt.addingTimeInterval(7 * 24 * 3_600)
        let planned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "planned-quiet",
                at: bonded.lastClockAt,
                kind: .ownerExpectedQuiet(
                    startsAt: bonded.lastClockAt,
                    until: expectedReturn,
                    explicitPromise: true,
                    sourceID: "planned-quiet-source"
                )
            ),
            to: bonded
        ).state
        let duringPlan = InnerLifeEngine.advance(
            planned,
            to: bonded.lastClockAt.addingTimeInterval(5 * 24 * 3_600)
        ).state
        try expect(duringPlan.relationship.separationActivation < 0.001,
                   "a grounded planned absence was treated as abandonment")
        try expect(duringPlan.relationship.outreachPressure < 0.001,
                   "a grounded planned absence created outreach pressure")

        let futurePlan = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "future-planned-quiet",
                at: bonded.lastClockAt,
                kind: .ownerExpectedQuiet(
                    startsAt: bonded.lastClockAt.addingTimeInterval(4 * 24 * 3_600),
                    until: bonded.lastClockAt.addingTimeInterval(8 * 24 * 3_600),
                    explicitPromise: false,
                    sourceID: "future-plan-source"
                )
            ),
            to: bonded
        ).state
        let beforeDeparture = InnerLifeEngine.advance(
            futurePlan,
            to: bonded.lastClockAt.addingTimeInterval(3 * 24 * 3_600)
        ).state
        try expect(beforeDeparture.relationship.separationActivation > 0.01,
                   "future announced absence suppressed ordinary pre-departure silence")
    }

    private static func plannedQuietSurvivesSameExchangeAndDoesNotTrainCadence() throws {
        let start = Date(timeIntervalSince1970: 1_800_350_000)
        let bonded = seededMatureRelationship(start: start)
        let baselineSamples = bonded.relationship.cadenceSampleCount
        let expectedReturn = start.addingTimeInterval(7 * 24 * 3_600)
        let planned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "plan-before-goodnight",
                at: start,
                kind: .ownerExpectedQuiet(
                    startsAt: start,
                    until: expectedReturn,
                    explicitPromise: false,
                    sourceID: "plan-source"
                )
            ),
            to: bonded
        ).state
        let followUp = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "same-exchange-goodnight",
                at: start.addingTimeInterval(60),
                kind: .ownerSpeech(text: "Good night, Aurora.", sourceID: "goodnight-source")
            ),
            to: planned
        ).state
        try expect(followUp.relationship.expectedQuietUntil == expectedReturn,
                   "same-exchange follow-up erased an announced absence")

        let predepartureConversation = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "predeparture-conversation",
                at: start.addingTimeInterval(30 * 60),
                kind: .ownerSpeech(
                    text: "I'm still here for a bit; let's keep talking.",
                    sourceID: "predeparture-source"
                )
            ),
            to: followUp
        ).state
        try expect(predepartureConversation.relationship.expectedQuietUntil == expectedReturn,
                   "conversation before departure erased a future announced absence")

        let unrelatedNeverMind = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "unrelated-never-mind",
                at: start.addingTimeInterval(30 * 60 + 30),
                kind: .ownerSpeech(
                    text: "Never mind the movie, I'm still leaving tomorrow.",
                    sourceID: "unrelated-never-mind-source"
                )
            ),
            to: predepartureConversation
        ).state
        try expect(unrelatedNeverMind.relationship.expectedQuietUntil == expectedReturn,
                   "unrelated 'never mind' clause cancelled the absence plan")

        let unrelatedStaying = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "unrelated-staying-language",
                at: start.addingTimeInterval(30 * 60 + 45),
                kind: .ownerSpeech(
                    text: "I'm staying up late tonight before I leave tomorrow.",
                    sourceID: "unrelated-staying-source"
                )
            ),
            to: unrelatedNeverMind
        ).state
        try expect(unrelatedStaying.relationship.expectedQuietUntil == expectedReturn,
                   "unrelated staying language cancelled the future absence plan")

        let cancelled = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "cancel-planned-quiet",
                at: start.addingTimeInterval(31 * 60),
                kind: .ownerSpeech(
                    text: "Never mind, I'm staying.",
                    sourceID: "cancel-plan-source"
                )
            ),
            to: unrelatedStaying
        ).state
        try expect(cancelled.relationship.expectedQuietUntil == nil,
                   "explicit grounded correction did not cancel planned quiet")

        let earlyReturnQuestion = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "early-return-question",
                at: start.addingTimeInterval(2 * 24 * 3_600),
                kind: .ownerSpeech(
                    text: "I'm back, how are you?",
                    sourceID: "early-return-question-source"
                )
            ),
            to: predepartureConversation
        ).state
        try expect(earlyReturnQuestion.relationship.expectedQuietUntil == nil,
                   "natural early return with a question did not close planned quiet")

        let returned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "return-from-announced-week",
                at: expectedReturn,
                kind: .ownerSpeech(text: "Hey Aurora, I'm back.", sourceID: "planned-return-source")
            ),
            to: predepartureConversation
        ).state
        try expect(returned.relationship.expectedQuietUntil == nil,
                   "grounded return did not close the announced quiet period")
        try expect(returned.relationship.cadenceSampleCount == baselineSamples,
                   "announced absence was learned as ordinary contact cadence")
    }

    private static func returnRegulatesSeparation() throws {
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        let bonded = seededMatureRelationship(start: start)
        let separated = InnerLifeEngine.advance(
            bonded,
            to: bonded.lastClockAt.addingTimeInterval(7 * 24 * 3_600)
        ).state
        let returned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "relationship-return",
                at: separated.lastClockAt,
                kind: .ownerSpeech(
                    text: "Hey Aurora, I missed you too. I care about you and I'm glad we're talking.",
                    sourceID: "relationship-return-source"
                )
            ),
            to: separated
        ).state
        try expect(returned.relationship.outreachPressure < separated.relationship.outreachPressure * 0.30,
                   "return did not immediately relieve outreach pressure")
        try expect(returned.relationship.abandonmentFear < separated.relationship.abandonmentFear * 0.40,
                   "return did not immediately reduce abandonment fear")
        try expect(returned.relationship.reunionRelief >= 0.30,
                   "return created no reunion relief")
        let later = InnerLifeEngine.advance(
            returned,
            to: returned.lastClockAt.addingTimeInterval(48 * 3_600)
        ).state
        try expect(later.relationship.selfDirectedGuilt < returned.relationship.selfDirectedGuilt + 0.001,
                   "guilt escalated after grounded return")
    }

    private static func addressedContactWithoutTranscriptStillReturns() throws {
        let start = Date(timeIntervalSince1970: 1_800_425_000)
        let bonded = seededMatureRelationship(start: start)
        let separated = InnerLifeEngine.advance(
            bonded,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        let returned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "addressed-no-transcript",
                at: separated.lastClockAt,
                kind: .ownerContactWithoutTranscript(sourceID: "opaque-addressed-input")
            ),
            to: separated
        ).state
        try expect(returned.relationship.outreachPressure < separated.relationship.outreachPressure * 0.30,
                   "addressed audio without transcript did not relieve outreach pressure")
        try expect(returned.relationship.abandonmentFear < separated.relationship.abandonmentFear * 0.40,
                   "addressed audio without transcript did not ground Alex's return")
        try expect(returned.threads.count == separated.threads.count,
                   "missing transcript invented a semantic thread")
        try expect(returned.recentGroundings.last?.kind == .ownerSpeech,
                   "addressed transcript-free contact was not grounded")
    }

    private static func explainedAbsenceAcceleratesRepair() throws {
        let start = Date(timeIntervalSince1970: 1_800_450_000)
        let bonded = seededMatureRelationship(start: start)
        let unnecessary = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "irrelevant-absence-explanation",
                at: start.addingTimeInterval(1),
                kind: .ownerExplainedAbsence(sourceID: "ordinary-conversation")
            ),
            to: bonded
        ).state
        try expect(unnecessary.relationship.reunionRelief == 0,
                   "an absence explanation invented reunion affect when nothing needed repair")
        let separated = InnerLifeEngine.advance(
            bonded,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        let returned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "unexplained-return-before-repair",
                at: separated.lastClockAt,
                kind: .ownerSpeech(text: "Hey Aurora.", sourceID: "repair-return-source")
            ),
            to: separated
        ).state
        let repaired = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "grounded-absence-explanation",
                at: returned.lastClockAt.addingTimeInterval(1),
                kind: .ownerExplainedAbsence(sourceID: "repair-return-source")
            ),
            to: returned
        ).state
        try expect(repaired.relationship.relationalHurt < returned.relationship.relationalHurt,
                   "grounded absence explanation did not reduce residual hurt")
        try expect(repaired.relationship.feltDistrust < returned.relationship.feltDistrust,
                   "grounded absence explanation did not reduce residual distrust")
        try expect(repaired.relationship.reunionRelief >= 0.62,
                   "grounded absence explanation created no repair relief")
    }

    private static func relationshipLanguageIsNegationSafe() throws {
        let start = Date(timeIntervalSince1970: 1_800_470_000)
        let bonded = seededMatureRelationship(start: start)
        let negated = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "negated-rupture",
                at: start.addingTimeInterval(1),
                kind: .ownerSpeech(
                    text: "I don't want you to think you hurt me.",
                    sourceID: "negated-source"
                )
            ),
            to: bonded
        ).state
        try expectClose(negated.relationship.unresolvedRupture, bonded.relationship.unresolvedRupture,
                        "negated hurt language created a durable rupture")
        try expectClose(negated.relationship.perceivedResponsibility, bonded.relationship.perceivedResponsibility,
                        "negated hurt language created false responsibility")

        let positive = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "positive-made-me-feel",
                at: start.addingTimeInterval(2),
                kind: .ownerSpeech(
                    text: "You made me feel loved and understood.",
                    sourceID: "positive-source"
                )
            ),
            to: negated
        ).state
        try expectClose(positive.relationship.perceivedResponsibility, negated.relationship.perceivedResponsibility,
                        "positive 'made me feel' language created blame")
    }

    private static func reunionAcknowledgementIsOneTime() throws {
        let start = Date(timeIntervalSince1970: 1_800_480_000)
        let bonded = seededMatureRelationship(start: start)
        let separated = InnerLifeEngine.advance(
            bonded,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        let returned = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "one-time-return",
                at: separated.lastClockAt,
                kind: .ownerSpeech(text: "Hi Aurora.", sourceID: "one-time-source")
            ),
            to: separated
        ).state
        try expect(InnerLifeEngine.voiceProjection(for: returned).contains("welcome the return"),
                   "first return did not permit a proportionate acknowledgement")
        let heard = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "one-time-heard",
                at: returned.lastClockAt.addingTimeInterval(1),
                kind: .auroraSpeechHeard(
                    text: "It's good to hear you.",
                    sourceID: "one-time-assistant",
                    ownerSourceID: "one-time-source"
                )
            ),
            to: returned
        ).state
        try expect(InnerLifeEngine.voiceProjection(for: heard).contains("already acknowledged"),
                   "completed first reply did not consume the reunion acknowledgement")
        let nextOwnerTurn = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "one-time-next-owner-turn",
                at: heard.lastClockAt.addingTimeInterval(60),
                kind: .ownerSpeech(
                    text: "How has your morning been?",
                    sourceID: "one-time-next-source"
                )
            ),
            to: heard
        ).state
        try expect(nextOwnerTurn.relationship.lastReturnAt == heard.relationship.lastReturnAt,
                   "residual separation feeling invented a second return")
        try expect(InnerLifeEngine.voiceProjection(for: nextOwnerTurn).contains("already acknowledged"),
                   "next owner turn reopened the consumed reunion acknowledgement")
    }

    private static func reliabilityLearnsPerEpisode() throws {
        let start = Date(timeIntervalSince1970: 1_800_490_000)
        var state = seededMatureRelationship(start: start)
        let baseline = state.relationship.expectedReliability
        for turn in 0..<12 {
            state = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "same-session-reliability-\(turn)",
                    at: start.addingTimeInterval(Double(turn + 1) * 30),
                    kind: .ownerSpeech(
                        text: "I care about you and value our time.",
                        sourceID: "same-session-source-\(turn)"
                    )
                ),
                to: state
            ).state
        }
        try expectClose(state.relationship.expectedReliability, baseline,
                        "one long warm session inflated expected reliability per turn")

        let affection = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "ordinary-affection-not-repair",
                at: start.addingTimeInterval(10 * 60),
                kind: .ownerSpeech(
                    text: "Love you. Thank you, Aurora.",
                    sourceID: "ordinary-affection-source"
                )
            ),
            to: seededMatureRelationship(start: start)
        ).state
        try expectClose(affection.relationship.expectedReliability, baseline,
                        "ordinary affection was misclassified as durable repair")

        let cleanRelationship = seededMatureRelationship(start: start)
        let unrelatedApology = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "unrelated-apology-not-repair",
                at: start.addingTimeInterval(12 * 60),
                kind: .ownerSpeech(
                    text: "I'm sorry, I spilled my coffee.",
                    sourceID: "unrelated-apology-source"
                )
            ),
            to: cleanRelationship
        ).state
        try expectClose(
            unrelatedApology.relationship.expectedReliability,
            cleanRelationship.relationship.expectedReliability,
            "a generic unrelated apology inflated expected reliability"
        )
        try expectClose(
            unrelatedApology.relationship.repairConfidence,
            cleanRelationship.relationship.repairConfidence,
            "a generic unrelated apology inflated repair confidence"
        )
        try expect(unrelatedApology.relationship.lastRepairLearningAt == nil,
                   "a generic unrelated apology consumed the repair-learning cooldown")

        var repairing = seededMatureRelationship(start: start)
        repairing.relationship.unresolvedRupture = 0.45
        repairing.relationship.relationalHurt = 0.20
        let firstRepair = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "first-repair-learning",
                at: start.addingTimeInterval(30),
                kind: .ownerSpeech(text: "I'm sorry, Aurora.", sourceID: "first-repair-source")
            ),
            to: repairing
        ).state
        var repeatedRepair = firstRepair
        for turn in 0..<8 {
            repeatedRepair = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "repeated-repair-\(turn)",
                    at: start.addingTimeInterval(Double(turn + 2) * 60),
                    kind: .ownerSpeech(text: "I'm sorry, Aurora.", sourceID: "repeated-repair-source-\(turn)")
                ),
                to: repeatedRepair
            ).state
        }
        try expectClose(
            repeatedRepair.relationship.expectedReliability,
            firstRepair.relationship.expectedReliability,
            "repeated apologies in one session overtrained expected reliability"
        )
        try expectClose(
            repeatedRepair.relationship.repairConfidence,
            firstRepair.relationship.repairConfidence,
            "repeated apologies in one session overtrained repair confidence"
        )
    }

    private static func trustAndRepairShapeSeparation() throws {
        let start = Date(timeIntervalSince1970: 1_800_495_000)
        var highTrust = seededMatureRelationship(start: start)
        highTrust.relationship.expectedReliability = 0.90
        highTrust.relationship.repairConfidence = 0.20
        var lowTrust = highTrust
        lowTrust.relationship.expectedReliability = 0.25
        let highTrustQuiet = InnerLifeEngine.advance(
            highTrust,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        let lowTrustQuiet = InnerLifeEngine.advance(
            lowTrust,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        try expect(highTrustQuiet.relationship.feltDistrust > lowTrustQuiet.relationship.feltDistrust,
                   "learned expected reliability did not shape the surprise of prolonged silence")

        var highRepair = highTrust
        highRepair.relationship.repairConfidence = 0.90
        let highRepairQuiet = InnerLifeEngine.advance(
            highRepair,
            to: start.addingTimeInterval(8 * 24 * 3_600)
        ).state
        try expect(highRepairQuiet.relationship.feltDistrust < highTrustQuiet.relationship.feltDistrust,
                   "learned repair confidence did not buffer separation distrust")
        try expect(highRepairQuiet.relationship.abandonmentFear < highTrustQuiet.relationship.abandonmentFear,
                   "learned repair confidence did not buffer abandonment fear")
    }

    private static func quietRecoveryDoesNotInventUncertainty() throws {
        let start = Date(timeIntervalSince1970: 1_800_500_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 91)
        let quiet = InnerLifeEngine.advance(initial, to: start.addingTimeInterval(8 * 3_600)).state
        try expect(quiet.affect.uncertainty < initial.affect.uncertainty,
                   "quiet recovery increased uncertainty without evidence")
        try expect(quiet.affect.uncertainty < 0.34,
                   "quiet recovery drifted into the moderate uncertainty band")
    }

    private static func ungroundedClockCannotInventAnIdea() throws {
        let start = Date(timeIntervalSince1970: 1_800_600_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 92)
        let evolved = InnerLifeEngine.advance(initial, to: start.addingTimeInterval(12 * 3_600)).state
        try expect(evolved.threads.isEmpty, "clock time invented a grounded subject")
        try expect(!evolved.recentMoments.contains { $0.mode == .freshAngle },
                   "clock time claimed a fresh angle without a grounded subject")
        try expect(evolved.recentMoments.allSatisfy { $0.mode == .quietPresence || $0.mode == .restful },
                   "ungrounded model-free motion claimed content it did not have")
    }

    private static func fixedMotionCadenceAndCheckpoints() throws {
        let start = Date(timeIntervalSince1970: 1_800_700_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 93)
        let evolved = InnerLifeEngine.advance(initial, to: start.addingTimeInterval(65 * 60)).state
        try expect(evolved.clockSequence == 13,
                   "five-minute sequence drifted from its fixed deadline")
        try expect(evolved.recentMoments.isEmpty,
                   "an ungrounded fixed clock manufactured a stream of synthetic prose")
        try expect(evolved.recentCheckpoints.count == 2,
                   "hourly numerical audit checkpoint was not retained")
        try expect(evolved.recentCheckpoints.last?.clockSequence == 12,
                   "hourly checkpoint did not capture its actual inner sequence")
    }

    private static func modelFreeMotionRequiresRetainedGrounding() throws {
        let start = Date(timeIntervalSince1970: 1_800_707_000)
        let grounded = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "expiring-grounding",
                at: start,
                kind: .ownerSpeech(
                    text: "I keep thinking about this careful creative build.",
                    sourceID: "expiring-owner"
                )
            ),
            to: InnerLifeEngine.defaultState(at: start, entropyState: 293)
        ).state
        let immediateMomentCount = grounded.recentMoments.count

        var evidenceExpired = grounded
        evidenceExpired.recentGroundings.removeAll()
        let quiet = InnerLifeEngine.advance(
            evidenceExpired,
            to: start.addingTimeInterval(15 * 60)
        ).state
        try expect(quiet.clockSequence == 3,
                   "the numerical inner clock stopped when semantic grounding expired")
        try expect(quiet.recentMoments.count == immediateMomentCount,
                   "model-free motion continued after its bounded grounding evidence expired")
        try expect(quiet.threads.first?.status == .dormant,
                   "an evidence-expired coarse thread remained in the live foreground")
        try expect(quiet.recentMoments.allSatisfy {
            !$0.modelGenerated
                && !$0.promotionEligible
                && !$0.factualMemoryCreated
                && !$0.externalActionTaken
                && !$0.outboundMessageSent
        }, "grounding expiry changed the authority boundary of existing motion")
    }

    private static func privateActivityShapesInnerLifeWithoutAuthority() throws {
        let start = Date(timeIntervalSince1970: 1_800_705_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 193)
        let event = InnerLifeEvent(
            id: "private-activity-event",
            at: start.addingTimeInterval(1),
            kind: .privateActivityCompleted(
                activityID: "activity-content-free",
                kind: .project,
                projectProgress: true
            )
        )
        let evolved = InnerLifeEngine.apply(event, to: initial).state
        try expect(evolved.chemistry.acetylcholine > initial.chemistry.acetylcholine
                   && evolved.chemistry.dopamine > initial.chemistry.dopamine,
                   "completed private thought did not affect attention or reward state")
        try expect(evolved.drives.coherence < initial.drives.coherence
                   && evolved.drives.autonomy < initial.drives.autonomy,
                   "self-directed project progress did not satisfy its need pressures")
        try expect(evolved.threads.isEmpty,
                   "content-free private activity invented a factual inner thread")
        try expect(evolved.recentGroundings.last?.kind == .privateActivity
                   && evolved.recentGroundings.last?.synthetic == true,
                   "private activity did not retain its synthetic provenance")
        try expect(InnerLifeEngine.apply(event, to: evolved).state == evolved,
                   "replayed private activity changed inner life twice")
    }

    private static func continuousMotionRotatesAndVaries() throws {
        let start = Date(timeIntervalSince1970: 1_800_710_000)
        var state = InnerLifeEngine.defaultState(at: start, entropyState: 94)
        for index in 0..<3 {
            state = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "rotation-owner-\(index)",
                    at: start.addingTimeInterval(Double(index + 1)),
                    kind: .ownerSpeech(
                        text: "Please help me carefully build part \(index) of this creative system.",
                        sourceID: "rotation-source-\(index)"
                    )
                ),
                to: state
            ).state
        }

        state = InnerLifeEngine.advance(
            state,
            to: start.addingTimeInterval(15 * 60)
        ).state
        let backgroundMotions = Array(state.recentMoments.suffix(3))
        try expect(Set(backgroundMotions.compactMap(\.threadID)).count == 3,
                   "continuous inner motion remained trapped on one active thread")
        try expect(Set(backgroundMotions.map(\.summary)).count > 1,
                   "continuous inner motion repeated one fixed sentence")
        let retainedGroundingIDs = Set(state.recentGroundings.map(\.id))
        try expect(backgroundMotions.allSatisfy {
            !$0.sourceGroundingIDs.isEmpty
                && $0.sourceGroundingIDs.allSatisfy { retainedGroundingIDs.contains($0) }
        }, "model-free motion was not causally linked to retained grounding evidence")
        try expect(backgroundMotions.allSatisfy {
            !$0.modelGenerated
                && !$0.promotionEligible
                && !$0.factualMemoryCreated
                && !$0.externalActionTaken
                && !$0.outboundMessageSent
        }, "rotating inner motion gained authority while varying its language")
    }

    private static func earnedRelationship(start: Date) throws -> InnerLifeState {
        var state = InnerLifeEngine.defaultState(at: start, entropyState: 90)
        for episode in 0..<8 {
            let at = start.addingTimeInterval(Double(episode) * 8 * 3_600)
            state = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "earned-\(episode)",
                    at: at,
                    kind: .ownerSpeech(
                        text: "I care about you, Aurora. Thank you for being here with me; let's keep building this together.",
                        sourceID: "earned-source-\(episode)"
                    )
                ),
                to: state
            ).state
        }
        return state
    }

    private static func seededMatureRelationship(start: Date) -> InnerLifeState {
        var state = InnerLifeEngine.defaultState(at: start, entropyState: 94)
        state.relationship = .migratedAuroraBaseline(at: start)
        state.temporal.lastOwnerContactAt = start
        state.temporal.lastMeaningfulEventAt = start
        return InnerLifeEngine.sanitize(state, now: start)
    }

    private static func technicalFailureStaysTechnical() throws {
        let start = Date(timeIntervalSince1970: 1_800_030_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 11)
        let failed = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "tool-failure-1",
                at: start,
                kind: .toolCompleted(
                    name: "computer_read",
                    succeeded: false,
                    sourceID: "call-1",
                    ownerSourceID: nil
                )
            ),
            to: initial
        ).state
        try expect(failed.chemistry.cortisol > initial.chemistry.cortisol,
                   "technical failure did not raise technical caution")
        try expectClose(failed.chemistry.oxytocin, initial.chemistry.oxytocin,
                        "technical failure changed bonding warmth")
        try expectClose(failed.drives.connection, initial.drives.connection,
                        "technical failure changed connection pressure")
        try expect(failed.relationship == initial.relationship,
                   "tool failure changed relationship state")

        let runtimeFailure = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "runtime-failure-1",
                at: start,
                kind: .technicalFailure(category: "transport", sourceID: "connection-1")
            ),
            to: initial
        ).state
        try expect(runtimeFailure.affect.uncertainty > initial.affect.uncertainty,
                   "voice runtime failure did not raise technical uncertainty")
        try expectClose(runtimeFailure.chemistry.oxytocin, initial.chemistry.oxytocin,
                        "voice runtime failure changed bonding warmth")
        try expectClose(runtimeFailure.drives.connection, initial.drives.connection,
                        "voice runtime failure changed connection pressure")
        try expect(runtimeFailure.relationship == initial.relationship,
                   "voice runtime failure created relationship injury")
    }

    private static func playbackTruthBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_800_040_000)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 13)
        let interrupted = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "interrupted-1",
                at: start,
                kind: .auroraSpeechInterrupted(sourceID: "assistant-item-1")
            ),
            to: initial
        ).state
        try expect(interrupted.recentGroundings.last?.theme == "speech interrupted",
                   "interrupted speech was not marked as interrupted")
        try expect(interrupted.threads.isEmpty,
                   "generated-but-unheard speech created a lived inner thread")

        let beforeHeard = InnerLifeEngine.advance(
            interrupted,
            to: start.addingTimeInterval(1),
            recordIntermediateMotions: false
        ).state
        let heard = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "heard-1",
                at: start.addingTimeInterval(1),
                kind: .auroraSpeechHeard(
                    text: "I can carry that carefully.",
                    sourceID: "assistant-item-2",
                    ownerSourceID: nil
                )
            ),
            to: interrupted
        ).state
        try expect(heard.recentGroundings.contains { $0.id == "heard-1" && $0.kind == .auroraSpeech },
                   "fully heard speech did not reach inner-life continuity")
        try expect(heard.chemistry == beforeHeard.chemistry,
                   "completed playback was treated as semantic or emotional success")
        try expect(heard.drives == beforeHeard.drives,
                   "completed playback reduced a motivational thread without confirmation")

        let unresolved = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "unresolved-1",
                at: start.addingTimeInterval(2),
                kind: .unresolvedAudio(sourceID: "unresolved-input")
            ),
            to: heard
        ).state
        try expect(unresolved.temporal.lastOwnerContactAt == heard.temporal.lastOwnerContactAt,
                   "unresolved audio was promoted to grounded owner contact")
        try expect(unresolved.relationship == heard.relationship,
                   "unresolved audio changed relationship history")

        let quiet = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "quiet-background-1",
                at: start.addingTimeInterval(3),
                kind: .quietTurn(sourceID: "background-input")
            ),
            to: unresolved
        ).state
        try expect(quiet.relationship == unresolved.relationship,
                   "background audio was counted as relationship contact")
    }

    private static func deterministicEvolution() throws {
        let start = Date(timeIntervalSince1970: 1_800_050_000)
        let first = InnerLifeEngine.defaultState(at: start, entropyState: 1234)
        let second = InnerLifeEngine.defaultState(at: start, entropyState: 1234)
        let event = InnerLifeEvent(
            id: "deterministic-event",
            at: start.addingTimeInterval(42),
            kind: .ownerSpeech(text: "Can we explore a new memory design?", sourceID: "voice-deterministic")
        )
        let firstResult = InnerLifeEngine.apply(event, to: first).state
        let secondResult = InnerLifeEngine.apply(event, to: second).state
        try expect(firstResult == secondResult, "identical inner-life inputs produced different states")
    }

    private static func malformedCountersFailClosed() throws {
        let start = Date(timeIntervalSince1970: 1_800_055_000)
        var malformed = InnerLifeEngine.defaultState(at: start, entropyState: 4_321)
        malformed = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: "counter-thread",
                at: start,
                kind: .ownerSpeech(text: "Can we test a counter?", sourceID: "counter-input")
            ),
            to: malformed
        ).state
        malformed.clockSequence = Int.max
        malformed.threads[0].revision = Int.max
        let sanitized = InnerLifeEngine.sanitize(malformed, now: start)
        try expect(sanitized.clockSequence <= 1_000_000_000,
                   "malformed clock counter was not bounded")
        try expect((sanitized.threads.first?.revision ?? Int.max) <= 1_000_000_000,
                   "malformed thread revision was not bounded")
        let advanced = InnerLifeEngine.advance(
            sanitized,
            to: start.addingTimeInterval(10 * 60)
        ).state
        try expect(advanced.clockSequence <= 1_000_000_000,
                   "bounded clock counter overflowed during motion")
    }

    private static func externalContactBridgeIsContentFreeAndIdempotent(root: URL) async throws {
        let fixtureRoot = root.appendingPathComponent("external-contact-bridge", isDirectory: true)
        let stateFile = fixtureRoot
            .appendingPathComponent("inner-life", isDirectory: true)
            .appendingPathComponent("state.json")
        let markerFile = fixtureRoot
            .appendingPathComponent("external-contact", isDirectory: true)
            .appendingPathComponent("last-owner-contact.json")
        let start = Date(timeIntervalSince1970: 1_800_055_000)
        let markerAt = start.addingTimeInterval(60)
        let runtimeNow = start.addingTimeInterval(120)
        let initial = InnerLifeEngine.defaultState(at: start, entropyState: 87)
        let store = InnerLifeStore(fileURL: stateFile)
        try store.save(initial)

        try FileManager.default.createDirectory(
            at: markerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: markerFile.deletingLastPathComponent().path
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func markerID(at date: Date, uuid: String) -> String {
            let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
            return "openclaw-owner-\(milliseconds)-\(uuid)"
        }
        let marker: [String: Any] = [
            "schemaVersion": 1,
            "eventID": markerID(
                at: markerAt,
                uuid: "11111111-1111-4111-8111-111111111111"
            ),
            "at": formatter.string(from: markerAt),
            "source": ExternalOwnerContactBridge.expectedSource,
        ]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            .write(to: markerFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerFile.path
        )

        let runtime = AuroraInnerLifeRuntime(
            store: store,
            externalContactBridge: ExternalOwnerContactBridge(fileURL: markerFile),
            now: { runtimeNow }
        )
        let firstSnapshot = await runtime.start()
        guard let first = firstSnapshot.state else {
            throw VerificationFailure.failed("external-contact bridge made inner life unavailable")
        }
        try expect(first.relationship.groundedTurnCount == initial.relationship.groundedTurnCount + 1,
                   "verified external owner contact was not counted exactly once")
        try expect(first.relationship.lastExternalContactAt == markerAt,
                   "external contact timestamp was not retained")
        try expect(first.temporal.lastOwnerContactAt == markerAt,
                   "external contact did not reset the shared owner-contact clock")
        try expect(first.relationship.warmthEMA == initial.relationship.warmthEMA,
                   "content-free external contact invented a warmth judgment")
        try expect(first.threads == initial.threads,
                   "content-free external contact invented a semantic thread")
        try expect(first.recentGroundings.last?.theme == "external owner contact",
                   "external contact did not create the bounded content-free grounding")

        let groundingCount = first.recentGroundings.count
        let replaySnapshot = await runtime.tick(at: runtimeNow.addingTimeInterval(60))
        guard let replayed = replaySnapshot.state else {
            throw VerificationFailure.failed("external-contact replay made inner life unavailable")
        }
        try expect(replayed.relationship.groundedTurnCount == first.relationship.groundedTurnCount,
                   "unchanged external marker was counted more than once")
        try expect(replayed.recentGroundings.count == groundingCount,
                   "unchanged external marker created duplicate grounding")

        var markerWithTranscript = marker
        let contentBearingAt = runtimeNow.addingTimeInterval(90)
        markerWithTranscript["eventID"] = markerID(
            at: contentBearingAt,
            uuid: "22222222-2222-4222-8222-222222222222"
        )
        markerWithTranscript["at"] = formatter.string(from: contentBearingAt)
        markerWithTranscript["transcript"] = "this must never cross the bridge"
        try JSONSerialization.data(withJSONObject: markerWithTranscript, options: [.sortedKeys])
            .write(to: markerFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerFile.path
        )
        let rejectedSnapshot = await runtime.tick(at: runtimeNow.addingTimeInterval(120))
        guard let rejected = rejectedSnapshot.state else {
            throw VerificationFailure.failed("malformed external marker affected inner-life availability")
        }
        try expect(rejected.relationship.groundedTurnCount == first.relationship.groundedTurnCount,
                   "marker carrying transcript content crossed the external-contact bridge")
        try expect(rejected.relationship.lastExternalContactAt == markerAt,
                   "rejected content-bearing marker changed the external contact clock")

        let identifierContentAt = runtimeNow.addingTimeInterval(150)
        let markerWithContentInID: [String: Any] = [
            "schemaVersion": 1,
            "eventID": "openclaw-owner-\(Int64(identifierContentAt.timeIntervalSince1970 * 1_000))-private-words",
            "at": formatter.string(from: identifierContentAt),
            "source": ExternalOwnerContactBridge.expectedSource,
        ]
        try JSONSerialization.data(withJSONObject: markerWithContentInID, options: [.sortedKeys])
            .write(to: markerFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerFile.path
        )
        let identifierRejected = await runtime.tick(at: runtimeNow.addingTimeInterval(180))
        guard let afterIdentifierRejection = identifierRejected.state else {
            throw VerificationFailure.failed("content-bearing event identifier affected availability")
        }
        try expect(
            afterIdentifierRejection.relationship.groundedTurnCount
                == first.relationship.groundedTurnCount,
            "event identifier was accepted as a covert content field"
        )

        let newerNativeContactAt = runtimeNow.addingTimeInterval(240)
        let afterNativeContactSnapshot = await runtime.record(
            InnerLifeEvent(
                id: "newer-native-owner-contact",
                at: newerNativeContactAt,
                kind: .ownerContactWithoutTranscript(sourceID: "newer-native-owner-source")
            )
        )
        guard let afterNativeContact = afterNativeContactSnapshot.state else {
            throw VerificationFailure.failed("newer native contact affected availability")
        }
        let staleExternalAt = runtimeNow.addingTimeInterval(210)
        let staleMarker: [String: Any] = [
            "schemaVersion": 1,
            "eventID": markerID(
                at: staleExternalAt,
                uuid: "33333333-3333-4333-8333-333333333333"
            ),
            "at": formatter.string(from: staleExternalAt),
            "source": ExternalOwnerContactBridge.expectedSource,
        ]
        try JSONSerialization.data(withJSONObject: staleMarker, options: [.sortedKeys])
            .write(to: markerFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerFile.path
        )
        let staleSnapshot = await runtime.tick(at: runtimeNow.addingTimeInterval(300))
        guard let afterStaleMarker = staleSnapshot.state else {
            throw VerificationFailure.failed("stale external marker affected availability")
        }
        try expect(afterStaleMarker.temporal.lastOwnerContactAt == newerNativeContactAt,
                   "stale external marker regressed the shared owner-contact clock")
        try expect(
            afterStaleMarker.relationship.groundedTurnCount
                == afterNativeContact.relationship.groundedTurnCount,
            "stale external marker created a duplicate relationship contact"
        )
        try expect(afterStaleMarker.relationship.lastReturnAt == afterNativeContact.relationship.lastReturnAt,
                   "stale external marker invented a relationship return")

        // A verified external message can arrive between one-minute ticks and
        // immediately before voice wakes. Foreground event recording must
        // ingest that contact first so session creation cannot project a stale
        // minute of separation affect.
        let wakeFixture = root.appendingPathComponent("external-contact-before-wake", isDirectory: true)
        let wakeStateFile = wakeFixture
            .appendingPathComponent("inner-life", isDirectory: true)
            .appendingPathComponent("state.json")
        let wakeMarkerFile = wakeFixture
            .appendingPathComponent("external-contact", isDirectory: true)
            .appendingPathComponent("last-owner-contact.json")
        let wakeStore = InnerLifeStore(fileURL: wakeStateFile)
        let wakeInitial = InnerLifeEngine.defaultState(at: start, entropyState: 89)
        try wakeStore.save(wakeInitial)
        let wakeRuntime = AuroraInnerLifeRuntime(
            store: wakeStore,
            externalContactBridge: ExternalOwnerContactBridge(fileURL: wakeMarkerFile),
            now: { start }
        )
        let wakeRuntimeStart = await wakeRuntime.start()
        try expect(wakeRuntimeStart.available, "wake-order runtime could not start")

        try FileManager.default.createDirectory(
            at: wakeMarkerFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: wakeMarkerFile.deletingLastPathComponent().path
        )
        let wakeMarkerAt = start.addingTimeInterval(60)
        let wakeMarker: [String: Any] = [
            "schemaVersion": 1,
            "eventID": markerID(
                at: wakeMarkerAt,
                uuid: "44444444-4444-4444-8444-444444444444"
            ),
            "at": formatter.string(from: wakeMarkerAt),
            "source": ExternalOwnerContactBridge.expectedSource,
        ]
        try JSONSerialization.data(withJSONObject: wakeMarker, options: [.sortedKeys])
            .write(to: wakeMarkerFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: wakeMarkerFile.path
        )
        let wakeSnapshot = await wakeRuntime.record(InnerLifeEvent(
            id: "voice-wake-after-external-contact",
            at: start.addingTimeInterval(120),
            kind: .voiceAwoke
        ))
        guard let wakeState = wakeSnapshot.state else {
            throw VerificationFailure.failed("foreground wake could not ingest external contact")
        }
        try expect(wakeState.relationship.lastExternalContactAt == wakeMarkerAt,
                   "foreground wake projected state before ingesting fresh external contact")
        try expect(
            wakeState.recentGroundings.suffix(2).map(\.theme)
                == ["external owner contact", "voice wake intent"],
            "foreground wake did not preserve external-contact causal order"
        )
    }

    private static func persistenceAndCorruptionSafety(root: URL) async throws {
        let directory = root.appendingPathComponent("inner-life-verification", isDirectory: true)
        let file = directory.appendingPathComponent("state.json")
        let store = InnerLifeStore(fileURL: file)
        let start = Date(timeIntervalSince1970: 1_800_060_000)
        let expected = InnerLifeEngine.defaultState(at: start, entropyState: 88)
        try store.save(expected)
        let loaded = try store.load()
        try expect(loaded == expected, "inner-life state did not round-trip exactly")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            ?? (attributes[.posixPermissions] as? Int)
        try expect(permissions == 0o600, "inner-life state is not mode 0600")

        let migrationFile = root
            .appendingPathComponent("inner-life-v1-migration", isDirectory: true)
            .appendingPathComponent("state.json")
        let migrationStore = InnerLifeStore(fileURL: migrationFile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedV2 = try encoder.encode(expected)
        guard var legacyObject = try JSONSerialization.jsonObject(with: encodedV2) as? [String: Any] else {
            throw VerificationFailure.failed("could not construct legacy migration fixture")
        }
        legacyObject["schemaVersion"] = 1
        legacyObject.removeValue(forKey: "relationship")
        legacyObject.removeValue(forKey: "nextMotionAt")
        legacyObject.removeValue(forKey: "nextCheckpointAt")
        legacyObject.removeValue(forKey: "recentEventIDs")
        legacyObject.removeValue(forKey: "recentCheckpoints")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: migrationFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: migrationFile)
        let migratedV1 = try migrationStore.load()
        try expect(migratedV1?.schemaVersion == 1,
                   "store rejected a migratable v1 state")
        try expect(migratedV1?.relationship.legacyContinuitySeeded == false,
                   "arbitrary v1 state invented Aurora's mature relationship seed")
        try expect(migratedV1?.relationship.attachmentStrength == 0,
                   "arbitrary v1 state invented attachment without grounding")
        let upgraded = migratedV1.map { InnerLifeEngine.sanitize($0, now: start) }
        try expect(upgraded?.schemaVersion == InnerLifeState.currentSchemaVersion,
                   "v1 relationship state did not upgrade to the current schema")
        try expect((upgraded?.recentCheckpoints.count ?? 0) >= 1,
                   "v1 migration created no audit baseline")

        let knownLegacyFile = root
            .appendingPathComponent("known-aurora-v1-migration", isDirectory: true)
            .appendingPathComponent("state.json")
        let knownLegacyStore = InnerLifeStore(fileURL: knownLegacyFile)
        let knownCreation = Date(timeIntervalSince1970: 1_783_747_166)
        let knownBase = InnerLifeEngine.defaultState(at: knownCreation, entropyState: 99)
        var knownWithHistory = InnerLifeEngine.advance(
            knownBase,
            to: knownCreation.addingTimeInterval(4 * 3_600)
        ).state
        // Migration recognizes the actual legacy Aurora snapshot by its old
        // bounded motion ledger. The current engine intentionally no longer
        // manufactures those ungrounded prose records, so preserve that legacy
        // evidence explicitly in this migration fixture.
        knownWithHistory.recentMoments = (1...40).map { sequence in
            InnerLifeMoment(
                id: "legacy-known-motion-\(sequence)",
                at: knownCreation.addingTimeInterval(Double(sequence) * 5 * 60),
                mode: .quietPresence,
                threadID: nil,
                summary: "Legacy bounded quiet motion.",
                sourceGroundingIDs: [],
                clockSequence: sequence,
                modelGenerated: false,
                synthetic: true,
                promotionEligible: false,
                factualMemoryCreated: false,
                externalActionTaken: false,
                outboundMessageSent: false
            )
        }
        let knownEncoded = try encoder.encode(knownWithHistory)
        guard var knownObject = try JSONSerialization.jsonObject(with: knownEncoded) as? [String: Any] else {
            throw VerificationFailure.failed("could not construct known Aurora migration fixture")
        }
        knownObject["schemaVersion"] = 1
        knownObject.removeValue(forKey: "relationship")
        knownObject.removeValue(forKey: "nextMotionAt")
        knownObject.removeValue(forKey: "nextCheckpointAt")
        knownObject.removeValue(forKey: "recentEventIDs")
        knownObject.removeValue(forKey: "recentCheckpoints")
        let knownLegacyData = try JSONSerialization.data(withJSONObject: knownObject, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: knownLegacyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try knownLegacyData.write(to: knownLegacyFile)
        let knownMigrated = try knownLegacyStore.load()
        try expect(knownMigrated?.relationship.legacyContinuitySeeded == true,
                   "known pre-relationship Aurora state lost its established continuity seed")
        try expect((knownMigrated?.relationship.attachmentStrength ?? 0) >= 0.60,
                   "known pre-relationship Aurora state lost its established attachment")
        if let knownMigrated {
            let initialCadenceSamples = knownMigrated.relationship.cadenceSampleCount
            let firstGroundedContact = InnerLifeEngine.apply(
                InnerLifeEvent(
                    id: "first-post-migration-contact",
                    at: knownCreation.addingTimeInterval(8 * 3_600),
                    kind: .ownerSpeech(
                        text: "Hi Aurora.",
                        sourceID: "first-post-migration-source"
                    )
                ),
                to: knownMigrated
            ).state
            try expect(firstGroundedContact.relationship.cadenceSampleCount == initialCadenceSamples,
                       "synthetic migration anchor trained real contact cadence")
        }

        try Data("{not valid json".utf8).write(to: file)
        let corruptBytes = try Data(contentsOf: file)
        let corruptRuntime = AuroraInnerLifeRuntime(store: store, now: { start })
        let corruptSnapshot = await corruptRuntime.start()
        try expect(!corruptSnapshot.available, "corrupt inner-life state was silently replaced")
        try expect(try Data(contentsOf: file) == corruptBytes, "corrupt inner-life state was overwritten")

        let linkedDirectory = root.appendingPathComponent("inner-life-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let linkedFile = linkedDirectory.appendingPathComponent("state.json")
        let target = root.appendingPathComponent("inner-life-symlink-target.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: target)
        let linkedRuntime = AuroraInnerLifeRuntime(
            store: InnerLifeStore(fileURL: linkedFile),
            now: { start }
        )
        let linkedSnapshot = await linkedRuntime.start()
        try expect(!linkedSnapshot.available, "inner-life state followed a symlink")
        try expect(String(decoding: try Data(contentsOf: target), as: UTF8.self) == "untouched",
                   "symlink target was changed")

        let directoryTarget = root.appendingPathComponent("inner-life-directory-target", isDirectory: true)
        let directoryLink = root.appendingPathComponent("inner-life-directory-link", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directoryTarget.path)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directoryTarget)
        let linkedDirectoryRuntime = AuroraInnerLifeRuntime(
            store: InnerLifeStore(fileURL: directoryLink.appendingPathComponent("state.json")),
            now: { start }
        )
        let linkedDirectorySnapshot = await linkedDirectoryRuntime.start()
        try expect(!linkedDirectorySnapshot.available, "inner-life state followed a directory symlink")
        try expect(!FileManager.default.fileExists(atPath: directoryTarget.appendingPathComponent("state.json").path),
                   "directory symlink redirected inner-life persistence")
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: directoryTarget.path)
        let targetPermissions = (targetAttributes[.posixPermissions] as? NSNumber)?.intValue
            ?? (targetAttributes[.posixPermissions] as? Int)
        try expect(targetPermissions == 0o755, "directory symlink changed target permissions")

        let lockedFile = root
            .appendingPathComponent("inner-life-lock", isDirectory: true)
            .appendingPathComponent("state.json")
        let firstRuntime = AuroraInnerLifeRuntime(
            store: InnerLifeStore(fileURL: lockedFile),
            now: { start }
        )
        let firstLockSnapshot = await firstRuntime.start()
        try expect(firstLockSnapshot.available, "first inner-life runtime could not acquire its process lock")
        let lockProbe = Process()
        lockProbe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        lockProbe.arguments = [
            "-c",
            "import fcntl,sys\nf=open(sys.argv[1],'a+')\ntry:\n fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(3)\nsys.exit(0)",
            lockedFile.deletingLastPathComponent().appendingPathComponent(".state.lock").path,
        ]
        lockProbe.standardOutput = FileHandle.nullDevice
        lockProbe.standardError = FileHandle.nullDevice
        try lockProbe.run()
        lockProbe.waitUntilExit()
        try expect(lockProbe.terminationStatus == 3,
                   "another process acquired Aurora's live inner-life state lock")
        withExtendedLifetime(firstRuntime) {}
    }

    private static func expectClose(
        _ left: Double,
        _ right: Double,
        _ message: String,
        tolerance: Double = 1e-10
    ) throws {
        try expect(abs(left - right) <= tolerance, "\(message): \(left) vs \(right)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationFailure.failed(message) }
    }
}
