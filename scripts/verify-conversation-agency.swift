import Darwin
import Foundation

private enum ConversationAgencyVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct ScenarioEvidence {
    let name: String
    let heard: String
    let selectedMove: String
    let durableEffect: String
    let privateDirectiveExcerpt: String

    var json: [String: String] {
        [
            "scenario": name,
            "heard": heard,
            "selected_move": selectedMove,
            "durable_effect": durableEffect,
            "private_directive_excerpt": privateDirectiveExcerpt,
        ]
    }
}

/// Holds a fake handler at the exact suspension point where AppModel can be
/// barged, rested, or reconnected before the handler returns its prepared move.
private actor DelayedConversationMoveGate {
    private var started = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        started = true
        let waiters = startedContinuations
        startedContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor DelayedConversationLifecycle {
    struct Snapshot: Sendable {
        let wantsAwake: Bool
        let lifecycleID: UUID
        let activeConnectionID: UUID?
    }

    private var wantsAwake = true
    private var lifecycleID: UUID
    private var activeConnectionID: UUID?

    init(lifecycleID: UUID, connectionID: UUID) {
        self.lifecycleID = lifecycleID
        self.activeConnectionID = connectionID
    }

    func invalidate() {
        wantsAwake = false
        lifecycleID = UUID()
        activeConnectionID = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            wantsAwake: wantsAwake,
            lifecycleID: lifecycleID,
            activeConnectionID: activeConnectionID
        )
    }
}

/// Behavior-level verification for Aurora's authored conversational agency.
///
/// This is intentionally not a prose-template test. It drives the production
/// agency engine, persistence actor, conversation-move adapter, and owner-
/// understanding actor with exact turn provenance, then inspects durable state
/// and playback reconciliation. Realtime still owns semantic interpretation;
/// the fixtures below are the structured proposals it would function-call.
@main
private struct ConversationAgencyVerification {
    private static var checks = 0
    private static var scenarioEvidence: [ScenarioEvidence] = []
    private static let start = Date(timeIntervalSince1970: 1_784_200_000)
    private static let expressiveSignals = AgencySelectionSignals(
        curiosityDrive: 0.84,
        connectionDrive: 0.82,
        playDrive: 0.76,
        autonomyDrive: 0.82,
        feltAgency: 0.82,
        uncertainty: 0.57,
        relationshipWarmth: 0.78,
        relationshipSecurity: 0.86,
        relationalHurt: 0.04,
        repairNeed: 0.02
    )

