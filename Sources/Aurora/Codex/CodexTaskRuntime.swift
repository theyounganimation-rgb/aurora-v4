import Foundation

enum CodexTaskRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case invalidTaskIdentifier
    case invalidThreadIdentifier
    case invalidInput
    case executableRejected
    case processUnavailable
    case processTerminated(exitCode: Int32)
    case transportFailure
    case protocolViolation
    case inboundMessageTooLarge
    case outboundMessageTooLarge
    case detachedPersistenceUnavailable
    case chatGPTLoginRequired
    case requestTimedOut(method: String)
    case requestCancelled
    case serverError(code: Int, message: String)
    case taskAlreadyExists
    case taskNotFound
    case taskBusy
    case turnAlreadyActive
    case noActiveTurn
    case threadUnavailable
    case threadWorkingDirectoryChanged
    case unknownServerRequest

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The Codex task runtime configuration is invalid."
        case .invalidTaskIdentifier:
            return "The Codex task identifier is invalid."
        case .invalidThreadIdentifier:
            return "The Codex thread identifier is invalid."
        case .invalidInput:
            return "The Codex task input is invalid."
        case .executableRejected:
            return "The bundled Codex executable could not be trusted."
        case .processUnavailable:
            return "The Codex app server could not be started."
        case .processTerminated:
            return "The Codex app server stopped unexpectedly."
        case .transportFailure:
            return "The Codex app server connection failed."
        case .protocolViolation:
            return "The Codex app server returned an invalid protocol message."
        case .inboundMessageTooLarge:
            return "The Codex app server exceeded its response boundary."
        case .outboundMessageTooLarge:
            return "The Codex request exceeded its size boundary."
        case .detachedPersistenceUnavailable:
            return "The shared Codex daemon is required for work that must continue after Aurora closes."
        case .chatGPTLoginRequired:
            return "Codex must be signed in with ChatGPT."
        case .requestTimedOut:
            return "The Codex app server did not respond in time."
        case .requestCancelled:
            return "The Codex request was cancelled."
        case .serverError(_, let message):
            return message.isEmpty ? "The Codex app server rejected the request." : message
        case .taskAlreadyExists:
            return "That Codex task already has a thread."
        case .taskNotFound:
            return "That Codex task has no mapped thread."
        case .taskBusy:
            return "That Codex task already has a request in progress."
        case .turnAlreadyActive:
            return "That Codex task already has an active turn."
        case .noActiveTurn:
            return "That Codex task has no active turn."
        case .threadUnavailable:
            return "That Codex task is no longer available as an unarchived persistent task."
        case .threadWorkingDirectoryChanged:
            return "That Codex task is no longer in the selected project."
        case .unknownServerRequest:
            return "That Codex server request is no longer pending."
        }
    }
}

enum CodexTaskApprovalPolicy: String, Sendable, Codable, CaseIterable {
    case untrusted
    case onRequest = "on-request"
    case never
}

enum CodexTaskSandboxMode: String, Sendable, Codable, CaseIterable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    fileprivate var responseType: String {
        switch self {
        case .readOnly: return "readOnly"
        case .workspaceWrite: return "workspaceWrite"
        case .dangerFullAccess: return "dangerFullAccess"
        }
    }
}

/// Per-turn reasoning levels accepted by the Codex app-server `turn/start`
/// protocol. Keeping this explicit lets lightweight motor work choose a lower
/// latency profile without changing the model or weakening its execution
/// boundary.
enum CodexTaskReasoningEffort: String, Sendable, Codable, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

/// A deliberately small typed JSON-Schema surface for app-server dynamic
/// function tools. Aurora currently needs bounded string arguments only; not
/// accepting arbitrary JSON here keeps the host contract reviewable and makes
/// validation happen before a thread is created.
struct CodexTaskDynamicToolStringProperty: Sendable, Equatable {
    var description: String?
    var allowedValues: [String]?
    var minimumLength: Int?
    var maximumLength: Int?

    init(
        description: String? = nil,
        allowedValues: [String]? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil
    ) {
        self.description = description
        self.allowedValues = allowedValues
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
    }
}

struct CodexTaskDynamicToolInputSchema: Sendable, Equatable {
    var properties: [String: CodexTaskDynamicToolStringProperty]
    var required: [String]

    init(
        properties: [String: CodexTaskDynamicToolStringProperty],
        required: [String] = []
    ) {
        self.properties = properties
        self.required = required
    }
}

struct CodexTaskDynamicToolSpec: Sendable, Equatable {
    var name: String
    var description: String
    var inputSchema: CodexTaskDynamicToolInputSchema
    var deferLoading: Bool

    init(
        name: String,
        description: String,
        inputSchema: CodexTaskDynamicToolInputSchema,
        deferLoading: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.deferLoading = deferLoading
    }
}

struct CodexTaskThreadOptions: Sendable, Equatable {
    var model: String?
    var reasoningEffort: CodexTaskReasoningEffort?
    var workingDirectory: URL?
    var approvalPolicy: CodexTaskApprovalPolicy
    var sandboxMode: CodexTaskSandboxMode
    var developerInstructions: String?
    /// Host-owned functions exposed only when this thread is first created.
    /// Their arguments remain untrusted and must be validated again by the
    /// server-request handler before any result is returned.
    var dynamicTools: [CodexTaskDynamicToolSpec]
    /// A bounded, user-facing title for the persistent Codex Desktop thread.
    /// This is display metadata only; it is never interpreted as authorization.
    var threadName: String?
    var ephemeral: Bool
    /// Fail closed unless the exact thread/start is issued through the shared
    /// daemon. This is checked inside startTask after every startup await, not
    /// merely as a coordinator preflight.
    var requiresDetachedPersistence: Bool

    init(
        model: String? = nil,
        reasoningEffort: CodexTaskReasoningEffort? = nil,
        workingDirectory: URL? = nil,
        approvalPolicy: CodexTaskApprovalPolicy = .onRequest,
        sandboxMode: CodexTaskSandboxMode = .readOnly,
        developerInstructions: String? = nil,
        dynamicTools: [CodexTaskDynamicToolSpec] = [],
        threadName: String? = nil,
        ephemeral: Bool = false,
        requiresDetachedPersistence: Bool = false
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workingDirectory = workingDirectory
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.developerInstructions = developerInstructions
        self.dynamicTools = dynamicTools
        self.threadName = threadName
        self.ephemeral = ephemeral
        self.requiresDetachedPersistence = requiresDetachedPersistence
    }
}

struct CodexTaskRuntimeConfiguration: Sendable, Equatable {
    var executableURL: URL
    var codexHomeURL: URL
    var requestTimeout: TimeInterval
    var maximumInboundLineBytes: Int
    var maximumBufferedInboundBytes: Int
    var maximumOutboundMessageBytes: Int
    var maximumStandardErrorBytes: Int
    var maximumInputBytes: Int
    var maximumDeveloperInstructionBytes: Int
    var maximumPendingServerRequests: Int
    var terminationGracePeriod: TimeInterval
    var prefersSharedDaemon: Bool
    var sharedDaemonProbeTimeout: TimeInterval

    init(
        executableURL: URL = OpenAICodexExecutableValidator.expectedExecutableURL,
        codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        requestTimeout: TimeInterval = 15,
        // Image-generation results can legitimately exceed 2 MiB. Keep
        // enough bounded headroom for those app-server events while the
        // configuration validator retains the hard 16 MiB ceiling.
        maximumInboundLineBytes: Int = 8 * 1_024 * 1_024,
        // Bound aggregate queued stdout independently from the single-line
        // allowance. This keeps several image-sized events valid without
        // permitting a burst to retain hundreds of megabytes.
        maximumBufferedInboundBytes: Int = 32 * 1_024 * 1_024,
        maximumOutboundMessageBytes: Int = 256 * 1_024,
        maximumStandardErrorBytes: Int = 64 * 1_024,
        maximumInputBytes: Int = 64 * 1_024,
        maximumDeveloperInstructionBytes: Int = 32 * 1_024,
        maximumPendingServerRequests: Int = 32,
        terminationGracePeriod: TimeInterval = 0.75,
        prefersSharedDaemon: Bool = true,
        sharedDaemonProbeTimeout: TimeInterval = 1.25
    ) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.requestTimeout = requestTimeout
        self.maximumInboundLineBytes = maximumInboundLineBytes
        self.maximumBufferedInboundBytes = maximumBufferedInboundBytes
        self.maximumOutboundMessageBytes = maximumOutboundMessageBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.maximumInputBytes = maximumInputBytes
        self.maximumDeveloperInstructionBytes = maximumDeveloperInstructionBytes
        self.maximumPendingServerRequests = maximumPendingServerRequests
        self.terminationGracePeriod = terminationGracePeriod
        self.prefersSharedDaemon = prefersSharedDaemon
        self.sharedDaemonProbeTimeout = sharedDaemonProbeTimeout
    }
}

struct CodexTaskHandle: Sendable, Equatable {
    let taskID: String
    let threadID: String
    let turnID: String
}

struct CodexTaskAccountSnapshot: Sendable, Equatable {
    let authenticationType: String
    let planType: String?
}

/// Typed surface Aurora uses to inspect and manage the same Codex
/// threads shown by the ChatGPT/Codex desktop app. Ordinary ChatGPT chats are
/// intentionally outside app-server's supported protocol.
struct AuroraCodexThreadQuery: Sendable, Equatable {
    var searchTerm: String?
    var workingDirectory: URL?
    var cursor: String?
    var limit: Int
    var archived: Bool

    init(
        searchTerm: String? = nil,
        workingDirectory: URL? = nil,
        cursor: String? = nil,
        limit: Int = 50,
        archived: Bool = false
    ) {
        self.searchTerm = searchTerm
        self.workingDirectory = workingDirectory
        self.cursor = cursor
        self.limit = limit
        self.archived = archived
    }
}

struct AuroraCodexThreadSummary: Sendable, Equatable {
    let threadID: String
    let name: String?
    let preview: String
    let workingDirectory: URL
    let status: String
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let ephemeral: Bool
}

struct AuroraCodexThreadPage: Sendable, Equatable {
    let threads: [AuroraCodexThreadSummary]
    let nextCursor: String?
}

struct AuroraCodexThreadDocument: Sendable, Equatable {
    let summary: AuroraCodexThreadSummary
    /// Canonical bounded JSON returned by thread/read. This preserves Codex's
    /// evolving item vocabulary without leaking unvalidated dictionaries into
    /// the rest of Aurora.
    let canonicalThreadJSON: Data
}

protocol AuroraCodexAppAPI: Sendable {
    /// Creates one persistent Codex thread and starts its first turn. The task
    /// identifier is Aurora-owned; the returned thread/turn identifiers are the
    /// app-server identities shown by Codex Desktop.
    func startTask(
        taskID: String,
        input: String,
        options: CodexTaskThreadOptions
    ) async throws -> CodexTaskHandle
    /// Creates a persistent project thread from the exact owner-authored text.
    /// The options must identify a working directory and may not add developer
    /// instructions or dynamic tools; those are Aurora's delegated-task
    /// scaffold and do not belong in an owner-selected Codex conversation.
    func startRawProjectThread(
        taskID: String,
        input: String,
        options: CodexTaskThreadOptions
    ) async throws -> CodexTaskHandle
    /// Sends exact owner-authored text to an existing persistent Codex thread.
    /// The runtime revalidates the unarchived thread and expected project, then
    /// preserves the thread's existing model, instructions, and permissions.
    func sendRawProjectMessage(
        taskID: String,
        threadID: String,
        input: String,
        expectedWorkingDirectory: URL
    ) async throws -> CodexTaskHandle
    /// Reads and, when necessary, subscribes to an existing selected project
    /// thread without starting a turn or replacing any server-owned settings.
    func reconcileExactProjectThread(
        taskID: String,
        threadID: String,
        expectedWorkingDirectory: URL
    ) async throws -> CodexDelegateTaskReconciliation
    /// Continues a completed thread as a new turn, or steers the currently
    /// running turn without inventing a second task.
    func continueTask(
        taskID: String,
        input: String,
        reasoningEffort: CodexTaskReasoningEffort?
    ) async throws -> CodexTaskHandle
    func steerTask(taskID: String, input: String) async throws
    func interruptTask(taskID: String) async throws
    func listThreads(
        query: AuroraCodexThreadQuery
    ) async throws -> AuroraCodexThreadPage
    func readThread(
        threadID: String,
        includeTurns: Bool
    ) async throws -> AuroraCodexThreadDocument
    func renameThread(threadID: String, name: String) async throws
    func archiveThread(threadID: String) async throws
    func unarchiveThread(threadID: String) async throws
    func openThreadInDesktop(threadID: String) async -> Bool
}

