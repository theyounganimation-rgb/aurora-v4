import Darwin
import Foundation

struct AuroraJournalEvent: Codable, Sendable {
    let timestamp: Date
    let kind: String
    let sessionID: String?
    let detail: String
    let metadata: [String: String]

    init(
        kind: String,
        sessionID: String? = nil,
        detail: String,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.sessionID = sessionID
        self.detail = detail
        self.metadata = metadata
    }
}

/// Private, append-only evidence of what the native voice app generated,
/// actually played, interrupted, and executed. Files are no-follow, mode 0600,
/// and automatically expire after the local diagnostic window.
actor EventJournal {
    private let directory: URL
    private let encoder: JSONEncoder
    private let calendar = Calendar(identifier: .gregorian)
    private let fileManager: FileManager
    private let retentionDays: Int
    private var lastRetentionDay: DateComponents?
    private var lastFailureDescription: String?

    init(
        directory: URL = AuroraPaths.eventJournalDirectory,
        retentionDays: Int = 30,
        fileManager: FileManager = .default
    ) {
        self.directory = directory.standardizedFileURL
        self.retentionDays = min(max(retentionDays, 1), 365)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    @discardableResult
    func append(_ event: AuroraJournalEvent) async -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
            }

            // Resolve platform-owned aliases such as /var -> /private/var only
            // after proving the requested leaf itself is not a symlink.
            let canonicalDirectory: URL = directory.path.withCString { pathPointer in
                guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else { return directory }
                defer { Darwin.free(resolvedPointer) }
                return URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
            }
            let directoryFD = try openDirectoryDescriptorWithoutFollowingSymlinks(canonicalDirectory)
            defer { Darwin.close(directoryFD) }
            try pruneIfNeeded(directoryFD: directoryFD, now: event.timestamp)

            let components = calendar.dateComponents([.year, .month, .day], from: event.timestamp)
            let filename = String(
                format: "%04d-%02d-%02d.ndjson",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
            var data = try encoder.encode(event)
            data.append(0x0A)

            let fileFD = Darwin.openat(
                directoryFD,
                filename,
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
            lastFailureDescription = nil
            return true
        } catch {
            // Diagnostics must never break Aurora's live voice. Security checks
            // fail closed by discarding the event rather than following a link.
            lastFailureDescription = String(describing: error)
            return false
        }
    }

    func failureDescriptionForVerification() -> String? {
        lastFailureDescription
    }

    private func pruneIfNeeded(directoryFD: Int32, now: Date) throws {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        if today == lastRetentionDay { return }
        lastRetentionDay = today
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where child.pathExtension.lowercased() == "ndjson" {
            let values = try child.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            _ = child.lastPathComponent.withCString { name in
                Darwin.unlinkat(directoryFD, name, 0)
            }
        }
    }

    private func openDirectoryDescriptorWithoutFollowingSymlinks(_ target: URL) throws -> Int32 {
        // O_NOFOLLOW applies to the final component while still allowing
        // macOS APFS firmlinks (for example /private/var) in the canonical
        // system path. The leaf was also checked through URL resource values.
        let descriptor = target.path.withCString { path in
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
}
