import Darwin
import Foundation

enum AgencyStoreError: LocalizedError, Equatable {
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
            return "Aurora's agency directory is not a safe private directory."
        case .unsafeStateFile:
            return "Aurora's agency state is not a safe regular file."
        case .stateTooLarge:
            return "Aurora's agency state exceeded its bounded size."
        case .corruptState:
            return "Aurora's agency state is unreadable and was left untouched."
        case .unsupportedSchema(let version):
            return "Aurora's agency state uses unsupported schema version \(version)."
        case .stateInUse:
            return "Aurora's agency state is already owned by another process."
        case .posix(let code):
            return "Aurora could not persist agency state (system error \(code))."
        }
    }
}

final class AgencyProcessLock: @unchecked Sendable {
    fileprivate let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

/// Bounded, atomic, mode-0600, no-follow persistence. A malformed or unsafe
/// existing file is preserved rather than replaced by an invented empty life.
struct AgencyStore: Sendable {
    static let maximumStateBytes = 512 * 1_024
    static let defaultFileURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Aurora", isDirectory: true)
            .appendingPathComponent("agency", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }()

    let fileURL: URL

    init(fileURL: URL = AgencyStore.defaultFileURL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    func acquireExclusiveProcessLock() throws -> AgencyProcessLock {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }
        let lockFD = Darwin.openat(
            directoryFD,
            ".state.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockFD >= 0 else {
            if errno == ELOOP { throw AgencyStoreError.unsafeStateFile }
            throw AgencyStoreError.posix(errno)
        }
        var status = stat()
        guard Darwin.fstat(lockFD, &status) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw AgencyStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(lockFD)
            throw AgencyStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw AgencyStoreError.posix(code)
        }
        guard Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                throw AgencyStoreError.stateInUse
            }
            throw AgencyStoreError.posix(code)
        }
        return AgencyProcessLock(fileDescriptor: lockFD)
    }

    func load() throws -> AgencyState? {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }
        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw AgencyStoreError.unsafeStateFile }
            throw AgencyStoreError.posix(errno)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw AgencyStoreError.unsafeStateFile
        }
        guard status.st_size > 0, status.st_size <= Self.maximumStateBytes else {
            if status.st_size == 0 { throw AgencyStoreError.corruptState }
            throw AgencyStoreError.stateTooLarge
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
        let data = try readAll(from: fileFD, expectedBytes: Int(status.st_size))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: AgencyState
        do {
            decoded = try decoder.decode(AgencyState.self, from: data)
        } catch {
            throw AgencyStoreError.corruptState
        }
        guard decoded.schemaVersion == AgencyState.currentSchemaVersion else {
            throw AgencyStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        guard AgencyEngine.persistedStateIsStructurallyValid(decoded) else {
            throw AgencyStoreError.corruptState
        }
        // Return the structurally valid bytes exactly as persisted. The
        // runtime owns semantic sanitization and compares its repaired state
        // with this raw value before saving, so one-time migrations are not
        // accidentally made memory-only by sanitizing twice.
        return decoded
    }

    func save(_ rawState: AgencyState) throws {
        guard rawState.schemaVersion == AgencyState.currentSchemaVersion else {
            throw AgencyStoreError.unsupportedSchema(rawState.schemaVersion)
        }
        let state = AgencyEngine.sanitize(rawState, now: rawState.updatedAt)
        guard AgencyEngine.persistedStateIsStructurallyValid(state) else {
            throw AgencyStoreError.corruptState
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw AgencyStoreError.corruptState
        }
        data.append(0x0A)
        guard data.count <= Self.maximumStateBytes else {
            throw AgencyStoreError.stateTooLarge
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
        guard temporaryFD >= 0 else { throw AgencyStoreError.posix(errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }
        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
        try writeAll(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
        let renameResult = temporaryName.withCString { source in
            fileURL.lastPathComponent.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameResult == 0 else { throw AgencyStoreError.posix(errno) }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
    }

    private func openPrivateDirectory() throws -> Int32 {
        guard !fileURL.lastPathComponent.isEmpty, fileURL.lastPathComponent != "." else {
            throw AgencyStoreError.unsafeStateFile
        }
        let directory = fileURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AgencyStoreError.unsafeDirectory
        }

        var pathStatus = stat()
        var result = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        if result != 0 {
            guard errno == ENOENT else { throw AgencyStoreError.unsafeDirectory }
            let createResult = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if createResult != 0, errno != EEXIST {
                throw AgencyStoreError.posix(errno)
            }
            result = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        }
        guard result == 0, (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw AgencyStoreError.unsafeDirectory
        }

        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw AgencyStoreError.unsafeDirectory }
            throw AgencyStoreError.posix(errno)
        }
        var openedStatus = stat()
        guard Darwin.fstat(directoryFD, &openedStatus) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw AgencyStoreError.posix(code)
        }
        guard (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(directoryFD)
            throw AgencyStoreError.unsafeDirectory
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw AgencyStoreError.posix(code)
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
            if errno == ELOOP { throw AgencyStoreError.unsafeStateFile }
            throw AgencyStoreError.posix(errno)
        }
        defer { Darwin.close(existingFD) }
        var status = stat()
        guard Darwin.fstat(existingFD, &status) == 0 else {
            throw AgencyStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size <= Self.maximumStateBytes else {
            if status.st_size > Self.maximumStateBytes { throw AgencyStoreError.stateTooLarge }
            throw AgencyStoreError.unsafeStateFile
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
                throw AgencyStoreError.posix(errno)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumStateBytes { throw AgencyStoreError.stateTooLarge }
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
                    throw AgencyStoreError.posix(errno)
                }
                offset += written
            }
        }
    }
}
