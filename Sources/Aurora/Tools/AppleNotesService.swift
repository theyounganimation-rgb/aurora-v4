import AppKit
import Foundation

/// The semantic Notes effects available to Aurora's capability broker.
/// Natural-language interpretation deliberately does not live in this layer.
public enum AppleNotesServiceOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case createBlank = "create_blank"
    case setTitle = "set_title"
    case addItems = "add_items"
    case removeItems = "remove_items"
    case open
}

/// A typed, already-authorized Notes request. The request identifier is local
/// authorization state, not a model-supplied permission flag. Retrying the
/// same request identifier is idempotent for this Aurora process.
public enum AppleNotesServiceRequest: Sendable, Equatable {
    case createBlank(requestID: String)
    case setTitle(requestID: String, noteID: String, title: String)
    case addItems(requestID: String, noteID: String, items: [String])
    case removeItems(requestID: String, noteID: String, items: [String])
    case open(requestID: String, noteID: String)

    public var requestID: String {
        switch self {
        case .createBlank(let requestID),
             .setTitle(let requestID, _, _),
             .addItems(let requestID, _, _),
             .removeItems(let requestID, _, _),
             .open(let requestID, _):
            return requestID
        }
    }

    public var operation: AppleNotesServiceOperation {
        switch self {
        case .createBlank: return .createBlank
        case .setTitle: return .setTitle
        case .addItems: return .addItems
        case .removeItems: return .removeItems
        case .open: return .open
        }
    }
}

/// A receipt is emitted only after Notes has been read back and the requested
/// postcondition has been observed. Raw note HTML and plaintext never cross
/// this boundary into Realtime or the audit journal.
public struct AppleNotesServiceReceipt: Codable, Sendable, Equatable {
    public let requestID: String
    public let operation: AppleNotesServiceOperation
    public let noteID: String
    public let title: String?
    public let itemCount: Int
    public let affectedItemCount: Int
    public let selectedAndVisible: Bool
    public let verified: Bool

    public init(
        requestID: String,
        operation: AppleNotesServiceOperation,
        noteID: String,
        title: String?,
        itemCount: Int,
        affectedItemCount: Int,
        selectedAndVisible: Bool,
        verified: Bool
    ) {
        self.requestID = requestID
        self.operation = operation
        self.noteID = noteID
        self.title = title
        self.itemCount = max(0, itemCount)
        self.affectedItemCount = max(0, affectedItemCount)
        self.selectedAndVisible = selectedAndVisible
        self.verified = verified
    }
}

public protocol AppleNotesServicing: Sendable {
    func perform(_ request: AppleNotesServiceRequest) async throws -> AppleNotesServiceReceipt
}

