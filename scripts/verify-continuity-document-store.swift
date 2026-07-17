import Darwin
import Foundation

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum ContinuityDocumentStoreVerification {
    static func main() async {
        do {
            try await run()
            print("Continuity document store verification: 25/25 passed")
        } catch {
            fputs("Continuity document store verification failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("aurora-continuity-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let root = sandbox.appendingPathComponent("continuity", isDirectory: true)
        let store = ContinuityDocumentStore(
            rootURL: root,
            maximumDocumentBytes: 512,
            maximumHistoryEntries: 8
        )
        try await store.prepare(ownerDisplayName: "Maya")

        try expect(mode(of: root) == 0o700, "root permissions are not 0700")
        let seeded = try await store.list()
        try expect(seeded.count == 6, "all six allowlisted documents were not seeded")
        try expect(Set(seeded.map(\.document)) == Set(ContinuityDocument.allCases),
                   "seeded document allowlist drifted")
        try expect(seeded.allSatisfy { mode(of: root.appendingPathComponent($0.document.rawValue)) == 0o600 },
                   "seeded document permissions are not 0600")
        let user = try await store.read(.user)
        try expect(user.content.contains("Maya"), "owner name did not reach a newly seeded USER.md")
        try expect(user.revision == ContinuityDocumentStore.revision(for: user.content)
                   && user.revision.count == 64,
                   "read snapshots do not carry SHA-256 revisions")

        let preserved = "# Existing soul\nDo not overwrite me.\n"
        let preservedRoot = sandbox.appendingPathComponent("preserved", isDirectory: true)
        try fileManager.createDirectory(at: preservedRoot, withIntermediateDirectories: true)
        try Data(preserved.utf8).write(to: preservedRoot.appendingPathComponent("SOUL.md"))
        let preservedStore = ContinuityDocumentStore(rootURL: preservedRoot, maximumDocumentBytes: 512)
        try await preservedStore.prepare(ownerDisplayName: "Nobody")
        let preservedSnapshot = try await preservedStore.read(.soul)
        try expect(preservedSnapshot.content == preserved,
                   "prepare overwrote an existing continuity document")

        let firstRevision = user.revision
        let revisedContent = user.content + "\n## Names\nMorgan is spelled M-o-r-g-a-n.\n"
        let revised = try await store.write(
            .user,
            content: revisedContent,
            expectedRevision: firstRevision
        )
        try expect(revised.content == revisedContent && revised.revision != firstRevision,
                   "an authorized revision was not saved")
        try expect(mode(of: root.appendingPathComponent("USER.md")) == 0o600,
                   "saved document permissions drifted")
        let history = try await store.history(.user)
        try expect(history.contains(where: { $0.revision == firstRevision })
                   && history.contains(where: { $0.revision == revised.revision && $0.isCurrent }),
                   "durable history did not retain both document revisions")
        let voiceCapsule = try await store.voiceIdentityCapsule()
        try expect(Set(voiceCapsule.sources) == Set(ContinuityDocument.allCases.map(\.rawValue)),
                   "the live voice kernel did not include all six editable documents")
        try expect(voiceCapsule.text.count <= 4_500
                   && voiceCapsule.text.contains("Morgan is spelled M-o-r-g-a-n")
                   && voiceCapsule.text.contains(String(revised.revision.prefix(10))),
                   "a saved Markdown edit was not causal in the bounded live voice kernel")
        let fullVoiceCapsule = try await store.voiceIdentityCapsule(
            maximumCharacters: 32_000
        )
        let currentDocuments = try await store.list()
        try expect(
            !fullVoiceCapsule.truncated
                && fullVoiceCapsule.text.count <= 32_000
                && currentDocuments.allSatisfy {
                    fullVoiceCapsule.text.contains($0.content)
                        && fullVoiceCapsule.text.contains(String($0.revision.prefix(10)))
                },
            "the replaceable live projection did not carry every fitting document byte-for-byte"
        )

        do {
            _ = try await store.write(
                .user,
                content: "stale overwrite",
                expectedRevision: firstRevision
            )
            throw VerificationFailure(description: "stale optimistic write was accepted")
        } catch ContinuityDocumentStoreError.revisionConflict(let expected, let actual) {
            try expect(expected == firstRevision && actual == revised.revision,
                       "revision conflict did not report expected and actual revisions")
        }

        let restored = try await store.restore(
            .user,
            revision: firstRevision,
            expectedRevision: revised.revision
        )
        try expect(restored.content == user.content && restored.revision == firstRevision,
                   "history restore did not recover the exact prior bytes")
        let restoredHistory = try await store.history(.user)
        try expect(restoredHistory.contains(where: { $0.revision == revised.revision }),
                   "restore discarded the version it replaced")

        do {
            _ = try ContinuityDocument(validatingFileName: "../SOUL.md")
            throw VerificationFailure(description: "path traversal entered the allowlist")
        } catch ContinuityDocumentStoreError.documentNotAllowed {}
        do {
            _ = try ContinuityDocument(validatingFileName: "RANDOM.md")
            throw VerificationFailure(description: "unknown Markdown entered the allowlist")
        } catch ContinuityDocumentStoreError.documentNotAllowed {}
        try expect(try ContinuityDocument(validatingFileName: "MEMORY.md") == .memory,
                   "an exact allowlisted name was rejected")

        let oversized = String(repeating: "x", count: 513)
        do {
            _ = try await store.write(.memory, content: oversized, expectedRevision: seededRevision(.memory, in: seeded))
            throw VerificationFailure(description: "oversized write was accepted")
        } catch ContinuityDocumentStoreError.documentTooLarge(.memory, let limit) {
            try expect(limit == 512, "oversized write reported the wrong bound")
        }

        try await verifyUnsafeFileKinds(in: sandbox)
        try await verifyExternalConflict(in: sandbox)

        let historyRoot = root.appendingPathComponent(".aurora-continuity-history", isDirectory: true)
        try expect(mode(of: historyRoot) == 0o700,
                   "history directory permissions are not 0700")
        let historyFiles = try recursiveFiles(at: historyRoot)
        try expect(!historyFiles.isEmpty && historyFiles.allSatisfy { mode(of: $0) == 0o600 },
                   "history files are missing or not private")
        try expect(try fileManager.contentsOfDirectory(atPath: root.path)
            .allSatisfy { !$0.hasPrefix(".aurora-continuity-write-") },
                   "atomic-write temporary files were left behind")
    }

    private static func verifyUnsafeFileKinds(in sandbox: URL) async throws {
        let fileManager = FileManager.default

        let symlinkRoot = sandbox.appendingPathComponent("symlink", isDirectory: true)
        try fileManager.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        try fileManager.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent("SOUL.md"),
            withDestinationURL: outside
        )
        let symlinkStore = ContinuityDocumentStore(rootURL: symlinkRoot, maximumDocumentBytes: 512)
        do {
            try await symlinkStore.prepare(ownerDisplayName: "Maya")
            throw VerificationFailure(description: "symbolic-link document was accepted")
        } catch ContinuityDocumentStoreError.symbolicLink(.soul) {}

        let hardlinkRoot = sandbox.appendingPathComponent("hardlink", isDirectory: true)
        try fileManager.createDirectory(at: hardlinkRoot, withIntermediateDirectories: true)
        let hardlink = hardlinkRoot.appendingPathComponent("SOUL.md")
        guard link(outside.path, hardlink.path) == 0 else {
            throw VerificationFailure(description: "test could not create hard link")
        }
        let hardlinkStore = ContinuityDocumentStore(rootURL: hardlinkRoot, maximumDocumentBytes: 512)
        do {
            try await hardlinkStore.prepare(ownerDisplayName: "Maya")
            throw VerificationFailure(description: "multiple-hard-link document was accepted")
        } catch ContinuityDocumentStoreError.multipleHardLinks(.soul) {}

        let directoryRoot = sandbox.appendingPathComponent("nonregular", isDirectory: true)
        try fileManager.createDirectory(
            at: directoryRoot.appendingPathComponent("SOUL.md", isDirectory: true),
            withIntermediateDirectories: true
        )
        let directoryStore = ContinuityDocumentStore(rootURL: directoryRoot, maximumDocumentBytes: 512)
        do {
            try await directoryStore.prepare(ownerDisplayName: "Maya")
            throw VerificationFailure(description: "non-regular document was accepted")
        } catch ContinuityDocumentStoreError.nonRegularFile(.soul) {}

        let actualRoot = sandbox.appendingPathComponent("actual-root", isDirectory: true)
        try fileManager.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let linkedRoot = sandbox.appendingPathComponent("linked-root", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: actualRoot)
        let linkedStore = ContinuityDocumentStore(rootURL: linkedRoot, maximumDocumentBytes: 512)
        do {
            try await linkedStore.prepare(ownerDisplayName: "Maya")
            throw VerificationFailure(description: "symbolic-link root was accepted")
        } catch ContinuityDocumentStoreError.unsafeRoot {}
    }

    private static func verifyExternalConflict(in sandbox: URL) async throws {
        let root = sandbox.appendingPathComponent("external-conflict", isDirectory: true)
        let store = ContinuityDocumentStore(rootURL: root, maximumDocumentBytes: 512)
        try await store.prepare(ownerDisplayName: "Maya")
        let original = try await store.read(.memory)
        let externallyChanged = original.content + "External writer.\n"
        try Data(externallyChanged.utf8).write(
            to: root.appendingPathComponent("MEMORY.md"),
            options: [.atomic]
        )
        do {
            _ = try await store.write(
                .memory,
                content: original.content + "Stale editor.\n",
                expectedRevision: original.revision
            )
            throw VerificationFailure(description: "external revision conflict was not detected")
        } catch ContinuityDocumentStoreError.revisionConflict(_, let actual) {
            try expect(actual == ContinuityDocumentStore.revision(for: externallyChanged),
                       "external revision conflict reported the wrong current digest")
        }
    }

    private static func seededRevision(
        _ document: ContinuityDocument,
        in snapshots: [ContinuityDocumentSnapshot]
    ) throws -> String {
        guard let revision = snapshots.first(where: { $0.document == document })?.revision else {
            throw VerificationFailure(description: "missing seeded revision")
        }
        return revision
    }

    private static func recursiveFiles(at root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func mode(of url: URL) -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return 0 }
        return status.st_mode & mode_t(0o777)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationFailure(description: message) }
    }
}
