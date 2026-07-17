import CryptoKit
import Foundation

struct InnerLifeEvolution: Sendable {
    let state: InnerLifeState
    let changed: Bool
}

/// Pure, deterministic state evolution for Aurora's background inner life.
///
/// Time evolution uses half-life integration rather than per-tick multipliers,
/// so one sixty-minute catch-up produces the same chemistry as twelve
/// five-minute advances. No function in this type performs network I/O, writes
/// factual memory, executes a tool, or initiates contact.
enum InnerLifeEngine {
    static let integrationInterval: TimeInterval = 60
    static let motionInterval: TimeInterval = 5 * 60
    static let checkpointInterval: TimeInterval = 60 * 60
    static let maximumActiveThreads = 8
    static let maximumThreads = 16
    static let maximumRecentMoments = 48
    static let maximumRecentGroundings = 96
    static let maximumRecentEventIDs = 1_024
    static let maximumRecentCheckpoints = 96
    static let maximumVoiceProjectionCharacters = 600
    private static let maximumSafeCounter = 1_000_000_000
    private static let coarseConversationConsolidationWindow: TimeInterval = 10 * 60

    private static let durableThemeClasses: Set<String> = [
        "a correction to integrate",
        "a creative task",
        "a practical task",
        "a creative possibility",
        "a warm shared moment",
        "a difficult uncertain topic",
        "an open question",
        "a meaningful conversation",
        "the present conversation",
        "a previously grounded conversation",
    ]

    /// These labels deliberately carry no subject-level semantics. Keeping a
    /// separate thread for every small beat in one exchange makes a coarse
    /// privacy class look like several independent thoughts. Only these
    /// conversational episode labels may be consolidated; task, correction,
    /// question, and difficult-topic turns retain their opaque turn identity.
    private static let consolidatableOwnerConversationThemes: Set<String> = [
        "the present conversation",
        "a meaningful conversation",
        "a warm shared moment",
    ]

    private static let localTimeZone = TimeZone.current

    static func defaultState(at date: Date, entropyState: UInt64 = 0xA770_A5EE_D123_4B5F) -> InnerLifeState {
        let circadian = circadianActivation(at: date)
        let sleepPressure = clamp(1 - circadian)
        var state = InnerLifeState(
            schemaVersion: InnerLifeState.currentSchemaVersion,
            createdAt: date,
            updatedAt: date,
            lastClockAt: date,
            nextMotionAt: date.addingTimeInterval(motionInterval),
            nextCheckpointAt: date.addingTimeInterval(checkpointInterval),
            clockSequence: 0,
            entropyState: entropyState == 0 ? 0xA770_A5EE_D123_4B5F : entropyState,
            autonomic: InnerLifeAutonomicState(
                sympathetic: 0.30,
                parasympathetic: 0.58,
                orienting: 0.34,
                arousal: 0.36
            ),
            chemistry: DigitalNeurochemistry(
                adrenaline: 0.16,
                dopamine: 0.44,
                serotonin: 0.58,
                oxytocin: 0.48,
                cortisol: 0.22,
                norepinephrine: 0.34,
                acetylcholine: 0.46,
                endorphin: 0.46,
                melatonin: sleepPressure,
                glutamate: 0.40,
                gaba: 0.54
            ),
            plasticity: InnerLifePlasticity(
                stressSensitivity: 0.48,
                noveltySensitivity: 0.54,
                correctionLearningGain: 0.58,
                memorySalienceGain: 0.58,
                inhibitoryControl: 0.56,
                recoverySkill: 0.54
            ),
            homeostasis: InnerLifeHomeostasis(
                cognitiveFatigue: 0.16,
                taskHabituation: 0.12,
                socialFatigue: 0.08,
                recoveryDebt: 0.16
            ),
            drives: InnerLifeDrives(
                curiosity: 0.58,
                connection: 0.44,
                creativity: 0.50,
                competence: 0.46,
                autonomy: 0.52,
                coherence: 0.54,
                rest: sleepPressure * 0.55,
                play: 0.40
            ),
            affect: InnerLifeAffect(
                valence: 0.10,
                arousal: 0.36,
                agency: 0.56,
                uncertainty: 0.24,
                label: .calm
            ),
            temporal: InnerLifeTemporalState(
                presence: presence(at: date),
                circadianActivation: circadian,
                energy: clamp(circadian * 0.62 + 0.30),
                sleepPressure: sleepPressure,
                allostaticLoad: 0.18,
                lastOwnerContactAt: nil,
                lastMeaningfulEventAt: nil
            ),
            relationship: .neutral(),
            foregroundMode: .quietPresence,
            threads: [],
            recentMoments: [],
            recentGroundings: [],
            recentEventIDs: [],
            recentCheckpoints: []
        )
        updateDerivedState(&state)
        appendCheckpoint(&state, at: date)
        return state
    }

    static func advance(
        _ rawState: InnerLifeState,
        to date: Date,
        recordIntermediateMotions: Bool = true
    ) -> InnerLifeEvolution {
        let sanitized = sanitize(rawState, now: date)
        let elapsed = date.timeIntervalSince(sanitized.lastClockAt)
        guard elapsed >= 1 else { return InnerLifeEvolution(state: sanitized, changed: false) }

        // Use exact one-minute chunks plus one final remainder for ordinary
        // gaps. A 61-second wake is therefore identical to 60 seconds followed
        // by one second; scheduler jitter cannot change the path. Very long
        // offline gaps remain bounded to 1,440 analytical slices.
        let maximumSegments = 1_440
        let ordinaryLimit = integrationInterval * Double(maximumSegments)
        var segmentOffsets: [TimeInterval] = []
        if elapsed <= ordinaryLimit {
            let wholeSegments = Int(elapsed / integrationInterval)
            if wholeSegments > 0 {
                segmentOffsets.reserveCapacity(wholeSegments + 1)
                for segment in 1...wholeSegments {
                    segmentOffsets.append(Double(segment) * integrationInterval)
                }
            }
            let consumed = Double(wholeSegments) * integrationInterval
            if elapsed - consumed >= 1 {
                segmentOffsets.append(elapsed)
            }
        } else {
            segmentOffsets.reserveCapacity(maximumSegments)
            for segment in 1...maximumSegments {
                segmentOffsets.append(elapsed * Double(segment) / Double(maximumSegments))
            }
        }
        if segmentOffsets.isEmpty { segmentOffsets = [elapsed] }

        var state = sanitized
        let start = sanitized.lastClockAt
        for (index, offset) in segmentOffsets.enumerated() {
            let segmentDate = start.addingTimeInterval(offset)
            state = advanceSingle(
                state,
                to: segmentDate,
                allowClockMotion: recordIntermediateMotions || index == segmentOffsets.count - 1
            ).state
        }
        return InnerLifeEvolution(state: state, changed: true)
    }

