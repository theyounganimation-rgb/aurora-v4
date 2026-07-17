import Foundation

enum AuroraSessionParticipant: Equatable, Sendable {
    case owner(displayName: String)
    case guest(displayName: String)
    case unknown

    var isOwner: Bool {
        if case .owner = self { return true }
        return false
    }

    var displayName: String? {
        switch self {
        case .owner(let name), .guest(let name): return name
        case .unknown: return nil
        }
    }

    var continuityLabel: String {
        switch self {
        case .owner(let name): return name
        case .guest(let name): return "Guest \(name)"
        case .unknown: return "Unknown speaker"
        }
    }
}

/// A Realtime Conversation may contain either owner-private context or a
/// guest-safe view, never both. Changing between these epochs requires a fresh
/// server Conversation; a prompt amendment inside the old Conversation is not
/// an information boundary because prior items remain visible to the model.
enum AuroraSessionPrivacyEpoch: Equatable, Sendable {
    case owner
    case guest(displayName: String)

    var isOwner: Bool {
        if case .owner = self { return true }
        return false
    }

    static func forParticipant(
        _ participant: AuroraSessionParticipant
    ) -> AuroraSessionPrivacyEpoch? {
        switch participant {
        case .owner:
            return .owner
        case .guest(let displayName):
            return .guest(displayName: displayName)
        case .unknown:
            return nil
        }
    }

    func requiresFreshConversation(
        for participant: AuroraSessionParticipant
    ) -> Bool {
        guard let target = Self.forParticipant(participant) else { return false }
        return target != self
    }
}

/// A deliberately conservative session-only participant boundary. It does not
/// pretend to be voice biometrics. It changes away from the configured owner
/// only after an explicit self-identification, so ordinary phrases such as
/// "I'm tired" or "this is ridiculous" can never create a guest identity.
struct SessionParticipantTracker: Sendable {
    let ownerName: String
    private(set) var current: AuroraSessionParticipant

    init(
        ownerName: String,
        startingParticipant: AuroraSessionParticipant? = nil
    ) {
        let bounded = SessionParticipantTracker.boundedName(ownerName) ?? "Owner"
        self.ownerName = bounded
        self.current = startingParticipant ?? .owner(displayName: bounded)
    }

    @discardableResult
    mutating func observe(transcript: String) -> AuroraSessionParticipant {
        let compact = String(transcript.prefix(500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return current }

        if explicitlyReturnsOwner(compact) {
            current = .owner(displayName: ownerName)
            return current
        }

        if let guestName = explicitGuestName(in: compact) {
            current = .guest(displayName: guestName)
        }
        return current
    }

    /// Recovers provenance after an earlier transcript outage only when the
    /// speaker explicitly identifies themself. Ordinary conversation cannot
    /// silently turn an unknown participant back into the configured owner.
    @discardableResult
    mutating func observeExplicitIdentification(
        transcript: String
    ) -> AuroraSessionParticipant? {
        let compact = String(transcript.prefix(500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        if explicitlyReturnsOwner(compact) {
            current = .owner(displayName: ownerName)
            return current
        }
        if let guestName = explicitGuestName(in: compact) {
            current = .guest(displayName: guestName)
            return current
        }
        return nil
    }

    private func explicitlyReturnsOwner(_ text: String) -> Bool {
        guard text.count <= 100 else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: ownerName)
        let pattern = "(?i)(?:^|[.!?]\\s*)(?:hi[, ]+)?(?:this is|i am|i['’]m)\\s+\(escaped)(?:\\s+here)?(?:[.!?]|$)|(?:^|[.!?]\\s*)\(escaped)\\s+here(?:[.!?]|$)"
        return firstCapture(pattern: pattern, in: text) != nil
    }

    private func explicitGuestName(in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: ownerName)
        let denialPattern = "(?i)\\bthis\\s+(?:is\\s+not|isn['’]t)\\s+\(escaped)\\b.{0,60}?\\bthis\\s+is\\s+([\\p{L}][\\p{L}'’.-]{0,39})"
        if let captured = firstCapture(pattern: denialPattern, in: text),
           let name = Self.boundedName(captured),
           name.caseInsensitiveCompare(ownerName) != .orderedSame {
            return name
        }

        let namedPattern = "(?i)\\bmy\\s+name\\s+is\\s+([\\p{L}][\\p{L}'’.-]{0,39})(?:[.!?,]|$)"
        if let captured = firstCapture(pattern: namedPattern, in: text),
           let name = Self.boundedName(captured),
           name.caseInsensitiveCompare(ownerName) != .orderedSame {
            return name
        }
        return nil
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else { return nil }
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[range])
    }

    private static func boundedName(_ value: String) -> String? {
        let compact = value
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ".,!?;:"))
            )
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !compact.isEmpty, compact.count <= 40,
              compact.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.letters.union(.whitespaces).contains(scalar)
                    || "'-.’".unicodeScalars.contains(scalar)
              }) else { return nil }
        return compact.prefix(1).uppercased() + compact.dropFirst()
    }
}
