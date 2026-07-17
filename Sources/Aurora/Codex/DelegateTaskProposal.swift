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
        let taskKind: DelegateTaskKind?
        if let taskKindText = try Self.optionalString(
            "task_kind", in: arguments, path: "$.task_kind"
        ) {
            guard let decoded = DelegateTaskKind(rawValue: taskKindText) else {
                throw DelegateTaskProposalValidationError.unsupportedValue(path: "$.task_kind")
            }
            taskKind = decoded
        } else {
            taskKind = nil
        }
        let executionClass: DelegateTaskExecutionClass?
        if let executionClassText = try Self.optionalString(
            "execution_class", in: arguments, path: "$.execution_class"
        ) {
            guard let decoded = DelegateTaskExecutionClass(rawValue: executionClassText) else {
                throw DelegateTaskProposalValidationError.unsupportedValue(
                    path: "$.execution_class"
                )
            }
            executionClass = decoded
        } else {
            executionClass = nil
        }
        if operation == .start || operation == .update, executionClass == nil {
            throw DelegateTaskProposalValidationError.missingField("execution_class")
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
        try self.init(
            commitment: commitment,
            operation: operation,
            targetReference: target,
            taskKind: taskKind,
            executionClass: executionClass,
            parameters: DelegateTaskParameters(
                goal: try Self.optionalString("goal", in: parameterObject, path: "$.parameters.goal"),
                successCriteria: try Self.optionalString(
                    "success_criteria", in: parameterObject, path: "$.parameters.success_criteria"
                ),
                instruction: try Self.optionalString(
                    "instruction", in: parameterObject, path: "$.parameters.instruction"
                ),
                workspacePath: try Self.optionalString(
                    "workspace_path", in: parameterObject, path: "$.parameters.workspace_path"
                )
            )
        )
    }

    public static let realtimeFunctionSchema = RealtimeFunctionSchema(
        name: "delegate_task",
        description: "Hand every committed external task to Osiris/Codex in the background. This is Aurora's only action boundary for Mac control, apps, files, coding, research, web work, mail, notes, reminders, calendars, and any other requested effect. Preserve the smallest effect the owner actually requested; never inflate open/show/continue/reopen into install, rebuild, audit, test, or report work unless explicitly requested. Resolve references to work Codex already created or is doing as operation=update,target_reference=active_task so the same visible thread and artifacts are reused. Set execution_class=interactive for an immediate action or showing/reopening an existing artifact, standard for bounded non-project work, and project only for substantial creation or modification. Use task_kind=computer for opening/showing/controlling something on the current Mac, including bringing an existing local artifact into view. Use coding only to create or modify software. New unrelated work: commitment=execute, operation=start, target_reference=new_task, include task_kind, execution_class, and parameters.goal. Change or revisit active work: include execution_class, omit task_kind, and include only parameters.instruction. Cancel/status: target_reference=active_task, omit task_kind and execution_class, and use empty parameters.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "commitment": enumStringSchema(IntentCommitment.allCases.map(\.rawValue)),
                "operation": enumStringSchema(DelegateTaskOperation.allCases.map(\.rawValue)),
                "target_reference": enumStringSchema(
                    DelegateTaskTargetReference.allCases.map(\.rawValue)
                ),
                "task_kind": enumStringSchema(DelegateTaskKind.allCases.map(\.rawValue)),
                "execution_class": enumStringSchema(
                    DelegateTaskExecutionClass.allCases.map(\.rawValue)
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "goal": boundedStringSchema(maximum: maximumGoalCharacters),
                        "success_criteria": boundedStringSchema(
                            maximum: maximumSuccessCriteriaCharacters
                        ),
                        "instruction": boundedStringSchema(maximum: maximumInstructionCharacters),
                        "workspace_path": boundedStringSchema(
                            maximum: maximumWorkspacePathCharacters
                        ),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "required": .array([
                .string("commitment"),
                .string("operation"),
                .string("target_reference"),
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

    private static func boundedStringSchema(maximum: Int) -> ToolJSONValue {
        // The host enforces the exact bounds. Keeping advisory min/max copies
        // out of the Realtime schema saves prompt tokens on every voice session.
        _ = maximum
        return .object([
            "type": .string("string"),
        ])
    }
}