enum CodexTaskServerRequestID: Sendable, Hashable, Equatable {
    case integer(Int64)
    case string(String)

    fileprivate var jsonValue: Any {
        switch self {
        case .integer(let value): return value
        case .string(let value): return value
        }
    }
}

struct CodexTaskRuntimeEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case notification
        case serverRequest
        case lifecycle
    }

    let kind: Kind
    let method: String
    let taskID: String?
    let threadID: String?
    let turnID: String?
    let serverRequestID: CodexTaskServerRequestID?
    /// Canonical bounded JSON for the event's `params` object. Screen, app,
    /// file, and tool content remains observation data; it is never converted
    /// into authorization by this transport.
    let paramsJSON: Data
}

struct CodexAppServerLaunch: Sendable, Equatable {
    let generation: UUID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let maximumInboundLineBytes: Int
    let maximumBufferedInboundBytes: Int
    let maximumOutboundMessageBytes: Int
    let maximumStandardErrorBytes: Int
    let terminationGracePeriod: TimeInterval
}

/// Retains one inbound JSONL record and releases its transport byte-budget
/// reservation when the record leaves the stream and runtime. The release
/// hook is transport bookkeeping only; the immutable bytes remain the event's
/// canonical wire payload.
final class CodexAppServerInboundLine: @unchecked Sendable, Equatable {
    let data: Data
    private let onRelease: (@Sendable () -> Void)?

    init(data: Data, onRelease: (@Sendable () -> Void)? = nil) {
        self.data = data
        self.onRelease = onRelease
    }

    deinit {
        onRelease?()
    }

    static func == (lhs: CodexAppServerInboundLine, rhs: CodexAppServerInboundLine) -> Bool {
        lhs.data == rhs.data
    }
}

enum CodexAppServerTransportEvent: Sendable, Equatable {
    case line(sequence: UInt64, data: CodexAppServerInboundLine)
    case inboundOverflow
    case protocolFailure
    case terminated(exitCode: Int32, expected: Bool, standardErrorOverflowed: Bool)
}

protocol CodexAppServerTransporting: Sendable {
    func start(_ launch: CodexAppServerLaunch) async throws -> AsyncStream<CodexAppServerTransportEvent>
    func send(_ message: Data, generation: UUID) async throws
    func stop() async
}

protocol CodexTaskExecutableValidating: Sendable {
    func validate(executableURL: URL) throws
}

/// Makes an existing persistent app-server thread visible in Codex Desktop.
/// The deeplink loads the existing identity; it never creates, executes, or
/// duplicates a thread and is not evidence that the task itself succeeded.
protocol CodexDesktopThreadRegistering: Sendable {
    func registerPersistentThread(threadID: String) async -> Bool
}

