import Foundation
import Security

enum KeychainVoiceKeyError: LocalizedError {
    case malformedValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .malformedValue:
            return "Aurora's saved voice key could not be read."
        case .keychain(let status):
            // securityd returns this legacy CSSM status when an app bundle is
            // replaced while its old process is still alive. The old process
            // then points at the installer's removed `.previous` bundle, so
            // Keychain can no longer validate its path-bound ACL subject.
            if status == 100_002 {
                return "Aurora was updated while she was still open. Quit Aurora completely, then reopen her."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "macOS Keychain error: \(message)"
        }
    }
}

enum KeychainVoiceKey {
    static let service = "ai.aurora.voice"
    static let legacyService = "ai.openclaw.aurora-realtime"
    static let account = "openai"

    static func load() throws -> String? {
        if let current = try load(service: service) {
            // Reading must be read-only. Rewriting the protected item every
            // time the owner presses Talk needlessly re-enters Keychain ACL
            // authorization and can invalidate an “Always Allow” decision.
            return current
        }
        // One-time, non-destructive migration from the earlier OpenClaw
        // experiment. Aurora's native app owns its credential from here on.
        if let legacy = try load(service: legacyService) {
            try save(legacy)
            return legacy
        }
        return nil
    }

    private static func load(service selectedService: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: selectedService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainVoiceKeyError.keychain(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            throw KeychainVoiceKeyError.malformedValue
        }
        return value
    }

    static func save(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw KeychainVoiceKeyError.malformedValue }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainVoiceKeyError.keychain(updated) }

        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainVoiceKeyError.keychain(added) }
    }
}

/// Keeps one successfully unlocked credential in memory for the lifetime of
/// the Aurora process. Resting and waking voice again therefore does not ask
/// macOS Keychain to authorize the same item on every Talk press. The value is
/// never persisted anywhere except the existing Keychain item.
final class VoiceKeySessionCache {
    typealias Loader = () throws -> String?
    typealias Saver = (String) throws -> Void

    private let loader: Loader
    private let saver: Saver
    private var cachedValue: String?

    init(
        loader: @escaping Loader = KeychainVoiceKey.load,
        saver: @escaping Saver = KeychainVoiceKey.save
    ) {
        self.loader = loader
        self.saver = saver
    }

    func load() throws -> String? {
        if let cachedValue { return cachedValue }
        let loaded = try loader()
        cachedValue = loaded
        return loaded
    }

    func save(_ value: String) throws {
        try saver(value)
        cachedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
