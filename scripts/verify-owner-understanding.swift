import Foundation

enum OwnerUnderstandingVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct OwnerUnderstandingVerification {
    static func main() async {
        do {
            let checks = try await run()
            let payload: [String: Any] = [
                "ok": true,
                "checks": checks,
                "schemaVersion": OwnerUnderstandingState.currentSchemaVersion,
                "maximumProjectionCharacters": OwnerUnderstandingEngine.maximumProjectionCharacters,
                "networkCalls": 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("owner-understanding verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> Int {
        var checks = 0
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        var state = OwnerUnderstandingEngine.defaultState(at: start)
        try expect(state.directStatements.isEmpty && state.tentativeInferences.isEmpty,
                   "new state invented knowledge about Alex")
        checks += 1

        let teal = try OwnerUnderstandingEngine.recordDirectStatement(
            state,
            domain: .tastes,
            subject: "favorite color",
            meaning: "Alex's favorite color is teal",
            exactQuote: "Yeah, teal.",
            sourceSessionID: "session-1",
            sourceTurnID: "turn-1",
            importance: 0.8,
            at: start.addingTimeInterval(1)
        )
        state = teal.state
        try expect(state.directStatements.first?.exactQuote == "Yeah, teal."
                   && state.directStatements.first?.sourceTurnID == "turn-1",
                   "direct knowledge lost exact quote or source turn")
        checks += 1

        let inference = try OwnerUnderstandingEngine.recordTentativeInference(
            state,
            domain: .personalHistory,
            inference: "Addresses from childhood may carry emotional meaning for Alex",
            evidenceStatementIDs: [teal.statementID],
            sourceSessionID: "session-1",
            sourceTurnIDs: ["turn-2"],
            confidence: 0.42,
            at: start.addingTimeInterval(2)
        )
        state = inference.state
        try expect(state.tentativeInferences.count == 1
                   && state.directStatements.count == 1
                   && state.tentativeInferences[0].status == .active,
                   "tentative inference was flattened into direct knowledge")
        checks += 1

        let revised = try OwnerUnderstandingEngine.recordDirectStatement(
            state,
            domain: .tastes,
            subject: "favorite color",
            meaning: "Alex currently likes deep teal most",
            exactQuote: "Actually, deep teal is more accurate.",
            sourceSessionID: "session-1",
            sourceTurnID: "turn-3",
            importance: 0.9,
            supersedesStatementID: teal.statementID,
            at: start.addingTimeInterval(3)
        )
        state = revised.state
        let old = try require(state.directStatements.first(where: { $0.id == teal.statementID }),
                              "revised statement disappeared")
        let current = try require(state.directStatements.first(where: { $0.id == revised.statementID }),
                                  "replacement statement disappeared")
        try expect(old.status == .revised
                   && old.supersededByStatementID == current.id
                   && current.supersedesStatementID == old.id,
                   "contradiction/revision chain was not retained")
        checks += 1

        let curiosity = try OwnerUnderstandingEngine.openCuriosity(
            state,
            domain: .personalHistory,
            question: "What made that childhood house feel like home to you?",
            reason: "The number attached to it still matters to Alex",
            basedOnStatementIDs: [revised.statementID],
            originSourceIDs: ["reflection-1"],
            interest: 0.85,
            at: start.addingTimeInterval(4)
        )
        state = curiosity.state
        let openProjection = OwnerUnderstandingEngine.projection(
            for: state,
            at: start.addingTimeInterval(4)
        )
        try expect(
            openProjection.text.contains("curiosity_id=\(curiosity.curiosityID)"),
            "voice projection hid the opaque curiosity ID needed for lifecycle calls"
        )
        state = try OwnerUnderstandingEngine.prepareCuriosityForPlayback(
            state,
            curiosityID: curiosity.curiosityID,
            responseID: "response-cut-off",
            sourceSessionID: "session-1",
            sourceTurnID: "aurora-turn-1",
            at: start.addingTimeInterval(5)
        )
        try expect(state.curiosities.last?.status == .pendingAsk,
                   "prepared question was marked asked before playback")
        let interrupted = try OwnerUnderstandingEngine.reconcilePlayback(
            state,
            responseID: "response-cut-off",
            fullyPlayed: false,
            playbackEventID: "playback-interrupted-1",
            at: start.addingTimeInterval(6)
        )
        state = interrupted.state
        try expect(state.curiosities.last?.status == .open
                   && state.curiosities.last?.askCount == 0,
                   "interrupted playback consumed the curiosity")
        checks += 1

        state = try OwnerUnderstandingEngine.prepareCuriosityForPlayback(
            state,
            curiosityID: curiosity.curiosityID,
            responseID: "response-heard",
            sourceSessionID: "session-1",
            sourceTurnID: "aurora-turn-2",
            at: start.addingTimeInterval(7)
        )
        let fullyPlayed = try OwnerUnderstandingEngine.reconcilePlayback(
            state,
            responseID: "response-heard",
            fullyPlayed: true,
            playbackEventID: "playback-complete-1",
            at: start.addingTimeInterval(8)
        )
        state = fullyPlayed.state
        try expect(state.curiosities.last?.status == .asked
                   && state.curiosities.last?.askCount == 1
                   && OwnerUnderstandingEngine.cadenceDirection(for: state, at: start.addingTimeInterval(8)) == .stayWithCurrentThread,
                   "fully played question did not enter an asked/current-thread state")
        let duplicatePlayback = try OwnerUnderstandingEngine.reconcilePlayback(
            state,
            responseID: "response-heard",
            fullyPlayed: true,
            playbackEventID: "playback-complete-1",
            at: start.addingTimeInterval(9)
        )
        try expect(duplicatePlayback.state.curiosities.last?.askCount == 1,
                   "duplicate playback receipt counted a question twice")
        state = duplicatePlayback.state
        checks += 1

        let afterFollowUpWindow = start.addingTimeInterval(
            8 + OwnerUnderstandingEngine.askedCuriosityFollowUpWindow + 1
        )
        let agedProjection = OwnerUnderstandingEngine.projection(
            for: state,
            at: afterFollowUpWindow
        )
        try expect(
            OwnerUnderstandingEngine.cadenceDirection(
                for: state,
                at: afterFollowUpWindow
            ) != .stayWithCurrentThread
                && !agedProjection.text.contains("Already asked; stay with his answer")
                && state.curiosities.last?.status == .asked,
            "an unanswered question monopolized Aurora's live attention indefinitely"
        )
        checks += 1

        var playbackBindings = OwnerCuriosityPlaybackBindings()
        try expect(
            playbackBindings.bind(
                inputItemID: "owner-input-one",
                planningResponseID: "private-planning-response",
                exactQuestion: "What makes that feel personal to you?"
            ) == nil
                && playbackBindings.consumePlanningResponseID(
                    forAudibleInputItemID: "owner-input-one"
                ) == "private-planning-response"
                && playbackBindings.consumePlanningResponseID(
                    forAudibleInputItemID: "owner-input-one"
                ) == nil,
            "audible continuation did not consume its planning-response binding exactly once"
        )
        _ = playbackBindings.bind(
            inputItemID: "owner-input-two",
            planningResponseID: "private-planning-two",
            exactQuestion: "What are you still wondering about?"
        )
        try expect(
            playbackBindings.drain().map(\.planningResponseID) == ["private-planning-two"]
                && playbackBindings.isEmpty,
            "interruption did not drain pending curiosity playback bindings"
        )
        checks += 1

        let answer = try OwnerUnderstandingEngine.recordDirectStatement(
            state,
            domain: .personalHistory,
            subject: "childhood home",
            meaning: "The people in Alex's childhood house made it feel like home",
            exactQuote: "Honestly, it was the people in it.",
            sourceSessionID: "session-1",
            sourceTurnID: "turn-4",
            importance: 0.9,
            at: start.addingTimeInterval(10)
        )
        state = try OwnerUnderstandingEngine.answerCuriosity(
            answer.state,
            curiosityID: curiosity.curiosityID,
            statementIDs: [answer.statementID],
            exactQuote: "Honestly, it was the people in it.",
            sourceSessionID: "session-1",
            sourceTurnID: "turn-4",
            at: start.addingTimeInterval(10)
        )
        try expect(state.curiosities.last?.status == .answered
                   && state.curiosities.last?.answerStatementIDs == [answer.statementID],
                   "curiosity answer was not grounded in a direct owner statement")
        checks += 1

        for index in 0..<5 {
            let item = try OwnerUnderstandingEngine.recordDirectStatement(
                state,
                domain: OwnerUnderstandingDomain.allCases[index],
                subject: "subject \(index)",
                meaning: "Bounded projection fact \(index)",
                exactQuote: "Exact quote \(index)",
                sourceSessionID: "session-2",
                sourceTurnID: "projection-turn-\(index)",
                importance: Double(index) / 5,
                at: start.addingTimeInterval(Double(20 + index))
            )
            state = item.state
        }
        let projection = OwnerUnderstandingEngine.projection(for: state, at: start.addingTimeInterval(30))
        try expect(projection.text.count <= OwnerUnderstandingEngine.maximumProjectionCharacters
                   && projection.directStatementIDs.count <= 3
                   && projection.tentativeInferenceID != nil,
                   "voice projection escaped its fact/inference/character bounds")
        checks += 1

        let checklist = """
        # Preferences
        - [x] Favorite color: teal
        - [ ] Favorite food
        Ordinary prose must not import.
        ## Personal history
        * [X] Childhood address mattered
        * [ ] A place he wants to revisit
        """
        let source = OwnerLegacyChecklistSource(
            path: "personhood/people/alex.md",
            revision: "sha256:fixture-v1"
        )
        let parsed = try OwnerUnderstandingEngine.importLegacyChecklist(
            markdown: checklist,
            source: source,
            at: start
        )
        try expect(parsed.evidence.count == 2
                   && parsed.gapCandidates.count == 2
                   && parsed.evidence.allSatisfy { $0.sourcePath == source.path },
                   "structural legacy checklist parser imported non-checkbox prose or lost provenance")
        let beforeDirectCount = state.directStatements.count
        let imported = try OwnerUnderstandingEngine.commitLegacyChecklistImport(
            state,
            checklistImport: parsed,
            at: start.addingTimeInterval(31)
        )
        state = imported.state
        try expect(imported.imported
                   && state.directStatements.count == beforeDirectCount
                   && state.legacyContinuityEvidence.count == 2,
                   "legacy continuity was mislabeled as a direct owner quote")
        let legacyGap = try require(
            state.legacyGapCandidates.first,
            "legacy gap candidate was not retained"
        )
        let legacyProjection = OwnerUnderstandingEngine.projection(
            for: state,
            at: start.addingTimeInterval(31)
        )
        try expect(
            legacyProjection.text.count <= 800
                && legacyProjection.text.contains("origin_source_id=\(legacyGap.id)"),
            "bounded voice projection did not expose an inherited gap as a nonfactual cue"
        )
        let promotedGap = try OwnerUnderstandingEngine.openCuriosity(
            state,
            domain: .tastes,
            question: "What food do you never get tired of?",
            reason: "The inherited checklist marks favorite food as unknown.",
            basedOnStatementIDs: [],
            originSourceIDs: [legacyGap.id],
            at: start.addingTimeInterval(31)
        )
        state = promotedGap.state
        try expect(
            state.legacyGapCandidates.first(where: { $0.id == legacyGap.id })?.retiredAt != nil,
            "a legacy cue remained eligible after becoming a living curiosity"
        )
        let laterRevision = try OwnerUnderstandingEngine.importLegacyChecklist(
            markdown: "- [x] A replacement",
            source: OwnerLegacyChecklistSource(path: source.path, revision: "sha256:fixture-v2"),
            at: start.addingTimeInterval(32)
        )
        let duplicateImport = try OwnerUnderstandingEngine.commitLegacyChecklistImport(
            state,
            checklistImport: laterRevision,
            at: start.addingTimeInterval(32)
        )
        try expect(!duplicateImport.imported
                   && duplicateImport.state.legacyContinuityEvidence.count == 2,
                   "one-time legacy bootstrap silently rewrote imported history")
        state = duplicateImport.state
        checks += 1

        var malformedPending = state
        malformedPending.curiosities[0].status = .pendingAsk
        malformedPending.curiosities[0].pendingResponseID = nil
        let pendingSanitized = OwnerUnderstandingEngine.sanitize(
            malformedPending,
            now: start.addingTimeInterval(40)
        )
        try expect(pendingSanitized.curiosities.first?.status == .open,
                   "sanitizer retained an unbound pending question")

        var oversized = state
        let template = try require(state.directStatements.last, "missing direct statement fixture")
        for index in 0..<(OwnerUnderstandingEngine.maximumDirectStatements + 30) {
            var copy = template
            copy = OwnerDirectStatement(
                id: "bounded-fixture-\(index)",
                domain: copy.domain,
                subject: copy.subject,
                meaning: copy.meaning,
                exactQuote: copy.exactQuote,
                sourceSessionID: copy.sourceSessionID,
                sourceTurnID: "bounded-source-\(index)",
                createdAt: copy.createdAt,
                updatedAt: copy.updatedAt,
                importance: copy.importance,
                status: .active,
                supersedesStatementID: nil,
                supersededByStatementID: nil,
                revisionSourceSessionID: nil,
                revisionSourceTurnID: nil,
                revisionExactQuote: nil
            )
            oversized.directStatements.append(copy)
        }
        let sanitized = OwnerUnderstandingEngine.sanitize(oversized, now: start.addingTimeInterval(40))
        try expect(sanitized.directStatements.count == OwnerUnderstandingEngine.maximumDirectStatements,
                   "sanitizer failed direct-statement count bounds")
        checks += 1

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-owner-understanding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root
            .appendingPathComponent("owner-understanding", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let store = OwnerUnderstandingStore(fileURL: stateURL)
        try store.save(state)
        let reloaded = try require(try store.load(), "persisted state did not reload")
        try expect(reloaded == OwnerUnderstandingEngine.sanitize(state, now: state.updatedAt)
                   && reloaded.directStatements.contains(where: { $0.id == revised.statementID }),
                   "relaunch persistence lost owner understanding or revision history")
        checks += 1

        let corruptURL = root
            .appendingPathComponent("corrupt", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let corruptStore = OwnerUnderstandingStore(fileURL: corruptURL)
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: corruptURL)
        try expectStoreError(.corruptState) { _ = try corruptStore.load() }
        checks += 1

        let oversizedURL = root
            .appendingPathComponent("oversized", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let oversizedStore = OwnerUnderstandingStore(fileURL: oversizedURL)
        try FileManager.default.createDirectory(at: oversizedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: OwnerUnderstandingStore.maximumStateBytes + 1).write(to: oversizedURL)
        try expectStoreError(.stateTooLarge) { _ = try oversizedStore.load() }
        checks += 1

        let symlinkFileDirectory = root.appendingPathComponent("symlink-file", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkFileDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json", isDirectory: false)
        try Data("{}".utf8).write(to: target)
        let symlinkFileURL = symlinkFileDirectory.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: symlinkFileURL, withDestinationURL: target)
        try expectStoreError(.unsafeStateFile) {
            _ = try OwnerUnderstandingStore(fileURL: symlinkFileURL).load()
        }
        checks += 1

        let symlinkParent = root.appendingPathComponent("symlink-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
        let actualDirectory = root.appendingPathComponent("actual-state", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
        let linkedDirectory = symlinkParent.appendingPathComponent("owner-understanding", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: actualDirectory)
        let linkedStateURL = linkedDirectory.appendingPathComponent("state.json")
        try expectStoreError(.unsafeDirectory) {
            _ = try OwnerUnderstandingStore(fileURL: linkedStateURL).load()
        }
        checks += 1

        let runtimeURL = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let runtime = AuroraOwnerUnderstandingRuntime(
            store: OwnerUnderstandingStore(fileURL: runtimeURL),
            now: { start }
        )
        let startedRuntime = await runtime.start()
        try expect(startedRuntime.available, "runtime failed to start")
        let update = OwnerUnderstandingUpdate(
            action: .recordDirectStatement,
            domain: .tastes,
            subject: "favorite food",
            content: "Alex's favorite food is sushi",
            sourceQuote: "Sushi, easily.",
            importance: 0.8
        )
        _ = try await runtime.recordExchange(
            ownerText: "Sushi, easily.",
            sourceTurnID: "runtime-turn-1",
            sessionID: "runtime-session-1",
            updates: [update],
            at: start.addingTimeInterval(50)
        )
        let runtimeSnapshot = await runtime.snapshot()
        try expect(runtimeSnapshot.state?.directStatements.first?.exactQuote == "Sushi, easily.",
                   "runtime recordExchange lost exact evidence")

        let runtimeStatementID = try require(
            runtimeSnapshot.state?.directStatements.first?.id,
            "runtime statement fixture had no ID"
        )
        _ = try await runtime.recordExchange(
            ownerText: "That answer made me wonder what you would ask next.",
            sourceTurnID: "runtime-turn-curiosity",
            sessionID: "runtime-session-1",
            updates: [OwnerUnderstandingUpdate(
                action: .openCuriosity,
                domain: .tastes,
                question: "What makes sushi feel like the easy answer for you?",
                reason: "Alex named it immediately, but the personal reason is unknown.",
                evidenceStatementIDs: [runtimeStatementID],
                importance: 0.7,
                spokenInThisResponse: true
            )],
            responseID: "private-planning-curiosity",
            at: start.addingTimeInterval(50.5)
        )
        var runtimeBindings = OwnerCuriosityPlaybackBindings()
        _ = runtimeBindings.bind(
            inputItemID: "runtime-turn-curiosity",
            planningResponseID: "private-planning-curiosity",
            exactQuestion: "What makes sushi feel like the easy answer for you?"
        )
        let boundPlanningResponse = try require(
            runtimeBindings.consumePlanningResponseID(
                forAudibleInputItemID: "runtime-turn-curiosity"
            ),
            "later audible continuation lost its private planning response"
        )
        _ = try await runtime.reconcilePlayback(
            responseID: boundPlanningResponse,
            fullyPlayed: true,
            playbackEventID: "audible-continuation-playback",
            at: start.addingTimeInterval(50.75)
        )
        let heardCuriosity = await runtime.snapshot().state?.curiosities.last
        try expect(
            heardCuriosity?.status == .asked
                && heardCuriosity?.askCount == 1
                && heardCuriosity?.lastAskedResponseID == "private-planning-curiosity"
                && runtimeBindings.isEmpty,
            "a fully heard continuation left its question open or eligible for repeated asking"
        )
        checks += 1
        do {
            _ = try await runtime.recordExchange(
                ownerText: "That is not what I said.",
                sourceTurnID: "runtime-turn-2",
                sessionID: "runtime-session-1",
                updates: [update],
                at: start.addingTimeInterval(51)
            )
            throw OwnerUnderstandingVerificationFailure.failed(
                "runtime accepted a source quote absent from the finalized turn"
            )
        } catch let error as OwnerUnderstandingInputError {
            guard case .invalidInput = error else { throw error }
        }
        let voice = await runtime.voiceProjection(at: start.addingTimeInterval(52))
        try expect(voice.count <= OwnerUnderstandingEngine.maximumProjectionCharacters
                   && voice.contains("favorite food is sushi"),
                   "runtime did not expose its bounded live projection")
        checks += 1

        do {
            _ = try OwnerUnderstandingEngine.openCuriosity(
                state,
                domain: .identity,
                question: "parts continuity wanting coherence caring most central sense aliveness?",
                reason: "syntactically malformed model output",
                basedOnStatementIDs: [],
                originSourceIDs: ["malformed-question-fixture"],
                at: start.addingTimeInterval(53)
            )
            throw OwnerUnderstandingVerificationFailure.failed(
                "owner understanding accepted an abstract question fragment"
            )
        } catch let error as OwnerUnderstandingInputError {
            guard case .invalidInput = error else { throw error }
        }
        checks += 1

        return checks
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw OwnerUnderstandingVerificationFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw OwnerUnderstandingVerificationFailure.failed(message) }
        return value
    }

    private static func expectStoreError(
        _ expected: OwnerUnderstandingStoreError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw OwnerUnderstandingVerificationFailure.failed("expected store error \(expected)")
        } catch let error as OwnerUnderstandingStoreError {
            try expect(error == expected, "expected \(expected), received \(error)")
        }
    }
}
