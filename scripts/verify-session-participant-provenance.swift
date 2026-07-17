import Foundation

enum ParticipantProvenanceVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
enum SessionParticipantProvenanceVerifier {
    private static var checks = 0

    static func main() throws {
        try productionTailOverlapTraceDoesNotPoisonOwner()
        try genuineUnknownAndRemoteAudioRemainUnknown()
        try explicitGuestIdentitySurvivesOverlap()
        try activePlaybackInterruptionIsNeverTailMerged()
        try outOfOrderTranscriptCorrectsTheWholeAcousticTurn()
        try privacyEpochChangesRequireFreshConversation()

        let output: [String: Any] = [
            "ok": true,
            "checks": checks,
            "maximum_tail_artifact_ms": SessionParticipantProvenanceResolver
                .maximumTailArtifactDurationMilliseconds,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func productionTailOverlapTraceDoesNotPoisonOwner() throws {
        let resolution = resolve([
            evidence("owner-before", transcript: "What memories do you have?"),
            // Exact production trace: 1,176 ms tail fragment followed by the
            // real turn beginning 472 ms before the fragment boundary ended.
            evidence(
                "tail-fragment",
                transcript: nil,
                start: 146_600,
                end: 147_776,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "owner-overlap",
                transcript: "What do you remember about me?",
                start: 147_304,
                end: 149_952
            ),
            evidence("owner-after", transcript: "Is that all you know?"),
        ])

        try expect(
            resolution.mergedTailArtifactItemIDs == ["tail-fragment"],
            "the exact production tail fragment was not causally merged"
        )
        for itemID in ["owner-before", "tail-fragment", "owner-overlap", "owner-after"] {
            try expect(
                resolution.participantByInputItem[itemID] == .owner(displayName: "Avery"),
                "the production overlap poisoned \(itemID) as non-owner"
            )
        }
        try expect(
            resolution.finalParticipant == .owner(displayName: "Avery"),
            "the production overlap changed the session participant"
        )
    }

    private static func genuineUnknownAndRemoteAudioRemainUnknown() throws {
        let nonOverlapping = resolve([
            evidence(
                "missing-real-turn",
                transcript: nil,
                start: 10_000,
                end: 11_100,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "later-turn",
                transcript: "Open my notes.",
                start: 11_250,
                end: 12_300
            ),
        ])
        try expect(
            nonOverlapping.mergedTailArtifactItemIDs.isEmpty,
            "non-overlapping unknown audio was discarded as tail echo"
        )
        try expect(
            nonOverlapping.participantByInputItem["later-turn"] == .unknown,
            "a genuine transcript gap did not fail closed"
        )

        let unauthenticated = resolve([
            evidence(
                "remote-fragment",
                transcript: nil,
                start: 20_000,
                end: 21_100,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "remote-followup",
                transcript: "Open my notes.",
                start: 20_700,
                end: 22_100
            ),
        ], authenticatedOwnerLocalSession: false)
        try expect(
            unauthenticated.mergedTailArtifactItemIDs.isEmpty,
            "overlap bypassed the authenticated owner-local session boundary"
        )
        try expect(
            unauthenticated.participantByInputItem["remote-followup"] == .unknown,
            "unauthenticated overlapping audio inherited owner provenance"
        )

        let tooLong = resolve([
            evidence(
                "long-fragment",
                transcript: nil,
                start: 25_000,
                end: 26_501,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "long-followup",
                transcript: "This is still one thought.",
                start: 26_000,
                end: 27_400
            ),
        ])
        try expect(
            tooLong.mergedTailArtifactItemIDs.isEmpty,
            "an ordinary-length transcriptless utterance was treated as a short tail artifact"
        )
        try expect(
            tooLong.participantByInputItem["long-followup"] == .unknown,
            "the short-fragment duration bound did not fail closed"
        )
    }

    private static func explicitGuestIdentitySurvivesOverlap() throws {
        let resolution = resolve([
            evidence(
                "guest-tail-fragment",
                transcript: nil,
                start: 30_000,
                end: 31_200,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "guest-introduction",
                transcript: "This isn't Avery, this is Morgan.",
                start: 30_800,
                end: 32_500
            ),
            evidence("guest-followup", transcript: "Tell me about Aurora."),
        ])
        for itemID in ["guest-tail-fragment", "guest-introduction", "guest-followup"] {
            try expect(
                resolution.participantByInputItem[itemID] == .guest(displayName: "Morgan"),
                "explicit guest identity was weakened for \(itemID)"
            )
        }
        try expect(
            resolution.finalParticipant == .guest(displayName: "Morgan"),
            "explicit guest identity did not remain active"
        )
    }

    private static func activePlaybackInterruptionIsNeverTailMerged() throws {
        let resolution = resolve([
            evidence(
                "barge-in-fragment",
                transcript: nil,
                start: 40_000,
                end: 41_200,
                relation: .activeAssistantPlayback
            ),
            evidence(
                "barge-in-followup",
                transcript: "No, stop. Listen to me.",
                start: 40_700,
                end: 42_600
            ),
        ])
        try expect(
            resolution.mergedTailArtifactItemIDs.isEmpty,
            "a real active-playback interruption was mistaken for completed-playback tail"
        )
        try expect(
            resolution.participantByInputItem["barge-in-followup"] == .unknown,
            "a transcriptless interruption weakened the fail-closed boundary"
        )
    }

    private static func outOfOrderTranscriptCorrectsTheWholeAcousticTurn() throws {
        let early = resolve([
            evidence(
                "late-first-transcript",
                transcript: nil,
                start: 50_000,
                end: 51_100,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "early-second-transcript",
                transcript: "Can you open Notes?",
                start: 50_650,
                end: 52_200
            ),
        ])
        try expect(
            early.participantByInputItem["early-second-transcript"]
                == .owner(displayName: "Avery"),
            "the finalized half of one overlapping owner turn stayed poisoned"
        )

        let corrected = resolve([
            evidence(
                "late-first-transcript",
                transcript: "This isn't Avery, this is Morgan.",
                start: 50_000,
                end: 51_100,
                relation: .recentlyCompletedAssistantPlayback
            ),
            evidence(
                "early-second-transcript",
                transcript: "Can you open Notes?",
                start: 50_650,
                end: 52_200
            ),
            evidence("after-correction", transcript: "Start a new one."),
        ])
        try expect(
            corrected.participantByInputItem["late-first-transcript"]
                == .guest(displayName: "Morgan"),
            "late explicit identification did not correct its own item"
        )
        try expect(
            corrected.participantByInputItem["early-second-transcript"]
                == .guest(displayName: "Morgan"),
            "late explicit identification did not correct the overlapping item"
        )
        try expect(
            corrected.participantByInputItem["after-correction"]
                == .guest(displayName: "Morgan"),
            "late guest identification did not govern later committed audio"
        )
    }

    private static func privacyEpochChangesRequireFreshConversation() throws {
        let owner = AuroraSessionPrivacyEpoch.owner
        try expect(
            !owner.requiresFreshConversation(
                for: .owner(displayName: "Avery")
            ),
            "an owner turn unnecessarily replaced its clean owner Conversation"
        )
        try expect(
            owner.requiresFreshConversation(
                for: .guest(displayName: "Morgan")
            ),
            "a newly identified guest could inherit an owner-private Conversation"
        )
        let guest = AuroraSessionPrivacyEpoch.guest(displayName: "Morgan")
        try expect(
            !guest.requiresFreshConversation(
                for: .guest(displayName: "Morgan")
            ),
            "ordinary guest continuity unnecessarily replaced its clean epoch"
        )
        try expect(
            guest.requiresFreshConversation(
                for: .owner(displayName: "Avery")
            ),
            "the returning owner could not regain a fresh owner-private Conversation"
        )
        try expect(
            !guest.requiresFreshConversation(for: .unknown),
            "unknown provenance was converted into a participant identity"
        )
    }

    private static func resolve(
        _ inputs: [SessionParticipantInputEvidence],
        authenticatedOwnerLocalSession: Bool = true
    ) -> SessionParticipantProvenanceResolution {
        SessionParticipantProvenanceResolver.resolve(
            ownerName: "Avery",
            startingParticipant: .owner(displayName: "Avery"),
            authenticatedOwnerLocalSession: authenticatedOwnerLocalSession,
            inputs: inputs
        )
    }

    private static func evidence(
        _ itemID: String,
        transcript: String?,
        start: Int? = nil,
        end: Int? = nil,
        relation: RealtimeInputPlaybackRelation = .none
    ) -> SessionParticipantInputEvidence {
        SessionParticipantInputEvidence(
            itemID: itemID,
            transcript: transcript,
            audioStartMilliseconds: start,
            audioEndMilliseconds: end,
            playbackRelationAtSpeechStart: relation
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        checks += 1
        guard condition() else {
            throw ParticipantProvenanceVerificationFailure.failed(message)
        }
    }
}
