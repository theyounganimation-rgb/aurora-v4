import Foundation

/// Realtime owns this semantic decision. Deterministic host code validates the
/// value but never reparses the owner's wording through a phrase grammar.
public enum IntentCommitment: String, Codable, Sendable, Equatable, CaseIterable {
    case execute
    case cancel
    case conditional
    case delayed
    case uncertain
}

/// Realtime resolves whether the owner is conversing or asking Aurora to hand
/// work to her Codex runtime. The host validates this structure without
/// interpreting the owner's words a second time.
public enum DelegateTaskOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case start
    case update
    case cancel
    case status
}

public enum DelegateTaskKind: String, Codable, Sendable, Equatable, CaseIterable {
    case computer
    case coding
    case research
    case general

    /// Direct screen and application control should stop with the live voice
    /// session. Longer creative/intellectual work is genuinely backstage work
    /// and remains explicitly cancellable through its persistent task.
    var continuesAfterVoiceRest: Bool { self != .computer }
}

/// Realtime resolves the latency/complexity contract together with semantic
/// intent. Deterministic code validates and enforces this value; it never
/// guesses complexity by reparsing the owner's words.
public enum DelegateTaskExecutionClass: String, Codable, Sendable, Equatable, CaseIterable {
    case interactive
    case standard
    case project
}

public enum DelegateTaskTargetReference: String, Codable, Sendable, Equatable, CaseIterable {
    case newTask = "new_task"
    case activeTask = "active_task"
}

public struct DelegateTaskParameters: Codable, Sendable, Equatable {
    public let goal: String?
    public let successCriteria: String?
    public let instruction: String?
    public let workspacePath: String?

    public init(
        goal: String? = nil,
        successCriteria: String? = nil,
        instruction: String? = nil,
        workspacePath: String? = nil
    ) {
        self.goal = goal
        self.successCriteria = successCriteria
        self.instruction = instruction
        self.workspacePath = workspacePath
    }

    public static let empty = DelegateTaskParameters()
}

public enum DelegateTaskProposalValidationError: LocalizedError, Sendable, Equatable {
    case missingField(String)
    case unknownField(path: String, field: String)
    case invalidType(path: String)
    case unsupportedValue(path: String)
    case emptyValue(path: String)
    case valueTooLong(path: String, maximumCharacters: Int)
    case unsupportedControlCharacter(path: String)
    case incompatibleFields(operation: DelegateTaskOperation)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "The task proposal is missing \(field)."
        case .unknownField(let path, let field):
            return "The task proposal contains an unsupported field at \(path).\(field)."
        case .invalidType(let path):
            return "The task proposal field \(path) has the wrong type."
        case .unsupportedValue(let path):
            return "The task proposal field \(path) has an unsupported value."
        case .emptyValue(let path):
            return "The task proposal field \(path) cannot be empty."
        case .valueTooLong(let path, let maximum):
            return "The task proposal field \(path) exceeds \(maximum) characters."
        case .unsupportedControlCharacter(let path):
            return "The task proposal field \(path) contains an unsupported control character."
        case .incompatibleFields(let operation):
            return "The task proposal fields do not match \(operation.rawValue)."
        }
    }

    /// A content-free diagnostic that can cross the audit boundary without
    /// recording the owner's task text or any rejected function-call value.
    public var diagnosticCode: String {
        switch self {
        case .missingField: return "missing_field"
        case .unknownField: return "unknown_field"
        case .invalidType: return "invalid_type"
        case .unsupportedValue: return "unsupported_value"
        case .emptyValue: return "empty_value"
        case .valueTooLong: return "value_too_long"
        case .unsupportedControlCharacter: return "unsupported_control_character"
        case .incompatibleFields: return "incompatible_fields"
        }
    }

    /// The schema location only. It never contains the rejected content.
    public var diagnosticPath: String {
        switch self {
        case .missingField(let field): return "$.\(field)"
        case .unknownField(let path, _): return path
        case .invalidType(let path), .unsupportedValue(let path),
             .emptyValue(let path), .valueTooLong(let path, _),
             .unsupportedControlCharacter(let path):
            return path
        case .incompatibleFields(let operation):
            return "$.operation.\(operation.rawValue)"
        }
    }
}

