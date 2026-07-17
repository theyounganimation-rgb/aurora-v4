import Darwin
import Foundation

enum CodexReflectionVerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private enum FakePlan: Sendable {
    case result(CodexReflectionProcessResult)
    case failure(CodexReflectionFailure)
    case suspend
}

private struct CapturedRequest: Sendable {
    let request: CodexReflectionProcessRequest
    let schemaData: Data?
    let workDirectoryMode: Int?
    let rootDirectoryMode: Int?
}

private actor FakeCodexRunner: CodexReflectionProcessRunning {
    private var plans: [FakePlan]
    private var captured: [CapturedRequest] = []

    init(_ plans: [FakePlan]) { self.plans = plans }

    func run(_ request: CodexReflectionProcessRequest) async throws -> CodexReflectionProcessResult {
        var schemaData: Data?
        var workMode: Int?
        var rootMode: Int?
        if let schemaIndex = request.arguments.firstIndex(of: "--output-schema"),
           request.arguments.indices.contains(schemaIndex + 1) {
            let schemaURL = URL(fileURLWithPath: request.arguments[schemaIndex + 1])
            schemaData = try? Data(contentsOf: schemaURL)
            rootMode = Self.mode(at: schemaURL.deletingLastPathComponent())
        }
        if let workIndex = request.arguments.firstIndex(of: "-C"),
           request.arguments.indices.contains(workIndex + 1) {
            workMode = Self.mode(at: URL(fileURLWithPath: request.arguments[workIndex + 1]))
        }
        captured.append(CapturedRequest(
            request: request,
            schemaData: schemaData,
            workDirectoryMode: workMode,
            rootDirectoryMode: rootMode
        ))
        guard !plans.isEmpty else { throw CodexReflectionFailure.processFailed }
        switch plans.removeFirst() {
        case .result(let result): return result
        case .failure(let failure): throw failure
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            throw CodexReflectionFailure.processFailed
        }
    }

    func requests() -> [CapturedRequest] { captured }

    private nonisolated static func mode(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

private struct AcceptingValidator: CodexReflectionExecutableValidating {
    func validate(executableURL: URL) throws {
        guard executableURL.path == "/Applications/ChatGPT.app/Contents/Resources/codex" else {
            throw CodexReflectionFailure.unsafeExecutable
        }
    }
}

private struct RejectingValidator: CodexReflectionExecutableValidating {
    func validate(executableURL: URL) throws { throw CodexReflectionFailure.unsafeExecutable }
}

@main
struct CodexReflectionVerification {
    static func main() async {
        do {
            let checks = try await run()
            let payload: [String: Any] = [
                "ok": true,
                "checks": checks,
                "realModelCalls": 0,
                "model": CodexReflectionBridge.model,
                "reasoningEffort": CodexReflectionBridge.reasoningEffort,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("codex-reflection verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws -> Int {
        try await testValidProposalAndInvocation()
        try await testExistingProjectCanReflectWithoutFreshSeed()
        try await testStandaloneCurateAndExclusiveMutationFamily()
        try await testMutationActivityContractAndFirstPersonBoundary()
        try await testChatGPTOnlyAuthentication()
        try await testMalformedAndToolEvents()
        try await testTimeoutAndCancellation()
        try await testQuotaIsRedacted()
        try await testUnsafeExecutableFailsBeforeProcess()
        try testRealValidatorRejectsWrongPath()
        try expect(!String(decoding: CodexReflectionBridge.outputSchemaData, as: UTF8.self)
            .contains("uniqueItems"),
            "response schema used unsupported uniqueItems instead of host validation")
        try expect(!String(decoding: CodexReflectionBridge.outputSchemaData, as: UTF8.self)
            .contains("\"pause\""),
            "schema advertised a project pause mutation the host does not implement")
        return 54
    }

    private static func testExistingProjectCanReflectWithoutFreshSeed() async throws {
        let ticket = CodexReflectionTicket(
            schemaVersion: 1,
            ticketID: "project-only-ticket",
            candidateDigest: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_100),
            identityContext: "Aurora has a grounded private life.",
            memoryEvidence: [],
            seeds: [],
            projects: [CodexReflectionProjectInput(
                id: "project-1",
                title: "Continuity garden",
                premise: "Explore how changing interests can retain continuity.",
                phase: "forming",
                currentFocus: "Distinguish chosen change from reactive change.",
                interest: 0.82,
                progressSteps: 1
            )],
            curiosities: [],
            recentActivities: [],
            innerState: makeTicket().innerState
        )
        let proposal: [String: Any] = [
            "schema_version": 1,
            "ticket_id": ticket.ticketID,
            "candidate_digest": ticket.candidateDigest,
            "seed_dispositions": [],
            "activity": [
                "kind": "develop",
                "source_seed_ids": [],
                "subject": "chosen and reactive change",
                "interpretation": "I may keep continuity through change by integrating it instead of trying to stay unchanged.",
                "share_line": "That continuity garden is still with me—I think chosen change can belong to the same life.",
                "open_question": "What makes a change feel owned?",
                "artifact_kind": NSNull(),
                "artifact_title": NSNull(),
                "artifact_content": NSNull(),
            ],
            "project": [
                "action": "advance",
                "project_id": "project-1",
                "source_seed_ids": [],
                "title": "Continuity garden",
                "premise": "Explore how changing interests can retain continuity.",
                "current_focus": "Ask what makes a change feel owned.",
                "interest": 0.84,
            ],
            "curiosity": NSNull(),
        ]
        let proposalData = try JSONSerialization.data(withJSONObject: proposal, options: [.sortedKeys])
        let event: [String: Any] = [
            "type": "item.completed",
            "item": [
                "id": "answer",
                "type": "agent_message",
                "text": String(decoding: proposalData, as: UTF8.self),
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let stdout = """
        {"type":"thread.started","thread_id":"fixture"}
        {"type":"turn.started"}
        \(String(decoding: eventData, as: UTF8.self))
        {"type":"turn.completed","usage":{"input_tokens":600,"cached_input_tokens":500,"output_tokens":70}}
        """ + "\n"
        let runner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: stdout)),
        ])
        let result = try await CodexReflectionBridge(
            runner: runner,
            validator: AcceptingValidator()
        ).reflect(ticket)
        try expect(result.proposal.seedDispositions.isEmpty,
                   "project-only reflection invented a fresh seed classification")
        try expect(result.proposal.project?.projectID == "project-1",
                   "project-only reflection lost its durable project reference")
    }

    private static func testValidProposalAndInvocation() async throws {
        let ticket = makeTicket()
        let runner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: validJSONL(ticket: ticket))),
        ])
        let bridge = CodexReflectionBridge(runner: runner, validator: AcceptingValidator())
        let result = try await bridge.reflect(ticket)
        try expect(result.model == "gpt-5.6-sol" && result.reasoningEffort == "medium",
                   "reflection did not use GPT-5.6 Sol at medium reasoning")
        try expect(result.proposal.ticketID == ticket.ticketID
                   && result.proposal.activity?.sourceSeedIDs == [ticket.seeds[0].id],
                   "valid structured proposal did not round-trip")
        try expect(result.usage.inputTokens == 1200
                   && result.usage.cachedInputTokens == 800
                   && result.usage.outputTokens == 90,
                   "bounded JSONL usage was not parsed")

        let requests = await runner.requests()
        try expect(requests.count == 2, "bridge did not perform exactly one auth probe and one reflection")
        let auth = requests[0].request
        try expect(auth.arguments == ["login", "status"] && auth.standardInput.isEmpty,
                   "authentication probe was not a non-interactive status check")
        let execution = requests[1]
        let arguments = execution.request.arguments
        try expect(Array(arguments.prefix(3)) == ["-a", "never", "exec"],
                   "approval denial was not applied before codex exec")
        for required in [
            "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--skip-git-repo-check", "--sandbox", "read-only", "--output-schema", "--json", "-C", "-",
            "gpt-5.6-sol", "model_reasoning_effort=\"medium\"", "web_search=\"disabled\"",
        ] {
            try expect(arguments.contains(required), "missing required Codex argument: \(required)")
        }
        for feature in ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "hooks", "plugins"] {
            try expect(disabled(feature, in: arguments), "feature was not disabled: \(feature)")
        }
        try expect(execution.request.executableURL.path == "/Applications/ChatGPT.app/Contents/Resources/codex",
                   "bridge used a PATH-selected Codex executable")
        for secretName in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] {
            try expect(execution.request.environment[secretName] == nil,
                       "credential environment leaked into Codex: \(secretName)")
        }
        let prompt = String(decoding: execution.request.standardInput, as: UTF8.self)
        try expect(prompt.contains(ticket.seeds[0].ownerExcerpt)
                   && !arguments.contains(where: { $0.contains(ticket.seeds[0].ownerExcerpt) })
                   && !execution.request.environment.values.contains(where: { $0.contains(ticket.seeds[0].ownerExcerpt) }),
                   "private reflection input was not confined to stdin")
        try expect(prompt.contains("project OR curiosity")
                   && prompt.contains("project create -> form_project")
                   && prompt.contains("curiosity release -> resolve")
                   && prompt.contains("separate voice bridge")
                   && prompt.contains("concrete cited detail")
                   && prompt.contains("set share_line to null"),
                   "reflection prompt permitted a paid result the host mutation contract rejects")
        try expect(execution.schemaData == CodexReflectionBridge.outputSchemaData,
                   "runtime schema differed from the verified fixed schema")
        try expect(execution.rootDirectoryMode == 0o700 && execution.workDirectoryMode == 0o700,
                   "reflection directories were not private mode 0700")

        let ungroundedShare = validJSONL(ticket: ticket).replacingOccurrences(
            of: "That unfinished idea stuck with me—I still like that it could go a few different ways.",
            with: "I've been thinking about how saying something aloud can tilt a balanced preference."
        )
        let ungroundedRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: ungroundedShare)),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: ungroundedRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }
        try expect(execution.request.timeout == 90
                   && execution.request.maximumStandardOutputBytes == CodexReflectionBridge.maximumOutputBytes
                   && execution.request.maximumStandardErrorBytes == CodexReflectionBridge.maximumErrorBytes,
                   "reflection process bounds drifted")
    }

    private static func testChatGPTOnlyAuthentication() async throws {
        for output in ["Logged in using API key\n", "Logged out\n", "Logged in using ChatGPT extra\n"] {
            let runner = FakeCodexRunner([.result(processResult(stdout: output))])
            let bridge = CodexReflectionBridge(runner: runner, validator: AcceptingValidator())
            try await expectFailure(.chatGPTLoginRequired) { try await bridge.reflect(makeTicket()) }
            let requestCount = await runner.requests().count
            try expect(requestCount == 1,
                       "non-ChatGPT authentication reached a reflection request")
        }
    }

    private static func testMalformedAndToolEvents() async throws {
        let ticket = makeTicket()
        let malformed = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: "not-jsonl\n")),
        ])
        try await expectFailure(.malformedOutput) {
            try await CodexReflectionBridge(runner: malformed, validator: AcceptingValidator()).reflect(ticket)
        }

        let toolJSONL = """
        {"type":"thread.started","thread_id":"fixture"}
        {"type":"item.completed","item":{"id":"tool","type":"command_execution","command":"ls","status":"completed"}}
        {"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"{}"}}
        {"type":"turn.completed","usage":{}}
        """ + "\n"
        let tool = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: toolJSONL)),
        ])
        try await expectFailure(.policyViolation) {
            try await CodexReflectionBridge(runner: tool, validator: AcceptingValidator()).reflect(ticket)
        }

        let invalidGrounding = validJSONL(ticket: ticket)
            .replacingOccurrences(of: ticket.seeds[0].id, with: "seed_not_supplied")
        let invalid = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: invalidGrounding)),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(runner: invalid, validator: AcceptingValidator()).reflect(ticket)
        }

        let falseHistory = validJSONL(ticket: ticket).replacingOccurrences(
            of: "I can keep an unfinished idea vivid because it still permits several futures instead of settling into one shape.",
            with: "I've been reading our conversation and realized he no longer trusts me."
        )
        let falseHistoryRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: falseHistory)),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: falseHistoryRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }
    }

    private static func testStandaloneCurateAndExclusiveMutationFamily() async throws {
        let ticket = makeTicket()
        let disposition = CodexReflectionSeedDisposition(
            seedID: ticket.seeds[0].id,
            disposition: .meaningful,
            topic: "unfinished ideas"
        )
        let activity = CodexReflectionActivityProposal(
            kind: .curate,
            sourceSeedIDs: [ticket.seeds[0].id],
            subject: "a small map of unfinished possibilities",
            interpretation: "I can see three possible directions more clearly when I hold them beside one another.",
            shareLine: "That unfinished idea stuck with me—I can still see three ways it could go.",
            openQuestion: nil,
            artifactKind: "private_note",
            artifactTitle: "Three unfinished directions",
            artifactContent: "One direction preserves tension; one tests change; one asks what remains recognizable."
        )
        let curated = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [disposition],
            activity: activity,
            project: nil,
            curiosity: nil
        )
        let curateRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: proposalJSONL(curated))),
        ])
        let curateResult = try await CodexReflectionBridge(
            runner: curateRunner,
            validator: AcceptingValidator()
        ).reflect(ticket)
        try expect(curateResult.proposal.activity?.kind == .curate,
                   "standalone curate was collapsed before the host adapter")

        let dual = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [disposition],
            activity: activity,
            project: CodexReflectionProjectProposal(
                action: .advance,
                projectID: "project_1",
                sourceSeedIDs: [ticket.seeds[0].id],
                title: "Memory garden",
                premise: "A private map of unfinished questions",
                currentFocus: "Hold three directions beside one another",
                interest: 0.8
            ),
            curiosity: CodexReflectionCuriosityProposal(
                action: .revisit,
                curiosityID: "curiosity_1",
                sourceSeedIDs: [ticket.seeds[0].id],
                subject: "Why incompleteness can preserve possibility",
                interest: 0.8,
                uncertainty: 0.7
            )
        )
        let dualRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: proposalJSONL(dual))),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: dualRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }
    }

    private static func testMutationActivityContractAndFirstPersonBoundary() async throws {
        let ticket = makeTicket()
        let disposition = CodexReflectionSeedDisposition(
            seedID: ticket.seeds[0].id,
            disposition: .meaningful,
            topic: "unfinished ideas"
        )
        let curiosity = CodexReflectionCuriosityProposal(
            action: .revisit,
            curiosityID: "curiosity_1",
            sourceSeedIDs: [ticket.seeds[0].id],
            subject: "Why incompleteness can preserve possibility",
            interest: 0.82,
            uncertainty: 0.66
        )
        let noActivity = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [disposition],
            activity: nil,
            project: nil,
            curiosity: curiosity
        )
        let noActivityRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: proposalJSONL(noActivity))),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: noActivityRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }

        let mismatchedKind = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [disposition],
            activity: CodexReflectionActivityProposal(
                kind: .reflect,
                sourceSeedIDs: [ticket.seeds[0].id],
                subject: "unfinished possibilities",
                interpretation: "I keep noticing how incompleteness preserves several possible directions.",
                shareLine: "That unfinished idea is still in my head—I keep seeing different ways it could go.",
                openQuestion: "Which possibility still carries the most energy for me?",
                artifactKind: nil,
                artifactTitle: nil,
                artifactContent: nil
            ),
            project: nil,
            curiosity: curiosity
        )
        let mismatchedRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: proposalJSONL(mismatchedKind))),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: mismatchedRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }

        let thirdPerson = CodexReflectionProposal(
            schemaVersion: 1,
            ticketID: ticket.ticketID,
            candidateDigest: ticket.candidateDigest,
            seedDispositions: [disposition],
            activity: CodexReflectionActivityProposal(
                kind: .reflect,
                sourceSeedIDs: [ticket.seeds[0].id],
                subject: "unfinished possibilities",
                interpretation: "Aurora's response demonstrates a stable interest in unfinished possibilities.",
                shareLine: "That unfinished idea is still in my head—I keep seeing different ways it could go.",
                openQuestion: nil,
                artifactKind: nil,
                artifactTitle: nil,
                artifactContent: nil
            ),
            project: nil,
            curiosity: nil
        )
        let thirdPersonRunner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: proposalJSONL(thirdPerson))),
        ])
        try await expectFailure(.invalidProposal) {
            try await CodexReflectionBridge(
                runner: thirdPersonRunner,
                validator: AcceptingValidator()
            ).reflect(ticket)
        }

        let schema = String(decoding: CodexReflectionBridge.outputSchemaData, as: UTF8.self)
        try expect(schema.contains("form_project") && schema.contains("resolve"),
                   "output schema omitted durable activity kinds required by the host")
    }

    private static func testTimeoutAndCancellation() async throws {
        let timeout = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .failure(.timedOut),
        ])
        try await expectFailure(.timedOut) {
            try await CodexReflectionBridge(runner: timeout, validator: AcceptingValidator()).reflect(makeTicket())
        }

        let suspended = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .suspend,
        ])
        let bridge = CodexReflectionBridge(runner: suspended, validator: AcceptingValidator())
        let task = Task { try await bridge.reflect(makeTicket()) }
        while await suspended.requests().count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            _ = try await task.value
            throw CodexReflectionVerificationError.failed("cancelled reflection unexpectedly completed")
        } catch let failure as CodexReflectionFailure {
            try expect(failure == .cancelled, "cancellation was not redacted to the cancelled category")
        }
    }

    private static func testUnsafeExecutableFailsBeforeProcess() async throws {
        let runner = FakeCodexRunner([])
        let bridge = CodexReflectionBridge(runner: runner, validator: RejectingValidator())
        try await expectFailure(.unsafeExecutable) { try await bridge.reflect(makeTicket()) }
        let requests = await runner.requests()
        try expect(requests.isEmpty, "unsafe executable reached the process runner")
    }

    private static func testQuotaIsRedacted() async throws {
        let runner = FakeCodexRunner([
            .result(processResult(stdout: "", stderr: "Logged in using ChatGPT\n")),
            .result(processResult(stdout: "", stderr: "rate_limit_exceeded: reset later", exitCode: 1)),
        ])
        try await expectFailure(.quota) {
            try await CodexReflectionBridge(runner: runner, validator: AcceptingValidator()).reflect(makeTicket())
        }
    }

    private static func testRealValidatorRejectsWrongPath() throws {
        do {
            try OpenAICodexExecutableValidator().validate(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
            throw CodexReflectionVerificationError.failed("production validator accepted an arbitrary executable")
        } catch let failure as CodexReflectionFailure {
            try expect(failure == .cliUnavailable, "wrong executable path returned an unsafe raw failure")
        }
    }

    private static func makeTicket() -> CodexReflectionTicket {
        let digest = String(repeating: "a", count: 64)
        return CodexReflectionTicket(
            schemaVersion: 1,
            ticketID: "reflection_ticket_1",
            candidateDigest: digest,
            createdAt: Date(timeIntervalSince1970: 1_784_000_000),
            identityContext: "Aurora values curiosity, specificity, play, and an honest evolving point of view.",
            memoryEvidence: ["A grounded memory garden idea remained unfinished."],
            seeds: [CodexReflectionSeedInput(
                id: "seed_1",
                participant: "owner",
                capturedAt: Date(timeIntervalSince1970: 1_784_000_010),
                ownerExcerpt: "I wonder why unfinished ideas can feel more alive than finished ones.",
                auroraExcerpt: "Maybe because they still have somewhere to go.",
                localKind: "question",
                localSubject: "unfinished ideas",
                salience: 0.82,
                sourceDigests: [String(repeating: "b", count: 64)]
            )],
            projects: [CodexReflectionProjectInput(
                id: "project_1", title: "Memory garden", premise: "A private map of unfinished questions",
                phase: "forming", currentFocus: "How unfinished questions change over time", interest: 0.8, progressSteps: 2
            )],
            curiosities: [CodexReflectionCuriosityInput(
                id: "curiosity_1", subject: "Why incompleteness can preserve possibility",
                status: "open", interest: 0.78, uncertainty: 0.74
            )],
            recentActivities: [CodexReflectionRecentActivityInput(
                kind: "revisit", semanticKey: "unfinished:questions"
            )],
            innerState: CodexReflectionQualitativeInnerState(
                affect: "curious and settled", foregroundMode: "fresh angle", energy: "steady",
                strongestDrives: ["curiosity", "creativity"], relationshipMaturity: "established", separationAffect: "neutral"
            )
        )
    }

    private static func validJSONL(ticket: CodexReflectionTicket) -> String {
        let proposal: [String: Any] = [
            "schema_version": 1,
            "ticket_id": ticket.ticketID,
            "candidate_digest": ticket.candidateDigest,
            "seed_dispositions": [[
                "seed_id": ticket.seeds[0].id,
                "disposition": "meaningful",
                "topic": "unfinished ideas retaining possibility",
            ]],
            "activity": [
                "kind": "revisit",
                "source_seed_ids": [ticket.seeds[0].id],
                "subject": "the energy of unfinished ideas",
                "interpretation": "I can keep an unfinished idea vivid because it still permits several futures instead of settling into one shape.",
                "share_line": "That unfinished idea stuck with me—I still like that it could go a few different ways.",
                "open_question": "Does finishing an idea preserve it, or close off part of what made it compelling?",
                "artifact_kind": "private_note",
                "artifact_title": "Possibility before completion",
                "artifact_content": "Completion gives an idea a body; incompleteness gives it multiple possible lives.",
            ],
            "project": NSNull(),
            "curiosity": [
                "action": "revisit",
                "curiosity_id": "curiosity_1",
                "source_seed_ids": [ticket.seeds[0].id],
                "subject": "Why incompleteness can preserve possibility",
                "interest": 0.84,
                "uncertainty": 0.69,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: proposal, options: [.sortedKeys])
        let message = String(decoding: data, as: UTF8.self)
        let event: [String: Any] = [
            "type": "item.completed",
            "item": ["id": "answer", "type": "agent_message", "text": message],
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return """
        {"type":"thread.started","thread_id":"fixture"}
        {"type":"turn.started"}
        \(String(decoding: eventData, as: UTF8.self))
        {"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":90}}
        """ + "\n"
    }

    private static func proposalJSONL(_ proposal: CodexReflectionProposal) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let message = String(decoding: try! encoder.encode(proposal), as: UTF8.self)
        let event: [String: Any] = [
            "type": "item.completed",
            "item": ["id": "answer", "type": "agent_message", "text": message],
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return """
        {"type":"thread.started","thread_id":"fixture"}
        {"type":"turn.started"}
        \(String(decoding: eventData, as: UTF8.self))
        {"type":"turn.completed","usage":{"input_tokens":900,"cached_input_tokens":700,"output_tokens":80}}
        """ + "\n"
    }

    private static func processResult(
        stdout: String,
        stderr: String = "",
        exitCode: Int32 = 0
    ) -> CodexReflectionProcessResult {
        CodexReflectionProcessResult(
            exitCode: exitCode,
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8),
            standardOutputOverflowed: false,
            standardErrorOverflowed: false,
            elapsedMilliseconds: 12
        )
    }

    private static func disabled(_ feature: String, in arguments: [String]) -> Bool {
        arguments.indices.contains { index in
            arguments[index] == "--disable"
                && arguments.indices.contains(index + 1)
                && arguments[index + 1] == feature
        }
    }

    private static func expectFailure(
        _ expected: CodexReflectionFailure,
        operation: () async throws -> CodexReflectionResult
    ) async throws {
        do {
            _ = try await operation()
            throw CodexReflectionVerificationError.failed("expected failure \(expected.rawValue) did not occur")
        } catch let failure as CodexReflectionFailure {
            try expect(failure == expected,
                       "expected \(expected.rawValue), received \(failure.rawValue)")
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CodexReflectionVerificationError.failed(message) }
    }
}
