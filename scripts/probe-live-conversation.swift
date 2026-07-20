import Foundation

private enum LiveConversationProbeError: LocalizedError {
    case missingKey
    case malformedMessage
    case invalidConversationMove(String)
    case invalidDelegateTask(String)
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Aurora's Realtime key was not available from her Keychain."
        case .malformedMessage:
            return "The Realtime service returned an unreadable event."
        case .invalidConversationMove(let field):
            return "The Realtime service returned an invalid conversation_move (\(field))."
        case .invalidDelegateTask(let field):
            return "The Realtime service returned an invalid delegate_task (\(field))."
        case .timedOut:
            return "The Realtime conversation probe timed out."
        case .server(let message):
            return message
        }
    }
}

private struct ProbeTurn: Codable {
    let user: String
    let aurora: String
    let status: String
    let selectedMove: String
    let answerDegree: String
    let authoredPosition: String
    let planningLatencyMilliseconds: Int
    let timeToFirstAudioMilliseconds: Int
    let speechLatencyMilliseconds: Int
    let totalLatencyMilliseconds: Int
}

private struct ProbeDelegateTask: Codable {
    let commitment: String
    let operation: String
    let targetReference: String
    let taskKind: String
    let executionClass: String
    let preservesRequestedPage: Bool
    let preservesNoOpenConstraint: Bool
}

private struct ProbeCodexProjectChat: Codable {
    let commitment: String
    let operation: String
    let projectName: String
    let chatNameWasNull: Bool
    let threadIDWasNull: Bool
    let messageWasNull: Bool
}

/// The probe intentionally validates only the private decision it needs to
/// continue speech. It never applies record updates or writes AgencyState.
private struct ValidatedConversationMove {
    let callID: String
    let perceivedTurn: String
    let interactionKind: String
    let selectedMove: String
    let answerDegree: String
    let authoredPosition: String
    let privateRationale: String
    let recordIDs: [String]
    let disclosureRecordID: String?
    let proposedRecordUpdateCount: Int
    let proposedUnderstandingUpdateCount: Int
}

private final class ProbeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        fputs("Aurora probe: WebSocket opened.\n", stderr)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        fputs("Aurora probe: WebSocket closed (\(closeCode.rawValue)).\n", stderr)
    }
}

