import Foundation
import Darwin

public struct ToolAuditEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let callID: String
    public let sessionID: String?
    public let tool: String
    public let argumentSummary: String
    public let phase: String
    public let succeeded: Bool?
    /// Legacy tools may still populate this Boolean. New intent execution
    /// records the scoped envelope below instead of treating one Boolean as
    /// authorization for an arbitrary effect.
    public let approvalGranted: Bool?
    public let authorizationID: String?
    public let authorizationDecision: String?
    public let operation: String?
    public let capabilityRoute: String?
    public let resultCode: String?
    public let durationMilliseconds: Int
    public let outcome: String

    public init(
        timestamp: Date = Date(),
        callID: String,
        sessionID: String?,
        tool: String,
        argumentSummary: String,
        phase: String = "completed",
        succeeded: Bool?,
        approvalGranted: Bool?,
        authorizationID: String? = nil,
        authorizationDecision: String? = nil,
        operation: String? = nil,
        capabilityRoute: String? = nil,
        resultCode: String? = nil,
        durationMilliseconds: Int,
        outcome: String
    ) {
        self.timestamp = timestamp
        self.callID = callID
        self.sessionID = sessionID
        self.tool = tool
        self.argumentSummary = argumentSummary
        self.phase = phase
        self.succeeded = succeeded
        self.approvalGranted = approvalGranted
        self.authorizationID = authorizationID.map { String($0.prefix(160)) }
        self.authorizationDecision = authorizationDecision.map { String($0.prefix(80)) }
        self.operation = operation.map { String($0.prefix(120)) }
        self.capabilityRoute = capabilityRoute.map { String($0.prefix(80)) }
        self.resultCode = resultCode.map { String($0.prefix(80)) }
        self.durationMilliseconds = durationMilliseconds
        self.outcome = outcome
    }
}

/// An append-only JSONL account of local capabilities. Arguments are summarized
/// by ToolRegistry so memory text and command contents are never copied here.
public actor ToolAuditJournal {
    public nonisolated let fileURL: URL

    private let fileManager: FileManager
    private let canonicalDirectoryPath: String

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aurora", isDirectory: true)
            .appendingPathComponent("tool-audit.jsonl", isDirectory: false),
        fileManager: FileManager = .default
    ) {
        let standardized = fileURL.standardizedFileURL
        self.fileURL = standardized
        self.fileManager = fileManager
        self.canonicalDirectoryPath = canonicalAuditPathString(
            preservingMissingComponentsOf: standardized.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    public func append(_ event: ToolAuditEvent) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)

        let directoryFD = try openDirectoryDescriptorWithoutFollowingSymlinks(canonicalDirectoryPath)
        defer { Darwin.close(directoryFD) }

        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fileFD >= 0 else { throw posixError() }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else { throw posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else { throw posixError() }
        try writeAll(data, to: fileFD)
        guard Darwin.fsync(fileFD) == 0 else { throw posixError() }
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func openDirectoryDescriptorWithoutFollowingSymlinks(_ directoryPath: String) throws -> Int32 {
        let descriptor = directoryPath.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            let failure = posixError()
            Darwin.close(descriptor)
            throw failure
        }
        return descriptor
    }
}

private func canonicalAuditPathString(
    preservingMissingComponentsOf url: URL,
    fileManager: FileManager
) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while existing.path != "/", !fileManager.fileExists(atPath: existing.path) {
        missing.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }

    let resolvedExisting: String = existing.path.withCString { pathPointer in
        guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else { return existing.path }
        defer { Darwin.free(resolvedPointer) }
        return String(cString: resolvedPointer)
    }
    return missing.reduce(resolvedExisting) { partial, component in
        (partial as NSString).appendingPathComponent(component)
    }
}
