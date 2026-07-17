import Darwin
import Foundation

enum PrivateLifeStoreError: LocalizedError {
    case unsafeDirectory
    case unsafeStateFile
    case stateTooLarge
    case corruptState
    case unsupportedSchema(Int)
    case stateInUse
    case legacyBackupConflict
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "Aurora's private-life directory is not a safe private directory."
        case .unsafeStateFile:
            return "Aurora's private-life state is not a safe regular file."
        case .stateTooLarge:
            return "Aurora's private-life state exceeded its bounded size."
        case .corruptState:
            return "Aurora's private-life state is unreadable; it was left untouched for recovery."
        case .unsupportedSchema(let version):
            return "Aurora's private-life state uses unsupported schema version \(version)."
        case .stateInUse:
            return "Aurora's private-life state is already owned by another running process."
        case .legacyBackupConflict:
            return "Aurora's private-life migration backup already exists with different content."
        case .posix(let code):
            return "Aurora could not persist her private life (system error \(code))."
        }
    }
}

final class PrivateLifeProcessLock: @unchecked Sendable {
    fileprivate let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

/// Atomic no-follow persistence for Aurora's private semantic life.
///
/// This is deliberately separate from the numerical inner-life snapshot. A
/// malformed private-life file is preserved rather than silently resetting
/// projects or inventing a replacement history.
struct PrivateLifeStore: Sendable {
    static let maximumStateBytes = 2 * 1_024 * 1_024

    let fileURL: URL

    var legacyBackupURL: URL {
        migrationBackupURL(schemaVersion: 1)
    }

