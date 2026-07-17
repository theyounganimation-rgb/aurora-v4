import Foundation
import Darwin

/// The small, curated set of memory Aurora may place in a live voice session.
/// This is intentionally not a dump of the workspace.
public struct IdentityCapsule: Codable, Sendable, Equatable {
    public let text: String
    public let sources: [String]
    public let truncated: Bool

    public init(text: String, sources: [String], truncated: Bool) {
        self.text = text
        self.sources = sources
        self.truncated = truncated
    }
}

public struct MemorySearchHit: Codable, Sendable, Equatable {
    public let path: String
    public let title: String
    public let excerpt: String
    public let score: Int

    public init(path: String, title: String, excerpt: String, score: Int) {
        self.path = path
        self.title = title
        self.excerpt = excerpt
        self.score = score
    }
}

public struct MemoryDocument: Codable, Sendable, Equatable {
    public let path: String
    public let content: String
    public let truncated: Bool

    public init(path: String, content: String, truncated: Bool) {
        self.path = path
        self.content = content
        self.truncated = truncated
    }
}

public struct VoiceMemoryProvenance: Codable, Sendable, Equatable {
    public let source: String
    public let sessionID: String?
    public let callID: String?
    public let speaker: String
    public let evidence: String?
    public let verificationStatus: String
    public let capturedAt: Date
    public let confidence: Double?

    public init(
        source: String = "openai_realtime_voice",
        sessionID: String? = nil,
        callID: String? = nil,
        speaker: String = "Owner",
        evidence: String? = nil,
        verificationStatus: String = "unverified caller-supplied learning",
        capturedAt: Date = Date(),
        confidence: Double? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.callID = callID
        self.speaker = speaker
        self.evidence = evidence
        self.verificationStatus = verificationStatus
        self.capturedAt = capturedAt
        self.confidence = confidence
    }
}

public struct MemoryWriteReceipt: Codable, Sendable, Equatable {
    public let path: String
    public let capturedAt: Date
    public let charactersWritten: Int

    public init(path: String, capturedAt: Date, charactersWritten: Int) {
        self.path = path
        self.capturedAt = capturedAt
        self.charactersWritten = charactersWritten
    }
}

public enum MemoryStoreError: LocalizedError, Sendable, Equatable {
    case emptyQuery
    case emptyMemory
    case invalidPath
    case pathOutsideWorkspace
    case documentNotAllowed
    case documentNotFound
    case documentTooLarge

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "A memory search needs a few words to look for."
        case .emptyMemory: return "There is no memory to save."
        case .invalidPath: return "That memory path is not valid."
        case .pathOutsideWorkspace: return "Memory access is limited to Aurora's workspace."
        case .documentNotAllowed: return "Aurora may only read approved Markdown memory documents."
        case .documentNotFound: return "That memory document does not exist."
        case .documentTooLarge: return "That memory is too large to save as one voice learning."
        }
    }
}