public enum AppleNotesServiceError: LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case idempotencyConflict
    case scriptCompilationFailed
    case automationPermissionDenied
    case scriptExecutionFailed(number: Int?)
    case outputTooLarge
    case malformedResponse
    case defaultAccountUnavailable
    case defaultFolderUnavailable
    case noteNotFound
    case ambiguousNoteIdentifier
    case noteNotManaged
    case passwordProtected
    case staleTarget
    case executionFailed
    case verificationFailed
    case visibilityVerificationFailed

    public var resultCode: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .idempotencyConflict: return "idempotency_conflict"
        case .scriptCompilationFailed: return "script_compilation_failed"
        case .automationPermissionDenied: return "automation_permission_denied"
        case .scriptExecutionFailed: return "script_execution_failed"
        case .outputTooLarge: return "output_too_large"
        case .malformedResponse: return "malformed_response"
        case .defaultAccountUnavailable: return "default_account_unavailable"
        case .defaultFolderUnavailable: return "default_folder_unavailable"
        case .noteNotFound: return "note_not_found"
        case .ambiguousNoteIdentifier: return "ambiguous_note_identifier"
        case .noteNotManaged: return "note_not_managed"
        case .passwordProtected: return "password_protected"
        case .staleTarget: return "target_stale"
        case .executionFailed: return "execution_failed"
        case .verificationFailed: return "verification_failed"
        case .visibilityVerificationFailed: return "visibility_verification_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field):
            return "The Apple Notes \(field) was not valid."
        case .idempotencyConflict:
            return "That Notes request identifier was already used for a different effect."
        case .scriptCompilationFailed:
            return "Aurora's built-in Apple Notes bridge could not be prepared."
        case .automationPermissionDenied:
            return "macOS has not allowed Aurora to automate Apple Notes."
        case .scriptExecutionFailed:
            return "Apple Notes could not execute that operation."
        case .outputTooLarge:
            return "Apple Notes returned more data than Aurora can safely verify."
        case .malformedResponse:
            return "Apple Notes returned a response Aurora could not verify."
        case .defaultAccountUnavailable:
            return "Apple Notes has no default account available for a new note."
        case .defaultFolderUnavailable:
            return "Apple Notes has no default folder available for a new note."
        case .noteNotFound:
            return "The Apple Note Aurora was working with no longer exists."
        case .ambiguousNoteIdentifier:
            return "Apple Notes returned more than one note for the saved identifier."
        case .noteNotManaged:
            return "Aurora no longer has the verified state needed to change that note safely."
        case .passwordProtected:
            return "Aurora cannot change a password-protected Apple Note through this route."
        case .staleTarget:
            return "That Apple Note changed after Aurora last verified it."
        case .executionFailed:
            return "Apple Notes could not complete that operation."
        case .verificationFailed:
            return "Aurora could not verify whether Apple Notes reached the requested result."
        case .visibilityVerificationFailed:
            return "Aurora found the note but could not verify that Apple Notes visibly opened it."
        }
    }
}

public enum AppleNotesScriptOperation: String, Sendable, Equatable, CaseIterable {
    case create
    case read
    case replace
    case open
}

/// User-controlled note IDs, titles, and content are carried only in this
/// Apple-event argument vector. `source` is selected exclusively from fixed
/// constants in `AppleNotesStaticScripts`.
public struct AppleNotesScriptInvocation: Sendable, Equatable {
    public let operation: AppleNotesScriptOperation
    public let source: String
    public let arguments: [String]

    public init(operation: AppleNotesScriptOperation, source: String, arguments: [String]) {
        self.operation = operation
        self.source = source
        self.arguments = arguments
    }
}

public struct AppleNotesScriptOutput: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Injectable AppleScript execution seam. The live runner creates and
/// compiles a fresh fixed script for every invocation, then passes arguments
/// in an Apple-event list rather than interpolating them into source text.
public struct AppleNotesScriptRunner: Sendable {
    public typealias Implementation = @Sendable (
        _ invocation: AppleNotesScriptInvocation,
        _ maximumOutputBytes: Int
    ) async throws -> AppleNotesScriptOutput

    private let implementation: Implementation

    public init(_ implementation: @escaping Implementation) {
        self.implementation = implementation
    }

    public func run(
        _ invocation: AppleNotesScriptInvocation,
        maximumOutputBytes: Int
    ) async throws -> AppleNotesScriptOutput {
        try await implementation(invocation, maximumOutputBytes)
    }

    public static let live = AppleNotesScriptRunner { invocation, maximumOutputBytes in
        try await Task.detached(priority: .userInitiated) {
            try executeLive(invocation, maximumOutputBytes: maximumOutputBytes)
        }.value
    }

