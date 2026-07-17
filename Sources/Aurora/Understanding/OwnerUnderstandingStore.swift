import Darwin
import Foundation

enum OwnerUnderstandingStoreError: LocalizedError, Equatable {
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
            return "Aurora's owner-understanding directory is not a safe private directory."
        case .unsafeStateFile:
            return "Aurora's owner-understanding state is not a safe regular file."
        case .stateTooLarge:
            return "Aurora's owner-understanding state exceeded its bounded size."
        case .corruptState:
            return "Aurora's owner-understanding state is unreadable and was left untouched."
        case .unsupportedSchema(let version):
            return "Aurora's owner-understanding state uses unsupported schema version \(version)."
        case .stateInUse:
            return "Aurora's owner-understanding state is already owned by another process."
        case .posix(let code):
            return "Aurora could not persist owner understanding (system error \(code))."
        }
    }
}

final class OwnerUnderstandingProcessLock: @unchecked Sendable {
    fileprivate let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

/// Bounded, atomic, no-follow JSON persistence. Unsafe or malformed existing
/// state is never replaced with an empty personal history.
struct OwnerUnderstandingStore: Sendable {
    static let maximumStateBytes = 512 * 1_024

    let fileURL: URL

    init(fileURL: URL = OwnerUnderstandingStore.defaultFileURL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Aurora", isDirectory: true)
            .appendingPathComponent("owner-understanding", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func acquireExclusiveProcessLock() throws -> OwnerUnderstandingProcessLock {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }
        let lockFD = Darwin.openat(
            directoryFD,
            ".state.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockFD >= 0 else {
            if errno == ELOOP { throw OwnerUnderstandingStoreError.unsafeStateFile }
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        var status = stat()
        guard Darwin.fstat(lockFD, &status) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw OwnerUnderstandingStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(lockFD)
            throw OwnerUnderstandingStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw OwnerUnderstandingStoreError.posix(code)
        }
        guard Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                throw OwnerUnderstandingStoreError.stateInUse
            }
            throw OwnerUnderstandingStoreError.posix(code)
        }
        return OwnerUnderstandingProcessLock(fileDescriptor: lockFD)
    }

    func load() throws -> OwnerUnderstandingState? {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }
        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw OwnerUnderstandingStoreError.unsafeStateFile }
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw OwnerUnderstandingStoreError.unsafeStateFile
        }
        guard status.st_size > 0, status.st_size <= Self.maximumStateBytes else {
            if status.st_size == 0 { throw OwnerUnderstandingStoreError.corruptState }
            throw OwnerUnderstandingStoreError.stateTooLarge
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        let data = try readAll(from: fileFD, expectedBytes: Int(status.st_size))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: OwnerUnderstandingState
        do {
            decoded = try decoder.decode(OwnerUnderstandingState.self, from: data)
        } catch {
            throw OwnerUnderstandingStoreError.corruptState
        }
        guard decoded.schemaVersion == OwnerUnderstandingState.currentSchemaVersion else {
            throw OwnerUnderstandingStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        return OwnerUnderstandingEngine.sanitize(decoded, now: max(decoded.updatedAt, decoded.createdAt))
    }

    func save(_ rawState: OwnerUnderstandingState) throws {
        let state = OwnerUnderstandingEngine.sanitize(rawState, now: rawState.updatedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw OwnerUnderstandingStoreError.corruptState
        }
        data.append(0x0A)
        guard data.count <= Self.maximumStateBytes else {
            throw OwnerUnderstandingStoreError.stateTooLarge
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
        guard temporaryFD >= 0 else { throw OwnerUnderstandingStoreError.posix(errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }
        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        try writeAll(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        let renameResult = temporaryName.withCString { source in
            fileURL.lastPathComponent.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameResult == 0 else { throw OwnerUnderstandingStoreError.posix(errno) }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
    }

    private func openPrivateDirectory() throws -> Int32 {
        guard !fileURL.lastPathComponent.isEmpty, fileURL.lastPathComponent != "." else {
            throw OwnerUnderstandingStoreError.unsafeStateFile
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
            throw OwnerUnderstandingStoreError.unsafeDirectory
        }

        var pathStatus = stat()
        var result = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        if result != 0 {
            guard errno == ENOENT else { throw OwnerUnderstandingStoreError.unsafeDirectory }
            let createResult = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if createResult != 0, errno != EEXIST {
                throw OwnerUnderstandingStoreError.posix(errno)
            }
            result = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        }
        guard result == 0, (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw OwnerUnderstandingStoreError.unsafeDirectory
        }

        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw OwnerUnderstandingStoreError.unsafeDirectory
            }
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        var openedStatus = stat()
        guard Darwin.fstat(directoryFD, &openedStatus) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw OwnerUnderstandingStoreError.posix(code)
        }
        guard (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(directoryFD)
            throw OwnerUnderstandingStoreError.unsafeDirectory
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw OwnerUnderstandingStoreError.posix(code)
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
            if errno == ELOOP { throw OwnerUnderstandingStoreError.unsafeStateFile }
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        defer { Darwin.close(existingFD) }
        var status = stat()
        guard Darwin.fstat(existingFD, &status) == 0 else {
            throw OwnerUnderstandingStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size <= Self.maximumStateBytes else {
            if status.st_size > Self.maximumStateBytes {
                throw OwnerUnderstandingStoreError.stateTooLarge
            }
            throw OwnerUnderstandingStoreError.unsafeStateFile
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
                throw OwnerUnderstandingStoreError.posix(errno)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumStateBytes {
                throw OwnerUnderstandingStoreError.stateTooLarge
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
                    throw OwnerUnderstandingStoreError.posix(errno)
                }
                offset += written
            }
        }
    }
}