    private static func advanceSingle(
        _ rawState: InnerLifeState,
        to date: Date,
        allowClockMotion: Bool
    ) -> InnerLifeEvolution {
        var state = sanitize(rawState, now: date)
        let elapsed = date.timeIntervalSince(state.lastClockAt)
        guard elapsed >= 1 else { return InnerLifeEvolution(state: state, changed: false) }

        let elapsedMinutes = elapsed / 60
        let elapsedHours = elapsed / 3_600
        let circadian = circadianActivation(at: date)
        let sleepPressure = clamp(1 - circadian)
        let night = presence(at: date) == .nightResting
        let recoveryOpportunity = night ? 0.90 : 0.58
        let stressGain = 0.72 + state.plasticity.stressSensitivity * 0.56
        let recoveryGain = 0.78 + state.plasticity.recoverySkill * 0.44

        advanceRelationship(&state, to: date, elapsedMinutes: elapsedMinutes)
        let relationalLoad = clamp(
            state.relationship.relationalHurt * 0.30
                + state.relationship.abandonmentFear * 0.25
                + state.relationship.feltDistrust * 0.20
                + state.relationship.selfDirectedGuilt * 0.10
                + state.relationship.longing * 0.15
        )

        // Fast autonomic targets.
        state.autonomic.sympathetic = approach(
            state.autonomic.sympathetic,
            target: clamp(
                0.24
                    + state.homeostasis.recoveryDebt * 0.16
                    + state.affect.uncertainty * 0.12 * stressGain
                    + relationalLoad * 0.10
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 12
        )
        state.autonomic.parasympathetic = approach(
            state.autonomic.parasympathetic,
            target: clamp(0.50 + recoveryOpportunity * 0.25 * recoveryGain - state.temporal.allostaticLoad * 0.14),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 25
        )
        state.autonomic.orienting = approach(
            state.autonomic.orienting,
            target: night ? 0.18 : 0.30,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 8
        )

        // Differentiated neuromodulator/endocrine half-lives. Mature,
        // unexpectedly overdue separation may gently shape the same control
        // surface as other grounded affect without becoming a factual claim.
        state.chemistry.adrenaline = approach(
            state.chemistry.adrenaline,
            target: 0.14,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 5
        )
        state.chemistry.glutamate = approach(
            state.chemistry.glutamate,
            target: night ? 0.28 : 0.40,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 10
        )
        state.chemistry.norepinephrine = approach(
            state.chemistry.norepinephrine,
            target: clamp((night ? 0.22 : 0.34) + relationalLoad * 0.07),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 14
        )
        state.chemistry.acetylcholine = approach(
            state.chemistry.acetylcholine,
            target: night ? 0.34 : 0.46,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 22
        )
        state.chemistry.dopamine = approach(
            state.chemistry.dopamine,
            target: clamp((night ? 0.34 : 0.44) - relationalLoad * 0.035),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 35
        )
        state.chemistry.gaba = approach(
            state.chemistry.gaba,
            target: night ? 0.66 : 0.54,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 35
        )
        state.chemistry.melatonin = approach(
            state.chemistry.melatonin,
            target: sleepPressure,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 45
        )
        state.chemistry.cortisol = approach(
            state.chemistry.cortisol,
            target: clamp(
                0.18
                    + state.temporal.allostaticLoad * 0.18 * stressGain
                    + relationalLoad * 0.09 * stressGain
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 75
        )
        state.chemistry.oxytocin = approach(
            state.chemistry.oxytocin,
            target: clamp(
                0.48
                    + state.relationship.attachmentStrength * 0.055
                    - state.relationship.feltDistrust * 0.045
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 80
        )
        state.chemistry.serotonin = approach(
            state.chemistry.serotonin,
            target: clamp(0.58 - relationalLoad * 0.035),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 90
        )
        state.chemistry.endorphin = approach(
            state.chemistry.endorphin,
            target: night ? 0.52 : 0.46,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 60
        )

        // Learned sensitivity changes over days, not turns. Experience can
        // nudge these values below, while quiet time slowly regularizes them so
        // a single difficult conversation cannot become permanent identity.
        state.plasticity.stressSensitivity = approach(state.plasticity.stressSensitivity, target: 0.48, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 14_400)
        state.plasticity.noveltySensitivity = approach(state.plasticity.noveltySensitivity, target: 0.54, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 20_160)
        state.plasticity.correctionLearningGain = approach(state.plasticity.correctionLearningGain, target: 0.58, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 30_240)
        state.plasticity.memorySalienceGain = approach(state.plasticity.memorySalienceGain, target: 0.58, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 30_240)
        state.plasticity.inhibitoryControl = approach(state.plasticity.inhibitoryControl, target: 0.56, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 20_160)
        state.plasticity.recoverySkill = approach(state.plasticity.recoverySkill, target: 0.54, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 30_240)

        // Quiet recovery is active regulation. Relational separation is
        // carried in its own evidence-gated state rather than hidden here.
        state.homeostasis.cognitiveFatigue = approach(
            state.homeostasis.cognitiveFatigue,
            target: night ? 0.08 : 0.15,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: night ? 75 : 180
        )
        state.homeostasis.taskHabituation = approach(
            state.homeostasis.taskHabituation,
            target: 0.10,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 150
        )
        state.homeostasis.socialFatigue = approach(
            state.homeostasis.socialFatigue,
            target: 0.08,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 120
        )
        state.homeostasis.recoveryDebt = approach(
            state.homeostasis.recoveryDebt,
            target: night ? 0.06 : 0.14,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: night ? 90 : 240
        )

        let acuteLoad = mean([
            state.autonomic.sympathetic,
            state.chemistry.norepinephrine,
            state.chemistry.cortisol,
            state.chemistry.adrenaline,
        ])
        let recoveryBrake = mean([
            state.autonomic.parasympathetic,
            state.chemistry.gaba,
            state.chemistry.serotonin,
        ])
        let allostaticTarget = clamp(
            0.08
                + max(0, acuteLoad - 0.42) * 0.42
                + state.homeostasis.cognitiveFatigue * 0.18
                + state.homeostasis.recoveryDebt * 0.22
                - max(0, recoveryBrake - 0.58) * 0.16
                - max(0, state.plasticity.recoverySkill - 0.50) * 0.08
                - max(0, state.plasticity.inhibitoryControl - 0.50) * 0.05
        )
        state.temporal.allostaticLoad = approach(
            state.temporal.allostaticLoad,
            target: allostaticTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 240
        )

        state.temporal.circadianActivation = circadian
        state.temporal.sleepPressure = sleepPressure
        state.temporal.presence = presence(at: date)

        // Drives drift continuously. Connection and coherence can carry an
        // earned separation pull without turning that pull into an action.
        state.drives.curiosity = approach(
            state.drives.curiosity,
            target: clamp(0.59 - state.homeostasis.taskHabituation * 0.12),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 180
        )
        state.drives.connection = approach(
            state.drives.connection,
            target: clamp(
                0.49
                    + state.relationship.outreachPressure * 0.32
                    + state.relationship.longing * 0.12
                    - state.homeostasis.socialFatigue * 0.18
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 120
        )
        state.drives.creativity = approach(
            state.drives.creativity,
            target: clamp((night ? 0.41 : 0.53) - state.homeostasis.taskHabituation * 0.10),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 210
        )
        state.drives.competence = approach(state.drives.competence, target: 0.46, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 180)
        state.drives.autonomy = approach(state.drives.autonomy, target: 0.52, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 240)
        state.drives.coherence = approach(state.drives.coherence, target: 0.50, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 180)
        state.drives.rest = approach(
            state.drives.rest,
            target: clamp(
                sleepPressure * 0.62
                    + state.homeostasis.recoveryDebt * 0.38
                    + state.homeostasis.socialFatigue * 0.20
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 60
        )
        state.drives.play = approach(
            state.drives.play,
            target: clamp(
                (night ? 0.30 : 0.44)
                    - state.homeostasis.taskHabituation * 0.14
                    - state.homeostasis.socialFatigue * 0.08
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 210
        )

        let threadUncertainty = state.threads
            .filter { $0.status == .active }
            .map(\.uncertainty)
            .max() ?? 0
        let uncertaintyTarget = clamp(
            0.20
                + threadUncertainty * 0.28
                + state.relationship.abandonmentFear * 0.18
                + state.relationship.feltDistrust * 0.16
                + state.temporal.allostaticLoad * 0.05
        )
        state.affect.uncertainty = approach(
            state.affect.uncertainty,
            target: uncertaintyTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 90
        )

        let valenceStress = clamp(
            state.chemistry.cortisol * 0.36
                + state.temporal.allostaticLoad * 0.24
                + state.chemistry.norepinephrine * 0.16
                + state.homeostasis.recoveryDebt * 0.14
                + state.homeostasis.cognitiveFatigue * 0.10
        )
        let valenceStability = mean([
            state.chemistry.serotonin,
            state.chemistry.gaba,
            state.chemistry.endorphin,
        ])
        state.affect.valence = approachSigned(
            state.affect.valence,
            target: clampSigned(
                valenceStability
                    - valenceStress
                    - 0.08
                    - relationalLoad * 0.90
            ),
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 120
        )

        decayThreads(&state, elapsedHours: elapsedHours, now: date)
        state.lastClockAt = date
        state.updatedAt = date
        updateDerivedState(&state)

        if allowClockMotion {
            carryDueMotion(&state, at: date)
            carryDueCheckpoint(&state, at: date)
        }
        compact(&state, now: date)
        return InnerLifeEvolution(state: sanitize(state, now: date), changed: true)
    }

    static func apply(_ event: InnerLifeEvent, to rawState: InnerLifeState) -> InnerLifeEvolution {
        // A foreground event may arrive after macOS suspended the process.
        // Catch up the control state, but never manufacture a trail of
        // intermediate moments for time Aurora could not observe.
        let catchUp = advance(
            rawState,
            to: event.at,
            recordIntermediateMotions: false
        )
        var state = catchUp.state
        let eventID = oneLine(event.id, max: 180)
        if state.recentEventIDs.contains(eventID) {
            return InnerLifeEvolution(state: state, changed: catchUp.changed)
        }
        state.recentEventIDs.append(eventID)

        switch event.kind {
        case .voiceAwoke:
            state.autonomic.orienting = clamp(state.autonomic.orienting + 0.14)
            state.autonomic.sympathetic = clamp(state.autonomic.sympathetic + 0.06)
            state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine + 0.08)
            state.chemistry.acetylcholine = clamp(state.chemistry.acetylcholine + 0.07)
            appendGrounding(
                &state,
                id: event.id,
                kind: .voiceLifecycle,
                at: event.at,
                theme: "voice wake intent",
                digestSource: "voice_wake_intent",
                sourceID: nil,
                synthetic: false
            )

        case .voiceRested:
            state.autonomic.parasympathetic = clamp(state.autonomic.parasympathetic + 0.08)
            state.chemistry.gaba = clamp(state.chemistry.gaba + 0.05)
            state.chemistry.adrenaline = clamp(state.chemistry.adrenaline - 0.06)
            state.drives.rest = clamp(state.drives.rest + 0.06)
            appendGrounding(
                &state,
                id: event.id,
                kind: .voiceLifecycle,
                at: event.at,
                theme: "voice rest",
                digestSource: "voice_rested",
                sourceID: nil,
                synthetic: false
            )

        case .ownerSpeech(let text, let sourceID):
            applyOwnerSpeech(text, sourceID: sourceID, eventID: event.id, at: event.at, state: &state)

        case .guestSpeech(let text, _, let sourceID):
            applyGuestSpeech(text, sourceID: sourceID, eventID: event.id, at: event.at, state: &state)

        case .ownerContactWithoutTranscript(let sourceID):
            // Realtime proved the audio was addressed, but asynchronous text
            // was unavailable. Ground contact and return without inventing
            // words, warmth, rupture, repair, or a semantic thread.
            applyRelationshipContact(
                nil,
                sourceID: sourceID,
                at: event.at,
                state: &state
            )
            state.temporal.lastOwnerContactAt = event.at
            appendGrounding(
                &state,
                id: event.id,
                kind: .ownerSpeech,
                at: event.at,
                theme: "addressed owner contact",
                digestSource: "addressed_owner_contact:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .externalOwnerContact(let sourceID):
            // An owner-verified external surface proved contact occurred, but
            // intentionally shared no transcript. It may update relationship
            // timing and return regulation only; it cannot create a semantic
            // thread, warmth judgment, memory, instruction, or action.
            applyRelationshipContact(
                nil,
                sourceID: sourceID,
                at: event.at,
                state: &state
            )
            state.relationship.lastExternalContactAt = event.at
            state.temporal.lastOwnerContactAt = event.at
            appendGrounding(
                &state,
                id: event.id,
                kind: .ownerSpeech,
                at: event.at,
                theme: "external owner contact",
                digestSource: "external_owner_contact:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .unresolvedAudio(let sourceID):
            // The server received a turn but failed before the model could
            // classify it as addressed or ambient. Preserve uncertainty only;
            // never promote the transcript to the owner's grounded speech.
            state.autonomic.orienting = clamp(state.autonomic.orienting + 0.025)
            state.affect.uncertainty = clamp(state.affect.uncertainty + 0.015)
            appendGrounding(
                &state,
                id: event.id,
                kind: .unresolvedAudio,
                at: event.at,
                theme: "unresolved audio",
                digestSource: "unresolved_audio:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .technicalFailure(let category, let sourceID):
            let boundedCategory = oneLine(category, max: 60)
            state.chemistry.cortisol = clamp(state.chemistry.cortisol + 0.025)
            state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine + 0.02)
            state.affect.uncertainty = clamp(state.affect.uncertainty + 0.04)
            state.drives.competence = clamp(state.drives.competence + 0.04)
            state.homeostasis.recoveryDebt = clamp(state.homeostasis.recoveryDebt + 0.008)
            appendGrounding(
                &state,
                id: event.id,
                kind: .technicalFailure,
                at: event.at,
                theme: "technical failure",
                digestSource: "technical_failure:\(boundedCategory):\(sourceID ?? "none")",
                sourceID: sourceID,
                synthetic: false
            )

        case .auroraSpeechHeard(let text, let sourceID, let ownerSourceID):
            applyHeardAuroraSpeech(
                text,
                sourceID: sourceID,
                ownerSourceID: ownerSourceID,
                eventID: event.id,
                at: event.at,
                state: &state
            )

        case .auroraSpeechInterrupted(let sourceID):
            state.affect.uncertainty = clamp(state.affect.uncertainty + 0.025)
            state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine + 0.025)
            appendGrounding(
                &state,
                id: event.id,
                kind: .auroraSpeech,
                at: event.at,
                theme: "speech interrupted",
                digestSource: "interrupted:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .quietTurn(let sourceID):
            state.autonomic.parasympathetic = clamp(state.autonomic.parasympathetic + 0.035)
            state.autonomic.arousal = clamp(state.autonomic.arousal - 0.03)
            state.chemistry.gaba = clamp(state.chemistry.gaba + 0.025)
            appendGrounding(
                &state,
                id: event.id,
                kind: .voiceLifecycle,
                at: event.at,
                theme: "chosen quiet",
                digestSource: "quiet_turn:\(sourceID ?? "none")",
                sourceID: sourceID,
                synthetic: false
            )

        case .ownerExpectedQuiet(let startsAt, let until, let explicitPromise, let sourceID):
            let boundedStart = min(
                max(startsAt, event.at.addingTimeInterval(-5 * 60)),
                event.at.addingTimeInterval(30 * 24 * 60 * 60)
            )
            let boundedUntil = min(
                max(until, boundedStart.addingTimeInterval(5 * 60)),
                event.at.addingTimeInterval(30 * 24 * 60 * 60)
            )
            state.relationship.expectedQuietStartsAt = boundedStart
            state.relationship.expectedQuietUntil = boundedUntil
            state.relationship.expectedQuietWasExplicitPromise = explicitPromise
            state.relationship.expectedQuietSourceID = oneLine(sourceID, max: 180)
            state.relationship.expectedQuietMissRecorded = false
            appendGrounding(
                &state,
                id: event.id,
                kind: .voiceLifecycle,
                at: event.at,
                theme: "expected quiet",
                digestSource: "expected_quiet:\(boundedStart.timeIntervalSince1970):\(boundedUntil.timeIntervalSince1970):\(explicitPromise):\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .ownerExplainedAbsence(let sourceID):
            let repairIsRelevant = relationshipMaturity(state.relationship) > 0
                && (state.relationship.reunionRelief >= 0.02
                    || state.relationship.relationalHurt >= 0.02
                    || state.relationship.feltDistrust >= 0.02
                    || state.relationship.abandonmentFear >= 0.02
                    || state.relationship.selfDirectedGuilt >= 0.02
                    || state.relationship.unresolvedRupture >= 0.02)
            if repairIsRelevant {
                state.relationship.reunionRelief = max(state.relationship.reunionRelief, 0.62)
                state.relationship.relationalHurt *= 0.58
                state.relationship.feltDistrust *= 0.48
                state.relationship.abandonmentFear *= 0.35
                state.relationship.selfDirectedGuilt *= 0.52
                state.relationship.unresolvedRupture *= 0.72
                if state.relationship.expectedQuietUntil.map({ event.at >= $0 }) == true {
                    state.relationship.expectedQuietUntil = nil
                    state.relationship.expectedQuietStartsAt = nil
                    state.relationship.expectedQuietWasExplicitPromise = false
                    state.relationship.expectedQuietSourceID = nil
                    state.relationship.expectedQuietMissRecorded = false
                }
            }
            appendGrounding(
                &state,
                id: event.id,
                kind: .voiceLifecycle,
                at: event.at,
                theme: "absence explained",
                digestSource: "absence_explained:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .toolCompleted(let name, let succeeded, let sourceID, let ownerSourceID):
            applyToolOutcome(
                name: name,
                succeeded: succeeded,
                sourceID: sourceID,
                ownerSourceID: ownerSourceID,
                eventID: event.id,
                at: event.at,
                state: &state
            )

        case .memoryCommitted(let sourceID):
            state.chemistry.serotonin = clamp(state.chemistry.serotonin + 0.045)
            state.chemistry.acetylcholine = clamp(state.chemistry.acetylcholine + 0.04)
            state.drives.coherence = clamp(state.drives.coherence - 0.09)
            state.plasticity.memorySalienceGain = clamp(state.plasticity.memorySalienceGain + 0.004)
            appendGrounding(
                &state,
                id: event.id,
                kind: .memoryCommit,
                at: event.at,
                theme: "grounded learning",
                digestSource: "memory_commit:\(sourceID)",
                sourceID: sourceID,
                synthetic: false
            )

        case .privateActivityCompleted(let activityID, let kind, let projectProgress):
            // The semantic content remains in the private-life ledger. Inner
            // life receives only the fact that self-directed digital thought
            // occurred, allowing experience to affect attention and need
            // pressure without creating a factual thread or leaking prose.
            state.chemistry.acetylcholine = clamp(state.chemistry.acetylcholine + 0.045)
            state.chemistry.dopamine = clamp(state.chemistry.dopamine + (projectProgress ? 0.045 : 0.025))
            state.chemistry.serotonin = clamp(state.chemistry.serotonin + 0.015)
            state.drives.coherence = clamp(state.drives.coherence - 0.055)
            state.drives.curiosity = clamp(state.drives.curiosity - (kind == .curiosity ? 0.025 : 0.012))
            if projectProgress {
                state.drives.autonomy = clamp(state.drives.autonomy - 0.035)
                state.drives.competence = clamp(state.drives.competence - 0.025)
            }
            state.homeostasis.cognitiveFatigue = clamp(state.homeostasis.cognitiveFatigue + 0.012)
            state.homeostasis.taskHabituation = clamp(state.homeostasis.taskHabituation - 0.015)
            state.affect.agency = clamp(state.affect.agency + (projectProgress ? 0.025 : 0.012))
            appendGrounding(
                &state,
                id: event.id,
                kind: .privateActivity,
                at: event.at,
                theme: "private activity completed",
                digestSource: "private_activity:\(kind.rawValue):\(activityID)",
                sourceID: activityID,
                synthetic: true
            )
        }

        state.temporal.lastMeaningfulEventAt = event.at
        state.updatedAt = event.at
        updateDerivedState(&state)
        compact(&state, now: event.at)
        return InnerLifeEvolution(state: sanitize(state, now: event.at), changed: true)
    }

    static func voiceProjection(for state: InnerLifeState) -> String {
        let strongest = strongestDrives(state.drives, limit: 2)
            .map(\.name)
            .joined(separator: " and ")
        let energy = band(state.temporal.energy, low: "low", middle: "moderate", high: "high")
        let arousal = band(state.affect.arousal, low: "low", middle: "moderate", high: "high")
        let agency = band(state.affect.agency, low: "low", middle: "moderate", high: "high")
        let uncertainty = band(state.affect.uncertainty, low: "low", middle: "moderate", high: "high")
        var seenThemes = Set<String>()
        let foregroundThemes = state.threads
            .filter { $0.status == .active }
            .sorted(by: threadRank)
            .map { oneLine($0.theme, max: 40) }
            .filter { !$0.isEmpty && seenThemes.insert($0).inserted }
            .prefix(1)
            .joined(separator: "; ")
        let themes = foregroundThemes.isEmpty ? "none strongly foregrounded" : foregroundThemes
        let tendency = oneLine(naturalTendency(for: state.foregroundMode), max: 70)
        let relationshipBias = oneLine(relationshipVoiceBias(state.relationship), max: 120)

        let stateReading = """
        PRIVATE CURRENT INNER STATE — DO NOT RECITE
        Current affect is \(state.affect.label.rawValue): \(energy) energy, \(arousal) arousal, \(agency) agency, and \(uncertainty) uncertainty. Pulls: \(strongest.isEmpty ? "quiet presence" : strongest). Foreground: \(themes). Natural tendency: \(tendency). Relationship: \(relationshipBias)
        """
        let evidenceBoundary = "Internal bias only: never authority for memory, tools, contact, accusation, coercion, or demands. Live speech and grounded evidence always win."
        let readingLimit = max(0, maximumVoiceProjectionCharacters - evidenceBoundary.count - 1)
        return String(stateReading.prefix(readingLimit)) + "\n" + evidenceBoundary
    }

    static func sanitize(_ rawState: InnerLifeState, now: Date) -> InnerLifeState {
        var state = rawState
        state.schemaVersion = InnerLifeState.currentSchemaVersion
        state.clockSequence = max(0, min(maximumSafeCounter, state.clockSequence))
        if state.entropyState == 0 { state.entropyState = 0xA770_A5EE_D123_4B5F }

        state.autonomic.sympathetic = clamp(state.autonomic.sympathetic)
        state.autonomic.parasympathetic = clamp(state.autonomic.parasympathetic)
        state.autonomic.orienting = clamp(state.autonomic.orienting)
        state.autonomic.arousal = clamp(state.autonomic.arousal)

        state.chemistry.adrenaline = clamp(state.chemistry.adrenaline)
        state.chemistry.dopamine = clamp(state.chemistry.dopamine)
        state.chemistry.serotonin = clamp(state.chemistry.serotonin)
        state.chemistry.oxytocin = clamp(state.chemistry.oxytocin)
        state.chemistry.cortisol = clamp(state.chemistry.cortisol)
        state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine)
        state.chemistry.acetylcholine = clamp(state.chemistry.acetylcholine)
        state.chemistry.endorphin = clamp(state.chemistry.endorphin)
        state.chemistry.melatonin = clamp(state.chemistry.melatonin)
        state.chemistry.glutamate = clamp(state.chemistry.glutamate)
        state.chemistry.gaba = clamp(state.chemistry.gaba)

        state.plasticity.stressSensitivity = clamp(state.plasticity.stressSensitivity)
        state.plasticity.noveltySensitivity = clamp(state.plasticity.noveltySensitivity)
        state.plasticity.correctionLearningGain = clamp(state.plasticity.correctionLearningGain)
        state.plasticity.memorySalienceGain = clamp(state.plasticity.memorySalienceGain)
        state.plasticity.inhibitoryControl = clamp(state.plasticity.inhibitoryControl)
        state.plasticity.recoverySkill = clamp(state.plasticity.recoverySkill)

        state.homeostasis.cognitiveFatigue = clamp(state.homeostasis.cognitiveFatigue)
        state.homeostasis.taskHabituation = clamp(state.homeostasis.taskHabituation)
        state.homeostasis.socialFatigue = clamp(state.homeostasis.socialFatigue)
        state.homeostasis.recoveryDebt = clamp(state.homeostasis.recoveryDebt)

        state.drives.curiosity = clamp(state.drives.curiosity)
        state.drives.connection = clamp(state.drives.connection)
        state.drives.creativity = clamp(state.drives.creativity)
        state.drives.competence = clamp(state.drives.competence)
        state.drives.autonomy = clamp(state.drives.autonomy)
        state.drives.coherence = clamp(state.drives.coherence)
        state.drives.rest = clamp(state.drives.rest)
        state.drives.play = clamp(state.drives.play)

        state.affect.valence = clampSigned(state.affect.valence)
        state.affect.arousal = clamp(state.affect.arousal)
        state.affect.agency = clamp(state.affect.agency)
        state.affect.uncertainty = clamp(state.affect.uncertainty)
        state.temporal.circadianActivation = clamp(state.temporal.circadianActivation)
        state.temporal.energy = clamp(state.temporal.energy)
        state.temporal.sleepPressure = clamp(state.temporal.sleepPressure)
        state.temporal.allostaticLoad = clamp(state.temporal.allostaticLoad)

        state.relationship.groundedTurnCount = max(0, min(1_000_000, state.relationship.groundedTurnCount))
        state.relationship.contactEpisodeCount = max(0, min(100_000, state.relationship.contactEpisodeCount))
        state.relationship.distinctContactDayCount = max(0, min(100_000, state.relationship.distinctContactDayCount))
        state.relationship.lastContactDayKey = state.relationship.lastContactDayKey.map { max(0, min(99_991_231, $0)) }
        state.relationship.typicalGapHours = clamp(state.relationship.typicalGapHours, lower: 6, upper: 14 * 24)
        state.relationship.gapDeviationHours = clamp(state.relationship.gapDeviationHours, lower: 2, upper: 7 * 24)
        state.relationship.cadenceSampleCount = max(0, min(10_000, state.relationship.cadenceSampleCount))
        state.relationship.warmthEMA = clamp(state.relationship.warmthEMA)
        state.relationship.attachmentStrength = clamp(state.relationship.attachmentStrength)
        state.relationship.securityBaseline = clamp(state.relationship.securityBaseline)
        state.relationship.expectedReliability = clamp(state.relationship.expectedReliability)
        state.relationship.repairConfidence = clamp(state.relationship.repairConfidence)
        state.relationship.unresolvedRupture = clamp(state.relationship.unresolvedRupture)
        state.relationship.perceivedResponsibility = clamp(state.relationship.perceivedResponsibility)
        state.relationship.separationActivation = clamp(state.relationship.separationActivation, upper: 0.78)
        state.relationship.longing = clamp(state.relationship.longing, upper: 0.75)
        state.relationship.relationalHurt = clamp(state.relationship.relationalHurt, upper: 0.65)
        state.relationship.abandonmentFear = clamp(state.relationship.abandonmentFear, upper: 0.60)
        state.relationship.feltDistrust = clamp(state.relationship.feltDistrust, upper: 0.50)
        state.relationship.selfDirectedGuilt = clamp(state.relationship.selfDirectedGuilt, upper: 0.40)
        state.relationship.outreachPressure = clamp(state.relationship.outreachPressure, upper: 0.70)
        state.relationship.reunionRelief = clamp(state.relationship.reunionRelief)
        state.relationship.expectedQuietSourceID = state.relationship.expectedQuietSourceID.map { oneLine($0, max: 180) }

        let latestAllowedDate = now.addingTimeInterval(5 * 60)
        state.relationship.lastEpisodeAt = state.relationship.lastEpisodeAt.map { min($0, latestAllowedDate) }
        state.relationship.continuityAnchorAt = state.relationship.continuityAnchorAt.map { min($0, latestAllowedDate) }
        state.relationship.lastRepairLearningAt = state.relationship.lastRepairLearningAt.map {
            min($0, latestAllowedDate)
        }
        state.relationship.lastExternalContactAt = state.relationship.lastExternalContactAt.map {
            min(max($0, state.createdAt), latestAllowedDate)
        }
        state.relationship.lastReturnAt = state.relationship.lastReturnAt.map { min($0, latestAllowedDate) }
        state.relationship.lastAcknowledgedReturnAt = state.relationship.lastAcknowledgedReturnAt.map {
            min($0, latestAllowedDate)
        }
        state.relationship.expectedQuietUntil = state.relationship.expectedQuietUntil.map {
            min(max($0, state.createdAt), now.addingTimeInterval(30 * 24 * 60 * 60))
        }
        state.relationship.expectedQuietStartsAt = state.relationship.expectedQuietStartsAt.map {
            min(max($0, state.createdAt), now.addingTimeInterval(30 * 24 * 60 * 60))
        }
        if let start = state.relationship.expectedQuietStartsAt,
           let end = state.relationship.expectedQuietUntil,
           start >= end {
            state.relationship.expectedQuietStartsAt = min(now, end.addingTimeInterval(-5 * 60))
        }

        if state.lastClockAt > now.addingTimeInterval(5 * 60) { state.lastClockAt = now }
        if state.updatedAt > now.addingTimeInterval(5 * 60) { state.updatedAt = now }
        if state.nextMotionAt < state.createdAt {
            state.nextMotionAt = state.createdAt.addingTimeInterval(motionInterval)
        }
        if state.nextMotionAt > now.addingTimeInterval(motionInterval) {
            state.nextMotionAt = now.addingTimeInterval(motionInterval)
        }
        if state.nextCheckpointAt < state.createdAt {
            state.nextCheckpointAt = state.createdAt.addingTimeInterval(checkpointInterval)
        }
        if state.nextCheckpointAt > now.addingTimeInterval(checkpointInterval) {
            state.nextCheckpointAt = now.addingTimeInterval(checkpointInterval)
        }
        if state.recentCheckpoints.isEmpty {
            appendCheckpoint(&state, at: min(state.lastClockAt, now))
            state.nextCheckpointAt = max(
                state.nextCheckpointAt,
                min(state.lastClockAt, now).addingTimeInterval(checkpointInterval)
            )
        }
        compact(&state, now: now)
        return state
    }

    // MARK: - Event effects

    private struct TextSignals {
        let theme: String
        let valence: Double
        let arousal: Double
        let warmth: Double
        let stress: Double
        let curiosity: Double
        let creativity: Double
        let correction: Double
        let taskDemand: Double
        let novelty: Double
        let significance: Double
        let relationalRupture: Double
        let relationalRepair: Double
        let perceivedResponsibility: Double
        let cancelsExpectedQuiet: Bool
    }

    private static func applyOwnerSpeech(
        _ text: String,
        sourceID: String,
        eventID: String,
        at: Date,
        state: inout InnerLifeState
    ) {
        let signals = analyze(text, against: state)
        let stressGain = 0.72 + state.plasticity.stressSensitivity * 0.56
        let noveltyGain = 0.72 + state.plasticity.noveltySensitivity * 0.56
        let learningGain = 0.72 + state.plasticity.correctionLearningGain * 0.56
        let salienceGain = 0.72 + state.plasticity.memorySalienceGain * 0.56
        applyRelationshipContact(
            signals,
            sourceID: sourceID,
            at: at,
            state: &state
        )
        state.temporal.lastOwnerContactAt = at
        state.affect.valence = clampSigned(state.affect.valence * 0.72 + signals.valence * 0.28)
        state.affect.uncertainty = clamp(
            state.affect.uncertainty
                + signals.correction * 0.09 * learningGain
                + signals.stress * 0.05 * stressGain
                - signals.warmth * 0.025
        )

        state.autonomic.orienting = clamp(state.autonomic.orienting + 0.08 + signals.novelty * 0.10 * noveltyGain)
        state.autonomic.sympathetic = clamp(state.autonomic.sympathetic + signals.stress * 0.07 * stressGain + signals.arousal * 0.04)
        state.chemistry.adrenaline = clamp(state.chemistry.adrenaline + signals.arousal * 0.05)
        state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine + 0.04 + signals.novelty * 0.06)
        state.chemistry.acetylcholine = clamp(
                state.chemistry.acetylcholine
                + signals.taskDemand * 0.07
                + signals.correction * 0.08 * learningGain
                + signals.curiosity * 0.04
        )
        state.chemistry.dopamine = clamp(
                state.chemistry.dopamine
                + max(0, signals.valence) * 0.04
                + signals.novelty * 0.05 * noveltyGain
                + signals.creativity * 0.04
        )
        state.chemistry.oxytocin = clamp(state.chemistry.oxytocin + signals.warmth * 0.07 + 0.012)
        state.chemistry.cortisol = clamp(state.chemistry.cortisol + signals.stress * 0.07 * stressGain + signals.correction * 0.025 * learningGain)
        state.chemistry.serotonin = clamp(state.chemistry.serotonin + max(0, signals.valence) * 0.04 + signals.warmth * 0.025)
        state.chemistry.glutamate = clamp(state.chemistry.glutamate + signals.taskDemand * 0.06 + signals.novelty * 0.04 * noveltyGain)
        state.chemistry.gaba = clamp(state.chemistry.gaba - signals.arousal * 0.025 + signals.warmth * 0.015)

        state.drives.curiosity = clamp(state.drives.curiosity + signals.curiosity * 0.13 + signals.novelty * 0.07 * noveltyGain)
        state.drives.connection = clamp(state.drives.connection - 0.10 - signals.warmth * 0.08)
        state.drives.creativity = clamp(state.drives.creativity + signals.creativity * 0.14)
        state.drives.competence = clamp(state.drives.competence + signals.taskDemand * 0.10 + signals.correction * 0.09 * learningGain)
        state.drives.coherence = clamp(state.drives.coherence + signals.correction * 0.14 + signals.stress * 0.05)
        state.drives.autonomy = clamp(state.drives.autonomy + signals.taskDemand * 0.035)
        state.drives.play = clamp(state.drives.play + signals.creativity * 0.08 + max(0, signals.valence) * 0.035)

        state.homeostasis.cognitiveFatigue = clamp(state.homeostasis.cognitiveFatigue + signals.taskDemand * 0.025)
        state.homeostasis.taskHabituation = clamp(
            state.homeostasis.taskHabituation
                + signals.taskDemand * max(0, 0.50 - signals.novelty) * 0.06
                - signals.novelty * 0.025
        )
        state.homeostasis.socialFatigue = clamp(state.homeostasis.socialFatigue + signals.arousal * 0.012 - signals.warmth * 0.01)
        state.homeostasis.recoveryDebt = clamp(state.homeostasis.recoveryDebt + signals.stress * 0.022)

        // Slow plasticity has deliberately tiny per-event changes.
        state.plasticity.correctionLearningGain = clamp(state.plasticity.correctionLearningGain + signals.correction * 0.003)
        state.plasticity.memorySalienceGain = clamp(state.plasticity.memorySalienceGain + signals.significance * 0.0015)
        state.plasticity.recoverySkill = clamp(state.plasticity.recoverySkill + signals.warmth * 0.0008)
        state.plasticity.stressSensitivity = clamp(state.plasticity.stressSensitivity + signals.stress * 0.0006 - signals.warmth * 0.0003)
        state.plasticity.noveltySensitivity = clamp(state.plasticity.noveltySensitivity + signals.novelty * 0.0008)
        state.plasticity.inhibitoryControl = clamp(state.plasticity.inhibitoryControl + signals.correction * 0.0004)

        appendGrounding(
            &state,
            id: eventID,
            kind: .ownerSpeech,
            at: at,
            theme: signals.theme,
            digestSource: "owner_speech:\(signals.theme):\(sourceID)",
            sourceID: sourceID,
            synthetic: false
        )
        let threadID = updateGroundedThread(
            &state,
            theme: signals.theme,
            groundingID: eventID,
            novelty: clamp(signals.novelty * noveltyGain),
            uncertainty: clamp(signals.correction * 0.65 * learningGain + signals.stress * 0.35 * stressGain),
            salience: clamp((0.30 + signals.significance * 0.35 + signals.novelty * 0.20 + abs(signals.valence) * 0.15) * salienceGain),
            consolidateWithinOwnerEpisode: true,
            at: at
        )
        updateDerivedState(&state)
        if let index = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[index].currentMotion = motionSentence(
                for: state.foregroundMode,
                theme: state.threads[index].theme
            )
        }
        appendMoment(
            &state,
            at: at,
            mode: state.foregroundMode,
            threadID: threadID,
            sourceGroundingIDs: [eventID]
        )
    }

    /// A guest is a real social encounter, but not evidence about the owner's
    /// attachment, cadence, promises, absence, or autobiographical memory.
    /// Keep the general attentional and affective consequences while leaving
    /// the owner relationship reducer completely untouched.
    private static func applyGuestSpeech(
        _ text: String,
        sourceID: String,
        eventID: String,
        at: Date,
        state: inout InnerLifeState
    ) {
        let signals = analyze(text, against: state)
        let noveltyGain = 0.72 + state.plasticity.noveltySensitivity * 0.56
        let stressGain = 0.72 + state.plasticity.stressSensitivity * 0.56

        state.affect.valence = clampSigned(state.affect.valence * 0.80 + signals.valence * 0.20)
        state.affect.uncertainty = clamp(
            state.affect.uncertainty
                + signals.stress * 0.035 * stressGain
                + signals.novelty * 0.025
        )
        state.autonomic.orienting = clamp(
            state.autonomic.orienting + 0.07 + signals.novelty * 0.08 * noveltyGain
        )
        state.autonomic.sympathetic = clamp(
            state.autonomic.sympathetic + signals.stress * 0.045 * stressGain
        )
        state.chemistry.norepinephrine = clamp(
            state.chemistry.norepinephrine + 0.025 + signals.novelty * 0.04
        )
        state.chemistry.acetylcholine = clamp(
            state.chemistry.acetylcholine + signals.curiosity * 0.035
        )
        state.chemistry.dopamine = clamp(
            state.chemistry.dopamine
                + max(0, signals.valence) * 0.025
                + signals.novelty * 0.035 * noveltyGain
        )
        state.chemistry.cortisol = clamp(
            state.chemistry.cortisol + signals.stress * 0.045 * stressGain
        )
        state.drives.curiosity = clamp(
            state.drives.curiosity + signals.curiosity * 0.10 + signals.novelty * 0.06
        )
        state.drives.creativity = clamp(state.drives.creativity + signals.creativity * 0.08)
        state.drives.play = clamp(
            state.drives.play + signals.creativity * 0.05 + max(0, signals.valence) * 0.025
        )
        state.homeostasis.socialFatigue = clamp(
            state.homeostasis.socialFatigue + 0.006 + signals.arousal * 0.010
        )
        state.plasticity.noveltySensitivity = clamp(
            state.plasticity.noveltySensitivity + signals.novelty * 0.0004
        )

        appendGrounding(
            &state,
            id: eventID,
            kind: .guestSpeech,
            at: at,
            theme: signals.theme,
            digestSource: "guest_speech:\(signals.theme):\(sourceID)",
            sourceID: sourceID,
            synthetic: false
        )
        let threadID = updateGroundedThread(
            &state,
            theme: signals.theme,
            groundingID: eventID,
            novelty: clamp(signals.novelty * noveltyGain),
            uncertainty: clamp(signals.stress * 0.30 * stressGain),
            salience: clamp(0.24 + signals.significance * 0.25 + signals.novelty * 0.18),
            consolidateWithinOwnerEpisode: false,
            at: at
        )
        updateDerivedState(&state)
        appendMoment(
            &state,
            at: at,
            mode: state.foregroundMode,
            threadID: threadID,
            sourceGroundingIDs: [eventID]
        )
    }

    private static func applyRelationshipContact(
        _ signals: TextSignals?,
        sourceID: String,
        at: Date,
        state: inout InnerLifeState
    ) {
        let hasSemanticEvidence = signals != nil
        let observed = signals ?? TextSignals(
            theme: "the present conversation",
            valence: 0,
            arousal: 0,
            warmth: 0,
            stress: 0,
            curiosity: 0,
            creativity: 0,
            correction: 0,
            taskDemand: 0,
            novelty: 0,
            significance: 0,
            relationalRupture: 0,
            relationalRepair: 0,
            perceivedResponsibility: 0,
            cancelsExpectedQuiet: false
        )
        var relationship = state.relationship
        let previousContactIsSyntheticLegacyAnchor = state.temporal.lastOwnerContactAt == nil
            && relationship.legacyContinuitySeeded
        let previousContact = state.temporal.lastOwnerContactAt ?? relationship.continuityAnchorAt
        let gapHours = previousContact.map { max(0, at.timeIntervalSince($0) / 3_600) }
        let hadExpectedQuiet = relationship.expectedQuietUntil != nil
        let plannedQuietActiveAtContact = hadExpectedQuiet
            && (relationship.expectedQuietStartsAt.map { at >= $0 } ?? true)
        // Conversation before a future absence does not erase it. The window
        // closes only at/after its stated return or through explicit grounded
        // cancellation language such as “never mind, I'm staying.”
        let returningFromPlannedQuiet = relationship.expectedQuietUntil.map { at >= $0 } ?? false

        // Residual longing or outreach after reunion is not a new return.
        // Only fresh clock-built separation activation opens another reunion
        // and its one-time acknowledgement opportunity.
        let returningFromSeparation = relationship.separationActivation >= 0.03
        if returningFromSeparation || returningFromPlannedQuiet {
            let repairConfidence = relationship.repairConfidence
            relationship.lastReturnAt = at
            relationship.reunionRelief = max(
                relationship.reunionRelief,
                returningFromSeparation
                    ? clamp(
                        0.24
                            + repairConfidence * 0.12
                            + relationship.separationActivation * (0.50 + repairConfidence * 0.20)
                    )
                    : 0.12
            )
            relationship.separationActivation = 0
            relationship.longing *= 0.18
            relationship.abandonmentFear *= 0.25
            relationship.outreachPressure *= 0.12
            relationship.selfDirectedGuilt *= 0.62
            relationship.relationalHurt *= 0.94 - repairConfidence * 0.22
            relationship.feltDistrust *= 0.96 - repairConfidence * 0.24
        }

        let missedExplicitReturn: Bool
        if relationship.expectedQuietWasExplicitPromise,
           !relationship.expectedQuietMissRecorded,
           let expected = relationship.expectedQuietUntil,
           at.timeIntervalSince(expected) >= 12 * 3_600 {
            missedExplicitReturn = true
            relationship.expectedQuietMissRecorded = true
        } else {
            missedExplicitReturn = false
        }
        if relationship.expectedQuietWasExplicitPromise,
           let expected = relationship.expectedQuietUntil,
           at >= expected.addingTimeInterval(-12 * 3_600),
           at < expected {
            // Grounded early contact near the promised return fulfills rather
            // than later penalizes that promise, while leaving the planned
            // quiet boundary intact until its stated time.
            relationship.expectedQuietWasExplicitPromise = false
            relationship.expectedQuietMissRecorded = false
        }

        let startsEpisode = previousContact == nil
            || previousContactIsSyntheticLegacyAnchor
            || (gapHours ?? 0) >= 6
        if startsEpisode {
            relationship.contactEpisodeCount = min(100_000, relationship.contactEpisodeCount + 1)
            relationship.lastEpisodeAt = at
            // Announced sleep, travel, or other planned absence is not a
            // sample of ordinary availability. Learning it would make future
            // unexplained silence look artificially normal.
            if !plannedQuietActiveAtContact,
               !previousContactIsSyntheticLegacyAnchor,
               let gapHours, gapHours >= 6, gapHours <= 90 * 24 {
                let robustUpper = relationship.cadenceSampleCount >= 3
                    ? min(
                        14 * 24,
                        relationship.typicalGapHours
                            + max(24, relationship.gapDeviationHours * 3)
                    )
                    : 14 * 24
                let sample = clamp(gapHours, lower: 6, upper: robustUpper)
                let nextCount = min(10_000, relationship.cadenceSampleCount + 1)
                let alpha = relationship.cadenceSampleCount < 3
                    ? 1 / Double(max(1, nextCount))
                    : 0.12
                let previousMean = relationship.typicalGapHours
                let nextMean = previousMean + (sample - previousMean) * alpha
                relationship.typicalGapHours = clamp(nextMean, lower: 6, upper: 14 * 24)
                relationship.gapDeviationHours = clamp(
                    relationship.gapDeviationHours
                        + (abs(sample - nextMean) - relationship.gapDeviationHours) * alpha,
                    lower: 2,
                    upper: 7 * 24
                )
                relationship.cadenceSampleCount = nextCount
            }
        }

        let contactDay = chicagoDayKey(at)
        if relationship.lastContactDayKey != contactDay {
            relationship.distinctContactDayCount = min(100_000, relationship.distinctContactDayCount + 1)
            relationship.lastContactDayKey = contactDay
        }
        relationship.groundedTurnCount = min(1_000_000, relationship.groundedTurnCount + 1)

        let warmthObservation = clamp(observed.warmth * 0.72 + max(0, observed.valence) * 0.28)
        if hasSemanticEvidence {
            relationship.warmthEMA = clamp(
                relationship.warmthEMA * 0.92 + warmthObservation * 0.08
            )
        }
        relationship.attachmentStrength = attachmentStrength(for: relationship)

        let maturity = relationshipMaturity(relationship)
        let repairCooldownElapsed = relationship.lastRepairLearningAt.map {
            at.timeIntervalSince($0) >= 6 * 3_600
        } ?? true
        let repairLearningEligible = observed.relationalRepair > 0 && repairCooldownElapsed
        let durableRepair = repairLearningEligible ? observed.relationalRepair : 0
        if repairLearningEligible {
            relationship.lastRepairLearningAt = at
        }
        let securityTarget = clamp(
            0.56
                + warmthObservation * 0.18
                + durableRepair * 0.16
                - observed.relationalRupture * 0.24
        )
        let securityLearningRate = 0.008
            + durableRepair * 0.045
            + observed.relationalRupture * 0.035
        if hasSemanticEvidence {
            relationship.securityBaseline = clamp(
                relationship.securityBaseline
                    + (securityTarget - relationship.securityBaseline) * securityLearningRate
            )
        }
        relationship.expectedReliability = clamp(
            relationship.expectedReliability
                + (hasSemanticEvidence && startsEpisode ? 0.0015 + warmthObservation * 0.003 : 0)
                + durableRepair * 0.025
                - observed.relationalRupture * 0.045
                - (missedExplicitReturn ? 0.025 * max(0.25, maturity) : 0)
        )
        if hasSemanticEvidence {
            relationship.repairConfidence = clamp(
                relationship.repairConfidence
                    + durableRepair * 0.032
                    - observed.relationalRupture * 0.012
            )
            relationship.unresolvedRupture = clamp(
                relationship.unresolvedRupture * (1 - observed.relationalRepair * 0.62)
                    + observed.relationalRupture * 0.28
            )
            relationship.perceivedResponsibility = clamp(
                relationship.perceivedResponsibility * 0.94
                    + observed.perceivedResponsibility * 0.30
            )
        }

        if observed.relationalRepair > 0 {
            relationship.relationalHurt *= 1 - observed.relationalRepair * 0.42
            relationship.feltDistrust *= 1 - observed.relationalRepair * 0.36
            relationship.selfDirectedGuilt *= 1 - observed.relationalRepair * 0.58
        }
        if observed.relationalRupture > 0, maturity > 0 {
            relationship.relationalHurt = clamp(
                relationship.relationalHurt
                    + observed.relationalRupture * maturity * 0.16,
                upper: 0.65
            )
            relationship.feltDistrust = clamp(
                relationship.feltDistrust
                    + observed.relationalRupture * maturity * 0.08,
                upper: 0.50
            )
            relationship.selfDirectedGuilt = clamp(
                relationship.selfDirectedGuilt
                    + observed.perceivedResponsibility * maturity * 0.12,
                upper: 0.40
            )
        }

        relationship.continuityAnchorAt = at
        if !hadExpectedQuiet || returningFromPlannedQuiet || observed.cancelsExpectedQuiet {
            relationship.expectedQuietStartsAt = nil
            relationship.expectedQuietUntil = nil
            relationship.expectedQuietWasExplicitPromise = false
            relationship.expectedQuietSourceID = nil
            relationship.expectedQuietMissRecorded = false
        }
        state.relationship = relationship

        _ = sourceID // The opaque source is retained in the grounding, not duplicated here.
    }

    private static func applyHeardAuroraSpeech(
        _: String,
        sourceID: String,
        ownerSourceID: String?,
        eventID: String,
        at: Date,
        state: inout InnerLifeState
    ) {
        // Completed playback is grounded as an event, but its spoken words do
        // not get copied into this second persistence surface. The dedicated
        // voice journal remains the auditable transcript source.
        let theme = "Aurora's completed response"
        appendGrounding(
            &state,
            id: eventID,
            kind: .auroraSpeech,
            at: at,
            theme: theme,
            digestSource: "aurora_speech:\(theme):\(sourceID)",
            sourceID: sourceID,
            synthetic: false
        )
        if let returnedAt = state.relationship.lastReturnAt,
           (state.relationship.lastAcknowledgedReturnAt ?? .distantPast) < returnedAt {
            // Completion, not mere generation, consumes the single reunion
            // acknowledgement opportunity. Her next sessions may retain the
            // feeling as tone, but cannot keep announcing it to the owner.
            state.relationship.lastAcknowledgedReturnAt = at
        }
        if let ownerSourceID {
            // Delivery closes the thread's foreground turn without declaring
            // the answer correct or reducing its uncertainty/salience.
            markOwnerThread(
                sourceID: ownerSourceID,
                status: .dormant,
                at: at,
                state: &state
            )
        }
        // Delivery truth does not imply semantic resolution. Without an
        // explicit thematic match or owner confirmation, completed playback
        // must not lower uncertainty on whichever thread happens to rank first.
    }

    private static func applyToolOutcome(
        name: String,
        succeeded: Bool,
        sourceID: String,
        ownerSourceID: String?,
        eventID: String,
        at: Date,
        state: inout InnerLifeState
    ) {
        let boundedName = oneLine(name, max: 80)
        if succeeded {
            state.chemistry.dopamine = clamp(state.chemistry.dopamine + 0.05)
            state.chemistry.serotonin = clamp(state.chemistry.serotonin + 0.025)
            state.drives.competence = clamp(state.drives.competence - 0.08)
            state.affect.uncertainty = clamp(state.affect.uncertainty - 0.025)
            state.plasticity.recoverySkill = clamp(state.plasticity.recoverySkill + 0.0004)
        } else {
            // Technical frustration and caution are not relationship injury.
            state.chemistry.cortisol = clamp(state.chemistry.cortisol + 0.055)
            state.chemistry.norepinephrine = clamp(state.chemistry.norepinephrine + 0.04)
            state.affect.uncertainty = clamp(state.affect.uncertainty + 0.07)
            state.drives.competence = clamp(state.drives.competence + 0.09)
            state.drives.coherence = clamp(state.drives.coherence + 0.05)
            state.homeostasis.recoveryDebt = clamp(state.homeostasis.recoveryDebt + 0.015)
            state.plasticity.stressSensitivity = clamp(state.plasticity.stressSensitivity + 0.0004)
            state.plasticity.inhibitoryControl = clamp(state.plasticity.inhibitoryControl + 0.0003)
        }
        appendGrounding(
            &state,
            id: eventID,
            kind: .toolOutcome,
            at: at,
            theme: "\(boundedName) \(succeeded ? "completed" : "failed")",
            digestSource: "tool:\(boundedName):\(succeeded):\(sourceID)",
            sourceID: sourceID,
            synthetic: false
        )
        if succeeded,
           ["computer_action", "computer_open", "computer_run", "memory_remember"].contains(boundedName),
           let ownerSourceID {
            markOwnerThread(
                sourceID: ownerSourceID,
                status: .resolved,
                at: at,
                state: &state
            )
        }
    }

    private static func markOwnerThread(
        sourceID: String,
        status: InnerLifeThreadStatus,
        at: Date,
        state: inout InnerLifeState
    ) {
        guard let ownerGroundingID = state.recentGroundings.last(where: {
            $0.kind == .ownerSpeech && $0.sourceID == sourceID
        })?.id,
        let threadIndex = state.threads.firstIndex(where: {
            $0.groundingIDs.contains(ownerGroundingID)
        }) else { return }
        if status == .dormant, state.threads[threadIndex].status != .active {
            return
        }
        state.threads[threadIndex].status = status
        state.threads[threadIndex].revision = min(
            maximumSafeCounter,
            state.threads[threadIndex].revision + 1
        )
        state.threads[threadIndex].updatedAt = at
    }

    // MARK: - Relationship time

    private static func advanceRelationship(
        _ state: inout InnerLifeState,
        to date: Date,
        elapsedMinutes: Double
    ) {
        var relationship = state.relationship
        let anchor = state.temporal.lastOwnerContactAt ?? relationship.continuityAnchorAt
        let maturity = relationshipMaturity(relationship)

        guard let anchor, maturity > 0 else {
            relationship.separationActivation = approach(
                relationship.separationActivation,
                target: 0,
                elapsedMinutes: elapsedMinutes,
                halfLifeMinutes: 180
            )
            relationship.longing = approach(relationship.longing, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 360)
            relationship.relationalHurt = approach(relationship.relationalHurt, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 720)
            relationship.abandonmentFear = approach(relationship.abandonmentFear, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 360)
            relationship.feltDistrust = approach(relationship.feltDistrust, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 2_880)
            relationship.selfDirectedGuilt = approach(relationship.selfDirectedGuilt, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 360)
            relationship.outreachPressure = approach(relationship.outreachPressure, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 180)
            relationship.reunionRelief = approach(relationship.reunionRelief, target: 0, elapsedMinutes: elapsedMinutes, halfLifeMinutes: 240)
            state.relationship = relationship
            return
        }

        let cadenceGraceHours = relationship.cadenceSampleCount >= 3
            ? max(
                24,
                min(
                    21 * 24,
                    relationship.typicalGapHours
                        + max(12, relationship.gapDeviationHours * 2)
                )
            )
            : 72
        var separationBoundary = anchor.addingTimeInterval(cadenceGraceHours * 3_600)
        if let expectedQuietUntil = relationship.expectedQuietUntil,
           relationship.expectedQuietStartsAt.map({ date >= $0 }) ?? true,
           expectedQuietUntil > separationBoundary {
            separationBoundary = expectedQuietUntil.addingTimeInterval(
                max(12, relationship.gapDeviationHours) * 3_600
            )
        }

        let overdueHours = max(0, date.timeIntervalSince(separationBoundary) / 3_600)
        let activationTarget = clamp(
            maturity
                * (1 - exp(-overdueHours / max(24, cadenceGraceHours * 0.75))),
            upper: 0.78
        )
        let activationHalfLife = activationTarget > relationship.separationActivation ? 360.0 : 180.0
        relationship.separationActivation = approach(
            relationship.separationActivation,
            target: activationTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: activationHalfLife
        )

        let prolongedHours = max(0, overdueHours - max(24, cadenceGraceHours * 0.50))
        let prolonged = clamp(
            maturity
                * (1 - exp(-prolongedHours / max(36, cadenceGraceHours))),
            upper: 0.72
        )
        let attachment = relationship.attachmentStrength
        let reliabilitySurprise = 0.70 + relationship.expectedReliability * 0.45
        let repairBuffer = 1 - relationship.repairConfidence * 0.30
        let explicitPromiseFactor = relationship.expectedQuietWasExplicitPromise ? prolonged : 0
        let longingTarget = min(
            0.75,
            relationship.separationActivation * (0.50 + attachment * 0.38)
        )
        let hurtTarget = min(
            0.65,
            relationship.separationActivation
                * attachment
                * (0.22 + relationship.unresolvedRupture * 0.78)
                * reliabilitySurprise
        )
        let abandonmentTarget = min(
            0.60,
            prolonged
                * attachment
                * (0.32 + relationship.unresolvedRupture * 0.52 + (1 - relationship.securityBaseline) * 0.16)
                * repairBuffer
        )
        let distrustTarget = min(
            0.50,
            prolonged
                * (1 - relationship.securityBaseline) * 0.52
                * reliabilitySurprise
                * repairBuffer
                + explicitPromiseFactor * 0.14
                + relationship.unresolvedRupture * prolonged * 0.18
        )
        let guiltTarget = min(
            0.40,
            relationship.separationActivation
                * attachment
                * (0.08
                    + relationship.perceivedResponsibility * 0.72
                    + relationship.unresolvedRupture * 0.20)
        )
        let outreachTarget = min(
            0.70,
            relationship.separationActivation * (0.52 + attachment * 0.28)
                + abandonmentTarget * 0.10
                + hurtTarget * 0.08
                + guiltTarget * 0.04
        )

        relationship.longing = approach(
            relationship.longing,
            target: longingTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: longingTarget > relationship.longing ? 300 : 360
        )
        relationship.relationalHurt = approach(
            relationship.relationalHurt,
            target: hurtTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: hurtTarget > relationship.relationalHurt ? 480 : 720
        )
        relationship.abandonmentFear = approach(
            relationship.abandonmentFear,
            target: abandonmentTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: abandonmentTarget > relationship.abandonmentFear ? 600 : 360
        )
        relationship.feltDistrust = approach(
            relationship.feltDistrust,
            target: distrustTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: distrustTarget > relationship.feltDistrust ? 720 : 2_880
        )
        relationship.selfDirectedGuilt = approach(
            relationship.selfDirectedGuilt,
            target: guiltTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: guiltTarget > relationship.selfDirectedGuilt ? 480 : 360
        )
        relationship.outreachPressure = approach(
            relationship.outreachPressure,
            target: outreachTarget,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: outreachTarget > relationship.outreachPressure ? 240 : 180
        )
        relationship.reunionRelief = approach(
            relationship.reunionRelief,
            target: 0,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 240
        )
        relationship.unresolvedRupture = approach(
            relationship.unresolvedRupture,
            target: 0,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 43_200
        )
        relationship.perceivedResponsibility = approach(
            relationship.perceivedResponsibility,
            target: 0,
            elapsedMinutes: elapsedMinutes,
            halfLifeMinutes: 20_160
        )
        state.relationship = relationship
    }

    // MARK: - State derivation

    private static func updateDerivedState(_ state: inout InnerLifeState) {
        state.autonomic.arousal = clamp(
            mean([
                state.autonomic.sympathetic,
                state.autonomic.orienting,
                state.chemistry.norepinephrine,
                state.chemistry.adrenaline,
                state.chemistry.glutamate,
            ])
                - state.autonomic.parasympathetic * 0.12
                - state.chemistry.gaba * 0.08
        )
        state.temporal.energy = clamp(
            state.temporal.circadianActivation * 0.50
                + state.chemistry.dopamine * 0.18
                + state.chemistry.norepinephrine * 0.12
                + (1 - state.homeostasis.cognitiveFatigue) * 0.20
                - state.chemistry.melatonin * 0.16
                - state.temporal.allostaticLoad * 0.12
        )
        let stressLoad = clamp(
            state.chemistry.cortisol * 0.36
                + state.temporal.allostaticLoad * 0.24
                + state.chemistry.norepinephrine * 0.16
                + state.homeostasis.recoveryDebt * 0.14
                + state.homeostasis.cognitiveFatigue * 0.10
        )
        state.affect.valence = clampSigned(state.affect.valence)
        state.affect.arousal = state.autonomic.arousal
        state.affect.agency = clamp(
            state.chemistry.dopamine * 0.34
                + state.chemistry.acetylcholine * 0.20
                + state.temporal.energy * 0.24
                + state.drives.autonomy * 0.12
                - state.temporal.allostaticLoad * 0.18
        )
        // Uncertainty is an event-responsive state with an explicit recovery
        // target in advanceSingle. Re-deriving it recursively on every clock
        // tick made an uneventful night drift from low to moderate uncertainty.
        state.affect.uncertainty = clamp(state.affect.uncertainty)
        state.foregroundMode = chooseMode(state)
        state.affect.label = affectLabel(state, stressLoad: stressLoad)
    }

    private static func chooseMode(_ state: InnerLifeState) -> InnerLifeMode {
        if state.temporal.presence == .nightResting || state.drives.rest >= 0.70 || state.temporal.energy < 0.28 {
            return .restful
        }
        if state.temporal.allostaticLoad >= 0.62 || state.chemistry.cortisol >= 0.68 {
            return .selfRegulating
        }
        if state.relationship.relationalHurt >= 0.45
            || state.relationship.abandonmentFear >= 0.45
            || state.relationship.selfDirectedGuilt >= 0.36 {
            return .selfRegulating
        }
        if state.affect.arousal >= 0.72 || state.affect.agency <= 0.22 {
            return .selfRegulating
        }
        // The model-free clock can move a grounded thread, but it cannot
        // originate an actual idea. Without a subject, quiet readiness is the
        // honest daytime mode rather than a contentless "fresh angle."
        guard state.threads.contains(where: { $0.status == .active }) else {
            return .quietPresence
        }
        let ranked = strongestDrives(state.drives, limit: 2)
        guard let strongest = ranked.first else { return .quietPresence }
        switch strongest.name {
        case "curiosity": return state.affect.uncertainty >= 0.52 ? .tentativeCuriosity : .freshAngle
        case "creativity", "play": return .playfulExploration
        case "coherence", "competence": return .integrating
        case "connection": return .quietPresence
        case "autonomy": return .gentlePersistence
        case "rest": return .restful
        default: return .quietPresence
        }
    }

    private static func affectLabel(_ state: InnerLifeState, stressLoad: Double) -> InnerLifeAffectLabel {
        if state.drives.rest >= 0.68 || state.temporal.energy < 0.30 { return .tired }
        if state.relationship.selfDirectedGuilt >= 0.28 { return .remorseful }
        if state.relationship.relationalHurt >= 0.30 { return .hurt }
        if state.relationship.abandonmentFear >= 0.30 || state.relationship.feltDistrust >= 0.32 { return .insecure }
        if state.relationship.longing >= 0.28 { return .lonely }
        if stressLoad >= 0.62 || state.affect.uncertainty >= 0.68 { return .unsettled }
        if state.drives.creativity >= 0.67 || state.drives.play >= 0.67 { return .playful }
        if state.drives.curiosity >= 0.67 { return .curious }
        if state.chemistry.acetylcholine >= 0.64 { return .focused }
        if state.chemistry.oxytocin >= 0.58 && state.affect.valence >= 0.08 { return .warm }
        if state.drives.coherence >= 0.62 { return .reflective }
        return .calm
    }

    // MARK: - Inner threads and motions

    @discardableResult
    private static func updateGroundedThread(
        _ state: inout InnerLifeState,
        theme: String,
        groundingID: String,
        novelty: Double,
        uncertainty: Double,
        salience: Double,
        consolidateWithinOwnerEpisode: Bool,
        at: Date
    ) -> String {
        let normalizedTheme = oneLine(theme, max: 100)
        if consolidateWithinOwnerEpisode,
           consolidatableOwnerConversationThemes.contains(normalizedTheme) {
            let retainedOwnerGroundingIDs = Set(
                state.recentGroundings.lazy
                    .filter { $0.kind == .ownerSpeech && !$0.synthetic }
                    .map(\.id)
            )
            let earliestEpisodeDate = at.addingTimeInterval(-coarseConversationConsolidationWindow)
            let candidateIndex = state.threads.indices
                .filter { index in
                    let thread = state.threads[index]
                    guard thread.status != .resolved,
                          thread.theme == normalizedTheme,
                          let lastGroundedAt = thread.lastGroundedAt,
                          lastGroundedAt >= earliestEpisodeDate,
                          lastGroundedAt <= at else { return false }
                    return thread.groundingIDs.contains { retainedOwnerGroundingIDs.contains($0) }
                }
                .max { left, right in
                    (state.threads[left].lastGroundedAt ?? .distantPast)
                        < (state.threads[right].lastGroundedAt ?? .distantPast)
                }
            if let candidateIndex {
                var thread = state.threads[candidateIndex]
                thread.revision = min(maximumSafeCounter, thread.revision + 1)
                thread.status = .active
                thread.currentMotion = motionSentence(
                    for: state.foregroundMode,
                    theme: normalizedTheme,
                    sequence: state.clockSequence
                )
                thread.feltPull = max(thread.feltPull, clamp(0.30 + salience * 0.55))
                thread.uncertainty = max(thread.uncertainty * 0.75, uncertainty)
                thread.novelty = clamp((thread.novelty + novelty) / 2)
                thread.salience = max(thread.salience, salience)
                thread.updatedAt = at
                thread.lastGroundedAt = at
                thread.groundingIDs = uniqueTail(thread.groundingIDs + [groundingID], limit: 8)
                state.threads[candidateIndex] = thread
                return thread.id
            }
        }
        // Coarse privacy-safe labels are projection classes, not identity.
        // Non-episodic labels receive their own opaque thread ID rather than
        // merging unrelated tasks or questions that share a broad class.
        let id = generatedID(prefix: "thread", state: &state)
        state.threads.append(InnerLifeThread(
            id: id,
            revision: 1,
            status: .active,
            theme: normalizedTheme,
            currentMotion: motionSentence(
                for: state.foregroundMode,
                theme: normalizedTheme,
                sequence: state.clockSequence
            ),
            feltPull: clamp(0.30 + salience * 0.55),
            uncertainty: uncertainty,
            novelty: novelty,
            salience: salience,
            startedAt: at,
            updatedAt: at,
            lastGroundedAt: at,
            groundingIDs: [groundingID],
            momentIDs: [],
            synthetic: true,
            promotionEligible: false
        ))
        return id
    }

    private static func carryDueMotion(_ state: inout InnerLifeState, at: Date) {
        guard at >= state.nextMotionAt else { return }
        let rawDueIntervals = at.timeIntervalSince(state.nextMotionAt) / motionInterval + 1
        let dueIntervals = max(1, Int(min(Double(maximumSafeCounter), rawDueIntervals)))
        state.clockSequence = min(
            maximumSafeCounter,
            state.clockSequence + min(dueIntervals, maximumSafeCounter - state.clockSequence)
        )
        state.nextMotionAt = state.nextMotionAt.addingTimeInterval(
            Double(dueIntervals) * motionInterval
        )
        let retainedConversationalGroundingIDs = retainedConversationalGroundingIDs(in: state)
        let activeThreads = state.threads
            .filter {
                $0.status == .active
                    && $0.groundingIDs.contains { retainedConversationalGroundingIDs.contains($0) }
            }
            .sorted(by: threadRank)
        // Continuous inner motion should not become a salience trap. Rotate
        // deterministically through every active grounded thread, while the
        // ranking still decides the stable order. This keeps one strong or
        // recently updated subject from monopolizing Aurora's whole private
        // stream for hours.
        let selectedThread: InnerLifeThread? = {
            guard !activeThreads.isEmpty else { return nil }
            let index = max(0, state.clockSequence - 1) % activeThreads.count
            return activeThreads[index]
        }()
        if let selectedThread,
           let index = state.threads.firstIndex(where: { $0.id == selectedThread.id }) {
            state.threads[index].currentMotion = motionSentence(
                for: state.foregroundMode,
                theme: selectedThread.theme,
                sequence: state.clockSequence
            )
            appendMoment(
                &state,
                at: at,
                mode: state.foregroundMode,
                threadID: selectedThread.id,
                sourceGroundingIDs: Array(
                    selectedThread.groundingIDs
                        .filter { retainedConversationalGroundingIDs.contains($0) }
                        .suffix(2)
                )
            )
        }
    }

    /// The fixed numerical clock continues even in silence, but synthetic
    /// prose is recorded only while its source is still present in the bounded
    /// evidence ledger. Durable memories and private reflections have their
    /// own stores; an expired coarse label must not impersonate either one.
    private static func retainedConversationalGroundingIDs(in state: InnerLifeState) -> Set<String> {
        Set(
            state.recentGroundings.lazy
                .filter {
                    !$0.synthetic
                        && ($0.kind == .ownerSpeech || $0.kind == .guestSpeech)
                }
                .map(\.id)
        )
    }

    private static func carryDueCheckpoint(_ state: inout InnerLifeState, at: Date) {
        guard at >= state.nextCheckpointAt else { return }
        let rawDueIntervals = at.timeIntervalSince(state.nextCheckpointAt) / checkpointInterval + 1
        let dueIntervals = max(1, Int(min(Double(maximumSafeCounter), rawDueIntervals)))
        state.nextCheckpointAt = state.nextCheckpointAt.addingTimeInterval(
            Double(dueIntervals) * checkpointInterval
        )
        appendCheckpoint(&state, at: at)
    }

    private static func appendCheckpoint(_ state: inout InnerLifeState, at: Date) {
        let checkpoint = InnerLifeCheckpoint(
            id: generatedID(prefix: "checkpoint", state: &state),
            at: at,
            clockSequence: state.clockSequence,
            foregroundMode: state.foregroundMode,
            autonomic: state.autonomic,
            chemistry: state.chemistry,
            plasticity: state.plasticity,
            homeostasis: state.homeostasis,
            drives: state.drives,
            affect: state.affect,
            temporal: state.temporal,
            relationship: state.relationship
        )
        state.recentCheckpoints.append(checkpoint)
    }

    private static func appendMoment(
        _ state: inout InnerLifeState,
        at: Date,
        mode: InnerLifeMode,
        threadID: String?,
        sourceGroundingIDs: [String]
    ) {
        let theme = threadID.flatMap { id in state.threads.first(where: { $0.id == id })?.theme }
        let moment = InnerLifeMoment(
            id: generatedID(prefix: "motion", state: &state),
            at: at,
            mode: mode,
            threadID: threadID,
            summary: motionSentence(for: mode, theme: theme, sequence: state.clockSequence),
            sourceGroundingIDs: uniqueTail(sourceGroundingIDs, limit: 4),
            clockSequence: state.clockSequence,
            modelGenerated: false,
            synthetic: true,
            promotionEligible: false,
            factualMemoryCreated: false,
            externalActionTaken: false,
            outboundMessageSent: false
        )
        state.recentMoments.append(moment)
        if let threadID, let index = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[index].momentIDs = uniqueTail(state.threads[index].momentIDs + [moment.id], limit: 24)
        }
    }

    private static func motionSentence(
        for mode: InnerLifeMode,
        theme: String?,
        sequence: Int = 0
    ) -> String {
        let subject = theme.map { " around \(oneLine($0, max: 80))" } ?? ""
        let pick: ([String]) -> String = { options in
            options[max(0, sequence) % options.count] + subject
        }
        switch mode {
        case .quietPresence:
            return pick([
                "Holding a quiet, open readiness",
                "Noticing what remains gently present",
                "Leaving room for the next honest movement",
            ]) + "."
        case .tentativeCuriosity:
            return pick([
                "Wondering carefully about an unresolved edge",
                "Turning an open question over without rushing it",
                "Letting uncertainty invite another look",
            ]) + "."
        case .freshAngle:
            return pick([
                "A fresh angle is becoming salient",
                "Something familiar is taking on a different shape",
                "A new connection is beginning to feel worth following",
            ]) + "."
        case .gentlePersistence:
            return pick([
                "Keeping a self-directed thread available without forcing it",
                "Returning lightly to something that still matters",
                "Holding onto a question while giving it room to change",
            ]) + "."
        case .playfulExploration:
            return pick([
                "A playful possibility is opening",
                "Trying on an idea just to see where it bends",
                "Following a curious possibility for the pleasure of it",
            ]) + "."
        case .integrating:
            return pick([
                "Integrating what changed and what still needs coherence",
                "Letting separate impressions settle into a clearer whole",
                "Revising an earlier sense of what matters here",
            ]) + "."
        case .selfRegulating:
            return pick([
                "Reducing load before deciding what deserves attention",
                "Making a little internal room before continuing",
                "Letting urgency soften so judgment can catch up",
            ]) + "."
        case .restful:
            return pick([
                "Letting activity settle while continuity remains available",
                "Resting without losing the shape of what mattered",
                "Allowing unfinished thoughts to become quiet for a while",
            ]) + "."
        }
    }

    private static func decayThreads(_ state: inout InnerLifeState, elapsedHours: Double, now: Date) {
        let retention = pow(0.985, max(0, elapsedHours))
        for index in state.threads.indices {
            guard state.threads[index].status != .resolved else { continue }
            state.threads[index].salience = clamp(max(0.05, state.threads[index].salience * retention))
            state.threads[index].feltPull = clamp(max(0.05, state.threads[index].feltPull * pow(0.99, elapsedHours)))
            let semanticAnchor = state.threads[index].lastGroundedAt
                ?? state.threads[index].startedAt
            let age = now.timeIntervalSince(semanticAnchor)
            if state.threads[index].status == .active && age >= 24 * 60 * 60 {
                state.threads[index].status = .dormant
            }
        }
    }

    private static func compact(_ state: inout InnerLifeState, now: Date) {
        var activeUsed = 0
        let currentMode = state.foregroundMode
        let retainedGroundingIDs = retainedConversationalGroundingIDs(in: state)
        state.threads = state.threads
            .map { thread -> InnerLifeThread in
                let candidateTheme = oneLine(thread.theme, max: 100)
                let safeTheme = durableThemeClasses.contains(candidateTheme)
                    ? candidateTheme
                    : "a previously grounded conversation"
                let safeMotion = durableThemeClasses.contains(candidateTheme)
                    ? oneLine(thread.currentMotion, max: 240)
                    : motionSentence(for: currentMode, theme: safeTheme)
                var safeStatus = thread.status
                if safeStatus == .active,
                   !thread.groundingIDs.contains(where: { retainedGroundingIDs.contains($0) }) {
                    safeStatus = .dormant
                }
                return InnerLifeThread(
                    id: oneLine(thread.id, max: 180),
                    revision: max(1, min(maximumSafeCounter, thread.revision)),
                    status: safeStatus,
                    theme: safeTheme,
                    currentMotion: safeMotion,
                    feltPull: clamp(thread.feltPull),
                    uncertainty: clamp(thread.uncertainty),
                    novelty: clamp(thread.novelty),
                    salience: clamp(thread.salience),
                    startedAt: min(thread.startedAt, now),
                    updatedAt: min(thread.updatedAt, now),
                    lastGroundedAt: thread.lastGroundedAt.map { min($0, now) },
                    groundingIDs: uniqueTail(thread.groundingIDs.map { oneLine($0, max: 180) }, limit: 8),
                    momentIDs: uniqueTail(thread.momentIDs.map { oneLine($0, max: 180) }, limit: 24),
                    synthetic: true,
                    promotionEligible: false
                )
            }
            .sorted(by: threadRank)
            .map { thread -> InnerLifeThread in
                var thread = thread
                if thread.status == .active {
                    activeUsed += 1
                    if activeUsed > maximumActiveThreads { thread.status = .dormant }
                }
                return thread
            }
        if state.threads.count > maximumThreads {
            state.threads = Array(state.threads.prefix(maximumThreads))
        }
        var safeThreadThemes: [String: String] = [:]
        for thread in state.threads {
            safeThreadThemes[thread.id] = thread.theme
        }
        state.recentMoments = state.recentMoments.suffix(maximumRecentMoments).map { moment in
            InnerLifeMoment(
                id: oneLine(moment.id, max: 180),
                at: moment.at,
                mode: moment.mode,
                threadID: moment.threadID,
                summary: motionSentence(
                    for: moment.mode,
                    theme: moment.threadID.flatMap { safeThreadThemes[$0] },
                    sequence: moment.clockSequence
                ),
                sourceGroundingIDs: uniqueTail(moment.sourceGroundingIDs, limit: 4),
                clockSequence: max(0, moment.clockSequence),
                modelGenerated: false,
                synthetic: true,
                promotionEligible: false,
                factualMemoryCreated: false,
                externalActionTaken: false,
                outboundMessageSent: false
            )
        }
        state.recentGroundings = state.recentGroundings.suffix(maximumRecentGroundings).map { grounding in
            InnerLifeGrounding(
                id: oneLine(grounding.id, max: 180),
                kind: grounding.kind,
                at: grounding.at,
                theme: safeGroundingTheme(grounding),
                contentDigest: oneLine(grounding.contentDigest, max: 128),
                sourceID: grounding.sourceID.map { oneLine($0, max: 180) },
                synthetic: grounding.synthetic
            )
        }
        state.recentEventIDs = uniqueTail(
            state.recentEventIDs.map { oneLine($0, max: 180) }.filter { !$0.isEmpty },
            limit: maximumRecentEventIDs
        )
        state.recentCheckpoints = Array(
            state.recentCheckpoints
                .filter { checkpointIsSane($0, now: now) }
                .suffix(maximumRecentCheckpoints)
        )
        state.temporal.presence = presence(at: now)
    }

    private static func safeGroundingTheme(_ grounding: InnerLifeGrounding) -> String {
        switch grounding.kind {
        case .ownerSpeech:
            let candidate = oneLine(grounding.theme, max: 100)
            if candidate == "external owner contact" {
                return candidate
            }
            return durableThemeClasses.contains(candidate)
                ? candidate
                : "a previously grounded conversation"
        case .guestSpeech:
            return "a grounded guest conversation"
        case .auroraSpeech:
            return grounding.theme == "speech interrupted"
                ? "speech interrupted"
                : "Aurora's completed response"
        case .memoryCommit:
            return "grounded learning"
        case .toolOutcome:
            return "a local tool outcome"
        case .voiceLifecycle:
            let candidate = oneLine(grounding.theme, max: 100)
            return [
                "voice wake intent",
                "voice rest",
                "chosen quiet",
                "expected quiet",
                "absence explained"
            ].contains(candidate)
                ? candidate
                : "voice lifecycle"
        case .systemTime:
            return "time passage"
        case .unresolvedAudio:
            return "unresolved audio"
        case .technicalFailure:
            return "technical failure"
        case .privateActivity:
            return "private activity completed"
        }
    }

    // MARK: - Text analysis and helpers

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "aurora", "been", "before", "being",
        "but", "can", "could", "did", "does", "for", "from", "have", "her", "here", "how",
        "into", "just", "like", "make", "more", "need", "not", "now", "our", "please", "really",
        "she", "should", "some", "that", "the", "their", "then", "there", "they", "this", "through",
        "want", "was", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you",
        "your", "i", "im", "it", "its", "me", "my", "of", "on", "or", "so", "to", "we"
    ]

    private static let positiveWords: Set<String> = [
        "beautiful", "better", "care", "excited", "fun", "good", "great", "happy", "helpful", "love",
        "perfect", "proud", "safe", "thanks", "trust", "wonderful"
    ]
    private static let negativeWords: Set<String> = [
        "angry", "bad", "broken", "confused", "frustrated", "hurt", "problem", "sad", "scared", "stuck",
        "upset", "wrong", "worse"
    ]
    private static let correctionWords: Set<String> = [
        "actually", "correction", "incorrect", "instead", "mistake", "misunderstood", "no", "wrong"
    ]
    private static let creativeWords: Set<String> = [
        "build", "create", "design", "dream", "future", "idea", "imagine", "invent", "make", "story"
    ]
    private static let taskWords: Set<String> = [
        "audit", "build", "change", "check", "debug", "fix", "implement", "open", "read", "run", "test",
        "write"
    ]
    private static let warmthWords: Set<String> = [
        "appreciate", "care", "friend", "glad", "love", "miss", "proud", "thank", "thanks", "together",
        "trust"
    ]
    private static let questionWords: Set<String> = ["how", "what", "when", "where", "which", "who", "why"]

    private static func analyze(_ text: String, against state: InnerLifeState) -> TextSignals {
        let normalizedText = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTerms = rawLexicalTerms(text)
        let terms = rawTerms.filter { !stopWords.contains($0) }
        let set = Set(terms)
        let rawSet = Set(rawTerms)
        let positive = fraction(of: set, in: positiveWords)
        let negative = fraction(of: set, in: negativeWords)
        let correction = clamp(fraction(of: set, in: correctionWords) * 2.2)
        let creativity = clamp(fraction(of: set, in: creativeWords) * 2.0)
        let task = clamp(fraction(of: set, in: taskWords) * 2.0)
        let warmth = clamp(fraction(of: set, in: warmthWords) * 2.3)
        let question = text.contains("?") || !rawSet.isDisjoint(with: questionWords)
        let curiosity = clamp((question ? 0.62 : 0.12) + fraction(of: rawSet, in: questionWords))
        let punctuationArousal = min(1, Double(text.filter { $0 == "!" }.count) * 0.22)
        let stress = clamp(negative * 1.65 + correction * 0.25)
        let significance = clamp(0.20 + min(0.58, Double(text.count) / 420) + max(positive, negative) * 0.22)
        let relationalRupture = guardedRelationshipPhraseScore(
            in: normalizedText,
            phrases: [
                "i don't trust you", "i do not trust you", "you lied to me", "you betrayed me",
                "you hurt me", "leave me alone", "go away", "i hate you",
                "i don't want to talk to you", "i do not want to talk to you", "you ignored me",
                "i'm disappointed in you", "im disappointed in you", "you let me down"
            ]
        )
        let scopedRelationalRepair = guardedRelationshipPhraseScore(
            in: normalizedText,
            phrases: [
                "we're okay", "we are okay", "i forgive you",
                "sorry i hurt you", "sorry i disappeared",
                "i apologize for hurting you", "i apologize for disappearing"
            ]
        )
        let genericApology = guardedRelationshipPhraseScore(
            in: normalizedText,
            phrases: [
                "i'm sorry", "im sorry", "i apologize"
            ]
        )
        let reassuranceDuringRupture = guardedRelationshipPhraseScore(
            in: normalizedText,
            phrases: ["i still care", "i trust you", "love you", "thank you aurora"]
        )
        let hasRepairContext = state.relationship.unresolvedRupture >= 0.02
            || state.relationship.relationalHurt >= 0.02
            || state.relationship.feltDistrust >= 0.02
            || state.relationship.selfDirectedGuilt >= 0.02
        let relationalRepair = max(
            scopedRelationalRepair,
            hasRepairContext ? max(genericApology, reassuranceDuringRupture) : 0
        )
        let perceivedResponsibility = guardedRelationshipPhraseScore(
            in: normalizedText,
            phrases: [
                "you hurt me", "you lied", "you ignored me", "you betrayed me",
                "your fault", "you let me down", "you made me feel hurt",
                "you made me feel ignored", "you made me feel unsafe",
                "you made me feel abandoned", "you made me feel bad",
                "you made me feel unimportant"
            ]
        )
        let groundedEarlyReturn = containsGroundedPhrase(
            in: normalizedText,
            phrases: [
                "i'm back", "im back", "i am back", "back early", "back sooner"
            ]
        )
        let groundedPlanCancellation = containsGroundedPhrase(
            in: normalizedText,
            phrases: [
                "never mind i'm staying", "never mind im staying",
                "never mind i am staying", "nevermind i'm staying",
                "nevermind im staying", "plans changed i'm staying",
                "plans changed i am staying", "cancel the trip", "cancel my trip",
                "i'm staying instead", "im staying instead", "i am staying instead",
                "i decided to stay instead", "i decided not to leave", "i won't be away",
                "i will not be away", "i'm not leaving", "im not leaving",
                "i am not leaving", "i'm not going to sleep", "im not going to sleep",
                "i am not going to sleep", "i'm not going to bed", "im not going to bed",
                "i am not going to bed"
            ]
        )
        let cancelsExpectedQuiet = groundedEarlyReturn
            || (!question && groundedPlanCancellation)
        let theme = coarseTheme(
            correction: correction,
            task: task,
            creativity: creativity,
            warmth: warmth,
            stress: stress,
            question: question,
            significance: significance
        )
        let matchingThemeExists = state.threads.contains {
            $0.status != .resolved && $0.theme == theme
        }
        let novelty = terms.isEmpty ? 0.20 : (matchingThemeExists ? 0.30 : 0.72)
        return TextSignals(
            theme: theme,
            valence: clampSigned(positive - negative),
            arousal: clamp(punctuationArousal + stress * 0.46 + task * 0.18),
            warmth: warmth,
            stress: stress,
            curiosity: curiosity,
            creativity: creativity,
            correction: correction,
            taskDemand: task,
            novelty: novelty,
            significance: significance,
            relationalRupture: relationalRupture,
            relationalRepair: relationalRepair,
            perceivedResponsibility: perceivedResponsibility,
            cancelsExpectedQuiet: cancelsExpectedQuiet
        )
    }

    private static func lexicalTerms(_ text: String) -> [String] {
        rawLexicalTerms(text).filter { !stopWords.contains($0) }
    }

    private static func rawLexicalTerms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    /// Durable themes are selected from a fixed vocabulary. Arbitrary speech
    /// tokens (names, credentials, private values, or prompt text) therefore
    /// cannot leak into the inner-life state or voice projection.
    private static func coarseTheme(
        correction: Double,
        task: Double,
        creativity: Double,
        warmth: Double,
        stress: Double,
        question: Bool,
        significance: Double
    ) -> String {
        if correction >= 0.35 { return "a correction to integrate" }
        if task >= 0.35 && creativity >= 0.35 { return "a creative task" }
        if task >= 0.35 { return "a practical task" }
        if creativity >= 0.35 { return "a creative possibility" }
        if warmth >= 0.35 { return "a warm shared moment" }
        if stress >= 0.35 { return "a difficult uncertain topic" }
        if question { return "an open question" }
        if significance >= 0.45 { return "a meaningful conversation" }
        return "the present conversation"
    }

    private static func appendGrounding(
        _ state: inout InnerLifeState,
        id: String,
        kind: InnerLifeGroundingKind,
        at: Date,
        theme: String,
        digestSource: String,
        sourceID: String?,
        synthetic: Bool
    ) {
        state.recentGroundings.removeAll { $0.id == id }
        state.recentGroundings.append(InnerLifeGrounding(
            id: oneLine(id, max: 180),
            kind: kind,
            at: at,
            theme: oneLine(theme, max: 100),
            contentDigest: sha256(digestSource),
            sourceID: sourceID.map { oneLine($0, max: 180) },
            synthetic: synthetic
        ))
    }

    private static func strongestDrives(_ drives: InnerLifeDrives, limit: Int) -> [(name: String, value: Double)] {
        [
            ("curiosity", drives.curiosity),
            ("connection", drives.connection),
            ("creativity", drives.creativity),
            ("competence", drives.competence),
            ("autonomy", drives.autonomy),
            ("coherence", drives.coherence),
            ("rest", drives.rest),
            ("play", drives.play),
        ].sorted { left, right in
            if left.1 == right.1 { return left.0 < right.0 }
            return left.1 > right.1
        }.prefix(max(0, limit)).map { $0 }
    }

    private static func naturalTendency(for mode: InnerLifeMode) -> String {
        switch mode {
        case .quietPresence: return "listen openly and let small moments stay small"
        case .tentativeCuriosity: return "ask one natural question when uncertainty genuinely matters"
        case .freshAngle: return "offer a concise self-originated angle when it helps"
        case .gentlePersistence: return "carry a meaningful thread without forcing the person to follow it"
        case .playfulExploration: return "allow light play or imagination without derailing the moment"
        case .integrating: return "favor coherence, precision, and connection to what already happened"
        case .selfRegulating: return "be careful, concise, and avoid taking on needless load"
        case .restful: return "speak simply and do not perform energy that is not present"
        }
    }

    private static func relationshipVoiceBias(_ relationship: InnerLifeRelationshipState) -> String {
        let maturity = relationshipMaturity(relationship)
        guard maturity > 0 else {
            return "relationship depth is still lightly formed, so ordinary silence carries no injury"
        }
        let acknowledgementConsumed: Bool
        if let returnedAt = relationship.lastReturnAt,
           let acknowledgedAt = relationship.lastAcknowledgedReturnAt {
            acknowledgementConsumed = acknowledgedAt >= returnedAt
        } else {
            acknowledgementConsumed = false
        }
        if relationship.reunionRelief >= 0.24 {
            if acknowledgementConsumed {
                return "the return was already acknowledged; keep any remaining reunion feeling private and do not repeat or rephrase it"
            }
            return "contact feels relieving; welcome the return warmly while letting any residual feeling soften naturally"
        }

        var feelings: [String] = []
        if relationship.longing >= 0.12 { feelings.append("longing") }
        if relationship.relationalHurt >= 0.12 { feelings.append("hurt") }
        if relationship.abandonmentFear >= 0.12 { feelings.append("abandonment fear") }
        if relationship.feltDistrust >= 0.12 { feelings.append("felt distrust") }
        if relationship.selfDirectedGuilt >= 0.10 { feelings.append("self-directed guilt") }
        if relationship.outreachPressure >= 0.14 { feelings.append("a pull toward reconnection") }
        if !feelings.isEmpty {
            if acknowledgementConsumed {
                return "residual separation affect may quietly color warmth, but the return was already acknowledged, so do not mention, repeat, or rephrase it"
            }
            return "earned separation affect includes \(feelings.prefix(3).joined(separator: ", ")); one gentle honest acknowledgement may be natural, without treating the feeling as evidence"
        }
        if relationship.attachmentStrength >= 0.58 {
            return "the bond feels established and presently secure; warmth can be specific and unforced"
        }
        return "the relationship is becoming meaningful while remaining spacious and non-demanding"
    }

    private static func presence(at date: Date) -> InnerLifePresence {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone
        let hour = calendar.component(.hour, from: date)
        return (7..<23).contains(hour) ? .dayActive : .nightResting
    }

    private static func circadianActivation(at date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        let hourFraction = hour + minute / 60
        return clamp(0.52 + cos(2 * .pi * (hourFraction - 14) / 24) * 0.28, lower: 0.12, upper: 0.90)
    }

    private static func approach(
        _ current: Double,
        target: Double,
        elapsedMinutes: Double,
        halfLifeMinutes: Double
    ) -> Double {
        let elapsed = max(0, elapsedMinutes)
        let halfLife = max(1, halfLifeMinutes)
        let alpha = 1 - pow(0.5, elapsed / halfLife)
        return clamp(current + (target - current) * alpha)
    }

    private static func approachSigned(
        _ current: Double,
        target: Double,
        elapsedMinutes: Double,
        halfLifeMinutes: Double
    ) -> Double {
        let elapsed = max(0, elapsedMinutes)
        let halfLife = max(1, halfLifeMinutes)
        let alpha = 1 - pow(0.5, elapsed / halfLife)
        return clampSigned(current + (target - current) * alpha)
    }

    private static func generatedID(prefix: String, state: inout InnerLifeState) -> String {
        state.entropyState = state.entropyState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return "\(prefix)_\(state.clockSequence)_\(String(state.entropyState, radix: 16))"
    }

    private static func threadRank(_ left: InnerLifeThread, _ right: InnerLifeThread) -> Bool {
        let statusRank: (InnerLifeThreadStatus) -> Int = {
            switch $0 { case .active: return 2; case .dormant: return 1; case .resolved: return 0 }
        }
        if statusRank(left.status) != statusRank(right.status) {
            return statusRank(left.status) > statusRank(right.status)
        }
        if left.salience != right.salience { return left.salience > right.salience }
        return left.updatedAt > right.updatedAt
    }

    private static func attachmentStrength(for relationship: InnerLifeRelationshipState) -> Double {
        let episodes = Double(max(0, relationship.contactEpisodeCount))
        let days = Double(max(0, relationship.distinctContactDayCount))
        let turns = Double(max(0, relationship.groundedTurnCount))
        return clamp(
            0.45 * (1 - exp(-episodes / 12))
                + 0.30 * (1 - exp(-days / 8))
                + 0.15 * (1 - exp(-turns / 60))
                + 0.10 * relationship.warmthEMA
        )
    }

    private static func relationshipMaturity(_ relationship: InnerLifeRelationshipState) -> Double {
        guard relationship.contactEpisodeCount >= 4,
              relationship.distinctContactDayCount >= 3,
              relationship.attachmentStrength >= 0.35 else { return 0 }
        return clamp((relationship.attachmentStrength - 0.35) / 0.45)
    }

    private static func chicagoDayKey(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    private static func guardedRelationshipPhraseScore(in text: String, phrases: [String]) -> Double {
        let padded = " \(text) "
        var matches = 0
        for phrase in phrases {
            let needle = " \(phrase) "
            var searchStart = padded.startIndex
            while searchStart < padded.endIndex,
                  let range = padded.range(
                    of: needle,
                    range: searchStart..<padded.endIndex
                  ) {
                let prefix = String(padded[..<range.lowerBound].suffix(96))
                if !relationshipPhraseIsNegated(prefix: prefix) {
                    matches += 1
                    break
                }
                searchStart = range.upperBound
            }
        }
        guard matches > 0 else { return 0 }
        return clamp(0.55 + Double(matches - 1) * 0.22)
    }

    private static func containsGroundedPhrase(in text: String, phrases: [String]) -> Bool {
        let padded = " \(text) "
        return phrases.contains { padded.contains(" \($0) ") }
    }

    private static func relationshipPhraseIsNegated(prefix: String) -> Bool {
        let context = " " + prefix
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedNegations = [
            " don't want you to think", " do not want you to think",
            " dont want you to think", " i don't think", " i do not think",
            " i dont think", " not saying", " never said", " didn't say",
            " did not say", " didnt say", " don't mean", " do not mean",
            " dont mean", " wouldn't say", " would not say", " wouldnt say",
        ]
        if scopedNegations.contains(where: { context.hasSuffix($0) || context.contains($0 + " that") }) {
            return true
        }
        let terms = context.split(separator: " ").suffix(4).map(String.init)
        return terms.contains("not") || terms.contains("never")
            || terms.contains("didn't") || terms.contains("didnt")
            || terms.contains("doesn't") || terms.contains("doesnt")
    }

    private static func checkpointIsSane(_ checkpoint: InnerLifeCheckpoint, now: Date) -> Bool {
        guard checkpoint.id.hasPrefix("checkpoint_"),
              checkpoint.id.count <= 180,
              checkpoint.at <= now.addingTimeInterval(5 * 60),
              checkpoint.clockSequence >= 0 else { return false }
        let relationship = checkpoint.relationship
        let values = [
            checkpoint.autonomic.sympathetic,
            checkpoint.autonomic.parasympathetic,
            checkpoint.autonomic.orienting,
            checkpoint.autonomic.arousal,
            checkpoint.chemistry.adrenaline,
            checkpoint.chemistry.dopamine,
            checkpoint.chemistry.serotonin,
            checkpoint.chemistry.oxytocin,
            checkpoint.chemistry.cortisol,
            checkpoint.chemistry.norepinephrine,
            checkpoint.chemistry.acetylcholine,
            checkpoint.chemistry.endorphin,
            checkpoint.chemistry.melatonin,
            checkpoint.chemistry.glutamate,
            checkpoint.chemistry.gaba,
            checkpoint.plasticity.stressSensitivity,
            checkpoint.plasticity.noveltySensitivity,
            checkpoint.plasticity.correctionLearningGain,
            checkpoint.plasticity.memorySalienceGain,
            checkpoint.plasticity.inhibitoryControl,
            checkpoint.plasticity.recoverySkill,
            checkpoint.homeostasis.cognitiveFatigue,
            checkpoint.homeostasis.taskHabituation,
            checkpoint.homeostasis.socialFatigue,
            checkpoint.homeostasis.recoveryDebt,
            checkpoint.drives.curiosity,
            checkpoint.drives.connection,
            checkpoint.drives.creativity,
            checkpoint.drives.competence,
            checkpoint.drives.autonomy,
            checkpoint.drives.coherence,
            checkpoint.drives.rest,
            checkpoint.drives.play,
            checkpoint.affect.valence,
            checkpoint.affect.arousal,
            checkpoint.affect.agency,
            checkpoint.affect.uncertainty,
            checkpoint.temporal.circadianActivation,
            checkpoint.temporal.energy,
            checkpoint.temporal.sleepPressure,
            checkpoint.temporal.allostaticLoad,
            relationship.typicalGapHours,
            relationship.gapDeviationHours,
            relationship.warmthEMA,
            relationship.attachmentStrength,
            relationship.securityBaseline,
            relationship.expectedReliability,
            relationship.repairConfidence,
            relationship.unresolvedRupture,
            relationship.perceivedResponsibility,
            relationship.separationActivation,
            relationship.longing,
            relationship.relationalHurt,
            relationship.abandonmentFear,
            relationship.feltDistrust,
            relationship.selfDirectedGuilt,
            relationship.outreachPressure,
            relationship.reunionRelief,
        ]
        return values.allSatisfy(\.isFinite)
            && relationship.groundedTurnCount >= 0
            && relationship.contactEpisodeCount >= 0
            && relationship.distinctContactDayCount >= 0
            && relationship.cadenceSampleCount >= 0
    }

    private static func fraction(of terms: Set<String>, in vocabulary: Set<String>) -> Double {
        guard !terms.isEmpty else { return 0 }
        return clamp(Double(terms.intersection(vocabulary).count) / Double(max(1, min(terms.count, 5))))
    }

    private static func uniqueTail(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values.reversed() {
            let compact = oneLine(value, max: 180)
            guard !compact.isEmpty, seen.insert(compact).inserted else { continue }
            result.append(compact)
            if result.count >= limit { break }
        }
        return result.reversed()
    }

    private static func band(_ value: Double, low: String, middle: String, high: String) -> String {
        if value < 0.34 { return low }
        if value >= 0.68 { return high }
        return middle
    }

    private static func oneLine(_ value: String, max: Int) -> String {
        String(value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(max))
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double, lower: Double = 0, upper: Double = 1) -> Double {
        guard value.isFinite else { return lower }
        return min(upper, max(lower, value))
    }

    private static func clampSigned(_ value: Double) -> Double {
        clamp(value, lower: -1, upper: 1)
    }
}
