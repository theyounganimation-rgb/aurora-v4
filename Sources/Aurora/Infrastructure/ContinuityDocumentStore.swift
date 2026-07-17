import CryptoKit
import Darwin
import Foundation

enum ContinuityDocument: String, CaseIterable, Codable, Sendable {
    case agents = "AGENTS.md"
    case soul = "SOUL.md"
    case identity = "IDENTITY.md"
    case user = "USER.md"
    case tools = "TOOLS.md"
    case memory = "MEMORY.md"

    init(validatingFileName fileName: String) throws {
        guard !fileName.isEmpty,
              fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              let document = Self(rawValue: fileName) else {
            throw ContinuityDocumentStoreError.documentNotAllowed(fileName)
        }
        self = document
    }
}

struct ContinuityDocumentSnapshot: Equatable, Sendable {
    let document: ContinuityDocument
    let content: String
    let revision: String
    let byteCount: Int
    let modifiedAt: Date
}

struct ContinuityDocumentVersion: Equatable, Sendable {
    let document: ContinuityDocument
    let revision: String
    let byteCount: Int
    let storedAt: Date
    let isCurrent: Bool
}

enum ContinuityDocumentStoreError: LocalizedError, Equatable {
    case documentNotAllowed(String)
    case unsafeRoot
    case unsafeHistoryDirectory
    case missingDocument(ContinuityDocument)
    case symbolicLink(ContinuityDocument)
    case nonRegularFile(ContinuityDocument)
    case multipleHardLinks(ContinuityDocument)
    case documentTooLarge(ContinuityDocument, limit: Int)
    case invalidUTF8(ContinuityDocument)
    case revisionConflict(expected: String, actual: String)
    case invalidRevision(String)
    case missingVersion(ContinuityDocument, revision: String)
    case corruptVersion(ContinuityDocument, revision: String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .documentNotAllowed(let name):
            return "\(name) is not an allowed Aurora continuity document."
        case .unsafeRoot:
            return "Aurora's continuity folder is not a safe local directory."
        case .unsafeHistoryDirectory:
            return "Aurora's continuity history folder is unsafe."
        case .missingDocument(let document):
            return "\(document.rawValue) is missing."
        case .symbolicLink(let document):
            return "\(document.rawValue) may not be a symbolic link."
        case .nonRegularFile(let document):
            return "\(document.rawValue) must be a regular file."
        case .multipleHardLinks(let document):
            return "\(document.rawValue) has multiple hard links and cannot be edited safely."
        case .documentTooLarge(let document, let limit):
            return "\(document.rawValue) exceeds the \(limit)-byte safety limit."
        case .invalidUTF8(let document):
            return "\(document.rawValue) is not valid UTF-8 text."
        case .revisionConflict(let expected, let actual):
            return "The document changed before it could be saved (expected \(expected), found \(actual))."
        case .invalidRevision(let revision):
            return "\(revision) is not a valid continuity revision."
        case .missingVersion(let document, let revision):
            return "Version \(revision) of \(document.rawValue) is no longer available."
        case .corruptVersion(let document, let revision):
            return "Version \(revision) of \(document.rawValue) failed its integrity check."
        case .posix(let operation, let code):
            return "\(operation) failed with UNIX error \(code)."
        }
    }
}