public struct DelegateTaskProposal: Codable, Sendable, Equatable {
    public static let maximumGoalCharacters = 2_000
    public static let maximumSuccessCriteriaCharacters = 1_000
    public static let maximumInstructionCharacters = 1_200
    public static let maximumWorkspacePathCharacters = 1_024

    public let commitment: IntentCommitment
    public let operation: DelegateTaskOperation
    public let targetReference: DelegateTaskTargetReference
    public let taskKind: DelegateTaskKind?
    public let executionClass: DelegateTaskExecutionClass?
    public let parameters: DelegateTaskParameters

    /// Stable host-only representation used to bind a task proposed before an
    /// internal memory/continuity lookup to the exact later delegate_task.
    /// Helper output may refine an execution plan, but it cannot change this
    /// authorized effect without a new owner turn.
    public var canonicalAuthorizationBinding: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public init(
        commitment: IntentCommitment,
        operation: DelegateTaskOperation,
        targetReference: DelegateTaskTargetReference,
        taskKind: DelegateTaskKind? = nil,
        executionClass: DelegateTaskExecutionClass? = nil,
        parameters: DelegateTaskParameters = .empty
    ) throws {
        self.commitment = commitment
        self.operation = operation
        self.targetReference = targetReference
        self.taskKind = taskKind
        switch operation {
        case .start:
            self.executionClass = executionClass ?? taskKind.map(Self.defaultExecutionClass)
        case .update:
            self.executionClass = executionClass ?? .standard
        case .cancel, .status:
            self.executionClass = executionClass
        }
        self.parameters = parameters
        try Self.validate(parameters)
        try Self.validateCombination(
            operation: operation,
            targetReference: targetReference,
            taskKind: taskKind,
            executionClass: self.executionClass,
            parameters: parameters
        )
    }

    /// JSON Schema is advisory for Realtime function calling. This initializer
    /// is the actual boundary and rejects every unknown or incompatible field.
    public init(arguments: [String: ToolJSONValue]) throws {
        try Self.rejectUnknownKeys(
            in: arguments,
            allowed: Set([
                "commitment", "operation", "target_reference", "task_kind",
                "execution_class", "parameters",
            ]),
            path: "$"
        )
        let commitmentText = try Self.requiredString(
            "commitment", in: arguments, path: "$.commitment"
        )
        guard let commitment = IntentCommitment(rawValue: commitmentText) else {
            throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.commitment")
        }
        let operationText = try Self.requiredString(
            "operation", in: arguments, path: "$.operation"
        )
        guard let operation = DelegateTaskOperation(rawValue: operationText) else {
            throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.operation")
        }
        let targetText = try Self.requiredString(
            "target_reference", in: arguments, path: "$.target_reference"
        )
        guard let target = DelegateTaskTargetReference(rawValue: targetText) else {
            throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.target_reference")
        }
        let proposedTaskKind: DelegateTaskKind?
        if let taskKindText = try Self.optionalString(
            "task_kind", in: arguments, path: "$.task_kind"
        ) {
            guard let decoded = DelegateTaskKind(rawValue: taskKindText) else {
                throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.task_kind")
            }
            proposedTaskKind = decoded
        } else {
            proposedTaskKind = nil
        }
        let proposedExecutionClass: DelegateTaskExecutionClass?
        if let executionClassText = try Self.optionalString(
            "execution_class", in: arguments, path: "$.execution_class"
        ) {
            guard let decoded = DelegateTaskExecutionClass(rawValue: executionClassText) else {
                throw DelegateTaskProposalValidationError.unsupportedValue(
                    path: "$.execution_class"
                )
            }
            proposedExecutionClass = decoded
        } else {
            proposedExecutionClass = nil
        }
        guard let rawParameters = arguments["parameters"] else {
            throw DelegateTaskProposalValidationError.missingField("parameters")
        }
        guard case .object(let parameterObject) = rawParameters else {
            throw DelegateTaskProposalValidationError.invalidType(path: "$.parameters")
        }
        try Self.rejectUnknownKeys(
            in: parameterObject,
            allowed: Set(["goal", "success_criteria", "instruction", "workspace_path"]),
            path: "$.parameters"
        )
        let goal = try Self.optionalString(
            "goal", in: parameterObject, path: "$.parameters.goal"
        )
        var successCriteria = try Self.optionalString(
            "success_criteria",
            in: parameterObject,
            path: "$.parameters.success_criteria"
        )
        var instruction = try Self.optionalString(
            "instruction", in: parameterObject, path: "$.parameters.instruction"
        )
        let workspacePath = try Self.optionalString(
            "workspace_path", in: parameterObject, path: "$.parameters.workspace_path"
        )

        // Realtime function schemas are advisory rather than a full
        // Structured Outputs boundary. Normalize only missing structural
        // classifiers; never reinterpret the owner's natural-language goal.
        // If an initial negative constraint lands in `instruction`, preserve
        // it verbatim as a success condition instead of losing the whole task.
        let taskKind = proposedTaskKind
        var executionClass = proposedExecutionClass
        if operation == .start {
            guard taskKind != nil else {
                throw DelegateTaskProposalValidationError.missingField("task_kind")
            }
            if executionClass == nil, let taskKind {
                // This is a structural execution-profile fallback from an
                // already-resolved task kind, never an interpretation of the
                // owner's words. Realtime still owns the semantic classifier.
                executionClass = Self.defaultExecutionClass(for: taskKind)
            }
            if let initialConstraint = instruction {
                successCriteria = try Self.mergingInitialConstraint(
                    successCriteria,
                    initialConstraint
                )
                instruction = nil
            }
        } else if operation == .update, executionClass == nil {
            throw DelegateTaskProposalValidationError.missingField("execution_class")
        }

        try self.init(
            commitment: commitment,
            operation: operation,
            targetReference: target,
            taskKind: taskKind,
            executionClass: executionClass,
            parameters: DelegateTaskParameters(
                goal: goal,
                successCriteria: successCriteria,
                instruction: instruction,
                workspacePath: workspacePath
            )
        )
    }