    func migrationBackupURL(schemaVersion: Int) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).schema-v\(schemaVersion).backup",
                isDirectory: false
            )
    }

    init(fileURL: URL = PrivateLifeStore.defaultFileURL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Aurora", isDirectory: true)
            .appendingPathComponent("private-life", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func acquireExclusiveProcessLock() throws -> PrivateLifeProcessLock {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }

        let lockFD = Darwin.openat(
            directoryFD,
            ".state.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockFD >= 0 else {
            if errno == ELOOP { throw PrivateLifeStoreError.unsafeStateFile }
            throw PrivateLifeStoreError.posix(errno)
        }

        var status = stat()
        guard Darwin.fstat(lockFD, &status) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw PrivateLifeStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(lockFD)
            throw PrivateLifeStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw PrivateLifeStoreError.posix(code)
        }
        guard Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                throw PrivateLifeStoreError.stateInUse
            }
            throw PrivateLifeStoreError.posix(code)
        }
        return PrivateLifeProcessLock(fileDescriptor: lockFD)
    }

    func load() throws -> PrivateLifeState? {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }

        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw PrivateLifeStoreError.unsafeStateFile }
            throw PrivateLifeStoreError.posix(errno)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw PrivateLifeStoreError.unsafeStateFile
        }
        guard status.st_size >= 0, status.st_size <= Self.maximumStateBytes else {
            throw PrivateLifeStoreError.stateTooLarge
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }

        let data = try readAll(from: fileFD, expectedBytes: Int(status.st_size))
        guard !data.isEmpty else { throw PrivateLifeStoreError.corruptState }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: PrivateLifeState
        do {
            state = try decoder.decode(PrivateLifeState.self, from: data)
        } catch {
            throw PrivateLifeStoreError.corruptState
        }
        guard state.schemaVersion >= PrivateLifeState.oldestMigratableSchemaVersion,
              state.schemaVersion <= PrivateLifeState.currentSchemaVersion else {
            throw PrivateLifeStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    /// Creates one byte-for-byte, mode-0600 backup before an older state is
    /// replaced. `linkat` publishes the fully fsynced temporary file without
    /// overwriting an existing backup, even if another caller races.
    func backupLegacyStateIfNeeded() throws {
        try backupStateBeforeMigrationIfNeeded(schemaVersion: 1)
    }

    func backupStateBeforeMigrationIfNeeded(schemaVersion: Int) throws {
        guard schemaVersion >= PrivateLifeState.oldestMigratableSchemaVersion,
              schemaVersion < PrivateLifeState.currentSchemaVersion else { return }
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }

        let sourceFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceFD >= 0 else {
            if errno == ELOOP { throw PrivateLifeStoreError.unsafeStateFile }
            throw PrivateLifeStoreError.posix(errno)
        }
        defer { Darwin.close(sourceFD) }
        var sourceStatus = stat()
        guard Darwin.fstat(sourceFD, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG,
              sourceStatus.st_nlink == 1,
              sourceStatus.st_size >= 0,
              sourceStatus.st_size <= Self.maximumStateBytes else {
            throw PrivateLifeStoreError.unsafeStateFile
        }
        let sourceData = try readAll(from: sourceFD, expectedBytes: Int(sourceStatus.st_size))
        guard let object = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              object["schemaVersion"] as? Int == schemaVersion else {
            return
        }

        let backupName = migrationBackupURL(schemaVersion: schemaVersion).lastPathComponent
        let existingFD = Darwin.openat(directoryFD, backupName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existingFD >= 0 {
            defer { Darwin.close(existingFD) }
            var status = stat()
            guard Darwin.fstat(existingFD, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_size >= 0,
                  status.st_size <= Self.maximumStateBytes else {
                throw PrivateLifeStoreError.unsafeStateFile
            }
            guard Darwin.fchmod(existingFD, mode_t(0o600)) == 0 else {
                throw PrivateLifeStoreError.posix(errno)
            }
            let existing = try readAll(from: existingFD, expectedBytes: Int(status.st_size))
            guard existing == sourceData else { throw PrivateLifeStoreError.legacyBackupConflict }
            return
        }
        if errno != ENOENT {
            if errno == ELOOP { throw PrivateLifeStoreError.unsafeStateFile }
            throw PrivateLifeStoreError.posix(errno)
        }

        let temporaryName = ".\(backupName).tmp-\(UUID().uuidString.lowercased())"
        let temporaryFD = Darwin.openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw PrivateLifeStoreError.posix(errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }
        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }
        try writeAll(sourceData, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else { throw PrivateLifeStoreError.posix(errno) }

        let linkResult = temporaryName.withCString { source in
            backupName.withCString { destination in
                Darwin.linkat(directoryFD, source, directoryFD, destination, 0)
            }
        }
        if linkResult != 0 {
            if errno == EEXIST { throw PrivateLifeStoreError.legacyBackupConflict }
            throw PrivateLifeStoreError.posix(errno)
        }
        _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else { throw PrivateLifeStoreError.posix(errno) }
    }

    func save(_ state: PrivateLifeState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        guard data.count <= Self.maximumStateBytes else {
            throw PrivateLifeStoreError.stateTooLarge
        }

        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }
        try validateExistingState(in: directoryFD)

        let temporaryName = ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        let temporaryFD = Darwin.openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw PrivateLifeStoreError.posix(errno) }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }
        try writeAll(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }

        let renameResult = temporaryName.withCString { source in
            fileURL.lastPathComponent.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameResult == 0 else { throw PrivateLifeStoreError.posix(errno) }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }
    }

    private func openPrivateDirectory() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw PrivateLifeStoreError.unsafeDirectory
        }

        var pathStatus = stat()
        var statusResult = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        if statusResult != 0 {
            guard errno == ENOENT else { throw PrivateLifeStoreError.unsafeDirectory }
            let createResult = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if createResult != 0, errno != EEXIST {
                throw PrivateLifeStoreError.posix(errno)
            }
            statusResult = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        }
        guard statusResult == 0, (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw PrivateLifeStoreError.unsafeDirectory
        }

        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw PrivateLifeStoreError.unsafeDirectory
            }
            throw PrivateLifeStoreError.posix(errno)
        }

        var status = stat()
        guard Darwin.fstat(directoryFD, &status) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw PrivateLifeStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_dev == pathStatus.st_dev,
              status.st_ino == pathStatus.st_ino else {
            Darwin.close(directoryFD)
            throw PrivateLifeStoreError.unsafeDirectory
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw PrivateLifeStoreError.posix(code)
        }
        return directoryFD
    }

    private func validateExistingState(in directoryFD: Int32) throws {
        let existingFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if existingFD < 0 {
            if errno == ENOENT { return }
            if errno == ELOOP { throw PrivateLifeStoreError.unsafeStateFile }
            throw PrivateLifeStoreError.posix(errno)
        }
        defer { Darwin.close(existingFD) }

        var status = stat()
        guard Darwin.fstat(existingFD, &status) == 0 else {
            throw PrivateLifeStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw PrivateLifeStoreError.unsafeStateFile
        }
    }

    private func readAll(from fileDescriptor: Int32, expectedBytes: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(expectedBytes, Self.maximumStateBytes))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PrivateLifeStoreError.posix(errno)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumStateBytes { throw PrivateLifeStoreError.stateTooLarge }
        }
        return data
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
                    throw PrivateLifeStoreError.posix(errno)
                }
                offset += written
            }
        }
    }
}
