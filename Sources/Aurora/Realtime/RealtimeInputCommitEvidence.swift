import Foundation

/// Host-observed playback state at the beginning of a server VAD boundary.
/// This is causal transport evidence, never a speaker guess.
enum RealtimeInputPlaybackRelation: String, Equatable, Sendable {
    case none
    /// Speech began while assistant audio was still in the playback engine.
    /// This is a real barge-in boundary and must never be treated as tail echo.
    case activeAssistantPlayback
    /// Speech began shortly after a fully played assistant item drained.
    /// It is only a tail-artifact candidate; overlapping audio and transcript
    /// evidence still have to establish that two commits were one acoustic turn.
    case recentlyCompletedAssistantPlayback
}

/// A committed Realtime input item plus the server and local timing evidence
/// that created it. Natural-language content is deliberately absent.
struct RealtimeInputCommitEvent: Equatable, Sendable {
    let connectionID: UUID
    let itemID: String
    let audioStartMilliseconds: Int?
    let audioEndMilliseconds: Int?
    let playbackRelationAtSpeechStart: RealtimeInputPlaybackRelation
}