    public static let realtimeFunctionSchema = RealtimeFunctionSchema(
        name: "delegate_task",
        description: "Send every ordinary committed external task to Osiris/Codex: Mac, apps, browser, files, coding, research, mail, Notes, Calendar, Reminders, and other requested effects. Do not use this function when the owner explicitly asks to browse, select, create, leave, or message a named Codex project/chat; that sole exception uses codex_project_chat. Preserve the exact smallest effect and all negative constraints; never expand open/show/continue/reopen into install, rebuild, audit, test, or report work. Current-work references use operation=update,target_reference=active_task so the same thread and artifacts continue. Every property is required: use JSON null when inapplicable, never an object, array, or placeholder. execution_class: interactive for immediate control or showing an existing artifact; standard for bounded non-project work; project for software creation/modification or other substantial work. task_kind=computer only for operating existing Mac UI or showing an existing artifact. Creating or modifying any website, webpage, app, script, code, or code-bearing file is coding even on Desktop. New work: execute+start+new_task, include task_kind and execution_class, put the complete outcome and every constraint in parameters.goal as one string, and set instruction=null. Active-work changes put the exact revision in instruction with task_kind=null. Cancel/status use active_task with task_kind, execution_class, and all parameters null.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "commitment": enumStringSchema(IntentCommitment.allCases.map(\.rawValue)),
                "operation": enumStringSchema(DelegateTaskOperation.allCases.map(\.rawValue)),
                "target_reference": enumStringSchema(
                    DelegateTaskTargetReference.allCases.map(\.rawValue)
                ),
                "task_kind": nullableEnumStringSchema(DelegateTaskKind.allCases.map(\.rawValue)),
                "execution_class": nullableEnumStringSchema(
                    DelegateTaskExecutionClass.allCases.map(\.rawValue)
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "goal": nullableBoundedStringSchema(maximum: maximumGoalCharacters),
                        "success_criteria": nullableBoundedStringSchema(
                            maximum: maximumSuccessCriteriaCharacters
                        ),
                        "instruction": nullableBoundedStringSchema(maximum: maximumInstructionCharacters),
                        "workspace_path": nullableBoundedStringSchema(
                            maximum: maximumWorkspacePathCharacters
                        ),
                    ]),
                    "required": .array([
                        .string("goal"),
                        .string("success_criteria"),
                        .string("instruction"),
                        .string("workspace_path"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "required": .array([
                .string("commitment"),
                .string("operation"),
                .string("target_reference"),
                .string("task_kind"),
                .string("execution_class"),
                .string("parameters"),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    private static func validate(_ parameters: DelegateTaskParameters) throws {
        try validateText(
            parameters.goal,
            path: "$.parameters.goal",
            maximum: maximumGoalCharacters
        )
        try validateText(
            parameters.successCriteria,
            path: "$.parameters.success_criteria",
            maximum: maximumSuccessCriteriaCharacters
        )
        try validateText(
            parameters.instruction,
            path: "$.parameters.instruction",
            maximum: maximumInstructionCharacters
        )
        try validateText(
            parameters.workspacePath,
            path: "$.parameters.workspace_path",
            maximum: maximumWorkspacePathCharacters
        )
    }

    private static func mergingInitialConstraint(
        _ successCriteria: String?,
        _ initialConstraint: String
    ) throws -> String {
        let merged = successCriteria.map { "\($0) \(initialConstraint)" }
            ?? initialConstraint
        guard merged.count <= maximumSuccessCriteriaCharacters else {
            throw DelegateTaskProposalValidationError.valueTooLong(
                path: "$.parameters.success_criteria",
                maximumCharacters: maximumSuccessCriteriaCharacters
            )
        }
        return merged
    }

    private static func validateCombination(
        operation: DelegateTaskOperation,
        targetReference: DelegateTaskTargetReference,
        taskKind: DelegateTaskKind?,
        executionClass: DelegateTaskExecutionClass?,
        parameters: DelegateTaskParameters
    ) throws {
        let compatible: Bool
        switch operation {
        case .start:
            compatible = targetReference == .newTask
                && taskKind != nil
                && executionClass != nil
                && parameters.goal != nil
                && parameters.instruction == nil
        case .update:
            compatible = targetReference == .activeTask
                && taskKind == nil
                && executionClass != nil
                && parameters.goal == nil
                && parameters.successCriteria == nil
                && parameters.instruction != nil
                && parameters.workspacePath == nil
        case .cancel, .status:
            compatible = targetReference == .activeTask
                && taskKind == nil
                && executionClass == nil
                && parameters == .empty
        }
        guard compatible else {
            throw DelegateTaskProposalValidationError.incompatibleFields(operation: operation)
        }
    }

    private static func defaultExecutionClass(
        for taskKind: DelegateTaskKind
    ) -> DelegateTaskExecutionClass {
        switch taskKind {
        case .computer: return .interactive
        case .coding: return .project
        case .research, .general: return .standard
        }
    }

    private static func validateText(
        _ value: String?,
        path: String,
        maximum: Int
    ) throws {
        guard let value else { return }
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DelegateTaskProposalValidationError.emptyValue(path: path)
        }
        guard value.count <= maximum else {
            throw DelegateTaskProposalValidationError.valueTooLong(
                path: path,
                maximumCharacters: maximum
            )
        }
        guard value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw DelegateTaskProposalValidationError.unsupportedControlCharacter(path: path)
        }
    }

    private static func rejectUnknownKeys(
        in object: [String: ToolJSONValue],
        allowed: Set<String>,
        path: String
    ) throws {
        if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw DelegateTaskProposalValidationError.unknownField(path: path, field: unknown)
        }
    }

    private static func requiredString(
        _ key: String,
        in object: [String: ToolJSONValue],
        path: String
    ) throws -> String {
        guard let value = object[key] else {
            throw DelegateTaskProposalValidationError.missingField(key)
        }
        guard case .string(let string) = value else {
            throw DelegateTaskProposalValidationError.invalidType(path: path)
        }
        guard !string.isEmpty else {
            throw DelegateTaskProposalValidationError.emptyValue(path: path)
        }
        return string
    }

    private static func optionalString(
        _ key: String,
        in object: [String: ToolJSONValue],
        path: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        if case .null = value { return nil }
        guard case .string(let string) = value else {
            throw DelegateTaskProposalValidationError.invalidType(path: path)
        }
        return string
    }

    private static func enumStringSchema(_ values: [String]) -> ToolJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(ToolJSONValue.string)),
        ])
    }

    private static func nullableEnumStringSchema(_ values: [String]) -> ToolJSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "enum": .array(values.map(ToolJSONValue.string) + [.null]),
        ])
    }

    private static func boundedStringSchema(maximum: Int) -> ToolJSONValue {
        // The host enforces the exact bounds. Keeping advisory min/max copies
        // out of the Realtime schema saves prompt tokens on every voice session.
        _ = maximum
        return .object([
            "type": .string("string"),
        ])
    }

    private static func nullableBoundedStringSchema(maximum: Int) -> ToolJSONValue {
        _ = maximum
        return .object([
            "type": .array([.string("string"), .string("null")]),
        ])
    }
}

