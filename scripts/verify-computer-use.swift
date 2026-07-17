import Foundation

#if COMPUTER_USE_FOCUSED
enum VerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}
#endif

actor VerificationComputerUseTransport: ComputerUseTransport {
    private var responses: [ComputerUseHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [ComputerUseHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> ComputerUseHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ComputerUseClientError.transportFailed
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

actor VerificationFlakyComputerUseTransport: ComputerUseTransport {
    private var failuresRemaining: Int
    private let eventualResponse: ComputerUseHTTPResponse
    private var requests: [URLRequest] = []

    init(failuresRemaining: Int, eventualResponse: ComputerUseHTTPResponse) {
        self.failuresRemaining = failuresRemaining
        self.eventualResponse = eventualResponse
    }

    func send(_ request: URLRequest) async throws -> ComputerUseHTTPResponse {
        requests.append(request)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ComputerUseClientError.transportFailed
        }
        return eventualResponse
    }

    func recordedRequests() -> [URLRequest] { requests }
}

actor VerificationMacDesktopPerformer: MacDesktopActionPerforming {
    private var actions: [MacDesktopExecutableAction] = []

    func perform(_ action: MacDesktopExecutableAction) async throws {
        actions.append(action)
    }

    func recordedActions() -> [MacDesktopExecutableAction] { actions }
}

actor VerificationBlockingComputerUseTransport: ComputerUseTransport {
    private var requests: [URLRequest] = []
    private var finishedRequests = 0

    func send(_ request: URLRequest) async throws -> ComputerUseHTTPResponse {
        requests.append(request)
        defer { finishedRequests += 1 }
        try await Task.sleep(for: .seconds(30))
        return ComputerUseHTTPResponse(
            data: try JSONSerialization.data(withJSONObject: [
                "id": "resp_blocking",
                "status": "completed",
                "output": [],
            ]),
            statusCode: 200
        )
    }

    func requestCount() -> Int { requests.count }
    func finishedRequestCount() -> Int { finishedRequests }
}

actor VerificationDesktopTaskEvents {
    private var events: [DesktopTaskEvent] = []

    func append(_ event: DesktopTaskEvent) { events.append(event) }
    func snapshot() -> [DesktopTaskEvent] { events }
}

enum ComputerUseVerification {
    private static let fixturePNG = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x41, 0x75, 0x72, 0x6f, 0x72, 0x61,
    ])

    static func run() async throws -> Int {
        try await responsePayloadAndContinuation()
        try await transientRequestsRetryWithinShortDeadline()
        try await responseAndInputLimitsFailClosed()
        try failedProviderStepCannotMasqueradeAsCompletion()
        try await desktopActionAdapterIsBounded()
        try screenshotDataRemainsEphemeral()
        try await coordinatorStateAndBounds()
        try await realtimeUpdatesCannotRepurposeStaleTasks()
        try realtimeSchemaAndEvidencePolicy()
        return 41
    }

    private static func failedProviderStepCannotMasqueradeAsCompletion() throws {
        let failed = DesktopTaskStep(
            responseID: "resp_failed",
            responseStatus: "failed",
            computerCalls: [],
            outputText: "Something went wrong."
        )
        let incomplete = DesktopTaskStep(
            responseID: "resp_incomplete",
            responseStatus: "incomplete",
            computerCalls: [],
            outputText: nil
        )
        try expect(!failed.isComplete && !incomplete.isComplete,
                   "failed or incomplete provider response became a completed Mac task")
    }

    private static func responsePayloadAndContinuation() async throws {
        let firstResponse = try jsonData([
            "id": "resp_computer_1",
            "status": "completed",
            "output": [[
                "type": "computer_call",
                "call_id": "call_desktop_1",
                "status": "completed",
                "actions": [
                    ["type": "screenshot"],
                    ["type": "click", "x": 120, "y": 220, "button": "left"],
                    ["type": "double_click", "x": 130, "y": 230, "button": "right"],
                    [
                        "type": "drag",
                        "path": [["x": 10, "y": 20], ["x": 30, "y": 40]],
                    ],
                    ["type": "move", "x": 140, "y": 240],
                    [
                        "type": "scroll",
                        "x": 150,
                        "y": 250,
                        "scroll_x": -12,
                        "scroll_y": 640,
                    ],
                    ["type": "keypress", "keys": ["CMD", "L"]],
                    ["type": "type", "text": "Aurora"],
                    ["type": "wait"],
                    ["type": "future_action"],
                ],
            ]],
        ])
        let finalResponse = try jsonData([
            "id": "resp_computer_2",
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "The desktop task is complete."]],
            ]],
        ])
        let transport = VerificationComputerUseTransport(responses: [
            ComputerUseHTTPResponse(data: firstResponse, statusCode: 200),
            ComputerUseHTTPResponse(data: finalResponse, statusCode: 200),
        ])
        let client = ComputerUseClient(apiKey: "verification-key", transport: transport)

        let first = try await client.start(task: "Open the requested app and inspect it.")
        try expect(first.responseID == "resp_computer_1"
                   && first.responseStatus == "completed"
                   && first.computerCalls.count == 1
                   && !first.isComplete,
                   "computer response did not preserve its response/call continuation IDs")
        let call = first.computerCalls[0]
        try expect(call.callID == "call_desktop_1"
                   && call.status == "completed"
                   && call.actions.count == 10,
                   "GA computer_call.actions[] was not decoded as one ordered batch")
        try expect(call.actions[0] == .screenshot,
                   "screenshot-first computer turns are not supported")
        try expect(call.actions[1] == .click(x: 120, y: 220, button: .left)
                   && call.actions[2] == .doubleClick(x: 130, y: 230, button: .right),
                   "click or double-click action decoding drifted")
        try expect(call.actions[3] == .drag(path: [
            DesktopPoint(x: 10, y: 20),
            DesktopPoint(x: 30, y: 40),
        ]), "drag path decoding drifted")
        try expect(call.actions[4] == .move(x: 140, y: 240)
                   && call.actions[5] == .scroll(
                       x: 150,
                       y: 250,
                       deltaX: -12,
                       deltaY: 640
                   ), "move or scroll action decoding drifted")
        try expect(call.actions[6] == .keypress(keys: ["CMD", "L"])
                   && call.actions[7] == .type(text: "Aurora")
                   && call.actions[8] == .wait
                   && call.actions[9] == .unsupported(type: "future_action"),
                   "keyboard, wait, or forward-compatible action decoding drifted")

        let final = try await client.submitScreenshot(
            previousResponseID: first.responseID,
            callID: call.callID,
            pngData: fixturePNG
        )
        try expect(final.responseID == "resp_computer_2"
                   && final.computerCalls.isEmpty
                   && final.isComplete
                   && final.outputText == "The desktop task is complete.",
                   "a computer_call_output continuation did not terminate with final text")

        let requests = await transport.recordedRequests()
        try expect(requests.count == 2, "computer client did not make exactly one request per API step")
        let initial = try requestJSON(requests[0])
        try expect(requests[0].httpMethod == "POST"
                   && requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer verification-key"
                   && initial["model"] as? String == "gpt-5.6"
                   && initial["input"] as? String == "Open the requested app and inspect it.",
                   "initial Responses request lost its model, task, or bearer credential")
        guard let initialTools = initial["tools"] as? [[String: Any]] else {
            throw VerificationFailure.failed("initial computer request omitted tools")
        }
        try expect(initialTools.count == 1 && initialTools[0]["type"] as? String == "computer",
                   "new computer integration is not using the GA Responses computer tool")

        let continuation = try requestJSON(requests[1])
        guard let continuationInput = continuation["input"] as? [[String: Any]],
              let output = continuationInput.first?["output"] as? [String: Any] else {
            throw VerificationFailure.failed("screenshot continuation shape was malformed")
        }
        try expect(continuation["previous_response_id"] as? String == "resp_computer_1"
                   && continuationInput.count == 1
                   && continuationInput[0]["type"] as? String == "computer_call_output"
                   && continuationInput[0]["call_id"] as? String == "call_desktop_1"
                   && output["type"] as? String == "computer_screenshot"
                   && output["detail"] as? String == "original",
                   "continuation lost the previous response, call ID, or screenshot output type")
        let expectedDataURL = "data:image/png;base64,\(fixturePNG.base64EncodedString())"
        try expect(output["image_url"] as? String == expectedDataURL
                   && !(output["image_url"] as? String ?? "").hasPrefix("file:"),
                   "screenshot was not sent directly from memory as a PNG data URL")
    }

    private static func transientRequestsRetryWithinShortDeadline() async throws {
        let completion = ComputerUseHTTPResponse(
            data: try jsonData([
                "id": "resp_retry_complete",
                "status": "completed",
                "output": [],
            ]),
            statusCode: 200
        )
        let flakyTransport = VerificationFlakyComputerUseTransport(
            failuresRemaining: 1,
            eventualResponse: completion
        )
        let flakyClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: flakyTransport
        )
        let recovered = try await flakyClient.start(task: "Recover from one transport failure.")
        try expect(recovered.responseID == "resp_retry_complete" && recovered.isComplete,
                   "computer client did not recover from one transient transport failure")

        let retriedRequests = await flakyTransport.recordedRequests()
        let retryKeys = retriedRequests.compactMap {
            $0.value(forHTTPHeaderField: "Idempotency-Key")
        }
        try expect(retriedRequests.count == 2
                   && retriedRequests.allSatisfy { $0.timeoutInterval == 30 },
                   "computer retries lost the bounded 30-second per-request deadline")
        try expect(retryKeys.count == 2
                   && retryKeys[0] == retryKeys[1]
                   && !retryKeys[0].isEmpty,
                   "computer retry did not preserve one logical idempotency key")

        let serviceUnavailable = ComputerUseHTTPResponse(
            data: try jsonData([
                "error": [
                    "message": "temporary outage",
                    "type": "server_error",
                    "code": "service_unavailable",
                ],
            ]),
            statusCode: 503
        )
        let httpTransport = VerificationComputerUseTransport(responses: [
            serviceUnavailable,
            completion,
        ])
        let httpClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: httpTransport
        )
        _ = try await httpClient.start(task: "Recover from one transient HTTP failure.")
        let httpRequests = await httpTransport.recordedRequests()
        try expect(httpRequests.count == 2,
                   "computer client did not retry a transient provider 503")

        let exhaustedTransport = VerificationFlakyComputerUseTransport(
            failuresRemaining: 10,
            eventualResponse: completion
        )
        let exhaustedClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: exhaustedTransport
        )
        do {
            _ = try await exhaustedClient.start(task: "Stop after the retry budget.")
            throw VerificationFailure.failed("exhausted computer transport unexpectedly succeeded")
        } catch ComputerUseClientError.transportFailed {
            // Expected after the original request and exactly one retry.
        }
        let exhaustedRequests = await exhaustedTransport.recordedRequests()
        try expect(exhaustedRequests.count == 2,
                   "computer transport retry was not bounded to two attempts")

        let invalidRequest = ComputerUseHTTPResponse(
            data: try jsonData([
                "error": [
                    "message": "invalid request",
                    "type": "invalid_request_error",
                    "code": "invalid_request",
                ],
            ]),
            statusCode: 400
        )
        let invalidTransport = VerificationComputerUseTransport(responses: [invalidRequest])
        let invalidClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: invalidTransport
        )
        do {
            _ = try await invalidClient.start(task: "Do not retry a permanent rejection.")
            throw VerificationFailure.failed("permanent computer API rejection unexpectedly succeeded")
        } catch ComputerUseClientError.api(let statusCode, _, _, _) {
            try expect(statusCode == 400,
                       "permanent computer API rejection lost its original status")
        }
        let invalidRequests = await invalidTransport.recordedRequests()
        try expect(invalidRequests.count == 1,
                   "computer client retried a permanent provider rejection")
    }

    private static func responseAndInputLimitsFailClosed() async throws {
        let limits = ComputerUseLimits(
            maximumResponseBytes: 2_000,
            maximumScreenshotBytes: fixturePNG.count,
            maximumTaskCharacters: 12,
            maximumOutputItems: 2,
            maximumComputerCalls: 1,
            maximumActionsPerCall: 2,
            maximumActionTextCharacters: 8,
            maximumOutputTextCharacters: 12
        )
        let transport = VerificationComputerUseTransport(responses: [
            ComputerUseHTTPResponse(
                data: try jsonData(["id": "unused", "output": []]),
                statusCode: 200
            ),
        ])
        let client = ComputerUseClient(
            apiKey: "verification-key",
            transport: transport,
            limits: limits
        )
        do {
            _ = try await client.start(task: "This task is too long")
            throw VerificationFailure.failed("overlong computer task reached the transport")
        } catch ComputerUseClientError.invalidTask {
            // Expected.
        }
        do {
            _ = try await client.submitScreenshot(
                previousResponseID: "resp_1",
                callID: "call_1",
                pngData: fixturePNG + Data([0])
            )
            throw VerificationFailure.failed("oversized screenshot reached the transport")
        } catch ComputerUseClientError.screenshotTooLarge {
            // Expected.
        }
        let rejectedRequests = await transport.recordedRequests()
        try expect(rejectedRequests.isEmpty,
                   "rejected computer input still produced a network request")

        let excessiveActions = try jsonData([
            "id": "resp_too_many_actions",
            "output": [[
                "type": "computer_call",
                "call_id": "call_1",
                "actions": [
                    ["type": "wait"],
                    ["type": "wait"],
                    ["type": "wait"],
                ],
            ]],
        ])
        let boundedTransport = VerificationComputerUseTransport(responses: [
            ComputerUseHTTPResponse(data: excessiveActions, statusCode: 200),
        ])
        let boundedClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: boundedTransport,
            limits: limits
        )
        do {
            _ = try await boundedClient.start(task: "short task")
            throw VerificationFailure.failed("oversized computer action batch was decoded")
        } catch ComputerUseClientError.responseLimitExceeded {
            // Expected.
        }

        let oversizedTransport = VerificationComputerUseTransport(responses: [
            ComputerUseHTTPResponse(data: Data(repeating: 65, count: 2_001), statusCode: 200),
        ])
        let oversizedClient = ComputerUseClient(
            apiKey: "verification-key",
            transport: oversizedTransport,
            limits: limits
        )
        do {
            _ = try await oversizedClient.start(task: "short task")
            throw VerificationFailure.failed("oversized provider response was decoded")
        } catch ComputerUseClientError.responseTooLarge {
            // Expected.
        }
    }

    private static func desktopActionAdapterIsBounded() async throws {
        let denied = MacDesktopPermissionProvider {
            MacDesktopPermissionStatus(
                screenRecordingAllowed: false,
                accessibilityAllowed: false,
                eventPostingAllowed: false
            )
        }
        let deniedPerformer = VerificationMacDesktopPerformer()
        let deniedEnvironment = try MacDesktopEnvironment(
            taskID: "desktop-verification",
            permissionProvider: denied,
            actionPerformer: deniedPerformer
        )
        do {
            _ = try await deniedEnvironment.execute(.click(x: 10, y: 10, button: .left))
            throw VerificationFailure.failed("pointer action ran without a task screenshot")
        } catch MacDesktopEnvironmentError.screenshotRequired {
            // A coordinate-space snapshot is required before all pointer actions.
        }
        do {
            _ = try await deniedEnvironment.execute(.keypress(keys: ["CMD", "L"]))
            throw VerificationFailure.failed("keypress ran without Accessibility permission")
        } catch MacDesktopEnvironmentError.accessibilityPermissionDenied {
            // Expected.
        }
        do {
            _ = try await deniedEnvironment.execute(.unsupported(type: "future_action"))
            throw VerificationFailure.failed("unknown provider action reached native execution")
        } catch MacDesktopEnvironmentError.unsupportedAction {
            // Expected.
        }
        let rejectedActions = await deniedPerformer.recordedActions()
        try expect(rejectedActions.isEmpty,
                   "rejected desktop actions reached the native performer")

        let allowed = MacDesktopPermissionProvider {
            MacDesktopPermissionStatus(
                screenRecordingAllowed: true,
                accessibilityAllowed: true,
                eventPostingAllowed: true
            )
        }
        let performer = VerificationMacDesktopPerformer()
        let environment = try MacDesktopEnvironment(
            taskID: "desktop-verification",
            configuration: .init(waitDuration: 0.05),
            permissionProvider: allowed,
            actionPerformer: performer
        )
        let typeReceipt = try await environment.execute(.type(text: "Aurora"))
        let waitReceipt = try await environment.execute(.wait)
        let fnReceipt = try await environment.execute(.keypress(keys: ["FN"]))
        let fnF11Receipt = try await environment.execute(.keypress(keys: ["FN", "F11"]))
        let chordReceipt = try await environment.execute(.keypress(keys: ["CMD+L"]))
        try expect(typeReceipt.taskID == "desktop-verification"
                   && typeReceipt.actionType == .type
                   && waitReceipt.actionType == .wait
                   && fnReceipt.actionType == .keypress
                   && fnF11Receipt.actionType == .keypress
                   && chordReceipt.actionType == .keypress,
                   "desktop environment receipts lost their task or action identity")
        let performedActions = await performer.recordedActions()
        try expect(performedActions == [
            .type(text: "Aurora"),
            .wait(seconds: 0.05),
            .keypress(keys: ["FN"]),
            .keypress(keys: ["FN", "F11"]),
            .keypress(keys: ["CMD+L"]),
        ], "provider-facing keyboard/wait actions were not translated exactly once")
        do {
            _ = try await environment.execute(.keypress(keys: ["MAGIC_KEY"]))
            throw VerificationFailure.failed("an unsupported desktop key reached native execution")
        } catch MacDesktopEnvironmentError.unsupportedKey {
            // Expected.
        }
    }

    private static func screenshotDataRemainsEphemeral() throws {
        let sourceURLs = [
            "Sources/Aurora/ComputerUse/ComputerUseClient.swift",
            "Sources/Aurora/ComputerUse/MacDesktopEnvironment.swift",
            "Sources/Aurora/ComputerUse/DesktopTaskCoordinator.swift",
        ].map { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent($0) }
        for url in sourceURLs where FileManager.default.fileExists(atPath: url.path) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let suspicious = source.split(separator: "\n").contains { line in
                let lower = line.lowercased()
                let isImageLine = lower.contains("screenshot") || lower.contains("png")
                let isFileWrite = lower.contains(".write(to:")
                    || lower.contains("createfile(")
                    || lower.contains("filehandle(forwriting")
                return isImageLine && isFileWrite
            }
            try expect(!suspicious,
                       "computer-use screenshot bytes gained a disk-persistence path in \(url.lastPathComponent)")
        }
        try expect(Mirror(reflecting: DesktopTaskStep(
            responseID: "resp_1",
            computerCalls: [],
            outputText: "done"
        )).children.allSatisfy { child in
            let label = child.label?.lowercased() ?? ""
            return !label.contains("screenshot") && !label.contains("png") && !label.contains("image")
        }, "task step began retaining screenshot/image payloads")
    }

    private static func coordinatorStateAndBounds() async throws {
        try expect(DesktopTaskCoordinator.maximumGoalCharacters == 1_200
                   && DesktopTaskCoordinator.maximumSuccessCriteriaCharacters == 600
                   && DesktopTaskCoordinator.maximumUpdateCharacters == 800
                   && DesktopTaskCoordinator.maximumSteps == 40
                   && DesktopTaskCoordinator.maximumTaskDurationSeconds == 600,
                   "desktop coordinator goals, updates, steps, or lifetime are not bounded")

        let statuses: [DesktopTaskStatus] = [
            .queued, .running, .paused, .completed, .cancelled, .failed,
        ]
        try expect(statuses.map(\.rawValue) == [
            "queued", "running", "paused", "completed", "cancelled", "failed",
        ], "desktop task status raw values drifted")

        let now = Date(timeIntervalSince1970: 1_783_777_200)
        let low = DesktopTaskSnapshot(
            taskID: "task_low",
            goal: String(repeating: "g", count: 1_500),
            successCriteria: String(repeating: "c", count: 700),
            status: .queued,
            stepCount: -10,
            startedAt: now,
            updatedAt: now,
            summary: String(repeating: "s", count: 900),
            failureCode: String(repeating: "f", count: 300)
        )
        let high = DesktopTaskSnapshot(
            taskID: "task_high",
            goal: "finish",
            successCriteria: nil,
            status: .completed,
            stepCount: 10_000,
            startedAt: now,
            updatedAt: now,
            summary: "done"
        )
        try expect(low.goal.count == DesktopTaskCoordinator.maximumGoalCharacters
                   && low.successCriteria?.count == DesktopTaskCoordinator.maximumSuccessCriteriaCharacters
                   && low.summary?.count == 600
                   && low.failureCode?.count == 160
                   && low.stepCount == 0
                   && high.stepCount == DesktopTaskCoordinator.maximumSteps,
                   "desktop task snapshots do not clamp untrusted text and step counts")
        try expect(high.status == .completed && high.summary == "done",
                   "completed desktop task snapshot lost its terminal state")
        try expect(DesktopTaskCoordinator.settlementDelayMilliseconds(
            for: .click(x: 10, y: 10, button: .right)
        ) > DesktopTaskCoordinator.settlementDelayMilliseconds(
            for: .click(x: 10, y: 10, button: .left)
        ) && DesktopTaskCoordinator.settlementDelayMilliseconds(
            for: .screenshot
        ) == 0, "dependent desktop actions do not allow native interfaces to settle")

        let transport = VerificationBlockingComputerUseTransport()
        let events = VerificationDesktopTaskEvents()
        let deniedPermissions = MacDesktopPermissionProvider {
            MacDesktopPermissionStatus(
                screenRecordingAllowed: false,
                accessibilityAllowed: false,
                eventPostingAllowed: false
            )
        }
        let coordinator = DesktopTaskCoordinator(
            clientFactory: { key in
                ComputerUseClient(apiKey: key, transport: transport)
            },
            environmentFactory: { taskID in
                try MacDesktopEnvironment(
                    taskID: taskID,
                    permissionProvider: deniedPermissions,
                    actionPerformer: VerificationMacDesktopPerformer()
                )
            }
        )
        await coordinator.setEventHandler { event in
            await events.append(event)
        }
        do {
            _ = try await coordinator.start(goal: "unconfigured")
            throw VerificationFailure.failed("desktop task started without an API key")
        } catch DesktopTaskCoordinatorError.missingAPIKey {
            // Expected.
        }
        await coordinator.configure(apiKey: "verification-key")
        do {
            _ = try await coordinator.start(
                goal: String(repeating: "g", count: DesktopTaskCoordinator.maximumGoalCharacters + 1)
            )
            throw VerificationFailure.failed("overlong desktop goal was accepted")
        } catch DesktopTaskCoordinatorError.invalidGoal {
            // Expected.
        }

        let started = try await coordinator.start(
            goal: "Open the requested page.",
            successCriteria: "The page is visibly open.",
            sessionID: "voice-session"
        )
        try expect(started.status == .queued
                   && started.stepCount == 0
                   && started.goal == "Open the requested page.",
                   "desktop task did not begin in a bounded queued state")
        try await eventually("desktop coordinator did not start its provider request") {
            await transport.requestCount() == 1
        }
        let runningStatus = await coordinator.status(taskID: started.taskID)
        try expect(runningStatus?.status == .running,
                   "active desktop task did not become running")

        await coordinator.pauseForOwnerSpeech()
        let pausedStatus = await coordinator.status(taskID: started.taskID)
        try expect(pausedStatus?.status == .paused,
                   "owner speech did not pause the desktop task")
        await coordinator.resumeAfterOwnerTurn()
        let resumedStatus = await coordinator.status(taskID: started.taskID)
        try expect(resumedStatus?.status == .running,
                   "desktop task did not resume after the owner turn")

        let updated = try await coordinator.update(
            taskID: started.taskID,
            instruction: "Use the other window."
        )
        try expect(updated.taskID == started.taskID
                   && updated.status == .queued
                   && updated.stepCount == 0,
                   "desktop update replaced the task identity or skipped re-observation")
        try await eventually("desktop update did not replace the in-flight provider request") {
            await transport.requestCount() >= 2
        }
        let replacement = try await coordinator.start(
            goal: "Open the newer requested page.",
            successCriteria: "The newer page is visibly open.",
            sessionID: "voice-session"
        )
        let supersededStatus = await coordinator.status(taskID: started.taskID)
        try expect(replacement.taskID != started.taskID
                   && replacement.status == .queued
                   && supersededStatus?.status == .cancelled
                   && supersededStatus?.summary == "Superseded by a newer owner request.",
                   "a newer owner desktop request did not supersede the stale task")
        let cancelled = try await coordinator.cancel(taskID: replacement.taskID)
        let cancelledStatus = await coordinator.status(taskID: replacement.taskID)
        try expect(cancelled.status == .cancelled
                   && cancelled.summary == "Cancelled."
                   && cancelledStatus == cancelled,
                   "desktop cancellation was not durable through status")
        let repeatedCancel = try await coordinator.cancel(taskID: replacement.taskID)
        try expect(repeatedCancel == cancelled,
                   "repeated desktop cancellation was not idempotent")
        do {
            _ = try await coordinator.update(
                taskID: replacement.taskID,
                instruction: "continue"
            )
            throw VerificationFailure.failed("terminal desktop task accepted an update")
        } catch DesktopTaskCoordinatorError.taskNotActive {
            // Expected.
        }
        let missingStatus = await coordinator.status(taskID: "missing-task")
        try expect(missingStatus == nil,
                   "unknown desktop task returned another task's state")
        try await eventually("desktop lifecycle callbacks did not drain") {
            await events.snapshot().count >= 5
        }
        let recordedEvents = await events.snapshot()
        try expect(recordedEvents.contains { $0.kind == .started && $0.snapshot.taskID == started.taskID }
                   && recordedEvents.contains { $0.kind == .updated && $0.snapshot.taskID == started.taskID }
                   && recordedEvents.contains { $0.kind == .cancelled && $0.snapshot.taskID == started.taskID }
                   && recordedEvents.contains { $0.kind == .started && $0.snapshot.taskID == replacement.taskID }
                   && recordedEvents.contains { $0.kind == .cancelled && $0.snapshot.taskID == replacement.taskID },
                   "desktop lifecycle updates were not emitted with bounded snapshots")

        let requestsBeforeSessionEnd = await transport.requestCount()
        let sessionBoundTask = try await coordinator.start(
            goal: "Click the requested video.",
            sessionID: "ending-voice-session"
        )
        try await eventually("session-bound desktop task did not start") {
            await transport.requestCount() > requestsBeforeSessionEnd
        }
        let wrongSessionCancellation = await coordinator.cancelActive(
            matchingSessionID: "newer-voice-session",
            reason: "Voice session ended."
        )
        let stillActive = await coordinator.status(taskID: sessionBoundTask.taskID)
        try expect(wrongSessionCancellation == nil
                   && stillActive?.status == .running,
                   "a delayed old-session cleanup could cancel newer desktop work")
        let sessionEndCancellation = await coordinator.cancelActive(
            matchingSessionID: "ending-voice-session",
            reason: "Voice session ended."
        )
        let afterSessionEnd = await coordinator.status(taskID: sessionBoundTask.taskID)
        try expect(sessionEndCancellation?.status == .cancelled
                   && sessionEndCancellation?.summary == "Voice session ended."
                   && afterSessionEnd == sessionEndCancellation,
                   "ending a voice session did not durably cancel its desktop task")
        try await Task.sleep(for: .milliseconds(30))
        let eventsAfterSessionEnd = await events.snapshot()
        try expect(eventsAfterSessionEnd.contains {
            $0.kind == .cancelled && $0.snapshot.taskID == sessionBoundTask.taskID
        } && !eventsAfterSessionEnd.contains {
            $0.kind == .completed && $0.snapshot.taskID == sessionBoundTask.taskID
        }, "cancelled session work later emitted a false completion")
        await coordinator.shutdown()

        let barrierTransport = VerificationBlockingComputerUseTransport()
        let barrierCoordinator = DesktopTaskCoordinator(
            clientFactory: { key in
                ComputerUseClient(apiKey: key, transport: barrierTransport)
            },
            environmentFactory: { taskID in
                try MacDesktopEnvironment(
                    taskID: taskID,
                    permissionProvider: deniedPermissions,
                    actionPerformer: VerificationMacDesktopPerformer()
                )
            }
        )
        await barrierCoordinator.configure(apiKey: "verification-key")
        let barrierTask = try await barrierCoordinator.start(
            goal: "Open a video before a direct media command."
        )
        try await eventually("cancellation barrier task did not enter its provider request") {
            await barrierTransport.requestCount() == 1
        }
        let barrierCancellation = try await barrierCoordinator.cancel(taskID: barrierTask.taskID)
        let finishedBarrierRequests = await barrierTransport.finishedRequestCount()
        try expect(barrierCancellation.taskID == barrierTask.taskID
                   && barrierCancellation.status == .cancelled
                   && finishedBarrierRequests == 1,
                   "exact-task cancellation returned before that visual runner unwound")

        // Reproduce the speech-start race: an obsolete function-call task is
        // cancelled while trying to enter `start`. It must never create a new
        // motor record after the cancellation barrier has observed the old
        // runner.
        let requestsBeforeCancelledStart = await barrierTransport.requestCount()
        let cancelledStart = Task {
            try await barrierCoordinator.start(
                goal: "This superseded voice turn must never touch the Mac."
            )
        }
        cancelledStart.cancel()
        do {
            _ = try await cancelledStart.value
            throw VerificationFailure.failed(
                "a cancelled function call created a fresh desktop task"
            )
        } catch is CancellationError {
            // Expected.
        }
        try await Task.sleep(for: .milliseconds(30))
        let requestsAfterCancelledStart = await barrierTransport.requestCount()
        try expect(requestsAfterCancelledStart == requestsBeforeCancelledStart,
                   "a cancelled function call reached computer use after motor drain")
        await barrierCoordinator.shutdown()

        let terminalResponse = ComputerUseHTTPResponse(
            data: try jsonData(["id": "unused", "status": "completed", "output": []]),
            statusCode: 200
        )
        let failingTransport = VerificationFlakyComputerUseTransport(
            failuresRemaining: 10,
            eventualResponse: terminalResponse
        )
        let failingCoordinator = DesktopTaskCoordinator(
            clientFactory: { key in
                ComputerUseClient(apiKey: key, transport: failingTransport)
            },
            environmentFactory: { taskID in
                try MacDesktopEnvironment(
                    taskID: taskID,
                    permissionProvider: deniedPermissions,
                    actionPerformer: VerificationMacDesktopPerformer()
                )
            }
        )
        await failingCoordinator.configure(apiKey: "verification-key")
        let failingTask = try await failingCoordinator.start(goal: "Click a visible video.")
        try await eventually(
            "initial computer-use transport failure did not become observable",
            attempts: 300
        ) {
            await failingCoordinator.status(taskID: failingTask.taskID)?.status == .failed
        }
        let failedStatus = await failingCoordinator.status(taskID: failingTask.taskID)
        try expect(failedStatus?.stepCount == 0
                   && failedStatus?.failureCode == "initial_request_transport_failed",
                   "zero-step computer-use failure lost its safe phase diagnostic")
        await failingCoordinator.shutdown()
    }

    /// Kept type-checked even though integration tests cannot construct the
    /// concrete coordinator without a live API key and macOS screen capture.
    private static func coordinatorAPIContract(
        _ coordinator: DesktopTaskCoordinator,
        taskID: String
    ) async throws {
        await coordinator.configure(apiKey: "verification-key")
        _ = try await coordinator.start(
            goal: "Open the requested page.",
            successCriteria: "The page is visibly open.",
            sessionID: "voice-session"
        )
        _ = try await coordinator.update(taskID: taskID, instruction: "Use the other window.")
        _ = await coordinator.status(taskID: taskID)
        _ = await coordinator.cancelActive(
            matchingSessionID: "voice-session",
            reason: "Voice session ended."
        )
        _ = await coordinator.cancelActiveAndWait()
        await coordinator.pauseForOwnerSpeech()
        await coordinator.resumeAfterOwnerTurn()
        _ = try await coordinator.cancel(taskID: taskID)
        await coordinator.shutdown()
    }

    private static func realtimeUpdatesCannotRepurposeStaleTasks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-computer-task-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = VerificationBlockingComputerUseTransport()
        let deniedPermissions = MacDesktopPermissionProvider {
            MacDesktopPermissionStatus(
                screenRecordingAllowed: false,
                accessibilityAllowed: false,
                eventPostingAllowed: false
            )
        }
        let coordinator = DesktopTaskCoordinator(
            clientFactory: { key in
                ComputerUseClient(apiKey: key, transport: transport)
            },
            environmentFactory: { taskID in
                try MacDesktopEnvironment(
                    taskID: taskID,
                    permissionProvider: deniedPermissions,
                    actionPerformer: VerificationMacDesktopPerformer()
                )
            }
        )
        await coordinator.configure(apiKey: "verification-key")
        let registry = ToolRegistry(
            memoryStore: MemoryStore(configuration: .init(rootURL: root)),
            configuration: .init(
                allowedComputerRoots: [root],
                auditURL: root.appendingPathComponent("audit.jsonl")
            ),
            commandApproval: { _ in false },
            desktopTaskCoordinator: coordinator
        )
        let first = await registry.execute(
            name: "computer_task",
            argumentsJSON: #"{"action":"start","goal":"Click the token video.","success_criteria":"Its watch page is open."}"#,
            context: ToolInvocationContext(
                callID: "stale-task-start",
                sessionID: "verification-session",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Click the token video.",
                ownerAudioItemID: "owner-audio-stale-start"
            )
        )
        guard first.ok,
              let firstID = first.metadata["desktop_task_id"]?.stringValue else {
            throw VerificationFailure.failed("Realtime could not start the initial desktop task")
        }
        let replacement = await registry.execute(
            name: "computer_task",
            argumentsJSON: #"{"action":"update","task_id":"\#(firstID)","instruction":"Maximize Gmail."}"#,
            context: ToolInvocationContext(
                callID: "stale-task-unrelated-update",
                sessionID: "verification-session",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Maximize Gmail.",
                ownerAudioItemID: "owner-audio-stale-replacement"
            )
        )
        guard replacement.ok,
              let replacementID = replacement.metadata["desktop_task_id"]?.stringValue else {
            throw VerificationFailure.failed("Realtime could not replace the stale desktop task")
        }
        let oldStatus = await coordinator.status(taskID: firstID)
        let newStatus = await coordinator.status(taskID: replacementID)
        try expect(firstID != replacementID
                   && oldStatus?.status == .cancelled
                   && newStatus?.goal.contains("Maximize Gmail") == true
                   && newStatus?.goal.contains("token video") == false,
                   "an unrelated owner request was grafted onto a stale desktop task")
        _ = try? await coordinator.cancel(taskID: replacementID)
        await coordinator.shutdown()
    }

    private static func realtimeSchemaAndEvidencePolicy() throws {
        let exposedNames = Set(ToolRegistry.realtimeFunctionSchemas.map(\.name))
        let expectedNames: Set<String> = [
            "delegate_task",
            "memory_search",
            "memory_read",
            "memory_remember",
            "wait_for_user",
            "relationship_expect_quiet",
            "relationship_explain_absence",
        ]
        try expect(
            ToolRegistry.realtimeFunctionSchemas.count == expectedNames.count
                && exposedNames == expectedNames,
            "Realtime exposes an action path besides delegate_task: \(exposedNames.sorted())"
        )
        let retiredActionSchemas: Set<String> = [
            "research",
            "personal_action",
            "youtube_search",
            "calendar_action",
            "intent_proposal",
            "computer_open",
            "computer_action",
            "computer_visual",
            "computer_task",
            "mail",
        ]
        try expect(
            exposedNames.isDisjoint(with: retiredActionSchemas),
            "Realtime can still bypass Osiris through a retired action schema"
        )
        try expect(ToolEvidencePolicy.requiresFinalizedTranscript("computer_task"),
                   "the private legacy fallback lost its finalized-turn boundary")
        try expect(ToolRegistry.desktopEvidenceRequestsClearScreenPostcondition(
            "Use the blue image as my wallpaper, then clear the screen so I can see it."
        ) && ToolRegistry.desktopEvidenceRequestsClearScreenPostcondition(
            "Set the wallpaper and minimize all my windows."
        ) && !ToolRegistry.desktopEvidenceRequestsClearScreenPostcondition(
            "Set the wallpaper, but do not clear the screen."
        ) && !ToolRegistry.desktopEvidenceRequestsClearScreenPostcondition(
            "Set the wallpaper."
        ), "clear-screen completion was not narrowly bound to explicit owner evidence")
        let verifiedFinalReceipt = NativeDesktopActionResult(
            action: .minimizeEverything,
            applicationName: "Mac",
            affectedCount: 3,
            summary: "Minimized 3 windows.",
            effectVerified: true,
            applicationCount: 2,
            remainingVisibleCount: 0
        )
        let incompleteFinalReceipt = NativeDesktopActionResult(
            action: .minimizeEverything,
            applicationName: "Mac",
            affectedCount: 2,
            summary: "One window remains.",
            effectVerified: false,
            applicationCount: 2,
            remainingVisibleCount: 1
        )
        try expect(DesktopTaskCoordinator.finalNativeReceiptIsVerified(verifiedFinalReceipt)
                   && !DesktopTaskCoordinator.finalNativeReceiptIsVerified(incompleteFinalReceipt),
                   "desktop task completion no longer requires a verified zero-window native receipt")
    }

    private static func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw VerificationFailure.failed("computer-use request body was not JSON")
        }
        return object
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func eventually(
        _ message: String,
        attempts: Int = 200,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VerificationFailure.failed(message)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationFailure.failed(message) }
    }
}

#if COMPUTER_USE_FOCUSED
@main
enum ComputerUseFocusedVerifier {
    static func main() async throws {
        let checks = try await ComputerUseVerification.run()
        print(#"{"ok":true,"computerUseChecks":\#(checks)}"#)
    }
}
#endif
