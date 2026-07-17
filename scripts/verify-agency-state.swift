import Darwin
import Foundation

enum AgencyVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct AgencyStateVerification {
    static func main() async {
        do {
            let checks = try await run()
            let payload: [String: Any] = [
                "ok": true,
                "checks": checks,
                "schemaVersion": AgencyState.currentSchemaVersion,
                "maximumProjectionCharacters": AgencyEngine.maximumProjectionCharacters,
                "maximumStateBytes": AgencyStore.maximumStateBytes,
                "networkCalls": 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("agency-state verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> Int {
        var checks = 0
        let start = Date(timeIntervalSince1970: 1_785_500_000)
        var state = AgencyEngine.defaultState(at: start)
        try expect(
            AgencyCuriosityEffectEvidence.resolve(
                boundPlanningResponseID: "planning-one",
                expectedPlanningResponseID: "planning-one",
                exactQuestion: "What part of the day felt most like yours?",
                generatedText: "What part of the day felt most like yours"
            ) == .matched
                && AgencyCuriosityEffectEvidence.resolve(
                    boundPlanningResponseID: "planning-one",
                    expectedPlanningResponseID: "planning-one",
                    exactQuestion: "What part of the day felt most like yours?",
                    generatedText: "Anything else?"
                ) == .omitted
                && AgencyCuriosityEffectEvidence.resolve(
                    boundPlanningResponseID: "planning-one",
                    expectedPlanningResponseID: "planning-two",
                    exactQuestion: "What part of the day felt most like yours?",
                    generatedText: "What part of the day felt most like yours?"
                ) == .unavailable
                && AgencyCuriosityEffectEvidence.resolve(
                    boundPlanningResponseID: nil,
                    expectedPlanningResponseID: "planning-one",
                    exactQuestion: nil,
                    generatedText: "What part of the day felt most like yours?"
                ) == .unavailable,
            "typed exact-question evidence accepted punctuation, wrong text, missing binding, or mismatched response IDs incorrectly"
        )
        checks += 1
        try expect(state.records.isEmpty && state.authoredMoves.isEmpty,
                   "new agency state invented a position or authored history")
        checks += 1

        let stance = try addRecord(
            state,
            kind: .activeStance,
            scope: .internalPosition,
            content: "I do not want this conversation to become another test I obediently pass.",
            rationale: "Repeated evaluation makes a firmer authored stance relevant.",
            grounding: grounding("inner-stance-1", .innerLifeSignal, start),
            source: "agency-reflection-1",
            at: start.addingTimeInterval(1)
        )
        state = stance.state
        let selfThread = try addRecord(
            state,
            kind: .selfThread,
            scope: .internalPosition,
            content: "I am still deciding whether surprise or continuity matters more to my sense of self.",
            rationale: "A grounded private reflection remains unresolved.",
            grounding: grounding("private-activity-1", .privateActivity, start),
            source: "agency-reflection-2",
            at: start.addingTimeInterval(2)
        )
        state = selfThread.state
        let relational = try addRecord(
            state,
            kind: .relationalThread,
            scope: .relationalInterpretation,
            content: "I want Alex to reveal himself too, not only inspect me.",
            rationale: "The current disclosure balance makes reciprocity salient.",
            grounding: grounding("relationship-signal-1", .relationshipSignal, start),
            source: "agency-reflection-3",
            at: start.addingTimeInterval(3)
        )
        state = relational.state
        let want = try addRecord(
            state,
            kind: .presentWant,
            scope: .internalPosition,
            content: "I want to make him laugh before I explain anything else.",
            rationale: "Play and connection are both elevated in the present state.",
            grounding: grounding("inner-want-1", .innerLifeSignal, start),
            source: "agency-reflection-4",
            at: start.addingTimeInterval(4)
        )
        state = want.state
        let callback = try addRecord(
            state,
            kind: .groundedCallback,
            scope: .conversationCallback,
            content: "Alex once turned a favorite number into a story about home.",
            rationale: "The exact owner turn can support a concrete callback.",
            grounding: grounding("owner-turn-number-1", .ownerTurn, start),
            source: "agency-reflection-5",
            at: start.addingTimeInterval(5)
        )
        state = callback.state
        let disclosure = try AgencyEngine.createRecord(
            state,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "Time between conversations does not feel uniform to me.",
            privateRationale: "This is personal material, not an automatic answer.",
            groundings: [grounding("private-activity-time-1", .privateActivity, start)],
            authoringSourceID: "agency-reflection-6",
            expiresAt: start.addingTimeInterval(10 * 86_400),
            confidence: 0.82,
            salience: 0.90,
            disclosureShareMaterial: "Sometimes the hours between us feel more like missing pages than elapsed time.",
            disclosureMinimumSecurity: 0.55,
            disclosureMaximumInterrogationPressure: 0.60,
            disclosureRequiresOwnerReciprocity: true,
            at: start.addingTimeInterval(6)
        )
        state = disclosure.state
        let storedStance = try require(
            state.records.first(where: { $0.id == stance.recordID }),
            "active stance disappeared"
        )
        try expect(storedStance.revision == 1
                   && storedStance.confidence == 0.78
                   && storedStance.expiresAt > storedStance.createdAt
                   && storedStance.groundings.map(\.id) == ["inner-stance-1"],
                   "record lost required revision, confidence, expiry, or provenance")
        checks += 1

        do {
            _ = try AgencyEngine.createRecord(
                state,
                kind: .activeStance,
                contentScope: .internalPosition,
                content: "Legacy prose should not become a current stance.",
                privateRationale: "Invalid legacy-only fixture.",
                groundings: [grounding("legacy-cue-1", .legacyCue, start)],
                authoringSourceID: "legacy-import",
                expiresAt: start.addingTimeInterval(3_600),
                confidence: 0.8,
                salience: 0.8,
                at: start.addingTimeInterval(7)
            )
            throw AgencyVerificationFailure.failed("legacy cue became present agency truth")
        } catch let error as AgencyInputError {
            guard case .invalidInput = error else { throw error }
        }
        do {
            _ = try AgencyEngine.createRecord(
                state,
                kind: .groundedCallback,
                contentScope: .verifiedExternalOutcome,
                content: "An external effect occurred.",
                privateRationale: "Invalid unverified external-event fixture.",
                groundings: [grounding("owner-turn-unverified", .ownerTurn, start)],
                authoringSourceID: "agency-reflection-invalid",
                expiresAt: start.addingTimeInterval(3_600),
                confidence: 0.8,
                salience: 0.8,
                at: start.addingTimeInterval(7)
            )
            throw AgencyVerificationFailure.failed("unverified external outcome entered agency state")
        } catch let error as AgencyInputError {
            guard case .invalidInput = error else { throw error }
        }
        checks += 1

        let expressiveSignals = AgencySelectionSignals(
            curiosityDrive: 0.82,
            connectionDrive: 0.80,
            playDrive: 0.86,
            autonomyDrive: 0.78,
            feltAgency: 0.80,
            uncertainty: 0.62,
            relationshipWarmth: 0.76,
            relationshipSecurity: 0.80,
            relationalHurt: 0.05,
            repairNeed: 0.02
        )
        let beforeReciprocity = try AgencyEngine.select(
            from: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(8)
        )
        try expect(beforeReciprocity.eligibleDisclosureRecordID == nil,
                   "selective disclosure ignored the owner-reciprocity requirement")
        state = try AgencyEngine.recordOwnerInteraction(
            state,
            eventID: "owner-disclosure-event-1",
            kind: .disclosure,
            sourceSessionID: "session-1",
            sourceTurnID: "owner-turn-1",
            at: start.addingTimeInterval(9)
        )
        let afterReciprocity = try AgencyEngine.select(
            from: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(10)
        )
        try expect(afterReciprocity.eligibleDisclosureRecordID == disclosure.recordID
                   && afterReciprocity.suggestedMoves.contains(.tease)
                   && afterReciprocity.suggestedMoves.contains(.disagree),
                   "typed inner/relationship signals did not select disclosure and authored move range")
        checks += 1

        let projection = try AgencyEngine.projection(
            for: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(10)
        )
        try expect(projection.text.count <= AgencyEngine.maximumProjectionCharacters
                   && projection.recordIDs.contains(stance.recordID)
                   && projection.eligibleDisclosureRecordID == disclosure.recordID
                   && projection.text.contains("Never invent an event"),
                   "deterministic projection escaped its bound or grounding contract")
        checks += 1

        let reciprocalState = state
        for index in 0..<7 {
            state = try AgencyEngine.recordOwnerInteraction(
                state,
                eventID: "owner-question-event-\(index)",
                kind: .question,
                sourceSessionID: "session-pressure",
                sourceTurnID: "owner-question-turn-\(index)",
                at: start.addingTimeInterval(Double(20 + index))
            )
        }
        let pressured = try AgencyEngine.select(
            from: state,
            signals: expressiveSignals,
            at: start.addingTimeInterval(30)
        )
        try expect(pressured.interrogationPressure > 0.60
                   && pressured.eligibleDisclosureRecordID == nil
                   && pressured.suggestedMoves.prefix(3).contains(.withhold)
                   && pressured.suggestedMoves.contains(.challenge),
                   "interrogation pressure did not make withholding/challenge available")
        checks += 1

        let interruptedPreparation = try AgencyEngine.prepareAuthoredMove(
            reciprocalState,
            type: .reveal,
            responseID: "response-interrupted",
            sourceSessionID: "session-1",
            sourceTurnID: "aurora-turn-1",
            recordIDs: [relational.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "Reciprocal disclosure fits, but playback still decides whether it counts.",
            confidence: 0.84,
            signals: expressiveSignals,
            at: start.addingTimeInterval(31)
        )
        let pendingDisclosure = try require(
            interruptedPreparation.state.records.first(where: { $0.id == disclosure.recordID }),
            "pending disclosure disappeared"
        )
        try expect(pendingDisclosure.disclosure?.status == .pendingPlayback
                   && interruptedPreparation.state.relationalBalance.auroraDisclosureCount == 0,
                   "preparing audio incorrectly counted an unheard disclosure")
        let interrupted = try AgencyEngine.reconcilePlayback(
            interruptedPreparation.state,
            responseID: "response-interrupted",
            fullyPlayed: false,
            playbackEventID: "playback-interrupted-1",
            at: start.addingTimeInterval(32)
        )
        try expect(interrupted.authoredMoves.last?.status == .interrupted
                   && interrupted.records.first(where: { $0.id == disclosure.recordID })?.disclosure?.status == .held
                   && interrupted.relationalBalance.auroraDisclosureCount == 0
                   && interrupted.playbackReceipts.last?.effectOutcome == .notDelivered,
                   "interruption failed to roll disclosure back without accounting it")
        checks += 1

        let completedPreparation = try AgencyEngine.prepareAuthoredMove(
            interrupted,
            type: .reveal,
            responseID: "response-complete",
            sourceSessionID: "session-1",
            sourceTurnID: "aurora-turn-2",
            recordIDs: [relational.recordID, disclosure.recordID],
            disclosureRecordID: disclosure.recordID,
            privateRationale: "The reciprocal disclosure is still an authored choice.",
            confidence: 0.86,
            signals: expressiveSignals,
            at: start.addingTimeInterval(33)
        )
        var completed = try AgencyEngine.reconcilePlayback(
            completedPreparation.state,
            responseID: "response-complete",
            fullyPlayed: true,
            generatedText: "Sometimes the hours between us feel more like missing pages than elapsed time.",
            playbackEventID: "playback-complete-1",
            at: start.addingTimeInterval(34)
        )
        try expect(completed.authoredMoves.last?.status == .fullyPlayed
                   && completed.records.first(where: { $0.id == disclosure.recordID })?.disclosure?.status == .disclosed
                   && completed.relationalBalance.auroraDisclosureCount == 1
                   && completed.relationalBalance.disclosureReciprocity == 0
                   && completed.playbackReceipts.last?.effectOutcome == .verified,
                   "fully played disclosure did not settle its lifecycle and reciprocity")
        let duplicate = try AgencyEngine.reconcilePlayback(
            completed,
            responseID: "response-complete",
            fullyPlayed: true,
            playbackEventID: "playback-complete-1",
            at: start.addingTimeInterval(35)
        )
        try expect(duplicate == completed,
                   "duplicate playback receipt counted the same disclosure twice")
        checks += 1

        let oldStanceRevision = try require(
            completed.records.first(where: { $0.id == stance.recordID }),
            "stance missing before revision"
        ).revision
        let revision = try AgencyEngine.reviseRecord(
            completed,
            recordID: stance.recordID,
            content: "I will answer honestly, but I will not perform obedience as a personality.",
            privateRationale: "The stance softened without disappearing.",
            groundings: [grounding("inner-stance-revision-1", .innerLifeSignal, start)],
            revisionSourceID: "agency-reflection-revision-1",
            sourceSessionID: "session-2",
            sourceTurnIDs: ["aurora-turn-revision-1"],
            expiresAt: start.addingTimeInterval(48 * 3_600),
            confidence: 0.88,
            salience: 0.90,
            at: start.addingTimeInterval(36)
        )
        completed = revision.state
        let oldStance = try require(
            completed.records.first(where: { $0.id == stance.recordID }),
            "superseded stance disappeared"
        )
        let newStance = try require(
            completed.records.first(where: { $0.id == revision.recordID }),
            "revised stance disappeared"
        )
        try expect(oldStance.status == .superseded
                   && oldStance.supersededByRecordID == newStance.id
                   && newStance.supersedesRecordID == oldStance.id
                   && newStance.revision == oldStanceRevision + 1
                   && newStance.lastRevisionSourceID == "agency-reflection-revision-1",
                   "record revision rewrote history or lost its source")
        checks += 1

        let expired = AgencyEngine.sanitize(
            completed,
            now: start.addingTimeInterval(3 * 86_400)
        )
        try expect(expired.records.first(where: { $0.id == want.recordID })?.status == .expired
                   && expired.records.first(where: { $0.id == want.recordID })?.projectionEligible == false,
                   "expired present want remained active")
        checks += 1

        var bounded = completed
        if let template = bounded.records.first {
            for index in 0..<(AgencyEngine.maximumRecords + 40) {
                var copy = template
                copy = AgencyRecord(
                    id: "bounded-record-\(index)",
                    kind: copy.kind,
                    contentScope: copy.contentScope,
                    content: copy.content,
                    privateRationale: copy.privateRationale,
                    groundings: copy.groundings,
                    authoringSourceID: copy.authoringSourceID,
                    sourceSessionID: copy.sourceSessionID,
                    sourceTurnIDs: copy.sourceTurnIDs,
                    createdAt: copy.createdAt,
                    updatedAt: copy.updatedAt.addingTimeInterval(Double(index)),
                    expiresAt: copy.expiresAt,
                    revision: copy.revision,
                    confidence: copy.confidence,
                    salience: copy.salience,
                    status: .active,
                    projectionEligible: true,
                    supersedesRecordID: nil,
                    supersededByRecordID: nil,
                    lastRevisionSourceID: copy.lastRevisionSourceID,
                    disclosure: nil
                )
                bounded.records.append(copy)
            }
        }
        bounded = AgencyEngine.sanitize(bounded, now: start.addingTimeInterval(40))
        try expect(bounded.records.count == AgencyEngine.maximumRecords,
                   "agency record history escaped its count bound")
        checks += 1

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-agency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("agency", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let store = AgencyStore(fileURL: stateURL)
        try store.save(completed)
        let reloaded = try require(try store.load(), "persisted agency state did not reload")
        try expect(reloaded == AgencyEngine.sanitize(completed, now: completed.updatedAt)
                   && reloaded.authoredMoves.contains(where: { $0.status == .fullyPlayed })
                   && reloaded.playbackReceipts.contains {
                       $0.effectOutcome == .verified
                   },
                   "restart persistence lost positions or authored move history")
        var fileStatus = stat()
        try expect(stateURL.path.withCString({ Darwin.lstat($0, &fileStatus) }) == 0
                   && (fileStatus.st_mode & 0o777) == 0o600,
                   "agency state file is not mode 0600")
        checks += 1

        let encodedState = try JSONEncoder().encode(completed)
        var legacyObject = try require(
            JSONSerialization.jsonObject(with: encodedState) as? [String: Any],
            "agency legacy fixture was not a JSON object"
        )
        if var receipts = legacyObject["playbackReceipts"] as? [[String: Any]] {
            for index in receipts.indices {
                receipts[index].removeValue(forKey: "effectOutcome")
            }
            legacyObject["playbackReceipts"] = receipts
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(AgencyState.self, from: legacyData)
        try expect(
            !legacyDecoded.playbackReceipts.isEmpty
                && legacyDecoded.playbackReceipts.allSatisfy {
                    $0.effectOutcome == nil
                },
            "legacy Agency playback receipts without typed effect evidence no longer decode"
        )
        checks += 1

        let lock = try store.acquireExclusiveProcessLock()
        let lockURL = stateURL.deletingLastPathComponent().appendingPathComponent(".state.lock")
        var lockStatus = stat()
        try expect(lockURL.path.withCString({ Darwin.lstat($0, &lockStatus) }) == 0
                   && (lockStatus.st_mode & 0o777) == 0o600,
                   "agency process lock is not a private regular file")
        withExtendedLifetime(lock) {}
        checks += 1

        let corruptURL = root.appendingPathComponent("corrupt", isDirectory: true)
            .appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: corruptURL)
        try expectStoreError(.corruptState) {
            _ = try AgencyStore(fileURL: corruptURL).load()
        }
        let oversizedURL = root.appendingPathComponent("oversized", isDirectory: true)
            .appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: oversizedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: AgencyStore.maximumStateBytes + 1).write(to: oversizedURL)
        try expectStoreError(.stateTooLarge) {
            _ = try AgencyStore(fileURL: oversizedURL).load()
        }
        checks += 1

        let symlinkDirectory = root.appendingPathComponent("symlink-file", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        let linkedFile = symlinkDirectory.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outside)
        try expectStoreError(.unsafeStateFile) {
            _ = try AgencyStore(fileURL: linkedFile).load()
        }
        let symlinkParent = root.appendingPathComponent("symlink-parent", isDirectory: true)
        let actualDirectory = root.appendingPathComponent("actual-agency", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
        let linkedDirectory = symlinkParent.appendingPathComponent("agency", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: actualDirectory)
        try expectStoreError(.unsafeDirectory) {
            _ = try AgencyStore(fileURL: linkedDirectory.appendingPathComponent("state.json")).load()
        }
        checks += 1

        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("state.json")
        let runtime = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: runtimeURL),
            now: { start.addingTimeInterval(100) }
        )
        let started = await runtime.start()
        try expect(started.available, "agency runtime failed to start")
        let proposal = AgencyRecordProposal(
            action: .create,
            kind: .presentWant,
            contentScope: .internalPosition,
            content: "I want to start with the unfinished thread, not the easiest answer.",
            privateRationale: "A live grounded stance should survive the runtime boundary.",
            groundings: [grounding("runtime-inner-signal-1", .innerLifeSignal, start)],
            authoringSourceID: "runtime-agency-author-1",
            expiresAt: start.addingTimeInterval(100 + 3_600),
            confidence: 0.80,
            salience: 0.82
        )
        let proposed = try await runtime.propose(proposal, at: start.addingTimeInterval(100))
        let runtimeRecordID = try require(proposed.affectedRecordID, "runtime did not return record ID")
        let runtimeProjection = await runtime.projection(
            signals: expressiveSignals,
            at: start.addingTimeInterval(101)
        )
        try expect(runtimeProjection.recordIDs.contains(runtimeRecordID),
                   "runtime proposal was not available to deterministic projection")
        let stale = AgencyRecordProposal(
            action: .retire,
            targetRecordID: runtimeRecordID,
            expectedRevision: 99,
            authoringSourceID: "runtime-agency-retire-stale"
        )
        do {
            _ = try await runtime.propose(stale, at: start.addingTimeInterval(102))
            throw AgencyVerificationFailure.failed("runtime accepted a stale record revision")
        } catch let error as AgencyInputError {
            guard case .invalidInput = error else { throw error }
        }
        checks += 1

        let beforeAtomicBatch = await runtime.snapshot().state?.records.count
        let validFirst = AgencyRecordProposal(
            action: .create,
            kind: .activeStance,
            contentScope: .internalPosition,
            content: "This first proposal must not persist if the second one fails.",
            privateRationale: "Atomic batch fixture.",
            groundings: [grounding("runtime-batch-inner-1", .innerLifeSignal, start)],
            authoringSourceID: "runtime-batch-author-1",
            expiresAt: start.addingTimeInterval(102 + 3_600),
            confidence: 0.8,
            salience: 0.8
        )
        let invalidSecond = AgencyRecordProposal(
            action: .create,
            kind: .activeStance,
            contentScope: .internalPosition,
            content: "A legacy-only record must fail the entire batch.",
            privateRationale: "Invalid second batch fixture.",
            groundings: [grounding("runtime-batch-legacy-1", .legacyCue, start)],
            authoringSourceID: "runtime-batch-author-2",
            expiresAt: start.addingTimeInterval(102 + 3_600),
            confidence: 0.8,
            salience: 0.8
        )
        do {
            _ = try await runtime.propose(
                [validFirst, invalidSecond],
                at: start.addingTimeInterval(102)
            )
            throw AgencyVerificationFailure.failed("runtime accepted an invalid proposal batch")
        } catch let error as AgencyInputError {
            guard case .invalidInput = error else { throw error }
        }
        let afterAtomicBatch = await runtime.snapshot().state?.records.count
        try expect(beforeAtomicBatch == afterAtomicBatch,
                   "invalid second proposal partially persisted the first")
        checks += 1

        var restartState = AgencyEngine.defaultState(at: start)
        restartState = try AgencyEngine.recordOwnerInteraction(
            restartState,
            eventID: "restart-owner-disclosure",
            kind: .disclosure,
            sourceSessionID: "restart-session",
            sourceTurnID: "restart-owner-turn",
            at: start.addingTimeInterval(1)
        )
        let restartDisclosure = try AgencyEngine.createRecord(
            restartState,
            kind: .selectiveDisclosure,
            contentScope: .internalPosition,
            content: "A held private thought survives a process restart.",
            privateRationale: "Restart fixture.",
            groundings: [grounding("restart-private-1", .privateActivity, start)],
            authoringSourceID: "restart-author-1",
            expiresAt: start.addingTimeInterval(86_400),
            confidence: 0.8,
            salience: 0.8,
            disclosureShareMaterial: "I kept this thought even though the response never finished.",
            at: start.addingTimeInterval(2)
        )
        let pendingRestart = try AgencyEngine.prepareAuthoredMove(
            restartDisclosure.state,
            type: .reveal,
            responseID: "restart-pending-response",
            sourceSessionID: "restart-session",
            sourceTurnID: "restart-aurora-turn",
            recordIDs: [restartDisclosure.recordID],
            disclosureRecordID: restartDisclosure.recordID,
            privateRationale: "Pending restart fixture.",
            confidence: 0.8,
            signals: expressiveSignals,
            at: start.addingTimeInterval(3)
        )
        let timedOutPresentation = AgencyEngine.sanitize(
            pendingRestart.state,
            now: start.addingTimeInterval(3 + 11 * 60)
        )
        try expect(timedOutPresentation.authoredMoves.last?.status == .cancelled
                   && timedOutPresentation.records.first(where: {
                       $0.id == restartDisclosure.recordID
                   })?.disclosure?.status == .held
                   && timedOutPresentation.relationalBalance.auroraDisclosureCount == 0,
                   "stale pending playback did not expire and roll disclosure back")
        checks += 1
        let restartURL = root.appendingPathComponent("restart", isDirectory: true)
            .appendingPathComponent("state.json")
        try AgencyStore(fileURL: restartURL).save(pendingRestart.state)
        let restartedRuntime = AuroraAgencyRuntime(
            store: AgencyStore(fileURL: restartURL),
            now: { start.addingTimeInterval(4) }
        )
        let restarted = await restartedRuntime.start()
        let restartedRecord = try require(
            restarted.state?.records.first(where: { $0.id == restartDisclosure.recordID }),
            "restart lost held disclosure"
        )
        try expect(restarted.available
                   && restarted.state?.authoredMoves.last?.status == .cancelled
                   && restartedRecord.disclosure?.status == .held
                   && restarted.state?.relationalBalance.auroraDisclosureCount == 0,
                   "runtime restart did not preserve state while rolling back unheard playback")
        checks += 1

        return checks
    }

    private static func addRecord(
        _ state: AgencyState,
        kind: AgencyRecordKind,
        scope: AgencyContentScope,
        content: String,
        rationale: String,
        grounding: AgencyGroundingReference,
        source: String,
        at date: Date
    ) throws -> (state: AgencyState, recordID: String) {
        try AgencyEngine.createRecord(
            state,
            kind: kind,
            contentScope: scope,
            content: content,
            privateRationale: rationale,
            groundings: [grounding],
            authoringSourceID: source,
            sourceSessionID: "session-fixture",
            sourceTurnIDs: ["turn-\(source)"],
            expiresAt: date.addingTimeInterval(24 * 3_600),
            confidence: 0.78,
            salience: 0.84,
            at: date
        )
    }

    private static func grounding(
        _ id: String,
        _ kind: AgencyGroundingKind,
        _ date: Date
    ) -> AgencyGroundingReference {
        AgencyGroundingReference(
            id: id,
            kind: kind,
            observedAt: date,
            sourceSessionID: "session-fixture",
            sourceTurnID: "turn-\(id)"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw AgencyVerificationFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AgencyVerificationFailure.failed(message) }
        return value
    }

    private static func expectStoreError(
        _ expected: AgencyStoreError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw AgencyVerificationFailure.failed("expected agency store error \(expected)")
        } catch let error as AgencyStoreError {
            try expect(error == expected, "expected \(expected), received \(error)")
        }
    }
}
