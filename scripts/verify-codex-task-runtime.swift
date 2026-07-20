import Foundation

// The standalone verifier compiles only the new runtime files. Production uses
// the identically named signed-binary validator from CodexReflectionBridge.
struct OpenAICodexExecutableValidator {
    static let expectedExecutableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    func validate(executableURL: URL) throws {}
}

private enum VerificationFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private struct AcceptingExecutableValidator: CodexTaskExecutableValidating {
    func validate(executableURL: URL) throws {}
}

private struct VerificationSharedDaemonProbe: CodexSharedDaemonProbing {
    let result: CodexSharedDaemonProbeResult

    func probe(
        executableURL: URL,
        codexHomeURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> CodexSharedDaemonProbeResult {
        result
    }
}

private actor VerificationDesktopThreadRegistrar: CodexDesktopThreadRegistering {
    private var registeredThreadIDs: [String] = []

    func registerPersistentThread(threadID: String) async -> Bool {
        registeredThreadIDs.append(threadID)
        return true
    }

    func registrations() -> [String] { registeredThreadIDs }
}

private actor EventCollector {
    private var values: [CodexTaskRuntimeEvent] = []
    func append(_ value: CodexTaskRuntimeEvent) { values.append(value) }
    func events() -> [CodexTaskRuntimeEvent] { values }
}

private actor FakeCodexAppServerTransport: CodexAppServerTransporting {
    enum AccountMode: Sendable { case chatGPT, apiKey }
    enum BoundaryMode: Sendable { case valid, widenedNetwork, wrongWorkingDirectory }

    private var accountMode: AccountMode
    private let boundaryMode: BoundaryMode
    private var continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation?
    private var generation: UUID?
    private var nextInboundSequence: UInt64 = 0
    private var sentMessages: [Data] = []
    private var launches: [CodexAppServerLaunch] = []
    private var startCount = 0
    private var stopCount = 0
    private var threadCounter = 0
    private var turnCounter = 0
    private var failsToStart: Bool
    private var threadReadResponses: [[String: Any]] = []
    private var threadListResponses: [[String: Any]] = []
    private var threadTurnsListResponses: [[String: Any]] = []
    private var simulatesOversizedHistoryOnIncludeTurns = false
    private var nextTurnStartError: [String: Any]?
    private var nextTurnSteerError: [String: Any]?
    private var completeNextTurnBeforeStartResponse = false

    init(
        accountMode: AccountMode = .chatGPT,
        boundaryMode: BoundaryMode = .valid,
        failsToStart: Bool = false
    ) {
        self.accountMode = accountMode
        self.boundaryMode = boundaryMode
        self.failsToStart = failsToStart
    }

    func start(_ launch: CodexAppServerLaunch) async throws -> AsyncStream<CodexAppServerTransportEvent> {
        guard continuation == nil else { throw CodexTaskRuntimeError.processUnavailable }
        launches.append(launch)
        startCount += 1
        if failsToStart { throw CodexTaskRuntimeError.processUnavailable }
        let pair = AsyncStream<CodexAppServerTransportEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        generation = launch.generation
        nextInboundSequence = 0
        return pair.stream
    }

    func send(_ message: Data, generation expectedGeneration: UUID) async throws {
        guard generation == expectedGeneration else {
            throw CodexTaskRuntimeError.transportFailure
        }
        sentMessages.append(message)
        var line = message
        if line.last == 0x0a { line.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String else {
            return
        }
        guard let id = object["id"] else { return }

        switch method {
        case "initialize":
            respond(id: id, result: ["codexHome": "/verification/.codex"])
        case "account/read":
            switch accountMode {
            case .chatGPT:
                respond(id: id, result: [
                    "account": [
                        "type": "chatgpt",
                        "email": NSNull(),
                        "planType": "pro",
                    ],
                    "requiresOpenaiAuth": true,
                ])
            case .apiKey:
                respond(id: id, result: [
                    "account": ["type": "apiKey"],
                    "requiresOpenaiAuth": true,
                ])
            }
        case "thread/start":
            threadCounter += 1
            let params = object["params"] as? [String: Any] ?? [:]
            respond(
                id: id,
                result: threadResponse(
                    threadID: "thread-" + String(threadCounter),
                    params: params
                )
            )
        case "thread/resume":
            let params = object["params"] as? [String: Any] ?? [:]
            let threadID = params["threadId"] as? String ?? "missing"
            respond(id: id, result: threadResponse(threadID: threadID, params: params))
        case "thread/read":
            let params = object["params"] as? [String: Any] ?? [:]
            let threadID = params["threadId"] as? String ?? "missing"
            if simulatesOversizedHistoryOnIncludeTurns,
               params["includeTurns"] as? Bool == true {
                respond(id: id, result: [
                    "thread": desktopThread(
                        threadID: threadID,
                        turns: [[
                            "id": "turn-oversized-history",
                            "status": "completed",
                            "items": [[
                                "id": "item-oversized-history",
                                "type": "agentMessage",
                                "phase": "final_answer",
                                "text": String(repeating: "x", count: 256 * 1_024),
                            ]],
                        ]]
                    ),
                ])
                return
            }
            let response = threadReadResponses.isEmpty
                ? [
                    "thread": desktopThread(threadID: threadID, turns: []),
                ]
                : threadReadResponses.removeFirst()
            respond(id: id, result: response)
        case "thread/turns/list":
            let response = threadTurnsListResponses.isEmpty
                ? [
                    "data": [],
                    "nextCursor": NSNull(),
                    "backwardsCursor": NSNull(),
                ]
                : threadTurnsListResponses.removeFirst()
            respond(id: id, result: response)
        case "thread/list":
            let response = threadListResponses.isEmpty
                ? [
                    "data": [desktopThread(threadID: "thread-1", turns: [])],
                    "nextCursor": NSNull(),
                    "backwardsCursor": "previous-page",
                ]
                : threadListResponses.removeFirst()
            respond(id: id, result: response)
        case "thread/name/set":
            respond(id: id, result: [:])
        case "thread/archive", "thread/unarchive":
            respond(id: id, result: [:])
        case "turn/start":
            if let error = nextTurnStartError {
                nextTurnStartError = nil
                respond(id: id, error: error)
                return
            }
            turnCounter += 1
            let params = object["params"] as? [String: Any]
            let threadID = params?["threadId"] as? String ?? "missing"
            let turnID = "turn-" + String(turnCounter)
            notify(method: "turn/started", params: [
                "threadId": threadID,
                "turn": ["id": turnID, "status": "inProgress"],
            ])
            if completeNextTurnBeforeStartResponse {
                completeNextTurnBeforeStartResponse = false
                notify(method: "turn/completed", params: [
                    "threadId": threadID,
                    "turn": [
                        "id": turnID,
                        "status": "completed",
                        "items": [[
                            "id": "fast-runtime-final",
                            "type": "agentMessage",
                            "phase": "final_answer",
                            "text": "The fast runtime turn completed.",
                        ]],
                    ],
                ])
            }
            respond(id: id, result: [
                "turn": ["id": turnID, "items": [], "status": "inProgress"],
            ])
        case "turn/steer":
            if let error = nextTurnSteerError {
                nextTurnSteerError = nil
                respond(id: id, error: error)
                return
            }
            let params = object["params"] as? [String: Any]
            respond(id: id, result: ["turnId": params?["expectedTurnId"] as? String ?? "missing"])
        case "turn/interrupt":
            respond(id: id, result: [:])
        default:
            respond(id: id, error: ["code": -32601, "message": "Method not found"])
        }
    }

    func stop() async {
        guard let continuation else { return }
        stopCount += 1
        self.continuation = nil
        generation = nil
        continuation.yield(.terminated(
            exitCode: 0,
            expected: true,
            standardErrorOverflowed: false
        ))
        continuation.finish()
    }

    func emitNotification(method: String, params: [String: Any]) {
        notify(method: method, params: params)
    }

    func setAccountMode(_ mode: AccountMode) {
        accountMode = mode
        notify(method: "account/updated", params: [
            "authMode": mode == .chatGPT ? "chatgpt" : "apikey",
            "planType": mode == .chatGPT ? "pro" : NSNull(),
        ])
    }

    func emitServerRequest(
        id: String,
        method: String,
        params: [String: Any]
    ) {
        emit(["id": id, "method": method, "params": params])
    }

    func emitSequenceGap(method: String = "verification/gap") {
        nextInboundSequence &+= 1
        notify(method: method, params: [:])
    }

    func emitInboundOverflow() {
        continuation?.yield(.inboundOverflow)
    }

    func emitProtocolFailure() {
        continuation?.yield(.protocolFailure)
    }

    func terminateUnexpectedly(exitCode: Int32) {
        guard let continuation else { return }
        self.continuation = nil
        generation = nil
        continuation.yield(.terminated(
            exitCode: exitCode,
            expected: false,
            standardErrorOverflowed: false
        ))
        continuation.finish()
    }

    func messageData() -> [Data] { sentMessages }
    func launchData() -> [CodexAppServerLaunch] { launches }
    func counts() -> (starts: Int, stops: Int) { (startCount, stopCount) }

    func setThreadReadResponses(_ responses: [[String: Any]]) {
        threadReadResponses = responses
    }

    func setThreadListResponses(_ responses: [[String: Any]]) {
        threadListResponses = responses
    }

    func setThreadTurnsListResponses(_ responses: [[String: Any]]) {
        threadTurnsListResponses = responses
    }

    func simulateOversizedHistoryOnIncludeTurns() {
        simulatesOversizedHistoryOnIncludeTurns = true
    }

    func failNextTurnStart(code: Int = -32_000, message: String) {
        nextTurnStartError = ["code": code, "message": message]
    }

    func failNextTurnSteer(code: Int = -32_000, message: String) {
        nextTurnSteerError = ["code": code, "message": message]
    }

    func completeNextTurnBeforeReturningStartHandle() {
        completeNextTurnBeforeStartResponse = true
    }

    func setFailsToStart(_ fails: Bool) {
        failsToStart = fails
    }

    private func respond(id: Any, result: [String: Any]) {
        emit(["id": id, "result": result])
    }

    private func respond(id: Any, error: [String: Any]) {
        emit(["id": id, "error": error])
    }

    private func notify(method: String, params: [String: Any]) {
        emit(["method": method, "params": params])
    }

    private func threadResponse(
        threadID: String,
        params: [String: Any]
    ) -> [String: Any] {
        let requestedSandbox = params["sandbox"] as? String ?? "read-only"
        let type: String
        switch requestedSandbox {
        case "workspace-write": type = "workspaceWrite"
        case "danger-full-access": type = "dangerFullAccess"
        default: type = "readOnly"
        }
        var sandbox: [String: Any] = ["type": type]
        if type == "readOnly" {
            sandbox["networkAccess"] = boundaryMode == .widenedNetwork
        } else if type == "workspaceWrite" {
            sandbox["networkAccess"] = boundaryMode == .widenedNetwork
            sandbox["writableRoots"] = []
            sandbox["excludeTmpdirEnvVar"] = false
            sandbox["excludeSlashTmp"] = false
        }
        let requestedCWD = params["cwd"] as? String ?? "/verification/Aurora V4"
        let cwd = boundaryMode == .wrongWorkingDirectory
            ? "/verification/unrelated"
            : requestedCWD
        return [
            "thread": ["id": threadID],
            "model": params["model"] as? String ?? "gpt-5.6-sol",
            "modelProvider": "openai",
            "cwd": cwd,
            "approvalPolicy": params["approvalPolicy"] as? String ?? "on-request",
            "approvalsReviewer": "user",
            "sandbox": sandbox,
            "activePermissionProfile": NSNull(),
        ]
    }

    private func desktopThread(
        threadID: String,
        turns: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": threadID,
            "sessionId": "session-1",
            "name": "Aurora — Open Notes",
            "preview": "Open Notes",
            "cwd": "/verification/Aurora V4",
            "status": ["type": "notLoaded"],
            "source": "appServer",
            "threadSource": "appServer",
            "modelProvider": "openai",
            "cliVersion": "0.144.5",
            "createdAt": 1_700_000_000,
            "updatedAt": 1_700_000_001,
            "ephemeral": false,
            "turns": turns,
        ]
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        continuation?.yield(.line(
            sequence: nextInboundSequence,
            data: CodexAppServerInboundLine(data: data)
        ))
        nextInboundSequence &+= 1
    }
}

@main
private enum CodexTaskRuntimeVerifier {
    static func main() async {
        do {
            try await verifyLifecycleAndServerRequests()
            try await verifyRawProjectThreadMessaging()
            try await verifyExactProjectThreadReconciliation()
            try await verifyRestartResumesMappedThread()
            try await verifyReconciliationClosesReadSubscribeRace()
            try await verifyBrowserSurfaceReceiptRecovery()
            try await verifyChatGPTOnlyAndInputBounds()
            try await verifyDuplicateServerRequestFailsClosed()
            try await verifyBoundaryAndAccountChangesFailClosed()
            try await verifyStaleApprovalAndSequenceGapFailClosed()
            try await verifyLargeInboundEventAndExplicitOverflow()
            try await verifyFoundationTransportByteBudget()
            try await verifySharedDaemonSelectionAndFallback()
            try verifySharedDaemonVersionAndWebSocketCodec()
            let liveHandshakeRequested = ProcessInfo.processInfo.environment[
                "AURORA_VERIFY_LIVE_CODEX_ACCOUNT"
            ] == "1"
            var liveSharedDaemonHandshake = false
            if liveHandshakeRequested {
                liveSharedDaemonHandshake = try await verifyLiveAccountHandshakeOnly()
            }
            let payload: [String: Any] = [
                "ok": true,
                "checks": 123,
                "liveAccountHandshake": liveHandshakeRequested,
                "liveSharedDaemonHandshake": liveSharedDaemonHandshake,
                "realModelCalls": 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("codex-task-runtime verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyLifecycleAndServerRequests() async throws {
        let transport = FakeCodexAppServerTransport()
        let events = EventCollector()
        let desktopRegistrar = VerificationDesktopThreadRegistrar()
        let runtime = makeRuntime(
            transport: transport,
            desktopThreadRegistrar: desktopRegistrar
        )
        let projectDirectory = URL(
            fileURLWithPath: "/verification/Aurora V4",
            isDirectory: true
        )
        await runtime.setEventHandler { event in
            Task { await events.append(event) }
        }

        try await runtime.start()
        let account = await runtime.accountSnapshot
        try expect(account == CodexTaskAccountSnapshot(
            authenticationType: "chatgpt",
            planType: "pro"
        ), "runtime did not validate ChatGPT account auth")

        let launches = await transport.launchData()
        try expect(launches.count == 1, "runtime launched app-server more than once")
        try expect(launches[0].arguments == ["app-server", "--listen", "stdio://", "--strict-config"],
                   "runtime did not use the bounded stdio app-server interface")
        try expect(launches[0].environment["CODEX_HOME"] == "/verification/.codex"
                   && launches[0].environment["OPENAI_API_KEY"] == nil,
                   "runtime did not isolate cached Codex auth from API-key environment state")

        let handle = try await runtime.startTask(
            taskID: "owner.notes-demo",
            input: "Open Notes",
            options: CodexTaskThreadOptions(
                reasoningEffort: .low,
                workingDirectory: projectDirectory,
                dynamicTools: [effectReportTool()],
                threadName: "Aurora — Open Notes"
            )
        )
        try expect(handle == CodexTaskHandle(
            taskID: "owner.notes-demo",
            threadID: "thread-1",
            turnID: "turn-1"
        ), "thread/start and turn/start did not create a stable task mapping: \(handle)")
        let mappedThreadID = await runtime.threadID(forTaskID: "owner.notes-demo")
        let mappedTurnID = await runtime.activeTurnID(forTaskID: "owner.notes-demo")
        try expect(mappedThreadID == "thread-1",
                   "task-to-thread mapping was not retained")
        try expect(mappedTurnID == "turn-1",
                   "turn/started was not mapped to the task")
        let desktopPage = try await runtime.listThreads(query: AuroraCodexThreadQuery(
            searchTerm: "Open Notes",
            workingDirectory: projectDirectory,
            limit: 20
        ))
        try expect(
            desktopPage.threads.count == 1
                && desktopPage.threads[0].threadID == "thread-1"
                && desktopPage.threads[0].name == "Aurora — Open Notes"
                && desktopPage.threads[0].status == "notLoaded"
                && desktopPage.nextCursor == nil,
            "typed Codex thread discovery did not return the app-server thread"
        )
        let desktopDocument = try await runtime.readThread(
            threadID: "thread-1",
            includeTurns: true
        )
        try expect(
            desktopDocument.summary.threadID == "thread-1"
                && desktopDocument.canonicalThreadJSON.isEmpty == false,
            "typed Codex thread/read did not preserve the bounded document"
        )
        try await waitUntil {
            await desktopRegistrar.registrations().count == 1
        }
        let registeredDesktopThreads = await desktopRegistrar.registrations()
        try expect(
            registeredDesktopThreads == ["thread-1"],
            "the new persistent thread was not registered with Codex Desktop exactly once"
        )

        try await runtime.steerTask(taskID: "owner.notes-demo", input: "Use the current window")
        let messages = try decodeMessages(await transport.messageData())
        guard let initialize = messages.first(where: { $0["method"] as? String == "initialize" }),
              let initializeParams = initialize["params"] as? [String: Any],
              let capabilities = initializeParams["capabilities"] as? [String: Any] else {
            throw VerificationFailure.failed("initialize capability negotiation was not sent")
        }
        try expect(
            capabilities["experimentalApi"] as? Bool == true,
            "runtime exposed dynamicTools without negotiating experimentalApi"
        )
        guard let threadList = messages.first(where: {
            $0["method"] as? String == "thread/list"
        }),
              let threadListParams = threadList["params"] as? [String: Any],
              let sourceKinds = threadListParams["sourceKinds"] as? [String],
              let modelProviders = threadListParams["modelProviders"] as? [String]
        else {
            throw VerificationFailure.failed("thread/list discovery parameters were missing")
        }
        try expect(
            Set(sourceKinds) == Set([
                "cli",
                "vscode",
                "exec",
                "appServer",
                "subAgent",
                "subAgentReview",
                "subAgentCompact",
                "subAgentThreadSpawn",
                "subAgentOther",
                "unknown",
            ])
                && modelProviders.isEmpty
                && threadListParams["useStateDbOnly"] as? Bool == false,
            "thread/list could hide Desktop-projected or stale Codex tasks"
        )
        guard let threadStart = messages.first(where: { $0["method"] as? String == "thread/start" }),
              let threadParams = threadStart["params"] as? [String: Any] else {
            throw VerificationFailure.failed("thread/start was not sent")
        }
        try expect(threadParams["approvalPolicy"] as? String == "on-request"
                   && threadParams["sandbox"] as? String == "read-only"
                   && threadParams["modelProvider"] as? String == "openai"
                   && threadParams["serviceName"] as? String == "Aurora"
                   && threadParams["threadSource"] as? String == "appServer"
                   && threadParams["ephemeral"] as? Bool == false
                   && threadParams["cwd"] as? String == projectDirectory.path,
                   "runtime did not preserve persistent project-affinity metadata")
        guard let dynamicTools = threadParams["dynamicTools"] as? [[String: Any]],
              dynamicTools.count == 1,
              let effectTool = dynamicTools.first,
              let effectSchema = effectTool["inputSchema"] as? [String: Any],
              let effectProperties = effectSchema["properties"] as? [String: Any],
              let outcomeProperty = effectProperties["outcome"] as? [String: Any],
              let observationProperty = effectProperties["observed_postcondition"]
                as? [String: Any],
              let required = effectSchema["required"] as? [String] else {
            throw VerificationFailure.failed("thread/start dynamic tool schema was malformed")
        }
        try expect(
            effectTool["type"] as? String == "function"
                && effectTool["name"] as? String == "report_effect_result"
                && effectTool["deferLoading"] == nil
                && effectSchema["type"] as? String == "object"
                && effectSchema["additionalProperties"] as? Bool == false
                && Set(required) == Set(["outcome", "observed_postcondition"])
                && outcomeProperty["type"] as? String == "string"
                && outcomeProperty["enum"] as? [String]
                    == ["verified", "not_verified", "no_external_effect"]
                && observationProperty["type"] as? String == "string"
                && observationProperty["minLength"] as? Int == 1
                && observationProperty["maxLength"] as? Int == 2_000,
            "thread/start did not preserve the strict typed effect-report contract"
        )
        let nameIndices = messages.indices.filter {
            messages[$0]["method"] as? String == "thread/name/set"
        }
        guard let nameIndex = nameIndices.first,
              let startIndex = messages.firstIndex(where: {
                  $0["method"] as? String == "thread/start"
              }),
              let firstTurnIndex = messages.firstIndex(where: {
                  $0["method"] as? String == "turn/start"
              }),
              let nameParams = messages[nameIndex]["params"] as? [String: Any] else {
            throw VerificationFailure.failed("persistent Codex thread name was not sent")
        }
        try expect(
            nameIndices.count == 1
                && startIndex < firstTurnIndex && firstTurnIndex < nameIndex
                && nameParams["threadId"] as? String == "thread-1"
                && nameParams["name"] as? String == "Aurora — Open Notes",
            "the Desktop-visible title was not assigned once after work began"
        )
        guard let turnStart = messages.first(where: { $0["method"] as? String == "turn/start" }),
              let turnParams = turnStart["params"] as? [String: Any],
              let input = turnParams["input"] as? [[String: Any]],
              let textInput = input.first else {
            throw VerificationFailure.failed("turn/start input was malformed")
        }
        try expect(turnParams["effort"] as? String == "low"
                   && textInput["text"] as? String == "Open Notes"
                   && (textInput["text_elements"] as? [Any])?.isEmpty == true,
                   "turn input or explicit reasoning effort did not match the app-server schema")
        try expect(
            messages.filter { $0["method"] as? String == "account/read" }.count == 1,
            "a task RPC repeated the startup subscription-auth check"
        )
        try expect(
            turnParams["outputSchema"] == nil,
            "the public Codex turn still forces machine JSON into owner-visible messages"
        )
        guard let steer = messages.first(where: { $0["method"] as? String == "turn/steer" }),
              let steerParams = steer["params"] as? [String: Any] else {
            throw VerificationFailure.failed("turn/steer was not sent")
        }
        try expect(steerParams["expectedTurnId"] as? String == "turn-1",
                   "turn/steer lacked the active-turn precondition")

        await transport.emitNotification(
            method: "item/completed",
            params: [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "item": [
                    "id": "item-file-change",
                    "type": "fileChange",
                    "status": "completed",
                    "changes": [["path": "Sources/Aurora.swift", "kind": "update"]],
                ],
            ]
        )
        try await waitUntil {
            await events.events().contains { $0.method == "item/completed" }
        }
        guard let streamedItem = await events.events().first(where: {
            $0.method == "item/completed"
        }),
              let streamedParams = try JSONSerialization.jsonObject(
                with: streamedItem.paramsJSON
              ) as? [String: Any],
              let streamedPayload = streamedParams["item"] as? [String: Any] else {
            throw VerificationFailure.failed("streamed Codex item was not surfaced")
        }
        try expect(
            streamedItem.taskID == "owner.notes-demo"
                && streamedItem.threadID == "thread-1"
                && streamedItem.turnID == "turn-1"
                && streamedPayload["id"] as? String == "item-file-change"
                && streamedPayload["type"] as? String == "fileChange",
            "streamed progress lost its persistent task/thread provenance"
        )

        await transport.emitServerRequest(
            id: "approval-1",
            method: "item/permissions/requestApproval",
            params: ["threadId": "thread-1", "turnId": "turn-1"]
        )
        try await waitUntil {
            await events.events().contains { $0.serverRequestID == .string("approval-1") }
        }
        guard let requestEvent = await events.events().first(where: {
            $0.serverRequestID == .string("approval-1")
        }) else {
            throw VerificationFailure.failed("server approval request was not surfaced")
        }
        try expect(requestEvent.taskID == "owner.notes-demo"
                   && requestEvent.threadID == "thread-1"
                   && requestEvent.turnID == "turn-1",
                   "server approval request lost its task provenance")
        try await runtime.respondToServerRequest(
            .string("approval-1"),
            resultJSON: Data(#"{"decision":"decline"}"#.utf8)
        )
        let afterApproval = try decodeMessages(await transport.messageData())
        try expect(afterApproval.contains { message in
            message["id"] as? String == "approval-1"
                && (message["result"] as? [String: Any])?["decision"] as? String == "decline"
        }, "bounded server-request response was not returned")

        await transport.emitNotification(
            method: "turn/completed",
            params: [
                "threadId": "thread-1",
                "turn": ["id": "turn-1", "status": "completed"],
            ]
        )
        try await waitUntil { await runtime.activeTurnID(forTaskID: "owner.notes-demo") == nil }
        let second = try await runtime.continueTask(
            taskID: "owner.notes-demo",
            input: "Verify the result",
            reasoningEffort: .minimal
        )
        try expect(second.turnID == "turn-2", "continued task did not create a new turn")
        let continuedMessages = try decodeMessages(await transport.messageData())
        let continuedTurns = continuedMessages.filter {
            $0["method"] as? String == "turn/start"
        }
        try expect(
            continuedMessages.filter { $0["method"] as? String == "account/read" }.count == 1
                && continuedTurns.count == 2
                && (continuedTurns[0]["params"] as? [String: Any])?["effort"] as? String
                    == "low"
                && (continuedTurns[1]["params"] as? [String: Any])?["effort"] as? String
                    == "minimal",
            "the live transport did not reuse auth or apply the continuation QoS override"
        )

        try await runtime.renameThread(
            threadID: "thread-1",
            name: "Aurora — Renamed task"
        )
        try await runtime.archiveThread(threadID: "thread-1")
        try await runtime.unarchiveThread(threadID: "thread-1")
        let openedExistingThread = await runtime.openThreadInDesktop(
            threadID: "thread-1"
        )
        let managementMessages = try decodeMessages(await transport.messageData())
        let explicitRename = managementMessages.last(where: {
            $0["method"] as? String == "thread/name/set"
        })?["params"] as? [String: Any]
        let archive = managementMessages.last(where: {
            $0["method"] as? String == "thread/archive"
        })?["params"] as? [String: Any]
        let unarchive = managementMessages.last(where: {
            $0["method"] as? String == "thread/unarchive"
        })?["params"] as? [String: Any]
        let managedRegistrations = await desktopRegistrar.registrations()
        try expect(
            explicitRename?["threadId"] as? String == "thread-1"
                && explicitRename?["name"] as? String == "Aurora — Renamed task"
                && archive?["threadId"] as? String == "thread-1"
                && unarchive?["threadId"] as? String == "thread-1"
                && openedExistingThread
                && managedRegistrations == ["thread-1", "thread-1"],
            "typed Codex task mutation or Desktop navigation lost its exact thread identity"
        )
        do {
            try await runtime.renameThread(threadID: "thread-1", name: "  ")
            throw VerificationFailure.failed("an empty Codex task name was accepted")
        } catch CodexTaskRuntimeError.invalidInput {
            // Expected.
        }
        let invalidThreadOpened = await runtime.openThreadInDesktop(
            threadID: "not an opaque id"
        )
        try expect(
            invalidThreadOpened == false,
            "an invalid Codex task identity reached Desktop navigation"
        )
        await runtime.shutdown()
    }

    private static func verifyRawProjectThreadMessaging() async throws {
        let projectDirectory = URL(
            fileURLWithPath: "/verification/Aurora V4",
            isDirectory: true
        )
        let exactNewText = "Build the page exactly as we discussed — don’t add a wrapper."
        let newTransport = FakeCodexAppServerTransport()
        let newRuntime = makeRuntime(transport: newTransport)
        let rawOptions = CodexTaskThreadOptions(
            model: "gpt-5.6-sol",
            reasoningEffort: .medium,
            workingDirectory: projectDirectory,
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess,
            threadName: "Owner-directed website task"
        )
        let newHandle = try await newRuntime.startRawProjectThread(
            taskID: "project.new-site",
            input: exactNewText,
            options: rawOptions
        )
        try expect(
            newHandle.threadID == "thread-1" && newHandle.turnID == "turn-1",
            "raw project-thread creation lost its stable Codex identities"
        )
        let newMessages = try decodeMessages(await newTransport.messageData())
        guard let rawThreadStart = newMessages.first(where: {
            $0["method"] as? String == "thread/start"
        }),
              let rawThreadParams = rawThreadStart["params"] as? [String: Any],
              let rawTurnStart = newMessages.first(where: {
                  $0["method"] as? String == "turn/start"
              }),
              let rawTurnParams = rawTurnStart["params"] as? [String: Any],
              let rawTurnInput = rawTurnParams["input"] as? [[String: Any]] else {
            throw VerificationFailure.failed("raw project thread RPCs were missing")
        }
        try expect(
            rawThreadParams["cwd"] as? String == projectDirectory.path
                && rawThreadParams["ephemeral"] as? Bool == false
                && rawThreadParams["developerInstructions"] == nil
                && rawThreadParams["dynamicTools"] == nil
                && rawTurnInput.first?["text"] as? String == exactNewText,
            "new project conversation received Aurora scaffolding or modified owner text"
        )
        do {
            _ = try await newRuntime.startRawProjectThread(
                taskID: "project.invalid-scaffold",
                input: "Keep this exact.",
                options: CodexTaskThreadOptions(
                    workingDirectory: projectDirectory,
                    developerInstructions: "Aurora task wrapper"
                )
            )
            throw VerificationFailure.failed(
                "raw project creation accepted delegated-task developer instructions"
            )
        } catch CodexTaskRuntimeError.invalidInput {
            // Expected.
        }
        await newRuntime.shutdown()

        let existingThreadID = "thread-owner-existing"
        let exactExistingText = "Please continue from here; keep the teal header."
        let existingTransport = FakeCodexAppServerTransport()
        await existingTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: existingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await existingTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-owner-complete",
                "status": "completed",
                "itemsView": "notLoaded",
                "items": [],
            ]]),
        ])
        // A real owner-selected chat reached 281 MB. If this path regresses to
        // thread/read(includeTurns: true), the fake returns a response larger
        // than the verifier's 128 KiB inbound boundary and the send fails.
        await existingTransport.simulateOversizedHistoryOnIncludeTurns()
        let existingRuntime = makeRuntime(transport: existingTransport)
        let existingHandle = try await existingRuntime.sendExactMessage(
            taskID: "project.owner-existing",
            threadID: existingThreadID,
            input: exactExistingText,
            expectedWorkingDirectory: projectDirectory
        )
        try expect(
            existingHandle.threadID == existingThreadID
                && existingHandle.turnID == "turn-1",
            "terminal owner thread did not continue as one new turn"
        )
        let existingMessages = try decodeMessages(await existingTransport.messageData())
        guard let resume = existingMessages.first(where: {
            $0["method"] as? String == "thread/resume"
        }),
              let resumeParams = resume["params"] as? [String: Any],
              let continuedTurn = existingMessages.last(where: {
                  $0["method"] as? String == "turn/start"
              }),
              let continuedParams = continuedTurn["params"] as? [String: Any],
              let continuedInput = continuedParams["input"] as? [[String: Any]] else {
            throw VerificationFailure.failed("existing raw thread was not resumed and continued")
        }
        try expect(
            Set(resumeParams.keys) == Set(["threadId", "excludeTurns"])
                && resumeParams["threadId"] as? String == existingThreadID
                && resumeParams["excludeTurns"] as? Bool == true
                && continuedInput.first?["text"] as? String == exactExistingText
                && continuedParams["effort"] == nil
                && continuedParams["outputSchema"] == nil,
            "existing Codex settings were overridden or relayed text was rewritten"
        )
        let existingMethods = existingMessages.compactMap { $0["method"] as? String }
        guard let listIndex = existingMethods.firstIndex(of: "thread/list"),
              let turnsIndex = existingMethods.firstIndex(of: "thread/turns/list"),
              let resumeIndex = existingMethods.firstIndex(of: "thread/resume"),
              let turnIndex = existingMethods.lastIndex(of: "turn/start") else {
            throw VerificationFailure.failed("raw existing-thread validation sequence was incomplete")
        }
        guard let turnsRequest = existingMessages.first(where: {
            $0["method"] as? String == "thread/turns/list"
        }), let turnsParams = turnsRequest["params"] as? [String: Any] else {
            throw VerificationFailure.failed("bounded latest-turn lookup was missing")
        }
        try expect(
            listIndex < turnsIndex && turnsIndex < resumeIndex && resumeIndex < turnIndex
                && turnsParams["threadId"] as? String == existingThreadID
                && turnsParams["limit"] as? Int == 1
                && turnsParams["sortDirection"] as? String == "desc"
                && turnsParams["itemsView"] as? String == "notLoaded"
                && !existingMethods.contains("thread/read"),
            "owner-selected thread executed before unarchived/project validation"
        )