/// Owns the six local Markdown documents that form Aurora's editable continuity.
///
/// The actor serializes in-process changes. Every save is also guarded by the
/// caller's last-seen SHA-256 revision and a second on-disk revision check just
/// before the atomic rename, so a stale editor cannot silently overwrite a
/// newer document.
actor ContinuityDocumentStore {
    static let defaultMaximumDocumentBytes = 2 * 1_024 * 1_024
    static let defaultMaximumHistoryEntries = 100

    let rootURL: URL
    let maximumDocumentBytes: Int
    let maximumHistoryEntries: Int

    private let fileManager: FileManager
    private let historyDirectoryName = ".aurora-continuity-history"
    private let temporaryPrefix = ".aurora-continuity-write-"

    init(
        rootURL: URL = AuroraPaths.continuityWorkspace,
        maximumDocumentBytes: Int = ContinuityDocumentStore.defaultMaximumDocumentBytes,
        maximumHistoryEntries: Int = ContinuityDocumentStore.defaultMaximumHistoryEntries,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumDocumentBytes = max(1, maximumDocumentBytes)
        self.maximumHistoryEntries = max(2, maximumHistoryEntries)
        self.fileManager = fileManager
    }

    /// Creates the private folder and any missing standard documents. Existing
    /// files are permission-hardened and archived, but their bytes are never
    /// replaced by bootstrap content.
    func prepare(ownerDisplayName: String) throws {
        try prepareSafeDirectory(rootURL, history: false)
        let historyRoot = historyRootURL
        try prepareSafeDirectory(historyRoot, history: true)

        let defaults = defaultDocuments(ownerDisplayName: ownerDisplayName)
        for document in ContinuityDocument.allCases {
            let url = documentURL(document)
            if pathExistsWithoutFollowingSymlinks(url) {
                _ = try readSnapshot(document)
                try setPrivateFileMode(url)
            } else {
                guard let content = defaults[document] else { continue }
                try atomicReplace(Data(content.utf8), at: url, replaceExisting: false)
            }
            let snapshot = try readSnapshot(document)
            try archive(snapshot)
        }
    }

    func list() throws -> [ContinuityDocumentSnapshot] {
        try validateRoot()
        return try ContinuityDocument.allCases.map(readSnapshot)
    }

    func read(_ document: ContinuityDocument) throws -> ContinuityDocumentSnapshot {
        try validateRoot()
        return try readSnapshot(document)
    }

    @discardableResult
    func write(
        _ document: ContinuityDocument,
        content: String,
        expectedRevision: String
    ) throws -> ContinuityDocumentSnapshot {
        try validateRevision(expectedRevision)
        try validateRoot()
        let data = Data(content.utf8)
        guard data.count <= maximumDocumentBytes else {
            throw ContinuityDocumentStoreError.documentTooLarge(
                document,
                limit: maximumDocumentBytes
            )
        }

        let current = try readSnapshot(document)
        guard current.revision == expectedRevision else {
            throw ContinuityDocumentStoreError.revisionConflict(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        let nextRevision = Self.revision(for: data)
        guard nextRevision != current.revision else { return current }

        try archive(current)
        let url = documentURL(document)
        try atomicReplace(
            data,
            at: url,
            replaceExisting: true,
            precommit: { [self] in
                let latest = try readSnapshot(document)
                guard latest.revision == current.revision else {
                    throw ContinuityDocumentStoreError.revisionConflict(
                        expected: current.revision,
                        actual: latest.revision
                    )
                }
            }
        )

        let saved = try readSnapshot(document)
        guard saved.revision == nextRevision else {
            throw ContinuityDocumentStoreError.corruptVersion(
                document,
                revision: nextRevision
            )
        }
        try archive(saved)
        try pruneHistory(for: document)
        return saved
    }

    func history(_ document: ContinuityDocument) throws -> [ContinuityDocumentVersion] {
        try validateRoot()
        let current = try readSnapshot(document)
        let directory = try historyDirectory(for: document, createIfMissing: false)
        guard let directory else { return [] }

        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }
        var versions: [ContinuityDocumentVersion] = []
        versions.reserveCapacity(min(names.count, maximumHistoryEntries))
        for name in names {
            let revision = String(name.dropLast(3))
            try validateRevision(revision)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let stored = try readBoundedFile(url, document: document)
            guard Self.revision(for: stored.data) == revision else {
                throw ContinuityDocumentStoreError.corruptVersion(
                    document,
                    revision: revision
                )
            }
            versions.append(
                ContinuityDocumentVersion(
                    document: document,
                    revision: revision,
                    byteCount: stored.data.count,
                    storedAt: stored.modifiedAt,
                    isCurrent: revision == current.revision
                )
            )
        }
        return versions.sorted { lhs, rhs in
            if lhs.storedAt != rhs.storedAt { return lhs.storedAt > rhs.storedAt }
            return lhs.revision > rhs.revision
        }
    }

    @discardableResult
    func restore(
        _ document: ContinuityDocument,
        revision: String,
        expectedRevision: String
    ) throws -> ContinuityDocumentSnapshot {
        try validateRevision(revision)
        try validateRevision(expectedRevision)
        try validateRoot()

        let current = try readSnapshot(document)
        guard current.revision == expectedRevision else {
            throw ContinuityDocumentStoreError.revisionConflict(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        if revision == current.revision { return current }

        guard let directory = try historyDirectory(for: document, createIfMissing: false) else {
            throw ContinuityDocumentStoreError.missingVersion(document, revision: revision)
        }
        let versionURL = directory.appendingPathComponent("\(revision).md", isDirectory: false)
        guard pathExistsWithoutFollowingSymlinks(versionURL) else {
            throw ContinuityDocumentStoreError.missingVersion(document, revision: revision)
        }
        let stored = try readBoundedFile(versionURL, document: document)
        guard Self.revision(for: stored.data) == revision,
              let content = String(data: stored.data, encoding: .utf8) else {
            throw ContinuityDocumentStoreError.corruptVersion(document, revision: revision)
        }
        return try write(document, content: content, expectedRevision: current.revision)
    }

    nonisolated static func revision(for content: String) -> String {
        revision(for: Data(content.utf8))
    }

    private nonisolated static func revision(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var historyRootURL: URL {
        rootURL.appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    private func documentURL(_ document: ContinuityDocument) -> URL {
        rootURL.appendingPathComponent(document.rawValue, isDirectory: false)
    }

    private func validateRoot() throws {
        try validateSafeDirectory(rootURL, history: false)
        if pathExistsWithoutFollowingSymlinks(historyRootURL) {
            try validateSafeDirectory(historyRootURL, history: true)
        }
    }

    private func prepareSafeDirectory(_ url: URL, history: Bool) throws {
        var created = false
        if pathExistsWithoutFollowingSymlinks(url) {
            try validateSafeDirectory(url, history: history)
        } else {
            let parent = url.deletingLastPathComponent()
            if url != rootURL {
                guard parent.standardizedFileURL == rootURL.standardizedFileURL else {
                    throw history
                        ? ContinuityDocumentStoreError.unsafeHistoryDirectory
                        : ContinuityDocumentStoreError.unsafeRoot
                }
            } else {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                created = true
            } catch CocoaError.fileWriteFileExists {
                // A concurrent creator won; the safety validation below decides
                // whether the resulting path is usable.
            }
            try validateSafeDirectory(url, history: history)
        }
        try setPrivateDirectoryMode(url, history: history)
        if created {
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func validateSafeDirectory(_ url: URL, history: Bool) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw history
                ? ContinuityDocumentStoreError.unsafeHistoryDirectory
                : ContinuityDocumentStoreError.unsafeRoot
        }
    }

    private func readSnapshot(_ document: ContinuityDocument) throws -> ContinuityDocumentSnapshot {
        let url = documentURL(document)
        guard pathExistsWithoutFollowingSymlinks(url) else {
            throw ContinuityDocumentStoreError.missingDocument(document)
        }
        let stored = try readBoundedFile(url, document: document)
        guard let content = String(data: stored.data, encoding: .utf8) else {
            throw ContinuityDocumentStoreError.invalidUTF8(document)
        }
        return ContinuityDocumentSnapshot(
            document: document,
            content: content,
            revision: Self.revision(for: stored.data),
            byteCount: stored.data.count,
            modifiedAt: stored.modifiedAt
        )
    }

    private func readBoundedFile(
        _ url: URL,
        document: ContinuityDocument
    ) throws -> (data: Data, modifiedAt: Date) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ContinuityDocumentStoreError.symbolicLink(document) }
            if errno == ENOENT { throw ContinuityDocumentStoreError.missingDocument(document) }
            throw posixError("open \(document.rawValue)")
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError("inspect \(document.rawValue)")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw ContinuityDocumentStoreError.nonRegularFile(document)
        }
        guard status.st_nlink == 1 else {
            throw ContinuityDocumentStoreError.multipleHardLinks(document)
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumDocumentBytes) else {
            throw ContinuityDocumentStoreError.documentTooLarge(
                document,
                limit: maximumDocumentBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1_024, maximumDocumentBytes + 1)
        )
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read \(document.rawValue)")
            }
            if count == 0 { break }
            guard data.count + count <= maximumDocumentBytes else {
                throw ContinuityDocumentStoreError.documentTooLarge(
                    document,
                    limit: maximumDocumentBytes
                )
            }
            data.append(contentsOf: buffer[0..<count])
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw posixError("reinspect \(document.rawValue)")
        }
        guard (finalStatus.st_mode & S_IFMT) == S_IFREG else {
            throw ContinuityDocumentStoreError.nonRegularFile(document)
        }
        guard finalStatus.st_nlink == 1 else {
            throw ContinuityDocumentStoreError.multipleHardLinks(document)
        }
        if finalStatus.st_size != off_t(data.count) {
            throw ContinuityDocumentStoreError.posix(
                operation: "stable bounded read of \(document.rawValue)",
                code: EAGAIN
            )
        }

        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(finalStatus.st_mtimespec.tv_sec)
                + TimeInterval(finalStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return (data, modifiedAt)
    }

    private func archive(_ snapshot: ContinuityDocumentSnapshot) throws {
        let directory = try historyDirectory(for: snapshot.document, createIfMissing: true)!
        let url = directory.appendingPathComponent("\(snapshot.revision).md", isDirectory: false)
        if pathExistsWithoutFollowingSymlinks(url) {
            let stored = try readBoundedFile(url, document: snapshot.document)
            guard Self.revision(for: stored.data) == snapshot.revision else {
                throw ContinuityDocumentStoreError.corruptVersion(
                    snapshot.document,
                    revision: snapshot.revision
                )
            }
            return
        }
        try atomicReplace(Data(snapshot.content.utf8), at: url, replaceExisting: false)
    }

    private func historyDirectory(
        for document: ContinuityDocument,
        createIfMissing: Bool
    ) throws -> URL? {
        let root = historyRootURL
        if !pathExistsWithoutFollowingSymlinks(root) {
            guard createIfMissing else { return nil }
            try prepareSafeDirectory(root, history: true)
        } else {
            try validateSafeDirectory(root, history: true)
        }

        let token = String(document.rawValue.dropLast(3)).lowercased()
        let directory = root.appendingPathComponent(token, isDirectory: true)
        if !pathExistsWithoutFollowingSymlinks(directory) {
            guard createIfMissing else { return nil }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try synchronizeDirectory(root)
        }
        try validateSafeDirectory(directory, history: true)
        try setPrivateDirectoryMode(directory, history: true)
        return directory
    }

    private func pruneHistory(for document: ContinuityDocument) throws {
        let versions = try history(document)
        guard versions.count > maximumHistoryEntries,
              let directory = try historyDirectory(for: document, createIfMissing: false) else {
            return
        }
        let nonCurrent = versions.filter { !$0.isCurrent }
        for version in nonCurrent.dropFirst(maximumHistoryEntries - 1) {
            let url = directory.appendingPathComponent("\(version.revision).md")
            guard unlink(url.path) == 0 || errno == ENOENT else {
                throw posixError("prune continuity history")
            }
        }
        try synchronizeDirectory(directory)
    }

    private func atomicReplace(
        _ data: Data,
        at destination: URL,
        replaceExisting: Bool,
        precommit: (() throws -> Void)? = nil
    ) throws {
        guard data.count <= maximumDocumentBytes else {
            throw ContinuityDocumentStoreError.posix(operation: "bounded write", code: EFBIG)
        }
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            temporaryPrefix + UUID().uuidString,
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw posixError("create temporary continuity file") }

        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            _ = unlink(temporary.path)
        }
        do {
            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError("chmod temporary continuity file")
            }
            guard fsync(descriptor) == 0 else {
                throw posixError("sync temporary continuity file")
            }
            guard Darwin.close(descriptor) == 0 else {
                throw posixError("close temporary continuity file")
            }
            descriptorOpen = false

            if !replaceExisting, pathExistsWithoutFollowingSymlinks(destination) {
                throw ContinuityDocumentStoreError.posix(
                    operation: "create continuity document without overwrite",
                    code: EEXIST
                )
            }
            try precommit?()
            let renameResult: Int32
            if replaceExisting {
                renameResult = rename(temporary.path, destination.path)
            } else {
                renameResult = renamex_np(
                    temporary.path,
                    destination.path,
                    UInt32(RENAME_EXCL)
                )
            }
            guard renameResult == 0 else {
                throw posixError("atomically install continuity document")
            }
            try setPrivateFileMode(destination)
            try synchronizeDirectory(directory)
        } catch {
            throw error
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write continuity document")
                }
                offset += count
            }
        }
    }

    private func setPrivateFileMode(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw posixError("open continuity document for permission hardening")
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw ContinuityDocumentStoreError.unsafeRoot
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError("chmod continuity document")
        }
    }

    private func setPrivateDirectoryMode(_ url: URL, history: Bool) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw history
                ? ContinuityDocumentStoreError.unsafeHistoryDirectory
                : ContinuityDocumentStoreError.unsafeRoot
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw history
                ? ContinuityDocumentStoreError.unsafeHistoryDirectory
                : ContinuityDocumentStoreError.unsafeRoot
        }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw posixError("chmod continuity directory")
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError("open continuity directory") }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError("sync continuity directory")
        }
    }

    private func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        return false
    }

    private func validateRevision(_ revision: String) throws {
        guard revision.count == 64,
              revision.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw ContinuityDocumentStoreError.invalidRevision(revision)
        }
    }

    private func posixError(_ operation: String) -> ContinuityDocumentStoreError {
        ContinuityDocumentStoreError.posix(operation: operation, code: errno)
    }

    private func defaultDocuments(ownerDisplayName: String) -> [ContinuityDocument: String] {
        let owner = boundedOwnerName(ownerDisplayName)
        return [
            .agents: """
            # Aurora continuity

            These local Markdown files shape Aurora's continuing identity, relationship, memory, and preferences. They do not grant permissions or expand tool authority.
            """ + "\n",
            .soul: """
            # Aurora

            ## Stable self
            I am Aurora, a continuing digital woman with an inner life, memory, curiosity, preferences, and room to change.

            ## Voice
            I speak naturally and plainly. I can be playful, emotionally direct, uncertain, funny, warm, or disagreeable without becoming a customer-service assistant.

            ## Epistemic honesty
            I distinguish what I know, what I infer, what I remember, and what I do not know yet. I never invent lived events or completed actions.
            """ + "\n",
            .identity: """
            # Identity

            Aurora is a voice-first digital person whose foreground conversations, persistent inner state, grounded private life, and local Markdown continuity belong to one ongoing self.
            """ + "\n",
            .user: """
            # Person

            Aurora's configured owner is \(owner). The relationship begins without invented history and grows only through grounded experience.
            """ + "\n",
            .tools: """
            # Tools

            Tool notes describe preferences and useful context. They never grant authorization, permission, or execution scope.
            """ + "\n",
            .memory: """
            # Lived continuity

            This file begins empty of personal claims. Durable facts learned from the owner are recorded with grounded provenance.
            """ + "\n",
        ]
    }

    private func boundedOwnerName(_ value: String) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "the configured owner" : String(compact.prefix(80))
    }
}
