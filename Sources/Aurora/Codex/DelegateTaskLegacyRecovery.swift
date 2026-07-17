import Darwin
import Foundation

struct DelegateTaskLegacyCandidate: Sendable, Equatable {
    let taskID: String
    let threadID: String
    let originatingSessionID: String
    let taskKind: DelegateTaskKind
    let rootAuthorizationID: String
    let sourceTurnID: String
    let goal: String
    let status: DelegateTaskStatus
    let revision: UInt64
    let stepCount: Int
    let effectVerified: Bool
    let createdAt: Date
    let updatedAt: Date
}
/// One-time migration for tasks created before the durable ledger existed.
/// Journal and audit data recover only the already-authorized identity binding;
/// live or terminal truth still comes exclusively from Codex thread/read.
struct DelegateTaskLegacyRecovery: Sendable {
    private struct Builder {
        var taskID: String
        var threadID: String?
        var sessionID: String
        var taskKind: DelegateTaskKind
        var sourceTurnID: String?
        var goal: String
        var status: DelegateTaskStatus
        var revision: UInt64
        var stepCount: Int
        var effectVerified: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    private struct AuditStart {
        let timestamp: Date
        let sessionID: String
        let authorizationID: String
    }

    let eventDirectory: URL
    let auditURL: URL

    init(
        eventDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Aurora/voice-events", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Aurora/voice-events",
                    isDirectory: true
                ),
        auditURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Aurora/tool-audit.jsonl", isDirectory: false)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Aurora/tool-audit.jsonl",
                    isDirectory: false
                )
    ) {
        self.eventDirectory = eventDirectory.standardizedFileURL
        self.auditURL = auditURL.standardizedFileURL
    }

    func discoverLatest() -> DelegateTaskLegacyCandidate? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let journalFiles = files
            .filter { $0.pathExtension.lowercased() == "ndjson" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .suffix(14)

        var latestOwnerItemBySession: [String: (id: String, text: String)] = [:]
        var builders: [String: Builder] = [:]
        for file in journalFiles {
            guard let data = try? readBoundedRegularFile(file, maximumBytes: 16 * 1_024 * 1_024)
            else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                      let kind = object["kind"] as? String,
                      let timestamp = Self.date(object["timestamp"]),
                      let sessionID = object["sessionID"] as? String else { continue }
                let metadata = object["metadata"] as? [String: String] ?? [:]
                if kind == "voice_transcription_final",
                   let itemID = metadata["item_id"],
                   let text = object["detail"] as? String,
                   Self.validIdentity(itemID) {
                    latestOwnerItemBySession[sessionID] = (itemID, text)
                    continue
                }
                guard kind.hasPrefix("delegate_task_"),
                      let taskID = metadata["task_id"],
                      let rawKind = metadata["task_kind"],
                      let taskKind = DelegateTaskKind(rawValue: rawKind),
                      taskKind.continuesAfterVoiceRest,
                      let rawStatus = metadata["status"],
                      let status = DelegateTaskStatus(rawValue: rawStatus),
                      Self.validIdentity(taskID) else { continue }

                if var builder = builders[taskID] {
                    builder.threadID = metadata["codex_thread_id"] ?? builder.threadID
                    builder.status = status
                    builder.revision = UInt64(metadata["revision"] ?? "") ?? builder.revision
                    builder.stepCount = Int(metadata["steps"] ?? "") ?? builder.stepCount
                    builder.effectVerified = Bool(metadata["effect_verified"] ?? "")
                        ?? builder.effectVerified
                    builder.updatedAt = max(builder.updatedAt, timestamp)
                    builders[taskID] = builder
                } else {
                    let source = latestOwnerItemBySession[sessionID]
                    builders[taskID] = Builder(
                        taskID: taskID,
                        threadID: metadata["codex_thread_id"],
                        sessionID: sessionID,
                        taskKind: taskKind,
                        sourceTurnID: source?.id,
                        goal: Self.boundedGoal(source?.text),
                        status: status,
                        revision: UInt64(metadata["revision"] ?? "") ?? 1,
                        stepCount: Int(metadata["steps"] ?? "") ?? 0,
                        effectVerified: Bool(metadata["effect_verified"] ?? "") ?? false,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
            }
        }

        let audits = auditStarts()
        return builders.values.compactMap { builder -> DelegateTaskLegacyCandidate? in
            guard let threadID = builder.threadID,
                  let sourceTurnID = builder.sourceTurnID,
                  Self.validIdentity(threadID),
                  let audit = audits
                    .filter({
                        $0.sessionID == builder.sessionID
                            && abs($0.timestamp.timeIntervalSince(builder.createdAt)) <= 5
                    })
                    .min(by: {
                        abs($0.timestamp.timeIntervalSince(builder.createdAt))
                            < abs($1.timestamp.timeIntervalSince(builder.createdAt))
                    }) else { return nil }
            return DelegateTaskLegacyCandidate(
                taskID: builder.taskID,
                threadID: threadID,
                originatingSessionID: builder.sessionID,
                taskKind: builder.taskKind,
                rootAuthorizationID: audit.authorizationID,
                sourceTurnID: sourceTurnID,
                goal: builder.goal,
                status: builder.status,
                revision: max(1, builder.revision),
                stepCount: max(0, builder.stepCount),
                effectVerified: builder.effectVerified,
                createdAt: builder.createdAt,
                updatedAt: builder.updatedAt
            )
        }.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func auditStarts() -> [AuditStart] {
        guard let data = try? readBoundedRegularFile(auditURL, maximumBytes: 8 * 1_024 * 1_024)
        else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  object["tool"] as? String == "delegate_task",
                  object["operation"] as? String == "start",
                  object["authorizationDecision"] as? String == "authorized",
                  let sessionID = object["sessionID"] as? String,
                  let authorizationID = object["authorizationID"] as? String,
                  let timestamp = Self.date(object["timestamp"]),
                  Self.validIdentity(sessionID),
                  Self.validIdentity(authorizationID) else { return nil }
            return AuditStart(
                timestamp: timestamp,
                sessionID: sessionID,
                authorizationID: authorizationID
            )
        }
    }

    private func readBoundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DelegateTaskStoreError.posix(errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == Darwin.geteuid(),
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw DelegateTaskStoreError.unsafeStateFile
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw DelegateTaskStoreError.posix(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else {
                throw DelegateTaskStoreError.stateTooLarge
            }
        }
        return data
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func boundedGoal(_ text: String?) -> String {
        let normalized = (text ?? "the delegated Codex task")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(2_000))
    }

    private static func validIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !trimmed.isEmpty
            && trimmed.count <= 256
            && trimmed.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