actor MacOSCodexDesktopThreadRegistrar: CodexDesktopThreadRegistering {
    func registerPersistentThread(threadID: String) async -> Bool {
        guard UUID(uuidString: threadID) != nil,
              let deeplink = URL(string: "codex://threads/\(threadID)") else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Load the thread without taking keyboard focus away from Aurora or
        // whatever the owner is currently doing on the Mac.
        process.arguments = ["-g", deeplink.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit
                && process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

struct OpenAICodexTaskExecutableValidator: CodexTaskExecutableValidating {
    func validate(executableURL: URL) throws {
        try OpenAICodexExecutableValidator().validate(executableURL: executableURL)
    }
}

actor CodexTaskRuntime: AuroraCodexAppAPI {
    typealias EventHandler = @Sendable (CodexTaskRuntimeEvent) -> Void

    private enum RawProjectTurnState: Equatable {
        case inactive
        case active(turnID: String)
    }

    private struct PendingRPC {
        let method: String
        let generation: UUID
        let continuation: CheckedContinuation<Data, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct PendingServerRequest: Sendable {
        let method: String
        let taskID: String?
        let threadID: String?
        let turnID: String?
    }

    private let configuration: CodexTaskRuntimeConfiguration
    private let transport: any CodexAppServerTransporting
    private let sharedDaemonTransport: any CodexAppServerTransporting
    private let sharedDaemonProbe: any CodexSharedDaemonProbing
    private let executableValidator: any CodexTaskExecutableValidating
    private let desktopThreadRegistrar: any CodexDesktopThreadRegistering

    private var eventHandler: EventHandler?
    private var eventConsumerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var startupToken: UUID?
    private var transportStopTask: Task<Void, Never>?
    private var transportStopToken: UUID?
    private var generation = UUID()
    private var expectedInboundSequence: UInt64 = 0
    private var transportActive = false
    private var activeTransport: (any CodexAppServerTransporting)?
    private var usingSharedDaemon = false
    private var ready = false
    private var nextRequestID: Int64 = 1
    private var pendingRPCs: [Int64: PendingRPC] = [:]
    private var pendingServerRequests: [CodexTaskServerRequestID: PendingServerRequest] = [:]
    private var taskThreads: [String: String] = [:]
    private var threadTasks: [String: String] = [:]
    private var threadOptions: [String: CodexTaskThreadOptions] = [:]
    /// Existing owner-selected Codex threads retain their server-owned
    /// settings. Their expected cwd is a resource identity check, not a
    /// thread/resume override.
    private var preservedThreadWorkingDirectories: [String: URL] = [:]
    private var loadedThreadIDs = Set<String>()
    private var activeTurnByTask: [String: String] = [:]
    private var busyTaskIDs = Set<String>()
    private var recentlyCompletedTurnIDs: [String] = []
    private(set) var accountSnapshot: CodexTaskAccountSnapshot?
    /// The subscription check is valid only for the transport generation that
    /// produced it. Runtime reset always clears both values, so a reconnect or
    /// restart must authenticate again before any task RPC is allowed.
    private var verifiedChatGPTAccountGeneration: UUID?

    init(
        configuration: CodexTaskRuntimeConfiguration = CodexTaskRuntimeConfiguration(),
        transport: any CodexAppServerTransporting = FoundationCodexAppServerTransport(),
        executableValidator: any CodexTaskExecutableValidating = OpenAICodexTaskExecutableValidator(),
        desktopThreadRegistrar: any CodexDesktopThreadRegistering = MacOSCodexDesktopThreadRegistrar(),
        sharedDaemonTransport: any CodexAppServerTransporting = SharedCodexAppServerTransport(),
        sharedDaemonProbe: any CodexSharedDaemonProbing = FoundationCodexSharedDaemonProbe()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sharedDaemonTransport = sharedDaemonTransport
        self.sharedDaemonProbe = sharedDaemonProbe
        self.executableValidator = executableValidator
        self.desktopThreadRegistrar = desktopThreadRegistrar
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    /// Persistent delegated work is truthful only when Aurora is attached to
    /// Codex's shared daemon. A standalone stdio child dies with Aurora.
    func supportsDetachedTaskPersistence() async throws -> Bool {
        try await start()
        return ready && usingSharedDaemon
    }

    func start() async throws {
        if let transportStopTask {
            await transportStopTask.value
        }
        if ready { return }
        if let startupTask {
            try await startupTask.value
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CodexTaskRuntimeError.processUnavailable }
            try Task.checkCancellation()
            try await self.performStartup()
        }
        startupToken = token
        startupTask = task
        do {
            try await task.value
            if startupToken == token {
                startupTask = nil
                startupToken = nil
            }
        } catch {
            if startupToken == token {
                startupTask = nil
                startupToken = nil
            }
            throw error
        }
    }

    func shutdown() async {
        startupTask?.cancel()
        startupTask = nil
        startupToken = nil
        await resetRuntime(
            failure: CodexTaskRuntimeError.requestCancelled,
            stopTransport: true,
            emitMethod: "$runtime/stopped"
        )
    }

    func restart() async throws {
        startupTask?.cancel()
        startupTask = nil
        startupToken = nil
        await resetRuntime(
            failure: CodexTaskRuntimeError.requestCancelled,
            stopTransport: true,
            emitMethod: "$runtime/restarting"
        )
        try await start()
    }

    func listThreads(
        query: AuroraCodexThreadQuery = AuroraCodexThreadQuery()
    ) async throws -> AuroraCodexThreadPage {
        try Self.validateThreadQuery(query)
        try await start()
        try requireVerifiedChatGPTAccount()
        var params: [String: Any] = [
            "limit": query.limit,
            "archived": query.archived,
            // Codex Desktop currently persists app-server-created tasks with
            // the Desktop source identity (`vscode`) while retaining
            // `thread_source = appServer` in the rollout. Query every source
            // kind supported by the installed protocol so Aurora never hides
            // a valid task merely because of that storage projection.
            "modelProviders": [],
            "sourceKinds": [
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
            ],
            "sortKey": "updated_at",
            "sortDirection": "desc",
            // The default scan-and-repair path makes newly archived or moved
            // rollouts visible even when the state DB has stale metadata.
            "useStateDbOnly": false,
        ]
        if let searchTerm = query.searchTerm { params["searchTerm"] = searchTerm }
        if let workingDirectory = query.workingDirectory {
            params["cwd"] = workingDirectory.standardizedFileURL.path
        }
        if let cursor = query.cursor { params["cursor"] = cursor }
        let result = try await rpc(method: "thread/list", params: params)
        let object = try Self.decodeObject(
            result,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        guard let rawThreads = object["data"] as? [[String: Any]],
              rawThreads.count <= query.limit else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let threads = try rawThreads.map(Self.desktopThreadSummary)
        let nextCursor = try Self.optionalBoundedProtocolString(
            object["nextCursor"],
            maximumBytes: 4_096
        )
        return AuroraCodexThreadPage(threads: threads, nextCursor: nextCursor)
    }

    func readThread(
        threadID: String,
        includeTurns: Bool = true
    ) async throws -> AuroraCodexThreadDocument {
        try Self.validateOpaqueID(threadID)
        try await start()
        try requireVerifiedChatGPTAccount()
        let result = try await rpc(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": includeTurns,
        ])
        let object = try Self.decodeObject(
            result,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        guard let thread = object["thread"] as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let summary = try Self.desktopThreadSummary(thread)
        guard summary.threadID == threadID else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let canonical = try Self.canonicalJSONData(
            thread,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        return AuroraCodexThreadDocument(
            summary: summary,
            canonicalThreadJSON: canonical
        )
    }

    func renameThread(threadID: String, name: String) async throws {
        try Self.validateOpaqueID(threadID)
        try Self.validateThreadName(name)
        try await start()
        try requireVerifiedChatGPTAccount()
        _ = try await rpc(method: "thread/name/set", params: [
            "threadId": threadID,
            "name": name,
        ])
    }

    func archiveThread(threadID: String) async throws {
        try Self.validateOpaqueID(threadID)
        try await start()
        try requireVerifiedChatGPTAccount()
        _ = try await rpc(method: "thread/archive", params: ["threadId": threadID])
    }

    func unarchiveThread(threadID: String) async throws {
        try Self.validateOpaqueID(threadID)
        try await start()
        try requireVerifiedChatGPTAccount()
        _ = try await rpc(method: "thread/unarchive", params: ["threadId": threadID])
    }

    func openThreadInDesktop(threadID: String) async -> Bool {
        guard (try? Self.validateOpaqueID(threadID)) != nil else { return false }
        return await desktopThreadRegistrar.registerPersistentThread(threadID: threadID)
    }

    func startTask(
        taskID: String,
        input: String,
        options: CodexTaskThreadOptions = CodexTaskThreadOptions()
    ) async throws -> CodexTaskHandle {
        try Self.validateTaskID(taskID)
        try validateInput(input)
        try validate(options)
        guard taskThreads[taskID] == nil else { throw CodexTaskRuntimeError.taskAlreadyExists }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        try requireDetachedPersistenceIfNeeded(options)
        try requireVerifiedChatGPTAccount()
        try requireDetachedPersistenceIfNeeded(options)
        var params: [String: Any] = [
            "approvalPolicy": options.approvalPolicy.rawValue,
            "approvalsReviewer": "user",
            "sandbox": options.sandboxMode.rawValue,
            "ephemeral": options.ephemeral,
            "modelProvider": "openai",
            "serviceName": "Aurora",
            // The stable app-server protocol records this separately from the
            // server-derived session source. It lets rich clients identify the
            // thread as a first-class app-server task without inventing a
            // private Desktop database or GUI integration.
            "threadSource": "appServer",
        ]
        if let model = options.model { params["model"] = model }
        if let workingDirectory = options.workingDirectory {
            params["cwd"] = workingDirectory.standardizedFileURL.path
        }
        if let instructions = options.developerInstructions {
            params["developerInstructions"] = instructions
        }
        if !options.dynamicTools.isEmpty {
            params["dynamicTools"] = options.dynamicTools.map(Self.dynamicToolJSON)
        }
        let result = try await rpc(method: "thread/start", params: params)
        do {
            try Self.requireSecurityBoundary(in: result, expected: options)
        } catch {
            await resetRuntime(
                failure: error,
                stopTransport: true,
                emitMethod: "$runtime/thread-security-mismatch"
            )
            throw error
        }
        let threadID = try Self.threadID(from: result)
        try bind(taskID: taskID, to: threadID, options: options)
        loadedThreadIDs.insert(threadID)
        let handle = try await beginTurn(taskID: taskID, threadID: threadID, input: input)
        if let threadName = options.threadName {
            // thread/start has no title field. Set the display-only name once,
            // after turn/start. Naming is presentation metadata, so it must not
            // delay the returned task handle or turn a successfully running
            // task into an execution failure when Desktop is briefly busy.
            Task { [weak self] in
                await self?.setThreadNameBestEffort(threadID: threadID, name: threadName)
            }
        }
        if !options.ephemeral {
            // The shared daemon owns execution and persistence; the documented
            // deep link is only a best-effort Desktop visibility nudge. It is
            // never part of execution truth, task acceptance latency, or a
            // second thread.
            let registrar = desktopThreadRegistrar
            Task {
                _ = await registrar.registerPersistentThread(threadID: threadID)
            }
        }
        return handle
    }

    func startRawProjectThread(
        taskID: String,
        input: String,
        options: CodexTaskThreadOptions
    ) async throws -> CodexTaskHandle {
        guard options.workingDirectory != nil,
              !options.ephemeral,
              options.developerInstructions == nil,
              options.dynamicTools.isEmpty else {
            throw CodexTaskRuntimeError.invalidInput
        }
        // `startTask` transmits input byte-for-byte. This constrained entry
        // point prevents the delegated-task developer prompt and receipt tools
        // from leaking into an explicitly owner-directed Codex conversation.
        return try await startTask(taskID: taskID, input: input, options: options)
    }

    func sendRawProjectMessage(
        taskID: String,
        threadID: String,
        input: String,
        expectedWorkingDirectory: URL
    ) async throws -> CodexTaskHandle {
        try Self.validateTaskID(taskID)
        try Self.validateOpaqueID(threadID, failure: .invalidThreadIdentifier)
        try validateInput(input)
        let expectedDirectory = expectedWorkingDirectory.standardizedFileURL
        guard expectedDirectory.isFileURL,
              expectedDirectory.path.hasPrefix("/"),
              !expectedDirectory.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CodexTaskRuntimeError.invalidInput
        }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        try requireVerifiedChatGPTAccount()
        try await requireUnarchivedPersistentThread(
            threadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        let initialState = try await rawProjectTurnState(
            threadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        try validatePreservingThreadBinding(
            taskID: taskID,
            threadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        if !loadedThreadIDs.contains(threadID) {
            try await resumePreservingThreadSettings(
                threadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
        }
        try bindPreservingThreadSettings(
            taskID: taskID,
            to: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        synchronizeRawTurnState(initialState, taskID: taskID)
        let clientMessageID = Self.makeClientMessageID()

        do {
            return try await performRawProjectSend(
                taskID: taskID,
                threadID: threadID,
                input: input,
                clientMessageID: clientMessageID,
                state: initialState
            )
        } catch let original as CodexTaskRuntimeError {
            guard case .serverError = original else { throw original }
            // Another Codex client can complete or begin a turn after our
            // read. Re-read once and retry only when that observable state
            // actually changed. Transport failures and unchanged rejections
            // are never replayed, preventing duplicate owner messages.
            try await requireUnarchivedPersistentThread(
                threadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
            let refreshedState = try await rawProjectTurnState(
                threadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
            guard refreshedState != initialState else { throw original }
            synchronizeRawTurnState(refreshedState, taskID: taskID)
            return try await performRawProjectSend(
                taskID: taskID,
                threadID: threadID,
                input: input,
                clientMessageID: clientMessageID,
                state: refreshedState
            )
        }
    }

    /// Coordinator-facing spelling for the same exact-text project-chat path.
    /// Kept distinct from `continueTask`, whose caller may intentionally build
    /// an Aurora delegated-task update prompt.
    func sendExactMessage(
        taskID: String,
        threadID: String,
        input: String,
        expectedWorkingDirectory: URL
    ) async throws -> CodexTaskHandle {
        try await sendRawProjectMessage(
            taskID: taskID,
            threadID: threadID,
            input: input,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
    }

    func reconcileExactProjectThread(
        taskID: String,
        threadID: String,
        expectedWorkingDirectory: URL
    ) async throws -> CodexDelegateTaskReconciliation {
        try Self.validateTaskID(taskID)
        try Self.validateOpaqueID(threadID, failure: .invalidThreadIdentifier)
        let expectedDirectory = expectedWorkingDirectory.standardizedFileURL
        guard expectedDirectory.isFileURL,
              expectedDirectory.path.hasPrefix("/"),
              !expectedDirectory.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CodexTaskRuntimeError.invalidInput
        }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        try requireVerifiedChatGPTAccount()
        try await requireUnarchivedPersistentThread(
            threadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        let firstRead = try await rpc(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": true,
        ])
        var observation = try Self.exactProjectReconciliation(
            from: firstRead,
            expectedThreadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        try validatePreservingThreadBinding(
            taskID: taskID,
            threadID: threadID,
            expectedWorkingDirectory: expectedDirectory
        )

        if observation.status == .running,
           observation.latestTurnID != nil,
           !loadedThreadIDs.contains(threadID) {
            // Resuming subscribes this client to subsequent events but does
            // not start a model turn. Supplying only the identity preserves
            // the selected thread's model, instructions, and permissions.
            try await resumePreservingThreadSettings(
                threadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
        }
        try bindPreservingThreadSettings(
            taskID: taskID,
            to: threadID,
            expectedWorkingDirectory: expectedDirectory
        )
        synchronizeReconciledTurn(observation, taskID: taskID)

        if observation.status == .running, observation.latestTurnID != nil {
            // Close read→subscribe races. Completion before resume is captured
            // here; completion after this read arrives through the now-bound
            // runtime event stream.
            let refreshed = try await rpc(method: "thread/read", params: [
                "threadId": threadID,
                "includeTurns": true,
            ])
            observation = try Self.exactProjectReconciliation(
                from: refreshed,
                expectedThreadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
            synchronizeReconciledTurn(observation, taskID: taskID)
        }
        return observation
    }

    private func setThreadNameBestEffort(threadID: String, name: String) async {
        _ = try? await rpc(method: "thread/name/set", params: [
            "threadId": threadID,
            "name": name,
        ])
    }

    private func requireDetachedPersistenceIfNeeded(
        _ options: CodexTaskThreadOptions
    ) throws {
        guard !options.requiresDetachedPersistence
                || (ready && usingSharedDaemon) else {
            throw CodexTaskRuntimeError.detachedPersistenceUnavailable
        }
    }

    func continueTask(taskID: String, input: String) async throws -> CodexTaskHandle {
        try await continueTask(
            taskID: taskID,
            input: input,
            reasoningEffort: nil
        )
    }

    func continueTask(
        taskID: String,
        input: String,
        reasoningEffort: CodexTaskReasoningEffort?
    ) async throws -> CodexTaskHandle {
        try Self.validateTaskID(taskID)
        try validateInput(input)
        guard let threadID = taskThreads[taskID] else { throw CodexTaskRuntimeError.taskNotFound }
        guard activeTurnByTask[taskID] == nil else { throw CodexTaskRuntimeError.turnAlreadyActive }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        if let options = threadOptions[threadID] {
            try requireDetachedPersistenceIfNeeded(options)
        }
        try requireVerifiedChatGPTAccount()
        if let options = threadOptions[threadID] {
            try requireDetachedPersistenceIfNeeded(options)
        }
        try await ensureThreadLoaded(threadID)
        return try await beginTurn(
            taskID: taskID,
            threadID: threadID,
            input: input,
            reasoningEffort: reasoningEffort
        )
    }

    func steerTask(taskID: String, input: String) async throws {
        try Self.validateTaskID(taskID)
        try validateInput(input)
        guard let threadID = taskThreads[taskID] else { throw CodexTaskRuntimeError.taskNotFound }
        guard let turnID = activeTurnByTask[taskID] else { throw CodexTaskRuntimeError.noActiveTurn }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        if let options = threadOptions[threadID] {
            try requireDetachedPersistenceIfNeeded(options)
        }
        try requireVerifiedChatGPTAccount()
        if let options = threadOptions[threadID] {
            try requireDetachedPersistenceIfNeeded(options)
        }
        try await ensureThreadLoaded(threadID)
        let result = try await rpc(method: "turn/steer", params: [
            "threadId": threadID,
            "expectedTurnId": turnID,
            "clientUserMessageId": Self.makeClientMessageID(),
            "input": Self.textInput(input),
        ])
        let returnedTurnID = try Self.requiredString("turnId", inJSON: result)
        guard returnedTurnID == turnID else { throw CodexTaskRuntimeError.protocolViolation }
    }

    func interruptTask(taskID: String) async throws {
        try Self.validateTaskID(taskID)
        guard let threadID = taskThreads[taskID] else { throw CodexTaskRuntimeError.taskNotFound }
        guard let turnID = activeTurnByTask[taskID] else { throw CodexTaskRuntimeError.noActiveTurn }
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        if let options = threadOptions[threadID] {
            try requireDetachedPersistenceIfNeeded(options)
        }
        _ = try await rpc(method: "turn/interrupt", params: [
            "threadId": threadID,
            "turnId": turnID,
        ])
        expireServerRequests(taskID: taskID, turnID: turnID)
    }

    func restoreTaskMapping(
        taskID: String,
        threadID: String,
        options: CodexTaskThreadOptions = CodexTaskThreadOptions()
    ) throws {
        try Self.validateTaskID(taskID)
        try Self.validateOpaqueID(threadID, failure: .invalidThreadIdentifier)
        try validate(options)
        try bind(taskID: taskID, to: threadID, options: options)
    }

    /// Reattaches Aurora's durable task identifier to a persisted Codex
    /// thread and reads the latest turn as the source of truth. A thread can be
    /// `notLoaded` while its latest turn is completed, so thread runtime status
    /// is intentionally not used as task completion truth.
    func reconcileTask(
        taskID: String,
        threadID: String,
        options: CodexTaskThreadOptions
    ) async throws -> CodexDelegateTaskReconciliation {
        try Self.validateTaskID(taskID)
        try Self.validateOpaqueID(threadID, failure: .invalidThreadIdentifier)
        try validate(options)
        try beginExclusiveTaskOperation(taskID)
        defer { busyTaskIDs.remove(taskID) }

        try await start()
        try requireDetachedPersistenceIfNeeded(options)
        try requireVerifiedChatGPTAccount()
        try requireDetachedPersistenceIfNeeded(options)
        let result = try await rpc(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": true,
        ])
        var observation = try Self.reconciliation(
            from: result,
            expectedThreadID: threadID,
            expectedDynamicToolNames: Set(options.dynamicTools.map(\.name))
        )
        try bind(taskID: taskID, to: threadID, options: options)

        if observation.status == .running,
           let turnID = observation.latestTurnID {
            activeTurnByTask[taskID] = turnID
            // A read does not subscribe this connection to later turn/item
            // notifications. Resume the exact thread so completion while
            // Aurora is awake continues to update the durable ledger.
            try await ensureThreadLoaded(threadID)
            // Close the read→subscribe race: if the turn completed between
            // the first read and thread/resume, this second read observes the
            // terminal turn. If it completes after this read, the now-active
            // subscription supplies the terminal notification instead.
            let refreshed = try await rpc(method: "thread/read", params: [
                "threadId": threadID,
                "includeTurns": true,
            ])
            observation = try Self.reconciliation(
                from: refreshed,
                expectedThreadID: threadID,
                expectedDynamicToolNames: Set(options.dynamicTools.map(\.name))
            )
            if observation.status != .running {
                activeTurnByTask.removeValue(forKey: taskID)
            }
        } else {
            activeTurnByTask.removeValue(forKey: taskID)
        }
        return observation
    }

    func threadID(forTaskID taskID: String) -> String? { taskThreads[taskID] }

    func activeTurnID(forTaskID taskID: String) -> String? { activeTurnByTask[taskID] }

    func taskThreadMappings() -> [String: String] { taskThreads }

    func respondToServerRequest(
        _ requestID: CodexTaskServerRequestID,
        resultJSON: Data
    ) async throws {
        guard resultJSON.count <= configuration.maximumOutboundMessageBytes else {
            throw CodexTaskRuntimeError.outboundMessageTooLarge
        }
        let result = try Self.decodeBoundedJSON(
            resultJSON,
            maximumBytes: configuration.maximumOutboundMessageBytes
        )
        let message = try encodeMessage(["id": requestID.jsonValue, "result": result])
        try claimLiveServerRequest(requestID)
        let sendGeneration = generation
        guard let activeTransport else {
            throw CodexTaskRuntimeError.processUnavailable
        }
        do {
            try await activeTransport.send(message, generation: sendGeneration)
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
        } catch {
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            await resetRuntime(
                failure: CodexTaskRuntimeError.transportFailure,
                stopTransport: true,
                emitMethod: "$runtime/transport-failed"
            )
            throw CodexTaskRuntimeError.transportFailure
        }
    }

    func rejectServerRequest(
        _ requestID: CodexTaskServerRequestID,
        code: Int = -32_000,
        message: String
    ) async throws {
        guard message.utf8.count <= 1_024 else { throw CodexTaskRuntimeError.invalidInput }
        let payload: [String: Any] = [
            "id": requestID.jsonValue,
            "error": ["code": code, "message": message],
        ]
        let encoded = try encodeMessage(payload)
        try claimLiveServerRequest(requestID)
        let sendGeneration = generation
        guard let activeTransport else {
            throw CodexTaskRuntimeError.processUnavailable
        }
        do {
            try await activeTransport.send(encoded, generation: sendGeneration)
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
        } catch {
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            await resetRuntime(
                failure: CodexTaskRuntimeError.transportFailure,
                stopTransport: true,
                emitMethod: "$runtime/transport-failed"
            )
            throw CodexTaskRuntimeError.transportFailure
        }
    }

    private func performStartup() async throws {
        try Task.checkCancellation()
        guard !ready else { return }
        try validateConfiguration()
        do {
            try executableValidator.validate(executableURL: configuration.executableURL)
        } catch {
            throw CodexTaskRuntimeError.executableRejected
        }

        let currentGeneration = UUID()
        generation = currentGeneration
        expectedInboundSequence = 0
        let environment = Self.minimumEnvironment(codexHomeURL: configuration.codexHomeURL)
        let probeResult: CodexSharedDaemonProbeResult
        if configuration.prefersSharedDaemon {
            probeResult = await sharedDaemonProbe.probe(
                executableURL: configuration.executableURL,
                codexHomeURL: configuration.codexHomeURL,
                environment: environment,
                timeout: configuration.sharedDaemonProbeTimeout
            )
        } else {
            probeResult = .unavailable
        }
        try Task.checkCancellation()
        guard generation == currentGeneration else {
            throw CodexTaskRuntimeError.requestCancelled
        }

        let standaloneLaunch = CodexAppServerLaunch(
            generation: currentGeneration,
            executableURL: configuration.executableURL,
            arguments: ["app-server", "--listen", "stdio://", "--strict-config"],
            environment: environment,
            maximumInboundLineBytes: configuration.maximumInboundLineBytes,
            maximumBufferedInboundBytes: configuration.maximumBufferedInboundBytes,
            maximumOutboundMessageBytes: configuration.maximumOutboundMessageBytes,
            maximumStandardErrorBytes: configuration.maximumStandardErrorBytes,
            terminationGracePeriod: configuration.terminationGracePeriod
        )
        var selectedTransport: any CodexAppServerTransporting = transport
        var selectedLaunch = standaloneLaunch
        var selectedSharedDaemon = false
        if case .compatible(let endpoint) = probeResult {
            selectedTransport = sharedDaemonTransport
            selectedLaunch = CodexAppServerLaunch(
                generation: currentGeneration,
                executableURL: endpoint.executableURL,
                arguments: [
                    "app-server", "proxy", "--sock", endpoint.socketURL.path,
                ],
                environment: environment,
                maximumInboundLineBytes: configuration.maximumInboundLineBytes,
                maximumBufferedInboundBytes: configuration.maximumBufferedInboundBytes,
                maximumOutboundMessageBytes: configuration.maximumOutboundMessageBytes,
                maximumStandardErrorBytes: configuration.maximumStandardErrorBytes,
                terminationGracePeriod: configuration.terminationGracePeriod
            )
            selectedSharedDaemon = true
        }

        let events: AsyncStream<CodexAppServerTransportEvent>
        do {
            events = try await selectedTransport.start(selectedLaunch)
        } catch {
            guard selectedSharedDaemon else {
                throw CodexTaskRuntimeError.processUnavailable
            }
            guard !Task.isCancelled, generation == currentGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            // The daemon can disappear between the read-only version probe and
            // connection. Fall back only when the WebSocket transport itself
            // could not start; protocol or RPC failures after connection still
            // fail closed instead of being hidden by a second execution path.
            selectedTransport = transport
            selectedLaunch = standaloneLaunch
            selectedSharedDaemon = false
            emitLifecycle("$runtime/shared-daemon-fallback")
            do {
                events = try await selectedTransport.start(selectedLaunch)
            } catch {
                throw CodexTaskRuntimeError.processUnavailable
            }
        }
        guard generation == currentGeneration else {
            await selectedTransport.stop()
            throw CodexTaskRuntimeError.requestCancelled
        }
        activeTransport = selectedTransport
        usingSharedDaemon = selectedSharedDaemon
        transportActive = true
        do {
            try Task.checkCancellation()
        } catch {
            await resetRuntime(
                failure: CodexTaskRuntimeError.requestCancelled,
                stopTransport: true,
                emitMethod: "$runtime/start-cancelled"
            )
            throw CodexTaskRuntimeError.requestCancelled
        }
        eventConsumerTask?.cancel()
        eventConsumerTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleTransportEvent(event, generation: currentGeneration)
            }
        }

        do {
            try Task.checkCancellation()
            _ = try await rpc(method: "initialize", params: [
                "clientInfo": [
                    "name": "aurora",
                    "title": "Aurora",
                    "version": "1.0",
                ],
                // Aurora's host-owned effect receipt is supplied through the
                // app-server `dynamicTools` field on thread/start. The field
                // is capability-gated by current Codex app-server builds; a
                // null capability set makes the shared ChatGPT daemon reject
                // the task before turn/start.
                "capabilities": [
                    "experimentalApi": true,
                ],
            ])
            try Task.checkCancellation()
            try await sendNotification(method: "initialized", params: [:])
            try await refreshAndRequireChatGPTAccount()
            try Task.checkCancellation()
            guard generation == currentGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            ready = true
            emitLifecycle("$runtime/ready", params: [
                "authentication_type": "chatgpt",
                "plan_type": accountSnapshot?.planType ?? "unknown",
                "transport": usingSharedDaemon ? "shared_daemon" : "standalone_stdio",
            ])
        } catch {
            guard generation == currentGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            await resetRuntime(
                failure: error,
                stopTransport: true,
                emitMethod: "$runtime/start-failed"
            )
            throw error
        }
    }

    private func beginTurn(
        taskID: String,
        threadID: String,
        input: String,
        reasoningEffort: CodexTaskReasoningEffort? = nil
    ) async throws -> CodexTaskHandle {
        guard activeTurnByTask[taskID] == nil else { throw CodexTaskRuntimeError.turnAlreadyActive }
        var params: [String: Any] = [
            "threadId": threadID,
            "clientUserMessageId": Self.makeClientMessageID(),
            "input": Self.textInput(input),
        ]
        if let reasoningEffort = reasoningEffort ?? threadOptions[threadID]?.reasoningEffort {
            params["effort"] = reasoningEffort.rawValue
        }
        let result = try await rpc(method: "turn/start", params: params)
        let turnID = try Self.turnID(from: result)
        if !recentlyCompletedTurnIDs.contains(turnID) {
            activeTurnByTask[taskID] = turnID
        }
        return CodexTaskHandle(taskID: taskID, threadID: threadID, turnID: turnID)
    }

    private func refreshAndRequireChatGPTAccount() async throws {
        let accountData = try await rpc(method: "account/read", params: [:])
        let accountResult = try Self.jsonObject(accountData)
        guard accountResult["requiresOpenaiAuth"] as? Bool == true,
              let account = accountResult["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else {
            accountSnapshot = nil
            throw CodexTaskRuntimeError.chatGPTLoginRequired
        }
        accountSnapshot = CodexTaskAccountSnapshot(
            authenticationType: "chatgpt",
            planType: account["planType"] as? String
        )
        verifiedChatGPTAccountGeneration = generation
    }

    /// Uses the startup-authenticated account for the lifetime of this exact
    /// transport. `account/updated`, disconnects, protocol failures, and
    /// explicit restart all invalidate the generation before another task can
    /// proceed.
    private func requireVerifiedChatGPTAccount() throws {
        guard ready,
              verifiedChatGPTAccountGeneration == generation,
              accountSnapshot?.authenticationType == "chatgpt" else {
            throw CodexTaskRuntimeError.chatGPTLoginRequired
        }
    }

    private func ensureThreadLoaded(_ threadID: String) async throws {
        guard !loadedThreadIDs.contains(threadID) else { return }
        if let expectedDirectory = preservedThreadWorkingDirectories[threadID] {
            try await resumePreservingThreadSettings(
                threadID: threadID,
                expectedWorkingDirectory: expectedDirectory
            )
            return
        }
        guard let options = threadOptions[threadID] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        var params: [String: Any] = [
            "threadId": threadID,
            "modelProvider": "openai",
            "approvalPolicy": options.approvalPolicy.rawValue,
            "approvalsReviewer": "user",
            "sandbox": options.sandboxMode.rawValue,
        ]
        if let model = options.model { params["model"] = model }
        if let workingDirectory = options.workingDirectory {
            params["cwd"] = workingDirectory.standardizedFileURL.path
        }
        if let instructions = options.developerInstructions {
            params["developerInstructions"] = instructions
        }
        let result = try await rpc(method: "thread/resume", params: params)
        do {
            try Self.requireSecurityBoundary(in: result, expected: options)
        } catch {
            await resetRuntime(
                failure: error,
                stopTransport: true,
                emitMethod: "$runtime/thread-security-mismatch"
            )
            throw error
        }
        guard try Self.threadID(from: result) == threadID else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        loadedThreadIDs.insert(threadID)
    }

    private func resumePreservingThreadSettings(
        threadID: String,
        expectedWorkingDirectory: URL
    ) async throws {
        let result = try await rpc(method: "thread/resume", params: [
            "threadId": threadID,
        ])
        guard try Self.threadID(from: result) == threadID else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let response = try Self.decodeObject(
            result,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        guard let returnedDirectory = response["cwd"] as? String,
              returnedDirectory.hasPrefix("/"),
              returnedDirectory.utf8.count <= 4_096,
              !returnedDirectory.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        guard URL(fileURLWithPath: returnedDirectory).standardizedFileURL.path
                == expectedWorkingDirectory.path else {
            throw CodexTaskRuntimeError.threadWorkingDirectoryChanged
        }
        loadedThreadIDs.insert(threadID)
    }

    private func requireUnarchivedPersistentThread(
        threadID: String,
        expectedWorkingDirectory: URL
    ) async throws {
        var cursor: String?
        var seenCursors = Set<String>()
        // Project selection is normally followed immediately by this check.
        // Twenty protocol-maximal pages leaves bounded room for unusually
        // large projects without permitting an unbounded server walk.
        for _ in 0..<20 {
            var params: [String: Any] = [
                "limit": 100,
                "archived": false,
                "cwd": expectedWorkingDirectory.path,
                "modelProviders": [],
                "sourceKinds": [
                    "cli", "vscode", "exec", "appServer", "subAgent",
                    "subAgentReview", "subAgentCompact", "subAgentThreadSpawn",
                    "subAgentOther", "unknown",
                ],
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": false,
            ]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc(method: "thread/list", params: params)
            let object = try Self.decodeObject(
                result,
                maximumBytes: configuration.maximumInboundLineBytes
            )
            guard let rawThreads = object["data"] as? [[String: Any]],
                  rawThreads.count <= 100 else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            for rawThread in rawThreads {
                let summary = try Self.desktopThreadSummary(rawThread)
                guard summary.threadID == threadID else { continue }
                guard summary.workingDirectory.path == expectedWorkingDirectory.path else {
                    throw CodexTaskRuntimeError.threadWorkingDirectoryChanged
                }
                guard !summary.ephemeral else {
                    throw CodexTaskRuntimeError.threadUnavailable
                }
                return
            }
            guard let nextCursor = try Self.optionalBoundedProtocolString(
                object["nextCursor"],
                maximumBytes: 4_096
            ) else {
                throw CodexTaskRuntimeError.threadUnavailable
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            cursor = nextCursor
        }
        throw CodexTaskRuntimeError.threadUnavailable
    }

    private func rawProjectTurnState(
        threadID: String,
        expectedWorkingDirectory: URL
    ) async throws -> RawProjectTurnState {
        let result = try await rpc(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": true,
        ])
        let object = try Self.decodeObject(
            result,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        guard let thread = object["thread"] as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let summary = try Self.desktopThreadSummary(thread)
        guard summary.threadID == threadID else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        guard summary.workingDirectory.path == expectedWorkingDirectory.path else {
            throw CodexTaskRuntimeError.threadWorkingDirectoryChanged
        }
        guard !summary.ephemeral,
              let turns = thread["turns"] as? [[String: Any]] else {
            throw CodexTaskRuntimeError.threadUnavailable
        }
        guard let latestTurn = turns.last else { return .inactive }
        let turnID = try Self.requiredString("id", in: latestTurn)
        try Self.validateOpaqueID(turnID)
        switch latestTurn["status"] as? String {
        case "inProgress":
            return .active(turnID: turnID)
        case "completed", "interrupted", "failed":
            return .inactive
        default:
            throw CodexTaskRuntimeError.protocolViolation
        }
    }

    private func synchronizeRawTurnState(
        _ state: RawProjectTurnState,
        taskID: String
    ) {
        switch state {
        case .inactive:
            activeTurnByTask.removeValue(forKey: taskID)
        case .active(let turnID):
            activeTurnByTask[taskID] = turnID
        }
    }

    private func synchronizeReconciledTurn(
        _ observation: CodexDelegateTaskReconciliation,
        taskID: String
    ) {
        if observation.status == .running,
           let turnID = observation.latestTurnID {
            activeTurnByTask[taskID] = turnID
        } else {
            activeTurnByTask.removeValue(forKey: taskID)
        }
    }

    private func performRawProjectSend(
        taskID: String,
        threadID: String,
        input: String,
        clientMessageID: String,
        state: RawProjectTurnState
    ) async throws -> CodexTaskHandle {
        switch state {
        case .inactive:
            let params: [String: Any] = [
                "threadId": threadID,
                "clientUserMessageId": clientMessageID,
                "input": Self.textInput(input),
            ]
            // Intentionally no effort/model/instructions override: this is a
            // user-selected Codex conversation, not an Aurora-owned worker.
            let result = try await rpc(method: "turn/start", params: params)
            let turnID = try Self.turnID(from: result)
            if !recentlyCompletedTurnIDs.contains(turnID) {
                activeTurnByTask[taskID] = turnID
            }
            return CodexTaskHandle(taskID: taskID, threadID: threadID, turnID: turnID)

        case .active(let turnID):
            let result = try await rpc(method: "turn/steer", params: [
                "threadId": threadID,
                "expectedTurnId": turnID,
                "clientUserMessageId": clientMessageID,
                "input": Self.textInput(input),
            ])
            let returnedTurnID = try Self.requiredString("turnId", inJSON: result)
            guard returnedTurnID == turnID else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            return CodexTaskHandle(taskID: taskID, threadID: threadID, turnID: turnID)
        }
    }

    private func rpc(method: String, params: [String: Any]) async throws -> Data {
        guard transportActive else { throw CodexTaskRuntimeError.processUnavailable }
        let requestGeneration = generation
        let requestID = nextRequestID
        guard requestID < Int64.max else { throw CodexTaskRuntimeError.protocolViolation }
        nextRequestID += 1
        let message = try encodeMessage(["method": method, "id": requestID, "params": params])

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRPCs[requestID] = PendingRPC(
                    method: method,
                    generation: requestGeneration,
                    continuation: continuation,
                    timeoutTask: nil
                )
                let timeout = configuration.requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    await self?.timeOutRPC(requestID)
                }
                pendingRPCs[requestID]?.timeoutTask = timeoutTask
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendRPC(
                        message,
                        requestID: requestID,
                        generation: requestGeneration
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failRPCAndReset(
                    requestID,
                    generation: requestGeneration,
                    failure: .requestCancelled
                )
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        let message = try encodeMessage(["method": method, "params": params])
        let sendGeneration = generation
        guard let activeTransport else {
            throw CodexTaskRuntimeError.processUnavailable
        }
        do {
            try await activeTransport.send(message, generation: sendGeneration)
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
        } catch {
            guard generation == sendGeneration else {
                throw CodexTaskRuntimeError.requestCancelled
            }
            throw CodexTaskRuntimeError.transportFailure
        }
    }

    private func sendRPC(
        _ message: Data,
        requestID: Int64,
        generation requestGeneration: UUID
    ) async {
        guard generation == requestGeneration,
              pendingRPCs[requestID]?.generation == requestGeneration,
              let activeTransport else { return }
        do {
            try await activeTransport.send(message, generation: requestGeneration)
        } catch {
            guard generation == requestGeneration else { return }
            await failRPCAndReset(
                requestID,
                generation: requestGeneration,
                failure: .transportFailure
            )
        }
    }

    private func handleTransportEvent(
        _ event: CodexAppServerTransportEvent,
        generation eventGeneration: UUID
    ) async {
        guard eventGeneration == generation else { return }
        switch event {
        case .line(let sequence, let line):
            guard sequence == expectedInboundSequence,
                  expectedInboundSequence < UInt64.max else {
                await resetRuntime(
                    failure: CodexTaskRuntimeError.inboundMessageTooLarge,
                    stopTransport: true,
                    emitMethod: "$runtime/inbound-sequence-gap"
                )
                return
            }
            expectedInboundSequence += 1
            do {
                try handleLine(line.data)
            } catch {
                let method: String
                if let runtimeError = error as? CodexTaskRuntimeError,
                   runtimeError == .chatGPTLoginRequired {
                    method = "$runtime/auth-changed"
                } else {
                    method = "$runtime/protocol-failed"
                }
                await resetRuntime(
                    failure: error,
                    stopTransport: true,
                    emitMethod: method
                )
            }
        case .inboundOverflow:
            await resetRuntime(
                failure: CodexTaskRuntimeError.inboundMessageTooLarge,
                stopTransport: true,
                emitMethod: "$runtime/inbound-overflow"
            )
        case .protocolFailure:
            await resetRuntime(
                failure: CodexTaskRuntimeError.protocolViolation,
                stopTransport: true,
                emitMethod: "$runtime/transport-protocol-failed"
            )
        case .terminated(let exitCode, let expected, let standardErrorOverflowed):
            guard transportActive else { return }
            let failure = CodexTaskRuntimeError.processTerminated(exitCode: exitCode)
            await resetRuntime(
                failure: failure,
                stopTransport: false,
                emitMethod: expected ? "$runtime/stopped" : "$runtime/terminated"
            )
            emitLifecycle("$runtime/process-exit", params: [
                "exit_code": Int(exitCode),
                "expected": expected,
                "standard_error_overflowed": standardErrorOverflowed,
            ])
        }
    }

    private func handleLine(_ line: Data) throws {
        guard !line.isEmpty, line.count <= configuration.maximumInboundLineBytes else {
            throw CodexTaskRuntimeError.inboundMessageTooLarge
        }
        let raw = try Self.decodeBoundedJSON(
            line,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        guard let message = raw as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }

        if message["method"] == nil, let requestID = Self.integerRequestID(message["id"]) {
            guard var pending = pendingRPCs.removeValue(forKey: requestID) else { return }
            pending.timeoutTask?.cancel()
            pending.timeoutTask = nil
            if let errorObject = message["error"] as? [String: Any] {
                let code = (errorObject["code"] as? NSNumber)?.intValue ?? -32_000
                let message = Self.boundedString(errorObject["message"] as? String, maximumBytes: 1_024)
                pending.continuation.resume(throwing: CodexTaskRuntimeError.serverError(
                    code: code,
                    message: message
                ))
                return
            }
            guard let result = message["result"] else {
                pending.continuation.resume(throwing: CodexTaskRuntimeError.protocolViolation)
                return
            }
            let data = try Self.canonicalJSONData(
                result,
                maximumBytes: configuration.maximumInboundLineBytes
            )
            pending.continuation.resume(returning: data)
            return
        }

        guard let method = message["method"] as? String,
              !method.isEmpty,
              method.utf8.count <= 256 else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let params: [String: Any]
        if message["params"] == nil || message["params"] is NSNull {
            params = [:]
        } else if let object = message["params"] as? [String: Any] {
            params = object
        } else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let paramsJSON = try Self.canonicalJSONData(
            params,
            maximumBytes: configuration.maximumInboundLineBytes
        )
        let threadID = Self.eventThreadID(params)
        let turnID = Self.eventTurnID(params)
        if let threadID { try Self.validateOpaqueID(threadID) }
        if let turnID { try Self.validateOpaqueID(turnID) }
        let taskID = threadID.flatMap { threadTasks[$0] }
        if method == "thread/settings/updated",
           let threadID,
           let options = threadOptions[threadID] {
            guard let settings = params["threadSettings"] as? [String: Any] else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            try Self.requireSecurityBoundary(
                in: settings,
                expected: options,
                sandboxKey: "sandboxPolicy"
            )
        }
        if method == "account/updated" {
            if params["authMode"] as? String == "chatgpt" {
                accountSnapshot = CodexTaskAccountSnapshot(
                    authenticationType: "chatgpt",
                    planType: params["planType"] as? String
                )
                verifiedChatGPTAccountGeneration = generation
            } else {
                accountSnapshot = nil
                verifiedChatGPTAccountGeneration = nil
                throw CodexTaskRuntimeError.chatGPTLoginRequired
            }
        }
        updateTaskState(method: method, taskID: taskID, threadID: threadID, turnID: turnID)

        if message.keys.contains("id") {
            guard let requestID = Self.serverRequestID(message["id"]) else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            guard pendingServerRequests.count < configuration.maximumPendingServerRequests else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            guard pendingServerRequests[requestID] == nil else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            pendingServerRequests[requestID] = PendingServerRequest(
                method: method,
                taskID: taskID,
                threadID: threadID,
                turnID: turnID
            )
            emit(CodexTaskRuntimeEvent(
                kind: .serverRequest,
                method: method,
                taskID: taskID,
                threadID: threadID,
                turnID: turnID,
                serverRequestID: requestID,
                paramsJSON: paramsJSON
            ))
        } else {
            emit(CodexTaskRuntimeEvent(
                kind: .notification,
                method: method,
                taskID: taskID,
                threadID: threadID,
                turnID: turnID,
                serverRequestID: nil,
                paramsJSON: paramsJSON
            ))
        }
    }

    private func updateTaskState(
        method: String,
        taskID: String?,
        threadID: String?,
        turnID: String?
    ) {
        guard let taskID else { return }
        if method == "turn/started", let turnID {
            activeTurnByTask[taskID] = turnID
        } else if method == "turn/completed", let turnID {
            if activeTurnByTask[taskID] == turnID {
                activeTurnByTask.removeValue(forKey: taskID)
            }
            recentlyCompletedTurnIDs.append(turnID)
            if recentlyCompletedTurnIDs.count > 128 {
                recentlyCompletedTurnIDs.removeFirst(recentlyCompletedTurnIDs.count - 96)
            }
            expireServerRequests(taskID: taskID, turnID: turnID)
        } else if method == "thread/deleted", let threadID {
            taskThreads.removeValue(forKey: taskID)
            threadTasks.removeValue(forKey: threadID)
            threadOptions.removeValue(forKey: threadID)
            preservedThreadWorkingDirectories.removeValue(forKey: threadID)
            loadedThreadIDs.remove(threadID)
            activeTurnByTask.removeValue(forKey: taskID)
            expireServerRequests(taskID: taskID, turnID: nil)
        }
    }

    private func claimLiveServerRequest(_ requestID: CodexTaskServerRequestID) throws {
        guard let pending = pendingServerRequests[requestID] else {
            throw CodexTaskRuntimeError.unknownServerRequest
        }
        if let taskID = pending.taskID {
            guard let threadID = pending.threadID,
                  taskThreads[taskID] == threadID else {
                pendingServerRequests.removeValue(forKey: requestID)
                throw CodexTaskRuntimeError.unknownServerRequest
            }
            if let turnID = pending.turnID,
               activeTurnByTask[taskID] != turnID {
                pendingServerRequests.removeValue(forKey: requestID)
                throw CodexTaskRuntimeError.unknownServerRequest
            }
        }
        pendingServerRequests.removeValue(forKey: requestID)
    }

    private func expireServerRequests(taskID: String, turnID: String?) {
        pendingServerRequests = pendingServerRequests.filter { _, request in
            guard request.taskID == taskID else { return true }
            guard let turnID else { return false }
            return request.turnID != turnID
        }
    }

    private func timeOutRPC(_ requestID: Int64) async {
        guard let pending = pendingRPCs.removeValue(forKey: requestID) else { return }
        guard generation == pending.generation else {
            pending.continuation.resume(throwing: CodexTaskRuntimeError.requestCancelled)
            return
        }
        pending.continuation.resume(throwing: CodexTaskRuntimeError.requestTimedOut(
            method: pending.method
        ))
        await resetRuntime(
            failure: CodexTaskRuntimeError.requestTimedOut(method: pending.method),
            stopTransport: true,
            emitMethod: "$runtime/request-timeout"
        )
    }

    private func failRPCAndReset(
        _ requestID: Int64,
        generation requestGeneration: UUID,
        failure: CodexTaskRuntimeError
    ) async {
        guard generation == requestGeneration,
              pendingRPCs[requestID]?.generation == requestGeneration,
              let pending = pendingRPCs.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: failure)
        await resetRuntime(
            failure: failure,
            stopTransport: true,
            emitMethod: "$runtime/request-failed"
        )
    }

    private func resetRuntime(
        failure: Error,
        stopTransport: Bool,
        emitMethod: String
    ) async {
        let oldConsumer = eventConsumerTask
        let transportToStop = activeTransport
        eventConsumerTask = nil
        activeTransport = nil
        usingSharedDaemon = false
        generation = UUID()
        expectedInboundSequence = 0
        ready = false
        transportActive = false
        loadedThreadIDs.removeAll()
        activeTurnByTask.removeAll()
        pendingServerRequests.removeAll()
        accountSnapshot = nil
        verifiedChatGPTAccountGeneration = nil
        let pending = pendingRPCs.values
        pendingRPCs.removeAll()
        for item in pending {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: failure)
        }
        oldConsumer?.cancel()
        emitLifecycle(emitMethod)
        if stopTransport {
            if let transportStopTask {
                await transportStopTask.value
            } else if let transportToStop {
                let token = UUID()
                let task = Task { await transportToStop.stop() }
                transportStopToken = token
                transportStopTask = task
                await task.value
                if transportStopToken == token {
                    transportStopTask = nil
                    transportStopToken = nil
                }
            }
        }
    }

    private func beginExclusiveTaskOperation(_ taskID: String) throws {
        guard busyTaskIDs.insert(taskID).inserted else { throw CodexTaskRuntimeError.taskBusy }
    }

    private func bind(
        taskID: String,
        to threadID: String,
        options: CodexTaskThreadOptions
    ) throws {
        if let existingThread = taskThreads[taskID], existingThread != threadID {
            throw CodexTaskRuntimeError.taskAlreadyExists
        }
        if let existingTask = threadTasks[threadID], existingTask != taskID {
            throw CodexTaskRuntimeError.protocolViolation
        }
        if let existingOptions = threadOptions[threadID], existingOptions != options {
            throw CodexTaskRuntimeError.protocolViolation
        }
        taskThreads[taskID] = threadID
        threadTasks[threadID] = taskID
        threadOptions[threadID] = options
    }

    private func bindPreservingThreadSettings(
        taskID: String,
        to threadID: String,
        expectedWorkingDirectory: URL
    ) throws {
        try validatePreservingThreadBinding(
            taskID: taskID,
            threadID: threadID,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
        taskThreads[taskID] = threadID
        threadTasks[threadID] = taskID
        preservedThreadWorkingDirectories[threadID] = expectedWorkingDirectory
    }

    private func validatePreservingThreadBinding(
        taskID: String,
        threadID: String,
        expectedWorkingDirectory: URL
    ) throws {
        if let existingThread = taskThreads[taskID], existingThread != threadID {
            throw CodexTaskRuntimeError.taskAlreadyExists
        }
        if let existingTask = threadTasks[threadID], existingTask != taskID {
            throw CodexTaskRuntimeError.protocolViolation
        }
        if let existingDirectory = preservedThreadWorkingDirectories[threadID],
           existingDirectory.path != expectedWorkingDirectory.path {
            throw CodexTaskRuntimeError.threadWorkingDirectoryChanged
        }
    }

    private func validateConfiguration() throws {
        guard configuration.requestTimeout >= 1,
              configuration.requestTimeout <= 120,
              configuration.maximumInboundLineBytes >= 4_096,
              configuration.maximumInboundLineBytes <= 16 * 1_024 * 1_024,
              configuration.maximumBufferedInboundBytes >= configuration.maximumInboundLineBytes,
              configuration.maximumBufferedInboundBytes <= 64 * 1_024 * 1_024,
              configuration.maximumOutboundMessageBytes >= 4_096,
              configuration.maximumOutboundMessageBytes <= 2 * 1_024 * 1_024,
              configuration.maximumStandardErrorBytes >= 1_024,
              configuration.maximumStandardErrorBytes <= 1 * 1_024 * 1_024,
              configuration.maximumInputBytes >= 1_024,
              configuration.maximumInputBytes <= configuration.maximumOutboundMessageBytes,
              configuration.maximumDeveloperInstructionBytes >= 1_024,
              configuration.maximumDeveloperInstructionBytes <= configuration.maximumOutboundMessageBytes,
              configuration.maximumPendingServerRequests >= 1,
              configuration.maximumPendingServerRequests <= 128,
              configuration.terminationGracePeriod >= 0.1,
              configuration.terminationGracePeriod <= 5,
              configuration.sharedDaemonProbeTimeout >= 0.25,
              configuration.sharedDaemonProbeTimeout <= 5,
              configuration.codexHomeURL.isFileURL,
              configuration.codexHomeURL.path.hasPrefix("/") else {
            throw CodexTaskRuntimeError.invalidConfiguration
        }
    }

    private func validateInput(_ input: String) throws {
        guard !input.isEmpty,
              input.utf8.count <= configuration.maximumInputBytes,
              !input.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CodexTaskRuntimeError.invalidInput
        }
    }

    private func validate(_ options: CodexTaskThreadOptions) throws {
        if let model = options.model {
            guard !model.isEmpty,
                  model.utf8.count <= 128,
                  model.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        if let directory = options.workingDirectory {
            guard directory.isFileURL,
                  directory.standardizedFileURL.path.hasPrefix("/"),
                  !directory.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        if let instructions = options.developerInstructions {
            guard !instructions.isEmpty,
                  instructions.utf8.count <= configuration.maximumDeveloperInstructionBytes,
                  !instructions.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        if let threadName = options.threadName {
            guard !threadName.isEmpty,
                  threadName.utf8.count <= 512,
                  threadName == threadName.trimmingCharacters(in: .whitespacesAndNewlines),
                  !threadName.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        guard options.dynamicTools.count <= 8 else {
            throw CodexTaskRuntimeError.invalidInput
        }
        var toolNames = Set<String>()
        for tool in options.dynamicTools {
            guard Self.isValidDynamicToolIdentifier(tool.name),
                  toolNames.insert(tool.name).inserted,
                  !tool.description.isEmpty,
                  tool.description.utf8.count <= 2_048,
                  !tool.description.unicodeScalars.contains(where: { $0.value == 0 }),
                  tool.inputSchema.properties.count <= 32,
                  tool.inputSchema.required.count <= tool.inputSchema.properties.count,
                  Set(tool.inputSchema.required).count == tool.inputSchema.required.count,
                  tool.inputSchema.required.allSatisfy({
                      tool.inputSchema.properties[$0] != nil
                  }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
            for (propertyName, property) in tool.inputSchema.properties {
                guard Self.isValidDynamicToolIdentifier(propertyName) else {
                    throw CodexTaskRuntimeError.invalidInput
                }
                if let description = property.description {
                    guard !description.isEmpty,
                          description.utf8.count <= 1_024,
                          !description.unicodeScalars.contains(where: { $0.value == 0 }) else {
                        throw CodexTaskRuntimeError.invalidInput
                    }
                }
                let minimum = property.minimumLength ?? 0
                let maximum = property.maximumLength ?? 4_096
                guard minimum >= 0, maximum >= minimum, maximum <= 4_096 else {
                    throw CodexTaskRuntimeError.invalidInput
                }
                if let values = property.allowedValues {
                    guard !values.isEmpty,
                          values.count <= 32,
                          Set(values).count == values.count,
                          values.allSatisfy({ value in
                              !value.isEmpty
                                  && value.utf8.count <= 256
                                  && value.count >= minimum
                                  && value.count <= maximum
                                  && !value.unicodeScalars.contains(where: { $0.value == 0 })
                          }) else {
                        throw CodexTaskRuntimeError.invalidInput
                    }
                }
            }
        }
        if !options.dynamicTools.isEmpty {
            let maximumSchemaBytes = min(64 * 1_024, configuration.maximumOutboundMessageBytes / 2)
            guard JSONSerialization.isValidJSONObject(
                options.dynamicTools.map(Self.dynamicToolJSON)
            ), let data = try? JSONSerialization.data(
                withJSONObject: options.dynamicTools.map(Self.dynamicToolJSON),
                options: [.sortedKeys]
            ), data.count <= maximumSchemaBytes else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
    }

    private static func isValidDynamicToolIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5a)
                || scalar.value == 0x5f
                || (scalar.value >= 0x61 && scalar.value <= 0x7a)
                || scalar.value == 0x2d
        }
    }

    private static func dynamicToolJSON(_ tool: CodexTaskDynamicToolSpec) -> [String: Any] {
        let properties = tool.inputSchema.properties.reduce(
            into: [String: Any]()
        ) { result, entry in
            let (name, property) = entry
            var schema: [String: Any] = ["type": "string"]
            if let description = property.description {
                schema["description"] = description
            }
            if let values = property.allowedValues {
                schema["enum"] = values
            }
            if let minimum = property.minimumLength {
                schema["minLength"] = minimum
            }
            if let maximum = property.maximumLength {
                schema["maxLength"] = maximum
            }
            result[name] = schema
        }
        let inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": tool.inputSchema.required,
            "additionalProperties": false,
        ]
        var value: [String: Any] = [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "inputSchema": inputSchema,
        ]
        if tool.deferLoading {
            value["deferLoading"] = true
        }
        return value
    }

    private func encodeMessage(_ object: [String: Any]) throws -> Data {
        let encoded = try Self.canonicalJSONData(
            object,
            maximumBytes: configuration.maximumOutboundMessageBytes - 1
        )
        guard encoded.count + 1 <= configuration.maximumOutboundMessageBytes else {
            throw CodexTaskRuntimeError.outboundMessageTooLarge
        }
        var line = encoded
        line.append(0x0a)
        return line
    }

    private func emitLifecycle(_ method: String, params: [String: Any] = [:]) {
        let data = (try? Self.canonicalJSONData(
            params,
            maximumBytes: configuration.maximumInboundLineBytes
        )) ?? Data("{}".utf8)
        emit(CodexTaskRuntimeEvent(
            kind: .lifecycle,
            method: method,
            taskID: nil,
            threadID: nil,
            turnID: nil,
            serverRequestID: nil,
            paramsJSON: data
        ))
    }

    private func emit(_ event: CodexTaskRuntimeEvent) {
        guard let eventHandler else { return }
        // Deliver synchronously from the actor. This gives the event boundary
        // natural backpressure instead of creating an unbounded queue of
        // callback closures when the app-server streams faster than a client
        // can consume.
        eventHandler(event)
    }

    private static func textInput(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "text_elements": []]]
    }

    private static func makeClientMessageID() -> String {
        "aurora_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private static func minimumEnvironment(codexHomeURL: URL) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "HOME": home,
            "CODEX_HOME": codexHomeURL.standardizedFileURL.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "RUST_LOG": "error",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
    }

    private static func validateTaskID(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 58, 95: return true
                  default: return false
                  }
              }) else {
            throw CodexTaskRuntimeError.invalidTaskIdentifier
        }
    }

    private static func validateOpaqueID(
        _ value: String,
        failure: CodexTaskRuntimeError = .protocolViolation
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7e
              }) else {
            throw failure
        }
    }

    private static func validateThreadQuery(_ query: AuroraCodexThreadQuery) throws {
        guard (1...100).contains(query.limit) else {
            throw CodexTaskRuntimeError.invalidInput
        }
        if let searchTerm = query.searchTerm {
            guard !searchTerm.isEmpty,
                  searchTerm.utf8.count <= 512,
                  !searchTerm.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        if let directory = query.workingDirectory {
            guard directory.isFileURL,
                  directory.standardizedFileURL.path.hasPrefix("/"),
                  !directory.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
        if let cursor = query.cursor {
            guard !cursor.isEmpty,
                  cursor.utf8.count <= 4_096,
                  cursor.unicodeScalars.allSatisfy({
                      $0.value >= 0x20 && $0.value <= 0x7e
                  }) else {
                throw CodexTaskRuntimeError.invalidInput
            }
        }
    }

    private static func validateThreadName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 512,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CodexTaskRuntimeError.invalidInput
        }
    }

    private static func desktopThreadSummary(
        _ object: [String: Any]
    ) throws -> AuroraCodexThreadSummary {
        guard let threadID = object["id"] as? String,
              let preview = object["preview"] as? String,
              preview.utf8.count <= 8_192,
              !preview.unicodeScalars.contains(where: { $0.value == 0 }),
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/"),
              cwd.utf8.count <= 4_096,
              !cwd.unicodeScalars.contains(where: { $0.value == 0 }),
              let ephemeral = object["ephemeral"] as? Bool,
              let statusObject = object["status"] as? [String: Any],
              let status = statusObject["type"] as? String,
              Set(["notLoaded", "idle", "active", "systemError"]).contains(status),
              let createdAt = protocolTimestamp(object["createdAt"]),
              let updatedAt = protocolTimestamp(object["updatedAt"]) else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        try validateOpaqueID(threadID, failure: .invalidThreadIdentifier)
        let name = try optionalBoundedProtocolString(
            object["name"],
            maximumBytes: 512
        )
        let source: String
        if let value = object["source"] as? String,
           value.utf8.count <= 64 {
            source = value
        } else if let value = object["source"] as? [String: Any],
                  value.keys.count == 1,
                  let key = value.keys.first,
                  key.utf8.count <= 64 {
            source = key
        } else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        return AuroraCodexThreadSummary(
            threadID: threadID,
            name: name,
            preview: preview,
            workingDirectory: URL(fileURLWithPath: cwd).standardizedFileURL,
            status: status,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt,
            ephemeral: ephemeral
        )
    }

    private static func protocolTimestamp(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func optionalBoundedProtocolString(
        _ value: Any?,
        maximumBytes: Int
    ) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let string = value as? String,
              string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        return string
    }

    private static func threadID(from data: Data) throws -> String {
        let object = try jsonObject(data)
        guard let thread = object["thread"] as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let value = try requiredString("id", in: thread)
        try validateOpaqueID(value)
        return value
    }

    private static func turnID(from data: Data) throws -> String {
        let object = try jsonObject(data)
        guard let turn = object["turn"] as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let value = try requiredString("id", in: turn)
        try validateOpaqueID(value)
        return value
    }

    private static func reconciliation(
        from data: Data,
        expectedThreadID: String,
        expectedDynamicToolNames: Set<String>
    ) throws -> CodexDelegateTaskReconciliation {
        let object = try jsonObject(data)
        guard let thread = object["thread"] as? [String: Any],
              let returnedThreadID = thread["id"] as? String,
              returnedThreadID == expectedThreadID,
              let turns = thread["turns"] as? [[String: Any]] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        try validateOpaqueID(returnedThreadID, failure: .invalidThreadIdentifier)

        let latestTurn = turns.last
        let latestTurnID: String?
        let status: CodexDelegateTaskObservedStatus?
        var summary: String?
        var effectReceipts: [DelegateTaskEffectReceipt] = []
        if let latestTurn {
            let turnID = try requiredString("id", in: latestTurn)
            latestTurnID = turnID
            switch latestTurn["status"] as? String {
            case "inProgress":
                status = .running
            case "completed":
                status = .completed
            case "interrupted":
                status = .cancelled
            case "failed":
                status = .failed
            default:
                throw CodexTaskRuntimeError.protocolViolation
            }

            let items = latestTurn["items"] as? [[String: Any]] ?? []
            if status != .running {
                effectReceipts = recoveredEffectReceipts(
                    from: items,
                    expectedDynamicToolNames: expectedDynamicToolNames
                )
            }
            let messages = items.compactMap { item -> (String, String?)? in
                guard item["type"] as? String == "agentMessage",
                      let text = item["text"] as? String,
                      !text.isEmpty else { return nil }
                return (text, item["phase"] as? String)
            }
            if status == .failed,
               let error = latestTurn["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                // Failure truth outranks an earlier progress/commentary item.
                summary = message
            } else {
                summary = messages.last(where: { $0.1 == "final_answer" })?.0
                    ?? messages.last?.0
            }
            if status == .cancelled, summary == nil {
                summary = "The task was cancelled."
            }
        } else {
            latestTurnID = nil
            status = nil
        }

        let boundedSummary = summary.map {
            String($0.prefix(8_000))
        }
        let name = (thread["name"] as? String).map { String($0.prefix(500)) }
        let cwd = (thread["cwd"] as? String).flatMap { path -> String? in
            guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return nil }
            return path
        }
        return CodexDelegateTaskReconciliation(
            threadID: returnedThreadID,
            latestTurnID: latestTurnID,
            status: status,
            resultSummary: boundedSummary,
            threadName: name,
            workspacePath: cwd,
            effectReceipts: effectReceipts
        )
    }

    private static func exactProjectReconciliation(
        from data: Data,
        expectedThreadID: String,
        expectedWorkingDirectory: URL
    ) throws -> CodexDelegateTaskReconciliation {
        let object = try jsonObject(data)
        guard let thread = object["thread"] as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        let summary = try desktopThreadSummary(thread)
        guard summary.threadID == expectedThreadID else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        guard !summary.ephemeral else {
            throw CodexTaskRuntimeError.threadUnavailable
        }
        guard summary.workingDirectory.path
                == expectedWorkingDirectory.standardizedFileURL.path else {
            throw CodexTaskRuntimeError.threadWorkingDirectoryChanged
        }
        return try reconciliation(
            from: data,
            expectedThreadID: expectedThreadID,
            expectedDynamicToolNames: []
        )
    }

    /// Recover only protocol-shaped receipts persisted on the exact latest
    /// turn. Agent prose and earlier turns are intentionally not consulted.
    private static func recoveredEffectReceipts(
        from items: [[String: Any]],
        expectedDynamicToolNames: Set<String>
    ) -> [DelegateTaskEffectReceipt] {
        let lastExecutorIndex = items.indices.last(where: {
            isExecutorItem(items[$0])
        })
        let lastNodeReplSurfaceIndex = items.indices.last(where: {
            items[$0]["type"] as? String == "mcpToolCall"
                && items[$0]["server"] as? String == "node_repl"
                && items[$0]["tool"] as? String == "js"
        })
        var seen = Set<String>()
        return items.indices.compactMap { index in
            let item = items[index]
            guard let receipt = recoveredEffectReceipt(
                from: item,
                expectedDynamicToolNames: expectedDynamicToolNames,
                allowReportedEffect: index == lastExecutorIndex,
                allowToolSurfaceObservation: index == lastNodeReplSurfaceIndex
            ) else { return nil }
            let key = "\(receipt.kind.rawValue):\(receipt.receiptID)"
            return seen.insert(key).inserted ? receipt : nil
        }
    }

    private static func recoveredEffectReceipt(
        from item: [String: Any],
        expectedDynamicToolNames: Set<String>,
        allowReportedEffect: Bool,
        allowToolSurfaceObservation: Bool
    ) -> DelegateTaskEffectReceipt? {
        guard let itemID = item["id"] as? String,
              isValidReceiptComponent(itemID, maximumBytes: 256) else {
            return nil
        }
        switch item["type"] as? String {
        case "fileChange":
            guard item["status"] as? String == "completed",
                  let changes = item["changes"] as? [Any],
                  !changes.isEmpty else { return nil }
            return DelegateTaskEffectReceipt(
                kind: .fileChange,
                receiptID: itemID,
                executor: "codex_file_change"
            )

        case "mcpToolCall":
            if allowToolSurfaceObservation,
               let receipt = recoveredToolSurfaceObservation(
                   from: item,
                   itemID: itemID
               ) {
                return receipt
            }
            guard item["status"] as? String == "completed",
                  item["error"] == nil || item["error"] is NSNull,
                  let result = item["result"] as? [String: Any],
                  let structured = result["structuredContent"] as? [String: Any],
                  hasExplicitStructuredEffectReceipt(structured),
                  let server = item["server"] as? String,
                  isValidReceiptComponent(server, maximumBytes: 120),
                  let tool = item["tool"] as? String,
                  isValidReceiptComponent(tool, maximumBytes: 120) else {
                return nil
            }
            return DelegateTaskEffectReceipt(
                kind: .structuredToolResult,
                receiptID: itemID,
                executor: "\(server)/\(tool)"
            )

        case "dynamicToolCall":
            let reportTool = "report_effect_result"
            guard allowReportedEffect,
                  expectedDynamicToolNames.contains(reportTool),
                  item["tool"] as? String == reportTool,
                  item["namespace"] == nil || item["namespace"] is NSNull,
                  item["status"] as? String == "completed",
                  item["success"] as? Bool == true,
                  let arguments = item["arguments"] as? [String: Any],
                  Set(arguments.keys) == Set(["outcome", "observed_postcondition"]),
                  arguments["outcome"] as? String == "verified",
                  let observation = arguments["observed_postcondition"] as? String,
                  !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  observation.utf8.count <= 2_000,
                  !observation.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return nil
            }
            return DelegateTaskEffectReceipt(
                kind: .reportedEffect,
                receiptID: itemID,
                executor: "dynamic/report_effect_result"
            )

        default:
            return nil
        }
    }

    private static func isExecutorItem(_ item: [String: Any]) -> Bool {
        switch item["type"] as? String {
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall",
             "collabAgentToolCall", "webSearch", "imageView", "sleep",
             "imageGeneration":
            return true
        default:
            return false
        }
    }

    /// Legacy threads cannot be retrofitted with a dynamic tool. Preserve a
    /// narrowly shaped, host-authored Computer/Browser Use observation so the
    /// coordinator can reconcile those threads without trusting tool prose.
    private static func recoveredToolSurfaceObservation(
        from item: [String: Any],
        itemID: String
    ) -> DelegateTaskEffectReceipt? {
        guard item["server"] as? String == "node_repl",
              item["tool"] as? String == "js",
              item["status"] as? String == "completed",
              item["error"] == nil || item["error"] is NSNull,
              let result = item["result"] as? [String: Any],
              result["isError"] as? Bool != true,
              let content = result["content"] as? [[String: Any]],
              content.contains(where: hasNonemptyToolContent),
              let metadata = result["_meta"] as? [String: Any],
              let surface = metadata["codex/toolSurface"] as? [String: Any],
              let surfaceKind = surface["kind"] as? String else {
            return nil
        }
        switch surfaceKind {
        case "computerUse":
            guard let app = surface["app"] as? [String: Any],
                  app["kind"] as? String == "appId",
                  let appID = app["appId"] as? String,
                  isValidReceiptComponent(appID, maximumBytes: 256) else {
                return nil
            }
        case "browserUse":
            guard let browserID = surface["browserId"] as? String,
                  isValidReceiptComponent(browserID, maximumBytes: 256) else {
                return nil
            }
        default:
            return nil
        }
        return DelegateTaskEffectReceipt(
            kind: .toolSurfaceObservation,
            receiptID: itemID,
            executor: "node_repl/js"
        )
    }

    private static func hasNonemptyToolContent(_ value: [String: Any]) -> Bool {
        switch value["type"] as? String {
        case "text":
            guard let text = value["text"] as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "image":
            if let data = value["data"] as? String { return !data.isEmpty }
            if let imageURL = value["imageUrl"] as? String { return !imageURL.isEmpty }
            return false
        default:
            return false
        }
    }

    private static func hasExplicitStructuredEffectReceipt(
        _ value: [String: Any]
    ) -> Bool {
        func verifiedPair(_ object: [String: Any]) -> Bool {
            let effectVerified = object["effect_verified"] as? Bool
                ?? object["effectVerified"] as? Bool
                ?? false
            let externalSideEffect = object["external_side_effect"] as? Bool
                ?? object["externalSideEffect"] as? Bool
                ?? false
            return effectVerified && externalSideEffect
        }
        if verifiedPair(value) { return true }
        if let receipt = value["receipt"] as? [String: Any], verifiedPair(receipt) {
            return true
        }
        if let metadata = value["metadata"] as? [String: Any], verifiedPair(metadata) {
            return true
        }
        return false
    }

    private static func isValidReceiptComponent(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func requireSecurityBoundary(
        in data: Data,
        expected: CodexTaskThreadOptions
    ) throws {
        let object = try jsonObject(data)
        try requireSecurityBoundary(in: object, expected: expected, sandboxKey: "sandbox")
    }

    private static func requireSecurityBoundary(
        in object: [String: Any],
        expected: CodexTaskThreadOptions,
        sandboxKey: String
    ) throws {
        guard object["modelProvider"] as? String == "openai",
              object["approvalPolicy"] as? String == expected.approvalPolicy.rawValue,
              object["approvalsReviewer"] as? String == "user",
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/"),
              let sandbox = object[sandboxKey] as? [String: Any],
              sandbox["type"] as? String == expected.sandboxMode.responseType else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        if let expectedModel = expected.model,
           object["model"] as? String != expectedModel {
            throw CodexTaskRuntimeError.protocolViolation
        }
        if let expectedDirectory = expected.workingDirectory {
            let expectedPath = expectedDirectory.standardizedFileURL.path
            guard URL(fileURLWithPath: cwd).standardizedFileURL.path == expectedPath else {
                throw CodexTaskRuntimeError.protocolViolation
            }
        }
        if let activeProfile = object["activePermissionProfile"],
           !(activeProfile is NSNull) {
            throw CodexTaskRuntimeError.protocolViolation
        }

        switch expected.sandboxMode {
        case .dangerFullAccess:
            break

        case .readOnly:
            guard (sandbox["networkAccess"] as? Bool) != true else {
                throw CodexTaskRuntimeError.protocolViolation
            }

        case .workspaceWrite:
            guard (sandbox["networkAccess"] as? Bool) != true else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            for key in ["excludeTmpdirEnvVar", "excludeSlashTmp"] {
                if let value = sandbox[key], !(value is Bool) {
                    throw CodexTaskRuntimeError.protocolViolation
                }
            }
            guard let roots = sandbox["writableRoots"] as? [Any] else {
                throw CodexTaskRuntimeError.protocolViolation
            }
            let allowedRoot = expected.workingDirectory?.standardizedFileURL.path
            for rawRoot in roots {
                guard let root = rawRoot as? String, root.hasPrefix("/") else {
                    throw CodexTaskRuntimeError.protocolViolation
                }
                let normalized = URL(fileURLWithPath: root).standardizedFileURL.path
                guard let allowedRoot,
                      normalized == allowedRoot || normalized.hasPrefix(allowedRoot + "/") else {
                    throw CodexTaskRuntimeError.protocolViolation
                }
            }
        }
    }

    private static func requiredString(_ key: String, inJSON data: Data) throws -> String {
        try requiredString(key, in: jsonObject(data))
    }

    private static func requiredString(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        try validateOpaqueID(value)
        return value
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        return object
    }

    private static func decodeObject(
        _ data: Data,
        maximumBytes: Int
    ) throws -> [String: Any] {
        guard let object = try decodeBoundedJSON(data, maximumBytes: maximumBytes)
                as? [String: Any] else {
            throw CodexTaskRuntimeError.protocolViolation
        }
        return object
    }

    private static func decodeBoundedJSON(_ data: Data, maximumBytes: Int) throws -> Any {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw data.count > maximumBytes
                ? CodexTaskRuntimeError.inboundMessageTooLarge
                : CodexTaskRuntimeError.protocolViolation
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodexTaskRuntimeError.protocolViolation
        }
    }

    private static func canonicalJSONData(_ object: Any, maximumBytes: Int) throws -> Data {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexTaskRuntimeError.protocolViolation
        }
        guard data.count <= maximumBytes else {
            throw CodexTaskRuntimeError.outboundMessageTooLarge
        }
        return data
    }

    private static func integerRequestID(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func serverRequestID(_ value: Any?) -> CodexTaskServerRequestID? {
        if let integer = integerRequestID(value) { return .integer(integer) }
        if let string = value as? String,
           !string.isEmpty,
           string.utf8.count <= 256,
           string.unicodeScalars.allSatisfy({
               $0.value >= 0x21 && $0.value <= 0x7e
           }) {
            return .string(string)
        }
        return nil
    }

    private static func eventThreadID(_ params: [String: Any]) -> String? {
        if let value = params["threadId"] as? String { return value }
        if let thread = params["thread"] as? [String: Any] {
            return thread["id"] as? String
        }
        return nil
    }

    private static func eventTurnID(_ params: [String: Any]) -> String? {
        if let value = params["turnId"] as? String { return value }
        if let turn = params["turn"] as? [String: Any] {
            return turn["id"] as? String
        }
        if let item = params["item"] as? [String: Any] {
            return item["turnId"] as? String
        }
        return nil
    }

    private static func boundedString(_ value: String?, maximumBytes: Int) -> String {
        guard let value else { return "" }
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        return String(decoding: data.prefix(maximumBytes), as: UTF8.self)
    }
}