/// An explicit navigation/relay command for the user's existing Codex work.
/// This is intentionally separate from `delegate_task`: ordinary Aurora work
/// keeps its current isolated-task behavior unless the owner deliberately
/// selects a Codex project or chat.
public enum CodexProjectChatOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case listProjects = "list_projects"
    case focusProject = "focus_project"
    case focusChat = "focus_chat"
    case prepareNewChat = "prepare_new_chat"
    case relay
    case relayToChat = "relay_to_chat"
    case leaveFocus = "leave_focus"
    case status
}

public struct CodexProjectChatProposal: Codable, Sendable, Equatable {
    public static let maximumResourceNameCharacters = 240
    public static let maximumThreadIDCharacters = 256
    public static let maximumMessageCharacters = 4_000

    public let commitment: IntentCommitment
    public let operation: CodexProjectChatOperation
    public let projectName: String?
    public let chatName: String?
    public let threadID: String?
    public let message: String?

    public init(
        commitment: IntentCommitment,
        operation: CodexProjectChatOperation,
        projectName: String? = nil,
        chatName: String? = nil,
        threadID: String? = nil,
        message: String? = nil
    ) throws {
        self.commitment = commitment
        self.operation = operation
        self.projectName = projectName
        self.chatName = chatName
        self.threadID = threadID
        self.message = message
        try Self.validateText(
            projectName,
            path: "$.project_name",
            maximum: Self.maximumResourceNameCharacters
        )
        try Self.validateText(
            chatName,
            path: "$.chat_name",
            maximum: Self.maximumResourceNameCharacters
        )
        try Self.validateText(
            threadID,
            path: "$.thread_id",
            maximum: Self.maximumThreadIDCharacters
        )
        try Self.validateText(
            message,
            path: "$.message",
            maximum: Self.maximumMessageCharacters,
            allowNewlines: true
        )
        try Self.validateCombination(
            operation: operation,
            projectName: projectName,
            chatName: chatName,
            threadID: threadID,
            message: message
        )
    }

