import Darwin
import Foundation

/// The only payload the native inner-life runtime accepts from another Aurora
/// surface. It deliberately carries no transcript, topic, channel identifier,
/// tool result, or instruction.
struct ExternalOwnerContactMarker: Equatable, Sendable {
    let eventID: String
    let at: Date
    let source: String
}

enum ExternalOwnerContactBridgeError: LocalizedError {
    case unsafeDirectory
    case unsafeMarkerFile
    case markerTooLarge
    case invalidMarker
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "Aurora's external-contact directory is not private and safe."
        case .unsafeMarkerFile:
            return "Aurora's external-contact marker is not a private regular file."
        case .markerTooLarge:
            return "Aurora's external-contact marker exceeded its bounded size."
        case .invalidMarker:
            return "Aurora's external-contact marker is malformed."
        case .posix(let code):
            return "Aurora could not read external contact (system error \(code))."
        }
    }
}

/// Read-only, no-follow bridge from an owner-verified external surface into
/// Aurora's native relationship clock. Invalid input is rejected by this type;
/// the runtime treats bridge failure as absence of evidence rather than making
/// her durable inner life unavailable.
struct ExternalOwnerContactBridge: Sendable {
    static let expectedSource = "openclaw_owner_channel"
    static let maximumMarkerBytes = 16 * 1_024

    let fileURL: URL

    init(
        fileURL: URL = AuroraPaths.applicationSupport
            .appendingPathComponent("external-contact", isDirectory: true)
            .appendingPathComponent("last-owner-contact.json", isDirectory: false)
    ) {
        self.fileURL = fileURL.standardizedFileURL
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let eventID: String
        let at: String
        let source: String
    }

    func latestContact(referenceDate: Date) throws -> ExternalOwnerContactMarker? {
        let directoryURL = fileURL.deletingLastPathComponent()

        var pathStatus = stat()
        let statusResult = directoryURL.path.withCString { Darwin.lstat($0, &pathStatus) }
        if statusResult != 0 {
            if errno == ENOENT { return nil }
            throw ExternalOwnerContactBridgeError.unsafeDirectory
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              pathStatus.st_uid == Darwin.geteuid(),
              (pathStatus.st_mode & mode_t(0o077)) == 0 else {
            throw ExternalOwnerContactBridgeError.unsafeDirectory
        }

        let directoryFD = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw ExternalOwnerContactBridgeError.unsafeDirectory
            }
            throw ExternalOwnerContactBridgeError.posix(errno)
        }
        defer { Darwin.close(directoryFD) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryFD, &directoryStatus) == 0 else {
            throw ExternalOwnerContactBridgeError.posix(errno)
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_dev == pathStatus.st_dev,
              directoryStatus.st_ino == pathStatus.st_ino,
              directoryStatus.st_uid == Darwin.geteuid(),
              (directoryStatus.st_mode & mode_t(0o077)) == 0 else {
            throw ExternalOwnerContactBridgeError.unsafeDirectory
        }

        let markerFD = Darwin.openat(
            directoryFD,
            fileURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if markerFD < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ExternalOwnerContactBridgeError.unsafeMarkerFile }
            throw ExternalOwnerContactBridgeError.posix(errno)
        }
        defer { Darwin.close(markerFD) }

        var markerStatus = stat()
        guard Darwin.fstat(markerFD, &markerStatus) == 0 else {
            throw ExternalOwnerContactBridgeError.posix(errno)
        }
        guard (markerStatus.st_mode & S_IFMT) == S_IFREG,
              markerStatus.st_nlink == 1,
              markerStatus.st_uid == Darwin.geteuid(),
              (markerStatus.st_mode & mode_t(0o077)) == 0 else {
            throw ExternalOwnerContactBridgeError.unsafeMarkerFile
        }
        guard markerStatus.st_size >= 0,
              markerStatus.st_size <= Self.maximumMarkerBytes else {
            throw ExternalOwnerContactBridgeError.markerTooLarge
        }

        let data = try readAll(from: markerFD, expectedBytes: Int(markerStatus.st_size))
        return try decode(data, referenceDate: referenceDate)
    }

    private func decode(_ data: Data, referenceDate: Date) throws -> ExternalOwnerContactMarker {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["schemaVersion", "eventID", "at", "source"]),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == 1,
              payload.source == Self.expectedSource,
              let at = parseISO8601(payload.at),
              validEventID(payload.eventID, at: at),
              at <= referenceDate.addingTimeInterval(5 * 60) else {
            throw ExternalOwnerContactBridgeError.invalidMarker
        }
        return ExternalOwnerContactMarker(
            eventID: payload.eventID,
            at: at,
            source: payload.source
        )
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    /// Accept only the opaque identifier emitted by the owner-channel writer:
    /// `openclaw-owner-<epoch_ms>-<lowercase UUID>`. Besides bounding replay
    /// identity, matching the embedded clock prevents the identifier from
    /// becoming a covert prose field.
    private func validEventID(_ eventID: String, at: Date) -> Bool {
        let parts = eventID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 8,
              parts[0] == "openclaw",
              parts[1] == "owner",
              parts[2].count == 13,
              parts[2].allSatisfy({ $0.isNumber }),
              let milliseconds = Int64(parts[2]),
              lowerHex(parts[3], count: 8),
              lowerHex(parts[4], count: 4),
              lowerHex(parts[5], count: 4),
              lowerHex(parts[6], count: 4),
              lowerHex(parts[7], count: 12),
              ["1", "2", "3", "4", "5"].contains(String(parts[5].prefix(1))),
              ["8", "9", "a", "b"].contains(String(parts[6].prefix(1))) else {
            return false
        }
        let embeddedDate = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return abs(embeddedDate.timeIntervalSince(at)) <= 2
    }

    private func lowerHex(_ value: Substring, count: Int) -> Bool {
        let allowed = Set("0123456789abcdef")
        return value.count == count && value.allSatisfy { allowed.contains($0) }
    }

    private func readAll(from descriptor: Int32, expectedBytes: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: min(4_096, max(1, expectedBytes)))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExternalOwnerContactBridgeError.posix(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > Self.maximumMarkerBytes {
                throw ExternalOwnerContactBridgeError.markerTooLarge
            }
        }
        return data
    }
}