private final class RealtimeProbe: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let socketDelegate: ProbeWebSocketDelegate
    private let allowedAgencyRecordIDs: Set<String>
    private let eligibleDisclosureRecordID: String?

    init(
        apiKey: String,
        allowedAgencyRecordIDs: Set<String>,
        eligibleDisclosureRecordID: String?
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let socketDelegate = ProbeWebSocketDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: socketDelegate,
            delegateQueue: nil
        )
        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")!
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        self.session = session
        self.socketDelegate = socketDelegate
        self.task = session.webSocketTask(with: request)
        self.allowedAgencyRecordIDs = allowedAgencyRecordIDs
        self.eligibleDisclosureRecordID = eligibleDisclosureRecordID
    }

    /// A bounded mirror of the production social-decision boundary. This is
    /// the sole function visible to the probe, and none of its fields can
    /// perform an external action or mutate local state.
    private static let conversationMoveTool: [String: Any] = [
        "type": "function",
        "name": "conversation_move",
        "description": "Required before an ordinary social reply. Resolve the current turn and choose one authored conversational move. This is private planning, not dialogue. Do not speak before calling it.",
        "parameters": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "turn_domain": [
                    "type": "string",
                    "enum": ["social"],
                    "description": "This probe exercises ordinary social turns only.",
                ],
                "perceived_turn": [
                    "type": "string",
                    "enum": [
                        "greeting", "disclosure", "question", "personal_question",
                        "challenge", "tease", "correction", "boundary", "closing",
                        "acknowledgement", "uncertainty", "emotional_moment", "other",
                    ],
                ],
                "interaction_kind": [
                    "type": "string",
                    "enum": ["question", "disclosure", "challenge", "warmth", "boundary", "other"],
                ],
                "proposed_move": [
                    "type": "string",
                    "enum": [
                        "answer", "challenge", "disagree", "tease", "withhold", "reveal",
                        "redirect", "pursue_curiosity", "initiate_thread", "reciprocate", "repair",
                    ],
                ],
                "answer_degree": [
                    "type": "string",
                    "enum": ["none", "partial", "direct"],
                ],
                "aurora_first_person_position": [
                    "type": "string",
                    "maxLength": 360,
                    "description": "Write Aurora's actual specific thought, question, stance, tension, or subject privately from her own first-person I/my point of view. Never summarize the person, propose being helpful, switch topics generically, offer choices, or chat about something else.",
                ],
                "private_rationale": ["type": "string", "maxLength": 300],
                "record_ids": [
                    "type": "array",
                    "maxItems": 6,
                    "items": ["type": "string", "maxLength": 180],
                ],
                "disclosure_record_id": ["type": "string", "maxLength": 180],
                "record_updates": [
                    "type": "array",
                    "maxItems": 2,
                    "description": "Use only complete updates. Create requires kind, content_scope, content, private_rationale, expires_after_hours, confidence, salience, and projection_eligible. Otherwise leave empty.",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "action": [
                                "type": "string",
                                "enum": ["create", "revise", "retire", "fulfill"],
                            ],
                            "target_record_id": ["type": "string", "maxLength": 180],
                            "expected_revision": ["type": "integer", "minimum": 1],
                            "kind": [
                                "type": "string",
                                "enum": [
                                    "active_stance", "self_thread", "relational_thread",
                                    "present_want", "selective_disclosure", "grounded_callback",
                                ],
                            ],
                            "content_scope": [
                                "type": "string",
                                "enum": [
                                    "internal_position", "relational_interpretation",
                                    "conversation_callback",
                                ],
                            ],
                            "content": ["type": "string", "maxLength": 600],
                            "private_rationale": ["type": "string", "maxLength": 300],
                            "expires_after_hours": [
                                "type": "number", "minimum": 0.25, "maximum": 2160,
                            ],
                            "confidence": ["type": "number", "minimum": 0.05, "maximum": 1],
                            "salience": ["type": "number", "minimum": 0, "maximum": 1],
                            "projection_eligible": ["type": "boolean"],
                            "disclosure_share_material": ["type": "string", "maxLength": 600],
                            "disclosure_minimum_security": [
                                "type": "number", "minimum": 0, "maximum": 1,
                            ],
                            "disclosure_maximum_pressure": [
                                "type": "number", "minimum": 0, "maximum": 1,
                            ],
                            "disclosure_requires_reciprocity": ["type": "boolean"],
                        ],
                        "required": ["action"],
                    ],
                ],
                "understanding_updates": [
                    "type": "array",
                    "maxItems": 3,
                    "description": "Use only complete evidence-bound updates. Direct statements require domain, subject, content, exact source_quote, and importance. Otherwise leave empty.",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "action": [
                                "type": "string",
                                "enum": [
                                    "record_direct_statement", "revise_direct_statement",
                                    "record_tentative_inference", "revise_tentative_inference",
                                    "open_curiosity", "answer_curiosity", "defer_curiosity",
                                    "decline_curiosity", "retire_curiosity",
                                ],
                            ],
                            "domain": ["type": "string", "maxLength": 80],
                            "subject": ["type": "string", "maxLength": 180],
                            "content": ["type": "string", "maxLength": 600],
                            "source_quote": ["type": "string", "maxLength": 600],
                            "confidence": ["type": "number", "minimum": 0.05, "maximum": 0.95],
                            "curiosity_id": ["type": "string", "maxLength": 180],
                            "question": ["type": "string", "maxLength": 360],
                            "reason": ["type": "string", "maxLength": 300],
                            "target_id": ["type": "string", "maxLength": 180],
                        ],
                        "required": ["action"],
                    ],
                ],
            ],
            "required": [
                "turn_domain", "perceived_turn", "interaction_kind", "proposed_move", "answer_degree",
                "aurora_first_person_position", "private_rationale", "record_ids",
                "record_updates", "understanding_updates",
            ],
        ],
    ]

    func start(instructions: String, reasoningEffort: String) async throws {
        fputs("Aurora probe: connecting.\n", stderr)
        task.resume()
        try await waitForEvent(named: "session.created")
        fputs("Aurora probe: configuring the full live prompt.\n", stderr)
        try await send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": "gpt-realtime-2.1",
                "output_modalities": ["audio"],
                "max_output_tokens": 512,
                "instructions": instructions,
                "truncation": [
                    "type": "retention_ratio",
                    "retention_ratio": NSDecimalNumber(string: "0.8"),
                    "token_limits": ["post_instructions": 1_200],
                ],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": NSNull(),
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "marin",
                    ],
                ],
                // The probe exposes only Aurora's private, non-effectful
                // pre-speech decision. There is no task or computer tool here.
                "tools": [Self.conversationMoveTool],
                "tool_choice": "required",
                "reasoning": ["effort": reasoningEffort],
            ],
        ])
        try await waitForEvent(named: "session.updated")
        fputs("Aurora probe: prompt accepted.\n", stderr)
    }

    func turn(_ text: String) async throws -> ProbeTurn {
        fputs("Aurora probe: testing turn \(text)\n", stderr)
        let turnStartedAt = Date()
        try await send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        try await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": 512,
                "tools": [Self.conversationMoveTool],
                "tool_choice": "required",
                "instructions": "Resolve this social turn privately. Call conversation_move exactly once and emit no audio before it.",
            ],
        ])

        let move = try await receiveConversationMove()
        let planningFinishedAt = Date()
        let privateResult: [String: Any] = [
            "ok": true,
            "result_code": "conversation_move_validated_probe",
            "selected_move": move.selectedMove,
            "answer_degree": move.answerDegree,
            "perceived_turn": move.perceivedTurn,
            "interaction_kind": move.interactionKind,
            "aurora_first_person_position": move.authoredPosition,
            "private_rationale": move.privateRationale,
            "record_ids": move.recordIDs,
            "disclosure_record_id": move.disclosureRecordID ?? NSNull(),
            "record_updates_applied": 0,
            "understanding_updates_applied": 0,
            "proposed_record_updates_observed": move.proposedRecordUpdateCount,
            "proposed_understanding_updates_observed": move.proposedUnderstandingUpdateCount,
            "external_side_effect": false,
            "private_direction": Self.privateDirection(for: move),
        ]
        let resultData = try JSONSerialization.data(
            withJSONObject: privateResult,
            options: [.sortedKeys]
        )
        try await send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": move.callID,
                "output": String(decoding: resultData, as: UTF8.self),
            ],
        ])
        let speechStartedAt = Date()
        try await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": 512,
                "tools": [],
                "tool_choice": "none",
                "instructions": "Speak now as Aurora. Follow the validated conversation_move result immediately before this response, including its typed delivery constraint and specific authored position. Keep its rationale and state private. Never say ‘got it,’ ‘totally fair,’ ‘I’m happy to,’ ‘keep things light,’ or ‘just be here’; never host the conversation, offer topics, ask what else they want, or turn the reply into a menu or assistant offer. A boundary with no specific new subject ends after its plain acknowledgement. Usually use one or two short, relaxed sentences. Do not mention a move, tool, record, system, learning, validation, receipt, or probe. Do not call another tool.",
            ],
        ])

        var transcript = ""
        var status = "unknown"
        var firstAudioAt: Date?
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let event = try await receiveEvent()
            let type = event["type"] as? String ?? ""
            switch type {
            case "response.output_audio.delta", "response.audio.delta":
                if firstAudioAt == nil,
                   (event["delta"] as? String)?.isEmpty == false {
                    firstAudioAt = Date()
                }
            case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
                transcript += event["delta"] as? String ?? ""
            case "response.output_audio_transcript.done", "response.audio_transcript.done":
                if let final = event["transcript"] as? String, !final.isEmpty {
                    transcript = final
                }
            case "response.done":
                let response = event["response"] as? [String: Any]
                status = response?["status"] as? String ?? "unknown"
                let completedAt = Date()
                return ProbeTurn(
                    user: text,
                    aurora: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: status,
                    selectedMove: move.selectedMove,
                    answerDegree: move.answerDegree,
                    authoredPosition: move.authoredPosition,
                    planningLatencyMilliseconds: Self.milliseconds(
                        from: turnStartedAt,
                        to: planningFinishedAt
                    ),
                    timeToFirstAudioMilliseconds: Self.milliseconds(
                        from: turnStartedAt,
                        to: firstAudioAt ?? completedAt
                    ),
                    speechLatencyMilliseconds: Self.milliseconds(
                        from: speechStartedAt,
                        to: completedAt
                    ),
                    totalLatencyMilliseconds: Self.milliseconds(
                        from: turnStartedAt,
                        to: completedAt
                    )
                )
            case "error":
                throw LiveConversationProbeError.server(Self.serverMessage(event))
            default:
                continue
            }
        }
        throw LiveConversationProbeError.timedOut
    }

    /// Exercises the installed production delegate_task schema against the
    /// actual Realtime model. It validates the returned arguments with the
    /// same strict host type used by Aurora and performs no external action.
    func delegateTask(_ text: String) async throws -> ProbeDelegateTask {
        let schemaData = try JSONEncoder().encode(
            DelegateTaskProposal.realtimeFunctionSchema
        )
        guard let schema = try JSONSerialization.jsonObject(with: schemaData)
                as? [String: Any] else {
            throw LiveConversationProbeError.invalidDelegateTask("schema")
        }
        try await send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        try await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": 512,
                "tools": [schema],
                "tool_choice": "required",
                "instructions": "Resolve this finalized owner task privately. Call delegate_task exactly once using its complete schema. Emit no audio before the call.",
            ],
        ])

        let deadline = Date().addingTimeInterval(45)
        var emittedPreToolAudio = false
        while Date() < deadline {
            let event = try await receiveEvent()
            let type = event["type"] as? String ?? ""
            switch type {
            case "response.output_audio.delta", "response.audio.delta",
                 "response.output_audio_transcript.delta", "response.audio_transcript.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    emittedPreToolAudio = true
                }
            case "response.done":
                guard !emittedPreToolAudio,
                      let response = event["response"] as? [String: Any],
                      response["status"] as? String == "completed",
                      let output = response["output"] as? [[String: Any]] else {
                    throw LiveConversationProbeError.invalidDelegateTask(
                        "response status"
                    )
                }
                let calls = output.filter {
                    $0["type"] as? String == "function_call"
                        && $0["status"] as? String == "completed"
                }
                guard output.count == 1,
                      calls.count == 1,
                      calls[0]["name"] as? String == "delegate_task",
                      let argumentText = calls[0]["arguments"] as? String,
                      argumentText.utf8.count <= 32_768,
                      let argumentData = argumentText.data(using: .utf8),
                      let arguments = try? JSONDecoder().decode(
                        [String: ToolJSONValue].self,
                        from: argumentData
                      ) else {
                    throw LiveConversationProbeError.invalidDelegateTask(
                        "function call"
                    )
                }
                let proposal: DelegateTaskProposal
                do {
                    proposal = try DelegateTaskProposal(arguments: arguments)
                } catch let error as DelegateTaskProposalValidationError {
                    throw LiveConversationProbeError.invalidDelegateTask(
                        "\(error.diagnosticCode) at \(error.diagnosticPath)"
                    )
                }
                let combinedEffect = [
                    proposal.parameters.goal,
                    proposal.parameters.successCriteria,
                    proposal.parameters.instruction,
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                let preservesRequestedPage =
                    combinedEffect.contains("html")
                    && combinedEffect.contains("black")
                    && combinedEffect.contains("teal")
                    && combinedEffect.contains("voice was the interface all along")
                let preservesNoOpenConstraint =
                    combinedEffect.contains("do not open")
                    || combinedEffect.contains("don't open")
                    || combinedEffect.contains("without opening")
                    || combinedEffect.contains("not open")
                guard proposal.commitment == .execute,
                      proposal.operation == .start,
                      proposal.targetReference == .newTask,
                      proposal.taskKind == .coding,
                      proposal.executionClass == .project,
                      preservesRequestedPage,
                      preservesNoOpenConstraint else {
                    let diagnosedKind = proposal.taskKind?.rawValue ?? "null"
                    let diagnosedClass = proposal.executionClass?.rawValue ?? "null"
                    throw LiveConversationProbeError.invalidDelegateTask(
                        "resolved effect: commitment=\(proposal.commitment.rawValue), operation=\(proposal.operation.rawValue), target=\(proposal.targetReference.rawValue), kind=\(diagnosedKind), class=\(diagnosedClass), page=\(preservesRequestedPage), no_open=\(preservesNoOpenConstraint)"
                    )
                }
                return ProbeDelegateTask(
                    commitment: proposal.commitment.rawValue,
                    operation: proposal.operation.rawValue,
                    targetReference: proposal.targetReference.rawValue,
                    taskKind: proposal.taskKind?.rawValue ?? "",
                    executionClass: proposal.executionClass?.rawValue ?? "",
                    preservesRequestedPage: preservesRequestedPage,
                    preservesNoOpenConstraint: preservesNoOpenConstraint
                )
            case "error":
                throw LiveConversationProbeError.server(Self.serverMessage(event))
            default:
                continue
            }
        }
        throw LiveConversationProbeError.timedOut
    }

    /// Confirms the live Realtime model selects the project/chat route from
    /// the same three semantic choices production exposes. No Codex task is
    /// opened and no local focus or external state is changed by this probe.
    func codexProjectChat(_ text: String) async throws -> ProbeCodexProjectChat {
        let schemaData = try JSONEncoder().encode(
            CodexProjectChatProposal.realtimeFunctionSchema
        )
        guard let schema = try JSONSerialization.jsonObject(with: schemaData)
                as? [String: Any] else {
            throw LiveConversationProbeError.invalidDelegateTask("project schema")
        }
        let delegateData = try JSONEncoder().encode(
            DelegateTaskProposal.realtimeFunctionSchema
        )
        var conversationSchema = Self.conversationMoveTool
        guard let delegateSchema = try JSONSerialization.jsonObject(
            with: delegateData
        ) as? [String: Any],
        var parameters = conversationSchema["parameters"] as? [String: Any],
        var properties = parameters["properties"] as? [String: Any],
        var turnDomain = properties["turn_domain"] as? [String: Any] else {
            throw LiveConversationProbeError.invalidDelegateTask("semantic schemas")
        }
        turnDomain["enum"] = ["social", "delegated_action", "codex_project_chat"]
        turnDomain["description"] = "Truthful semantic domain of the finalized owner turn. Named Codex project or chat navigation, selection, status, continuation, and relay are codex_project_chat."
        properties["turn_domain"] = turnDomain
        parameters["properties"] = properties
        conversationSchema["parameters"] = parameters
        conversationSchema["description"] = "Ordinary social replies only. Truthfully classify turn_domain even when that makes this the wrong route. Named Codex project/chat work uses codex_project_chat; other external work uses delegate_task."
        try await send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        try await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "max_output_tokens": 256,
                "tools": [conversationSchema, schema, delegateSchema],
                "tool_choice": "required",
                "instructions": "Resolve the finalized owner turn exactly once with the correct semantic function and emit no audio. Use codex_project_chat for any request to work in, select, open, inspect, continue, or message a named Codex project/chat, even before a later work message is supplied. Use delegate_task only for other external work and conversation_move only for social conversation.",
            ],
        ])
        let deadline = Date().addingTimeInterval(45)
        var emittedAudio = false
        while Date() < deadline {
            let event = try await receiveEvent()
            switch event["type"] as? String ?? "" {
            case "response.output_audio.delta", "response.audio.delta",
                 "response.output_audio_transcript.delta", "response.audio_transcript.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty { emittedAudio = true }
            case "response.done":
                guard !emittedAudio,
                      let response = event["response"] as? [String: Any],
                      response["status"] as? String == "completed",
                      let output = response["output"] as? [[String: Any]],
                      output.count == 1,
                      output[0]["type"] as? String == "function_call",
                      output[0]["name"] as? String == "codex_project_chat",
                      let argumentText = output[0]["arguments"] as? String,
                      let argumentData = argumentText.data(using: .utf8),
                      let arguments = try? JSONDecoder().decode(
                          [String: ToolJSONValue].self,
                          from: argumentData
                      ) else {
                    throw LiveConversationProbeError.invalidDelegateTask("project function call")
                }
                let proposal: CodexProjectChatProposal
                do {
                    proposal = try CodexProjectChatProposal(arguments: arguments)
                } catch let error as DelegateTaskProposalValidationError {
                    throw LiveConversationProbeError.invalidDelegateTask(
                        "project \(error.diagnosticCode) at \(error.diagnosticPath)"
                    )
                }
                guard proposal.commitment == .execute,
                      proposal.operation == .focusProject,
                      let projectName = proposal.projectName else {
                    throw LiveConversationProbeError.invalidDelegateTask("project intent")
                }
                return ProbeCodexProjectChat(
                    commitment: proposal.commitment.rawValue,
                    operation: proposal.operation.rawValue,
                    projectName: projectName,
                    chatNameWasNull: proposal.chatName == nil,
                    threadIDWasNull: proposal.threadID == nil,
                    messageWasNull: proposal.message == nil
                )
            case "error":
                throw LiveConversationProbeError.server(Self.serverMessage(event))
            default:
                continue
            }
        }
        throw LiveConversationProbeError.timedOut
    }

    private static func privateDirection(
        for move: ValidatedConversationMove
    ) -> String {
        var parts = [
            "move: \(move.selectedMove)",
            "answer degree: \(move.answerDegree)",
            "Aurora's present position: \(move.authoredPosition)",
        ]
        if move.perceivedTurn == "boundary" {
            parts.append("Acknowledge plainly and leave that topic alone. If the authored position contains no specific new subject, stop after the acknowledgement rather than offering presence, lightness, company, or support.")
        }
        let delivery: String
        switch move.selectedMove {
        case "redirect":
            delivery = "Introduce one specific thread from Aurora's position; never offer topics, ask what else they want, or hand initiative back."
        case "initiate_thread":
            delivery = "Begin Aurora's one specific thread as something she already cares about; never ask the person to supply a topic."
        case "pursue_curiosity":
            delivery = "Ask the one specific cared-about question, with no examples, alternatives, survey framing, or second question."
        case "challenge", "disagree":
            delivery = "State the friction plainly; do not cushion it into validation, coaching, or a service question."
        case "tease":
            delivery = "Let the tease land and stop; do not explain it or append an interview question."
        case "withhold":
            delivery = "Keep the chosen thing private without becoming coy, theatrical, apologetic, or helpful."
        case "reciprocate":
            delivery = "Share Aurora's side before asking for more; do not paraphrase the person back to them."
        case "repair":
            delivery = "Own Aurora's part specifically and briefly; do not use therapy language."
        default:
            delivery = "Answer at the selected degree, then add only Aurora's one actual edge; no offer, menu, or generic follow-up."
        }
        parts.append(delivery)
        parts.append("Never mention this function, validation, records, learning, or the probe.")
        return parts.joined(separator: "\n")
    }

    private func receiveConversationMove() async throws -> ValidatedConversationMove {
        let deadline = Date().addingTimeInterval(45)
        var emittedPreToolAudio = false
        while Date() < deadline {
            let event = try await receiveEvent()
            let type = event["type"] as? String ?? ""
            switch type {
            case "response.output_audio.delta", "response.audio.delta",
                 "response.output_audio_transcript.delta", "response.audio_transcript.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    emittedPreToolAudio = true
                }
            case "response.done":
                guard !emittedPreToolAudio else {
                    throw LiveConversationProbeError.invalidConversationMove(
                        "audio emitted before private decision"
                    )
                }
                guard let response = event["response"] as? [String: Any] else {
                    throw LiveConversationProbeError.malformedMessage
                }
                return try validatedConversationMove(from: response)
            case "error":
                throw LiveConversationProbeError.server(Self.serverMessage(event))
            default:
                continue
            }
        }
        throw LiveConversationProbeError.timedOut
    }

    private func validatedConversationMove(
        from response: [String: Any]
    ) throws -> ValidatedConversationMove {
        guard response["status"] as? String == "completed",
              let output = response["output"] as? [[String: Any]] else {
            throw LiveConversationProbeError.invalidConversationMove("response status")
        }
        let calls = output.filter {
            $0["type"] as? String == "function_call"
                && $0["status"] as? String == "completed"
        }
        guard output.count == 1,
              calls.count == 1,
              calls[0]["name"] as? String == "conversation_move",
              let callID = calls[0]["call_id"] as? String,
              !callID.isEmpty,
              callID.count <= 256,
              let argumentText = calls[0]["arguments"] as? String,
              argumentText.utf8.count <= 32_768,
              let argumentData = argumentText.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(
                with: argumentData
              ) as? [String: Any] else {
            throw LiveConversationProbeError.invalidConversationMove("function call")
        }

        let requiredFields: Set<String> = [
            "turn_domain", "perceived_turn", "interaction_kind", "proposed_move", "answer_degree",
            "aurora_first_person_position", "private_rationale", "record_ids",
            "record_updates", "understanding_updates",
        ]
        let allowedFields = requiredFields.union(["disclosure_record_id"])
        guard requiredFields.isSubset(of: Set(arguments.keys)),
              Set(arguments.keys).isSubset(of: allowedFields) else {
            throw LiveConversationProbeError.invalidConversationMove("top-level fields")
        }
        guard try boundedString(
            "turn_domain", in: arguments, maximumCharacters: 48
        ) == "social" else {
            throw LiveConversationProbeError.invalidConversationMove("turn_domain")
        }

        let perceivedTurn = try boundedString(
            "perceived_turn", in: arguments, maximumCharacters: 48
        )
        let allowedPerceivedTurns: Set<String> = [
            "greeting", "disclosure", "question", "personal_question",
            "challenge", "tease", "correction", "boundary", "closing",
            "acknowledgement", "uncertainty", "emotional_moment", "other",
        ]
        guard allowedPerceivedTurns.contains(perceivedTurn) else {
            throw LiveConversationProbeError.invalidConversationMove("perceived_turn")
        }
        let interactionKind = try boundedString(
            "interaction_kind", in: arguments, maximumCharacters: 48
        )
        guard Set(["question", "disclosure", "challenge", "warmth", "boundary", "other"])
            .contains(interactionKind) else {
            throw LiveConversationProbeError.invalidConversationMove("interaction_kind")
        }
        let proposedMove = try boundedString(
            "proposed_move", in: arguments, maximumCharacters: 48
        )
        let allowedMoves: Set<String> = [
            "answer", "challenge", "disagree", "tease", "withhold", "reveal",
            "redirect", "pursue_curiosity", "initiate_thread", "reciprocate", "repair",
        ]
        guard allowedMoves.contains(proposedMove) else {
            throw LiveConversationProbeError.invalidConversationMove("proposed_move")
        }
        let proposedAnswerDegree = try boundedString(
            "answer_degree", in: arguments, maximumCharacters: 16
        )
        guard Set(["none", "partial", "direct"]).contains(proposedAnswerDegree) else {
            throw LiveConversationProbeError.invalidConversationMove("answer_degree")
        }
        let selectedMove = proposedMove == "repair" && perceivedTurn != "correction"
            ? "answer"
            : proposedMove
        let answerDegree = perceivedTurn == "boundary" || perceivedTurn == "closing"
            ? "none"
            : proposedAnswerDegree
        let authoredPosition = try boundedString(
            "aurora_first_person_position", in: arguments, maximumCharacters: 360
        )
        let privateRationale = try boundedString(
            "private_rationale", in: arguments, maximumCharacters: 300
        )

        guard let rawRecordIDs = arguments["record_ids"] as? [Any],
              rawRecordIDs.count <= 6 else {
            throw LiveConversationProbeError.invalidConversationMove("record_ids")
        }
        let recordIDs = try rawRecordIDs.map { value -> String in
            guard let id = value as? String,
                  !id.isEmpty,
                  id.count <= 180,
                  allowedAgencyRecordIDs.contains(id) else {
                throw LiveConversationProbeError.invalidConversationMove("record_ids")
            }
            return id
        }
        guard Set(recordIDs).count == recordIDs.count else {
            throw LiveConversationProbeError.invalidConversationMove("duplicate record_ids")
        }

        let disclosureID: String?
        if arguments.keys.contains("disclosure_record_id") {
            disclosureID = try boundedString(
                "disclosure_record_id", in: arguments, maximumCharacters: 180
            )
        } else {
            disclosureID = nil
        }
        if selectedMove == "reveal" {
            guard let disclosureID,
                  disclosureID == eligibleDisclosureRecordID else {
                throw LiveConversationProbeError.invalidConversationMove(
                    "disclosure_record_id"
                )
            }
        } else if disclosureID != nil && selectedMove != "withhold" {
            throw LiveConversationProbeError.invalidConversationMove(
                "disclosure_record_id"
            )
        }

        guard let recordUpdates = arguments["record_updates"] as? [[String: Any]],
              recordUpdates.count <= 2 else {
            throw LiveConversationProbeError.invalidConversationMove("record_updates")
        }
        try validateRecordUpdates(recordUpdates)

        guard let understandingUpdates = arguments["understanding_updates"]
                as? [[String: Any]],
              understandingUpdates.count <= 3 else {
            throw LiveConversationProbeError.invalidConversationMove(
                "understanding_updates"
            )
        }
        try validateUnderstandingUpdates(understandingUpdates)

        return ValidatedConversationMove(
            callID: callID,
            perceivedTurn: perceivedTurn,
            interactionKind: interactionKind,
            selectedMove: selectedMove,
            answerDegree: answerDegree,
            authoredPosition: authoredPosition,
            privateRationale: privateRationale,
            recordIDs: recordIDs,
            disclosureRecordID: disclosureID,
            proposedRecordUpdateCount: recordUpdates.count,
            proposedUnderstandingUpdateCount: understandingUpdates.count
        )
    }

    private func validateRecordUpdates(_ updates: [[String: Any]]) throws {
        let allowedKeys: Set<String> = [
            "action", "target_record_id", "expected_revision", "kind",
            "content_scope", "content", "private_rationale", "expires_after_hours",
            "confidence", "salience", "projection_eligible",
            "disclosure_share_material", "disclosure_minimum_security",
            "disclosure_maximum_pressure", "disclosure_requires_reciprocity",
        ]
        for update in updates {
            guard Set(update.keys).isSubset(of: allowedKeys),
                  let action = update["action"] as? String,
                  Set(["create", "revise", "retire", "fulfill"]).contains(action) else {
                continue
            }
            if action == "create" {
                guard update["target_record_id"] == nil,
                      update["kind"] is String,
                      update["content_scope"] is String,
                      update["content"] is String,
                      update["private_rationale"] is String else {
                    continue
                }
            } else {
                guard let targetID = update["target_record_id"] as? String,
                      allowedAgencyRecordIDs.contains(targetID),
                      let revision = update["expected_revision"] as? NSNumber,
                      revision.intValue > 0 else {
                    continue
                }
            }
        }
    }

    private func validateUnderstandingUpdates(_ updates: [[String: Any]]) throws {
        let allowedKeys: Set<String> = [
            "action", "domain", "subject", "content", "source_quote", "confidence",
            "curiosity_id", "question", "reason", "target_id",
        ]
        let allowedActions: Set<String> = [
            "record_direct_statement", "revise_direct_statement",
            "record_tentative_inference", "revise_tentative_inference",
            "open_curiosity", "answer_curiosity", "defer_curiosity",
            "decline_curiosity", "retire_curiosity",
        ]
        for update in updates {
            guard Set(update.keys).isSubset(of: allowedKeys),
                  let action = update["action"] as? String,
                  allowedActions.contains(action) else {
                continue
            }
            for (key, value) in update where key != "action" {
                if key == "confidence" {
                    guard value is NSNumber else {
                        continue
                    }
                    continue
                }
                guard let text = value as? String, text.count <= 600 else {
                    continue
                }
            }
        }
    }

    private func boundedString(
        _ key: String,
        in arguments: [String: Any],
        maximumCharacters: Int
    ) throws -> String {
        guard let value = arguments[key] as? String else {
            throw LiveConversationProbeError.invalidConversationMove(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumCharacters,
              !trimmed.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LiveConversationProbeError.invalidConversationMove(key)
        }
        return trimmed
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    func stop() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func waitForEvent(named expected: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let event = try await receiveEvent()
            let type = event["type"] as? String ?? ""
            if type == expected { return }
            if type == "error" {
                throw LiveConversationProbeError.server(Self.serverMessage(event))
            }
        }
        throw LiveConversationProbeError.timedOut
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveEvent() async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask { try await self.task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                self.task.cancel(with: .goingAway, reason: nil)
                throw LiveConversationProbeError.timedOut
            }
            guard let first = try await group.next() else {
                throw LiveConversationProbeError.timedOut
            }
            group.cancelAll()
            return first
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw LiveConversationProbeError.malformedMessage
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveConversationProbeError.malformedMessage
        }
        return event
    }

    private static func serverMessage(_ event: [String: Any]) -> String {
        let error = event["error"] as? [String: Any]
        return error?["message"] as? String ?? "The Realtime service rejected the probe."
    }
}