    /// Realtime function arguments are untrusted. Every property is required
    /// by the schema (nullable where inapplicable), and this boundary rejects
    /// unknown fields, wrong types, and incompatible operation shapes.
    public init(arguments: [String: ToolJSONValue]) throws {
        let required: Set<String> = [
            "commitment", "operation", "project_name", "chat_name",
            "thread_id", "message",
        ]
        guard Set(arguments.keys) == required else {
            if let unknown = arguments.keys.filter({ !required.contains($0) }).sorted().first {
                throw DelegateTaskProposalValidationError.unknownField(path: "$", field: unknown)
            }
            let missing = required.subtracting(arguments.keys).sorted().first ?? "field"
            throw DelegateTaskProposalValidationError.missingField(missing)
        }
        let commitmentText = try Self.requiredString(
            arguments["commitment"],
            path: "$.commitment"
        )
        guard let commitment = IntentCommitment(rawValue: commitmentText) else {
            throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.commitment")
        }
        let operationText = try Self.requiredString(
            arguments["operation"],
            path: "$.operation"
        )
        guard let operation = CodexProjectChatOperation(rawValue: operationText) else {
            throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.operation")
        }
        try self.init(
            commitment: commitment,
            operation: operation,
            projectName: try Self.nullableString(
                arguments["project_name"], path: "$.project_name"
            ),
            chatName: try Self.nullableString(
                arguments["chat_name"], path: "$.chat_name"
            ),
            threadID: try Self.nullableString(
                arguments["thread_id"], path: "$.thread_id"
            ),
            message: try Self.nullableString(
                arguments["message"], path: "$.message"
            )
        )
    }

