import Foundation

/// The narrow set of supported Mail.app operations. Keeping the operation in
/// the invocation lets tests verify that no user-controlled value was ever
/// inserted into AppleScript source.
public enum AppleMailScriptOperation: String, Sendable, Equatable, CaseIterable {
    case accountStatus = "account_status"
    case search
    case read
    case createDraft = "create_draft"
    case sendDraft = "send_draft"
}

/// A static AppleScript plus a separate Apple-event argument vector.
///
/// `source` is selected only from constants in `AppleMailStaticScripts`.
/// Account identifiers, queries, message text, and recipient addresses belong
/// exclusively in `arguments`; they are never interpolated into source code.
public struct AppleMailScriptInvocation: Sendable, Equatable {
    public let operation: AppleMailScriptOperation
    public let source: String
    public let arguments: [String]

    public init(operation: AppleMailScriptOperation, source: String, arguments: [String]) {
        self.operation = operation
        self.source = source
        self.arguments = arguments
    }
}

public struct AppleMailScriptOutput: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum AppleMailServiceError: LocalizedError, Sendable, Equatable {
    case invalidArgument(String)
    case scriptCompilationFailed
    case automationPermissionDenied
    case scriptExecutionFailed(number: Int?)
    case outputTooLarge
    case malformedResponse
    case providerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let field):
            return "The Outlook \(field) was not valid."
        case .scriptCompilationFailed:
            return "Aurora's built-in Apple Mail bridge could not be prepared."
        case .automationPermissionDenied:
            return "Aurora needs permission to control Mail before she can use the connected Outlook account."
        case .scriptExecutionFailed:
            return "Apple Mail could not complete that Outlook request."
        case .outputTooLarge:
            return "Apple Mail returned more data than Aurora can safely accept."
        case .malformedResponse:
            return "Apple Mail returned a response Aurora could not safely read."
        case .providerFailure(let reason):
            switch reason {
            case "account_not_found":
                return "That Outlook account is no longer available in Apple Mail."
            case "inbox_not_found":
                return "Apple Mail could not find that Outlook account's inbox."
            case "message_not_found":
                return "That Outlook message is no longer available."
            case "draft_not_found":
                return "That Outlook draft is no longer open in Apple Mail."
            case "draft_account_mismatch":
                return "That draft does not belong to the selected Outlook account."
            case "no_sender_address":
                return "The selected Outlook account has no sending address in Apple Mail."
            case "send_failed":
                return "Apple Mail could not send that Outlook draft."
            default:
                return "Apple Mail could not complete that Outlook request."
            }
        }
    }
}

/// Injectable runner for deterministic tests. The live implementation creates
/// a fresh NSAppleScript inside a detached task, compiles the fixed source, and
/// invokes its `run` handler with an Apple-event list descriptor.
public struct AppleMailScriptRunner: Sendable {
    public typealias Implementation = @Sendable (
        _ invocation: AppleMailScriptInvocation,
        _ maximumOutputBytes: Int
    ) async throws -> AppleMailScriptOutput

    private let implementation: Implementation

    public init(_ implementation: @escaping Implementation) {
        self.implementation = implementation
    }

    public func run(
        _ invocation: AppleMailScriptInvocation,
        maximumOutputBytes: Int
    ) async throws -> AppleMailScriptOutput {
        try await implementation(invocation, maximumOutputBytes)
    }

    public static let live = AppleMailScriptRunner { invocation, maximumOutputBytes in
        try await Task.detached(priority: .userInitiated) {
            try executeLive(invocation, maximumOutputBytes: maximumOutputBytes)
        }.value
    }

    private static func executeLive(
        _ invocation: AppleMailScriptInvocation,
        maximumOutputBytes: Int
    ) throws -> AppleMailScriptOutput {
        try autoreleasepool {
            guard let script = NSAppleScript(source: invocation.source) else {
                throw AppleMailServiceError.scriptCompilationFailed
            }

            var compilationError: NSDictionary?
            guard script.compileAndReturnError(&compilationError) else {
                throw AppleMailServiceError.scriptCompilationFailed
            }

            // These are the four-character Apple-event codes for aevt/oapp
            // and the direct-object keyword (----). Numeric constants avoid a
            // Carbon dependency while preserving the canonical `run argv`
            // invocation used by osascript.
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
                if number == -1_743 {
                    throw AppleMailServiceError.automationPermissionDenied
                }
                throw AppleMailServiceError.scriptExecutionFailed(number: number)
            }
            let output = descriptor.stringValue ?? ""
            guard output.utf8.count <= maximumOutputBytes else {
                throw AppleMailServiceError.outputTooLarge
            }
            return AppleMailScriptOutput(text: output)
        }
    }
}