    private static func executeLive(
        _ invocation: AppleNotesScriptInvocation,
        maximumOutputBytes: Int
    ) throws -> AppleNotesScriptOutput {
        try autoreleasepool {
            guard let script = NSAppleScript(source: invocation.source) else {
                throw AppleNotesServiceError.scriptCompilationFailed
            }
            var compilationError: NSDictionary?
            guard script.compileAndReturnError(&compilationError) else {
                throw AppleNotesServiceError.scriptCompilationFailed
            }

            // aevt/oapp with the direct-object list invokes `on run argv`
            // without exposing arguments in the process list or script source.
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(0x6165_7674),
                eventID: AEEventID(0x6f61_7070),
                targetDescriptor: nil,
                returnID: AEReturnID(-1),
                transactionID: AETransactionID(0)
            )
            let argumentList = NSAppleEventDescriptor.list()
            for (offset, argument) in invocation.arguments.enumerated() {
                argumentList.insert(NSAppleEventDescriptor(string: argument), at: offset + 1)
            }
            event.setParam(argumentList, forKeyword: AEKeyword(0x2d2d_2d2d))

            var executionError: NSDictionary?
            let descriptor = script.executeAppleEvent(event, error: &executionError)
            if executionError != nil {
                let number = (executionError?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
                    ?? (executionError?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                if number == -1_743 {
                    throw AppleNotesServiceError.automationPermissionDenied
                }
                throw AppleNotesServiceError.scriptExecutionFailed(number: number)
            }
            let output = descriptor.stringValue ?? ""
            guard output.utf8.count <= maximumOutputBytes else {
                throw AppleNotesServiceError.outputTooLarge
            }
            return AppleNotesScriptOutput(text: output)
        }
    }
}

/// Separate from script output so tests can prove that a claimed open is not
/// accepted merely because Notes returned from `show`. The live verifier waits
/// for the signed Notes application to become the visible frontmost app.
public struct AppleNotesVisibilityVerifier: Sendable {
    public typealias Implementation = @Sendable (_ noteID: String) async -> Bool

    private let implementation: Implementation

    public init(_ implementation: @escaping Implementation) {
        self.implementation = implementation
    }

    public func verify(noteID: String) async -> Bool {
        await implementation(noteID)
    }