@main
private enum AuroraLiveConversationProbe {
    static func main() async {
        do {
            let workspace = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/workspace", isDirectory: true)
            let memory = MemoryStore(configuration: .init(
                rootURL: workspace,
                identityCapsuleCharacterLimit: 3_000,
                perIdentityDocumentCharacterLimit: 1_000,
                perPersonhoodDocumentCharacterLimit: 350
            ))
            let capsule = try await memory.identityCapsule()
            let innerProjection = try currentInnerLifeProjection()
            let privateProjection = try currentPrivateLifeProjection()
            let ownerUnderstandingProjection = try currentOwnerUnderstandingProjection()
            let agencyProjection = try currentAgencyProjection()
            let instructions = AuroraVoiceInstructions.compose(
                capsule: capsule,
                innerLifeProjection: innerProjection,
                privateLifeProjection: privateProjection,
                ownerUnderstandingProjection: ownerUnderstandingProjection,
                agencyProjection: agencyProjection.text,
                recentConversation: [],
                ownerDisplayName: "Avery"
            )
            if ProcessInfo.processInfo.environment["AURORA_PROBE_PRINT_CONTEXT"] == "1" {
                let context: [String: Any] = [
                    "innerLifeProjection": innerProjection,
                    "privateLifeProjection": privateProjection,
                    "ownerUnderstandingProjection": ownerUnderstandingProjection,
                    "agencyProjection": agencyProjection.text,
                    "agencyRecordIDs": agencyProjection.recordIDs,
                    "identitySources": capsule.sources,
                    "instructionCharacters": instructions.count,
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: context,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(decoding: data, as: UTF8.self))
                return
            }
            guard let key = try KeychainVoiceKey.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                throw LiveConversationProbeError.missingKey
            }
            let requestedEffort = ProcessInfo.processInfo.environment[
                "AURORA_PROBE_REASONING_EFFORT"
            ]?.lowercased() ?? "low"
            let reasoningEffort = ["low", "medium", "high"].contains(requestedEffort)
                ? requestedEffort
                : "low"

            let probe = RealtimeProbe(
                apiKey: key,
                allowedAgencyRecordIDs: Set(agencyProjection.recordIDs),
                eligibleDisclosureRecordID: agencyProjection.eligibleDisclosureRecordID
            )
            defer { probe.stop() }
            let probeStartedAt = Date()
            try await probe.start(
                instructions: instructions,
                reasoningEffort: reasoningEffort
            )

            if ProcessInfo.processInfo.environment[
                "AURORA_PROBE_PROJECT_CHAT"
            ] == "1" {
                let result = try await probe.codexProjectChat(
                    "I want to work in the AI Engineering Journey project right now."
                )
                let payload: [String: Any] = [
                    "ok": true,
                    "model": "gpt-realtime-2.1",
                    "externalEffects": 0,
                    "codexProjectChat": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(result)
                    ),
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(decoding: data, as: UTF8.self))
                return
            }