    public static let realtimeFunctionSchema = RealtimeFunctionSchema(
        name: "codex_project_chat",
        description: "Use only when the owner explicitly wants to browse, select, continue, create, or leave a named Codex project/chat. This is not the ordinary task route: all normal Mac, coding, research, and other external work still uses delegate_task. A selected chat remains focused across turns until leave_focus or another selection. list_projects lists available Codex project roots. focus_project selects a project and returns its chats. focus_chat selects one returned chat by exact thread_id or unambiguous chat_name. prepare_new_chat selects a new chat in the current project but creates it only with the next relay. relay sends the host-finalized owner transcript exactly to the selected chat, so set every target/message field null. relay_to_chat is only for a one-utterance request that names the project/chat and contains a separate message; copy one exact contiguous owner-transcript span without adding or paraphrasing words. Every property is required; use JSON null when inapplicable.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "commitment": Self.enumSchema(IntentCommitment.allCases.map(\.rawValue)),
                "operation": Self.enumSchema(CodexProjectChatOperation.allCases.map(\.rawValue)),
                "project_name": Self.nullableStringSchema(
                    maximum: maximumResourceNameCharacters
                ),
                "chat_name": Self.nullableStringSchema(
                    maximum: maximumResourceNameCharacters
                ),
                "thread_id": Self.nullableStringSchema(
                    maximum: maximumThreadIDCharacters
                ),
                "message": Self.nullableStringSchema(
                    maximum: maximumMessageCharacters
                ),
            ]),
            "required": .array([
                .string("commitment"), .string("operation"),
                .string("project_name"), .string("chat_name"),
                .string("thread_id"), .string("message"),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    private static func validateCombination(
        operation: CodexProjectChatOperation,
        projectName: String?,
        chatName: String?,
        threadID: String?,
        message: String?
    ) throws {
        let targetCount = [chatName, threadID].compactMap { $0 }.count
        let compatible: Bool
        switch operation {
        case .listProjects, .prepareNewChat, .relay, .leaveFocus, .status:
            compatible = projectName == nil && targetCount == 0 && message == nil
        case .focusProject:
            compatible = projectName != nil && targetCount == 0 && message == nil
        case .focusChat:
            compatible = projectName == nil && targetCount == 1 && message == nil
        case .relayToChat:
            compatible = projectName != nil && targetCount == 1 && message != nil
        }
        guard compatible else {
            // Reuse the shared content-free diagnostic family; the operation
            // remains visible while rejected values never cross the audit log.
            throw DelegateTaskProposalValidationError.unsupportedValue(
                path: "$.operation.\(operation.rawValue)"
            )
        }
    }

    private static func validateText(
        _ value: String?,
        path: String,
        maximum: Int,
        allowNewlines: Bool = false
    ) throws {
        guard let value else { return }
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DelegateTaskProposalValidationError.emptyValue(path: path)
        }
        guard value.count <= maximum else {
            throw DelegateTaskProposalValidationError.valueTooLong(
                path: path,
                maximumCharacters: maximum
            )
        }
        let forbidden = CharacterSet.controlCharacters.subtracting(
            allowNewlines ? CharacterSet.newlines : CharacterSet()
        )
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw DelegateTaskProposalValidationError.unsupportedControlCharacter(path: path)
        }
    }

    private static func requiredString(
        _ value: ToolJSONValue?,
        path: String
    ) throws -> String {
        guard let value else {
            throw DelegateTaskProposalValidationError.missingField(
                String(path.dropFirst(2))
            )
        }
        guard case .string(let text) = value else {
            throw DelegateTaskProposalValidationError.invalidType(path: path)
        }
        return text
    }

    private static func nullableString(
        _ value: ToolJSONValue?,
        path: String
    ) throws -> String? {
        guard let value else {
            throw DelegateTaskProposalValidationError.missingField(
                String(path.dropFirst(2))
            )
        }
        if case .null = value { return nil }
        guard case .string(let text) = value else {
            throw DelegateTaskProposalValidationError.invalidType(path: path)
        }
        return text
    }

    private static func enumSchema(_ values: [String]) -> ToolJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(ToolJSONValue.string)),
        ])
    }

    private static func nullableStringSchema(maximum: Int) -> ToolJSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "minLength": .integer(1),
            "maxLength": .integer(maximum),
        ])
    }
}