/// Owns Aurora's Markdown continuity without placing the entire memory corpus in
/// a model prompt. Reads are bounded, searches return excerpts, and voice
/// learning is append-only with explicit provenance.
public actor MemoryStore {
    public struct Configuration: Sendable, Equatable {
        public var rootURL: URL
        public var identityCapsuleCharacterLimit: Int
        public var perIdentityDocumentCharacterLimit: Int
        public var perPersonhoodDocumentCharacterLimit: Int
        public var readCharacterLimit: Int
        public var searchDocumentByteLimit: Int
        public var maximumSearchBytesPerQuery: Int
        public var maximumSearchDocuments: Int
        public var maximumSearchResults: Int
        public var maximumVoiceLearningCharacters: Int

        public init(
            rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/workspace", isDirectory: true),
            identityCapsuleCharacterLimit: Int = 4_500,
            perIdentityDocumentCharacterLimit: Int = 1_000,
            perPersonhoodDocumentCharacterLimit: Int = 350,
            readCharacterLimit: Int = 12_000,
            searchDocumentByteLimit: Int = 192_000,
            maximumSearchBytesPerQuery: Int = 32 * 1_024 * 1_024,
            maximumSearchDocuments: Int = 2_000,
            maximumSearchResults: Int = 8,
            maximumVoiceLearningCharacters: Int = 4_000
        ) {
            self.rootURL = rootURL
            self.identityCapsuleCharacterLimit = identityCapsuleCharacterLimit
            self.perIdentityDocumentCharacterLimit = perIdentityDocumentCharacterLimit
            self.perPersonhoodDocumentCharacterLimit = perPersonhoodDocumentCharacterLimit
            self.readCharacterLimit = readCharacterLimit
            self.searchDocumentByteLimit = searchDocumentByteLimit
            self.maximumSearchBytesPerQuery = maximumSearchBytesPerQuery
            self.maximumSearchDocuments = maximumSearchDocuments
            self.maximumSearchResults = maximumSearchResults
            self.maximumVoiceLearningCharacters = maximumVoiceLearningCharacters
        }
    }

    public nonisolated let rootURL: URL

    private let fileManager: FileManager
    private let configuration: Configuration
    private let canonicalRootPath: String
    private let canonicalRootURL: URL

    public init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        let standardized = configuration.rootURL.standardizedFileURL
        self.rootURL = standardized
        let canonicalPath = canonicalPathString(
            preservingMissingComponentsOf: standardized,
            fileManager: fileManager
        )
        self.canonicalRootPath = canonicalPath
        self.canonicalRootURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    /// Produces the continuity material that belongs in a live voice session.
    /// Only four named identity files and a small ranked set of personhood docs
    /// are considered; daily/voice memories are never swept into this capsule.
    public func identityCapsule() throws -> IdentityCapsule {
        let totalLimit = clamped(configuration.identityCapsuleCharacterLimit, 3_000, 64_000)
        let perIdentityLimit = clamped(configuration.perIdentityDocumentCharacterLimit, 500, 12_000)
        let perPersonhoodLimit = clamped(configuration.perPersonhoodDocumentCharacterLimit, 350, 6_000)
        let namedDocuments = ["SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md"]

        var candidates: [(url: URL, characterLimit: Int)] = []
        for path in namedDocuments {
            if let url = try? resolveCuratedCapsuleDocument(path) {
                candidates.append((url, perIdentityLimit))
            }
        }

        // Identity promotion is an explicit authority decision. A newly added
        // or cleverly named personhood file cannot silently enter every voice
        // session; it remains discoverable through memory_search instead.
        // Retired OpenClaw live-state documents such as active-scene.md and
        // nervous-system.md remain searchable historical evidence. They do not
        // enter every native voice session: the native self-knowledge contract
        // and current inner-life projection now own Aurora's live architecture.
        let curatedPersonhoodPaths = [
            "personhood/current-context.md",
            "personhood/lived-continuity.md",
            "personhood/self-authorship.md",
            "personhood/drives.md",
            "personhood/life-compass.md",
            "personhood/care-radar.md",
            "personhood/stakes.md"
        ]
        for path in curatedPersonhoodPaths {
            if let url = try? resolveCuratedCapsuleDocument(path) {
                candidates.append((url, perPersonhoodLimit))
            }
        }

        var output = "# Aurora continuity capsule\n"
        var sources: [String] = []
        var wasTruncated = false

        for candidate in candidates {
            let url = candidate.url
            let path = relativePath(for: url)
            guard !sources.contains(path) else { continue }

            // Canonical identity files are authored Markdown, not append-only
            // logs. A raw prefix used to preserve Aurora's aesthetic interests
            // while cutting off the later voice rules that explained how not
            // to perform those interests as polished dialogue. Read a bounded
            // source window, then give high-value behavioral sections a fair
            // share of the same compact prompt budget.
            let loaded = try readTextPrefix(at: url, byteLimit: min(64_000, candidate.characterLimit * 16))
            let curated = curatedIdentityExcerpt(
                path: path,
                text: loaded.text,
                limit: candidate.characterLimit
            )
            let bounded = boundedCharacters(curated.text, limit: candidate.characterLimit)
            let sectionPrefix = "\n\n## Source: \(path)\n\n"
            let available = totalLimit - output.count - sectionPrefix.count
            guard available > 0 else {
                wasTruncated = true
                break
            }

            let truncationMarker = "\n\n[Excerpt truncated; use memory_read if more detail is needed.]"
            let initiallyTruncated = loaded.truncated || curated.truncated || bounded.truncated || bounded.text.count > available
            let bodyLimit = initiallyTruncated ? max(0, available - truncationMarker.count) : available
            guard bodyLimit > 0 else {
                wasTruncated = true
                break
            }
            let sectionBody = boundedCharacters(bounded.text, limit: bodyLimit)
            let sourceWasTruncated = loaded.truncated || curated.truncated || bounded.truncated || sectionBody.truncated
            output += sectionPrefix + sectionBody.text
            if sourceWasTruncated { output += truncationMarker }
            sources.append(path)
            if sourceWasTruncated { wasTruncated = true }
            if output.count >= totalLimit {
                wasTruncated = true
                break
            }
        }

        return IdentityCapsule(text: output, sources: sources, truncated: wasTruncated)
    }

    /// Lexically searches only root-level Markdown plus memory/ and personhood/.
    /// Results are ranked excerpts rather than complete documents.
    public func search(_ query: String, limit requestedLimit: Int? = nil) throws -> [MemorySearchHit] {
        let terms = lexicalTerms(in: query)
        guard !terms.isEmpty else { throw MemoryStoreError.emptyQuery }

        let hardLimit = clamped(configuration.maximumSearchResults, 1, 12)
        let resultLimit = clamped(requestedLimit ?? hardLimit, 1, hardLimit)
        let byteLimit = clamped(configuration.searchDocumentByteLimit, 16_000, 512_000)
        var remainingByteBudget = clamped(
            configuration.maximumSearchBytesPerQuery,
            1 * 1_024 * 1_024,
            64 * 1_024 * 1_024
        )
        let documentLimit = clamped(configuration.maximumSearchDocuments, 100, 10_000)
        var hits: [MemorySearchHit] = []

        let documents = allowedMarkdownDocuments(maximumDocuments: documentLimit).sorted { left, right in
            modificationDate(for: left) > modificationDate(for: right)
        }
        for url in documents.prefix(documentLimit) {
            guard remainingByteBudget > 0 else { break }
            let lowercasePath = relativePath(for: url).lowercased()
            guard let match = try? lexicalMatch(
                in: url,
                terms: terms,
                excerptLimit: 700,
                chunkByteLimit: byteLimit,
                maximumBytes: remainingByteBudget
            ) else { continue }
            remainingByteBudget -= match.bytesScanned
            var score = match.score
            for term in terms where lowercasePath.contains(term) { score += 10 }
            guard score > 0 else { continue }

            hits.append(MemorySearchHit(
                path: relativePath(for: url),
                title: match.title,
                excerpt: match.excerpt,
                score: score
            ))
        }

        return Array(hits.sorted {
            if $0.score == $1.score { return $0.path < $1.path }
            return $0.score > $1.score
        }.prefix(resultLimit))
    }

    /// Reads one approved Markdown document. The caller must choose a document
    /// returned by search or a known identity path; there is no read-all API.
    public func read(path: String, maxCharacters: Int? = nil) throws -> MemoryDocument {
        let url = try resolveAllowedDocument(path)
        guard fileManager.fileExists(atPath: url.path) else { throw MemoryStoreError.documentNotFound }

        let hardLimit = clamped(configuration.readCharacterLimit, 2_000, 24_000)
        let characterLimit = clamped(maxCharacters ?? hardLimit, 500, hardLimit)
        let loaded = try readTextWindow(at: url, byteLimit: characterLimit)
        let bounded = boundedCharacters(loaded.text, limit: characterLimit)
        return MemoryDocument(
            path: relativePath(for: url),
            content: bounded.text,
            truncated: loaded.truncated || bounded.truncated
        )
    }

    /// Persists a compact learning from the live voice relationship. The
    /// learning is visibly quoted beneath immutable provenance metadata.
    public func remember(
        _ memory: String,
        provenance: VoiceMemoryProvenance = VoiceMemoryProvenance()
    ) throws -> MemoryWriteReceipt {
        let cleaned = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MemoryStoreError.emptyMemory }

        let maximum = clamped(configuration.maximumVoiceLearningCharacters, 500, 8_000)
        guard cleaned.count <= maximum else { throw MemoryStoreError.documentTooLarge }

        if !fileManager.fileExists(atPath: canonicalRootURL.path) {
            try fileManager.createDirectory(at: canonicalRootURL, withIntermediateDirectories: true)
        }
        let workspaceDirectory = try secureDirectory(canonicalRootURL)
        let memoryDirectory = try secureDirectory(
            workspaceDirectory.appendingPathComponent("memory", isDirectory: true)
        )
        let voiceDirectory = try secureDirectory(
            memoryDirectory.appendingPathComponent("voice", isDirectory: true)
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: voiceDirectory.path)

        let day = localDayString(for: provenance.capturedAt)
        let fileName = "\(day).md"
        let url = voiceDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard isInsideRoot(url), isAllowedMarkdownURL(url) else {
            throw MemoryStoreError.pathOutsideWorkspace
        }

        let source = markdownMetadata(provenance.source)
        let speaker = markdownMetadata(provenance.speaker)
        let session = provenance.sessionID.map(markdownMetadata) ?? "not supplied"
        let call = provenance.callID.map(markdownMetadata) ?? "not supplied"
        let verificationStatus = markdownMetadata(provenance.verificationStatus)
        let evidence = provenance.evidence?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_000)
            .description
        let timestamp = ISO8601DateFormatter().string(from: provenance.capturedAt)
        let confidenceLine = provenance.confidence.map {
            "- Confidence: \(String(format: "%.2f", min(max($0, 0), 1)))\n"
        } ?? ""
        let quotedMemory = cleaned
            .components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let quotedEvidence = evidence.map {
            $0.components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
        } ?? "> No supporting utterance was supplied."
        let entry = """
        ## Voice learning — \(timestamp)
        - Source: \(source)
        - Speaker: \(speaker)
        - Session: \(session)
        - Tool call: \(call)
        - Verification: \(verificationStatus)
        \(confidenceLine)
        ### Supporting voice evidence
        \(quotedEvidence)

        ### Synthesized learning
        \(quotedMemory)

        """

        try appendVoiceEntry(
            directoryPath: (canonicalRootPath as NSString).appendingPathComponent("memory/voice"),
            fileName: fileName,
            heading: "# Voice memories — \(day)\n\n",
            entry: entry
        )

        return MemoryWriteReceipt(
            path: relativePath(for: url),
            capturedAt: provenance.capturedAt,
            charactersWritten: cleaned.count
        )
    }

    // MARK: - Path policy

    private func secureDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard isInsideRoot(standardized) else { throw MemoryStoreError.pathOutsideWorkspace }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) {
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isDirectory.boolValue else {
                throw MemoryStoreError.pathOutsideWorkspace
            }
        } else {
            try fileManager.createDirectory(at: standardized, withIntermediateDirectories: false)
        }

        let canonical = standardized.resolvingSymlinksInPath()
        guard isInsideRoot(canonical) else { throw MemoryStoreError.pathOutsideWorkspace }
        return canonical
    }

    /// Uses directory-relative POSIX open with O_NOFOLLOW. The checked parent
    /// cannot be swapped for a symlink between validation and append, and the
    /// daily leaf itself may never be a symlink.
    private func appendVoiceEntry(
        directoryPath: String,
        fileName: String,
        heading: String,
        entry: String
    ) throws {
        let directoryFD = try openDirectoryDescriptorWithoutFollowingSymlinks(directoryPath)
        defer { Darwin.close(directoryFD) }

        let createFlags = O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var created = true
        var fileFD = Darwin.openat(directoryFD, fileName, createFlags, mode_t(0o600))
        if fileFD < 0, errno == EEXIST {
            created = false
            fileFD = Darwin.openat(
                directoryFD,
                fileName,
                O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0)
            )
        }
        guard fileFD >= 0 else { throw posixError() }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0 else { throw posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw MemoryStoreError.documentNotAllowed
        }

        if created { try writeAll(Data(heading.utf8), to: fileFD) }
        try writeAll(Data(entry.utf8), to: fileFD)
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
        var currentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else { throw posixError() }

        for componentSlice in directoryPath.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(componentSlice)
            let nextFD = Darwin.openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextFD < 0 {
                let failure = posixError()
                Darwin.close(currentFD)
                throw failure
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private func resolveAllowedDocument(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\0") else {
            throw MemoryStoreError.invalidPath
        }

        let candidate = canonicalRootURL.appendingPathComponent(trimmed).standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath()
        guard isInsideRoot(canonicalCandidate) else { throw MemoryStoreError.pathOutsideWorkspace }
        guard isAllowedMarkdownURL(canonicalCandidate) else { throw MemoryStoreError.documentNotAllowed }
        return canonicalCandidate
    }

    private func resolveCuratedCapsuleDocument(_ path: String) throws -> URL {
        let lexical = canonicalRootURL.appendingPathComponent(path).standardizedFileURL
        guard isInsideRoot(lexical), fileManager.fileExists(atPath: lexical.path) else {
            throw MemoryStoreError.documentNotFound
        }
        let values = try lexical.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MemoryStoreError.documentNotAllowed
        }
        let canonical = lexical.resolvingSymlinksInPath()
        guard canonical.path == lexical.path,
              relativePath(for: canonical) == path,
              isAllowedMarkdownURL(canonical) else {
            throw MemoryStoreError.documentNotAllowed
        }
        return canonical
    }

    private func allowedMarkdownDocuments(maximumDocuments: Int) -> [URL] {
        guard fileManager.fileExists(atPath: canonicalRootURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var urls: [URL] = []

        // Root means root-level Markdown, not a recursive sweep of every folder
        // that happens to live in the OpenClaw workspace.
        if let rootChildren = try? fileManager.contentsOfDirectory(
            at: canonicalRootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: rootChildren.filter { $0.pathExtension.lowercased() == "md" }.prefix(maximumDocuments))
        }

        var visitedEntries = 0
        let maximumVisitedEntries = max(2_000, maximumDocuments * 20)
        folderLoop: for folder in ["memory", "personhood"] {
            let directory = canonicalRootURL.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                visitedEntries += 1
                if visitedEntries > maximumVisitedEntries || urls.count >= maximumDocuments {
                    break folderLoop
                }
                guard url.pathExtension.lowercased() == "md" else { continue }
                urls.append(url)
            }
        }

        var unique = Set<String>()
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let canonical = url.resolvingSymlinksInPath()
            guard isInsideRoot(canonical), isAllowedMarkdownURL(canonical) else { return nil }
            guard let values = try? canonical.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            guard unique.insert(canonical.path).inserted else { return nil }
            return canonical
        }.sorted { relativePath(for: $0) < relativePath(for: $1) }
    }

    private func isAllowedMarkdownURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md", isInsideRoot(url) else { return false }
        let relative = relativePath(for: url)
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        if components.count == 1 { return true }
        let first = components[0].lowercased()
        return first == "memory" || first == "personhood"
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = canonicalRootPath
        let path = canonicalPathString(
            preservingMissingComponentsOf: url,
            fileManager: fileManager
        )
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = canonicalRootPath
        let path = canonicalPathString(
            preservingMissingComponentsOf: url,
            fileManager: fileManager
        )
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Bounded text helpers

    private func readTextPrefix(at url: URL, byteLimit: Int) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        let truncated = data.count > byteLimit
        let boundedData = truncated ? data.prefix(byteLimit) : data[...]
        return (String(decoding: boundedData, as: UTF8.self), truncated)
    }

    /// Keeps both provenance/header context and the newest append-only entries
    /// reachable when a Markdown document grows beyond one tool response.
    private func readTextWindow(at url: URL, byteLimit: Int) throws -> (text: String, truncated: Bool) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > UInt64(byteLimit) else {
            return try readTextPrefix(at: url, byteLimit: byteLimit)
        }

        let marker = "\n\n[… middle of document omitted …]\n\n"
        let payloadLimit = max(2, byteLimit - marker.utf8.count)
        let headLimit = payloadLimit / 2
        let tailLimit = payloadLimit - headLimit
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let head = try handle.read(upToCount: headLimit) ?? Data()
        let tailOffset = fileSize > UInt64(tailLimit) ? fileSize - UInt64(tailLimit) : 0
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.read(upToCount: tailLimit) ?? Data()
        return (
            String(decoding: head, as: UTF8.self) + marker + String(decoding: tail, as: UTF8.self),
            true
        )
    }

    private func boundedCharacters(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// Builds a small identity kernel from authored Markdown sections instead
    /// of blindly taking the first N characters. The selected headings are
    /// deliberately stable contracts, while all other material remains
    /// available through memory search/read.
    private func curatedIdentityExcerpt(
        path: String,
        text: String,
        limit: Int
    ) -> (text: String, truncated: Bool) {
        let wanted: [String]
        switch path {
        case "SOUL.md":
            wanted = ["stable self", "voice", "epistemic honesty"]
        case "MEMORY.md":
            wanted = ["owner", "aurora", "relationship and conversation"]
        default:
            return boundedCharacters(text, limit: limit)
        }

        let lines = text.components(separatedBy: .newlines)
        var preamble: [String] = []
        var sections: [String: [String]] = [:]
        var sectionOrder: [String] = []
        var currentSection: String?

        for line in lines {
            if line.hasPrefix("## ") {
                let title = line.dropFirst(3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                currentSection = title
                if sections[title] == nil {
                    sections[title] = [line]
                    sectionOrder.append(title)
                }
            } else if let currentSection {
                sections[currentSection, default: []].append(line)
            } else {
                preamble.append(line)
            }
        }

        // Unstructured fixtures and older identity files still behave like a
        // normal bounded prefix rather than disappearing from continuity.
        guard wanted.contains(where: { sections[$0] != nil }) else {
            return boundedCharacters(text, limit: limit)
        }

        let preambleBudget = min(220, max(100, limit / 5))
        var chunks: [String] = []
        let compactPreamble = preamble.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !compactPreamble.isEmpty {
            chunks.append(String(compactPreamble.prefix(preambleBudget)))
        }

        let presentSections = wanted.compactMap { title -> String? in
            guard let body = sections[title] else { return nil }
            return body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var remaining = max(0, limit - chunks.joined(separator: "\n\n").count)
        for (index, section) in presentSections.enumerated() where remaining > 0 {
            let sectionsLeft = max(1, presentSections.count - index)
            let separatorCost = chunks.isEmpty ? 0 : 2
            let share = max(0, (remaining - separatorCost) / sectionsLeft)
            chunks.append(String(section.prefix(share)))
            remaining = max(0, limit - chunks.joined(separator: "\n\n").count)
        }

        let excerpt = chunks.joined(separator: "\n\n")
        let representedTitles = Set(wanted.filter { sections[$0] != nil })
        let omittedAuthoredSection = sectionOrder.contains { !representedTitles.contains($0) }
        return (String(excerpt.prefix(limit)), text.count > excerpt.count || omittedAuthoredSection)
    }

    private func lexicalTerms(in text: String) -> [String] {
        var seen = Set<String>()
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
            "from", "had", "has", "have", "he", "her", "him", "his", "i",
            "in", "is", "it", "me", "my", "of", "on", "or", "our", "she",
            "that", "the", "their", "them", "they", "this", "to", "was", "we",
            "were", "what", "when", "where", "who", "with", "you", "your"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(16)
            .map { String($0.prefix(80)) }
    }

    /// Streams the complete document so older middle entries do not disappear
    /// merely because a daily Markdown journal grew. Only one short excerpt is
    /// retained for the model.
    private func lexicalMatch(
        in url: URL,
        terms: [String],
        excerptLimit: Int,
        chunkByteLimit: Int,
        maximumBytes: Int
    ) throws -> (score: Int, title: String, excerpt: String, bytesScanned: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var counts = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
        var firstExcerpt: String?
        var titleSource = ""
        var overlap = ""
        var bytesScanned = 0

        let fileSize = ((try fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        let allowedBytes = min(maximumBytes, fileSize > UInt64(Int.max) ? maximumBytes : Int(fileSize))
        let ranges: [(offset: UInt64, length: Int)]
        if fileSize > UInt64(allowedBytes), allowedBytes > 1 {
            let headLength = allowedBytes / 2
            let tailLength = allowedBytes - headLength
            ranges = [
                (0, headLength),
                (fileSize - UInt64(tailLength), tailLength)
            ]
        } else {
            ranges = [(0, allowedBytes)]
        }

        for range in ranges where range.length > 0 {
            try handle.seek(toOffset: range.offset)
            overlap = ""
            var rangeRemaining = range.length
            while rangeRemaining > 0 {
                let data = try handle.read(upToCount: min(chunkByteLimit, rangeRemaining)) ?? Data()
                guard !data.isEmpty else { break }
                rangeRemaining -= data.count
                bytesScanned += data.count
                let decoded = overlap + String(decoding: data, as: UTF8.self)
                if range.offset == 0, titleSource.count < 8_000 {
                    titleSource += String(decoded.prefix(8_000 - titleSource.count))
                }
                let lowercase = decoded.lowercased()

                for term in terms {
                    let remaining = max(0, 12 - (counts[term] ?? 0))
                    guard remaining > 0 else { continue }
                    let found = occurrenceCount(of: term, in: lowercase, cap: remaining)
                    if found > 0 {
                        counts[term, default: 0] += found
                        if firstExcerpt == nil {
                            firstExcerpt = excerpt(in: decoded, around: [term], limit: excerptLimit)
                        }
                    }
                }
                overlap = String(decoded.suffix(512))
                if counts.values.allSatisfy({ $0 >= 12 }) { break }
            }
            if counts.values.allSatisfy({ $0 >= 12 }) { break }
        }

        return (
            score: counts.values.reduce(0, +) * 5,
            title: markdownTitle(in: titleSource, fallback: url.deletingPathExtension().lastPathComponent),
            excerpt: firstExcerpt ?? "The query matched this document's path.",
            bytesScanned: bytesScanned
        )
    }

    private func occurrenceCount(of needle: String, in haystack: String, cap: Int) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while count < cap, let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private func markdownTitle(in content: String, fallback: String) -> String {
        for line in content.components(separatedBy: .newlines).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !title.isEmpty { return String(title.prefix(120)) }
            }
        }
        return fallback
    }

    private func excerpt(in content: String, around terms: [String], limit: Int) -> String {
        let source = content as NSString
        let lowercase = content.lowercased() as NSString
        var location = 0
        for term in terms {
            let range = lowercase.range(of: term)
            if range.location != NSNotFound {
                location = range.location
                break
            }
        }

        let half = limit / 2
        let start = max(0, min(location - half, max(0, source.length - limit)))
        let length = min(limit, source.length - start)
        let raw = source.substring(with: NSRange(location: start, length: length))
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let prefix = start > 0 ? "…" : ""
        let suffix = start + length < source.length ? "…" : ""
        return prefix + collapsed + suffix
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func markdownMetadata(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(240)
            .description
    }

    private func localDayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func clamped(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

private func canonicalPathString(
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
        guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else {
            return existing.path
        }
        defer { Darwin.free(resolvedPointer) }
        return String(cString: resolvedPointer)
    }
    return missing.reduce(resolvedExisting) { partial, component in
        (partial as NSString).appendingPathComponent(component)
    }
}