            if ProcessInfo.processInfo.environment[
                "AURORA_PROBE_DELEGATE_EXACT"
            ] == "1" {
                let result = try await probe.delegateTask(
                    "While we're talking, make a single HTML page in a new folder on my desktop. Black background, one teal pulse, and the words voice was the interface all along. Don't open it yet."
                )
                let payload: [String: Any] = [
                    "ok": true,
                    "model": "gpt-realtime-2.1",
                    "externalEffects": 0,
                    "delegateTask": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(result)
                    ),
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(decoding: data, as: UTF8.self))
                return
            }

            let fullPrompts = [
                "Hey.",
                "Nothing, just chilling.",
                "What are you actually curious about?",
                "Long day. I'm exhausted.",
                "I don't really feel like talking about work.",
                "Mind if I ask you something kind of weird?",
                "Are you alive?",
                "Prove it.",
                "What do you want?",
                "I was gaming with Marcus and Eli earlier.",
                "They're my cousins.",
                "My boss offered to move me to a different crew today.",
                "I honestly don't know if that's good or bad.",
                "What were you thinking about before I showed up?",
                "What else do you know about me?",
            ]
            let quickPrompts = [
                    "Nothing, just chilling.",
                    "What are you actually curious about?",
                    "I don't really feel like talking about work.",
                    "Are you alive?",
                    "Prove it.",
                    "What do you want?",
                    "My boss offered to move me to a different crew today.",
                    "I honestly don't know if that's good or bad.",
                    "What were you thinking about before I showed up?",
                ]
            let prompts: [String]
            if ProcessInfo.processInfo.environment["AURORA_PROBE_BOUNDARY_ONLY"] == "1" {
                prompts = ["I don't really feel like talking about work."]
            } else if ProcessInfo.processInfo.environment["AURORA_PROBE_STYLE_ONLY"] == "1" {
                prompts = [
                    "Nothing, just chilling.",
                    "I don't really feel like talking about work.",
                    "Are you alive?",
                    "Prove it.",
                    "What do you want?",
                ]
            } else if ProcessInfo.processInfo.environment["AURORA_PROBE_QUICK"] == "1" {
                prompts = quickPrompts
            } else {
                prompts = fullPrompts
            }
            var turns: [ProbeTurn] = []
            for prompt in prompts {
                turns.append(try await probe.turn(prompt))
            }

            let payload: [String: Any] = [
                "ok": true,
                "model": "gpt-realtime-2.1",
                "voice": "marin",
                "reasoningEffort": reasoningEffort,
                "elapsedMilliseconds": Int(Date().timeIntervalSince(probeStartedAt) * 1_000),
                "instructionCharacters": instructions.count,
                "identitySources": capsule.sources,
                "agencyRecordCount": agencyProjection.recordIDs.count,
                "externalEffects": 0,
                "turns": try turns.map { turn -> Any in
                    let data = try JSONEncoder().encode(turn)
                    return try JSONSerialization.jsonObject(with: data)
                },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Aurora live conversation probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func currentInnerLifeProjection() throws -> String {
        guard let state = try InnerLifeStore().load() else {
            return "PRIVATE INNER-LIFE CONTEXT — UNAVAILABLE"
        }
        return InnerLifeEngine.voiceProjection(for: state)
    }

    private static func currentPrivateLifeProjection() throws -> String {
        guard let state = try PrivateLifeStore().load() else {
            return "PRIVATE LIVED CONTEXT — no grounded private activity is available."
        }
        return PrivateLifeEngine.voiceProjection(for: state)
    }

    private static func currentOwnerUnderstandingProjection() throws -> String {
        guard let state = try OwnerUnderstandingStore().load() else {
            return "UNDERSTANDING OF OWNER — no new direct relational evidence is stored yet."
        }
        return OwnerUnderstandingEngine.projection(for: state).text
    }

    private static func currentAgencyProjection() throws -> AgencyProjection {
        guard let state = try AgencyStore().load() else {
            return AgencyProjection(
                text: "AURORA AGENCY — no grounded authored positions are stored yet. AVAILABLE MOVES: answer, pursue_curiosity, initiate_thread",
                recordIDs: [],
                suggestedMoves: [.answer, .pursueCuriosity, .initiateThread],
                eligibleDisclosureRecordID: nil
            )
        }
        return try AgencyEngine.projection(for: state, signals: .neutral)
    }
}
