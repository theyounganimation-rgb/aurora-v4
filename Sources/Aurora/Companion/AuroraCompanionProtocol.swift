import CryptoKit
import Foundation
import Security

enum AuroraCompanionMessageType: String, Codable, Sendable {
    case challenge
    case pairRequest = "pair_request"
    case pairAccepted = "pair_accepted"
    case authenticate
    case authenticated
    case wake
    case rest
    case state
    case audioStart = "audio_start"
    case microphone
    case playback
    case playbackItemComplete = "playback_item_complete"
    case playbackInterrupt = "playback_interrupt"
    case audioStop = "audio_stop"
    case playbackProgress = "playback_progress"
    case playbackFinished = "playback_finished"
    case playbackIdle = "playback_idle"
    case outputLevel = "output_level"
    case ping
    case pong
    case error
}

/// The companion wire contract is intentionally small: the iPhone carries
/// audio and presence, while the Mac remains Aurora's only cognition, memory,
/// Realtime, and task authority.
struct AuroraCompanionEnvelope: Codable, Sendable, Equatable {
    var version: Int = AuroraCompanionProtocol.version
    var type: AuroraCompanionMessageType
    var sequence: UInt64
    var generation: String?
    var nonce: String?
    var serverSessionID: String?
    var clientNonce: String?
    var deviceID: String?
    var proof: String?
    var pairingCode: String?
    var pairingSecret: String?
    var phase: String?
    var detail: String?
    /// The selected Mac audio route: `local` or `remote`.
    var audioRoute: String?
    /// The active voice-session owner: `none`, `mac`, or `iphone`.
    var sessionOwner: String?
    var inputLevel: Float?
    var outputLevel: Float?
    var audio: Data?
    var responseID: String?
    var itemID: String?
    var contentIndex: Int?
    var frameCount: Int64?

    init(type: AuroraCompanionMessageType, sequence: UInt64) {
        self.type = type
        self.sequence = sequence
    }
}

enum AuroraCompanionProtocolError: LocalizedError, Equatable {
    case frameTooLarge
    case malformedFrame
    case unsupportedVersion
    case outOfOrderSequence
    case audioTooLarge
    case authenticationFailed
    case authenticationTimeout
    case untrustedTransport
    case authenticationProtocol
    case pairingFailed
    case unavailable
    case connectionLost

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: return "The companion sent an oversized message."
        case .malformedFrame: return "The companion sent a malformed message."
        case .unsupportedVersion: return "The iPhone app needs to be updated with Aurora."
        case .outOfOrderSequence: return "The companion connection became out of order."
        case .audioTooLarge: return "The companion sent an oversized audio frame."
        case .authenticationFailed: return "Aurora could not verify this iPhone."
        case .authenticationTimeout: return "The iPhone did not finish connecting in time."
        case .untrustedTransport: return "The iPhone connection did not arrive through Tailscale."
        case .authenticationProtocol: return "The iPhone authentication exchange was invalid."
        case .pairingFailed: return "That pairing code was not accepted."
        case .unavailable: return "Aurora's iPhone companion is not connected."
        case .connectionLost: return "Aurora's iPhone audio path disconnected."
        }
    }
}

enum AuroraCompanionProtocol {
    static let version = 1
    static let port: UInt16 = 47_821
    static let tailscalePort: UInt16 = 8_443
    static let maximumFrameBytes = 256 * 1_024
    static let maximumAudioBytes = 64 * 1_024
    static let pairingWindowSeconds: TimeInterval = 10 * 60
    /// Pairing is interactive: the owner must have enough time to read and enter
    /// the code before this unauthenticated socket is retired.
    static let interactiveAuthenticationTimeoutSeconds: TimeInterval = 3 * 60

    /// Private companion routing is deployment configuration, never public
    /// source. With no configured peers the production transport fails closed.
    /// Values may be supplied through the process environment or matching
    /// Info.plist string entries in a private build.
    static let allowedPeerAddressesConfigurationKey =
        "AURORA_COMPANION_ALLOWED_PEERS"
    static let serviceHostConfigurationKey =
        "AURORA_COMPANION_SERVICE_HOST"