        let reusedEvents = EventCollector()
        await existingRuntime.setEventHandler { event in
            Task { await reusedEvents.append(event) }
        }
        await existingTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: existingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await existingTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": existingHandle.turnID,
                "status": "completed",
                "itemsView": "notLoaded",
                "items": [],
            ]]),
        ])
        await existingTransport.completeNextTurnBeforeReturningStartHandle()
        let reusedHandle = try await existingRuntime.sendExactMessage(
            taskID: "project.owner-existing",
            threadID: existingThreadID,
            input: "One tiny follow-up.",
            expectedWorkingDirectory: projectDirectory
        )
        try await Task.sleep(for: .milliseconds(25))
        let reusedEventsArrived = await reusedEvents.events().contains {
            $0.method == "turn/completed"
                && $0.taskID == "project.owner-existing"
                && $0.turnID == reusedHandle.turnID
        }
        let reusedActiveTurn = await existingRuntime.activeTurnID(
            forTaskID: "project.owner-existing"
        )
        try expect(
            reusedHandle.turnID == "turn-2"
                && reusedActiveTurn == nil
                && reusedEventsArrived,
            "a reused-chat completion that beat turn/start was dropped or left falsely running"
        )
        await existingRuntime.shutdown()

        let activeTransport = FakeCodexAppServerTransport()
        await activeTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: existingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await activeTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-already-running",
                "status": "inProgress",
                "itemsView": "notLoaded",
                "items": [],
            ]]),
        ])
        let activeRuntime = makeRuntime(transport: activeTransport)
        let activeText = "Also make the logo a little smaller."
        let steered = try await activeRuntime.sendRawProjectMessage(
            taskID: "project.owner-active",
            threadID: existingThreadID,
            input: activeText,
            expectedWorkingDirectory: projectDirectory
        )
        try expect(
            steered.turnID == "turn-already-running",
            "active owner thread did not retain its exact turn identity"
        )
        let activeMessages = try decodeMessages(await activeTransport.messageData())
        guard let activeSteer = activeMessages.first(where: {
            $0["method"] as? String == "turn/steer"
        }),
              let activeParams = activeSteer["params"] as? [String: Any],
              let activeInput = activeParams["input"] as? [[String: Any]] else {
            throw VerificationFailure.failed("active owner thread was not steered")
        }
        try expect(
            activeParams["expectedTurnId"] as? String == "turn-already-running"
                && activeInput.first?["text"] as? String == activeText
                && activeMessages.filter {
                    $0["method"] as? String == "turn/start"
                }.isEmpty,
            "active thread was forked or the owner's steering text changed"
        )
        await activeRuntime.shutdown()

        let raceTransport = FakeCodexAppServerTransport()
        await raceTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: existingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
            threadListFixture([
                desktopThreadFixture(
                    threadID: existingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await raceTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-before-race",
                "status": "completed",
                "itemsView": "notLoaded",
                "items": [],
            ]]),
            threadTurnsListFixture([[
                "id": "turn-won-race",
                "status": "inProgress",
                "itemsView": "notLoaded",
                "items": [],
            ]]),
        ])
        await raceTransport.failNextTurnStart(message: "A turn is already active")
        let raceRuntime = makeRuntime(transport: raceTransport)
        let raceText = "Use the second layout after all."
        let raceHandle = try await raceRuntime.sendRawProjectMessage(
            taskID: "project.owner-race",
            threadID: existingThreadID,
            input: raceText,
            expectedWorkingDirectory: projectDirectory
        )
        try expect(
            raceHandle.turnID == "turn-won-race",
            "changed turn state was not reconciled by the single bounded retry"
        )
        let raceMessages = try decodeMessages(await raceTransport.messageData())
        let racedStarts = raceMessages.filter { $0["method"] as? String == "turn/start" }
        let racedSteers = raceMessages.filter { $0["method"] as? String == "turn/steer" }
        let racedStartParams = racedStarts.first?["params"] as? [String: Any]
        let racedSteerParams = racedSteers.first?["params"] as? [String: Any]
        try expect(
            racedStarts.count == 1 && racedSteers.count == 1
                && racedSteerParams?["expectedTurnId"] as? String == "turn-won-race"
                && racedStartParams?["clientUserMessageId"] as? String
                    == racedSteerParams?["clientUserMessageId"] as? String,
            "changed-state recovery replayed more than once or targeted a stale turn"
        )
        await raceRuntime.shutdown()

        let archivedTransport = FakeCodexAppServerTransport()
        await archivedTransport.setThreadListResponses([threadListFixture([])])
        let archivedRuntime = makeRuntime(transport: archivedTransport)
        do {
            _ = try await archivedRuntime.sendRawProjectMessage(
                taskID: "project.archived",
                threadID: "thread-archived",
                input: "Continue this.",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed("archived thread was accepted as a live project target")
        } catch CodexTaskRuntimeError.projectMessagePreparationFailed(
            underlying: .threadUnavailable
        ) {
            // Expected.
        }
        let archivedMethods = try decodeMessages(
            await archivedTransport.messageData()
        ).compactMap { $0["method"] as? String }
        try expect(
            !archivedMethods.contains("thread/read")
                && !archivedMethods.contains("thread/turns/list")
                && !archivedMethods.contains("thread/resume")
                && !archivedMethods.contains("turn/start")
                && !archivedMethods.contains("turn/steer"),
            "archived-thread rejection reached an execution RPC"
        )
        await archivedRuntime.shutdown()

        let movedTransport = FakeCodexAppServerTransport()
        await movedTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: "thread-moved",
                    cwd: "/verification/Another Project",
                    turns: []
                ),
            ]),
        ])
        let movedRuntime = makeRuntime(transport: movedTransport)
        do {
            _ = try await movedRuntime.sendRawProjectMessage(
                taskID: "project.moved",
                threadID: "thread-moved",
                input: "Continue this.",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed("moved thread escaped its selected project boundary")
        } catch CodexTaskRuntimeError.projectMessagePreparationFailed(
            underlying: .threadWorkingDirectoryChanged
        ) {
            // Expected.
        }
        await movedRuntime.shutdown()

        let omittedViewTransport = FakeCodexAppServerTransport()
        await omittedViewTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: "thread-omitted-items-view",
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await omittedViewTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-defaults-to-full",
                "status": "completed",
                "items": [],
            ]]),
        ])
        let omittedViewRuntime = makeRuntime(transport: omittedViewTransport)
        do {
            _ = try await omittedViewRuntime.sendRawProjectMessage(
                taskID: "project.omitted-items-view",
                threadID: "thread-omitted-items-view",
                input: "Continue this.",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed(
                "a turn with an implicit full item view entered the bounded project path"
            )
        } catch CodexTaskRuntimeError.projectMessagePreparationFailed(
            underlying: .protocolViolation
        ) {
            // Expected: Turn.itemsView defaults to full when omitted.
        }
        let omittedViewMethods = try decodeMessages(
            await omittedViewTransport.messageData()
        ).compactMap { $0["method"] as? String }
        try expect(
            !omittedViewMethods.contains("thread/resume")
                && !omittedViewMethods.contains("turn/start")
                && !omittedViewMethods.contains("turn/steer"),
            "an unproven bounded turn response reached message submission"
        )
        await omittedViewRuntime.shutdown()
    }

    private static func verifyExactProjectThreadReconciliation() async throws {
        let projectDirectory = URL(
            fileURLWithPath: "/verification/Aurora V4",
            isDirectory: true
        )

        let terminalThreadID = "thread-project-terminal"
        let terminalTransport = FakeCodexAppServerTransport()
        await terminalTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: terminalThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await terminalTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-project-complete",
                "status": "completed",
                "itemsView": "summary",
                "items": [[
                    "id": "item-project-final",
                    "type": "agentMessage",
                    "phase": "final_answer",
                    "text": "The course plan is finished. Next, choose the day-two lab.",
                ]],
            ]]),
        ])
        await terminalTransport.simulateOversizedHistoryOnIncludeTurns()
        let terminalRuntime = makeRuntime(transport: terminalTransport)
        let terminal = try await terminalRuntime.reconcileExactProjectThread(
            taskID: "project.inspect-terminal",
            threadID: terminalThreadID,
            expectedTurnID: "turn-project-complete",
            expectedWorkingDirectory: projectDirectory
        )
        try expect(
            terminal.threadID == terminalThreadID
                && terminal.latestTurnID == "turn-project-complete"
                && terminal.status == .completed
                && terminal.resultSummary
                    == "The course plan is finished. Next, choose the day-two lab."
                && terminal.threadName == "Selected owner task"
                && terminal.workspacePath == projectDirectory.path,
            "read-only project reconciliation lost the terminal Codex result"
        )
        let terminalMessages = try decodeMessages(
            await terminalTransport.messageData()
        )
        let terminalMethods = terminalMessages.compactMap { $0["method"] as? String }
        let terminalTurnsParams = terminalMessages.first(where: {
            $0["method"] as? String == "thread/turns/list"
        })?["params"] as? [String: Any]
        try expect(
            terminalMethods.filter { $0 == "thread/list" }.count == 1
                && terminalMethods.filter { $0 == "thread/turns/list" }.count == 1
                && terminalTurnsParams?["threadId"] as? String == terminalThreadID
                && terminalTurnsParams?["limit"] as? Int == 1
                && terminalTurnsParams?["sortDirection"] as? String == "desc"
                && terminalTurnsParams?["itemsView"] as? String == "summary"
                && !terminalMethods.contains("thread/read")
                && !terminalMethods.contains("thread/resume")
                && !terminalMethods.contains("thread/start")
                && !terminalMethods.contains("turn/start")
                && !terminalMethods.contains("turn/steer"),
            "terminal project inspection mutated or resumed the selected thread"
        )
        let terminalMappedThread = await terminalRuntime.threadID(
            forTaskID: "project.inspect-terminal"
        )
        let terminalActiveTurn = await terminalRuntime.activeTurnID(
            forTaskID: "project.inspect-terminal"
        )
        try expect(
            terminalMappedThread == terminalThreadID && terminalActiveTurn == nil,
            "terminal project inspection did not preserve its exact task mapping"
        )
        await terminalRuntime.shutdown()

        let racingThreadID = "thread-project-racing"
        let racingTransport = FakeCodexAppServerTransport()
        await racingTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: racingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
            threadListFixture([
                desktopThreadFixture(
                    threadID: racingThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await racingTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-project-racing",
                "status": "inProgress",
                "itemsView": "summary",
                "items": [],
            ]]),
            threadTurnsListFixture([[
                "id": "turn-project-racing",
                "status": "completed",
                "itemsView": "summary",
                "items": [[
                    "id": "item-project-racing-final",
                    "type": "agentMessage",
                    "phase": "final_answer",
                    "text": "I finished the site and left one design question for you.",
                ]],
            ]]),
        ])
        let racingRuntime = makeRuntime(transport: racingTransport)
        let raced = try await racingRuntime.reconcileExactProjectThread(
            taskID: "project.inspect-racing",
            threadID: racingThreadID,
            expectedTurnID: "turn-project-racing",
            expectedWorkingDirectory: projectDirectory
        )
        try expect(
            raced.status == .completed
                && raced.latestTurnID == "turn-project-racing"
                && raced.resultSummary
                    == "I finished the site and left one design question for you.",
            "read→subscribe reconciliation missed a just-completed project turn"
        )
        let racingMessages = try decodeMessages(await racingTransport.messageData())
        guard let resume = racingMessages.first(where: {
            $0["method"] as? String == "thread/resume"
        }), let resumeParams = resume["params"] as? [String: Any] else {
            throw VerificationFailure.failed(
                "running project inspection did not subscribe to its existing thread"
            )
        }
        let racingMethods = racingMessages.compactMap { $0["method"] as? String }
        try expect(
            Set(resumeParams.keys) == Set(["threadId", "excludeTurns"])
                && resumeParams["threadId"] as? String == racingThreadID
                && resumeParams["excludeTurns"] as? Bool == true,
            "project inspection overrode settings while subscribing"
        )
        try expect(
            racingMethods.filter { $0 == "thread/list" }.count == 2
                && racingMethods.filter { $0 == "thread/turns/list" }.count == 2
                && racingMethods.filter { $0 == "thread/resume" }.count == 1
                && !racingMethods.contains("thread/read")
                && !racingMethods.contains("thread/start")
                && !racingMethods.contains("turn/start")
                && !racingMethods.contains("turn/steer"),
            "project reconciliation started or modified a model turn"
        )
        let racingMappedThread = await racingRuntime.threadID(
            forTaskID: "project.inspect-racing"
        )
        let racingActiveTurn = await racingRuntime.activeTurnID(
            forTaskID: "project.inspect-racing"
        )
        try expect(
            racingMappedThread == racingThreadID && racingActiveTurn == nil,
            "completed race reconciliation left a stale active turn"
        )
        await racingRuntime.shutdown()

        let runningThreadID = "thread-project-running"
        let runningTurn: [String: Any] = [
            "id": "turn-project-running",
            "status": "inProgress",
            "itemsView": "summary",
            "items": [],
        ]
        let runningTransport = FakeCodexAppServerTransport()
        await runningTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: runningThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
            threadListFixture([
                desktopThreadFixture(
                    threadID: runningThreadID,
                    cwd: projectDirectory.path,
                    turns: []
                ),
            ]),
        ])
        await runningTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([runningTurn]),
            threadTurnsListFixture([runningTurn]),
        ])
        let runningRuntime = makeRuntime(transport: runningTransport)
        let running = try await runningRuntime.reconcileExactProjectThread(
            taskID: "project.inspect-running",
            threadID: runningThreadID,
            expectedTurnID: "turn-project-running",
            expectedWorkingDirectory: projectDirectory
        )
        let reconciledActiveTurn = await runningRuntime.activeTurnID(
            forTaskID: "project.inspect-running"
        )
        try expect(
            running.status == .running
                && running.latestTurnID == "turn-project-running"
                && reconciledActiveTurn == "turn-project-running",
            "live project reconciliation did not retain its active turn"
        )
        let runningMethods = try decodeMessages(
            await runningTransport.messageData()
        ).compactMap { $0["method"] as? String }
        try expect(
            runningMethods.filter { $0 == "thread/list" }.count == 2
                && runningMethods.filter { $0 == "thread/turns/list" }.count == 2
                && runningMethods.filter { $0 == "thread/resume" }.count == 1
                && !runningMethods.contains("thread/read")
                && !runningMethods.contains("turn/start")
                && !runningMethods.contains("turn/steer"),
            "live project inspection emitted an action RPC"
        )
        await runningRuntime.shutdown()

        let changedThreadID = "thread-project-changed-turn"
        let changedTransport = FakeCodexAppServerTransport()
        await changedTransport.setThreadListResponses([threadListFixture([
            desktopThreadFixture(
                threadID: changedThreadID,
                cwd: projectDirectory.path,
                turns: []
            ),
        ])])
        await changedTransport.setThreadTurnsListResponses([
            threadTurnsListFixture([[
                "id": "turn-unrelated-latest",
                "status": "inProgress",
                "itemsView": "summary",
                "items": [],
            ]]),
        ])
        let changedRuntime = makeRuntime(transport: changedTransport)
        do {
            _ = try await changedRuntime.reconcileExactProjectThread(
                taskID: "project.inspect-changed-turn",
                threadID: changedThreadID,
                expectedTurnID: "turn-durably-bound",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed(
                "an unrelated latest project turn was adopted during exact reconciliation"
            )
        } catch CodexTaskRuntimeError.expectedProjectTurnChanged {
            // Expected: reject before resume, task binding, or event sync.
        }
        let changedMethods = try decodeMessages(
            await changedTransport.messageData()
        ).compactMap { $0["method"] as? String }
        let changedMapping = await changedRuntime.threadID(
            forTaskID: "project.inspect-changed-turn"
        )
        try expect(
            changedMapping == nil
                && !changedMethods.contains("thread/resume")
                && changedMethods.filter { $0 == "thread/turns/list" }.count == 1,
            "turn mismatch was detected only after the unrelated thread was bound"
        )
        await changedRuntime.shutdown()

        let archivedTransport = FakeCodexAppServerTransport()
        await archivedTransport.setThreadListResponses([threadListFixture([])])
        let archivedRuntime = makeRuntime(transport: archivedTransport)
        do {
            _ = try await archivedRuntime.reconcileExactProjectThread(
                taskID: "project.inspect-archived",
                threadID: "thread-project-archived",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed(
                "archived project thread was accepted for reconciliation"
            )
        } catch CodexTaskRuntimeError.threadUnavailable {
            // Expected.
        }
        let archivedMethods = try decodeMessages(
            await archivedTransport.messageData()
        ).compactMap { $0["method"] as? String }
        try expect(
            !archivedMethods.contains("thread/read")
                && !archivedMethods.contains("thread/turns/list")
                && !archivedMethods.contains("thread/resume")
                && !archivedMethods.contains("turn/start")
                && !archivedMethods.contains("turn/steer"),
            "archived project inspection crossed its validation boundary"
        )
        await archivedRuntime.shutdown()

        let movedTransport = FakeCodexAppServerTransport()
        await movedTransport.setThreadListResponses([
            threadListFixture([
                desktopThreadFixture(
                    threadID: "thread-project-moved",
                    cwd: "/verification/Another Project",
                    turns: []
                ),
            ]),
        ])
        let movedRuntime = makeRuntime(transport: movedTransport)
        do {
            _ = try await movedRuntime.reconcileExactProjectThread(
                taskID: "project.inspect-moved",
                threadID: "thread-project-moved",
                expectedWorkingDirectory: projectDirectory
            )
            throw VerificationFailure.failed(
                "moved project thread was accepted for reconciliation"
            )
        } catch CodexTaskRuntimeError.threadWorkingDirectoryChanged {
            // Expected.
        }
        let movedMethods = try decodeMessages(
            await movedTransport.messageData()
        ).compactMap { $0["method"] as? String }
        try expect(
            !movedMethods.contains("thread/read")
                && !movedMethods.contains("thread/resume")
                && !movedMethods.contains("turn/start")
                && !movedMethods.contains("turn/steer"),
            "moved project inspection crossed its project boundary"
        )
        await movedRuntime.shutdown()
    }

    private static func verifyRestartResumesMappedThread() async throws {
        let transport = FakeCodexAppServerTransport()
        let runtime = makeRuntime(transport: transport)
        let projectDirectory = URL(
            fileURLWithPath: "/verification/Aurora V4",
            isDirectory: true
        )
        let first = try await runtime.startTask(
            taskID: "resume-task",
            input: "First turn",
            options: CodexTaskThreadOptions(
                reasoningEffort: .medium,
                workingDirectory: projectDirectory,
                approvalPolicy: .onRequest,
                sandboxMode: .workspaceWrite,
                threadName: "Aurora — Persistent build"
            )
        )
        await transport.emitNotification(
            method: "turn/completed",
            params: [
                "threadId": first.threadID,
                "turn": ["id": first.turnID, "status": "completed"],
            ]
        )
        try await waitUntil { await runtime.activeTurnID(forTaskID: "resume-task") == nil }

        try await runtime.restart()
        let restoredThreadID = await runtime.threadID(forTaskID: "resume-task")
        try expect(restoredThreadID == first.threadID,
                   "restart discarded the durable task/thread mapping")
        _ = try await runtime.continueTask(taskID: "resume-task", input: "Second turn")
        let messages = try decodeMessages(await transport.messageData())
        let resumeIndex = messages.firstIndex(where: { $0["method"] as? String == "thread/resume" })
        let lastTurnIndex = messages.lastIndex(where: { $0["method"] as? String == "turn/start" })
        try expect(resumeIndex != nil && lastTurnIndex != nil && resumeIndex! < lastTurnIndex!,
                   "restart did not resume the persisted thread before its next turn")
        guard let resumeIndex,
              let resumeParams = messages[resumeIndex]["params"] as? [String: Any] else {
            throw VerificationFailure.failed("thread/resume parameters were missing")
        }
        let threadStarts = messages.filter { $0["method"] as? String == "thread/start" }
        let threadNames = messages.filter { $0["method"] as? String == "thread/name/set" }
        try expect(
            resumeParams["threadId"] as? String == first.threadID
                && resumeParams["cwd"] as? String == projectDirectory.path
                && resumeParams["approvalPolicy"] as? String == "on-request"
                && resumeParams["sandbox"] as? String == "workspace-write"
                && threadStarts.count == 1
                && threadNames.count == 1,
            "runtime restart forked or detached the task from its persistent project-affinity thread"
        )
        try expect(
            messages.filter { $0["method"] as? String == "account/read" }.count == 2,
            "restart did not authenticate exactly once per transport lifecycle"
        )
        let turnStarts = messages.filter { $0["method"] as? String == "turn/start" }
        try expect(
            turnStarts.count == 2 && turnStarts.allSatisfy {
                ($0["params"] as? [String: Any])?["effort"] as? String == "medium"
            },
            "reasoning effort did not survive a persistent-thread restart"
        )
        let counts = await transport.counts()
        try expect(counts.starts == 2 && counts.stops >= 1,
                   "restart did not replace exactly one app-server process")

        await transport.terminateUnexpectedly(exitCode: 7)
        try await waitUntil { await runtime.accountSnapshot == nil }
        try await runtime.start()
        let restartedCounts = await transport.counts()
        try expect(restartedCounts.starts == 3,
                   "runtime could not recover after unexpected process termination")
        let restartedMessages = try decodeMessages(await transport.messageData())
        try expect(
            restartedMessages.filter { $0["method"] as? String == "account/read" }.count == 3,
            "unexpected transport replacement did not force fresh subscription authentication"
        )
        await runtime.shutdown()
    }

    private static func verifyReconciliationClosesReadSubscribeRace() async throws {
        let transport = FakeCodexAppServerTransport()
        let runtime = makeRuntime(transport: transport)
        let threadID = "thread-persisted-website"
        let turnID = "turn-persisted-website"
        await transport.setThreadReadResponses([
            [
                "thread": [
                    "id": threadID,
                    "name": "Aurora — Build the sample-site website",
                    "cwd": "/verification/Aurora V4",
                    "status": ["type": "active", "activeFlags": []],
                    "turns": [[
                        "id": turnID,
                        "status": "inProgress",
                        "items": [],
                    ]],
                ],
            ],
            [
                "thread": [
                    "id": threadID,
                    "name": "Aurora — Build the sample-site website",
                    "cwd": "/verification/Aurora V4",
                    // A persisted thread may be notLoaded even though its last
                    // turn carries terminal truth.
                    "status": ["type": "notLoaded"],
                    "turns": [
                        [
                            "id": "turn-earlier-unrelated",
                            "status": "completed",
                            "items": [[
                                "id": "stale-reported-effect",
                                "type": "dynamicToolCall",
                                "namespace": NSNull(),
                                "tool": "report_effect_result",
                                "arguments": [
                                    "outcome": "verified",
                                    "observed_postcondition": "An earlier page was visible.",
                                ],
                                "status": "completed",
                                "success": true,
                            ]],
                        ],
                        [
                            "id": turnID,
                            "status": "completed",
                            "items": [
                                [
                                    "id": "file-effect",
                                    "type": "fileChange",
                                    "status": "completed",
                                    "changes": [[
                                        "path": "index.html",
                                        "kind": "update",
                                    ]],
                                ],
                                [
                                    "id": "mcp-effect",
                                    "type": "mcpToolCall",
                                    "server": "verified-server",
                                    "tool": "verified-tool",
                                    "status": "completed",
                                    "error": NSNull(),
                                    "result": [
                                        "structuredContent": [
                                            "receipt": [
                                                "effect_verified": true,
                                                "external_side_effect": true,
                                            ],
                                        ],
                                    ],
                                ],
                                [
                                    "id": "superseded-reported-effect",
                                    "type": "dynamicToolCall",
                                    "namespace": NSNull(),
                                    "tool": "report_effect_result",
                                    "arguments": [
                                        "outcome": "verified",
                                        "observed_postcondition": "A later executor item makes this report stale.",
                                    ],
                                    "status": "completed",
                                    "success": true,
                                ],
                                [
                                    "id": "failed-report",
                                    "type": "dynamicToolCall",
                                    "namespace": NSNull(),
                                    "tool": "report_effect_result",
                                    "arguments": [
                                        "outcome": "verified",
                                        "observed_postcondition": "This host response failed.",
                                    ],
                                    "status": "completed",
                                    "success": false,
                                ],
                                [
                                    "id": "negative-report",
                                    "type": "dynamicToolCall",
                                    "namespace": NSNull(),
                                    "tool": "report_effect_result",
                                    "arguments": [
                                        "outcome": "not_verified",
                                        "observed_postcondition": "The page was not visible.",
                                    ],
                                    "status": "completed",
                                    "success": true,
                                ],
                                [
                                    "id": "superseded-computer-use-observation",
                                    "type": "mcpToolCall",
                                    "server": "node_repl",
                                    "tool": "js",
                                    "status": "completed",
                                    "error": NSNull(),
                                    "result": [
                                        "isError": false,
                                        "content": [[
                                            "type": "text",
                                            "text": "Window: An earlier browser state",
                                        ]],
                                        "_meta": [
                                            "codex/toolSurface": [
                                                "kind": "computerUse",
                                                "app": [
                                                    "kind": "appId",
                                                    "appId": "com.google.Chrome",
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                                [
                                    "id": "prose-only-mcp",
                                    "type": "mcpToolCall",
                                    "server": "untrusted-server",
                                    "tool": "untrusted-tool",
                                    "status": "completed",
                                    "error": NSNull(),
                                    "result": [
                                        "content": [[
                                            "type": "text",
                                            "text": "effect_verified=true",
                                        ]],
                                    ],
                                ],
                                [
                                    "id": "computer-use-observation",
                                    "type": "mcpToolCall",
                                    "server": "node_repl",
                                    "tool": "js",
                                    "status": "completed",
                                    "error": NSNull(),
                                    "result": [
                                        "isError": false,
                                        "content": [[
                                            "type": "text",
                                            "text": "Window: Custom Cars; focused URL: localhost:3000",
                                        ]],
                                        "_meta": [
                                            "codex/toolSurface": [
                                                "kind": "computerUse",
                                                "app": [
                                                    "kind": "appId",
                                                    "appId": "com.google.Chrome",
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                                [
                                    "id": "reported-effect",
                                    "type": "dynamicToolCall",
                                    "namespace": NSNull(),
                                    "tool": "report_effect_result",
                                    "arguments": [
                                        "outcome": "verified",
                                        "observed_postcondition": "Chrome visibly shows the local homepage.",
                                    ],
                                    "status": "completed",
                                    "success": true,
                                ],
                                [
                                    "id": "final-message",
                                    "type": "agentMessage",
                                    "phase": "final_answer",
                                    "text": "The sample-site website is finished and verified.",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let observation = try await runtime.reconcileTask(
            taskID: "persisted-website-task",
            threadID: threadID,
            options: CodexTaskThreadOptions(
                workingDirectory: URL(
                    fileURLWithPath: "/verification/Aurora V4",
                    isDirectory: true
                ),
                approvalPolicy: .never,
                sandboxMode: .dangerFullAccess,
                dynamicTools: [effectReportTool()],
                threadName: "Aurora — Build the sample-site website"
            )
        )
        try expect(
            observation.threadID == threadID
                && observation.latestTurnID == turnID
                && observation.status == .completed
                && observation.resultSummary
                    == "The sample-site website is finished and verified.",
            "reconciliation trusted stale thread status or lost the latest turn result"
        )
        try expect(
            observation.effectReceipts == [
                DelegateTaskEffectReceipt(
                    kind: .fileChange,
                    receiptID: "file-effect",
                    executor: "codex_file_change"
                ),
                DelegateTaskEffectReceipt(
                    kind: .structuredToolResult,
                    receiptID: "mcp-effect",
                    executor: "verified-server/verified-tool"
                ),
                DelegateTaskEffectReceipt(
                    kind: .toolSurfaceObservation,
                    receiptID: "computer-use-observation",
                    executor: "node_repl/js"
                ),
                DelegateTaskEffectReceipt(
                    kind: .reportedEffect,
                    receiptID: "reported-effect",
                    executor: "dynamic/report_effect_result"
                ),
            ],
            "reconciliation inherited stale, prose-only, failed, or negative effect claims"
        )
        let restoredThreadID = await runtime.threadID(forTaskID: "persisted-website-task")
        let restoredTurnID = await runtime.activeTurnID(forTaskID: "persisted-website-task")
        try expect(
            restoredThreadID == threadID && restoredTurnID == nil,
            "reconciliation did not restore the exact task/thread binding or clear terminal activity"
        )
        let methods = try decodeMessages(await transport.messageData()).compactMap {
            $0["method"] as? String
        }
        guard let firstRead = methods.firstIndex(of: "thread/read"),
              let resume = methods.firstIndex(of: "thread/resume"),
              let secondRead = methods.lastIndex(of: "thread/read") else {
            throw VerificationFailure.failed("reconciliation omitted read/resume/read ordering")
        }
        try expect(
            firstRead < resume && resume < secondRead,
            "reconciliation did not close the read-to-subscribe completion race"
        )
        await runtime.shutdown()
    }

    private static func verifyBrowserSurfaceReceiptRecovery() async throws {
        let transport = FakeCodexAppServerTransport()
        let runtime = makeRuntime(transport: transport)
        let threadID = "thread-browser-observation"
        let turnID = "turn-browser-observation"
        await transport.setThreadReadResponses([[
            "thread": [
                "id": threadID,
                "name": "Aurora — Show the website",
                "cwd": "/verification/Aurora V4",
                "status": ["type": "notLoaded"],
                "turns": [[
                    "id": turnID,
                    "status": "completed",
                    "items": [[
                        "id": "browser-use-observation",
                        "type": "mcpToolCall",
                        "server": "node_repl",
                        "tool": "js",
                        "status": "completed",
                        "error": NSNull(),
                        "result": [
                            "content": [[
                                "type": "text",
                                "text": "Active tab: http://localhost:3000/",
                            ]],
                            "_meta": [
                                "codex/toolSurface": [
                                    "kind": "browserUse",
                                    "backend": "extension",
                                    "browserId": "chrome-owner-session",
                                ],
                            ],
                        ],
                    ]],
                ]],
            ],
        ]])
        let observation = try await runtime.reconcileTask(
            taskID: "browser-observation-task",
            threadID: threadID,
            options: CodexTaskThreadOptions(
                workingDirectory: URL(
                    fileURLWithPath: "/verification/Aurora V4",
                    isDirectory: true
                ),
                approvalPolicy: .never,
                sandboxMode: .dangerFullAccess,
                threadName: "Aurora — Show the website"
            )
        )
        try expect(
            observation.effectReceipts == [DelegateTaskEffectReceipt(
                kind: .toolSurfaceObservation,
                receiptID: "browser-use-observation",
                executor: "node_repl/js"
            )],
            "reconciliation did not recover a concrete trusted Browser Use observation"
        )

        let failedThreadID = "thread-failed-browser-observation"
        await transport.setThreadReadResponses([[
            "thread": [
                "id": failedThreadID,
                "name": "Aurora — Failed website observation",
                "cwd": "/verification/Aurora V4",
                "status": ["type": "notLoaded"],
                "turns": [[
                    "id": "turn-failed-browser-observation",
                    "status": "completed",
                    "items": [[
                        "id": "failed-browser-use-observation",
                        "type": "mcpToolCall",
                        "server": "node_repl",
                        "tool": "js",
                        "status": "completed",
                        "error": NSNull(),
                        "result": [
                            "isError": true,
                            "content": [[
                                "type": "text",
                                "text": "The browser operation failed.",
                            ]],
                            "_meta": [
                                "codex/toolSurface": [
                                    "kind": "browserUse",
                                    "backend": "extension",
                                    "browserId": "chrome-owner-session",
                                ],
                            ],
                        ],
                    ]],
                ]],
            ],
        ]])
        let failedObservation = try await runtime.reconcileTask(
            taskID: "failed-browser-observation-task",
            threadID: failedThreadID,
            options: CodexTaskThreadOptions(
                workingDirectory: URL(
                    fileURLWithPath: "/verification/Aurora V4",
                    isDirectory: true
                ),
                approvalPolicy: .never,
                sandboxMode: .dangerFullAccess,
                threadName: "Aurora — Failed website observation"
            )
        )
        try expect(
            failedObservation.effectReceipts.isEmpty,
            "reconciliation accepted an explicitly failed Browser Use observation"
        )
        await runtime.shutdown()
    }

    private static func verifyChatGPTOnlyAndInputBounds() async throws {
        let apiTransport = FakeCodexAppServerTransport(accountMode: .apiKey)
        let apiRuntime = makeRuntime(transport: apiTransport)
        do {
            try await apiRuntime.start()
            throw VerificationFailure.failed("API-key Codex auth was accepted as subscription auth")
        } catch let error as CodexTaskRuntimeError {
            try expect(error == .chatGPTLoginRequired,
                       "non-ChatGPT auth returned the wrong bounded failure")
        }

        let boundedTransport = FakeCodexAppServerTransport()
        let runtime = CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: URL(fileURLWithPath: "/verification/codex"),
                codexHomeURL: URL(fileURLWithPath: "/verification/.codex", isDirectory: true),
                requestTimeout: 2,
                maximumInboundLineBytes: 32 * 1_024,
                maximumOutboundMessageBytes: 8 * 1_024,
                maximumStandardErrorBytes: 4 * 1_024,
                maximumInputBytes: 1_024,
                maximumDeveloperInstructionBytes: 1_024,
                maximumPendingServerRequests: 4,
                terminationGracePeriod: 0.2
            ),
            transport: boundedTransport,
            executableValidator: AcceptingExecutableValidator()
        )
        do {
            _ = try await runtime.startTask(
                taskID: "oversized",
                input: String(repeating: "x", count: 1_025)
            )
            throw VerificationFailure.failed("oversized input reached the app-server")
        } catch let error as CodexTaskRuntimeError {
            try expect(error == .invalidInput, "oversized input returned the wrong failure")
        }
        for invalidName in [
            " Aurora — leading space",
            "Aurora — trailing space ",
            "Aurora — hidden\nline",
            String(repeating: "x", count: 513),
        ] {
            do {
                _ = try await runtime.startTask(
                    taskID: "invalid-name-\(UUID().uuidString)",
                    input: "This turn must not start.",
                    options: CodexTaskThreadOptions(threadName: invalidName)
                )
                throw VerificationFailure.failed("an invalid Codex thread name was accepted")
            } catch let error as CodexTaskRuntimeError {
                try expect(error == .invalidInput,
                           "an invalid thread name returned the wrong failure")
            }
        }
        let missingRequiredProperty = CodexTaskDynamicToolSpec(
            name: "report_effect_result",
            description: "Invalid schema used only by the verifier.",
            inputSchema: CodexTaskDynamicToolInputSchema(
                properties: [
                    "outcome": CodexTaskDynamicToolStringProperty()
                ],
                required: ["missing_property"]
            )
        )
        let unboundedProperty = CodexTaskDynamicToolSpec(
            name: "report_effect_result",
            description: "Invalid schema used only by the verifier.",
            inputSchema: CodexTaskDynamicToolInputSchema(
                properties: [
                    "observation": CodexTaskDynamicToolStringProperty(
                        maximumLength: 4_097
                    )
                ]
            )
        )
        for (index, invalidTools) in [
            [effectReportTool(), effectReportTool()],
            [missingRequiredProperty],
            [unboundedProperty],
        ].enumerated() {
            do {
                _ = try await runtime.startTask(
                    taskID: "invalid-dynamic-tool-\(index)",
                    input: "This turn must not start.",
                    options: CodexTaskThreadOptions(dynamicTools: invalidTools)
                )
                throw VerificationFailure.failed("an invalid dynamic tool schema was accepted")
            } catch let error as CodexTaskRuntimeError {
                try expect(
                    error == .invalidInput,
                    "an invalid dynamic tool schema returned the wrong failure"
                )
            }
        }
        let boundedCounts = await boundedTransport.counts()
        try expect(boundedCounts.starts == 0,
                   "invalid input launched a process before validation")
    }

    private static func verifyDuplicateServerRequestFailsClosed() async throws {
        let transport = FakeCodexAppServerTransport()
        let runtime = makeRuntime(transport: transport)
        try await runtime.start()
        await transport.emitServerRequest(
            id: "duplicate-approval",
            method: "item/permissions/requestApproval",
            params: [:]
        )
        await transport.emitServerRequest(
            id: "duplicate-approval",
            method: "item/permissions/requestApproval",
            params: [:]
        )
        try await waitUntil { await runtime.accountSnapshot == nil }
        let counts = await transport.counts()
        try expect(counts.stops == 1,
                   "duplicate JSON-RPC server request IDs did not fail closed")
        do {
            try await runtime.rejectServerRequest(
                .string("duplicate-approval"),
                message: "No authorization is available."
            )
            throw VerificationFailure.failed(
                "a duplicate server request survived the protocol reset"
            )
        } catch let error as CodexTaskRuntimeError {
            try expect(error == .unknownServerRequest,
                       "protocol reset retained a stale server request")
        }
        await runtime.shutdown()
    }

    private static func verifyBoundaryAndAccountChangesFailClosed() async throws {
        for boundaryMode in [
            FakeCodexAppServerTransport.BoundaryMode.widenedNetwork,
            .wrongWorkingDirectory,
        ] {
            let transport = FakeCodexAppServerTransport(boundaryMode: boundaryMode)
            let runtime = makeRuntime(transport: transport)
            do {
                _ = try await runtime.startTask(
                    taskID: "boundary-" + String(describing: boundaryMode),
                    input: "Stay inside the authorized boundary",
                    options: CodexTaskThreadOptions(
                        workingDirectory: URL(fileURLWithPath: "/verification", isDirectory: true),
                        approvalPolicy: .never,
                        sandboxMode: .workspaceWrite
                    )
                )
                throw VerificationFailure.failed("a widened thread boundary was accepted")
            } catch let error as CodexTaskRuntimeError {
                try expect(error == .protocolViolation,
                           "a widened boundary returned the wrong failure")
            }
            let counts = await transport.counts()
            try expect(counts.stops == 1,
                       "a widened boundary did not tear down the task runtime")
        }

        let authTransport = FakeCodexAppServerTransport()
        let authRuntime = makeRuntime(transport: authTransport)
        let authHandle = try await authRuntime.startTask(
            taskID: "auth-change",
            input: "Create a subscription-backed task"
        )
        await authTransport.emitNotification(
            method: "turn/completed",
            params: [
                "threadId": authHandle.threadID,
                "turn": ["id": authHandle.turnID, "items": [], "status": "completed"],
            ]
        )
        try await waitUntil { await authRuntime.activeTurnID(forTaskID: "auth-change") == nil }
        await authTransport.setAccountMode(.apiKey)
        try await waitUntil {
            let counts = await authTransport.counts()
            return await authRuntime.accountSnapshot == nil && counts.stops >= 1
        }
        do {
            _ = try await authRuntime.continueTask(
                taskID: "auth-change",
                input: "This must not run with API-key auth"
            )
            throw VerificationFailure.failed("an API-key account change reached a continued turn")
        } catch let error as CodexTaskRuntimeError {
            try expect(error == .chatGPTLoginRequired,
                       "an account-mode change returned the wrong failure")
        }
        let messages = try decodeMessages(await authTransport.messageData())
        try expect(messages.filter { $0["method"] as? String == "turn/start" }.count == 1,
                   "the runtime did not re-check subscription auth before continuing a task")
        await authRuntime.shutdown()
    }

    private static func verifyStaleApprovalAndSequenceGapFailClosed() async throws {
        let approvalTransport = FakeCodexAppServerTransport()
        let approvalRuntime = makeRuntime(transport: approvalTransport)
        let handle = try await approvalRuntime.startTask(
            taskID: "stale-approval",
            input: "Begin a bounded task"
        )
        await approvalTransport.emitServerRequest(
            id: "stale-request",
            method: "item/permissions/requestApproval",
            params: ["threadId": handle.threadID, "turnId": handle.turnID]
        )
        await approvalTransport.emitNotification(
            method: "turn/completed",
            params: [
                "threadId": handle.threadID,
                "turn": ["id": handle.turnID, "items": [], "status": "completed"],
            ]
        )
        try await waitUntil { await approvalRuntime.activeTurnID(forTaskID: "stale-approval") == nil }
        do {
            try await approvalRuntime.rejectServerRequest(
                .string("stale-request"),
                message: "No authorization is available."
            )
            throw VerificationFailure.failed("a completed turn retained a stale approval request")
        } catch let error as CodexTaskRuntimeError {
            try expect(error == .unknownServerRequest,
                       "a stale approval returned the wrong bounded failure")
        }
        await approvalRuntime.shutdown()

        let sequenceTransport = FakeCodexAppServerTransport()
        let sequenceRuntime = makeRuntime(transport: sequenceTransport)
        try await sequenceRuntime.start()
        await sequenceTransport.emitSequenceGap()
        try await waitUntil { await sequenceRuntime.accountSnapshot == nil }
        let sequenceCounts = await sequenceTransport.counts()
        try expect(sequenceCounts.stops == 1,
                   "an inbound stream gap did not fail closed")
        await sequenceRuntime.shutdown()

        let protocolTransport = FakeCodexAppServerTransport()
        let protocolRuntime = makeRuntime(transport: protocolTransport)
        try await protocolRuntime.start()
        await protocolTransport.emitProtocolFailure()
        try await waitUntil { await protocolRuntime.accountSnapshot == nil }
        let protocolCounts = await protocolTransport.counts()
        try expect(
            protocolCounts.stops == 1,
            "a malformed WebSocket frame did not fail closed"
        )
        await protocolRuntime.shutdown()
    }

    private static func verifyLargeInboundEventAndExplicitOverflow() async throws {
        let transport = FakeCodexAppServerTransport()
        let events = EventCollector()
        let runtime = CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: URL(fileURLWithPath: "/verification/codex"),
                codexHomeURL: URL(
                    fileURLWithPath: "/verification/.codex",
                    isDirectory: true
                ),
                requestTimeout: 2
            ),
            transport: transport,
            executableValidator: AcceptingExecutableValidator(),
            sharedDaemonProbe: VerificationSharedDaemonProbe(result: .unavailable)
        )
        await runtime.setEventHandler { event in
            Task { await events.append(event) }
        }

        try await runtime.start()
        let launches = await transport.launchData()
        try expect(
            launches.first?.maximumInboundLineBytes == 8 * 1_024 * 1_024,
            "the production inbound line allowance did not reach the transport"
        )
        try expect(
            launches.first?.maximumBufferedInboundBytes == 32 * 1_024 * 1_024,
            "the aggregate inbound byte budget did not reach the transport"
        )

        let imageResultBytes = (29 * 1_024 * 1_024) / 10
        await transport.emitNotification(
            method: "verification/large-image-result",
            params: ["result": String(repeating: "x", count: imageResultBytes)]
        )
        try await waitUntil(timeout: 2) {
            await events.events().contains { event in
                event.method == "verification/large-image-result"
                    && event.paramsJSON.count > 2 * 1_024 * 1_024
            }
        }
        let accountAfterLargeEvent = await runtime.accountSnapshot
        let countsAfterLargeEvent = await transport.counts()
        try expect(
            accountAfterLargeEvent?.authenticationType == "chatgpt"
                && countsAfterLargeEvent.stops == 0,
            "a roughly 2.9 MiB image result still stopped the Codex runtime"
        )

        await transport.emitInboundOverflow()
        try await waitUntil {
            await events.events().contains { $0.method == "$runtime/inbound-overflow" }
        }
        let countsAfterOverflow = await transport.counts()
        let accountAfterOverflow = await runtime.accountSnapshot
        try expect(
            accountAfterOverflow == nil && countsAfterOverflow.stops == 1,
            "an event beyond the bounded transport allowance did not fail explicitly"
        )
        await runtime.shutdown()
    }

    private static func verifyFoundationTransportByteBudget() async throws {
        let largeTransport = FoundationCodexAppServerTransport()
        let largeGeneration = UUID()
        let largeStream = try await largeTransport.start(CodexAppServerLaunch(
            generation: largeGeneration,
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print \"x\" x 2905607, \"\\n\";"],
            environment: ["PATH": "/usr/bin:/bin"],
            maximumInboundLineBytes: 8 * 1_024 * 1_024,
            maximumBufferedInboundBytes: 32 * 1_024 * 1_024,
            maximumOutboundMessageBytes: 4_096,
            maximumStandardErrorBytes: 1_024,
            terminationGracePeriod: 0.2
        ))
        var largeLineBytes: Int?
        var largeOverflowed = false
        for await event in largeStream {
            switch event {
            case .line(_, let line):
                largeLineBytes = line.data.count
            case .inboundOverflow:
                largeOverflowed = true
            case .protocolFailure:
                throw VerificationFailure.failed(
                    "the Foundation JSONL transport emitted a WebSocket protocol failure"
                )
            case .terminated:
                break
            }
            if case .terminated = event { break }
        }
        await largeTransport.stop()
        try expect(
            largeLineBytes == 2_905_607 && !largeOverflowed,
            "the Foundation transport rejected the proven 2,905,607-byte event"
        )

        let burstTransport = FoundationCodexAppServerTransport()
        let burstGeneration = UUID()
        let burstStream = try await burstTransport.start(CodexAppServerLaunch(
            generation: burstGeneration,
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "for (1..3) { print \"x\" x 3000, \"\\n\"; }"],
            environment: ["PATH": "/usr/bin:/bin"],
            maximumInboundLineBytes: 4_096,
            maximumBufferedInboundBytes: 7_000,
            maximumOutboundMessageBytes: 4_096,
            maximumStandardErrorBytes: 1_024,
            terminationGracePeriod: 0.2
        ))
        var burstEvents: [CodexAppServerTransportEvent] = []
        for await event in burstStream {
            burstEvents.append(event)
            if case .inboundOverflow = event { break }
        }
        await burstTransport.stop()
        let burstSequences = burstEvents.compactMap { event -> UInt64? in
            if case .line(let sequence, _) = event { return sequence }
            return nil
        }
        let overflowIndexes = burstEvents.indices.filter { index in
            if case .inboundOverflow = burstEvents[index] { return true }
            return false
        }
        try expect(
            burstSequences == [0, 1],
            "the byte budget did not preserve all accepted events in wire order"
        )
        try expect(
            overflowIndexes.count == 1 && overflowIndexes[0] == 2,
            "the byte budget did not append one deterministic overflow event"
        )
    }

    private static func verifySharedDaemonSelectionAndFallback() async throws {
        let codexHome = URL(fileURLWithPath: "/verification/.codex", isDirectory: true)
        let endpoint = CodexSharedDaemonEndpoint(
            executableURL: codexHome
                .appendingPathComponent("packages/standalone/current/codex"),
            socketURL: codexHome
                .appendingPathComponent("app-server-control/app-server-control.sock"),
            version: "0.144.4"
        )
        let standalone = FakeCodexAppServerTransport()
        let shared = FakeCodexAppServerTransport()
        let registrar = VerificationDesktopThreadRegistrar()
        let runtime = CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: URL(fileURLWithPath: "/verification/bundled-codex"),
                codexHomeURL: codexHome,
                requestTimeout: 2,
                maximumInboundLineBytes: 128 * 1_024,
                maximumOutboundMessageBytes: 128 * 1_024,
                maximumStandardErrorBytes: 8 * 1_024,
                maximumInputBytes: 16 * 1_024,
                maximumDeveloperInstructionBytes: 8 * 1_024,
                maximumPendingServerRequests: 8,
                terminationGracePeriod: 0.2
            ),
            transport: standalone,
            executableValidator: AcceptingExecutableValidator(),
            desktopThreadRegistrar: registrar,
            sharedDaemonTransport: shared,
            sharedDaemonProbe: VerificationSharedDaemonProbe(result: .compatible(endpoint))
        )
        try await runtime.start()
        let sharedDurability = try await runtime.supportsDetachedTaskPersistence()
        _ = try await runtime.startTask(taskID: "shared-task", input: "Begin")
        let sharedLaunches = await shared.launchData()
        let standaloneCounts = await standalone.counts()
        try await waitUntil { await registrar.registrations().count == 1 }
        let sharedRegistrations = await registrar.registrations()
        try expect(
            sharedLaunches.count == 1
                && sharedLaunches[0].executableURL == endpoint.executableURL
                && sharedLaunches[0].arguments == [
                    "app-server", "proxy", "--sock", endpoint.socketURL.path,
                ]
                && standaloneCounts.starts == 0
                && sharedDurability,
            "a compatible daemon did not select the managed WebSocket proxy transport"
        )
        try expect(
            sharedRegistrations == ["thread-1"],
            "shared-daemon task was not nudged into the Desktop thread list exactly once"
        )

        // The coordinator may preflight while shared is healthy, then race a
        // reset before thread/start. The runtime boundary itself must reject
        // a subsequent standalone fallback before creating any thread/turn.
        await shared.terminateUnexpectedly(exitCode: 17)
        try await waitUntil { await runtime.accountSnapshot == nil }
        await shared.setFailsToStart(true)
        var atomicDurabilityRejected = false
        do {
            _ = try await runtime.startTask(
                taskID: "shared-reset-persistent-task",
                input: "Build the site",
                options: CodexTaskThreadOptions(
                    workingDirectory: URL(fileURLWithPath: "/verification/Aurora V4"),
                    threadName: "Aurora — Build the site",
                    requiresDetachedPersistence: true
                )
            )
        } catch let error as CodexTaskRuntimeError {
            atomicDurabilityRejected = error == .detachedPersistenceUnavailable
        }
        let postResetStandaloneMessages = try decodeMessages(
            await standalone.messageData()
        )
        try expect(
            atomicDurabilityRejected,
            "a shared-ready preflight raced into standalone persistent execution"
        )
        try expect(
            !postResetStandaloneMessages.contains(where: {
                ($0["method"] as? String) == "thread/start"
                    || ($0["method"] as? String) == "turn/start"
            }),
            "standalone fallback created a persistent thread or turn before failing closed"
        )
        await runtime.shutdown()

        let fallbackStandalone = FakeCodexAppServerTransport()
        let unavailableShared = FakeCodexAppServerTransport(failsToStart: true)
        let fallbackRegistrar = VerificationDesktopThreadRegistrar()
        let fallbackRuntime = CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: URL(fileURLWithPath: "/verification/bundled-codex"),
                codexHomeURL: codexHome,
                requestTimeout: 2
            ),
            transport: fallbackStandalone,
            executableValidator: AcceptingExecutableValidator(),
            desktopThreadRegistrar: fallbackRegistrar,
            sharedDaemonTransport: unavailableShared,
            sharedDaemonProbe: VerificationSharedDaemonProbe(result: .compatible(endpoint))
        )
        try await fallbackRuntime.start()
        let fallbackDurability = try await fallbackRuntime
            .supportsDetachedTaskPersistence()
        _ = try await fallbackRuntime.startTask(taskID: "fallback-task", input: "Begin")
        let failedSharedCounts = await unavailableShared.counts()
        let fallbackLaunches = await fallbackStandalone.launchData()
        try await waitUntil { await fallbackRegistrar.registrations().count == 1 }
        let fallbackRegistrations = await fallbackRegistrar.registrations()
        try expect(
            failedSharedCounts.starts == 1
                && fallbackLaunches.count == 1
                && fallbackLaunches[0].arguments == [
                    "app-server", "--listen", "stdio://", "--strict-config",
                ],
            "a daemon connection race did not fall back to the bounded stdio runtime"
        )
        try expect(
            fallbackRegistrations == ["thread-1"] && !fallbackDurability,
            "standalone fallback claimed detached durability or lost Desktop registration"
        )
        await fallbackRuntime.shutdown()
    }

    private static func verifySharedDaemonVersionAndWebSocketCodec() throws {
        let codexHome = URL(fileURLWithPath: "/verification/.codex", isDirectory: true)
        let validReport = try JSONSerialization.data(withJSONObject: [
            "status": "running",
            "backend": "pid",
            "managedCodexPath": "/verification/.codex/packages/standalone/current/codex",
            "managedCodexVersion": "0.144.4",
            "socketPath": "/verification/.codex/app-server-control/app-server-control.sock",
            "cliVersion": "0.144.2",
            "appServerVersion": "0.144.4",
        ], options: [.sortedKeys])
        let endpoint = CodexSharedDaemonVersionReport.compatibleEndpoint(
            from: validReport,
            codexHomeURL: codexHome
        )
        try expect(
            endpoint?.version == "0.144.4",
            "the probe incorrectly required the bundled proxy CLI to equal the managed daemon"
        )
        let mismatchedReport = try JSONSerialization.data(withJSONObject: [
            "status": "running",
            "managedCodexPath": "/verification/.codex/packages/standalone/current/codex",
            "managedCodexVersion": "0.144.4",
            "socketPath": "/verification/.codex/app-server-control/app-server-control.sock",
            "appServerVersion": "0.144.5",
        ], options: [.sortedKeys])
        try expect(
            CodexSharedDaemonVersionReport.compatibleEndpoint(
                from: mismatchedReport,
                codexHomeURL: codexHome
            ) == nil,
            "the probe accepted a managed CLI/app-server version mismatch"
        )

        let handshake = CodexWebSocketCodec.makeHandshake()
        let requestText = String(decoding: handshake.request, as: UTF8.self)
        try expect(
            requestText.hasPrefix("GET /rpc HTTP/1.1\r\n")
                && requestText.contains("Upgrade: websocket\r\n")
                && !requestText.lowercased().contains("origin:"),
            "the proxy handshake did not use the daemon's documented /rpc WebSocket upgrade"
        )
        let response = Data((
            "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(handshake.expectedAccept)\r\n\r\n"
        ).utf8)
        try CodexWebSocketCodec.validateHandshakeResponse(
            response,
            expectedAccept: handshake.expectedAccept
        )
        do {
            try CodexWebSocketCodec.validateHandshakeResponse(
                response,
                expectedAccept: "incorrect"
            )
            throw VerificationFailure.failed("an invalid WebSocket accept proof was trusted")
        } catch CodexWebSocketCodecError.invalidHandshake {
            // Expected.
        }

        let outgoingPayload = Data("{\"method\":\"initialize\"}".utf8)
        let outgoing = CodexWebSocketCodec.encodeClientText(outgoingPayload)
        let decodedOutgoing = try decodeMaskedClientFrame(outgoing)
        try expect(
            outgoing.first == 0x81
                && outgoing.count > outgoingPayload.count
                && decodedOutgoing == outgoingPayload,
            "outgoing JSON-RPC was not encoded as one masked client text frame"
        )
        let extendedPayload = Data(repeating: 0x78, count: 70_000)
        let extendedOutgoing = CodexWebSocketCodec.encodeClientText(extendedPayload)
        let decodedExtendedOutgoing = try decodeMaskedClientFrame(extendedOutgoing)
        try expect(
            extendedOutgoing[1] & 0x7f == 127
                && decodedExtendedOutgoing == extendedPayload,
            "a 64-bit-length outgoing WebSocket frame was malformed"
        )

        var parser = CodexWebSocketFrameParser(maximumMessageBytes: 128)
        var frames = makeServerFrame(
            opcode: 0x1,
            final: false,
            payload: Data("{\"method\":\"".utf8)
        )
        frames.append(makeServerFrame(opcode: 0x9, final: true, payload: Data("p".utf8)))
        frames.append(makeServerFrame(
            opcode: 0x0,
            final: true,
            payload: Data("ready\"}".utf8)
        ))
        let split = min(5, frames.count)
        let firstEvents = try parser.append(Data(frames.prefix(split)))
        let secondEvents = try parser.append(Data(frames.dropFirst(split)))
        try expect(
            firstEvents.isEmpty
                && secondEvents == [
                    .ping(Data("p".utf8)),
                    .text(Data("{\"method\":\"ready\"}".utf8)),
                ],
            "fragmented text and interleaved ping frames were not decoded in wire order"
        )
        let closeEvents = try parser.append(makeServerFrame(
            opcode: 0x8,
            final: true,
            payload: Data([0x03, 0xE8])
        ))
        try expect(
            closeEvents == [.close(Data([0x03, 0xE8]))],
            "the WebSocket close control frame was not surfaced"
        )
        var extendedParser = CodexWebSocketFrameParser(maximumMessageBytes: 80_000)
        let extendedEvents = try extendedParser.append(makeServerFrame(
            opcode: 0x1,
            final: true,
            payload: extendedPayload
        ))
        try expect(
            extendedEvents == [.text(extendedPayload)],
            "a 64-bit-length incoming WebSocket frame was malformed"
        )

        var boundedParser = CodexWebSocketFrameParser(maximumMessageBytes: 4)
        do {
            _ = try boundedParser.append(makeServerFrame(
                opcode: 0x1,
                final: true,
                payload: Data("12345".utf8)
            ))
            throw VerificationFailure.failed("an oversized WebSocket message was accepted")
        } catch CodexWebSocketCodecError.messageTooLarge {
            // Expected.
        }
        var maskedServerFrame = makeServerFrame(
            opcode: 0x1,
            final: true,
            payload: Data("{}".utf8)
        )
        maskedServerFrame[1] |= 0x80
        var strictParser = CodexWebSocketFrameParser(maximumMessageBytes: 128)
        do {
            _ = try strictParser.append(maskedServerFrame)
            throw VerificationFailure.failed("a masked server frame was accepted")
        } catch CodexWebSocketCodecError.invalidFrame {
            // Expected.
        }
    }

    private static func makeServerFrame(
        opcode: UInt8,
        final: Bool,
        payload: Data
    ) -> Data {
        var data = Data([(final ? 0x80 : 0x00) | opcode])
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            data.append(126)
            data.append(UInt8((payload.count >> 8) & 0xff))
            data.append(UInt8(payload.count & 0xff))
        } else {
            data.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        data.append(payload)
        return data
    }

    private static func decodeMaskedClientFrame(_ frame: Data) throws -> Data {
        guard frame.count >= 6, frame[1] & 0x80 != 0 else {
            throw VerificationFailure.failed("client frame was not a bounded masked frame")
        }
        var headerBytes = 2
        var count = Int(frame[1] & 0x7f)
        if count == 126 {
            guard frame.count >= 8 else {
                throw VerificationFailure.failed("client 16-bit frame header was truncated")
            }
            count = Int(frame[2]) << 8 | Int(frame[3])
            headerBytes = 4
        } else if count == 127 {
            guard frame.count >= 14, frame[2] & 0x80 == 0 else {
                throw VerificationFailure.failed("client 64-bit frame header was truncated")
            }
            var length: UInt64 = 0
            for offset in 2..<10 {
                length = length << 8 | UInt64(frame[offset])
            }
            guard length <= UInt64(Int.max) else {
                throw VerificationFailure.failed("client frame length overflowed")
            }
            count = Int(length)
            headerBytes = 10
        }
        let payloadStart = headerBytes + 4
        guard frame.count == payloadStart + count else {
            throw VerificationFailure.failed("client frame length was malformed")
        }
        let mask = Array(frame[headerBytes..<payloadStart])
        return Data(frame[payloadStart...].enumerated().map { index, byte in
            byte ^ mask[index % 4]
        })
    }

    private static func verifyLiveAccountHandshakeOnly() async throws -> Bool {
        let events = EventCollector()
        let runtime = CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: OpenAICodexExecutableValidator.expectedExecutableURL,
                codexHomeURL: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true),
                requestTimeout: 10
            ),
            transport: FoundationCodexAppServerTransport(),
            executableValidator: AcceptingExecutableValidator()
        )
        await runtime.setEventHandler { event in
            Task { await events.append(event) }
        }
        try await runtime.start()
        let firstAccount = await runtime.accountSnapshot
        let liveThreads = try await runtime.listThreads(query: AuroraCodexThreadQuery(
            limit: 1
        ))
        if let firstThread = liveThreads.threads.first {
            let liveDocument = try await runtime.readThread(
                threadID: firstThread.threadID,
                includeTurns: false
            )
            try expect(
                liveDocument.summary.threadID == firstThread.threadID,
                "live typed thread/read changed the listed Codex identity"
            )
        }
        try await runtime.restart()
        let restartedAccount = await runtime.accountSnapshot
        await runtime.shutdown()
        try expect(firstAccount?.authenticationType == "chatgpt"
                   && restartedAccount?.authenticationType == "chatgpt",
                   "live app-server account/read was not ChatGPT-backed")
        let readyEvents = await events.events().filter { $0.method == "$runtime/ready" }
        let transports = readyEvents.compactMap { event -> String? in
            guard let object = try? JSONSerialization.jsonObject(
                with: event.paramsJSON
            ) as? [String: Any] else { return nil }
            return object["transport"] as? String
        }
        try expect(
            transports.count == 2,
            "live startup/restart did not report both selected transports"
        )
        return transports.allSatisfy { $0 == "shared_daemon" }
    }

    private static func effectReportTool() -> CodexTaskDynamicToolSpec {
        CodexTaskDynamicToolSpec(
            name: "report_effect_result",
            description: "Report the exact externally observed postcondition for this turn.",
            inputSchema: CodexTaskDynamicToolInputSchema(
                properties: [
                    "outcome": CodexTaskDynamicToolStringProperty(
                        description: "Whether the requested effect was observed.",
                        allowedValues: [
                            "verified",
                            "not_verified",
                            "no_external_effect",
                        ]
                    ),
                    "observed_postcondition": CodexTaskDynamicToolStringProperty(
                        description: "A short, concrete postcondition observation.",
                        minimumLength: 1,
                        maximumLength: 2_000
                    ),
                ],
                required: ["outcome", "observed_postcondition"]
            )
        )
    }

    private static func makeRuntime(
        transport: FakeCodexAppServerTransport,
        desktopThreadRegistrar: any CodexDesktopThreadRegistering = VerificationDesktopThreadRegistrar()
    ) -> CodexTaskRuntime {
        CodexTaskRuntime(
            configuration: CodexTaskRuntimeConfiguration(
                executableURL: URL(fileURLWithPath: "/verification/codex"),
                codexHomeURL: URL(fileURLWithPath: "/verification/.codex", isDirectory: true),
                requestTimeout: 2,
                maximumInboundLineBytes: 128 * 1_024,
                maximumOutboundMessageBytes: 128 * 1_024,
                maximumStandardErrorBytes: 8 * 1_024,
                maximumInputBytes: 16 * 1_024,
                maximumDeveloperInstructionBytes: 8 * 1_024,
                maximumPendingServerRequests: 8,
                terminationGracePeriod: 0.2
            ),
            transport: transport,
            executableValidator: AcceptingExecutableValidator(),
            desktopThreadRegistrar: desktopThreadRegistrar,
            sharedDaemonProbe: VerificationSharedDaemonProbe(result: .unavailable)
        )
    }

    private static func desktopThreadFixture(
        threadID: String,
        cwd: String,
        status: String = "notLoaded",
        ephemeral: Bool = false,
        turns: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": threadID,
            "sessionId": "session-fixture",
            "name": "Selected owner task",
            "preview": "Selected owner task",
            "cwd": cwd,
            "status": ["type": status],
            "source": "vscode",
            "threadSource": "user",
            "modelProvider": "openai",
            "cliVersion": "0.145.0",
            "createdAt": 1_700_000_000,
            "updatedAt": 1_700_000_001,
            "ephemeral": ephemeral,
            "turns": turns,
        ]
    }

    private static func threadListFixture(
        _ threads: [[String: Any]],
        nextCursor: String? = nil
    ) -> [String: Any] {
        [
            "data": threads,
            "nextCursor": nextCursor ?? NSNull(),
        ]
    }

    private static func threadTurnsListFixture(
        _ turns: [[String: Any]],
        nextCursor: String? = nil
    ) -> [String: Any] {
        [
            "data": turns,
            "nextCursor": nextCursor ?? NSNull(),
            "backwardsCursor": NSNull(),
        ]
    }

    private static func decodeMessages(_ messages: [Data]) throws -> [[String: Any]] {
        try messages.map { message in
            var line = message
            if line.last == 0x0a { line.removeLast() }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw VerificationFailure.failed("runtime wrote malformed JSONL")
            }
            return object
        }
    }

    private static func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VerificationFailure.failed("timed out waiting for verifier state")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationFailure.failed(message) }
    }
}
