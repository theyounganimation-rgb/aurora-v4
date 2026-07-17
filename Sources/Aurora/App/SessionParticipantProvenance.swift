import Foundation

struct SessionParticipantInputEvidence: Equatable, Sendable {
    let itemID: String
    let transcript: String?
    let audioStartMilliseconds: Int?
    let audioEndMilliseconds: Int?
    let playbackRelationAtSpeechStart: RealtimeInputPlaybackRelation

    init(
        itemID: String,
        transcript: String?,
        audioStartMilliseconds: Int? = nil,
        audioEndMilliseconds: Int? = nil,
        playbackRelationAtSpeechStart: RealtimeInputPlaybackRelation = .none
    ) {
        self.itemID = itemID
        self.transcript = transcript
        self.audioStartMilliseconds = audioStartMilliseconds
        self.audioEndMilliseconds = audioEndMilliseconds
        self.playbackRelationAtSpeechStart = playbackRelationAtSpeechStart
    }
}

struct SessionParticipantProvenanceResolution: Sendable {
    let participantByInputItem: [String: AuroraSessionParticipant]
    let finalParticipant: AuroraSessionParticipant
    let mergedTailArtifactItemIDs: Set<String>
}

/// Replays explicit participant changes in committed-audio order. A missing
/// transcript normally creates a fail-closed provenance gap. The sole narrow
/// exception is a short post-playback VAD item whose server audio interval
/// overlaps the immediately following finalized item: those two commits are
/// causally one acoustic turn, not two independently attributable speakers.
enum SessionParticipantProvenanceResolver {
    /// The observed production fragment was 1,176 ms. Keep the allowance tight
    /// enough that a normal short utterance cannot qualify without the stronger
    /// post-playback and interval-overlap evidence as well.
    static let maximumTailArtifactDurationMilliseconds = 1_500

    static func resolve(
        ownerName: String,
        startingParticipant: AuroraSessionParticipant,
        authenticatedOwnerLocalSession: Bool,
        inputs: [SessionParticipantInputEvidence]
    ) -> SessionParticipantProvenanceResolution {
        var tracker = SessionParticipantTracker(
            ownerName: ownerName,
            startingParticipant: startingParticipant
        )
        var hasEarlierUnknownAudio = false
        var rebuilt: [String: AuroraSessionParticipant] = [:]
        var mergedTailArtifacts = Set<String>()
        rebuilt.reserveCapacity(inputs.count)

        for (index, input) in inputs.enumerated() {
            let compactTranscript = input.transcript?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let compactTranscript, !compactTranscript.isEmpty {
                if hasEarlierUnknownAudio {
                    if let explicit = tracker.observeExplicitIdentification(
                        transcript: compactTranscript
                    ) {
                        rebuilt[input.itemID] = explicit
                        hasEarlierUnknownAudio = false
                    } else {
                        rebuilt[input.itemID] = .unknown
                    }
                } else {
                    rebuilt[input.itemID] = tracker.observe(
                        transcript: compactTranscript
                    )
                }
                continue
            }

            if canMergeTailArtifact(
                at: index,
                inputs: inputs,
                authenticatedOwnerLocalSession: authenticatedOwnerLocalSession,
                currentParticipant: tracker.current,
                hasEarlierUnknownAudio: hasEarlierUnknownAudio
            ) {
                // Resolve the whole overlapping acoustic turn from its one
                // finalized transcript. An explicit guest introduction on the
                // following item therefore labels the fragment as guest too.
                var preview = tracker
                let followingTranscript = inputs[index + 1].transcript ?? ""
                rebuilt[input.itemID] = preview.observe(
                    transcript: followingTranscript
                )
                mergedTailArtifacts.insert(input.itemID)
                continue
            }

            rebuilt[input.itemID] = hasEarlierUnknownAudio ? .unknown : tracker.current
            hasEarlierUnknownAudio = true
        }

        return SessionParticipantProvenanceResolution(
            participantByInputItem: rebuilt,
            finalParticipant: tracker.current,
            mergedTailArtifactItemIDs: mergedTailArtifacts
        )
    }

    private static func canMergeTailArtifact(
        at index: Int,
        inputs: [SessionParticipantInputEvidence],
        authenticatedOwnerLocalSession: Bool,
        currentParticipant: AuroraSessionParticipant,
        hasEarlierUnknownAudio: Bool
    ) -> Bool {
        guard authenticatedOwnerLocalSession,
              currentParticipant.isOwner,
              !hasEarlierUnknownAudio,
              index + 1 < inputs.count else { return false }

        let fragment = inputs[index]
        let following = inputs[index + 1]
        guard fragment.playbackRelationAtSpeechStart
                == .recentlyCompletedAssistantPlayback,
              let fragmentStart = fragment.audioStartMilliseconds,
              let fragmentEnd = fragment.audioEndMilliseconds,
              fragmentEnd > fragmentStart,
              fragmentEnd - fragmentStart <= maximumTailArtifactDurationMilliseconds,
              let followingStart = following.audioStartMilliseconds,
              let followingEnd = following.audioEndMilliseconds,
              followingEnd > followingStart,
              followingStart >= fragmentStart,
              followingStart < fragmentEnd,
              let followingTranscript = following.transcript,
              !followingTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else { return false }
        return true
    }
}
