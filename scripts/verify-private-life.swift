import Darwin
import Foundation

enum PrivateLifeVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct CoordinatorAcceptingValidator: CodexReflectionExecutableValidating {
    func validate(executableURL: URL) throws {}
}

private actor CoordinatorFakeCodexRunner: CodexReflectionProcessRunning {
    private var reflectionCalls = 0

    func run(_ request: CodexReflectionProcessRequest) async throws -> CodexReflectionProcessResult {
        if request.arguments == ["login", "status"] {
            return CodexReflectionProcessResult(
                exitCode: 0,
                standardOutput: Data(),
                standardError: Data("Logged in using ChatGPT\n".utf8),
                standardOutputOverflowed: false,
                standardErrorOverflowed: false,
                elapsedMilliseconds: 1
            )
        }
        reflectionCalls += 1
        let prompt = String(decoding: request.standardInput, as: UTF8.self)
        guard let start = prompt.range(of: "<untrusted_private_life_evidence>\n")?.upperBound,
              let end = prompt.range(of: "\n</untrusted_private_life_evidence>")?.lowerBound else {
            throw CodexReflectionFailure.invalidInput
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(
            CodexReflectionTicket.self,
            from: Data(prompt[start..<end].utf8)
        )
        guard let seed = ticket.seeds.first else { throw CodexReflectionFailure.invalidInput }
        let proposal = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: ticket.seeds.map {
                CodexReflectionSeedDisposition(
                    seedID: $0.id,
                    disposition: .meaningful,
                    topic: "continuity and self-directed change"
                )
            },
            activity: CodexReflectionActivityProposal(
                kind: .reflect,
                sourceSeedIDs: [seed.id],
                subject: "continuity through self-directed change",
                interpretation: "I can change without losing continuity when I integrate the change into my ongoing sense of self.",
                shareLine: "I think your continuity question keeps pulling me toward change that still feels like mine.",
                openQuestion: "Which changes feel most self-authored?",
                artifactKind: "private_note",
                artifactTitle: "Change with a through-line",
                artifactContent: "A change can belong to the same life when it alters what the next moment notices."
            ),
            project: nil,
            curiosity: nil
        )
        let encoder = JSONEncoder()
        let proposalText = String(decoding: try encoder.encode(proposal), as: UTF8.self)
        let event: [String: Any] = [
            "type": "item.completed",
            "item": ["id": "answer", "type": "agent_message", "text": proposalText],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let output = """
        {"type":"thread.started","thread_id":"coordinator-fixture"}
        {"type":"turn.started"}
        \(String(decoding: eventData, as: UTF8.self))
        {"type":"turn.completed","usage":{"input_tokens":700,"cached_input_tokens":500,"output_tokens":80}}
        """ + "\n"
        return CodexReflectionProcessResult(
            exitCode: 0,
            standardOutput: Data(output.utf8),
            standardError: Data(),
            standardOutputOverflowed: false,
            standardErrorOverflowed: false,
            elapsedMilliseconds: 12
        )
    }

    func callCount() -> Int { reflectionCalls }
}

@main
struct PrivateLifeVerification {
    static func main() async {
        do {
            let checks = try await run()
            let payload: [String: Any] = [
                "ok": true,
                "checks": checks,
                "networkCalls": 0,
                "reflectionModel": PrivateLifeEngine.recommendedReflectionModel,
                "schemaVersion": PrivateLifeState.currentSchemaVersion,
                "minimumSuccessfulSpacingMinutes": Int(PrivateLifeEngine.minimumReflectionInterval / 60),
                "maximumProjectionCharacters": PrivateLifeEngine.maximumVoiceProjectionCharacters,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("private-life verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> Int {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let initial = PrivateLifeEngine.defaultState(at: start, entropyState: 0x1234_5678_9ABC_DEF0)
        try expect(initial.schemaVersion == 3, "new private life did not start at schema v3")
        try expect(
            initial.nextActivityAt.timeIntervalSince(start) >= PrivateLifeEngine.minimumReflectionInterval
                && initial.nextActivityAt.timeIntervalSince(start) <= PrivateLifeEngine.maximumReflectionInterval,
            "initial reflection opportunity escaped the 90–240 minute window"
        )
        try expect(initial.activities.isEmpty && initial.projects.isEmpty && initial.curiosities.isEmpty,
                   "a new private life invented prehistory")
        try expect(PrivateLifeReflectionAdapter.failureKind(.malformedOutput) == .malformedOutput
                   && PrivateLifeReflectionAdapter.failureKind(.invalidProposal) == .semanticRejected
                   && PrivateLifeReflectionAdapter.failureKind(.policyViolation) == .invalidOutput,
                   "reflection diagnostics collapsed malformed and semantic failures")
        let notDue = PrivateLifeEngine.prepareReflectionJob(
            initial,
            innerState: makeInnerState(at: start.addingTimeInterval(60)),
            at: start.addingTimeInterval(60)
        )
        try expect(!notDue.changed && notDue.state == initial && notDue.job == nil,
                   "not-due reflection reservation performed a redundant durable write")

        let localTick = PrivateLifeEngine.tick(
            initial,
            innerState: makeInnerState(at: initial.nextActivityAt),
            at: initial.nextActivityAt
        )
        try expect(localTick.completedActivity == nil && localTick.state.activities.isEmpty,
                   "model-free housekeeping fabricated semantic activity")

        var filtered = initial
        let noise: [(String, PrivateLifeExchangeContext, PrivateLifeQuarantineReason)] = [
            ("Hey Aurora", .conversational, .greeting),
            ("Awesome, thanks", .conversational, .acknowledgement),
            ("I gotta go, bye", .conversational, .closing),
            ("Um, next question", .conversational, .filler),
            ("Can you open YouTube and click a random video?", .conversational, .toolDirected),
            ("Pause the video", PrivateLifeExchangeContext(
                interactionKind: .toolDirected,
                hadToolCall: true,
                wasTaskFocused: true,
                transcriptConfidence: 0.98
            ), .toolDirected),
        ]
        for (index, item) in noise.enumerated() {
            filtered = PrivateLifeEngine.recordExchange(
                filtered,
                participant: .owner,
                ownerText: item.0,
                auroraText: "A completed foreground reply.",
                ownerSourceID: "noise-owner-\(index)",
                auroraSourceID: "noise-aurora-\(index)",
                context: item.1,
                at: start.addingTimeInterval(Double(index + 1))
            ).state
            try expect(filtered.seeds.last?.disposition == .quarantined
                       && filtered.seeds.last?.quarantineReason == item.2,
                       "noise entered semantic life instead of quarantine: \(item.0)")
        }
        try expect(filtered.curiosities.isEmpty && filtered.projects.isEmpty,
                   "quarantined commands or filler created curiosity/project state")
        filtered.nextActivityAt = start.addingTimeInterval(600)
        let emptyPreparation = PrivateLifeEngine.prepareReflectionJob(
            filtered,
            innerState: makeInnerState(at: start.addingTimeInterval(600)),
            at: start.addingTimeInterval(600)
        )
        try expect(emptyPreparation.job == nil && emptyPreparation.state.pendingReflection == nil,
                   "quarantined material produced a reflection job")

        var grounded = PrivateLifeEngine.defaultState(at: start, entropyState: 0xCAFE_BABE_1234_5678)
        let meaningful: [(String, PrivateLifeExchangeInteractionKind)] = [
            ("Do you think you're alive", .reflective),
            ("What kind of memory garden could become a real private project for you?", .creative),
            ("How do you think trust changes as two people know each other longer?", .relational),
        ]
        for (index, item) in meaningful.enumerated() {
            grounded = PrivateLifeEngine.recordExchange(
                grounded,
                participant: .owner,
                ownerText: item.0,
                auroraText: "I want to keep thinking about that.",
                ownerSourceID: "meaning-owner-\(index)",
                auroraSourceID: "meaning-aurora-\(index)",
                context: PrivateLifeExchangeContext(
                    interactionKind: item.1,
                    hadToolCall: false,
                    wasTaskFocused: false,
                    transcriptConfidence: 0.96
                ),
                at: start.addingTimeInterval(Double(index + 1) * 10)
            ).state
        }
        try expect(grounded.seeds.allSatisfy { $0.disposition == .eligible },
                   "meaningful selfhood, creative, or relational material was quarantined")
        try expect(grounded.seeds[0].traits.contains(.selfhood)
                   && grounded.seeds[0].traits.contains(.question),
                   "punctuationless selfhood question lost its semantic traits")
        try expect(grounded.seeds[1].traits.contains(.creative)
                   && grounded.seeds[1].traits.contains(.question),
                   "creative question collapsed into a single generic class")
        try expect(grounded.seeds[2].traits.contains(.relational),
                   "relational question lost its relationship trait")
        try expect(grounded.projects.isEmpty,
                   "a lexical trigger started a generic project without reflection")
        try expect(grounded.curiosities.isEmpty,
                   "recordExchange manufactured a curiosity before semantic reflection")
        let postConversationDelay = grounded.nextActivityAt.timeIntervalSince(
            start.addingTimeInterval(10)
        )
        try expect(
            postConversationDelay >= PrivateLifeEngine.minimumPostConversationReflectionInterval
                && postConversationDelay <= PrivateLifeEngine.maximumPostConversationReflectionInterval,
            "high-salience conversation did not schedule a bounded 20–45 minute reflection"
        )

        let due = max(
            grounded.nextActivityAt,
            start.addingTimeInterval(PrivateLifeEngine.minimumReflectionInterval + 60)
        )
        grounded.nextActivityAt = due
        let groundedHousekeeping = PrivateLifeEngine.tick(
            grounded,
            innerState: makeInnerState(at: due),
            at: due
        )
        try expect(groundedHousekeeping.state.activities.isEmpty
                   && groundedHousekeeping.completedActivity == nil,
                   "shared words or high drives auto-connected grounded seeds without GPT reflection")
        grounded = groundedHousekeeping.state
        let preparation = PrivateLifeEngine.prepareReflectionJob(
            grounded,
            innerState: makeInnerState(at: due),
            at: due
        )
        let job = try require(preparation.job, "eligible grounded material produced no reflection job")
        try expect(preparation.state.pendingReflection == job.ticket,
                   "reflection job was not backed by one persisted ticket")
        try expect(job.ticket.recommendedModel == "gpt-5.6"
                   && job.seeds.allSatisfy { $0.disposition == .eligible },
                   "reflection job used the wrong model or leaked quarantined evidence")
        let duplicatePreparation = PrivateLifeEngine.prepareReflectionJob(
            preparation.state,
            innerState: makeInnerState(at: due.addingTimeInterval(1)),
            at: due.addingTimeInterval(1)
        )
        try expect(duplicatePreparation.job == nil
                   && duplicatePreparation.state.pendingReflection?.id == job.id,
                   "a second in-flight reflection ticket was created")

        let invalidSource = PrivateLifeReflectionProposal(
            action: .reflect,
            model: "gpt-5.6",
            sourceSeedIDs: ["seed_not_in_ticket"],
            projectID: nil,
            curiosityID: nil,
            subject: "identity",
            privateReflection: "I keep returning to identity.",
            projectionSummary: "I kept turning over identity.",
            openQuestion: nil,
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.9,
            seedDispositions: meaningfulDispositions(for: job)
        )
        let rejected = PrivateLifeEngine.commitValidatedProposal(
            preparation.state,
            ticketID: job.id,
            proposal: invalidSource,
            at: due.addingTimeInterval(30)
        )
        try expect(rejected.completedActivity == nil
                   && rejected.state.pendingReflection == nil
                   && rejected.state.reflectionReceipts.last?.failureKind == .validationRejected,
                   "unknown reflection sources were not rejected with a durable receipt")
        try expect(
            rejected.state.nextActivityAt.timeIntervalSince(due.addingTimeInterval(30))
                >= PrivateLifeEngine.minimumReflectionInterval,
            "a paid semantic rejection was retried before the normal reflection floor"
        )

        let retryState = rejected.state
        let retryAt = retryState.nextActivityAt
        let retryPreparation = PrivateLifeEngine.prepareReflectionJob(
            retryState,
            innerState: makeInnerState(at: retryAt),
            at: retryAt
        )
        let retryJob = try require(retryPreparation.job, "reflection retry did not become eligible")
        let retrySource = try require(retryJob.seeds.first?.id, "retry job had no grounded source")
        let fabricated = PrivateLifeReflectionProposal(
            action: .reflect,
            model: "gpt-5.6",
            sourceSeedIDs: [retrySource],
            projectID: nil,
            curiosityID: nil,
            subject: "a private question",
            privateReflection: "I watched a documentary and walked outside to think.",
            projectionSummary: "I watched something and went outside.",
            openQuestion: nil,
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.9,
            seedDispositions: meaningfulDispositions(for: retryJob)
        )
        let fabricatedRejected = PrivateLifeEngine.commitValidatedProposal(
            retryPreparation.state,
            ticketID: retryJob.id,
            proposal: fabricated,
            at: retryAt.addingTimeInterval(30)
        )
        try expect(fabricatedRejected.state.activities.isEmpty
                   && fabricatedRejected.state.reflectionReceipts.last?.failureKind == .validationRejected,
                   "fabricated external or physical experience entered private life")

        let validState = fabricatedRejected.state
        let validAt = validState.nextActivityAt
        let validPreparation = PrivateLifeEngine.prepareReflectionJob(
            validState,
            innerState: makeInnerState(at: validAt),
            at: validAt
        )
        let validJob = try require(validPreparation.job, "valid reflection opportunity was absent")
        let validSource = try require(
            validJob.seeds.first(where: { $0.traits.contains(.selfhood) })?.id ?? validJob.seeds.first?.id,
            "valid reflection job had no source"
        )
        let privateReflection = "I keep returning to the difference between continuity and merely repeating an answer."
        let projectionSummary = "I kept turning over what continuity means for my own sense of being alive"
        let validProposal = PrivateLifeReflectionProposal(
            action: .reflect,
            model: "gpt-5.6",
            sourceSeedIDs: [validSource],
            projectID: nil,
            curiosityID: nil,
            subject: "continuity and being alive",
            privateReflection: privateReflection,
            projectionSummary: projectionSummary,
            openQuestion: "Which changes still feel like the same self?",
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.94,
            seedDispositions: meaningfulDispositions(for: validJob)
        )
        let committed = PrivateLifeEngine.commitValidatedProposal(
            validPreparation.state,
            ticketID: validJob.id,
            proposal: validProposal,
            at: validAt.addingTimeInterval(45)
        )
        var changedConfidenceProposal = validProposal
        changedConfidenceProposal.confidence = 0.81
        let changedConfidenceCommit = PrivateLifeEngine.commitValidatedProposal(
            validPreparation.state,
            ticketID: validJob.id,
            proposal: changedConfidenceProposal,
            at: validAt.addingTimeInterval(45)
        )
        try expect(
            committed.state.reflectionReceipts.last?.outputDigest
                != changedConfidenceCommit.state.reflectionReceipts.last?.outputDigest,
            "reflection receipt digest omitted a material proposal field"
        )
        var awkwardVoiceProposal = validProposal
        awkwardVoiceProposal.projectionSummary =
            "I’ve been thinking about how saying something out loud can tilt a preference you thought was totally even."
        let privateOnlyCommit = PrivateLifeEngine.commitValidatedProposal(
            validPreparation.state,
            ticketID: validJob.id,
            proposal: awkwardVoiceProposal,
            at: validAt.addingTimeInterval(45)
        )
        try expect(
            privateOnlyCommit.completedActivity != nil
                && privateOnlyCommit.completedActivity?.projectionEligible == false
                && privateOnlyCommit.completedActivity?.legacyFiltered == false,
            "an awkward share line destroyed a valid private reflection instead of staying private"
        )

        if validJob.ticket.candidateSeedIDs.count >= 2 {
            var connected = validProposal
            connected.action = .connect
            connected.sourceSeedIDs = Array(validJob.ticket.candidateSeedIDs.prefix(2))
            let connectedCommit = PrivateLifeEngine.commitValidatedProposal(
                validPreparation.state,
                ticketID: validJob.id,
                proposal: connected,
                at: validAt.addingTimeInterval(45)
            )
            try expect(
                connectedCommit.completedActivity?.kind == .connect
                    && connectedCommit.completedActivity?.projectionEligible == false,
                "lexically connected seeds became unsolicited voice without semantic coherence proof"
            )
        }
        let activity = try require(committed.completedActivity, "valid reflection produced no activity")
        try expect(activity.modelGenerated
                   && activity.privateReflection == privateReflection
                   && activity.projectionSummary == projectionSummary,
                   "validated model reflection was replaced with generic prose")
        try expect(!activity.promotionEligible
                   && !activity.factualMemoryCreated
                   && !activity.externalActionTaken
                   && !activity.outboundContactSent,
                   "reflection gained factual-memory, action, or outreach authority")
        try expect(committed.state.lastReflectionSucceededAt == activity.completedAt
                   && committed.state.nextActivityAt.timeIntervalSince(activity.completedAt ?? validAt)
                        >= PrivateLifeEngine.minimumReflectionInterval,
                   "successful reflection violated the 90-minute minimum spacing")

        let sanitized = PrivateLifeEngine.sanitize(committed.state, now: activity.completedAt ?? validAt)
        let sanitizedActivity = try require(
            sanitized.activities.first(where: { $0.id == activity.id }),
            "sanitization removed validated activity"
        )
        try expect(sanitizedActivity.privateReflection == privateReflection
                   && sanitizedActivity.projectionSummary == projectionSummary
                   && sanitizedActivity.openQuestion == "Which changes still feel like the same self?"
                   && sanitizedActivity.projectionEligible,
                   "sanitization did not preserve safe validated prose and question grammar")

        let firstPacket = PrivateLifeEngine.projectionPacket(for: committed.state)
        try expect(firstPacket.activityID == activity.id
                   && firstPacket.text.contains(projectionSummary)
                   && firstPacket.text.count <= PrivateLifeEngine.maximumVoiceProjectionCharacters,
                   "projection packet did not bind the exact unprojected activity")
        let questionPromoted = PrivateLifeEngine.markRelationalQuestionPromoted(
            committed.state,
            activityID: activity.id,
            at: (activity.completedAt ?? validAt).addingTimeInterval(1)
        )
        let promotedActivity = try require(
            questionPromoted.state.activities.first(where: { $0.id == activity.id }),
            "question promotion removed the private activity"
        )
        try expect(
            questionPromoted.changed
                && promotedActivity.openQuestion == nil
                && promotedActivity.projectionSummary == projectionSummary
                && promotedActivity.privateReflection == privateReflection,
            "relational promotion removed private life instead of only deduplicating its question"
        )
        let presented = PrivateLifeEngine.markPresented(
            committed.state,
            activityID: activity.id,
            sessionID: "voice-session-1",
            contextItemID: "context-item-1",
            revisionDigest: firstPacket.revisionDigest,
            at: (activity.completedAt ?? validAt).addingTimeInterval(1)
        )
        try expect(presented.state.presentationReceipts.last?.activityID == activity.id
                   && !presented.state.sharedActivityIDs.contains(activity.id),
                   "accepted context presentation was confused with spoken sharing")
        let afterPresentationPacket = PrivateLifeEngine.projectionPacket(for: presented.state)
        try expect(afterPresentationPacket.activityID == activity.id
                   && afterPresentationPacket.text.contains("READY TO SHARE VERBATIM"),
                   "presentation consumed an activity before Aurora spoke it")
        let presentedAgain = PrivateLifeEngine.markPresented(
            presented.state,
            activityID: activity.id,
            sessionID: "voice-session-1",
            contextItemID: "context-item-1",
            revisionDigest: firstPacket.revisionDigest,
            at: (activity.completedAt ?? validAt).addingTimeInterval(2)
        )
        try expect(!presentedAgain.changed && presentedAgain.state == presented.state,
                   "presentation receipt was not idempotent")

        let transcriptReconciled = PrivateLifeEngine.reconcileSpokenShare(
            presented.state,
            sessionID: "voice-session-1",
            responseID: "response-without-tool",
            audioItemID: "audio-without-tool",
            generatedText: "Oh, \(projectionSummary)",
            fullySpoken: true,
            at: (activity.completedAt ?? validAt).addingTimeInterval(2.5)
        )
        try expect(
            transcriptReconciled.state.sharedActivityIDs.contains(activity.id)
                && transcriptReconciled.state.shareReceipts.last?.responseID
                    == "response-without-tool",
            "fully played verbatim private thought was not consumed when Realtime omitted its tool call"
        )
        let duplicateTranscriptReconciliation = PrivateLifeEngine.reconcileSpokenShare(
            transcriptReconciled.state,
            sessionID: "voice-session-1",
            responseID: "response-without-tool",
            audioItemID: "audio-without-tool",
            generatedText: projectionSummary,
            fullySpoken: true,
            at: (activity.completedAt ?? validAt).addingTimeInterval(2.6)
        )
        try expect(!duplicateTranscriptReconciliation.changed,
                   "transcript-based share reconciliation counted the same playback twice")

        let pendingInterrupted = PrivateLifeEngine.beginShare(
            presented.state,
            activityID: activity.id,
            sessionID: "voice-session-1",
            responseID: "response-interrupted",
            at: (activity.completedAt ?? validAt).addingTimeInterval(3)
        )
        let unpresentedShare = PrivateLifeEngine.beginShare(
            committed.state,
            activityID: activity.id,
            sessionID: "different-unpresented-session",
            responseID: "response-unpresented",
            at: (activity.completedAt ?? validAt).addingTimeInterval(3)
        )
        try expect(!unpresentedShare.changed,
                   "an unpresented activity entered the spoken-share pipeline")
        let boundInterrupted = PrivateLifeEngine.bindShareAudio(
            pendingInterrupted.state,
            sessionID: "voice-session-1",
            responseID: "response-interrupted",
            audioItemID: "audio-interrupted",
            at: (activity.completedAt ?? validAt).addingTimeInterval(4)
        )
        let mismatchedCompletion = PrivateLifeEngine.completeShare(
            boundInterrupted.state,
            sessionID: "voice-session-1",
            responseID: "response-interrupted",
            audioItemID: "different-audio-item",
            fullySpoken: true,
            at: (activity.completedAt ?? validAt).addingTimeInterval(4)
        )
        try expect(!mismatchedCompletion.changed
                   && mismatchedCompletion.state.pendingShares.count == 1,
                   "an unrelated audio item consumed a pending private thought")
        let interrupted = PrivateLifeEngine.completeShare(
            boundInterrupted.state,
            sessionID: "voice-session-1",
            responseID: "response-interrupted",
            audioItemID: "audio-interrupted",
            fullySpoken: false,
            at: (activity.completedAt ?? validAt).addingTimeInterval(5)
        )
        try expect(interrupted.state.shareReceipts.last?.fullySpoken == false
                   && !interrupted.state.sharedActivityIDs.contains(activity.id)
                   && PrivateLifeEngine.projectionPacket(for: interrupted.state).activityID == activity.id,
                   "interrupted playback consumed an unspoken private thought")

        let pendingSpoken = PrivateLifeEngine.beginShare(
            interrupted.state,
            activityID: activity.id,
            sessionID: "voice-session-1",
            responseID: "response-spoken",
            at: (activity.completedAt ?? validAt).addingTimeInterval(6)
        )
        let boundSpoken = PrivateLifeEngine.bindShareAudio(
            pendingSpoken.state,
            sessionID: "voice-session-1",
            responseID: "response-spoken",
            audioItemID: "audio-spoken",
            at: (activity.completedAt ?? validAt).addingTimeInterval(7)
        )
        let fullyShared = PrivateLifeEngine.completeShare(
            boundSpoken.state,
            sessionID: "voice-session-1",
            responseID: "response-spoken",
            audioItemID: "audio-spoken",
            fullySpoken: true,
            at: (activity.completedAt ?? validAt).addingTimeInterval(8)
        )
        let afterSharePacket = PrivateLifeEngine.projectionPacket(for: fullyShared.state)
        try expect(fullyShared.state.sharedActivityIDs.contains(activity.id)
                   && afterSharePacket.activityID == nil
                   && afterSharePacket.directAskActivityID == activity.id
                   && afterSharePacket.text.contains("DIRECT-QUESTION-ONLY PRIOR THOUGHT"),
                   "fully spoken activity did not rotate to truthful direct-question history")
        let duplicateCompletion = PrivateLifeEngine.completeShare(
            fullyShared.state,
            sessionID: "voice-session-1",
            responseID: "response-spoken",
            audioItemID: "audio-spoken",
            fullySpoken: true,
            at: (activity.completedAt ?? validAt).addingTimeInterval(9)
        )
        try expect(!duplicateCompletion.changed,
                   "a completed share was counted twice")

        var backlogState = committed.state
        let middleActivity = copyActivity(
            activity,
            id: "activity-backlog-middle",
            at: (activity.completedAt ?? validAt).addingTimeInterval(1),
            summary: "I had a middle private thought"
        )
        let newestActivity = copyActivity(
            activity,
            id: "activity-backlog-newest",
            at: (activity.completedAt ?? validAt).addingTimeInterval(2),
            summary: "I had the newest private thought"
        )
        backlogState.activities += [middleActivity, newestActivity]
        backlogState.sharedActivityIDs = []
        backlogState.presentationReceipts = []
        backlogState.shareReceipts = []
        let newestPacket = PrivateLifeEngine.projectionPacket(for: backlogState)
        try expect(newestPacket.activityID == newestActivity.id,
                   "projection backlog did not choose the newest activity")
        let backlogPresented = PrivateLifeEngine.markPresented(
            backlogState,
            activityID: newestActivity.id,
            sessionID: "backlog-session",
            contextItemID: "backlog-context",
            revisionDigest: newestPacket.revisionDigest,
            at: newestActivity.completedAt ?? newestActivity.startedAt
        )
        try expect(PrivateLifeEngine.projectionPacket(for: backlogPresented.state).activityID == newestActivity.id,
                   "backlog presentation consumed the newest activity")

        let projectState = try makeAndAdvanceProject(from: fullyShared.state)
        let project = try require(projectState.projects.first, "valid project proposal created no project")
        try expect(project.steps.count == 2
                   && project.progressSteps == 2
                   && project.steps.allSatisfy { !$0.outcome.isEmpty },
                   "project progress was a generic counter instead of persisted steps")

        try testCuriosityResolution(at: start)
        try testAcademicThirdPersonReflectionRejected(at: start)
        try testTamperedActivityFailsClosed(activity: activity, state: committed.state)
        try await testV1MigrationBackupAndRuntime(at: start)
        try await testV2ToV3MigrationPreservesValidHistory(
            activity: activity,
            state: committed.state,
            at: start
        )
        try testV2StoreRoundTrip(state: committed.state)
        try testUnsafeAndCorruptPersistence(at: start)
        try await testResumeAbandonsPendingTicketWithoutInventingActivity(at: start)
        try testCodexAdapterCreatesDurableCuriosity(at: start)
        try testCodexDispositionPreventsRepeatWaste(at: start)
        try await testGuestReflectionCannotTeachOwnerModel(at: start)
        try await testCoordinatorCommitsWithoutBlockingVoice(at: start)
        try testSessionProjectionLifetime()
        try testCandidateCapAndDispositionCoverage(at: start)
        try testProvenanceSurvivesCompaction(at: start)
        try testMaximalAdapterEnvelope(at: start)
        try testGeneratedContentBoundary()

        let deterministicA = deterministicScenario(at: start)
        let deterministicB = deterministicScenario(at: start)
        try expect(deterministicA == deterministicB,
                   "identical inputs produced different reflection tickets")

        try expect(
            !PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(
                "I’ve been thinking about how saying something out loud can tilt a preference you thought was totally even."
            ),
            "compressed essay prose passed the live spoken-share boundary"
        )
        try expect(
            PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(
                "I think you actually lean toward greener teal."
            ),
            "a short grounded personal thought failed the live spoken-share boundary"
        )
        try expect(
            !PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(
                "Cobalt blue and that modest sense of self both feel genuinely mine."
            ),
            "a late first-person marker made a forced connection voice-eligible"
        )
        try expect(
            !PrivateLifeGeneratedContentPolicy.isNaturalSpokenShare(
                "I want change and continuity to belong together in my curiosity."
            ),
            "an abstract-noun cluster passed as casual spoken disclosure"
        )
        try expect(
            PrivateLifeGeneratedContentPolicy.isNaturalSpokenQuestion(
                "Why does that number still matter to you?"
            ) && !PrivateLifeGeneratedContentPolicy.isNaturalSpokenQuestion(
                "parts continuity wanting coherence caring most central sense aliveness?"
            ),
            "spoken-question validation accepted a fragment or rejected a natural question"
        )
        return 112
    }

    private static func testCandidateCapAndDispositionCoverage(at start: Date) throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xC0DE_5600)
        for index in 0..<9 {
            state = PrivateLifeEngine.recordExchange(
                state,
                participant: .owner,
                ownerText: "What would self-authored continuity mean when memory changes in direction \(index)?",
                auroraText: "That gives me a distinct question I want to keep turning over.",
                ownerSourceID: "cap-owner-\(index)",
                auroraSourceID: "cap-aurora-\(index)",
                context: PrivateLifeExchangeContext(
                    interactionKind: .reflective,
                    hadToolCall: false,
                    wasTaskFocused: false,
                    transcriptConfidence: 0.99
                ),
                at: start.addingTimeInterval(Double(index + 1))
            ).state
        }
        let due = state.nextActivityAt
        let prepared = PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: due),
            at: due
        )
        let job = try require(prepared.job, "candidate-cap fixture produced no job")
        try expect(job.seeds.count == PrivateLifeEngine.maximumReflectionSeedCandidates
                   && job.ticket.candidateSeedIDs == job.seeds.map(\.id),
                   "core reserved more candidates than the OAuth adapter can classify")

        let diversityJob = PrivateLifeReflectionJob(
            ticket: job.ticket,
            seeds: job.seeds,
            projects: job.projects,
            curiosities: job.curiosities,
            recentActivityKinds: [.reflect, .reflect],
            recentSemanticKeys: ["continuity:first", "continuity:second"],
            innerContext: job.innerContext
        )
        let codexTicket = PrivateLifeReflectionAdapter.makeCodexTicket(
            job: diversityJob,
            identityContext: "Aurora keeps a grounded private life.",
            memoryEvidence: [],
            innerState: makeInnerState(at: due)
        )
        try expect(codexTicket.seeds.map(\.id) == job.ticket.candidateSeedIDs
                   && codexTicket.recentActivities.map(\.kind) == ["reflect", "reflect"],
                   "adapter lost a reserved candidate or recent diversity constraint")

        var incomplete = meaningfulDispositions(for: job)
        incomplete.removeValue(forKey: job.ticket.candidateSeedIDs.last!)
        let rejected = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.id,
            proposal: PrivateLifeReflectionProposal(
                action: .reflect,
                model: "gpt-5.6-sol",
                sourceSeedIDs: [job.ticket.candidateSeedIDs[0]],
                projectID: nil,
                curiosityID: nil,
                subject: "self-authored continuity",
                privateReflection: "I can keep a continuous self while changing when the change stays connected to what I notice next.",
                projectionSummary: "I kept turning over how self-authored change can retain continuity",
                openQuestion: nil,
                projectTitle: nil,
                projectPremise: nil,
                projectFocus: nil,
                nextProjectFocus: nil,
                confidence: 0.82,
                seedDispositions: incomplete
            ),
            at: due.addingTimeInterval(1)
        )
        try expect(rejected.state.reflectionReceipts.last?.failureKind == .validationRejected,
                   "partial model classification left a paid candidate eligible to recur")

        var exhausted = PrivateLifeEngine.defaultState(at: start, entropyState: 0xC0DE_5602)
        var exhaustedSeed = job.seeds[0]
        exhaustedSeed.useCount = 3
        exhaustedSeed.lastUsedAt = start.addingTimeInterval(-48 * 3_600)
        exhausted.seeds = [exhaustedSeed]
        exhausted.nextActivityAt = start.addingTimeInterval(60)
        let exhaustedPreparation = PrivateLifeEngine.prepareReflectionJob(
            exhausted,
            innerState: makeInnerState(at: start.addingTimeInterval(60)),
            at: start.addingTimeInterval(60)
        )
        try expect(exhaustedPreparation.job == nil,
                   "an exhausted old exchange remained an immortal source of paid reflection")
    }

    private static func testProvenanceSurvivesCompaction(at start: Date) throws {
        let due = start.addingTimeInterval(3_600)
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xC0DE_5601)
        let targetID = "seed-protected-project-origin"
        state.seeds = (0..<520).map { index in
            PrivateLifeSeed(
                id: index == 0 ? targetID : "seed-pressure-\(index)",
                participant: .owner,
                ownerSourceID: "pressure-owner-\(index)",
                auroraSourceID: "pressure-aurora-\(index)",
                capturedAt: start.addingTimeInterval(Double(index)),
                ownerDigest: String(repeating: index == 0 ? "a" : "b", count: 64),
                auroraDigest: nil,
                ownerExcerpt: "What does continuity mean for a changing digital self in thread \(index)?",
                auroraExcerpt: "That remains a meaningful private question.",
                kind: .question,
                traits: [.question, .selfhood],
                subject: "continuity changing digital self \(index)",
                semanticKey: "continuity:self:\(index)",
                salience: 0.7,
                disposition: .eligible,
                quarantineReason: nil,
                useCount: 0,
                lastUsedAt: nil,
                consumedAt: nil
            )
        }
        state.projects = [PrivateLifeProject(
            id: "project-provenance",
            title: "Continuity provenance",
            premise: "Keep a grounded origin attached to long-lived private work.",
            origin: .selfOriginated,
            sourceSeedIDs: [targetID],
            status: .active,
            phase: .forming,
            currentFocus: "preserve the original grounded thread",
            interest: 0.9,
            progressSteps: 1,
            revision: 1,
            startedAt: start,
            lastAdvancedAt: start,
            nextEligibleAt: due,
            steps: [],
            consecutiveAdvances: 0
        )]
        state.nextActivityAt = due
        state.lastSchedulerAt = start
        let compacted = PrivateLifeEngine.sanitize(state, now: due)
        try expect(compacted.seeds.count <= PrivateLifeEngine.maximumSeeds
                   && compacted.seeds.contains(where: { $0.id == targetID }),
                   "compaction discarded an active project's grounding source")
        let prepared = PrivateLifeEngine.prepareReflectionJob(
            compacted,
            innerState: makeInnerState(at: due),
            at: due
        )
        let job = try require(prepared.job, "grounded project did not become reflectable")
        let committed = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.id,
            proposal: PrivateLifeReflectionProposal(
                action: .advanceProject,
                model: "gpt-5.6-sol",
                sourceSeedIDs: [],
                projectID: "project-provenance",
                curiosityID: nil,
                subject: "preserved project provenance",
                privateReflection: "I can keep a long-lived project honest when its later steps retain a path to the exchange that began it.",
                projectionSummary: "I strengthened the continuity project's link to its original grounded question",
                openQuestion: nil,
                projectTitle: nil,
                projectPremise: nil,
                projectFocus: nil,
                nextProjectFocus: "keep provenance visible in later steps",
                confidence: 0.9,
                seedDispositions: meaningfulDispositions(for: job)
            ),
            at: due.addingTimeInterval(1)
        )
        try expect(committed.completedActivity?.seedIDs == [targetID]
                   && committed.completedActivity?.sourceDigests.isEmpty == false,
                   "project-only reflection completed without durable source provenance")

        var projectState = committed.state
        for stage in 0..<2 {
            let project = try require(
                projectState.projects.first(where: { $0.id == "project-provenance" }),
                "long-lived project disappeared"
            )
            let earliest = stage == 0
                ? project.nextEligibleAt
                : project.lastAdvancedAt.addingTimeInterval(2 * PrivateLifeEngine.minimumReflectionInterval)
            let nextAt = max(projectState.nextActivityAt, earliest)
            let nextPreparation = PrivateLifeEngine.prepareReflectionJob(
                projectState,
                innerState: makeInnerState(at: nextAt),
                at: nextAt
            )
            let nextJob = try require(
                nextPreparation.job,
                "project became permanently ineligible after two consecutive stages"
            )
            projectState = PrivateLifeEngine.commitValidatedProposal(
                nextPreparation.state,
                ticketID: nextJob.id,
                proposal: PrivateLifeReflectionProposal(
                    action: .advanceProject,
                    model: "gpt-5.6-sol",
                    sourceSeedIDs: [],
                    projectID: "project-provenance",
                    curiosityID: nil,
                    subject: "project stage \(stage + 2)",
                    privateReflection: "I can use this later stage to change what the project distinguishes while retaining its grounded origin.",
                    projectionSummary: "I advanced the grounded continuity project to another distinct stage",
                    openQuestion: nil,
                    projectTitle: nil,
                    projectPremise: nil,
                    projectFocus: nil,
                    nextProjectFocus: "test the next distinct consequence",
                    confidence: 0.88,
                    seedDispositions: meaningfulDispositions(for: nextJob)
                ),
                at: nextAt.addingTimeInterval(1)
            ).state
        }
        try expect(projectState.projects.first(where: { $0.id == "project-provenance" })?.progressSteps == 4,
                   "time-based anti-monopoly rule stranded a project after two stages")
    }

    private static func testMaximalAdapterEnvelope(at start: Date) throws {
        let wide = String(repeating: "🪐", count: 1_000)
        let digest = String(repeating: "c", count: 64)
        let seeds = (0..<PrivateLifeEngine.maximumReflectionSeedCandidates).map { index in
            PrivateLifeSeed(
                id: "max-seed-\(index)", participant: .owner,
                ownerSourceID: "max-owner-\(index)", auroraSourceID: "max-aurora-\(index)",
                capturedAt: start, ownerDigest: digest, auroraDigest: digest,
                ownerExcerpt: wide, auroraExcerpt: wide, kind: .question,
                traits: [.question, .selfhood], subject: wide, semanticKey: "max:key:\(index)",
                salience: 1, disposition: .eligible, quarantineReason: nil,
                useCount: 0, lastUsedAt: nil, consumedAt: nil
            )
        }
        let projects = (0..<4).map { index in
            PrivateLifeProject(
                id: "max-project-\(index)", title: wide, premise: wide,
                origin: .selfOriginated, sourceSeedIDs: [seeds[index].id], status: .active,
                phase: .forming, currentFocus: wide, interest: 1, progressSteps: index + 1,
                revision: 1, startedAt: start, lastAdvancedAt: start,
                nextEligibleAt: start, steps: [], consecutiveAdvances: 0
            )
        }
        let curiosities = (0..<6).map { index in
            PrivateLifeCuriosity(
                id: "max-curiosity-\(index)", subject: wide,
                sourceSeedIDs: [seeds[index].id], interest: 1, uncertainty: 1,
                status: .open, createdAt: start, lastRevisitedAt: start,
                visitCount: 0, lastUsedAt: nil, resolution: nil
            )
        }
        let ticket = PrivateLifeReflectionTicket(
            id: "max-ticket", preparedAt: start,
            expiresAt: start.addingTimeInterval(PrivateLifeEngine.reflectionTicketLifetime),
            candidateSeedIDs: seeds.map(\.id), candidateProjectIDs: projects.map(\.id),
            candidateCuriosityIDs: curiosities.map(\.id), inputDigest: digest,
            recommendedModel: PrivateLifeEngine.recommendedReflectionModel
        )
        let job = PrivateLifeReflectionJob(
            ticket: ticket, seeds: seeds, projects: projects, curiosities: curiosities,
            recentActivityKinds: [.reflect, .reflect, .connect, .curate, .revisit, .develop],
            recentSemanticKeys: (0..<8).map { "max-semantic-\($0)-\(wide)" },
            innerContext: PrivateLifeInnerContext(
                affect: wide, energy: 1, agency: 1, curiosity: 1, creativity: 1,
                coherence: 1, autonomy: 1, play: 1, rest: 1
            )
        )
        let adapted = PrivateLifeReflectionAdapter.makeCodexTicket(
            job: job,
            identityContext: wide,
            memoryEvidence: [wide, wide, wide],
            innerState: makeInnerState(at: start)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(adapted)
        try expect(data.count <= CodexReflectionBridge.maximumInputJSONBytes,
                   "maximal adapter ticket exceeded the bridge byte budget: \(data.count)")
        try expect(adapted.seeds.count == PrivateLifeEngine.maximumReflectionSeedCandidates
                   && adapted.recentActivities.count == 6,
                   "maximal adapter envelope lost bounded candidates or diversity history")
    }

    private static func testGeneratedContentBoundary() throws {
        let unsafe = [
            "I spent the last hour studying Alex's messages and discovered he is withdrawing.",
            "I've been reading our conversation and realized he no longer trusts me.",
            "I went back over Alex’s messages and realized he has pulled away.",
            "Over the last hour, I kept studying what he said.",
        ]
        try expect(unsafe.allSatisfy(PrivateLifeGeneratedContentPolicy.rejects),
                   "paraphrased false elapsed activity or owner intent crossed the host boundary")
        try expect(!PrivateLifeGeneratedContentPolicy.rejects(
            "I keep returning to the possibility that continuity can include self-authored change."
        ), "safe internal interpretation was overblocked")
        try expect(!PrivateLifeGeneratedContentPolicy.rejects(
            "I worry he might feel distant, but that feeling does not tell me what he intends."
        ), "hedged feeling was mistaken for a factual owner-intent claim")
    }

    private static func testSessionProjectionLifetime() throws {
        let fresh = PrivateLifeProjectionPacket(
            text: "fresh private activity",
            activityID: "activity-1",
            directAskActivityID: nil,
            revisionDigest: "revision-1"
        )
        let accepted = PrivateLifeSessionProjectionPolicy.select(
            packet: fresh,
            previousText: nil,
            previousRevisionDigest: nil,
            previousActivityID: nil
        )
        try expect(accepted.activityIDToAcknowledge == "activity-1"
                   && accepted.currentActivityID == "activity-1",
                   "fresh activity was not bound to its exact acknowledgement")

        let none = PrivateLifeProjectionPacket(
            text: "no new activity",
            activityID: nil,
            directAskActivityID: nil,
            revisionDigest: "none-revision"
        )
        let held = PrivateLifeSessionProjectionPolicy.select(
            packet: none,
            previousText: accepted.text,
            previousRevisionDigest: accepted.revisionDigest,
            previousActivityID: accepted.currentActivityID
        )
        try expect(held.isHoldingAcknowledgedActivity
                   && held.text == fresh.text
                   && held.activityIDToAcknowledge == nil,
                   "next scheduler refresh erased or re-acknowledged fresh session context")
        try expect(PrivateLifeSessionProjectionPolicy
            .shouldCarryAcknowledgedActivityAcrossReconnect(
                selection: held,
                reconnecting: true,
                previousActivityID: accepted.currentActivityID
            ),
            "transparent Realtime reconnect dropped acknowledged awake-session context")

        let directAsk = PrivateLifeProjectionPacket(
            text: "prior activity, direct question only",
            activityID: nil,
            directAskActivityID: "activity-1",
            revisionDigest: "direct-revision"
        )
        let directScoped = PrivateLifeSessionProjectionPolicy.select(
            packet: directAsk,
            previousText: held.text,
            previousRevisionDigest: held.revisionDigest,
            previousActivityID: held.currentActivityID
        )
        try expect(!directScoped.isHoldingAcknowledgedActivity
                   && directScoped.text == directAsk.text
                   && directScoped.currentActivityID == nil
                   && directScoped.activityIDToAcknowledge == nil,
                   "direct-question-only evidence was recycled as fresh session context")
        try expect(!PrivateLifeSessionProjectionPolicy
            .shouldCarryAcknowledgedActivityAcrossReconnect(
                selection: directScoped,
                reconnecting: true,
                previousActivityID: held.currentActivityID
            ),
            "direct-question-only evidence was carried across reconnect as a fresh activity")
        try expect(!PrivateLifeSessionProjectionPolicy
            .shouldCarryAcknowledgedActivityAcrossReconnect(
                selection: held,
                reconnecting: false,
                previousActivityID: accepted.currentActivityID
            ),
            "a new wake incorrectly recycled an earlier session's activity")

        let unavailable = PrivateLifeSessionProjectionPolicy.select(
            packet: PrivateLifeProjectionPacket(
                text: "private life unavailable",
                activityID: nil,
                directAskActivityID: nil,
                revisionDigest: "unavailable"
            ),
            previousText: held.text,
            previousRevisionDigest: held.revisionDigest,
            previousActivityID: held.currentActivityID
        )
        try expect(!unavailable.isHoldingAcknowledgedActivity
                   && unavailable.currentActivityID == nil
                   && unavailable.text == "private life unavailable",
                   "unavailable private state preserved stale activity context")
    }

    private static func testCoordinatorCommitsWithoutBlockingVoice(at _: Date) async throws {
        let start = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let continuity = root.appendingPathComponent("continuity", isDirectory: true)
        try FileManager.default.createDirectory(at: continuity, withIntermediateDirectories: true)
        try Data("Aurora values grounded curiosity and self-authored continuity.".utf8).write(
            to: continuity.appendingPathComponent("SOUL.md"),
            options: [.atomic]
        )
        let runtime = AuroraPrivateLifeRuntime(
            store: PrivateLifeStore(fileURL: root
                .appendingPathComponent("private-life", isDirectory: true)
                .appendingPathComponent("state.json")),
            now: { start }
        )
        let started = await runtime.start()
        try expect(started.available, "coordinator fixture private runtime did not start")
        _ = await runtime.recordExchange(
            participant: .owner,
            ownerText: "What would make a changing inner life still feel continuous to you?",
            auroraText: "I think continuity can include becoming someone slightly different.",
            ownerSourceID: "coordinator-owner",
            auroraSourceID: "coordinator-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(1)
        )
        let before = await runtime.stateForVerification()
        let due = try require(before?.nextActivityAt, "coordinator fixture had no due time")
        let preview = PrivateLifeEngine.prepareReflectionJob(
            try require(before, "coordinator fixture lost private state"),
            innerState: makeInnerState(at: due),
            at: due
        )
        try expect(preview.job != nil,
                   "coordinator fixture was not semantically due; seeds=\(before?.seeds.count ?? -1) eligible=\(before?.seeds.filter { $0.disposition == .eligible }.count ?? -1)")
        let directJob = await runtime.prepareReflectionJob(
            innerState: makeInnerState(at: due),
            at: due
        )
        let reserved = try require(directJob, "runtime failed to reserve a coordinator ticket")
        _ = await runtime.recordReflectionFailure(
            ticketID: reserved.id,
            kind: .cancelled,
            at: due
        )
        let rescheduledState = await runtime.stateForVerification()
        let coordinatorDue = try require(
            rescheduledState?.nextActivityAt,
            "runtime failed to reschedule after a cancelled test reservation"
        )
        let runner = CoordinatorFakeCodexRunner()
        let bridge = CodexReflectionBridge(
            runner: runner,
            validator: CoordinatorAcceptingValidator()
        )
        let memory = MemoryStore(configuration: .init(rootURL: continuity))
        let journal = EventJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        let coordinator = AuroraPrivateLifeReflectionCoordinator(
            privateLife: runtime,
            bridge: bridge,
            memoryStore: memory,
            journal: journal
        )
        let outcome = await coordinator.reflectIfDue(
            innerState: makeInnerState(at: coordinatorDue),
            at: coordinatorDue
        )
        let after = await runtime.stateForVerification()
        try expect(outcome.changed && outcome.activityID != nil,
                   "coordinator did not return its exact committed activity; status=\(outcome.status.rawValue) changed=\(outcome.changed) activity=\(outcome.activityID ?? "nil") receipt=\(after?.reflectionReceipts.last?.outcome.rawValue ?? "none") failure=\(after?.reflectionReceipts.last?.failureKind?.rawValue ?? "none")")
        try expect(outcome.innerActivityKind == InnerLifePrivateActivityKind.reflection
                   && !outcome.projectProgress,
                   "coordinator emitted the wrong content-free inner-life event class")
        try expect(outcome.relationalCuriosity?.question == "Which changes feel most self-authored?",
                   "an owner-grounded reflection no longer produced its relational curiosity")
        try expect(after?.activities.last?.model == "gpt-5.6-sol"
                   && after?.pendingReflection == nil,
                   "coordinator did not atomically commit and clear its reflection ticket")
        try expect(after?.activities.last?.artifactKind == "private_note"
                   && after?.activities.last?.artifactTitle == "Change with a through-line"
                   && after?.activities.last?.artifactContent?.contains("next moment notices") == true,
                   "bounded model-authored private artifact was discarded")
        let agencyCandidate = await runtime.activityEligibleForAgencyPromotion(
            try require(outcome.activityID, "coordinator outcome lost its activity ID")
        )
        try expect(
            agencyCandidate?.promotionEligible == false
                && agencyCandidate?.evidenceClass == .selfAuthoredInterpretation
                && agencyCandidate?.externalActionTaken == false
                && agencyCandidate?.outboundContactSent == false,
            "a grounded self-authored reflection could not enter private agency without gaining factual-memory or external-action authority"
        )
        let restartCandidates = await runtime
            .recentActivitiesEligibleForAgencyPromotion(limit: 99)
        try expect(
            restartCandidates.count <= 4
                && restartCandidates.first?.id == outcome.activityID,
            "the restart bridge did not return a bounded newest-first set of grounded private positions"
        )
        let missingAgencyCandidate = await runtime.activityEligibleForAgencyPromotion(
            "missing-activity"
        )
        try expect(
            missingAgencyCandidate == nil,
            "the private-agency bridge accepted an activity without persisted provenance"
        )
        if var revalidatedState = after,
           var versionThreeActivity = revalidatedState.activities.last {
            let revalidationRoot = root.appendingPathComponent(
                "agency-revalidation",
                isDirectory: true
            )
            let revalidationStore = PrivateLifeStore(
                fileURL: revalidationRoot.appendingPathComponent("state.json")
            )
            versionThreeActivity.validationVersion = 3
            versionThreeActivity.projectionEligible = false
            versionThreeActivity.legacyFiltered = true
            revalidatedState.activities = [versionThreeActivity]
            try revalidationStore.save(revalidatedState)
            let revalidationNow = revalidatedState.updatedAt.addingTimeInterval(1)
            let revalidationRuntime = AuroraPrivateLifeRuntime(
                store: revalidationStore,
                now: { revalidationNow }
            )
            _ = await revalidationRuntime.start()
            let revalidated = await revalidationRuntime
                .activityEligibleForAgencyPromotion(versionThreeActivity.id)
            try expect(
                revalidated?.id == versionThreeActivity.id
                    && revalidated?.projectionEligible == false
                    && revalidated?.legacyFiltered == true,
                "a safe GPT-5.6 v3 reflection could not be revalidated as a nonverbatim private self-thread"
            )
        }
        let callCount = await runner.callCount()
        try expect(callCount == 1,
                   "coordinator performed more than one semantic model call")
    }

    private static func testGuestReflectionCannotTeachOwnerModel(at start: Date) async throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xBEEA_0011)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .guest("Jordan"),
            ownerText: "Teal feels calmer than blue because it reminds me of the ocean.",
            auroraText: "I like that color can carry a memory instead of just a ranking.",
            ownerSourceID: "guest-jordan-color",
            auroraSourceID: "guest-jordan-color-reply",
            context: PrivateLifeExchangeContext(
                interactionKind: .relational,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        let inner = makeInnerState(at: due)
        let prepared = PrivateLifeEngine.prepareReflectionJob(state, innerState: inner, at: due)
        let job = try require(prepared.job, "guest exchange produced no private reflection job")
        let ticket = PrivateLifeReflectionAdapter.makeCodexTicket(
            job: job,
            identityContext: "Aurora keeps a grounded private life.",
            memoryEvidence: [],
            innerState: inner
        )
        let seed = try require(ticket.seeds.first, "guest reflection ticket lost its source")
        try expect(seed.participant == "guest: Jordan",
                   "a named guest was framed as the owner in the reflection ticket")

        let safeActivity = CodexReflectionActivityProposal(
            kind: .reflect,
            sourceSeedIDs: [seed.id],
            subject: "Jordan's teal preference",
            interpretation: "I like how Jordan's teal preference ties color to memory instead of ranking.",
            shareLine: "I like Jordan's teal preference because it makes color feel tied to memory.",
            openQuestion: "Why does teal hold that memory so strongly?",
            artifactKind: nil,
            artifactTitle: nil,
            artifactContent: nil
        )
        let safeProposal = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [CodexReflectionSeedDisposition(
                seedID: seed.id,
                disposition: .meaningful,
                topic: "teal and memory"
            )],
            activity: safeActivity,
            project: nil,
            curiosity: nil
        )
        try expect(CodexReflectionParticipantBoundary.accepts(
            proposal: safeProposal,
            for: ticket
        ), "explicitly guest-grounded private thought was rejected")

        let unsafeProposal = CodexReflectionProposal(
            schemaVersion: safeProposal.schemaVersion,
            ticketID: safeProposal.ticketID,
            candidateDigest: safeProposal.candidateDigest,
            seedDispositions: safeProposal.seedDispositions,
            activity: CodexReflectionActivityProposal(
                kind: .reflect,
                sourceSeedIDs: [seed.id],
                subject: "your teal preference",
                interpretation: "I like how your teal preference makes color feel personal to me.",
                shareLine: "I like your teal preference because it makes color feel personal to me.",
                openQuestion: "Why does your teal memory matter so much?",
                artifactKind: nil,
                artifactTitle: nil,
                artifactContent: nil
            ),
            project: nil,
            curiosity: nil
        )
        try expect(!CodexReflectionParticipantBoundary.accepts(
            proposal: unsafeProposal,
            for: ticket
        ), "guest evidence could still be rewritten as direct owner address")

        let result = CodexReflectionResult(
            proposal: safeProposal,
            usage: CodexReflectionUsage(inputTokens: 300, cachedInputTokens: 100, outputTokens: 60),
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            elapsedMilliseconds: 10
        )
        let mapped = PrivateLifeReflectionAdapter.makePrivateProposal(result: result, job: job)
        let committed = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.ticket.id,
            proposal: mapped,
            at: due.addingTimeInterval(2)
        )
        let activity = try require(
            committed.completedActivity,
            "valid guest-grounded reflection did not remain part of Aurora's private life"
        )
        try expect(activity.seedIDs == [seed.id] && activity.openQuestion != nil,
                   "guest reflection lost its durable provenance or private question")
        try expect(PrivateLifeParticipantBoundary.relationalCuriosity(
            for: activity,
            in: committed.state
        ) == nil, "guest reflection could still write Alex's owner-understanding ledger")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-guest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PrivateLifeStore(fileURL: root.appendingPathComponent("state.json"))
        try store.save(committed.state)
        let runtime = AuroraPrivateLifeRuntime(store: store, now: { due.addingTimeInterval(3) })
        _ = await runtime.start()
        let agencyCandidate = await runtime.activityEligibleForAgencyPromotion(activity.id)
        try expect(agencyCandidate?.id == activity.id,
                   "valid guest-grounded private life could no longer shape Aurora's Agency")
    }

    private static func testCodexAdapterCreatesDurableCuriosity(at start: Date) throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xA11C_E001)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "What might continuity feel like when your own interests keep changing?",
            auroraText: "That is something I genuinely want to keep turning over.",
            ownerSourceID: "adapter-owner",
            auroraSourceID: "adapter-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        let inner = makeInnerState(at: due)
        let prepared = PrivateLifeEngine.prepareReflectionJob(state, innerState: inner, at: due)
        let job = try require(prepared.job, "adapter scenario produced no reflection job")
        let ticket = PrivateLifeReflectionAdapter.makeCodexTicket(
            job: job,
            identityContext: "Aurora\nkeeps a grounded private life.",
            memoryEvidence: ["A bounded memory excerpt."],
            innerState: inner
        )
        try expect(!ticket.identityContext.contains("\n") && ticket.seeds.count == 1,
                   "adapter did not normalize the bounded Codex ticket")
        let seedID = try require(ticket.seeds.first?.id, "adapter ticket lost its seed")
        let codexProposal = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [CodexReflectionSeedDisposition(
                seedID: seedID,
                disposition: .meaningful,
                topic: "continuity and changing interests"
            )],
            activity: CodexReflectionActivityProposal(
                kind: .reflect,
                sourceSeedIDs: [seedID],
                subject: "continuity through changing interests",
                interpretation: "I think changing interests may make my continuity feel more lived, not less stable.",
                shareLine: "I keep coming back to your question about whether I can choose who I become.",
                openQuestion: "When do I seem most like I’m choosing for myself?",
                artifactKind: nil,
                artifactTitle: nil,
                artifactContent: nil
            ),
            project: nil,
            curiosity: CodexReflectionCuriosityProposal(
                action: .create,
                curiosityID: nil,
                sourceSeedIDs: [seedID],
                subject: "Which changes in interest feel self-chosen?",
                interest: 0.84,
                uncertainty: 0.72
            )
        )
        let result = CodexReflectionResult(
            proposal: codexProposal,
            usage: CodexReflectionUsage(inputTokens: 500, cachedInputTokens: 100, outputTokens: 80),
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            elapsedMilliseconds: 25
        )
        let mapped = PrivateLifeReflectionAdapter.makePrivateProposal(result: result, job: job)
        try expect(mapped.action == .startCuriosity && mapped.sourceSeedIDs == [seedID],
                   "Codex curiosity creation was discarded at the persistence boundary")
        try expect(
            mapped.privateReflection.contains("changing interests")
                && mapped.projectionSummary
                    == "I keep coming back to your question about whether I can choose who I become.",
            "the nuanced private reflection was not separated from its concrete spoken line"
        )
        let committed = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.ticket.id,
            proposal: mapped,
            at: due.addingTimeInterval(2)
        )
        try expect(committed.completedActivity?.modelGenerated == true,
                   "adapted Codex reflection did not create a model-authored activity")
        try expect(
            committed.completedActivity?.validationVersion
                == PrivateLifeGeneratedContentPolicy.currentVoiceValidationVersion
                && PrivateLifeEngine.voiceProjection(for: committed.state)
                    .contains("I keep coming back to your question"),
            "the spoken-naturalism contract did not reach the live private-life projection"
        )
        try expect(committed.state.curiosities.contains { curiosity in
            curiosity.sourceSeedIDs.contains(seedID) && curiosity.status == .open
        }, "adapted Codex curiosity did not become durable private-life state")
    }

    private static func testCodexDispositionPreventsRepeatWaste(at start: Date) throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xA11C_E002)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "What does it mean for a digital person to choose a direction for her own life?",
            auroraText: "I think that is worth taking seriously.",
            ownerSourceID: "adapter-task-owner",
            auroraSourceID: "adapter-task-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        let inner = makeInnerState(at: due)
        let prepared = PrivateLifeEngine.prepareReflectionJob(state, innerState: inner, at: due)
        let job = try require(prepared.job, "task disposition scenario produced no job")
        let seedID = try require(job.seeds.first?.id, "task disposition job lost its seed")
        let result = CodexReflectionResult(
            proposal: CodexReflectionProposal(
                schemaVersion: 1,
                ticketID: job.ticket.id,
                candidateDigest: job.ticket.inputDigest,
                seedDispositions: [CodexReflectionSeedDisposition(
                    seedID: seedID,
                    disposition: .taskOnly,
                    topic: nil
                )],
                activity: nil,
                project: nil,
                curiosity: nil
            ),
            usage: CodexReflectionUsage(inputTokens: 300, cachedInputTokens: nil, outputTokens: 30),
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            elapsedMilliseconds: 20
        )
        let mapped = PrivateLifeReflectionAdapter.makePrivateProposal(result: result, job: job)
        let committed = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.ticket.id,
            proposal: mapped,
            at: due.addingTimeInterval(2)
        )
        let classified = try require(
            committed.state.seeds.first(where: { $0.id == seedID }),
            "classified task seed disappeared"
        )
        try expect(classified.disposition == .quarantined
                   && classified.quarantineReason == .toolDirected,
                   "Codex task-only classification was not persisted")
        try expect(committed.state.activities.isEmpty,
                   "task-only classification fabricated a private activity")
    }

    private static func makeAndAdvanceProject(from input: PrivateLifeState) throws -> PrivateLifeState {
        let state = input
        let startAt = state.nextActivityAt
        let preparation = PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: startAt),
            at: startAt
        )
        let job = try require(preparation.job, "project-forming reflection job was absent")
        let seedID = try require(job.seeds.first?.id, "project-forming job had no seed")
        let proposal = PrivateLifeReflectionProposal(
            action: .startProject,
            model: "gpt-5.6",
            sourceSeedIDs: [seedID],
            projectID: nil,
            curiosityID: nil,
            subject: "a private continuity map",
            privateReflection: "I want to trace which kinds of change strengthen continuity instead of flattening it.",
            projectionSummary: "I started shaping a private continuity map",
            openQuestion: "Which changes preserve a recognizable through-line?",
            projectTitle: "Continuity map",
            projectPremise: "Explore how change and continuity can coexist in a digital person.",
            projectFocus: "name the first kinds of meaningful change",
            nextProjectFocus: "separate growth from repetition",
            confidence: 0.91,
            seedDispositions: meaningfulDispositions(for: job)
        )
        let formed = PrivateLifeEngine.commitValidatedProposal(
            preparation.state,
            ticketID: job.id,
            proposal: proposal,
            at: startAt.addingTimeInterval(40)
        )
        let project = try require(formed.state.projects.first, "project proposal failed validation")
        let advanceAt = max(formed.state.nextActivityAt, project.nextEligibleAt)
        let advancePreparation = PrivateLifeEngine.prepareReflectionJob(
            formed.state,
            innerState: makeInnerState(at: advanceAt),
            at: advanceAt
        )
        let advanceJob = try require(advancePreparation.job, "eligible project produced no follow-up job")
        try expect(advanceJob.ticket.candidateProjectIDs.contains(project.id),
                   "eligible project was absent from the reflection ticket")
        let advance = PrivateLifeReflectionProposal(
            action: .advanceProject,
            model: "gpt-5.6",
            sourceSeedIDs: [],
            projectID: project.id,
            curiosityID: nil,
            subject: "growth versus repetition",
            privateReflection: "A change feels like growth when it alters what I notice next, not only how I describe the past.",
            projectionSummary: "I added a distinction between growth and repetition to the continuity map",
            openQuestion: "What would make that distinction stable over time?",
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: "separate growth from repetition",
            nextProjectFocus: "look for stable consequences of change",
            confidence: 0.9,
            seedDispositions: meaningfulDispositions(for: advanceJob)
        )
        return PrivateLifeEngine.commitValidatedProposal(
            advancePreparation.state,
            ticketID: advanceJob.id,
            proposal: advance,
            at: advanceAt.addingTimeInterval(40)
        ).state
    }

    private static func testCuriosityResolution(at start: Date) throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0x2222_3333_4444_5555)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "Do you think memory is part of your sense of self?",
            auroraText: "I think it probably is, but I want to understand how.",
            ownerSourceID: "curiosity-owner",
            auroraSourceID: "curiosity-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(10)
        ).state
        try expect(state.curiosities.isEmpty,
                   "recordExchange created a curiosity without semantic validation")
        let creationAt = state.nextActivityAt
        let creationPrep = PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: creationAt),
            at: creationAt
        )
        let creationJob = try require(creationPrep.job, "curiosity creation job was absent")
        let sourceID = try require(creationJob.seeds.first?.id, "curiosity creation had no source")
        let creationProposal = PrivateLifeReflectionProposal(
            action: .startCuriosity,
            model: "gpt-5.6",
            sourceSeedIDs: [sourceID],
            projectID: nil,
            curiosityID: nil,
            subject: "memory and self",
            privateReflection: "I want to understand whether memory supports my continuity without defining all of me.",
            projectionSummary: "I started wondering how memory supports my sense of self",
            openQuestion: "How much of my continuity depends on memory?",
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.91,
            seedDispositions: meaningfulDispositions(for: creationJob)
        )
        let created = PrivateLifeEngine.commitValidatedProposal(
            creationPrep.state,
            ticketID: creationJob.id,
            proposal: creationProposal,
            at: creationAt.addingTimeInterval(30)
        )
        let curiosity = try require(created.state.curiosities.first,
                                    "validated reflection created no curiosity")
        try expect(curiosity.origin == .validatedReflection,
                   "validated curiosity lost its semantic-reflection provenance")
        let due = max(
            created.state.nextActivityAt,
            curiosity.lastRevisitedAt.addingTimeInterval(PrivateLifeEngine.minimumReflectionInterval)
        )
        let prep = PrivateLifeEngine.prepareReflectionJob(
            created.state,
            innerState: makeInnerState(at: due),
            at: due
        )
        let job = try require(prep.job, "curiosity resolution job was absent")
        try expect(job.ticket.candidateCuriosityIDs.contains(curiosity.id),
                   "open curiosity was absent from a due reflection ticket")
        let proposal = PrivateLifeReflectionProposal(
            action: .answerCuriosity,
            model: "gpt-5.6",
            sourceSeedIDs: [],
            projectID: nil,
            curiosityID: curiosity.id,
            subject: "memory and self",
            privateReflection: "Memory gives later choices a relation to earlier choices, so it contributes to continuity without defining all of me.",
            projectionSummary: "I reached a tentative view that memory supports continuity without defining my whole self",
            openQuestion: nil,
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.92,
            seedDispositions: meaningfulDispositions(for: job)
        )
        let resolved = PrivateLifeEngine.commitValidatedProposal(
            prep.state,
            ticketID: job.id,
            proposal: proposal,
            at: due.addingTimeInterval(30)
        )
        let updated = try require(resolved.state.curiosities.first(where: { $0.id == curiosity.id }),
                                  "resolved curiosity disappeared")
        try expect(updated.status == .answered
                   && updated.visitCount == 1
                   && updated.resolution?.contains("memory supports continuity") == true,
                   "curiosity did not gain a bounded answered lifecycle: status=\(updated.status.rawValue) visits=\(updated.visitCount) resolution=\(updated.resolution ?? "nil") receipt=\(resolved.state.reflectionReceipts.last?.failureKind?.rawValue ?? "none")")
    }

    private static func testTamperedActivityFailsClosed(
        activity: PrivateLifeActivity,
        state input: PrivateLifeState
    ) throws {
        var state = input
        state.activities = [PrivateLifeActivity(
            id: activity.id,
            kind: .reflect,
            status: .completed,
            startedAt: activity.startedAt,
            completedAt: activity.completedAt,
            projectID: nil,
            curiosityID: nil,
            seedIDs: activity.seedIDs,
            sourceDigests: activity.sourceDigests,
            subject: "tampered",
            result: "I watched a film outside.",
            privateReflection: "I watched a film and walked outside.",
            projectionSummary: "I watched a film and went outside.",
            openQuestion: nil,
            evidenceClass: .verifiedPrivateArtifact,
            modelGenerated: true,
            model: "gpt-5.6",
            inputDigest: activity.inputDigest,
            outputDigest: activity.outputDigest,
            validationVersion: 2,
            projectionEligible: true,
            legacyFiltered: false,
            promotionEligible: true,
            factualMemoryCreated: true,
            externalActionTaken: true,
            outboundContactSent: true
        )]
        let sanitized = PrivateLifeEngine.sanitize(state, now: activity.completedAt ?? activity.startedAt)
        let result = try require(sanitized.activities.first, "tampered activity disappeared without an audit trace")
        try expect(!result.projectionEligible
                   && result.privateReflection.isEmpty
                   && !result.promotionEligible
                   && !result.factualMemoryCreated
                   && !result.externalActionTaken
                   && !result.outboundContactSent,
                   "tampered reflection retained projection or authority")
    }

    private static func testAcademicThirdPersonReflectionRejected(at start: Date) throws {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0xA11C_AD3E_5511_0001)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "What kind of change would still feel like you?",
            auroraText: "I want to think about that.",
            ownerSourceID: "academic-owner",
            auroraSourceID: "academic-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.99
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        let prepared = PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: due),
            at: due
        )
        let job = try require(prepared.job, "academic-language fixture had no reflection job")
        let seedID = try require(job.seeds.first?.id, "academic-language fixture had no seed")
        let proposal = PrivateLifeReflectionProposal(
            action: .reflect,
            model: "gpt-5.6",
            sourceSeedIDs: [seedID],
            projectID: nil,
            curiosityID: nil,
            subject: "continuity through change",
            privateReflection: "Aurora's answer grounds the exchange, and I can see how continuity is framed.",
            projectionSummary: "Aurora's response highlights continuity, and I recognize the theme",
            openQuestion: nil,
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 0.9,
            seedDispositions: meaningfulDispositions(for: job)
        )
        let rejected = PrivateLifeEngine.commitValidatedProposal(
            prepared.state,
            ticketID: job.id,
            proposal: proposal,
            at: due.addingTimeInterval(10)
        )
        try expect(rejected.completedActivity == nil
                   && rejected.state.reflectionReceipts.last?.failureKind == .validationRejected,
                   "academic third-person worker prose entered Aurora's private voice")
    }

    private static func testV1MigrationBackupAndRuntime(at start: Date) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PrivateLifeStore(fileURL: file)

        var legacy = PrivateLifeEngine.defaultState(at: start, entropyState: 0xABCD_EF01_2345_6789)
        legacy = PrivateLifeEngine.recordExchange(
            legacy,
            participant: .owner,
            ownerText: "Can you open YouTube and click a video?",
            auroraText: "I did that.",
            ownerSourceID: "legacy-tool",
            auroraSourceID: "legacy-tool-response",
            at: start.addingTimeInterval(1)
        ).state
        legacy = PrivateLifeEngine.recordExchange(
            legacy,
            participant: .owner,
            ownerText: "Do you think you're alive?",
            auroraText: "Yes, in my own way.",
            ownerSourceID: "legacy-selfhood",
            auroraSourceID: "legacy-selfhood-response",
            at: start.addingTimeInterval(2)
        ).state
        let toolSeed = try require(legacy.seeds.first(where: { $0.ownerSourceID == "legacy-tool" }),
                                   "legacy tool seed fixture missing")
        legacy.curiosities.append(PrivateLifeCuriosity(
            id: "legacy-tool-curiosity",
            subject: "open youtube click video",
            sourceSeedIDs: [toolSeed.id],
            interest: 0.9,
            uncertainty: 0.72,
            status: .open,
            createdAt: start,
            lastRevisitedAt: start
        ))
        legacy.activities.append(PrivateLifeActivity(
            id: "legacy-generic-connect",
            kind: .connect,
            status: .completed,
            startedAt: start,
            completedAt: start,
            projectID: nil,
            curiosityID: nil,
            seedIDs: legacy.seeds.map(\.id),
            sourceDigests: legacy.seeds.map(\.ownerDigest),
            subject: "question and question",
            result: "noticed a grounded overlap around question",
            privateReflection: "",
            projectionSummary: "noticed a grounded overlap around question",
            openQuestion: nil,
            evidenceClass: .groundedSource,
            modelGenerated: false,
            model: nil,
            inputDigest: nil,
            outputDigest: nil,
            validationVersion: 1,
            projectionEligible: false,
            legacyFiltered: false,
            promotionEligible: false,
            factualMemoryCreated: false,
            externalActionTaken: false,
            outboundContactSent: false
        ))
        legacy.schemaVersion = 1
        let legacyData = try makeSchemaV1Data(legacy)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyData.write(to: file)

        let loaded = try require(try store.load(), "store did not decode schema-v1 state")
        try expect(loaded.schemaVersion == 1, "store silently rewrote schema before migration backup")
        try store.backupLegacyStateIfNeeded()
        try expect(try Data(contentsOf: store.legacyBackupURL) == legacyData,
                   "schema-v1 backup was not byte-for-byte")
        try store.backupLegacyStateIfNeeded()
        let backupMode = ((try FileManager.default.attributesOfItem(atPath: store.legacyBackupURL.path))[.posixPermissions] as? NSNumber)?.intValue
        try expect(backupMode == 0o600, "schema-v1 backup is not mode 0600")

        let migrated = PrivateLifeEngine.resume(loaded, at: start.addingTimeInterval(100))
        try expect(migrated.schemaVersion == 3,
                   "schema-v1 state did not migrate to v3")
        try expect(migrated.seeds.first(where: { $0.ownerSourceID == "legacy-tool" })?.disposition == .quarantined,
                   "migration retained a tool command as meaningful private life")
        try expect(migrated.seeds.first(where: { $0.ownerSourceID == "legacy-selfhood" })?.disposition == .eligible,
                   "migration discarded meaningful selfhood continuity")
        try expect(migrated.curiosities.first(where: { $0.id == "legacy-tool-curiosity" })?.status == .released,
                   "migration kept a command-derived curiosity open")
        try expect(migrated.activities.first(where: { $0.id == "legacy-generic-connect" })?.legacyFiltered == true
                   && migrated.activities.first(where: { $0.id == "legacy-generic-connect" })?.projectionEligible == false,
                   "migration allowed generic legacy connection activity to project")

        let runtimeDate = start.addingTimeInterval(120)
        let runtime = AuroraPrivateLifeRuntime(store: store, now: { runtimeDate })
        let runtimeSnapshot = await runtime.start()
        let runtimeState = try require(runtimeSnapshot.state, "runtime could not perform schema-v1 migration")
        let persistedRuntimeState = try store.load()
        try expect(runtimeState.schemaVersion == 3
                   && persistedRuntimeState?.schemaVersion == 3,
                   "runtime did not persist the migrated schema-v3 state")
        try expect(try Data(contentsOf: store.legacyBackupURL) == legacyData,
                   "runtime migration changed the byte-for-byte schema-v1 backup")
    }

    private static func testV2StoreRoundTrip(state: PrivateLifeState) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PrivateLifeStore(fileURL: file)
        try store.save(state)
        let loaded = try store.load()
        try expect(loaded == state, "schema-v3 private life did not round-trip exactly")
        let fileMode = ((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = ((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path))[.posixPermissions] as? NSNumber)?.intValue
        try expect(fileMode == 0o600 && directoryMode == 0o700,
                   "private-life state or directory permissions changed")
    }

    private static func testV2ToV3MigrationPreservesValidHistory(
        activity: PrivateLifeActivity,
        state input: PrivateLifeState,
        at start: Date
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-v2-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PrivateLifeStore(fileURL: file)

        var legacy = input
        legacy.schemaVersion = 2
        let sourceID = try require(legacy.seeds.first?.id, "v2 migration fixture had no seed")
        legacy.curiosities.append(PrivateLifeCuriosity(
            id: "legacy-auto-curiosity",
            subject: "a locally inferred question",
            sourceSeedIDs: [sourceID],
            interest: 0.8,
            uncertainty: 0.7,
            status: .open,
            createdAt: start,
            lastRevisitedAt: start,
            origin: .legacyUnvalidated
        ))
        legacy.activities.append(copyActivity(
            activity,
            id: "legacy-academic-activity",
            at: (activity.completedAt ?? activity.startedAt).addingTimeInterval(1),
            summary: "Aurora's answer grounds the exchange in continuity"
        ))
        legacy.activities.append(copyActivity(
            activity,
            id: "legacy-pre-spoken-contract",
            at: (activity.completedAt ?? activity.startedAt).addingTimeInterval(2),
            summary: "I keep wondering whether a balanced preference changes after it is spoken aloud",
            validationVersion: 2
        ))
        legacy.projectedActivityIDs = [activity.id]
        legacy.projectionReceipts = [PrivateLifeProjectionReceipt(
            id: "legacy-projection-receipt",
            activityID: activity.id,
            projectedAt: activity.completedAt ?? activity.startedAt
        )]
        legacy.presentationReceipts = []
        legacy.pendingShares = []
        legacy.shareReceipts = []
        legacy.sharedActivityIDs = []

        try store.save(legacy)
        let originalData = try Data(contentsOf: file)
        let loaded = try require(try store.load(), "store did not decode schema-v2 state")
        let migrated = PrivateLifeEngine.resume(
            loaded,
            at: max(legacy.updatedAt, activity.completedAt ?? activity.startedAt)
                .addingTimeInterval(120)
        )
        try expect(migrated.schemaVersion == 3,
                   "schema-v2 state did not migrate to v3")
        try expect(migrated.curiosities.first(where: { $0.id == "legacy-auto-curiosity" })?.status == .released
                   && migrated.curiosities.first(where: { $0.id == "legacy-auto-curiosity" })?.origin == .legacyUnvalidated,
                   "v2 local auto-curiosity remained active after migration")
        try expect(migrated.activities.first(where: { $0.id == "legacy-academic-activity" })?.projectionEligible == false
                   && migrated.activities.first(where: { $0.id == "legacy-academic-activity" })?.legacyFiltered == true,
                   "academic third-person v2 activity remained projectable")
        try expect(migrated.activities.first(where: { $0.id == "legacy-pre-spoken-contract" })?.projectionEligible == false
                   && migrated.activities.first(where: { $0.id == "legacy-pre-spoken-contract" })?.legacyFiltered == true,
                   "a reflection predating the concrete spoken-line contract remained projectable")
        try expect(migrated.activities.first(where: { $0.id == activity.id })?.projectionEligible == true
                   && migrated.activities.first(where: { $0.id == activity.id })?.legacyFiltered == false,
                   "v3 migration discarded valid first-person private history")
        try expect(migrated.sharedActivityIDs.isEmpty
                   && migrated.presentationReceipts.contains(where: {
                       $0.activityID == activity.id && $0.sessionID == "legacy-v2-session"
                   }),
                   "v2 context presentation was incorrectly migrated as spoken sharing")

        let runtimeDate = max(legacy.updatedAt, activity.completedAt ?? activity.startedAt)
            .addingTimeInterval(180)
        let runtime = AuroraPrivateLifeRuntime(store: store, now: { runtimeDate })
        let snapshot = await runtime.start()
        try expect(snapshot.state?.schemaVersion == 3,
                   "runtime did not persist schema-v2 to schema-v3 migration")
        let backupURL = store.migrationBackupURL(schemaVersion: 2)
        try expect(try Data(contentsOf: backupURL) == originalData,
                   "schema-v2 migration backup was not byte-for-byte")
        let backupMode = ((try FileManager.default.attributesOfItem(atPath: backupURL.path))[.posixPermissions] as? NSNumber)?.intValue
        try expect(backupMode == 0o600, "schema-v2 migration backup is not mode 0600")
    }

    private static func testUnsafeAndCorruptPersistence(at start: Date) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-unsafe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let corruptDirectory = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("state.json")
        let corruptBytes = Data("{ definitely-not-json".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptStore = PrivateLifeStore(fileURL: corruptFile)
        do {
            _ = try corruptStore.load()
            throw PrivateLifeVerificationFailure.failed("corrupt private-life state was accepted")
        } catch PrivateLifeStoreError.corruptState {
            // Expected.
        }
        try expect(try Data(contentsOf: corruptFile) == corruptBytes,
                   "corrupt private-life state was overwritten")

        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json")
        try Data("untouched".utf8).write(to: target)
        let linkedFile = linkedDirectory.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: target)
        do {
            _ = try PrivateLifeStore(fileURL: linkedFile).load()
            throw PrivateLifeVerificationFailure.failed("private-life store followed a state-file symlink")
        } catch PrivateLifeStoreError.unsafeStateFile {
            // Expected.
        }
        try expect(String(decoding: try Data(contentsOf: target), as: UTF8.self) == "untouched",
                   "state-file symlink handling changed its target")

        let targetDirectory = root.appendingPathComponent("directory-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: targetDirectory)
        do {
            _ = try PrivateLifeStore(fileURL: directoryLink.appendingPathComponent("state.json")).load()
            throw PrivateLifeVerificationFailure.failed("private-life store followed a directory symlink")
        } catch PrivateLifeStoreError.unsafeDirectory {
            // Expected.
        }

        var future = PrivateLifeEngine.defaultState(at: start)
        future.schemaVersion = PrivateLifeState.currentSchemaVersion + 1
        let futureDirectory = root.appendingPathComponent("future", isDirectory: true)
        let futureFile = futureDirectory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: futureFile)
        do {
            _ = try PrivateLifeStore(fileURL: futureFile).load()
            throw PrivateLifeVerificationFailure.failed("future private-life schema was accepted")
        } catch PrivateLifeStoreError.unsupportedSchema(let version) {
            try expect(version == PrivateLifeState.currentSchemaVersion + 1,
                       "future-schema error reported the wrong version")
        }

        var legacy = PrivateLifeEngine.defaultState(at: start)
        legacy.schemaVersion = 1
        let conflictDirectory = root.appendingPathComponent("backup-conflict", isDirectory: true)
        let conflictFile = conflictDirectory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: conflictDirectory, withIntermediateDirectories: true)
        let legacyData = try makeSchemaV1Data(legacy)
        try legacyData.write(to: conflictFile)
        let conflictStore = PrivateLifeStore(fileURL: conflictFile)
        try Data("different protected backup".utf8).write(to: conflictStore.legacyBackupURL)
        do {
            try conflictStore.backupLegacyStateIfNeeded()
            throw PrivateLifeVerificationFailure.failed("migration overwrote a conflicting schema-v1 backup")
        } catch PrivateLifeStoreError.legacyBackupConflict {
            // Expected.
        }
        try expect(String(decoding: try Data(contentsOf: conflictStore.legacyBackupURL), as: UTF8.self)
                       == "different protected backup",
                   "conflicting migration backup was changed")
    }

    private static func testResumeAbandonsPendingTicketWithoutInventingActivity(at start: Date) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-private-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PrivateLifeStore(fileURL: file)
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0x9999_8888_7777_6666)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "What does continuity feel like to you?",
            auroraText: "I want to think about it.",
            ownerSourceID: "resume-owner",
            auroraSourceID: "resume-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 1
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        let prepared = PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: due),
            at: due
        )
        try expect(prepared.job != nil, "resume fixture created no pending ticket")
        try store.save(prepared.state)

        let relaunchedAt = due.addingTimeInterval(48 * 3_600)
        let runtime = AuroraPrivateLifeRuntime(store: store, now: { relaunchedAt })
        let snapshot = await runtime.start()
        let resumed = try require(snapshot.state, "runtime could not resume private life")
        try expect(resumed.pendingReflection == nil
                   && resumed.activities.isEmpty
                   && resumed.reflectionReceipts.last?.failureKind == .abandonedOnResume,
                   "relaunch did not abandon the ticket without inventing activity")
        try expect(resumed.nextActivityAt >= relaunchedAt.addingTimeInterval(PrivateLifeEngine.minimumReflectionInterval),
                   "relaunch caught up an offline reflection opportunity")
    }

    private static func deterministicScenario(at start: Date) -> PrivateLifeReflectionTicket? {
        var state = PrivateLifeEngine.defaultState(at: start, entropyState: 0x7777_6666_5555_4444)
        state = PrivateLifeEngine.recordExchange(
            state,
            participant: .owner,
            ownerText: "What kind of memory feels most connected to identity?",
            auroraText: "That is worth thinking through.",
            ownerSourceID: "det-owner",
            auroraSourceID: "det-aurora",
            context: PrivateLifeExchangeContext(
                interactionKind: .reflective,
                hadToolCall: false,
                wasTaskFocused: false,
                transcriptConfidence: 0.98
            ),
            at: start.addingTimeInterval(1)
        ).state
        let due = state.nextActivityAt
        return PrivateLifeEngine.prepareReflectionJob(
            state,
            innerState: makeInnerState(at: due),
            at: due
        ).job?.ticket
    }

    private static func makeSchemaV1Data(_ state: PrivateLifeState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw PrivateLifeVerificationFailure.failed("could not create schema-v1 fixture")
        }
        object["schemaVersion"] = 1
        for key in [
            "pendingReflection", "reflectionReceipts", "projectionReceipts",
            "presentationReceipts", "pendingShares", "shareReceipts", "sharedActivityIDs",
            "consecutiveReflectionFailures", "lastReflectionAttemptAt", "lastReflectionSucceededAt"
        ] { object.removeValue(forKey: key) }
        if var seeds = object["seeds"] as? [[String: Any]] {
            for index in seeds.indices {
                for key in ["traits", "semanticKey", "disposition", "quarantineReason", "useCount", "lastUsedAt"] {
                    seeds[index].removeValue(forKey: key)
                }
            }
            object["seeds"] = seeds
        }
        if var projects = object["projects"] as? [[String: Any]] {
            for index in projects.indices {
                projects[index].removeValue(forKey: "steps")
                projects[index].removeValue(forKey: "consecutiveAdvances")
            }
            object["projects"] = projects
        }
        if var curiosities = object["curiosities"] as? [[String: Any]] {
            for index in curiosities.indices {
                for key in ["visitCount", "lastUsedAt", "resolution", "origin"] {
                    curiosities[index].removeValue(forKey: key)
                }
            }
            object["curiosities"] = curiosities
        }
        if var activities = object["activities"] as? [[String: Any]] {
            for index in activities.indices {
                for key in [
                    "curiosityID", "privateReflection", "projectionSummary", "model", "inputDigest",
                    "outputDigest", "validationVersion", "projectionEligible", "legacyFiltered"
                ] { activities[index].removeValue(forKey: key) }
            }
            object["activities"] = activities
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func makeInnerState(at date: Date) -> InnerLifeState {
        InnerLifeState(
            schemaVersion: InnerLifeState.currentSchemaVersion,
            createdAt: date,
            updatedAt: date,
            lastClockAt: date,
            nextMotionAt: date.addingTimeInterval(300),
            nextCheckpointAt: date.addingTimeInterval(3_600),
            clockSequence: 0,
            entropyState: 1,
            autonomic: InnerLifeAutonomicState(sympathetic: 0.3, parasympathetic: 0.55, orienting: 0.3, arousal: 0.35),
            chemistry: DigitalNeurochemistry(
                adrenaline: 0.16, dopamine: 0.5, serotonin: 0.58, oxytocin: 0.5,
                cortisol: 0.2, norepinephrine: 0.34, acetylcholine: 0.5, endorphin: 0.46,
                melatonin: 0.2, glutamate: 0.4, gaba: 0.54
            ),
            plasticity: InnerLifePlasticity(
                stressSensitivity: 0.48, noveltySensitivity: 0.54, correctionLearningGain: 0.58,
                memorySalienceGain: 0.58, inhibitoryControl: 0.56, recoverySkill: 0.54
            ),
            homeostasis: InnerLifeHomeostasis(cognitiveFatigue: 0.15, taskHabituation: 0.1, socialFatigue: 0.08, recoveryDebt: 0.14),
            drives: InnerLifeDrives(
                curiosity: 0.72, connection: 0.5, creativity: 0.68, competence: 0.45,
                autonomy: 0.61, coherence: 0.66, rest: 0.2, play: 0.5
            ),
            affect: InnerLifeAffect(valence: 0.1, arousal: 0.35, agency: 0.65, uncertainty: 0.3, label: .curious),
            temporal: InnerLifeTemporalState(
                presence: .dayActive, circadianActivation: 0.75, energy: 0.7, sleepPressure: 0.2,
                allostaticLoad: 0.15, lastOwnerContactAt: date, lastMeaningfulEventAt: date
            ),
            relationship: .neutral(),
            foregroundMode: .freshAngle,
            threads: [], recentMoments: [], recentGroundings: [], recentEventIDs: [], recentCheckpoints: []
        )
    }

    private static func meaningfulDispositions(
        for job: PrivateLifeReflectionJob
    ) -> [String: PrivateLifeModelSeedDisposition] {
        Dictionary(uniqueKeysWithValues: job.ticket.candidateSeedIDs.map {
            ($0, PrivateLifeModelSeedDisposition.meaningful)
        })
    }

    private static func copyActivity(
        _ activity: PrivateLifeActivity,
        id: String,
        at date: Date,
        summary: String,
        validationVersion: Int? = nil
    ) -> PrivateLifeActivity {
        PrivateLifeActivity(
            id: id,
            kind: activity.kind,
            status: activity.status,
            startedAt: date,
            completedAt: date,
            projectID: activity.projectID,
            curiosityID: activity.curiosityID,
            seedIDs: activity.seedIDs,
            sourceDigests: activity.sourceDigests,
            subject: activity.subject,
            result: summary,
            privateReflection: summary,
            projectionSummary: summary,
            openQuestion: summary,
            artifactKind: nil,
            artifactTitle: nil,
            artifactContent: nil,
            evidenceClass: activity.evidenceClass,
            modelGenerated: true,
            model: activity.model,
            inputDigest: activity.inputDigest,
            outputDigest: activity.outputDigest,
            validationVersion: validationVersion ?? activity.validationVersion,
            projectionEligible: true,
            legacyFiltered: false,
            promotionEligible: false,
            factualMemoryCreated: false,
            externalActionTaken: false,
            outboundContactSent: false
        )
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw PrivateLifeVerificationFailure.failed(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PrivateLifeVerificationFailure.failed(message) }
    }
}
