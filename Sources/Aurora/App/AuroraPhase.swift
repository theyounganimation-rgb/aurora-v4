import Foundation

enum AuroraPhase: Equatable {
    case resting
    case connecting
    case listening
    case thinking
    case waitingToRetry
    case speaking
    case reconnecting
    case needsVoiceKey
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .waitingToRetry, .speaking, .reconnecting:
            return true
        case .resting, .needsVoiceKey, .failed:
            return false
        }
    }

    var quietLabel: String {
        switch self {
        case .resting: return "say “Hey Aurora”"
        case .connecting: return "reaching"
        case .listening: return "listening"
        case .thinking: return "with you"
        case .waitingToRetry: return "waiting a moment"
        case .speaking: return "speaking"
        case .reconnecting: return "returning"
        case .needsVoiceKey: return "voice key needed"
        case .failed: return "try again"
        }
    }
}

enum AuroraSessionRefreshGate {
    static func shouldRefresh(
        phase: AuroraPhase,
        hasActiveSpeech: Bool,
        hasToolWork: Bool,
        hasEvidenceWait: Bool,
        hasPendingEvidence: Bool
    ) -> Bool {
        phase == .listening
            && !hasActiveSpeech
            && !hasToolWork
            && !hasEvidenceWait
            && !hasPendingEvidence
    }
}

/// The Realtime transport emits `.listening` both when a turn is genuinely
/// resolved and as a transitional phase on speech-start. Keep the desktop
/// motor paused for the latter so it cannot act while the owner is talking.
enum AuroraDesktopMotorResumeGate {
    static func shouldResume(
        phase: AuroraPhase,
        userSpeechActive: Bool
    ) -> Bool {
        phase == .listening && !userSpeechActive
    }
}