    public static let live = AppleNotesVisibilityVerifier { _ in
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if Task.isCancelled { return false }
            let visible = await MainActor.run {
                guard let frontmost = NSWorkspace.shared.frontmostApplication,
                      frontmost.bundleIdentifier == AppleNotesService.notesBundleIdentifier,
                      frontmost.isActive,
                      !frontmost.isHidden else {
                    return false
                }
                return true
            }
            if visible { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return false
    }
}

/// Direct, typed Apple Notes access for notes created during the current
/// Aurora process. The actor retains the exact last observed plaintext for
/// each created note so a human edit becomes a stale-target result rather than
/// being overwritten.
public actor AppleNotesService: AppleNotesServicing {
    public nonisolated static let notesBundleIdentifier = "com.apple.Notes"
    public nonisolated static let maximumRequestIDCharacters = 160
    public nonisolated static let maximumNoteIDCharacters = 2_048
    public nonisolated static let maximumTitleCharacters = 500
    public nonisolated static let maximumItemCharacters = 500
    public nonisolated static let maximumItems = 100
    public nonisolated static let maximumOutputBytes = 256 * 1_024
    public nonisolated static let maximumCachedOutcomes = 128

    private struct ManagedNote: Sendable, Equatable {
        var title: String?
        var items: [String]
        var exactPlaintext: String
    }

    private enum CachedOutcome: Sendable, Equatable {
        case success(AppleNotesServiceReceipt)
        case failure(AppleNotesServiceError)
    }

    private struct CacheEntry: Sendable, Equatable {
        let request: AppleNotesServiceRequest
        let outcome: CachedOutcome
    }

    private struct ScriptResponse: Decodable {
        let ok: Bool
        let error: String?
        let id: String?
        let name: String?
        let plaintext: String?
        let folderID: String?
        let selected: Bool?

        private enum CodingKeys: String, CodingKey {
            case ok, error, id, name, plaintext, selected
            case folderID = "folder_id"
        }
    }

    private let runner: AppleNotesScriptRunner
    private let visibilityVerifier: AppleNotesVisibilityVerifier
    private var managedNotes: [String: ManagedNote] = [:]
    private var outcomesByRequestID: [String: CacheEntry] = [:]
    private var outcomeOrder: [String] = []

    public init(
        runner: AppleNotesScriptRunner = .live,
        visibilityVerifier: AppleNotesVisibilityVerifier = .live
    ) {
        self.runner = runner
        self.visibilityVerifier = visibilityVerifier
    }

    public func perform(
        _ request: AppleNotesServiceRequest
    ) async throws -> AppleNotesServiceReceipt {
        let request = try Self.validated(request)
        if let cached = try cachedOutcome(for: request) {
            return try Self.resolve(cached)
        }

        do {
            let receipt: AppleNotesServiceReceipt
            switch request {
            case .createBlank(let requestID):
                receipt = try await createBlank(requestID: requestID)
            case .setTitle(let requestID, let noteID, let title):
                receipt = try await setTitle(requestID: requestID, noteID: noteID, title: title)
            case .addItems(let requestID, let noteID, let items):
                receipt = try await addItems(requestID: requestID, noteID: noteID, items: items)
            case .removeItems(let requestID, let noteID, let items):
                receipt = try await removeItems(requestID: requestID, noteID: noteID, items: items)
            case .open(let requestID, let noteID):
                receipt = try await open(requestID: requestID, noteID: noteID)
            }
            remember(.success(receipt), for: request)
            return receipt
        } catch let error as AppleNotesServiceError {
            // A script error can occur after Notes accepted a mutation. Cache
            // the failure so transport retries cannot duplicate that effect.
            remember(.failure(error), for: request)
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = AppleNotesServiceError.executionFailed
            remember(.failure(failure), for: request)
            throw failure
        }
    }

    /// Compiles every fixed script without sending an Apple event or opening
    /// Notes. Verifiers can call this safely on a developer machine.
    public nonisolated static func validateStaticScripts() throws {
        for operation in AppleNotesScriptOperation.allCases {
            guard let script = NSAppleScript(source: AppleNotesStaticScripts.source(for: operation)) else {
                throw AppleNotesServiceError.scriptCompilationFailed
            }
            var error: NSDictionary?
            guard script.compileAndReturnError(&error) else {
                throw AppleNotesServiceError.scriptCompilationFailed
            }
        }
    }

    private func createBlank(requestID: String) async throws -> AppleNotesServiceReceipt {
        let response = try await performScript(
            operation: .create,
            arguments: ["<div><br></div>"]
        )
        try Self.validateSuccess(response)
        guard let noteID = try Self.validIdentifier(response.id, field: "note identifier"),
              try Self.validIdentifier(response.folderID, field: "folder identifier") != nil,
              let plaintext = response.plaintext,
              Self.normalizedLines(plaintext).isEmpty else {
            throw AppleNotesServiceError.verificationFailed
        }
        managedNotes[noteID] = ManagedNote(title: nil, items: [], exactPlaintext: plaintext)
        return AppleNotesServiceReceipt(
            requestID: requestID,
            operation: .createBlank,
            noteID: noteID,
            title: nil,
            itemCount: 0,
            affectedItemCount: 1,
            selectedAndVisible: false,
            verified: true
        )
    }

    private func setTitle(
        requestID: String,
        noteID: String,
        title: String
    ) async throws -> AppleNotesServiceReceipt {
        guard var managed = managedNotes[noteID] else {
            throw AppleNotesServiceError.noteNotManaged
        }
        try await verifyTargetStillMatches(noteID: noteID, managed: managed)
        let desired = ManagedNote(
            title: title,
            items: managed.items,
            exactPlaintext: managed.exactPlaintext
        )
        managed = try await replace(noteID: noteID, previous: managed, desired: desired)
        managedNotes[noteID] = managed
        return AppleNotesServiceReceipt(
            requestID: requestID,
            operation: .setTitle,
            noteID: noteID,
            title: title,
            itemCount: managed.items.count,
            affectedItemCount: 1,
            selectedAndVisible: false,
            verified: true
        )
    }

    private func addItems(
        requestID: String,
        noteID: String,
        items: [String]
    ) async throws -> AppleNotesServiceReceipt {
        guard var managed = managedNotes[noteID] else {
            throw AppleNotesServiceError.noteNotManaged
        }
        try await verifyTargetStillMatches(noteID: noteID, managed: managed)
        let desired = ManagedNote(
            title: managed.title,
            items: managed.items + items,
            exactPlaintext: managed.exactPlaintext
        )
        managed = try await replace(noteID: noteID, previous: managed, desired: desired)
        managedNotes[noteID] = managed
        return AppleNotesServiceReceipt(
            requestID: requestID,
            operation: .addItems,
            noteID: noteID,
            title: managed.title,
            itemCount: managed.items.count,
            affectedItemCount: items.count,
            selectedAndVisible: false,
            verified: true
        )
    }

    private func removeItems(
        requestID: String,
        noteID: String,
        items: [String]
    ) async throws -> AppleNotesServiceReceipt {
        guard var managed = managedNotes[noteID] else {
            throw AppleNotesServiceError.noteNotManaged
        }
        try await verifyTargetStillMatches(noteID: noteID, managed: managed)
        let removalKeys = Set(items.map(Self.itemComparisonKey))
        let retained = managed.items.filter {
            !removalKeys.contains(Self.itemComparisonKey($0))
        }
        let removedCount = managed.items.count - retained.count
        if removedCount > 0 {
            let desired = ManagedNote(
                title: managed.title,
                items: retained,
                exactPlaintext: managed.exactPlaintext
            )
            managed = try await replace(noteID: noteID, previous: managed, desired: desired)
            managedNotes[noteID] = managed
        }
        return AppleNotesServiceReceipt(
            requestID: requestID,
            operation: .removeItems,
            noteID: noteID,
            title: managed.title,
            itemCount: managed.items.count,
            affectedItemCount: removedCount,
            selectedAndVisible: false,
            verified: true
        )
    }

    private func open(
        requestID: String,
        noteID: String
    ) async throws -> AppleNotesServiceReceipt {
        guard let managed = managedNotes[noteID] else {
            throw AppleNotesServiceError.noteNotManaged
        }
        let response = try await performScript(operation: .open, arguments: [noteID])
        try Self.validateSuccess(response)
        guard response.id == noteID, response.selected == true else {
            throw AppleNotesServiceError.verificationFailed
        }
        guard await visibilityVerifier.verify(noteID: noteID) else {
            throw AppleNotesServiceError.visibilityVerificationFailed
        }
        return AppleNotesServiceReceipt(
            requestID: requestID,
            operation: .open,
            noteID: noteID,
            title: managed.title,
            itemCount: managed.items.count,
            affectedItemCount: 0,
            selectedAndVisible: true,
            verified: true
        )
    }

    private func verifyTargetStillMatches(
        noteID: String,
        managed: ManagedNote
    ) async throws {
        let response = try await performScript(operation: .read, arguments: [noteID])
        try Self.validateSuccess(response)
        guard response.id == noteID, let plaintext = response.plaintext else {
            throw AppleNotesServiceError.verificationFailed
        }
        guard plaintext == managed.exactPlaintext else {
            throw AppleNotesServiceError.staleTarget
        }
        if let expectedTitle = managed.title, response.name != expectedTitle {
            throw AppleNotesServiceError.staleTarget
        }
    }

    private func replace(
        noteID: String,
        previous: ManagedNote,
        desired: ManagedNote
    ) async throws -> ManagedNote {
        let desiredHTML = try Self.canonicalHTML(title: desired.title, items: desired.items)
        let response = try await performScript(
            operation: .replace,
            arguments: [
                noteID,
                previous.exactPlaintext,
                desiredHTML,
                desired.title ?? "",
            ]
        )
        try Self.validateSuccess(response)
        guard response.id == noteID, let plaintext = response.plaintext else {
            throw AppleNotesServiceError.verificationFailed
        }
        if let title = desired.title, response.name != title {
            throw AppleNotesServiceError.verificationFailed
        }
        guard Self.normalizedLines(plaintext) == Self.expectedLines(for: desired) else {
            throw AppleNotesServiceError.verificationFailed
        }
        return ManagedNote(
            title: desired.title,
            items: desired.items,
            exactPlaintext: plaintext
        )
    }

    private func performScript(
        operation: AppleNotesScriptOperation,
        arguments: [String]
    ) async throws -> ScriptResponse {
        try Task.checkCancellation()
        let invocation = AppleNotesScriptInvocation(
            operation: operation,
            source: AppleNotesStaticScripts.source(for: operation),
            arguments: arguments
        )
        let output = try await runner.run(invocation, maximumOutputBytes: Self.maximumOutputBytes)
        guard output.text.utf8.count <= Self.maximumOutputBytes,
              let data = output.text.data(using: .utf8) else {
            throw AppleNotesServiceError.outputTooLarge
        }
        do {
            return try JSONDecoder().decode(ScriptResponse.self, from: data)
        } catch {
            throw AppleNotesServiceError.malformedResponse
        }
    }

    private static func validateSuccess(_ response: ScriptResponse) throws {
        guard response.ok else {
            switch response.error {
            case "default_account_unavailable": throw AppleNotesServiceError.defaultAccountUnavailable
            case "default_folder_unavailable": throw AppleNotesServiceError.defaultFolderUnavailable
            case "note_not_found": throw AppleNotesServiceError.noteNotFound
            case "ambiguous_note_identifier": throw AppleNotesServiceError.ambiguousNoteIdentifier
            case "password_protected": throw AppleNotesServiceError.passwordProtected
            case "stale_target": throw AppleNotesServiceError.staleTarget
            case "verification_failed": throw AppleNotesServiceError.verificationFailed
            default: throw AppleNotesServiceError.executionFailed
            }
        }
    }

    private func cachedOutcome(
        for request: AppleNotesServiceRequest
    ) throws -> CachedOutcome? {
        guard let entry = outcomesByRequestID[request.requestID] else { return nil }
        guard entry.request == request else {
            throw AppleNotesServiceError.idempotencyConflict
        }
        return entry.outcome
    }

    private static func resolve(
        _ outcome: CachedOutcome
    ) throws -> AppleNotesServiceReceipt {
        switch outcome {
        case .success(let receipt): return receipt
        case .failure(let error): throw error
        }
    }

    private func remember(
        _ outcome: CachedOutcome,
        for request: AppleNotesServiceRequest
    ) {
        if outcomesByRequestID[request.requestID] == nil {
            outcomeOrder.append(request.requestID)
        }
        outcomesByRequestID[request.requestID] = CacheEntry(request: request, outcome: outcome)
        while outcomeOrder.count > Self.maximumCachedOutcomes {
            let oldest = outcomeOrder.removeFirst()
            outcomesByRequestID.removeValue(forKey: oldest)
        }
    }

    private static func validated(
        _ request: AppleNotesServiceRequest
    ) throws -> AppleNotesServiceRequest {
        let requestID = try validSingleLine(
            request.requestID,
            field: "request identifier",
            maximumCharacters: maximumRequestIDCharacters
        )
        switch request {
        case .createBlank:
            return .createBlank(requestID: requestID)
        case .setTitle(_, let noteID, let title):
            return .setTitle(
                requestID: requestID,
                noteID: try validNoteID(noteID),
                title: try validSingleLine(
                    title,
                    field: "title",
                    maximumCharacters: maximumTitleCharacters
                )
            )
        case .addItems(_, let noteID, let items):
            return .addItems(
                requestID: requestID,
                noteID: try validNoteID(noteID),
                items: try validItems(items)
            )
        case .removeItems(_, let noteID, let items):
            return .removeItems(
                requestID: requestID,
                noteID: try validNoteID(noteID),
                items: try validItems(items)
            )
        case .open(_, let noteID):
            return .open(requestID: requestID, noteID: try validNoteID(noteID))
        }
    }

    private static func validNoteID(_ value: String) throws -> String {
        try validSingleLine(
            value,
            field: "note identifier",
            maximumCharacters: maximumNoteIDCharacters
        )
    }

    private static func validItems(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.count <= maximumItems else {
            throw AppleNotesServiceError.invalidRequest("items")
        }
        return try values.map {
            try validSingleLine(
                $0,
                field: "item",
                maximumCharacters: maximumItemCharacters
            )
        }
    }

    private static func validSingleLine(
        _ value: String,
        field: String,
        maximumCharacters: Int
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.count <= maximumCharacters,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("\u{2028}"),
              !value.contains("\u{2029}") else {
            throw AppleNotesServiceError.invalidRequest(field)
        }
        return value
    }

    private static func validIdentifier(
        _ value: String?,
        field: String
    ) throws -> String? {
        guard let value else { return nil }
        return try validSingleLine(
            value,
            field: field,
            maximumCharacters: maximumNoteIDCharacters
        )
    }

    private static func canonicalHTML(
        title: String?,
        items: [String]
    ) throws -> String {
        let lines = (title.map { [$0] } ?? []) + items
        if lines.isEmpty { return "<div><br></div>" }
        let html = lines.map { "<div>\(htmlEscaped($0))</div>" }.joined()
        guard html.utf8.count <= maximumOutputBytes else {
            throw AppleNotesServiceError.invalidRequest("content")
        }
        return html
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func expectedLines(for note: ManagedNote) -> [String] {
        (note.title.map { [$0] } ?? []) + note.items
    }

    private static func normalizedLines(_ value: String) -> [String] {
        value.split(whereSeparator: \Character.isNewline).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func itemComparisonKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

private enum AppleNotesStaticScripts {
    static func source(for operation: AppleNotesScriptOperation) -> String {
        commonHandlers + "\n" + operationBody(for: operation)
    }

    private static func operationBody(for operation: AppleNotesScriptOperation) -> String {
        switch operation {
        case .create: return create
        case .read: return read
        case .replace: return replace
        case .open: return open
        }
    }

    private static let commonHandlers = #"""
on jsonEscape(valueText)
    set sourceText to valueText as text
    set outputText to ""
    repeat with characterReference in characters of sourceText
        set characterText to characterReference as text
        if characterText is quote then
            set outputText to outputText & "\\\""
        else if characterText is "\\" then
            set outputText to outputText & "\\\\"
        else if characterText is return then
            set outputText to outputText & "\\n"
        else if characterText is linefeed then
            set outputText to outputText & "\\n"
        else if characterText is tab then
            set outputText to outputText & "\\t"
        else
            try
                set codeValue to ASCII number characterText
                if codeValue < 32 then
                    set outputText to outputText & " "
                else
                    set outputText to outputText & characterText
                end if
            on error
                set outputText to outputText & characterText
            end try
        end if
    end repeat
    return outputText
end jsonEscape

on jsonString(valueText)
    return quote & my jsonEscape(valueText) & quote
end jsonString

on booleanJSON(booleanValue)
    if booleanValue then return "true"
    return "false"
end booleanJSON

on containsText(textValues, targetText)
    repeat with valueReference in textValues
        if (valueReference as text) is targetText then return true
    end repeat
    return false
end containsText

on noteJSON(noteReference, folderIdentifier, selectedValue)
    tell application "Notes"
        set noteIdentifier to id of noteReference as text
        set noteName to ""
        set notePlaintext to ""
        try
            set noteName to name of noteReference as text
        end try
        try
            set notePlaintext to plaintext of noteReference as text
        end try
    end tell
    return "{\"ok\":true,\"id\":" & my jsonString(noteIdentifier) & ",\"name\":" & my jsonString(noteName) & ",\"plaintext\":" & my jsonString(notePlaintext) & ",\"folder_id\":" & my jsonString(folderIdentifier) & ",\"selected\":" & my booleanJSON(selectedValue) & "}"
end noteJSON
"""#

    private static let create = #"""
on run argv
    if (count of argv) is not 1 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set initialBody to item 1 of argv as text
    with timeout of 8 seconds
      tell application "Notes"
        try
            set accountReference to default account
        on error
            return "{\"ok\":false,\"error\":\"default_account_unavailable\"}"
        end try
        if accountReference is missing value then return "{\"ok\":false,\"error\":\"default_account_unavailable\"}"
        try
            set folderReference to default folder of accountReference
        on error
            return "{\"ok\":false,\"error\":\"default_folder_unavailable\"}"
        end try
        if folderReference is missing value then return "{\"ok\":false,\"error\":\"default_folder_unavailable\"}"
        try
            set createdNote to make new note at folderReference with properties {body:initialBody}
            set noteIdentifier to id of createdNote as text
            set folderIdentifier to id of folderReference as text
        on error
            return "{\"ok\":false,\"error\":\"execution_failed\"}"
        end try
        repeat 20 times
            try
                set foundNotes to every note of folderReference whose id is noteIdentifier
                if (count of foundNotes) is 1 then
                    return my noteJSON(item 1 of foundNotes, folderIdentifier, false)
                end if
            end try
            delay 0.05
        end repeat
      end tell
      return "{\"ok\":false,\"error\":\"verification_failed\"}"
    end timeout
end run
"""#

    private static let read = #"""
on run argv
    if (count of argv) is not 1 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set noteIdentifier to item 1 of argv as text
    with timeout of 8 seconds
      tell application "Notes"
        set foundNotes to every note whose id is noteIdentifier
        if (count of foundNotes) is 0 then return "{\"ok\":false,\"error\":\"note_not_found\"}"
        if (count of foundNotes) is not 1 then return "{\"ok\":false,\"error\":\"ambiguous_note_identifier\"}"
        set targetNote to item 1 of foundNotes
        try
            if password protected of targetNote then return "{\"ok\":false,\"error\":\"password_protected\"}"
        end try
        set folderIdentifier to id of container of targetNote as text
        return my noteJSON(targetNote, folderIdentifier, false)
      end tell
    end timeout
end run
"""#

    private static let replace = #"""
on run argv
    if (count of argv) is not 4 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set noteIdentifier to item 1 of argv as text
    set expectedPlaintext to item 2 of argv as text
    set replacementHTML to item 3 of argv as text
    set expectedTitle to item 4 of argv as text
    with timeout of 8 seconds
      tell application "Notes"
        set foundNotes to every note whose id is noteIdentifier
        if (count of foundNotes) is 0 then return "{\"ok\":false,\"error\":\"note_not_found\"}"
        if (count of foundNotes) is not 1 then return "{\"ok\":false,\"error\":\"ambiguous_note_identifier\"}"
        set targetNote to item 1 of foundNotes
        try
            if password protected of targetNote then return "{\"ok\":false,\"error\":\"password_protected\"}"
        end try
        set currentPlaintext to plaintext of targetNote as text
        if currentPlaintext is not expectedPlaintext then return "{\"ok\":false,\"error\":\"stale_target\"}"
        try
            set body of targetNote to replacementHTML
            if expectedTitle is not "" then set name of targetNote to expectedTitle
        on error
            return "{\"ok\":false,\"error\":\"execution_failed\"}"
        end try
        set folderIdentifier to id of container of targetNote as text
        repeat 20 times
            try
                set verifiedNotes to every note whose id is noteIdentifier
                if (count of verifiedNotes) is 1 then
                    set verifiedNote to item 1 of verifiedNotes
                    set verifiedName to name of verifiedNote as text
                    if expectedTitle is "" or verifiedName is expectedTitle then
                        return my noteJSON(verifiedNote, folderIdentifier, false)
                    end if
                end if
            end try
            delay 0.05
        end repeat
      end tell
      return "{\"ok\":false,\"error\":\"verification_failed\"}"
    end timeout
end run
"""#

    private static let open = #"""
on run argv
    if (count of argv) is not 1 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set noteIdentifier to item 1 of argv as text
    with timeout of 8 seconds
      tell application "Notes"
        set foundNotes to every note whose id is noteIdentifier
        if (count of foundNotes) is 0 then return "{\"ok\":false,\"error\":\"note_not_found\"}"
        if (count of foundNotes) is not 1 then return "{\"ok\":false,\"error\":\"ambiguous_note_identifier\"}"
        set targetNote to item 1 of foundNotes
        set folderIdentifier to id of container of targetNote as text
        activate
        show targetNote
        repeat 20 times
            set selectedIDs to {}
            try
                set selectedIDs to id of every note of selection
            end try
            if my containsText(selectedIDs, noteIdentifier) then
                return my noteJSON(targetNote, folderIdentifier, true)
            end if
            delay 0.05
        end repeat
      end tell
      return "{\"ok\":false,\"error\":\"verification_failed\"}"
    end timeout
end run
"""#
}
