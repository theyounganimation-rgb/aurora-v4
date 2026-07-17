import Foundation

struct AuroraOwnerProfile: Equatable, Sendable {
    let displayName: String
}

struct AuroraOwnerProfileBootstrap: Equatable, Sendable {
    let profile: AuroraOwnerProfile?
    let requiresFirstRunOnboarding: Bool
}

enum AuroraOwnerProfileError: LocalizedError, Equatable {
    case invalidDisplayName

    var errorDescription: String? {
        switch self {
        case .invalidDisplayName:
            return "Enter the name Aurora should use for you."
        }
    }
}

enum AuroraOnboardingMode: String, Equatable, Sendable {
    case firstRun
    case addVoiceKey
    case changeVoiceKey

    var canCancel: Bool { self != .firstRun }
}

/// Stores the small, non-secret local identity needed before Aurora can build
/// a personalized voice session. A missing profile always returns to onboarding
/// instead of guessing a public user's name from unrelated support files.
final class OwnerProfileStore {
    private static let displayNameKey = "owner-profile.display-name"
    private static let schemaVersionKey = "owner-profile.schema-version"
    private static let onboardingPendingKey = "owner-profile.onboarding-pending"
    private static let currentSchemaVersion = 1

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        fileManager _: FileManager = .default,
        applicationSupportURL _: URL = AuroraPaths.applicationSupport
    ) {
        self.defaults = defaults
    }

    func bootstrap() -> AuroraOwnerProfileBootstrap {
        if let stored = defaults.string(forKey: Self.displayNameKey),
           let normalized = try? validatedDisplayName(stored) {
            defaults.removeObject(forKey: Self.onboardingPendingKey)
            return AuroraOwnerProfileBootstrap(
                profile: AuroraOwnerProfile(displayName: normalized),
                requiresFirstRunOnboarding: false
            )
        }

        // A first launch can create inner-life support files before the person
        // finishes onboarding. Keep that interrupted setup in onboarding on
        // relaunch; local files are never evidence of a person's name.
        if defaults.bool(forKey: Self.onboardingPendingKey) {
            return AuroraOwnerProfileBootstrap(
                profile: nil,
                requiresFirstRunOnboarding: true
            )
        }

        defaults.set(true, forKey: Self.onboardingPendingKey)
        return AuroraOwnerProfileBootstrap(
            profile: nil,
            requiresFirstRunOnboarding: true
        )
    }

    @discardableResult
    func save(displayName: String) throws -> AuroraOwnerProfile {
        let profile = AuroraOwnerProfile(
            displayName: try validatedDisplayName(displayName)
        )
        persist(profile)
        return profile
    }

    func validatedDisplayName(_ value: String) throws -> String {
        guard value.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.newlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }) else {
            throw AuroraOwnerProfileError.invalidDisplayName
        }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.count <= 80,
              normalized.unicodeScalars.contains(where: {
                  CharacterSet.letters.union(.decimalDigits).contains($0)
              }),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains(scalar)
                      || "'-.’".unicodeScalars.contains(scalar)
              }) else {
            throw AuroraOwnerProfileError.invalidDisplayName
        }
        return normalized
    }

    private func persist(_ profile: AuroraOwnerProfile) {
        defaults.set(profile.displayName, forKey: Self.displayNameKey)
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
        defaults.removeObject(forKey: Self.onboardingPendingKey)
    }
}
