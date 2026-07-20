import Darwin
import Foundation

enum DelegateTaskStoreError: LocalizedError, Equatable {
    case unsafeDirectory
    case unsafeStateFile
    case stateTooLarge
    case corruptState
    case unsupportedSchema(Int)
    case stateInUse
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "Aurora's delegated-task directory is not a safe private directory."
        case .unsafeStateFile:
            return "Aurora's delegated-task state is not a safe regular file."
        case .stateTooLarge:
            return "Aurora's delegated-task state exceeded its bounded size."
        case .corruptState:
            return "Aurora's delegated-task state is unreadable and was left untouched."
        case .unsupportedSchema(let version):
            return "Aurora's delegated-task state uses unsupported schema version \(version)."
        case .stateInUse:
            return "Aurora's delegated-task state is already owned by another running process."
        case .posix(let code):
            return "Aurora could not persist delegated-task continuity (system error \(code))."
        }
    }
}

final class DelegateTaskProcessLock: @unchecked Sendable {
    fileprivate let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

struct DelegateTaskPersistedRecord: Codable, Sendable, Equatable {
    let taskID: String
    var codexThreadID: String?
    var codexTurnID: String?
    let originatingSessionID: String
    let taskKind: DelegateTaskKind
    /// Optional so existing schema-1 ledgers remain readable. Restored records
    /// receive the deterministic legacy default for their already-stored kind.
    var executionClass: DelegateTaskExecutionClass?
    let rootAuthorizationID: String
    var sourceTurnIDs: [String]
    let goal: String
    let successCriteria: String?
    let workspacePath: String?
    let createdAt: Date
    var updatedAt: Date
    var status: DelegateTaskStatus
    var statusKnowledge: DelegateTaskStatusKnowledge
    var revision: UInt64
    var resultSummary: String?
    var resultReport: DelegateTaskResultReport?
    var effectVerified: Bool
    var stepCount: Int
    /// Optional for backward compatibility with schema-1 ledgers written
    /// before pending direct-task cancellation became restart-safe.
    var cancellationPending: Bool?
    /// Append-only operation/effect history. Optional so every schema-1 state
    /// written before operation-level truth tracking remains readable.
    var operationLedger: [DelegateTaskOperationLedgerEntry]?
    /// Version of the host-owned structured effect-report contract installed
    /// when this Codex thread was created. `nil` identifies a legacy thread;
    /// dynamic tools cannot be retrofitted onto an existing app-server thread.
    var effectReportingContractVersion: Int?
    /// Explicit project-chat relays share the completion/event ledger but are
    /// not ordinary `delegate_task` work and must never become its implicit
    /// active-task target. Optional keeps every existing schema-1 ledger valid.
    var isProjectChat: Bool?
}

public enum CodexProjectChatFocusMode: String, Codable, Sendable, Equatable {
    case projectSelected = "project_selected"
    case threadSelected = "thread_selected"
    case newThreadPending = "new_thread_pending"
}

/// Durable, host-resolved location of the Codex work Aurora was explicitly
/// asked to focus. Natural-language selection is resolved by Realtime; this
/// record stores only exact resource identity and never acts as authorization.
struct CodexProjectChatPersistedFocus: Codable, Sendable, Equatable {
    var mode: CodexProjectChatFocusMode
    var projectName: String
    var workspacePath: String
    /// Exact cwd for a selected existing thread. Optional keeps older state
    /// readable and is nil for project-only/new-thread focus.
    var threadWorkspacePath: String?
    var threadID: String?
    var threadName: String?
    var taskID: String?
}

enum DelegateTaskOperationLedgerEvent: String, Codable, Sendable, Equatable {
    case authorized
    case executorBound = "executor_bound"
    case effectVerified = "effect_verified"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// An immutable event in a task's operation history. Authorization is recorded
/// once, then executor binding, effect receipts, and the terminal observation
/// are appended as later entries referring to the same operation ID.
struct DelegateTaskOperationLedgerEntry: Codable, Sendable, Equatable {
    let sequence: UInt64
    let operationID: String
    let event: DelegateTaskOperationLedgerEvent
    let operation: DelegateTaskOperation?
    let revision: UInt64
    let authorizationID: String?
    let sourceTurnIDs: [String]?
    let authorizedEffect: String?
    let codexTurnID: String?
    let executorStatus: DelegateTaskStatus?
    let effectReceipt: DelegateTaskEffectReceipt?
    let resultSummary: String?
    let recordedAt: Date
}

struct DelegateTaskPersistedState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [DelegateTaskPersistedRecord]
    var projectChatFocus: CodexProjectChatPersistedFocus?
    /// Optional for schema-1 compatibility. New builds use it to invalidate
    /// action envelopes prepared against an older focus selection.
    var projectChatGeneration: UInt64?

