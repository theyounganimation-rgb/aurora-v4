import Foundation
import Security

protocol AuroraCompanionPairingStoring: AnyObject {
    func secret() throws -> Data
    func pairingCode(at date: Date) -> String
}

extension AuroraCompanionPairingStoring {
    func pairingCode() -> String { pairingCode(at: Date()) }
}

final class AuroraCompanionPairingStore: AuroraCompanionPairingStoring {
    private static let service = "ai.aurora.voice.companion"
    private static let account = "pairing-secret-v1"
    private let lock = NSLock()
    private var cachedSecret: Data?

    func secret() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSecret { return cachedSecret }
        if let stored = try load() {
            guard stored.count == 32 else {
                throw AuroraCompanionProtocolError.unavailable
            }
            cachedSecret = stored
            return stored
        }
        let created = AuroraCompanionProtocol.randomData(count: 32)
        try save(created)
        cachedSecret = created
        return created
    }

    func pairingCode(at date: Date) -> String {
        guard let secret = try? secret() else { return "Unavailable" }
        return AuroraCompanionProtocol.pairingCode(secret: secret, at: date)
    }

    private func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuroraCompanionProtocolError.unavailable
        }
        return data
    }

    private func save(_ secret: Data) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw AuroraCompanionProtocolError.unavailable
        }
        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw AuroraCompanionProtocolError.unavailable
        }
    }
}
