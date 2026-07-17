import Foundation

/// Realtime owns the semantic decision represented here. Deterministic code
/// validates this bounded proposal, but never reparses the owner's transcript
/// to decide what the words meant.
public enum IntentCommitment: String, Codable, Sendable, Equatable, CaseIterable {
    case execute
    case cancel
    case conditional
    case delayed
    case uncertain
}

/// The first intentionally narrow operation vocabulary carried by the generic
/// intent-proposal boundary. New domains can add typed operations later without
/// adding natural-language phrases to a deterministic router.
public enum IntentOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case notesOpenApplication = "notes.open_application"
    case notesCreate = "notes.create"
    case notesSetTitle = "notes.set_title"
    case notesAddItems = "notes.add_items"
    case notesRemoveItems = "notes.remove_items"
    case notesOpen = "notes.open"
}

/// Realtime may resolve a conversational reference only to one of these opaque
/// task-state handles. It may not provide a concrete Notes identifier; the host
/// resolves `active_note` from trusted session state after validation.
public enum IntentTargetReference: String, Codable, Sendable, Equatable, CaseIterable {
    case notesApplication = "notes_application"
    case newNote = "new_note"
    case activeNote = "active_note"
}

public struct IntentParameters: Codable, Sendable, Equatable {
    public let title: String?
    public let items: [String]?

    public init(title: String? = nil, items: [String]? = nil) {
        self.title = title
        self.items = items
    }

    public static let empty = IntentParameters()
}

public enum IntentProposalValidationError: LocalizedError, Sendable, Equatable {
    case missingField(String)
    case unknownField(path: String, field: String)
    case invalidType(path: String)
    case unsupportedValue(path: String)
    case emptyValue(path: String)
    case valueTooLong(path: String, maximumCharacters: Int)
    case tooManyItems(maximum: Int)
    case unsupportedControlCharacter(path: String)
    case incompatibleFields(operation: IntentOperation)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "The intent proposal is missing \(field)."
        case .unknownField(let path, let field):
            return "The intent proposal contains an unsupported field at \(path).\(field)."
        case .invalidType(let path):
            return "The intent proposal field \(path) has the wrong type."
        case .unsupportedValue(let path):
            return "The intent proposal field \(path) has an unsupported value."
        case .emptyValue(let path):
            return "The intent proposal field \(path) cannot be empty."
        case .valueTooLong(let path, let maximum):
            return "The intent proposal field \(path) exceeds \(maximum) characters."
        case .tooManyItems(let maximum):
            return "The intent proposal contains more than \(maximum) items."
        case .unsupportedControlCharacter(let path):
            return "The intent proposal field \(path) contains an unsupported control character."
        case .incompatibleFields(let operation):
            return "The intent proposal fields do not match \(operation.rawValue)."
        }
    }
}

public struct IntentProposal: Codable, Sendable, Equatable {
    public static let maximumTitleCharacters = 500
    public static let maximumItemCharacters = 500
    public static let maximumItems = 100
    public static let maximumCombinedItemCharacters = 12_000

    public let commitment: IntentCommitment
    public let operation: IntentOperation
    public let targetReference: IntentTargetReference
    public let parameters: IntentParameters

    public init(
        commitment: IntentCommitment,
        operation: IntentOperation,
        targetReference: IntentTargetReference,
        parameters: IntentParameters = .empty
    ) throws {
        self.commitment = commitment
        self.operation = operation
        self.targetReference = targetReference
        self.parameters = parameters
        try Self.validateParameterValues(parameters)
        try Self.validateCombination(
            operation: operation,
            targetReference: targetReference,
            parameters: parameters
        )
    }

    /// Strictly decodes Realtime function-call arguments after the outer JSON
    /// object has crossed the transport boundary. JSON Schema is advisory here;
    /// this initializer rejects unknown keys, wrong types, invalid enum values,
    /// incompatible field combinations, and oversized content itself.
    public init(arguments: [String: ToolJSONValue]) throws {
        let allowedTopLevel = Set([
            "commitment", "operation", "target_reference", "parameters",
        ])
        try Self.rejectUnknownKeys(
            in: arguments,
            allowed: allowedTopLevel,
            path: "$"
        )

        let commitmentText = try Self.requiredString(
            "commitment",
            in: arguments,
            path: "$.commitment"
        )
        guard let commitment = IntentCommitment(rawValue: commitmentText) else {
            throw IntentProposalValidationError.unsupportedValue(path: "$.commitment")
        }

        let operationText = try Self.requiredString(
            "operation",
            in: arguments,
            path: "$.operation"
        )
        guard let operation = IntentOperation(rawValue: operationText) else {
            throw IntentProposalValidationError.unsupportedValue(path: "$.operation")
        }

        let targetText = try Self.requiredString(
            "target_reference",
            in: arguments,
            path: "$.target_reference"
        )
        guard let targetReference = IntentTargetReference(rawValue: targetText) else {
            throw IntentProposalValidationError.unsupportedValue(path: "$.target_reference")
        }

        guard let rawParameters = arguments["parameters"] else {
            throw IntentProposalValidationError.missingField("parameters")
        }
        guard case .object(let parameterObject) = rawParameters else {
            throw IntentProposalValidationError.invalidType(path: "$.parameters")
        }
        try Self.rejectUnknownKeys(
            in: parameterObject,
            allowed: Set(["title", "items"]),
            path: "$.parameters"
        )

        let title = try Self.optionalString(
            "title",
            in: parameterObject,
            path: "$.parameters.title"
        )
        let items = try Self.optionalStringArray(
            "items",
            in: parameterObject,
            path: "$.parameters.items"
        )
        try self.init(
            commitment: commitment,
            operation: operation,
            targetReference: targetReference,
            parameters: IntentParameters(title: title, items: items)
        )
    }