    init(
        records: [DelegateTaskPersistedRecord],
        projectChatFocus: CodexProjectChatPersistedFocus? = nil,
        projectChatGeneration: UInt64? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
        self.projectChatFocus = projectChatFocus
        self.projectChatGeneration = projectChatGeneration
    }
}

/// Atomic, no-follow persistence for the exact Codex task/thread/turn binding.
/// A malformed or substituted state file is never replaced automatically.
struct DelegateTaskStore: Sendable {
    static let maximumStateBytes = 1 * 1_024 * 1_024

    let fileURL: URL

    init(
        fileURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Aurora", isDirectory: true)
            .appendingPathComponent("delegate-tasks", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Aurora/delegate-tasks/state.json",
                    isDirectory: false
                )
    ) {
        self.fileURL = fileURL.standardizedFileURL
    }

    func acquireExclusiveProcessLock() throws -> DelegateTaskProcessLock {
        let directoryFD = try openPrivateDirectory(createIfMissing: true)
        guard directoryFD >= 0 else { throw DelegateTaskStoreError.unsafeDirectory }
        defer { Darwin.close(directoryFD) }

        let lockFD = Darwin.openat(
            directoryFD,
            ".state.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockFD >= 0 else {
            throw errno == ELOOP
                ? DelegateTaskStoreError.unsafeStateFile
                : DelegateTaskStoreError.posix(errno)
        }
        var status = stat()
        guard Darwin.fstat(lockFD, &status) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw DelegateTaskStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == Darwin.geteuid(),
              (status.st_mode & mode_t(0o022)) == 0 else {
            Darwin.close(lockFD)
            throw DelegateTaskStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw DelegateTaskStoreError.posix(code)
        }
        guard Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                throw DelegateTaskStoreError.stateInUse
            }
            throw DelegateTaskStoreError.posix(code)
        }
        return DelegateTaskProcessLock(fileDescriptor: lockFD)
    }

    func load() throws -> DelegateTaskPersistedState? {
        let directoryFD = try openPrivateDirectory(createIfMissing: false)
        if directoryFD < 0 { return nil }
        defer { Darwin.close(directoryFD) }

        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw DelegateTaskStoreError.unsafeStateFile }
            throw DelegateTaskStoreError.posix(errno)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw DelegateTaskStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == Darwin.geteuid(),
              (status.st_mode & mode_t(0o022)) == 0 else {
            throw DelegateTaskStoreError.unsafeStateFile
        }
        guard status.st_size > 0, status.st_size <= Self.maximumStateBytes else {
            throw status.st_size == 0
                ? DelegateTaskStoreError.corruptState
                : DelegateTaskStoreError.stateTooLarge
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw DelegateTaskStoreError.posix(errno)
        }

        let data = try readAll(from: fileFD, expectedBytes: Int(status.st_size))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: DelegateTaskPersistedState
        do {
            decoded = try decoder.decode(DelegateTaskPersistedState.self, from: data)
        } catch {
            throw DelegateTaskStoreError.corruptState
        }
        guard decoded.schemaVersion == DelegateTaskPersistedState.currentSchemaVersion else {
            throw DelegateTaskStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        return decoded
    }

    func save(_ state: DelegateTaskPersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        guard data.count <= Self.maximumStateBytes else {
            throw DelegateTaskStoreError.stateTooLarge
        }

        let directoryFD = try openPrivateDirectory(createIfMissing: true)
        guard directoryFD >= 0 else { throw DelegateTaskStoreError.unsafeDirectory }
        defer { Darwin.close(directoryFD) }
        try validateExistingState(in: directoryFD)

        let temporaryName = ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        let temporaryFD = Darwin.openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw DelegateTaskStoreError.posix(errno) }

        var removeTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if removeTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        var temporaryStatus = stat()
        guard Darwin.fstat(temporaryFD, &temporaryStatus) == 0,
              (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
              temporaryStatus.st_nlink == 1,
              temporaryStatus.st_uid == Darwin.geteuid(),
              (temporaryStatus.st_mode & mode_t(0o022)) == 0 else {
            throw DelegateTaskStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw DelegateTaskStoreError.posix(errno)
        }
        try writeAll(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw DelegateTaskStoreError.posix(errno)
        }
        let renameResult = temporaryName.withCString { source in
            fileURL.lastPathComponent.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameResult == 0 else { throw DelegateTaskStoreError.posix(errno) }
        removeTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw DelegateTaskStoreError.posix(errno)
        }
    }

    private func openPrivateDirectory(createIfMissing: Bool) throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        guard directory.path.hasPrefix("/") else {
            throw DelegateTaskStoreError.unsafeDirectory
        }
        let components = directory.path.split(separator: "/").map(String.init)
        var currentFD = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentFD >= 0 else { throw DelegateTaskStoreError.posix(errno) }

        for component in components {
            var nextFD = component.withCString {
                Darwin.openat(
                    currentFD,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if nextFD < 0, errno == ENOENT {
                guard createIfMissing else {
                    Darwin.close(currentFD)
                    return -1
                }
                let createResult = component.withCString {
                    Darwin.mkdirat(currentFD, $0, mode_t(0o700))
                }
                guard createResult == 0 || errno == EEXIST else {
                    let code = errno
                    Darwin.close(currentFD)
                    throw DelegateTaskStoreError.posix(code)
                }
                nextFD = component.withCString {
                    Darwin.openat(
                        currentFD,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard nextFD >= 0 else {
                let code = errno
                Darwin.close(currentFD)
                throw code == ELOOP || code == ENOTDIR
                    ? DelegateTaskStoreError.unsafeDirectory
                    : DelegateTaskStoreError.posix(code)
            }
            var status = stat()
            guard Darwin.fstat(nextFD, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR else {
                let code = errno
                Darwin.close(nextFD)
                Darwin.close(currentFD)
                throw code == 0
                    ? DelegateTaskStoreError.unsafeDirectory
                    : DelegateTaskStoreError.posix(code)
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }

        var finalStatus = stat()
        guard Darwin.fstat(currentFD, &finalStatus) == 0,
              finalStatus.st_uid == Darwin.geteuid(),
              (finalStatus.st_mode & mode_t(0o022)) == 0 else {
            Darwin.close(currentFD)
            throw DelegateTaskStoreError.unsafeDirectory
        }
        guard Darwin.fchmod(currentFD, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(currentFD)
            throw DelegateTaskStoreError.posix(code)
        }
        return currentFD
    }

    private func validateExistingState(in directoryFD: Int32) throws {
        var status = stat()
        let result = fileURL.lastPathComponent.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result < 0 {
            if errno == ENOENT { return }
            throw DelegateTaskStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == Darwin.geteuid(),
              (status.st_mode & mode_t(0o022)) == 0 else {
            throw DelegateTaskStoreError.unsafeStateFile
        }
    }

    private func readAll(from fileDescriptor: Int32, expectedBytes: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, max(1, expectedBytes)))
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw DelegateTaskStoreError.posix(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumStateBytes else {
                throw DelegateTaskStoreError.stateTooLarge
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DelegateTaskStoreError.posix(errno)
                }
                offset += written
            }
        }
    }
}
