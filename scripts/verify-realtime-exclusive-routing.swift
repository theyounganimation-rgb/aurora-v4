import Foundation

// This focused transport verifier does not compose the full identity prompt;
// it supplies only the bound RealtimeClient needs for its private-state item.
enum AuroraVoiceInstructions {
    static let maximumInnerLifeUpdateCharacters = 1_350
}

private enum ExclusiveRealtimeVerificationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class ExclusiveVerificationSocket: AuroraRealtimeSocket {
    private let lock = NSLock()
    private var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var sentMessages: [String] = []

    func resume() {}

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        lock.lock()
        receiveHandler = completionHandler
        lock.unlock()
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        lock.lock()
        if case .string(let text) = message {
            sentMessages.append(text)
        }
        lock.unlock()
        completionHandler(nil)
    }

    func cancel() {}

    func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        let handler = receiveHandler
        receiveHandler = nil
        lock.unlock()
        guard let handler else {
            throw ExclusiveRealtimeVerificationFailure.failed(
                "fake Realtime socket had no pending receive"
            )
        }
        handler(.success(.string(text)))
    }

    func sentEvents() -> [[String: Any]] {
        lock.lock()
        let messages = sentMessages
        lock.unlock()
        return messages.compactMap { text in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}

private final class ExclusiveVerificationSocketFactory {
    private(set) var sockets: [ExclusiveVerificationSocket] = []

    func make(_: URLRequest) -> AuroraRealtimeSocket {
        let socket = ExclusiveVerificationSocket()
        sockets.append(socket)
        return socket
    }
}

private final class ExclusiveVerificationScheduledTask: AuroraRealtimeScheduledTask {
    func cancel() {}
}

private final class ExclusiveVerificationScheduler: AuroraRealtimeScheduling {
    var now: TimeInterval { 100 }

    func schedule(
        on _: DispatchQueue,
        after _: TimeInterval,
        _: @escaping () -> Void
    ) -> AuroraRealtimeScheduledTask {
        ExclusiveVerificationScheduledTask()
    }
}

private final class ExclusiveVerificationAudio: AuroraRealtimeAudio {
    var onMicrophonePCM: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)?
    var onPlaybackIdle: (() -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var started = false

    func start() throws { started = true }
    func stop() { started = false }
    func enqueuePlayback(_: Data, for _: AuroraPlaybackKey) {}
    func markPlaybackItemComplete(_: AuroraPlaybackKey) {}
    func interruptPlayback() -> [AuroraPlaybackCut] { [] }
}

@main
private enum RealtimeExclusiveRoutingVerifier {
    private struct Harness {
        let client: AuroraRealtimeClient
        let socket: ExclusiveVerificationSocket
        let audio: ExclusiveVerificationAudio
    }

    private static let allowedNames: Set<String> = [
        "delegate_task",
        "codex_project_chat",
        "conversation_move",
        "memory_search",
        "memory_read",
        "memory_remember",
        "continuity_read",
        "continuity_patch",
        "wait_for_user",
        "relationship_expect_quiet",
        "relationship_explain_absence",
    ]

    private static let retiredNames = [
        "intent_proposal",
        "research",
        "youtube_search",
        "calendar_action",
        "personal_action",
        "computer_list",
        "computer_read",
        "computer_open",
        "computer_action",
        "computer_task",
        "computer_visual",
        "computer_run",
        "mail",
        "owner_understanding_update",
        "private_life_share",
    ]

    static func main() throws {
        let toolsJSON = try verificationToolsJSON()
        var rejectedNames = Set<String>()
        for (index, name) in retiredNames.enumerated() {
            let harness = try makeHarness(toolsJSON: toolsJSON, suffix: String(index))
            var deliveredCalls: [RealtimeFunctionCall] = []
            var diagnosedName: String?
            harness.client.onFunctionCall = { deliveredCalls.append($0) }
            harness.client.onDiagnostic = { _, kind, metadata in
                if kind == "unexposed_function_call_rejected" {
                    diagnosedName = metadata["tool"]
                }
            }
            let callID = "retired_\(index)"
            let responseID = "exclusive_response_\(index)"
            try committedTurn(
                itemID: "exclusive_input_\(index)",
                responseID: responseID,
                transcript: "Please do that on my Mac.",
                socket: harness.socket,
                client: harness.client
            )
            try deliver([
                "type": "response.done",
                "response": [
                    "id": responseID,
                    "status": "completed",
                    "output": [[
                        "type": "function_call",
                        "status": "completed",
                        "call_id": callID,
                        "name": name,
                        "arguments": "{}",
                    ]],
                ],
            ], socket: harness.socket, client: harness.client)

            try expect(
                deliveredCalls.isEmpty,
                "unadvertised retired call \(name) escaped to AuroraAppModel"
            )
            try expect(
                diagnosedName == name,
                "Realtime did not diagnose retired function \(name)"
            )
            let gotRejection = harness.socket.sentEvents().contains { event in
                guard event["type"] as? String == "conversation.item.create",
                      let item = event["item"] as? [String: Any],
                      item["type"] as? String == "function_call_output",
                      item["call_id"] as? String == callID,
                      let output = item["output"] as? String else { return false }
                return output.contains("tool_not_exposed")
            }
            try expect(
                gotRejection,
                "Realtime did not return tool_not_exposed for \(name)"
            )
            rejectedNames.insert(name)
        }
        try expect(rejectedNames == Set(retiredNames), "retired-call test table was incomplete")

        let data = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "allowedFunctions": allowedNames.sorted(),
                "retiredFunctionsRejected": retiredNames,
                "checks": [
                    "unadvertisedCallsNeverReachAppModel": true,
                    "everyRetiredCallGetsToolNotExposed": true,
                    "everyRetiredCallIsDiagnosed": true,
                ],
            ],
            options: [.sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func makeHarness(toolsJSON: String, suffix: String) throws -> Harness {
        let audio = ExclusiveVerificationAudio()
        let factory = ExclusiveVerificationSocketFactory()
        let callbackQueue = DispatchQueue(
            label: "aurora.verify.realtime-exclusive.callbacks.\(suffix)"
        )
        let client = AuroraRealtimeClient(
            audio: audio,
            callbackQueue: callbackQueue,
            socketFactory: factory.make,
            scheduler: ExclusiveVerificationScheduler()
        )
        _ = try client.start(configuration: RealtimeSessionConfiguration(
            apiKey: "verification-only",
            instructions: "Verification session.",
            toolsJSON: toolsJSON
        ))
        client.drainStateForVerification()
        guard let socket = factory.sockets.last else {
            throw ExclusiveRealtimeVerificationFailure.failed(
                "Realtime did not create a socket"
            )
        }
        try deliver(["type": "session.created", "session": [:]], socket: socket, client: client)
        guard let update = socket.sentEvents().last(where: {
            $0["type"] as? String == "session.update"
        }),
        let session = update["session"] as? [String: Any] else {
            throw ExclusiveRealtimeVerificationFailure.failed(
                "Realtime did not send its production session update"
            )
        }
        let advertised = Set(
            (session["tools"] as? [[String: Any]])?.compactMap {
                $0["name"] as? String
            } ?? []
        )
        try expect(
            session["tool_choice"] as? String == "required"
                && advertised == allowedNames,
            "ordinary owner audio can bypass the required conversation_move/delegate decision"
        )
        try deliver(["type": "session.updated", "session": [:]], socket: socket, client: client)
        try expect(audio.started, "audio did not start after the configured session was accepted")
        return Harness(client: client, socket: socket, audio: audio)
    }

    private static func verificationToolsJSON() throws -> String {
        let tools: [[String: Any]] = allowedNames.sorted().map { name in
            [
                "type": "function",
                "name": name,
                "description": "Verification-only production function.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": true,
                ],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: tools)
        return String(decoding: data, as: UTF8.self)
    }

    private static func committedTurn(
        itemID: String,
        responseID: String,
        transcript: String,
        socket: ExclusiveVerificationSocket,
        client: AuroraRealtimeClient
    ) throws {
        try deliver([
            "type": "input_audio_buffer.committed",
            "item_id": itemID,
            "previous_item_id": NSNull(),
        ], socket: socket, client: client)
        try deliver([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": itemID,
            "transcript": transcript,
        ], socket: socket, client: client)
        try deliver([
            "type": "response.created",
            "response": ["id": responseID, "status": "in_progress"],
        ], socket: socket, client: client)
    }

    private static func deliver(
        _ event: [String: Any],
        socket: ExclusiveVerificationSocket,
        client: AuroraRealtimeClient
    ) throws {
        try socket.emit(event)
        client.drainStateForVerification()
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw ExclusiveRealtimeVerificationFailure.failed(message)
        }
    }
}
