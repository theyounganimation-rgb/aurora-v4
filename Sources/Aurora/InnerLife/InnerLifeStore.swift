import Darwin
import Foundation

enum InnerLifeStoreError: LocalizedError {
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
            return "Aurora's inner-life directory is not a safe private directory."
        case .unsafeStateFile:
            return "Aurora's inner-life state is not a safe regular file."
        case .stateTooLarge:
            return "Aurora's inner-life state exceeded its bounded size."
        case .corruptState:
            return "Aurora's inner-life state is unreadable; it was left untouched for recovery."
        case .unsupportedSchema(let version):
            return "Aurora's inner-life state uses unsupported schema version \(version)."
        case .stateInUse:
            return "Aurora's inner-life state is already owned by another running process."
        case .posix(let code):
            return "Aurora could not persist her inner life (system error \(code))."
        }
    }
}

final class InnerLifeProcessLock: @unchecked Sendable {
    fileprivate let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

/// Atomic, no-follow persistence for Aurora's private inner-life state.
///
/// The store never silently replaces corrupt data. A missing file may create a
/// new state, but a malformed or unsafe existing file fails closed so a bug
/// cannot erase Aurora's continuity.
struct InnerLifeStore: Sendable {
    static let maximumStateBytes = 2 * 1_024 * 1_024

    let fileURL: URL

    init(
        fileURL: URL = AuroraPaths.applicationSupport
            .appendingPathComponent("inner-life", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    ) {
        self.fileURL = fileURL.standardizedFileURL
    }

    /// Holds an advisory lock for the lifetime of one production runtime. This
    /// prevents two Aurora processes from loading the same snapshot and then
    /// atomically overwriting each other's newer state.
    func acquireExclusiveProcessLock() throws -> InnerLifeProcessLock {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }

        let lockFD = Darwin.openat(
            directoryFD,
            ".state.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockFD >= 0 else {
            if errno == ELOOP { throw InnerLifeStoreError.unsafeStateFile }
            throw InnerLifeStoreError.posix(errno)
        }

        var status = stat()
        guard Darwin.fstat(lockFD, &status) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw InnerLifeStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            Darwin.close(lockFD)
            throw InnerLifeStoreError.unsafeStateFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw InnerLifeStoreError.posix(code)
        }
        guard Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                throw InnerLifeStoreError.stateInUse
            }
            throw InnerLifeStoreError.posix(code)
        }
        return InnerLifeProcessLock(fileDescriptor: lockFD)
    }

    func load() throws -> InnerLifeState? {
        let directoryFD = try openPrivateDirectory()
        defer { Darwin.close(directoryFD) }

        let fileFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw InnerLifeStoreError.unsafeStateFile }
            throw InnerLifeStoreError.posix(errno)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw InnerLifeStoreError.unsafeStateFile
        }
        guard status.st_size >= 0, status.st_size <= Self.maximumStateBytes else {
            throw InnerLifeStoreError.stateTooLarge
        }
        guard Darwin.fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }

        let data = try readAll(from: fileFD, expectedBytes: Int(status.st_size))
        guard !data.isEmpty else { throw InnerLifeStoreError.corruptState }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: InnerLifeState
        do {
            state = try decoder.decode(InnerLifeState.self, from: data)
        } catch {
            throw InnerLifeStoreError.corruptState
        }
        guard state.schemaVersion >= InnerLifeState.oldestMigratableSchemaVersion,
              state.schemaVersion <= InnerLifeState.currentSchemaVersion else {
            throw InnerLifeStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    func save(_ state: InnerLifeState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        guard data.count <= Self.maximumStateBytes else {
            throw InnerLifeStoreError.stateTooLarge
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
        guard temporaryFD >= 0 else { throw InnerLifeStoreError.posix(errno) }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryFD)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }
        }

        guard Darwin.fchmod(temporaryFD, mode_t(0o600)) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }
        try writeAll(data, to: temporaryFD)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }

        let renameResult = temporaryName.withCString { source in
            fileURL.lastPathComponent.withCString { destination in
                Darwin.renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard renameResult == 0 else { throw InnerLifeStoreError.posix(errno) }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryFD) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }
    }

    private func openPrivateDirectory() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch let error as InnerLifeStoreError {
            throw error
        } catch {
            throw InnerLifeStoreError.unsafeDirectory
        }

        // Inspect the final path without following it before changing any
        // permissions. This prevents a substituted symlink from causing chmod
        // side effects on an unrelated target directory.
        var pathStatus = stat()
        var statusResult = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        if statusResult != 0 {
            guard errno == ENOENT else { throw InnerLifeStoreError.unsafeDirectory }
            let createResult = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if createResult != 0, errno != EEXIST {
                throw InnerLifeStoreError.posix(errno)
            }
            statusResult = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        }
        guard statusResult == 0, (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw InnerLifeStoreError.unsafeDirectory
        }

        let directoryFD = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw InnerLifeStoreError.unsafeDirectory
            }
            throw InnerLifeStoreError.posix(errno)
        }

        var status = stat()
        guard Darwin.fstat(directoryFD, &status) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw InnerLifeStoreError.posix(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_dev == pathStatus.st_dev,
              status.st_ino == pathStatus.st_ino else {
            Darwin.close(directoryFD)
            throw InnerLifeStoreError.unsafeDirectory
        }
        guard Darwin.fchmod(directoryFD, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            throw InnerLifeStoreError.posix(code)
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
            if errno == ELOOP { throw InnerLifeStoreError.unsafeStateFile }
            throw InnerLifeStoreError.posix(errno)
        }
        defer { Darwin.close(existingFD) }

        var status = stat()
        guard Darwin.fstat(existingFD, &status) == 0 else {
            throw InnerLifeStoreError.posix(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw InnerLifeStoreError.unsafeStateFile
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
                throw InnerLifeStoreError.posix(errno)
            }
            data.append(buffer, count: count)
            if data.count > Self.maximumStateBytes { throw InnerLifeStoreError.stateTooLarge }
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
                    throw InnerLifeStoreError.posix(errno)
                }
                offset += written
            }
        }
    }
}