public struct AppleMailAccount: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let email: String
}

public struct AppleMailStatus: Codable, Sendable, Equatable {
    public let accounts: [AppleMailAccount]

    public init(accounts: [AppleMailAccount]) {
        self.accounts = accounts
    }
}

public struct AppleMailSearchHit: Codable, Sendable, Equatable {
    public let id: String
    public let messageID: String
    public let subject: String
    public let sender: String
    public let dateReceived: String
    public let isRead: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case subject
        case sender
        case dateReceived = "date_received"
        case isRead = "is_read"
    }
}

public struct AppleMailSearchResult: Codable, Sendable, Equatable {
    public let accountID: String
    public let messages: [AppleMailSearchHit]
    public let scannedMessages: Int

    public init(accountID: String, messages: [AppleMailSearchHit], scannedMessages: Int) {
        self.accountID = accountID
        self.messages = messages
        self.scannedMessages = scannedMessages
    }
}

public struct AppleMailMessage: Codable, Sendable, Equatable {
    public let id: String
    public let messageID: String
    public let subject: String
    public let sender: String
    public let dateReceived: String
    public let isRead: Bool
    public let content: String

    private enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case subject
        case sender
        case dateReceived = "date_received"
        case isRead = "is_read"
        case content
    }
}

public struct AppleMailDraftReceipt: Codable, Sendable, Equatable {
    public let accountID: String
    public let draftID: String
    public let recipientCount: Int

    public init(accountID: String, draftID: String, recipientCount: Int) {
        self.accountID = accountID
        self.draftID = draftID
        self.recipientCount = recipientCount
    }
}

public struct AppleMailSendReceipt: Codable, Sendable, Equatable {
    public let accountID: String
    public let draftID: String
    public let sent: Bool

    public init(accountID: String, draftID: String, sent: Bool) {
        self.accountID = accountID
        self.draftID = draftID
        self.sent = sent
    }
}