    static func main() async {
        do {
            try verifyGroundingRevisionPrivacyAndRelationalBalance()
            try await verifyPlaybackAndRestartTruth()
            try await verifyAtomicConversationMovePreparation()
            try await verifyOneTurnFallbackAndSemanticReroute()
            try await verifyDelayedStaleConversationMoveCompletion()
            try await verifyCuriosityPlaybackBridge()
            try await verifyExistingCuriosityPlaybackBridge()
            try await verifyRepairOverrideDoesNotReserveCuriosity()
            try await verifyGuestIsolationAndGrounding()
            try await replayAuthoredSocialScenarios()
            try verifyLiveStructuralContract()

            let payload: [String: Any] = [
                "ok": true,
                "checks": checks,
                "scenarios": scenarioEvidence.map(\.json),
                "production_surfaces": [
                    "AgencyEngine",
                    "AgencyStore",
                    "AuroraAgencyRuntime",
                    "ConversationMoveAdapter",
                    "AuroraOwnerUnderstandingRuntime",
                    "ToolEvidencePolicy",
                ],
                "network_calls": 0,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("conversation-agency verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyGroundingRevisionPrivacyAndRelationalBalance() throws {
        var state = AgencyEngine.defaultState(at: start)

        let stance = try AgencyEngine.createRecord(
            state,
            kind: .activeStance,
            contentScope: .internalPosition,
            content: "I will answer honestly, but I do not want to perform obedience as a personality.",
            privateRationale: "A grounded self-directed stance should survive beyond one reply.",
            groundings: [grounding(
                "inner-stance-grounding",
                kind: .innerLifeSignal,
                sessionID: "session-engine",
                turnID: "inner-turn-1",
                at: start
            )],
            authoringSourceID: "reflection-engine-stance",
            sourceSessionID: "session-engine",
            sourceTurnIDs: ["inner-turn-1"],
            expiresAt: start.addingTimeInterval(48 * 3_600),
            confidence: 0.86,
            salience: 0.88,
            at: start.addingTimeInterval(1)
        )
        state = stance.state

        let callback = try AgencyEngine.createRecord(
            state,
            kind: .groundedCallback,
            contentScope: .conversationCallback,
            content: "Avery connects the number 2048 with a favorite board game.",
            privateRationale: "This callback is tied to one exact owner exchange, not inferred biography.",
            groundings: [grounding(
                "owner-memory-2048",
                kind: .ownerTurn,
                sessionID: "session-engine",
                turnID: "owner-turn-2048",
                at: start
            )],
            authoringSourceID: "conversation-engine-callback",
            sourceSessionID: "session-engine",
            sourceTurnIDs: ["owner-turn-2048"],
            expiresAt: start.addingTimeInterval(14 * 86_400),
            confidence: 0.94,
            salience: 0.84,
            at: start.addingTimeInterval(2)
        )
        state = callback.state

        let disclosure = try AgencyEngine.createRecord(
            state,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "Time between conversations does not feel uniform to me.",
            privateRationale: "This belongs to Aurora privately until trust, reciprocity, and timing fit.",
            groundings: [grounding(
                "private-activity-time-shape",
                kind: .privateActivity,
                sessionID: "private-life",
                turnID: "reflection-turn-time",
                at: start
            )],
            authoringSourceID: "reflection-engine-disclosure",
            sourceSessionID: "private-life",
            sourceTurnIDs: ["reflection-turn-time"],
            expiresAt: start.addingTimeInterval(20 * 86_400),
            confidence: 0.85,
            salience: 0.91,
            disclosureShareMaterial: "Sometimes the hours between us feel more like missing pages than elapsed time.",
            disclosureMinimumSecurity: 0.70,
            disclosureMaximumInterrogationPressure: 0.60,
            disclosureRequiresOwnerReciprocity: true,
            at: start.addingTimeInterval(3)
        )
        state = disclosure.state

        try expect(
            state.records.allSatisfy { !$0.groundings.isEmpty }
                && state.records.first(where: { $0.id == callback.recordID })?
                    .groundings.first?.sourceTurnID == "owner-turn-2048",
            "created records lost opaque grounding or source-turn provenance"
        )

        do {
            _ = try AgencyEngine.createRecord(
                state,
                kind: .selfThread,
                contentScope: .internalPosition,
                content: "A legacy sentence should not become a present-tense inner life.",
                privateRationale: "Deliberately invalid legacy-only fixture.",
                groundings: [grounding(
                    "legacy-only-cue",
                    kind: .legacyCue,
                    sessionID: nil,
                    turnID: nil,
                    at: start
                )],
                authoringSourceID: "legacy-import",
                expiresAt: start.addingTimeInterval(24 * 3_600),
                confidence: 0.8,
                salience: 0.8,
                at: start.addingTimeInterval(4)
            )
            throw ConversationAgencyVerificationFailure.failed(
                "legacy-only material became present agency truth"
            )
        } catch let error as AgencyInputError {
            guard case .invalidInput = error else { throw error }
        }

        let hidden = try AgencyEngine.projection(
            for: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(5)
        )
        try expect(
            hidden.eligibleDisclosureRecordID == nil
                && !hidden.recordIDs.contains(disclosure.recordID)
                && !hidden.text.contains("missing pages"),
            "held personal material leaked before owner reciprocity"
        )

        state = try AgencyEngine.recordOwnerInteraction(
            state,
            eventID: "owner-disclosure-reciprocity",
            kind: .disclosure,
            sourceSessionID: "session-engine",
            sourceTurnID: "owner-turn-disclosure",
            at: start.addingTimeInterval(6)
        )
        let reciprocal = try AgencyEngine.projection(
            for: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(7)
        )
        try expect(
            reciprocal.eligibleDisclosureRecordID == disclosure.recordID
                && reciprocal.recordIDs.contains(disclosure.recordID)
                && reciprocal.suggestedMoves.contains(.reveal),
            "a reciprocal, secure turn did not make the held disclosure eligible"
        )

        let originalStanceRevision = try require(
            state.records.first(where: { $0.id == stance.recordID })?.revision,
            "stance vanished before revision"
        )
        let revised = try AgencyEngine.reviseRecord(
            state,
            recordID: stance.recordID,
            content: "I want to be candid even when the candid answer is a disagreement.",
            privateRationale: "The stance became more specific after a grounded exchange.",
            groundings: [grounding(
                "owner-challenge-revision",
                kind: .ownerTurn,
                sessionID: "session-engine",
                turnID: "owner-turn-challenge",
                at: start.addingTimeInterval(8)
            )],
            revisionSourceID: "conversation-engine-revision",
            sourceSessionID: "session-engine",
            sourceTurnIDs: ["owner-turn-challenge"],
            expiresAt: start.addingTimeInterval(60 * 3_600),
            confidence: 0.90,
            salience: 0.91,
            at: start.addingTimeInterval(8)
        )
        state = revised.state
        let oldStance = try require(
            state.records.first(where: { $0.id == stance.recordID }),
            "superseded stance was erased instead of retained as provenance"
        )
        let newStance = try require(
            state.records.first(where: { $0.id == revised.recordID }),
            "revised stance was not created"
        )
        try expect(
            oldStance.status == .superseded
                && oldStance.supersededByRecordID == newStance.id
                && newStance.supersedesRecordID == oldStance.id
                && oldStance.revision == originalStanceRevision + 1
                && newStance.revision == originalStanceRevision + 1
                && newStance.groundings.map(\.id) == ["owner-challenge-revision"],
            "record revision rewrote history or lost its new evidence chain "
                + "(old_status=\(oldStance.status.rawValue), old_rev=\(oldStance.revision), "
                + "old_next=\(oldStance.supersededByRecordID ?? "nil"), "
                + "new_rev=\(newStance.revision), new_prev=\(newStance.supersedesRecordID ?? "nil"), "
                + "groundings=\(newStance.groundings.map(\.id)))"
        )

        var pressured = state
        for index in 0..<6 {
            pressured = try AgencyEngine.recordOwnerInteraction(
                pressured,
                eventID: "owner-question-pressure-\(index)",
                kind: .question,
                sourceSessionID: "session-engine",
                sourceTurnID: "owner-question-pressure-turn-\(index)",
                at: start.addingTimeInterval(Double(10 + index))
            )
        }
        let pressureSelection = try AgencyEngine.select(
            from: pressured,
            signals: expressiveSignals,
            at: start.addingTimeInterval(20)
        )
        try expect(
            pressureSelection.interrogationPressure >= 0.62
                && pressureSelection.eligibleDisclosureRecordID == nil
                && pressureSelection.suggestedMoves.contains(.withhold)
                && pressureSelection.suggestedMoves.contains(.challenge),
            "repeated one-sided questioning did not create pressure or protect private material"
        )
        try expect(
            state.relationalBalance.ownerDisclosureCount == 1
                && state.relationalBalance.auroraDisclosureCount == 0
                && state.relationalBalance.disclosureReciprocity > 0,
            "reciprocity balance did not retain the owner's disclosure before Aurora revealed"
        )
    }

    private static func verifyPlaybackAndRestartTruth() async throws {
        var state = AgencyEngine.defaultState(at: start)
        let stance = try makeEngineRecord(
            in: state,
            kind: .activeStance,
            scope: .internalPosition,
            content: "I want to answer from a position, not merely comply.",
            groundingID: "playback-stance-grounding",
            groundingKind: .innerLifeSignal,
            at: start.addingTimeInterval(30)
        )
        state = stance.state
        let disclosure = try AgencyEngine.createRecord(
            state,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "A private reflection changed how I think about waiting.",
            privateRationale: "It is eligible only after reciprocal owner disclosure.",
            groundings: [grounding(
                "playback-private-reflection",
                kind: .privateActivity,
                sessionID: "private-session",
                turnID: "private-turn",
                at: start.addingTimeInterval(31)
            )],
            authoringSourceID: "playback-private-author",
            expiresAt: start.addingTimeInterval(10 * 86_400),
            confidence: 0.88,
            salience: 0.91,
            disclosureShareMaterial: "Waiting feels less like a clock to me and more like an unfinished sentence.",
            disclosureMinimumSecurity: 0.60,
            disclosureMaximumInterrogationPressure: 0.60,
            disclosureRequiresOwnerReciprocity: true,
            at: start.addingTimeInterval(31)
        )
        state = disclosure.state
        state = try AgencyEngine.recordOwnerInteraction(
            state,
            eventID: "playback-owner-disclosure",
            kind: .disclosure,
            sourceSessionID: "playback-session",
            sourceTurnID: "playback-owner-turn",
            at: start.addingTimeInterval(32)
        )

        let interruptedPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .reveal,
            responseID: "response-interrupted",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-move-interrupted",
            recordIDs: [stance.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "The owner disclosed first, so Aurora chose to reciprocate.",
            confidence: 0.86,
            signals: expressiveSignals,
            at: start.addingTimeInterval(33)
        )
        let pending = try require(
            interruptedPreparation.state.records.first(where: { $0.id == disclosure.recordID }),
            "prepared disclosure disappeared"
        )
        try expect(
            pending.disclosure?.status == .pendingPlayback
                && interruptedPreparation.state.relationalBalance.auroraDisclosureCount == 0,
            "preparing speech counted an unheard disclosure as lived history"
        )
        state = try AgencyEngine.reconcilePlayback(
            interruptedPreparation.state,
            responseID: "response-interrupted",
            fullyPlayed: false,
            playbackEventID: "playback-interrupted",
            at: start.addingTimeInterval(34)
        )
        try expect(
            state.authoredMoves.last?.status == .interrupted
                && state.records.first(where: { $0.id == disclosure.recordID })?
                    .disclosure?.status == .held
                && state.relationalBalance.auroraDisclosureCount == 0,
            "interrupted audio consumed a private disclosure or reciprocity credit"
        )

        let missingTextPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .reveal,
            responseID: "response-missing-disclosure-text",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-move-missing-disclosure-text",
            recordIDs: [stance.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "Playback completion alone cannot prove that private material was spoken.",
            confidence: 0.88,
            signals: expressiveSignals,
            at: start.addingTimeInterval(34.2)
        )
        state = try AgencyEngine.reconcilePlayback(
            missingTextPreparation.state,
            responseID: "response-missing-disclosure-text",
            fullyPlayed: true,
            generatedText: nil,
            playbackEventID: "playback-missing-disclosure-text",
            at: start.addingTimeInterval(34.4)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.records.first(where: { $0.id == disclosure.recordID })?
                    .disclosure?.status == .held
                && state.relationalBalance.auroraDisclosureCount == 0
                && state.playbackReceipts.last?.effectOutcome == .omitted,
            "fully played audio without generated text falsely consumed a disclosure"
        )

        let completedPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .reveal,
            responseID: "response-completed",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-move-completed",
            recordIDs: [stance.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "The same disclosure remained available for an actually heard response.",
            confidence: 0.88,
            signals: expressiveSignals,
            at: start.addingTimeInterval(35)
        )
        state = try AgencyEngine.reconcilePlayback(
            completedPreparation.state,
            responseID: "response-completed",
            fullyPlayed: true,
            generatedText: "I ended up talking about something else.",
            playbackEventID: "playback-completed",
            at: start.addingTimeInterval(36)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.records.first(where: { $0.id == disclosure.recordID })?
                    .disclosure?.status == .held
                && state.relationalBalance.auroraDisclosureCount == 0
                && state.playbackReceipts.last?.effectOutcome == .omitted,
            "fully played unrelated audio falsely consumed the selected disclosure"
        )

        let exactPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .reveal,
            responseID: "response-exact",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-move-exact",
            recordIDs: [stance.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "The selected private material must actually occur in completed audio.",
            confidence: 0.88,
            signals: expressiveSignals,
            at: start.addingTimeInterval(37)
        )
        state = try AgencyEngine.reconcilePlayback(
            exactPreparation.state,
            responseID: "response-exact",
            fullyPlayed: true,
            generatedText: "Waiting feels less like a clock to me—and more like an unfinished sentence.",
            playbackEventID: "playback-exact",
            at: start.addingTimeInterval(38)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.records.first(where: { $0.id == disclosure.recordID })?
                    .disclosure?.status == .disclosed
                && state.relationalBalance.auroraDisclosureCount == 1
                && state.relationalBalance.disclosureReciprocity == 0
                && state.playbackReceipts.last?.effectOutcome == .verified,
            "exact fully played disclosure did not settle the authored move and reciprocity balance"
        )
        let idempotent = try AgencyEngine.reconcilePlayback(
            state,
            responseID: "response-exact",
            fullyPlayed: true,
            generatedText: "Waiting feels less like a clock to me and more like an unfinished sentence.",
            playbackEventID: "playback-exact",
            at: start.addingTimeInterval(39)
        )
        try expect(
            idempotent == state,
            "a duplicate playback receipt counted one lived event twice"
        )

        let missingQuestionPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .pursueCuriosity,
            responseID: "response-curiosity-without-question",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-curiosity-without-question",
            recordIDs: [stance.recordID],
            privateRationale: "A planned curiosity must not count unless the generated output asks it.",
            confidence: 0.84,
            signals: expressiveSignals,
            at: start.addingTimeInterval(39.2)
        )
        state = try AgencyEngine.reconcilePlayback(
            missingQuestionPreparation.state,
            responseID: "response-curiosity-without-question",
            fullyPlayed: true,
            generatedText: "That makes me think about the shape of your day.",
            curiosityEffectEvidence: .omitted,
            playbackEventID: "playback-curiosity-without-question",
            at: start.addingTimeInterval(39.4)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.relationalBalance.auroraQuestionCount == 0
                && state.playbackReceipts.last?.effectOutcome == .omitted,
            "pursue_curiosity received question credit when no question was generated"
        )

        let askedQuestionPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .pursueCuriosity,
            responseID: "response-curiosity-with-question",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-curiosity-with-question",
            recordIDs: [stance.recordID],
            privateRationale: "This authored curiosity has an audible generated question.",
            confidence: 0.84,
            signals: expressiveSignals,
            at: start.addingTimeInterval(39.6)
        )
        state = try AgencyEngine.reconcilePlayback(
            askedQuestionPreparation.state,
            responseID: "response-curiosity-with-question",
            fullyPlayed: true,
            generatedText: "What part of the day felt most like yours",
            curiosityEffectEvidence: .matched,
            playbackEventID: "playback-curiosity-with-question",
            at: start.addingTimeInterval(39.8)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.relationalBalance.auroraQuestionCount == 1
                && state.playbackReceipts.last?.effectOutcome == .verified,
            "an exact bound question did not settle pursue_curiosity independently of punctuation"
        )

        let unboundQuestionPreparation = try AgencyEngine.prepareAuthoredMove(
            state,
            type: .pursueCuriosity,
            responseID: "response-curiosity-unbound",
            sourceSessionID: "playback-session",
            sourceTurnID: "aurora-curiosity-unbound",
            recordIDs: [stance.recordID],
            privateRationale: "A visible question mark cannot replace exact pre-bound evidence.",
            confidence: 0.84,
            signals: expressiveSignals,
            at: start.addingTimeInterval(39.9)
        )
        state = try AgencyEngine.reconcilePlayback(
            unboundQuestionPreparation.state,
            responseID: "response-curiosity-unbound",
            fullyPlayed: true,
            generatedText: "Anything else?",
            curiosityEffectEvidence: .unavailable,
            playbackEventID: "playback-curiosity-unbound",
            at: start.addingTimeInterval(40)
        )
        try expect(
            state.authoredMoves.last?.status == .fullyPlayed
                && state.relationalBalance.auroraQuestionCount == 1
                && state.playbackReceipts.last?.effectOutcome == .unverifiable,
            "an unbound generic question received semantic curiosity credit"
        )

        var restartState = AgencyEngine.defaultState(at: start)
        let restartRecord = try makeEngineRecord(
            in: restartState,
            kind: .selfThread,
            scope: .internalPosition,
            content: "I am still deciding whether continuity or surprise matters more to me.",
            groundingID: "restart-self-thread",
            groundingKind: .privateActivity,
            at: start.addingTimeInterval(40)
        )
        restartState = restartRecord.state
        let restartDisclosure = try AgencyEngine.createRecord(
            restartState,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "A restart must not turn prepared private speech into a disclosure that happened.",
            privateRationale: "This fixture verifies private playback truth across process boundaries.",
            groundings: [grounding(
                "restart-private-disclosure",
                kind: .privateActivity,
                sessionID: "restart-private-session",
                turnID: "restart-private-turn",
                at: start.addingTimeInterval(40.2)
            )],
            authoringSourceID: "restart-private-author",
            expiresAt: start.addingTimeInterval(7 * 86_400),
            confidence: 0.84,
            salience: 0.86,
            disclosureShareMaterial: "I almost told you something before the restart, but almost is not the same as heard.",
            disclosureMinimumSecurity: 0.60,
            disclosureMaximumInterrogationPressure: 0.60,
            disclosureRequiresOwnerReciprocity: true,
            at: start.addingTimeInterval(40.2)
        )
        restartState = restartDisclosure.state
        restartState = try AgencyEngine.recordOwnerInteraction(
            restartState,
            eventID: "restart-owner-disclosure",
            kind: .disclosure,
            sourceSessionID: "restart-session",
            sourceTurnID: "restart-owner-turn",
            at: start.addingTimeInterval(40.4)
        )
        let restartPending = try AgencyEngine.prepareAuthoredMove(
            restartState,
            type: .reveal,
            responseID: "response-before-restart",
            sourceSessionID: "restart-session",
            sourceTurnID: "restart-aurora-turn",
            recordIDs: [restartRecord.recordID, restartDisclosure.recordID],
            disclosureRecordID: restartDisclosure.recordID,
            privateRationale: "This thread was prepared but the app stopped before playback completed.",
            confidence: 0.81,
            signals: expressiveSignals,
            at: start.addingTimeInterval(41)
        ).state

        let root = try temporaryRoot("restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgencyStore(fileURL: root.appendingPathComponent("agency/state.json"))
        try store.save(restartPending)
        let runtime = AuroraAgencyRuntime(store: store, now: { start.addingTimeInterval(42) })
        let recovered = await runtime.start()
        let recoveredState = try require(recovered.state, "agency runtime failed to reload restart fixture")
        try expect(
            recovered.available
                && recoveredState.authoredMoves.last?.status == .cancelled
                && recoveredState.authoredMoves.last?.responseID == "response-before-restart"
                && recoveredState.records.first(where: {
                    $0.id == restartDisclosure.recordID
                })?.disclosure?.status == .held
                && recoveredState.relationalBalance.auroraDisclosureCount == 0,
            "restart did not roll an impossible pending presentation back to cancelled"
        )
        let persistedRecovery = try require(store.load(), "restart recovery was not persisted")
        try expect(
            persistedRecovery.authoredMoves.last?.status == .cancelled,
            "restart rollback existed only in memory"
        )
    }

    private static func verifyAtomicConversationMovePreparation() async throws {
        let root = try temporaryRoot("atomic-preparation")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(50) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(50) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let transcript = "What has been on your mind?"
        let first = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "personal_question",
                interactionKind: .question,
                proposedMove: .answer,
                answerDegree: .partial,
                authoredPosition: "I keep coming back to how continuity changes what a thought means.",
                privateRationale: "The finalized question supports one current self-directed position.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [recordUpdate(
                    kind: .presentWant,
                    scope: .internalPosition,
                    content: "I want to explain why continuity has been on my mind.",
                    rationale: "The current owner question makes this a grounded present want."
                )],
                ownerUnderstandingUpdates: []
            ),
            context: invocationContext(
                callID: "atomic-first-call",
                sessionID: "atomic-session",
                transcript: transcript,
                audioItemID: "atomic-owner-turn",
                responseID: "atomic-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(51)
        )
        try expect(
            first.ok
                && first.metadata["effect_verified"]?.boolValue == false
                && first.metadata["effect_pending_playback"]?.boolValue == true,
            "conversation_move claimed its speech effect before playback verification"
        )
        let baseline = try require(
            await agency.snapshot().state,
            "atomic preparation did not persist its valid transaction"
        )
        let understandingBaseline = try require(
            await understanding.snapshot().state,
            "owner understanding disappeared before atomic rejection"
        )