    static var allowedTailscalePeerAddresses: Set<String> {
        guard let value = configuredValue(
            for: allowedPeerAddressesConfigurationKey
        ) else { return [] }
        let separators = CharacterSet(charactersIn: ",;")
            .union(.whitespacesAndNewlines)
        return Set(
            value
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// The private iPhone prototype consumes this host in its own build. The
    /// public Mac source intentionally has no default network endpoint.
    static var serviceHost: String? {
        configuredValue(for: serviceHostConfigurationKey)
    }

    /// Compatibility accessors keep standalone protocol verifiers source-
    /// compatible while still deriving every value from private configuration.
    static var allowedTailscalePeerIPv4: String {
        allowedTailscalePeerAddresses.first(where: { $0.contains(".") }) ?? ""
    }

    static var allowedTailscalePeerIPv6: String {
        allowedTailscalePeerAddresses.first(where: { $0.contains(":") }) ?? ""
    }

    static func encode(_ envelope: AuroraCompanionEnvelope) throws -> Data {
        let payload = try JSONEncoder().encode(envelope)
        guard payload.count <= maximumFrameBytes else {
            throw AuroraCompanionProtocolError.frameTooLarge
        }
        let count = UInt32(payload.count)
        var framed = Data(capacity: payload.count + 4)
        framed.append(UInt8((count >> 24) & 0xff))
        framed.append(UInt8((count >> 16) & 0xff))
        framed.append(UInt8((count >> 8) & 0xff))
        framed.append(UInt8(count & 0xff))
        framed.append(payload)
        return framed
    }

    static func clientProof(
        secret: Data,
        serverNonce: String,
        clientNonce: String,
        deviceID: String
    ) -> String {
        hmac(
            secret: secret,
            text: "aurora-companion-v1|\(serverNonce)|\(clientNonce)|\(deviceID)"
        )
    }

    static func serverProof(
        secret: Data,
        serverNonce: String,
        clientNonce: String,
        deviceID: String
    ) -> String {
        hmac(
            secret: secret,
            text: "aurora-companion-v1-server|\(serverNonce)|\(clientNonce)|\(deviceID)"
        )
    }

    static func pairingCode(secret: Data, at date: Date = Date()) -> String {
        let bucket = Int64(floor(date.timeIntervalSince1970 / pairingWindowSeconds))
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("aurora-companion-pair|\(bucket)".utf8),
            using: SymmetricKey(data: secret)
        )
        let bytes = Array(digest.prefix(4))
        let number = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100_000_000
        return String(format: "%08u", number)
    }

    static func acceptsPairingCode(
        _ candidate: String,
        secret: Data,
        at date: Date = Date()
    ) -> Bool {
        let normalized = candidate.filter(\.isNumber)
        guard normalized.count == 8 else { return false }
        if constantTimeEqual(normalized, pairingCode(secret: secret, at: date)) {
            return true
        }
        return constantTimeEqual(
            normalized,
            pairingCode(secret: secret, at: date.addingTimeInterval(-pairingWindowSeconds))
        )
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure randomness must be available")
        return Data(bytes)
    }

    private static func hmac(secret: Data, text: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(text.utf8),
            using: SymmetricKey(data: secret)
        )
        return Data(code).base64EncodedString()
    }

    private static func configuredValue(for key: String) -> String? {
        let environmentValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return environmentValue
        }
        let bundleValue = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleValue, !bundleValue.isEmpty else { return nil }
        return bundleValue
    }
}

struct AuroraCompanionFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [AuroraCompanionEnvelope] {
        buffer.append(data)
        var messages: [AuroraCompanionEnvelope] = []
        while buffer.count >= 4 {
            let count = Int(buffer[buffer.startIndex]) << 24
                | Int(buffer[buffer.startIndex + 1]) << 16
                | Int(buffer[buffer.startIndex + 2]) << 8
                | Int(buffer[buffer.startIndex + 3])
            guard count > 0, count <= AuroraCompanionProtocol.maximumFrameBytes else {
                throw AuroraCompanionProtocolError.frameTooLarge
            }
            guard buffer.count >= count + 4 else { break }
            let payload = Data(buffer[(buffer.startIndex + 4)..<(buffer.startIndex + 4 + count)])
            buffer.removeFirst(count + 4)
            let envelope: AuroraCompanionEnvelope
            do {
                envelope = try JSONDecoder().decode(AuroraCompanionEnvelope.self, from: payload)
            } catch {
                throw AuroraCompanionProtocolError.malformedFrame
            }
            guard envelope.version == AuroraCompanionProtocol.version else {
                throw AuroraCompanionProtocolError.unsupportedVersion
            }
            if let audio = envelope.audio,
               audio.count > AuroraCompanionProtocol.maximumAudioBytes {
                throw AuroraCompanionProtocolError.audioTooLarge
            }
            messages.append(envelope)
        }
        return messages
    }
}