/// Outlook/Exchange access through accounts that are already connected to
/// macOS Mail. The service never reads the private Accounts database or the
/// Keychain; Mail owns its existing OAuth session and macOS mediates access
/// through the normal Automation permission.
public actor AppleMailService {
    public nonisolated static let maximumOutputBytes = 32 * 1_024
    public nonisolated static let maximumAccounts = 8
    public nonisolated static let maximumSearchResults = 20

    private let runner: AppleMailScriptRunner

    public init(runner: AppleMailScriptRunner = .live) {
        self.runner = runner
    }

    public func status() async throws -> AppleMailStatus {
        let response: StatusScriptResponse = try await perform(
            operation: .accountStatus,
            arguments: []
        )
        try validate(response.ok, providerError: response.error)
        let accounts = try response.accounts.prefix(Self.maximumAccounts).map {
            AppleMailAccount(
                id: try Self.bounded($0.id, field: "account", maximumCharacters: 512),
                name: Self.boundedOutput($0.name, maximumBytes: 320),
                email: Self.boundedOutput($0.email, maximumBytes: 320)
            )
        }
        return AppleMailStatus(accounts: Array(accounts))
    }

    public func search(
        accountID: String,
        query: String,
        maximumResults: Int = 10
    ) async throws -> AppleMailSearchResult {
        let accountID = try Self.bounded(accountID, field: "account", maximumCharacters: 512)
        let query = try Self.bounded(query, field: "query", maximumCharacters: 1_000)
        guard (1...Self.maximumSearchResults).contains(maximumResults) else {
            throw AppleMailServiceError.invalidArgument("max")
        }
        let response: SearchScriptResponse = try await perform(
            operation: .search,
            arguments: [accountID, query, String(maximumResults)]
        )
        try validate(response.ok, providerError: response.error)
        let messages = response.messages.prefix(maximumResults).map(Self.boundSearchHit)
        return AppleMailSearchResult(
            accountID: accountID,
            messages: Array(messages),
            scannedMessages: min(max(0, response.scanned), 500)
        )
    }

    public func read(accountID: String, messageID: String) async throws -> AppleMailMessage {
        let accountID = try Self.bounded(accountID, field: "account", maximumCharacters: 512)
        let messageID = try Self.numericIdentifier(messageID, field: "message id")
        let response: ReadScriptResponse = try await perform(
            operation: .read,
            arguments: [accountID, messageID]
        )
        try validate(response.ok, providerError: response.error)
        guard let message = response.message else {
            throw AppleMailServiceError.malformedResponse
        }
        return AppleMailMessage(
            id: Self.boundedOutput(message.id, maximumBytes: 128),
            messageID: Self.boundedOutput(message.messageID, maximumBytes: 998),
            subject: Self.boundedOutput(message.subject, maximumBytes: 2_000),
            sender: Self.boundedOutput(message.sender, maximumBytes: 1_000),
            dateReceived: Self.boundedOutput(message.dateReceived, maximumBytes: 160),
            isRead: message.isRead,
            content: Self.boundedOutput(message.content, maximumBytes: 16 * 1_024)
        )
    }

    public func createDraft(
        accountID: String,
        recipients: [String],
        subject: String,
        body: String
    ) async throws -> AppleMailDraftReceipt {
        let accountID = try Self.bounded(accountID, field: "account", maximumCharacters: 512)
        guard (1...20).contains(recipients.count) else {
            throw AppleMailServiceError.invalidArgument("recipients")
        }
        let recipients = try recipients.map(Self.validatedAddress)
        let subject = try Self.validatedHeader(subject, field: "subject", maximumCharacters: 998)
        let body = try Self.bounded(
            body,
            field: "body",
            maximumCharacters: 100_000,
            allowEmpty: true
        )
        let response: DraftScriptResponse = try await perform(
            operation: .createDraft,
            arguments: [accountID, subject, body] + recipients
        )
        try validate(response.ok, providerError: response.error)
        guard let draftID = response.draftID else {
            throw AppleMailServiceError.malformedResponse
        }
        return AppleMailDraftReceipt(
            accountID: accountID,
            draftID: try Self.numericIdentifier(draftID, field: "draft id"),
            recipientCount: recipients.count
        )
    }

    public func sendDraft(accountID: String, draftID: String) async throws -> AppleMailSendReceipt {
        let accountID = try Self.bounded(accountID, field: "account", maximumCharacters: 512)
        let draftID = try Self.numericIdentifier(draftID, field: "draft id")
        let response: SendScriptResponse = try await perform(
            operation: .sendDraft,
            arguments: [accountID, draftID]
        )
        try validate(response.ok, providerError: response.error)
        guard response.sent == true else {
            throw AppleMailServiceError.providerFailure("send_failed")
        }
        return AppleMailSendReceipt(
            accountID: accountID,
            draftID: draftID,
            sent: true
        )
    }

    /// Allows verification to compile every fixed script without talking to
    /// Mail. No Apple event is sent and no Automation prompt is triggered.
    public nonisolated static func validateStaticScripts() throws {
        for operation in AppleMailScriptOperation.allCases {
            guard let script = NSAppleScript(source: AppleMailStaticScripts.source(for: operation)) else {
                throw AppleMailServiceError.scriptCompilationFailed
            }
            var error: NSDictionary?
            guard script.compileAndReturnError(&error) else {
                throw AppleMailServiceError.scriptCompilationFailed
            }
        }
    }

    private func perform<Response: Decodable>(
        operation: AppleMailScriptOperation,
        arguments: [String]
    ) async throws -> Response {
        let invocation = AppleMailScriptInvocation(
            operation: operation,
            source: AppleMailStaticScripts.source(for: operation),
            arguments: arguments
        )
        let output = try await runner.run(
            invocation,
            maximumOutputBytes: Self.maximumOutputBytes
        )
        guard output.text.utf8.count <= Self.maximumOutputBytes,
              let data = output.text.data(using: .utf8) else {
            throw AppleMailServiceError.outputTooLarge
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AppleMailServiceError.malformedResponse
        }
    }

    private func validate(_ ok: Bool, providerError: String?) throws {
        guard ok else {
            let allowed = Set([
                "account_not_found", "inbox_not_found", "message_not_found",
                "draft_not_found", "draft_account_mismatch", "no_sender_address",
                "send_failed",
            ])
            throw AppleMailServiceError.providerFailure(
                providerError.flatMap { allowed.contains($0) ? $0 : nil } ?? "provider_error"
            )
        }
    }

    private nonisolated static func boundSearchHit(_ message: AppleMailSearchHit) -> AppleMailSearchHit {
        AppleMailSearchHit(
            id: boundedOutput(message.id, maximumBytes: 128),
            messageID: boundedOutput(message.messageID, maximumBytes: 998),
            subject: boundedOutput(message.subject, maximumBytes: 2_000),
            sender: boundedOutput(message.sender, maximumBytes: 1_000),
            dateReceived: boundedOutput(message.dateReceived, maximumBytes: 160),
            isRead: message.isRead
        )
    }

    private nonisolated static func bounded(
        _ value: String,
        field: String,
        maximumCharacters: Int,
        allowEmpty: Bool = false
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !trimmed.isEmpty),
              value.count <= maximumCharacters,
              !value.contains("\0") else {
            throw AppleMailServiceError.invalidArgument(field)
        }
        return value
    }

    private nonisolated static func validatedHeader(
        _ value: String,
        field: String,
        maximumCharacters: Int
    ) throws -> String {
        let value = try bounded(value, field: field, maximumCharacters: maximumCharacters)
        guard !value.contains("\r"), !value.contains("\n") else {
            throw AppleMailServiceError.invalidArgument(field)
        }
        return value
    }

    private nonisolated static func validatedAddress(_ value: String) throws -> String {
        let value = try validatedHeader(value, field: "recipient", maximumCharacters: 320)
        guard value.contains("@"), !value.contains(","), !value.contains(";") else {
            throw AppleMailServiceError.invalidArgument("recipient")
        }
        return value
    }

    private nonisolated static func numericIdentifier(
        _ value: String,
        field: String
    ) throws -> String {
        let value = try bounded(value, field: field, maximumCharacters: 128)
        guard value.allSatisfy(\.isNumber) else {
            throw AppleMailServiceError.invalidArgument(field)
        }
        return value
    }

    private nonisolated static func boundedOutput(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        var used = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            guard used + bytes <= maximumBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}