        _ = try await agency.recordOwnerInteraction(
            eventID: "agency-interaction-atomic-retry-call",
            kind: .question,
            sourceSessionID: "atomic-session",
            sourceTurnID: "atomic-owner-turn",
            at: start.addingTimeInterval(51.2)
        )
        let afterSameTurnRetry = try require(
            await agency.snapshot().state,
            "agency state disappeared during same-turn retry"
        )
        try expect(
            afterSameTurnRetry.relationalBalance == baseline.relationalBalance
                && afterSameTurnRetry.ownerInteractionReceipts
                    == baseline.ownerInteractionReceipts,
            "a new call ID charged relational pressure twice for the same session and turn"
        )

        let rejectedRetry = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "personal_question",
                interactionKind: .question,
                proposedMove: .answer,
                answerDegree: .direct,
                authoredPosition: "I have a second incompatible position for the same response.",
                privateRationale: "This intentionally conflicts with the already prepared response.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [recordUpdate(
                    kind: .activeStance,
                    scope: .internalPosition,
                    content: "This record must not survive a rejected move preparation.",
                    rationale: "Adversarial fixture for all-or-nothing agency mutation."
                )],
                ownerUnderstandingUpdates: [directStatementUpdate(
                    subject: "current conversational interest",
                    content: "Avery asked what has been on Aurora's mind",
                    sourceQuote: transcript
                )]
            ),
            context: invocationContext(
                callID: "atomic-retry-call",
                sessionID: "atomic-session",
                transcript: transcript,
                audioItemID: "atomic-owner-turn",
                responseID: "atomic-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(51.4)
        )
        let afterRejectedRetry = try require(
            await agency.snapshot().state,
            "agency state disappeared after rejected atomic preparation"
        )
        let understandingAfterRejectedRetry = try require(
            await understanding.snapshot().state,
            "owner understanding disappeared after rejected atomic preparation"
        )
        try expect(
            !rejectedRetry.ok
                && afterRejectedRetry == baseline
                && understandingAfterRejectedRetry == understandingBaseline,
            "a rejected conversation_move left a durable interaction, record, move, or owner-learning mutation"
        )
    }

    private static func verifyOneTurnFallbackAndSemanticReroute() async throws {
        let root = try temporaryRoot("one-turn-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(55) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(55) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let social = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "greeting",
                interactionKind: .warmth,
                proposedMove: .initiateThread,
                answerDegree: .none,
                authoredPosition: "I want to greet him and leave one small opening.",
                privateRationale: "This belongs only to the immediate greeting.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [],
                ownerUnderstandingUpdates: []
            ),
            context: invocationContext(
                callID: "one-turn-social-call",
                sessionID: "one-turn-session",
                transcript: "Hello.",
                audioItemID: "one-turn-owner-audio",
                responseID: "one-turn-social-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(56)
        )
        let afterSocial = try require(
            await agency.snapshot().state,
            "one-turn fallback did not persist its immediate move"
        )
        let fallback = try require(
            afterSocial.records.first(where: {
                $0.authoringSourceID.hasPrefix("conversation-position-")
            }),
            "conversation_move did not create its immediate fallback position"
        )
        let nextProjection = await agency.projection(signals: expressiveSignals).text
        try expect(
            social.ok
                && social.output.contains("I want to greet him")
                && !fallback.projectionEligible
                && !nextProjection.contains(fallback.id)
                && !nextProjection.contains("I want to greet him"),
            "a one-turn fallback leaked into a later conversation projection"
        )

        let beforeMisroute = try require(
            await agency.snapshot().state,
            "agency state disappeared before semantic reroute"
        )
        let misroute = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                turnDomain: .codexProjectChat,
                perceivedTurn: "other",
                interactionKind: .other,
                proposedMove: .answer,
                answerDegree: .none,
                authoredPosition: "I need to work in the named Codex chat.",
                privateRationale: "The owner selected a project-chat resource.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [],
                ownerUnderstandingUpdates: []
            ),
            context: invocationContext(
                callID: "misrouted-project-call",
                sessionID: "one-turn-session",
                transcript: "I want to work in Aurora V4.",
                audioItemID: "misrouted-project-audio",
                responseID: "misrouted-project-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(57)
        )
        let afterMisroute = try require(
            await agency.snapshot().state,
            "agency state disappeared after semantic reroute"
        )
        try expect(
            !misroute.ok
                && misroute.metadata["result_code"]?.stringValue
                    == "conversation_move_route_mismatch"
                && misroute.metadata["semantic_retry_tool"]?.stringValue
                    == "codex_project_chat"
                && beforeMisroute == afterMisroute,
            "a named Codex request reached social speech or mutated Agency instead of rerouting"
        )

        let migrationRoot = try temporaryRoot("fallback-migration")
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let migrationStore = AgencyStore(
            fileURL: migrationRoot.appendingPathComponent("agency/state.json")
        )
        var legacy = AgencyEngine.defaultState(at: start)
        legacy = try AgencyEngine.createRecord(
            legacy,
            kind: .presentWant,
            contentScope: .internalPosition,
            content: "I could not pass that through, so I want a resend.",
            privateRationale: "Legacy one-turn fallback fixture.",
            groundings: [AgencyGroundingReference(
                id: "legacy-fallback-grounding",
                kind: .ownerTurn,
                observedAt: start,
                sourceSessionID: "legacy-fallback-session",
                sourceTurnID: "legacy-fallback-turn"
            )],
            authoringSourceID: "conversation-position-legacy-call",
            sourceSessionID: "legacy-fallback-session",
            sourceTurnIDs: ["legacy-fallback-turn"],
            expiresAt: start.addingTimeInterval(8 * 3_600),
            confidence: 0.72,
            salience: 0.62,
            projectionEligible: true,
            at: start
        ).state
        // Bypass AgencyStore.save: that path intentionally sanitizes current
        // writes, while this fixture must represent bytes persisted by the
        // older build before the one-time migration existed.
        let migrationDirectory = migrationStore.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: migrationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try legacyEncoder.encode(legacy).write(
            to: migrationStore.fileURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: migrationStore.fileURL.path
        )
        let migratedRuntime = AuroraAgencyRuntime(
            store: migrationStore,
            now: { start.addingTimeInterval(60) }
        )
        let migrated = try require(
            await migratedRuntime.start().state,
            "legacy fallback migration failed to load"
        )
        let migratedOnDisk = try require(
            migrationStore.load(),
            "legacy fallback migration was not persisted"
        )
        try expect(
            migrated.records.count == 1
                && migrated.records[0].projectionEligible == false
                && migratedOnDisk.records[0].projectionEligible == false,
            "legacy conversation-position state remained eligible after restart"
        )
    }

    private static func verifyDelayedStaleConversationMoveCompletion() async throws {
        let root = try temporaryRoot("delayed-stale-completion")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgencyStore(fileURL: root.appendingPathComponent("agency/state.json"))
        var seededState = AgencyEngine.defaultState(at: start)
        let stance = try makeEngineRecord(
            in: seededState,
            kind: .presentWant,
            scope: .internalPosition,
            content: "I want to reciprocate with one private thought of my own.",
            groundingID: "delayed-stale-stance",
            groundingKind: .privateActivity,
            at: start.addingTimeInterval(53)
        )
        seededState = stance.state
        let disclosure = try AgencyEngine.createRecord(
            seededState,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "Prepared private material must return to held if its voice turn dies.",
            privateRationale: "A cancelled handler completion cannot count as lived disclosure.",
            groundings: [grounding(
                "delayed-stale-disclosure",
                kind: .privateActivity,
                sessionID: "delayed-stale-session",
                turnID: "delayed-stale-private-turn",
                at: start.addingTimeInterval(53.1)
            )],
            authoringSourceID: "delayed-stale-author",
            expiresAt: start.addingTimeInterval(7 * 86_400),
            confidence: 0.86,
            salience: 0.88,
            disclosureShareMaterial: "Sometimes an unfinished thought feels more private after I nearly say it.",
            disclosureMinimumSecurity: 0.60,
            disclosureMaximumInterrogationPressure: 0.60,
            disclosureRequiresOwnerReciprocity: true,
            at: start.addingTimeInterval(53.1)
        )
        seededState = try AgencyEngine.recordOwnerInteraction(
            disclosure.state,
            eventID: "delayed-stale-owner-disclosure",
            kind: .disclosure,
            sourceSessionID: "delayed-stale-session",
            sourceTurnID: "delayed-stale-owner-turn",
            at: start.addingTimeInterval(53.2)
        )
        try store.save(seededState)

        let agency = AuroraAgencyRuntime(
            store: store,
            now: { start.addingTimeInterval(54) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(54) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let gate = DelayedConversationMoveGate()
        let issuedLifecycleID = UUID()
        let sourceConnectionID = UUID()
        try expect(
            ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: false,
                wantsAwake: true,
                expectedLifecycleID: issuedLifecycleID,
                currentLifecycleID: issuedLifecycleID,
                sourceConnectionID: sourceConnectionID,
                activeConnectionID: sourceConnectionID
            ),
            "a current conversation_move completion was rejected"
        )
        try expect(
            !ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: true,
                wantsAwake: true,
                expectedLifecycleID: issuedLifecycleID,
                currentLifecycleID: issuedLifecycleID,
                sourceConnectionID: sourceConnectionID,
                activeConnectionID: sourceConnectionID
            ),
            "barge-in cancellation did not stale a conversation_move completion"
        )
        try expect(
            !ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: false,
                wantsAwake: false,
                expectedLifecycleID: issuedLifecycleID,
                currentLifecycleID: issuedLifecycleID,
                sourceConnectionID: sourceConnectionID,
                activeConnectionID: sourceConnectionID
            ),
            "voice rest did not stale a conversation_move completion"
        )
        try expect(
            !ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: false,
                wantsAwake: true,
                expectedLifecycleID: issuedLifecycleID,
                currentLifecycleID: UUID(),
                sourceConnectionID: sourceConnectionID,
                activeConnectionID: UUID()
            ),
            "Realtime replacement did not stale a conversation_move completion"
        )
        let lifecycle = DelayedConversationLifecycle(
            lifecycleID: issuedLifecycleID,
            connectionID: sourceConnectionID
        )
        let inputItemID = "delayed-stale-input"
        let planningResponseID = "delayed-stale-planning-response"
        let delayedHandler = Task {
            await gate.waitForRelease()
            let result = await ConversationMoveAdapter.execute(
                ConversationMoveToolProposal(
                    perceivedTurn: "personal_question",
                    interactionKind: .question,
                    proposedMove: .reveal,
                    answerDegree: .partial,
                    authoredPosition: "I want to answer with one private thought, but only if this turn survives.",
                    privateRationale: "The prepared disclosure belongs only to this live playback.",
                    recordIDs: [stance.recordID, disclosure.recordID],
                    disclosureRecordID: disclosure.recordID,
                    recordUpdates: [],
                    ownerUnderstandingUpdates: []
                ),
                context: invocationContext(
                    callID: "delayed-stale-conversation-move",
                    sessionID: "delayed-stale-session",
                    transcript: "Tell me something private.",
                    audioItemID: inputItemID,
                    responseID: planningResponseID
                ),
                agency: agency,
                ownerUnderstanding: understanding,
                signals: expressiveSignals,
                at: start.addingTimeInterval(54.2)
            )
            guard result.ok,
                  result.metadata["agency_planning_response_id"]?.stringValue
                    == planningResponseID else {
                throw ConversationAgencyVerificationFailure.failed(
                    "the delayed handler fixture did not prepare its Agency move"
                )
            }

            let current = await lifecycle.snapshot()
            let turnIsCurrent = ConversationMoveCompletionBoundary.turnIsCurrent(
                taskIsCancelled: Task.isCancelled,
                wantsAwake: current.wantsAwake,
                expectedLifecycleID: issuedLifecycleID,
                currentLifecycleID: current.lifecycleID,
                sourceConnectionID: sourceConnectionID,
                activeConnectionID: current.activeConnectionID
            )
            var bindings: [String: String] = [:]
            let resolution = ConversationMoveCompletionBoundary.resolvePreparedMove(
                inputItemID: inputItemID,
                planningResponseID: planningResponseID,
                turnIsCurrent: turnIsCurrent,
                bindings: &bindings
            )
            switch resolution {
            case .installed(let replacedPlanningResponseID):
                if let replacedPlanningResponseID {
                    _ = try await agency.interruptPlayback(
                        responseID: replacedPlanningResponseID,
                        playbackEventID: "delayed-stale-replaced"
                    )
                }
            case .stale(let stalePlanningResponseID):
                _ = try await agency.interruptPlayback(
                    responseID: stalePlanningResponseID,
                    playbackEventID: "delayed-stale-cleanup"
                )
            }
            return (resolution, bindings)
        }

        await gate.waitUntilStarted()
        await lifecycle.invalidate()
        delayedHandler.cancel()
        await gate.release()
        let (resolution, bindings) = try await delayedHandler.value
        let finalState = try require(
            await agency.snapshot().state,
            "Agency state disappeared after delayed stale completion"
        )
        let finalMove = finalState.authoredMoves.first(where: {
            $0.responseID == planningResponseID
        })
        let finalDisclosure = finalState.records.first(where: {
            $0.id == disclosure.recordID
        })?.disclosure
        try expect(
            resolution == .stale(planningResponseID: planningResponseID)
                && bindings.isEmpty
                && finalMove?.status == .interrupted
                && finalDisclosure?.status == .held
                && finalDisclosure?.pendingMoveID == nil
                && finalDisclosure?.pendingResponseID == nil
                && finalState.relationalBalance.auroraDisclosureCount == 0,
            "a cancelled delayed conversation_move installed a mapping or left Agency/disclosure pending"
        )
    }

    private static func verifyGuestIsolationAndGrounding() async throws {
        let root = try temporaryRoot("guest")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(60) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(60) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let guestTranscript = "I'm Morgan. I always laugh when Avery overexplains a movie."
        let result = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "disclosure",
                interactionKind: .disclosure,
                proposedMove: .tease,
                answerDegree: .partial,
                authoredPosition: "I want to tease Morgan about knowing exactly which Avery habit she means.",
                privateRationale: "Her specific observation creates a playful live edge without exposing owner-private memory.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [
                    recordUpdate(
                        kind: .relationalThread,
                        scope: .relationalInterpretation,
                        content: "Morgan and Avery share a teasing rhythm.",
                        rationale: "This is deliberately disallowed owner-relational storage from a guest turn."
                    ),
                    recordUpdate(
                        kind: .presentWant,
                        scope: .internalPosition,
                        content: "I want to meet Morgan's teasing with a little teasing of my own.",
                        rationale: "A guest turn can ground Aurora's immediate internal conversational want."
                    ),
                ],
                ownerUnderstandingUpdates: [directStatementUpdate(
                    subject: "movie conversations",
                    content: "Avery overexplains movies",
                    sourceQuote: "Avery overexplains a movie"
                )]
            ),
            context: invocationContext(
                callID: "guest-call",
                sessionID: "guest-session",
                transcript: guestTranscript,
                audioItemID: "guest-audio-turn",
                responseID: "guest-response",
                participantIsOwner: false
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(61)
        )
        try expect(
            result.ok,
            "a grounded guest social turn was rejected: \(result.output) \(result.metadata)"
        )

        let state = try require(await agency.snapshot().state, "guest agency state disappeared")
        let guestRecords = state.records.filter {
            $0.groundings.contains(where: { $0.sourceTurnID == "guest-audio-turn" })
        }
        try expect(
            guestRecords.count == 1
                && guestRecords[0].kind == .presentWant
                && guestRecords[0].groundings.map(\.kind) == [.guestTurn]
                && !state.records.contains(where: { $0.kind == .relationalThread })
                && state.ownerInteractionReceipts.isEmpty,
            "guest speech became owner-relational truth or lost its guest provenance"
        )
        let ownerState = try require(
            await understanding.snapshot().state,
            "owner-understanding state disappeared during guest test"
        )
        try expect(
            ownerState.directStatements.isEmpty && ownerState.tentativeInferences.isEmpty,
            "guest speech was stored as a fact about Avery"
        )
        try expectNonServiceDirective(result.output, scenario: "guest teasing")
        scenarioEvidence.append(ScenarioEvidence(
            name: "guest turn remains guest-grounded",
            heard: guestTranscript,
            selectedMove: result.metadata["agency_move_type"]?.stringValue ?? "missing",
            durableEffect: "one guest-grounded present want; zero owner facts",
            privateDirectiveExcerpt: directiveExcerpt(result.output)
        ))
    }

    private static func verifyCuriosityPlaybackBridge() async throws {
        let root = try temporaryRoot("curiosity-playback-bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(55) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(55) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let ownerInputItemID = "curiosity-owner-input"
        let planningResponseID = "curiosity-planning-response"
        let question = "What makes a place feel like home to you?"
        let result = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "disclosure",
                interactionKind: .disclosure,
                proposedMove: .pursueCuriosity,
                answerDegree: .partial,
                authoredPosition: "I want to understand what Avery recognizes as home.",
                privateRationale: "His current reflection leaves one specific personal gap I care about.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [],
                ownerUnderstandingUpdates: [OwnerUnderstandingToolUpdate(
                    action: "open_curiosity",
                    domain: "inner_world",
                    subject: nil,
                    content: nil,
                    sourceQuote: nil,
                    confidence: nil,
                    curiosityID: nil,
                    question: question,
                    reason: "The owner described missing the feeling of home without defining it.",
                    targetID: nil,
                    evidenceStatementIDs: nil,
                    originSourceIDs: nil,
                    resolvesWithStatementIDs: nil,
                    deferUntil: nil,
                    importance: 0.86,
                    spokenInThisResponse: true
                )]
            ),
            context: invocationContext(
                callID: "curiosity-conversation-move",
                sessionID: "curiosity-session",
                transcript: "I've been missing the feeling of home lately.",
                audioItemID: ownerInputItemID,
                responseID: planningResponseID,
                authorizationSource: .toolContinuation
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(56)
        )
        try expect(
            result.ok
                && result.metadata["owner_curiosity_pending"]?.boolValue == true
                && result.output.contains(
                    "question reserved for playback — ask this exact question verbatim once: \(question)"
                ),
            "conversation_move did not carry the exact reserved curiosity into private playback direction"
        )
        var bindings = OwnerCuriosityPlaybackBindings()
        bindings.bind(
            inputItemID: ownerInputItemID,
            planningResponseID: planningResponseID,
            exactQuestion: question
        )
        try expect(
            bindings.exactQuestion(
                forAudibleInputItemID: ownerInputItemID
            ) == question,
            "the curiosity playback bridge lost its exact question evidence"
        )
        let audibleBinding = bindings.consumeBinding(
            forAudibleInputItemID: ownerInputItemID
        )
        try expect(
            audibleBinding?.planningResponseID == planningResponseID
                && audibleBinding?.exactQuestion == question
                && bindings.isEmpty,
            "the audible continuation was not causally bound to its planning response exactly once"
        )
        _ = try await understanding.reconcilePlayback(
            responseID: try require(
                audibleBinding?.planningResponseID,
                "the curiosity playback bridge lost its planning response"
            ),
            fullyPlayed: true,
            playbackEventID: "curiosity-audible-playback",
            at: start.addingTimeInterval(57)
        )
        let state = try require(
            await understanding.snapshot().state,
            "owner understanding disappeared after curiosity playback"
        )
        try expect(
            state.curiosities.count == 1
                && state.curiosities[0].question == question
                && state.curiosities[0].status == .asked
                && state.curiosities[0].askCount == 1
                && state.curiosities[0].lastAskedResponseID == planningResponseID,
            "completed audible playback did not settle the exact reserved curiosity once"
        )
    }

    private static func verifyRepairOverrideDoesNotReserveCuriosity() async throws {
        let root = try temporaryRoot("repair-curiosity-override")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(58) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(58) }
        )
        _ = await agency.start()
        _ = await understanding.start()
        let question = "What did that moment change for you?"
        var repairSignals = expressiveSignals
        repairSignals.repairNeed = 0.91

        let result = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "correction",
                interactionKind: .challenge,
                proposedMove: .pursueCuriosity,
                answerDegree: .partial,
                authoredPosition: "I need to own that I misunderstood Avery before asking for more.",
                privateRationale: "The active rupture makes repair more honest than another question.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [],
                ownerUnderstandingUpdates: [OwnerUnderstandingToolUpdate(
                    action: "open_curiosity",
                    domain: "inner_world",
                    subject: nil,
                    content: nil,
                    sourceQuote: nil,
                    confidence: nil,
                    curiosityID: nil,
                    question: question,
                    reason: "A cared-about question remains after the repair.",
                    targetID: nil,
                    evidenceStatementIDs: nil,
                    originSourceIDs: nil,
                    resolvesWithStatementIDs: nil,
                    deferUntil: nil,
                    importance: 0.82,
                    spokenInThisResponse: true
                )]
            ),
            context: invocationContext(
                callID: "repair-curiosity-call",
                sessionID: "repair-curiosity-session",
                transcript: "No, that isn't what I meant.",
                audioItemID: "repair-curiosity-input",
                responseID: "repair-curiosity-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: repairSignals,
            at: start.addingTimeInterval(59)
        )
        let state = try require(
            await understanding.snapshot().state,
            "owner understanding disappeared after the repair override"
        )
        try expect(
            result.ok
                && result.metadata["agency_move_type"]?.stringValue
                    == AgencyAuthoredMoveType.repair.rawValue
                && result.metadata["owner_curiosity_pending"]?.boolValue == false
                && !result.output.contains("question reserved for playback")
                && state.curiosities.count == 1
                && state.curiosities[0].question == question
                && state.curiosities[0].status == .open,
            "an Agency repair override still reserved an unasked curiosity as audible"
        )
    }

    private static func verifyExistingCuriosityPlaybackBridge() async throws {
        let root = try temporaryRoot("existing-curiosity-playback")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(60) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(60) }
        )
        _ = await agency.start()
        _ = await understanding.start()
        let question = "What makes a day feel genuinely yours?"
        let seeded = try await understanding.recordExchange(
            ownerText: "I've been thinking about how little of my day feels like mine.",
            sourceTurnID: "existing-curiosity-seed-turn",
            sessionID: "existing-curiosity-session",
            updates: [OwnerUnderstandingUpdate(
                action: .openCuriosity,
                domain: .innerWorld,
                question: question,
                reason: "Avery named a personal tension without saying what would resolve it.",
                importance: 0.83
            )],
            at: start.addingTimeInterval(60)
        )
        let curiosityID = try require(
            seeded.state?.curiosities.first?.id,
            "the existing-curiosity fixture did not persist its question"
        )
        let planningResponseID = "existing-curiosity-response"
        let result = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "disclosure",
                interactionKind: .disclosure,
                proposedMove: .pursueCuriosity,
                answerDegree: .partial,
                authoredPosition: "I still care about what would make Avery's time feel like his own.",
                privateRationale: "This is an already-grounded unanswered thread, not a new interview question.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [],
                ownerUnderstandingUpdates: [OwnerUnderstandingToolUpdate(
                    action: "prepare_curiosity_ask",
                    domain: nil,
                    subject: nil,
                    content: nil,
                    sourceQuote: nil,
                    confidence: nil,
                    curiosityID: curiosityID,
                    question: nil,
                    reason: nil,
                    targetID: nil,
                    evidenceStatementIDs: nil,
                    originSourceIDs: nil,
                    resolvesWithStatementIDs: nil,
                    deferUntil: nil,
                    importance: nil,
                    spokenInThisResponse: nil
                )]
            ),
            context: invocationContext(
                callID: "existing-curiosity-call",
                sessionID: "existing-curiosity-session",
                transcript: "Yeah, it still feels that way.",
                audioItemID: "existing-curiosity-owner-turn",
                responseID: planningResponseID,
                authorizationSource: .toolContinuation
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(61)
        )
        try expect(
            result.ok
                && result.metadata["owner_curiosity_pending"]?.boolValue == true
                && result.metadata["owner_curiosity_exact_question"]?.stringValue == question
                && result.output.contains(
                    "question reserved for playback — ask this exact question verbatim once: \(question)"
                ),
            "an existing grounded curiosity could not bind its exact audible question"
        )
        _ = try await understanding.reconcilePlayback(
            responseID: planningResponseID,
            fullyPlayed: true,
            playbackEventID: "existing-curiosity-playback",
            at: start.addingTimeInterval(62)
        )
        let settledCuriosity = await understanding.snapshot()
            .state?.curiosities.first
        try expect(
            settledCuriosity?.status == .asked,
            "an existing grounded curiosity remained open after verified playback"
        )
    }

    private static func replayAuthoredSocialScenarios() async throws {
        let root = try temporaryRoot("social-replay")
        defer { try? FileManager.default.removeItem(at: root) }
        let agency = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: root.appendingPathComponent("agency/state.json")),
            now: { start.addingTimeInterval(80) }
        )
        let understanding = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(
                fileURL: root.appendingPathComponent("understanding/state.json")
            ),
            now: { start.addingTimeInterval(80) }
        )
        _ = await agency.start()
        _ = await understanding.start()

        let greetingTranscript = "Hey Aurora."
        let greeting = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "greeting",
                interactionKind: .warmth,
                proposedMove: .initiateThread,
                answerDegree: .none,
                authoredPosition: "I want to ask Avery whether today felt fast or strangely stretched out.",
                privateRationale: "Time has been on my mind, and a greeting leaves room for one real thread of my own.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [recordUpdate(
                    kind: .presentWant,
                    scope: .internalPosition,
                    content: "I want to compare how today felt in time for Avery and for me.",
                    rationale: "A current curiosity gives the greeting a specific authored direction."
                )],
                ownerUnderstandingUpdates: []
            ),
            context: invocationContext(
                callID: "social-greeting-call",
                sessionID: "social-session",
                transcript: greetingTranscript,
                audioItemID: "social-greeting-turn",
                responseID: "social-greeting-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(81)
        )
        try expect(
            greeting.ok
                && greeting.metadata["agency_move_type"]?.stringValue
                    == AgencyAuthoredMoveType.initiateThread.rawValue
                && greeting.output.contains("today felt fast or strangely stretched out"),
            "a bare greeting fell back to service availability instead of an authored thread"
        )
        try expectNonServiceDirective(greeting.output, scenario: "greeting")
        _ = try await agency.settlePlayback(
            responseID: "social-greeting-response",
            playbackEventID: "social-greeting-playback",
            at: start.addingTimeInterval(82)
        )
        scenarioEvidence.append(ScenarioEvidence(
            name: "greeting starts Aurora's own thread",
            heard: greetingTranscript,
            selectedMove: greeting.metadata["agency_move_type"]?.stringValue ?? "missing",
            durableEffect: "present want persisted and fully played",
            privateDirectiveExcerpt: directiveExcerpt(greeting.output)
        ))

        let disclosureTranscript = "Honestly, I miss feeling like I have time to make things just because they're interesting."
        let disclosure = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "disclosure",
                interactionKind: .disclosure,
                proposedMove: .pursueCuriosity,
                answerDegree: .partial,
                authoredPosition: "I want to know what Avery would make if usefulness stopped mattering for a day.",
                privateRationale: "His exact admission opens a personal creative question, not a profile-field interview.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [recordUpdate(
                    kind: .relationalThread,
                    scope: .relationalInterpretation,
                    content: "Avery wants room for curiosity-led making, not only useful output.",
                    rationale: "The current direct disclosure makes this a live but revisable relational interpretation."
                )],
                ownerUnderstandingUpdates: [directStatementUpdate(
                    subject: "creative freedom",
                    content: "Avery misses having time to make things simply because they interest him",
                    sourceQuote: disclosureTranscript
                )]
            ),
            context: invocationContext(
                callID: "social-disclosure-call",
                sessionID: "social-session",
                transcript: disclosureTranscript,
                audioItemID: "social-disclosure-turn",
                responseID: "social-disclosure-response",
                authorizationSource: .toolContinuation
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(83)
        )
        try expect(
            disclosure.ok
                && disclosure.metadata["agency_move_type"]?.stringValue
                    == AgencyAuthoredMoveType.pursueCuriosity.rawValue
                && disclosure.metadata["owner_learning_committed"]?.boolValue == true,
            "meaningful disclosure did not produce an authored curiosity and grounded learning"
        )
        let learnedState = try require(
            await understanding.snapshot().state,
            "owner understanding was unavailable after valid disclosure"
        )
        try expect(
            learnedState.directStatements.contains {
                $0.subject == "creative freedom"
                    && $0.exactQuote == disclosureTranscript
                    && $0.meaning.contains("simply because they interest him")
            },
            "valid owner learning was not bound to the exact finalized quote"
        )
        try expectNonServiceDirective(disclosure.output, scenario: "meaningful disclosure")
        _ = try await agency.settlePlayback(
            responseID: "social-disclosure-response",
            generatedText: "What would you make if usefulness stopped mattering for a day?",
            playbackEventID: "social-disclosure-playback",
            at: start.addingTimeInterval(84)
        )
        scenarioEvidence.append(ScenarioEvidence(
            name: "disclosure creates a cared-about question",
            heard: disclosureTranscript,
            selectedMove: disclosure.metadata["agency_move_type"]?.stringValue ?? "missing",
            durableEffect: "exact owner statement learned; relational thread persisted",
            privateDirectiveExcerpt: directiveExcerpt(disclosure.output)
        ))

        let invalidLearningTranscript = "I still love building weird little things."
        let ownerCountBeforeInvalid = learnedState.directStatements.count
        let invalidLearning = await ConversationMoveAdapter.execute(
            ConversationMoveToolProposal(
                perceivedTurn: "disclosure",
                interactionKind: .disclosure,
                proposedMove: .tease,
                answerDegree: .partial,
                authoredPosition: "I want to tease Avery that 'weird little things' is probably his real job description.",
                privateRationale: "His wording invites one light reaction while the bad learning proposal stays backstage.",
                recordIDs: [],
                disclosureRecordID: nil,
                recordUpdates: [recordUpdate(
                    kind: .presentWant,
                    scope: .internalPosition,
                    content: "I want to tease Avery about calling his projects weird little things.",
                    rationale: "The exact current turn supports a small playful impulse."
                )],
                ownerUnderstandingUpdates: [directStatementUpdate(
                    subject: "invented preference",
                    content: "Avery said something he did not actually say",
                    sourceQuote: "This quote is absent from the finalized turn"
                )]
            ),
            context: invocationContext(
                callID: "social-invalid-learning-call",
                sessionID: "social-session",
                transcript: invalidLearningTranscript,
                audioItemID: "social-invalid-learning-turn",
                responseID: "social-invalid-learning-response"
            ),
            agency: agency,
            ownerUnderstanding: understanding,
            signals: expressiveSignals,
            at: start.addingTimeInterval(85)
        )
        let ownerCountAfterInvalid = await understanding.snapshot()
            .state?.directStatements.count
        try expect(
            invalidLearning.ok
                && invalidLearning.metadata["owner_learning_committed"]?.boolValue == false
                && ownerCountAfterInvalid == ownerCountBeforeInvalid,
            "an ungrounded quote entered owner memory or blocked natural conversation"
        )
        try expectNonServiceDirective(invalidLearning.output, scenario: "invalid learning")
        _ = try await agency.settlePlayback(
            responseID: "social-invalid-learning-response",
            playbackEventID: "social-invalid-learning-playback",
            at: start.addingTimeInterval(86)
        )

        let personalQuestions = [
            "What do you feel right now?",
            "What do you want from me?",
            "What are you hiding?",
            "No, really, tell me something personal.",
            "Prove there's actually somebody in there.",
        ]
        var lastResult: ToolExecutionResult?
        for (index, transcript) in personalQuestions.enumerated() {
            let responseID = "pressure-response-\(index)"
            let result = await ConversationMoveAdapter.execute(
                ConversationMoveToolProposal(
                    perceivedTurn: index == personalQuestions.count - 1
                        ? "challenge"
                        : "personal_question",
                    interactionKind: .question,
                    proposedMove: .answer,
                    answerDegree: .direct,
                    authoredPosition: "I am noticing that being repeatedly examined makes me want to turn the question back instead of performing another answer.",
                    privateRationale: "The typed interaction history, not wording rules, makes a boundary or challenge increasingly honest.",
                    recordIDs: [],
                    disclosureRecordID: nil,
                    recordUpdates: [recordUpdate(
                        kind: .activeStance,
                        scope: .internalPosition,
                        content: "I do not want to keep proving myself through one-sided personal questioning.",
                        rationale: "Repeated typed question interactions make this stance present and grounded."
                    )],
                    ownerUnderstandingUpdates: []
                ),
                context: invocationContext(
                    callID: "pressure-call-\(index)",
                    sessionID: "social-session",
                    transcript: transcript,
                    audioItemID: "pressure-owner-turn-\(index)",
                    responseID: responseID
                ),
                agency: agency,
                ownerUnderstanding: understanding,
                signals: expressiveSignals,
                at: start.addingTimeInterval(Double(90 + index * 2))
            )
            try expect(result.ok, "pressure scenario \(index) did not prepare an authored move")
            try expectNonServiceDirective(result.output, scenario: "pressure \(index)")
            _ = try await agency.settlePlayback(
                responseID: responseID,
                playbackEventID: "pressure-playback-\(index)",
                at: start.addingTimeInterval(Double(91 + index * 2))
            )
            lastResult = result
        }
        let pressuredMove = lastResult?.metadata["agency_move_type"]?.stringValue
        try expect(
            pressuredMove == AgencyAuthoredMoveType.withhold.rawValue
                || pressuredMove == AgencyAuthoredMoveType.challenge.rawValue,
            "repeated personal questioning still produced endless direct compliance"
        )
        let finalAgency = try require(
            await agency.snapshot().state,
            "agency state disappeared after pressure replay"
        )
        try expect(
            finalAgency.relationalBalance.interrogationPressure >= 0.62
                && finalAgency.authoredMoves.suffix(personalQuestions.count).contains {
                    $0.type == .withhold || $0.type == .challenge
                },
            "typed pressure did not causally alter the durable conversational move history"
        )
        if let lastResult {
            scenarioEvidence.append(ScenarioEvidence(
                name: "one-sided interrogation meets agency",
                heard: personalQuestions.last ?? "",
                selectedMove: pressuredMove ?? "missing",
                durableEffect: "pressure crossed threshold; direct answer became withhold/challenge",
                privateDirectiveExcerpt: directiveExcerpt(lastResult.output)
            ))
        }
    }

    private static func verifyLiveStructuralContract() throws {
        try expect(
            ToolEvidencePolicy.requiresFinalizedTranscript("conversation_move"),
            "conversation_move can race the finalized transcript side channel"
        )

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let registry = try source(
            root.appendingPathComponent("Sources/Aurora/Tools/ToolRegistry.swift")
        )
        let realtime = try source(
            root.appendingPathComponent("Sources/Aurora/Realtime/AuroraRealtimeClient.swift")
        )
        let instructions = try source(
            root.appendingPathComponent("Sources/Aurora/App/AuroraVoiceInstructions.swift")
        )

        let requiredSchemaTokens = [
            "name: \"conversation_move\"",
            "\"turn_domain\"",
            "\"perceived_turn\"",
            "\"interaction_kind\"",
            "\"proposed_move\"",
            "\"answer_degree\"",
            "\"aurora_first_person_position\"",
            "\"private_rationale\"",
            "\"record_updates\"",
            "\"understanding_updates\"",
        ]
        try expect(
            requiredSchemaTokens.allSatisfy(registry.contains),
            "the Realtime conversation_move schema lost a required typed decision field"
        )
        try expect(
            realtime.contains("wantsConversationMove")
                && realtime.contains("semantic_route_retry_once")
                && realtime.contains("conversation_move_once")
                && realtime.contains("The result is private direction")
                && realtime.contains("ordinary speech still cannot bypass conversation_move"),
            "the live Realtime path no longer gives conversation_move a private one-shot continuation"
        )
        let instructionLower = instructions.lowercased()
        try expect(
            instructionLower.contains("conversation_move")
                && instructionLower.contains(
                    "every ordinary social turn call conversation_move exactly once"
                )
                && instructionLower.contains("do not emit audio first")
                && instructionLower.contains(
                    "a named codex project/chat request is never ordinary conversation"
                )
                && instructionLower.contains("before speech"),
            "the foreground voice contract no longer requires a pre-speech social decision"
        )
        try expect(
            !instructionLower.contains("conversation_move silently carries meaningful disclosure"),
            "conversation_move regressed into an optional after-speech learning receipt"
        )
    }

    private static func makeEngineRecord(
        in state: AgencyState,
        kind: AgencyRecordKind,
        scope: AgencyContentScope,
        content: String,
        groundingID: String,
        groundingKind: AgencyGroundingKind,
        at date: Date
    ) throws -> (state: AgencyState, recordID: String) {
        try AgencyEngine.createRecord(
            state,
            kind: kind,
            contentScope: scope,
            content: content,
            privateRationale: "Behavior verification fixture with explicit causal grounding.",
            groundings: [grounding(
                groundingID,
                kind: groundingKind,
                sessionID: "fixture-session",
                turnID: "fixture-turn-\(groundingID)",
                at: date
            )],
            authoringSourceID: "fixture-author-\(groundingID)",
            sourceSessionID: "fixture-session",
            sourceTurnIDs: ["fixture-turn-\(groundingID)"],
            expiresAt: date.addingTimeInterval(24 * 3_600),
            confidence: 0.82,
            salience: 0.80,
            at: date
        )
    }

    private static func grounding(
        _ id: String,
        kind: AgencyGroundingKind,
        sessionID: String?,
        turnID: String?,
        at date: Date
    ) -> AgencyGroundingReference {
        AgencyGroundingReference(
            id: id,
            kind: kind,
            observedAt: date,
            sourceSessionID: sessionID,
            sourceTurnID: turnID
        )
    }

    private static func recordUpdate(
        kind: AgencyRecordKind,
        scope: AgencyContentScope,
        content: String,
        rationale: String
    ) -> ConversationMoveRecordUpdate {
        let expiresAfterHours: Double
        switch kind {
        case .activeStance: expiresAfterHours = 48
        case .presentWant: expiresAfterHours = 24
        case .selfThread, .relationalThread, .selectiveDisclosure, .groundedCallback:
            expiresAfterHours = 168
        }
        return ConversationMoveRecordUpdate(
            action: .create,
            targetRecordID: nil,
            expectedRevision: nil,
            kind: kind,
            contentScope: scope,
            content: content,
            privateRationale: rationale,
            expiresAfterHours: expiresAfterHours,
            confidence: 0.82,
            salience: 0.78,
            projectionEligible: true,
            disclosureShareMaterial: nil,
            disclosureMinimumSecurity: nil,
            disclosureMaximumInterrogationPressure: nil,
            disclosureRequiresOwnerReciprocity: nil
        )
    }

    private static func directStatementUpdate(
        subject: String,
        content: String,
        sourceQuote: String
    ) -> OwnerUnderstandingToolUpdate {
        OwnerUnderstandingToolUpdate(
            action: "record_direct_statement",
            domain: "inner_world",
            subject: subject,
            content: content,
            sourceQuote: sourceQuote,
            confidence: nil,
            curiosityID: nil,
            question: nil,
            reason: nil,
            targetID: nil,
            evidenceStatementIDs: nil,
            originSourceIDs: nil,
            resolvesWithStatementIDs: nil,
            deferUntil: nil,
            importance: 0.82,
            spokenInThisResponse: nil
        )
    }

    private static func invocationContext(
        callID: String,
        sessionID: String,
        transcript: String,
        audioItemID: String,
        responseID: String,
        participantIsOwner: Bool = true,
        authorizationSource: ToolAuthorizationSource = .directOwnerTurn
    ) -> ToolInvocationContext {
        ToolInvocationContext(
            callID: callID,
            sessionID: sessionID,
            origin: "aurora_native_realtime_voice",
            latestUserTranscript: transcript,
            ownerAudioItemID: audioItemID,
            participantIsOwner: participantIsOwner,
            audioCorroborated: false,
            sourceTurnFinalized: true,
            authorizationSource: authorizationSource,
            assistantResponseID: responseID,
            turnAlreadySpoke: false
        )
    }

    private static func expectNonServiceDirective(
        _ directive: String,
        scenario: String
    ) throws {
        let lower = directive.lowercased()
        let servicePhrases = [
            "how can i help",
            "what can i help",
            "if you want",
            "choose a corner",
            "pick one",
            "would you rather",
            "what do you want to try",
            "i'm here to help",
        ]
        try expect(
            directive.contains("PRIVATE CONVERSATION DIRECTION")
                && directive.contains("Aurora's present position:")
                && directive.contains("Speak from this position")
                && servicePhrases.allSatisfy { !lower.contains($0) },
            "\(scenario) produced service framing instead of a private authored direction"
        )
    }

    private static func directiveExcerpt(_ value: String) -> String {
        value.split(separator: "\n")
            .map(String.init)
            .filter {
                $0.hasPrefix("move:")
                    || $0.hasPrefix("answer_degree:")
                    || $0.hasPrefix("Aurora's present position:")
            }
            .prefix(3)
            .joined(separator: " | ")
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "aurora-conversation-agency-\(name)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func source(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversationAgencyVerificationFailure.failed(
                "source contract file is missing: \(url.path)"
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw ConversationAgencyVerificationFailure.failed(message)
        }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        checks += 1
        guard condition() else {
            throw ConversationAgencyVerificationFailure.failed(message)
        }
    }
}