    /// The schema helps Realtime produce the intended shape, but callers must
    /// still use `init(arguments:)` because schema adherence is not trusted.
    public static let realtimeFunctionSchema = RealtimeFunctionSchema(
        name: "intent_proposal",
        description: "Propose one Notes action resolved from the active voice conversation. Resolve references such as 'a new one', 'call it', and 'add that' into the typed fields. Use this as the only output for the action; do not speak before its result.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "commitment": enumStringSchema(IntentCommitment.allCases.map(\.rawValue)),
                "operation": enumStringSchema(IntentOperation.allCases.map(\.rawValue)),
                "target_reference": enumStringSchema(IntentTargetReference.allCases.map(\.rawValue)),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "maxLength": .integer(maximumTitleCharacters),
                        ]),
                        "items": .object([
                            "type": .string("array"),
                            "maxItems": .integer(maximumItems),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .integer(maximumItemCharacters),
                            ]),
                        ]),
                    ]),
                    "required": .array([]),
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

    private static func enumStringSchema(_ values: [String]) -> ToolJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(ToolJSONValue.string)),
        ])
    }

    private static func validateParameterValues(_ parameters: IntentParameters) throws {
        if let title = parameters.title {
            try validateBoundedText(
                title,
                path: "$.parameters.title",
                maximumCharacters: maximumTitleCharacters
            )
        }
        if let items = parameters.items {
            guard !items.isEmpty else {
                throw IntentProposalValidationError.emptyValue(path: "$.parameters.items")
            }
            guard items.count <= maximumItems else {
                throw IntentProposalValidationError.tooManyItems(maximum: maximumItems)
            }
            var combinedCharacters = 0
            for (index, item) in items.enumerated() {
                let path = "$.parameters.items[\(index)]"
                try validateBoundedText(
                    item,
                    path: path,
                    maximumCharacters: maximumItemCharacters
                )
                combinedCharacters += item.count
            }
            guard combinedCharacters <= maximumCombinedItemCharacters else {
                throw IntentProposalValidationError.valueTooLong(
                    path: "$.parameters.items",
                    maximumCharacters: maximumCombinedItemCharacters
                )
            }
        }
    }

    private static func validateCombination(
        operation: IntentOperation,
        targetReference: IntentTargetReference,
        parameters: IntentParameters
    ) throws {
        let compatible: Bool
        switch operation {
        case .notesOpenApplication:
            compatible = targetReference == .notesApplication
                && parameters.title == nil
                && parameters.items == nil
        case .notesCreate:
            compatible = targetReference == .newNote
                && parameters.items == nil
        case .notesSetTitle:
            compatible = targetReference == .activeNote
                && parameters.title != nil
                && parameters.items == nil
        case .notesAddItems, .notesRemoveItems:
            compatible = targetReference == .activeNote
                && parameters.title == nil
                && parameters.items != nil
        case .notesOpen:
            compatible = targetReference == .activeNote
                && parameters.title == nil
                && parameters.items == nil
        }
        guard compatible else {
            throw IntentProposalValidationError.incompatibleFields(operation: operation)
        }
    }

    private static func validateBoundedText(
        _ value: String,
        path: String,
        maximumCharacters: Int
    ) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw IntentProposalValidationError.emptyValue(path: path)
        }
        guard value.count <= maximumCharacters else {
            throw IntentProposalValidationError.valueTooLong(
                path: path,
                maximumCharacters: maximumCharacters
            )
        }
        guard value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw IntentProposalValidationError.unsupportedControlCharacter(path: path)
        }
    }

    private static func rejectUnknownKeys(
        in object: [String: ToolJSONValue],
        allowed: Set<String>,
        path: String
    ) throws {
        if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw IntentProposalValidationError.unknownField(path: path, field: unknown)
        }
    }

    private static func requiredString(
        _ key: String,
        in object: [String: ToolJSONValue],
        path: String
    ) throws -> String {
        guard let value = object[key] else {
            throw IntentProposalValidationError.missingField(key)
        }
        guard case .string(let string) = value else {
            throw IntentProposalValidationError.invalidType(path: path)
        }
        guard !string.isEmpty else {
            throw IntentProposalValidationError.emptyValue(path: path)
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
            throw IntentProposalValidationError.invalidType(path: path)
        }
        return string
    }

    private static func optionalStringArray(
        _ key: String,
        in object: [String: ToolJSONValue],
        path: String
    ) throws -> [String]? {
        guard let value = object[key] else { return nil }
        guard case .array(let values) = value else {
            throw IntentProposalValidationError.invalidType(path: path)
        }
        return try values.enumerated().map { index, value in
            guard case .string(let string) = value else {
                throw IntentProposalValidationError.invalidType(
                    path: "\(path)[\(index)]"
                )
            }
            return string
        }
    }
}