private struct StatusScriptResponse: Decodable {
    let ok: Bool
    let error: String?
    let accounts: [AppleMailAccount]

    private enum CodingKeys: String, CodingKey {
        case ok, error, accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        accounts = try container.decodeIfPresent([AppleMailAccount].self, forKey: .accounts) ?? []
    }
}

private struct SearchScriptResponse: Decodable {
    let ok: Bool
    let error: String?
    let messages: [AppleMailSearchHit]
    let scanned: Int

    private enum CodingKeys: String, CodingKey {
        case ok, error, messages, scanned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        messages = try container.decodeIfPresent([AppleMailSearchHit].self, forKey: .messages) ?? []
        scanned = try container.decodeIfPresent(Int.self, forKey: .scanned) ?? 0
    }
}

private struct ReadScriptResponse: Decodable {
    let ok: Bool
    let error: String?
    let message: AppleMailMessage?
}

private struct DraftScriptResponse: Decodable {
    let ok: Bool
    let error: String?
    let draftID: String?

    private enum CodingKeys: String, CodingKey {
        case ok, error
        case draftID = "draft_id"
    }
}

private struct SendScriptResponse: Decodable {
    let ok: Bool
    let error: String?
    let sent: Bool?
}

private enum AppleMailStaticScripts {
    static func source(for operation: AppleMailScriptOperation) -> String {
        commonHandlers + "\n" + operationBody(for: operation)
    }

    private static func operationBody(for operation: AppleMailScriptOperation) -> String {
        switch operation {
        case .accountStatus: accountStatus
        case .search: search
        case .read: read
        case .createDraft: createDraft
        case .sendDraft: sendDraft
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

on joinJSON(jsonParts)
    if (count of jsonParts) is 0 then return ""
    set previousDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to ","
    set joinedText to jsonParts as text
    set AppleScript's text item delimiters to previousDelimiters
    return joinedText
end joinJSON

on truncateText(valueText, maximumCharacters)
    set sourceText to valueText as text
    if (count characters of sourceText) is less than or equal to maximumCharacters then return sourceText
    return text 1 thru maximumCharacters of sourceText
end truncateText

on booleanJSON(booleanValue)
    if booleanValue then return "true"
    return "false"
end booleanJSON

on mailAccountByID(accountIdentifier)
    tell application "Mail"
        repeat with accountReference in every account
            try
                if (id of accountReference as text) is accountIdentifier then return accountReference
            end try
        end repeat
    end tell
    return missing value
end mailAccountByID

on isOutlookAccount(accountReference)
    tell application "Mail"
        set hostText to ""
        set addressText to ""
        try
            set hostText to server name of accountReference as text
        end try
        try
            set configuredAddresses to email addresses of accountReference
            if (count of configuredAddresses) > 0 then set addressText to item 1 of configuredAddresses as text
        end try
    end tell
    ignoring case
        if hostText contains "outlook" then return true
        if hostText contains "office365" then return true
        if hostText contains "microsoft" then return true
        if hostText contains "exchange" then return true
        if addressText ends with "@outlook.com" then return true
        if addressText ends with "@hotmail.com" then return true
        if addressText ends with "@live.com" then return true
        if addressText ends with "@msn.com" then return true
    end ignoring
    return false
end isOutlookAccount

on inboxForAccount(accountReference)
    tell application "Mail"
        try
            repeat with mailboxReference in every mailbox of accountReference
                set mailboxName to name of mailboxReference as text
                ignoring case
                    if mailboxName is "inbox" or mailboxName is "in" then return mailboxReference
                end ignoring
            end repeat
        end try
    end tell
    return missing value
end inboxForAccount

on primaryAddressForAccount(accountReference)
    tell application "Mail"
        try
            set configuredAddresses to email addresses of accountReference
            if (count of configuredAddresses) > 0 then return item 1 of configuredAddresses as text
        end try
    end tell
    return ""
end primaryAddressForAccount
"""#

    private static let accountStatus = #"""
on run argv
    set accountRows to {}
    tell application "Mail"
        repeat with accountReference in every account
            try
                if (enabled of accountReference) and my isOutlookAccount(accountReference) then
                    set accountIdentifier to id of accountReference as text
                    set accountName to name of accountReference as text
                    set accountAddress to my primaryAddressForAccount(accountReference)
                    set rowJSON to "{\"id\":" & my jsonString(accountIdentifier) & ",\"name\":" & my jsonString(my truncateText(accountName, 320)) & ",\"email\":" & my jsonString(my truncateText(accountAddress, 320)) & "}"
                    set end of accountRows to rowJSON
                end if
            end try
        end repeat
    end tell
    return "{\"ok\":true,\"accounts\":[" & my joinJSON(accountRows) & "]}"
end run
"""#

    private static let search = #"""
on run argv
    if (count of argv) is not 3 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set accountIdentifier to item 1 of argv as text
    set queryText to item 2 of argv as text
    set maximumResults to item 3 of argv as integer
    set accountReference to my mailAccountByID(accountIdentifier)
    if accountReference is missing value then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    if not my isOutlookAccount(accountReference) then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    set inboxReference to my inboxForAccount(accountReference)
    if inboxReference is missing value then return "{\"ok\":false,\"error\":\"inbox_not_found\"}"

    set resultRows to {}
    set scannedCount to 0
    tell application "Mail"
        set candidateMessages to every message of inboxReference
        set candidateCount to count of candidateMessages
        if candidateCount > 500 then set candidateCount to 500
        repeat with messageIndex from 1 to candidateCount
            set scannedCount to scannedCount + 1
            set messageReference to item messageIndex of candidateMessages
            try
                set subjectText to subject of messageReference as text
                set senderText to sender of messageReference as text
                set isMatch to false
                ignoring case
                    if subjectText contains queryText or senderText contains queryText then set isMatch to true
                end ignoring
                if isMatch then
                    set localIdentifier to id of messageReference as text
                    set internetIdentifier to ""
                    try
                        set internetIdentifier to message id of messageReference as text
                    end try
                    set receivedText to date received of messageReference as text
                    set readValue to read status of messageReference
                    set rowJSON to "{\"id\":" & my jsonString(localIdentifier) & ",\"message_id\":" & my jsonString(my truncateText(internetIdentifier, 998)) & ",\"subject\":" & my jsonString(my truncateText(subjectText, 1000)) & ",\"sender\":" & my jsonString(my truncateText(senderText, 500)) & ",\"date_received\":" & my jsonString(my truncateText(receivedText, 160)) & ",\"is_read\":" & my booleanJSON(readValue) & "}"
                    set end of resultRows to rowJSON
                    if (count of resultRows) is greater than or equal to maximumResults then exit repeat
                end if
            end try
        end repeat
    end tell
    return "{\"ok\":true,\"scanned\":" & scannedCount & ",\"messages\":[" & my joinJSON(resultRows) & "]}"
end run
"""#

    private static let read = #"""
on run argv
    if (count of argv) is not 2 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set accountIdentifier to item 1 of argv as text
    set wantedIdentifier to item 2 of argv as text
    set accountReference to my mailAccountByID(accountIdentifier)
    if accountReference is missing value then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    if not my isOutlookAccount(accountReference) then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    set inboxReference to my inboxForAccount(accountReference)
    if inboxReference is missing value then return "{\"ok\":false,\"error\":\"inbox_not_found\"}"

    tell application "Mail"
        set candidateMessages to every message of inboxReference
        set candidateCount to count of candidateMessages
        if candidateCount > 500 then set candidateCount to 500
        repeat with messageIndex from 1 to candidateCount
            set messageReference to item messageIndex of candidateMessages
            try
                if (id of messageReference as text) is wantedIdentifier then
                    set internetIdentifier to ""
                    try
                        set internetIdentifier to message id of messageReference as text
                    end try
                    set subjectText to subject of messageReference as text
                    set senderText to sender of messageReference as text
                    set receivedText to date received of messageReference as text
                    set readValue to read status of messageReference
                    set bodyText to content of messageReference as text
                    set messageJSON to "{\"id\":" & my jsonString(wantedIdentifier) & ",\"message_id\":" & my jsonString(my truncateText(internetIdentifier, 998)) & ",\"subject\":" & my jsonString(my truncateText(subjectText, 1000)) & ",\"sender\":" & my jsonString(my truncateText(senderText, 500)) & ",\"date_received\":" & my jsonString(my truncateText(receivedText, 160)) & ",\"is_read\":" & my booleanJSON(readValue) & ",\"content\":" & my jsonString(my truncateText(bodyText, 16000)) & "}"
                    return "{\"ok\":true,\"message\":" & messageJSON & "}"
                end if
            end try
        end repeat
    end tell
    return "{\"ok\":false,\"error\":\"message_not_found\"}"
end run
"""#

    private static let createDraft = #"""
on run argv
    if (count of argv) is less than 4 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set accountIdentifier to item 1 of argv as text
    set subjectText to item 2 of argv as text
    set bodyText to item 3 of argv as text
    set accountReference to my mailAccountByID(accountIdentifier)
    if accountReference is missing value then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    if not my isOutlookAccount(accountReference) then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    set senderAddress to my primaryAddressForAccount(accountReference)
    if senderAddress is "" then return "{\"ok\":false,\"error\":\"no_sender_address\"}"

    tell application "Mail"
        set draftMessage to make new outgoing message with properties {visible:false, subject:subjectText, content:bodyText, sender:senderAddress}
        repeat with argumentIndex from 4 to count of argv
            set recipientAddress to item argumentIndex of argv as text
            tell draftMessage to make new to recipient at end of to recipients with properties {address:recipientAddress}
        end repeat
        save draftMessage
        set draftIdentifier to id of draftMessage as text
    end tell
    return "{\"ok\":true,\"draft_id\":" & my jsonString(draftIdentifier) & "}"
end run
"""#

    private static let sendDraft = #"""
on run argv
    if (count of argv) is not 2 then return "{\"ok\":false,\"error\":\"invalid_arguments\"}"
    set accountIdentifier to item 1 of argv as text
    set wantedDraftIdentifier to item 2 of argv as text
    set accountReference to my mailAccountByID(accountIdentifier)
    if accountReference is missing value then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    if not my isOutlookAccount(accountReference) then return "{\"ok\":false,\"error\":\"account_not_found\"}"
    set configuredAddresses to {}
    tell application "Mail"
        try
            set configuredAddresses to email addresses of accountReference
        end try
        repeat with draftReference in every outgoing message
            try
                if (id of draftReference as text) is wantedDraftIdentifier then
                    set draftSender to sender of draftReference as text
                    set senderMatches to false
                    repeat with configuredAddress in configuredAddresses
                        ignoring case
                            if draftSender contains (configuredAddress as text) then set senderMatches to true
                        end ignoring
                    end repeat
                    if not senderMatches then return "{\"ok\":false,\"error\":\"draft_account_mismatch\"}"
                    set sendSucceeded to send draftReference
                    if sendSucceeded then return "{\"ok\":true,\"sent\":true}"
                    return "{\"ok\":false,\"error\":\"send_failed\"}"
                end if
            end try
        end repeat
    end tell
    return "{\"ok\":false,\"error\":\"draft_not_found\"}"
end run
"""#
}
