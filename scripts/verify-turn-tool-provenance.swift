import Darwin
import Foundation

private enum ToolProvenanceVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
private enum ToolProvenanceVerification {
    static func main() {
        do {
            try verifyDelayedAcknowledgementLifecycle()
            try verifyBoundedRetentionAndCleanup()
            let payload: [String: Any] = [
                "ok": true,
                "checks": [
                    "addressedToolSurvivesOutcomeOnlyPass": true,
                    "delayedPlaybackInheritsToolDirectedContext": true,
                    "provenanceExpiresAfterExchange": true,
                    "retentionIsBounded": true,
                    "connectionCleanupClearsState": true,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("turn tool-provenance verification failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func verifyDelayedAcknowledgementLifecycle() throws {
        let inputItemID = "owner-command-1"
        var provenance = ToolAddressedInputProvenance(retentionLimit: 4)

        // Mirrors AuroraAppModel's response.done/addressedTool-only pass. No
        // spoken exchange exists yet, so provenance must remain unconsumed.
        provenance.mark(inputItemID)
        try expect(
            provenance.contains(inputItemID),
            "addressedTool-only processing discarded provenance before playback"
        )

        // Mirrors delayed acknowledgement playback, whose new outcome array
        // contains only `.spoken` and therefore cannot carry `.addressedTool`.
        let currentPassHadToolCall = false
        let inheritedToolCall = currentPassHadToolCall || provenance.contains(inputItemID)
        let context = PrivateLifeExchangeContext(
            interactionKind: inheritedToolCall ? .toolDirected : .conversational,
            hadToolCall: inheritedToolCall,
            wasTaskFocused: inheritedToolCall,
            transcriptConfidence: nil
        )
        try expect(
            context.interactionKind == .toolDirected
                && context.hadToolCall
                && context.wasTaskFocused,
            "delayed acknowledgement was reclassified as conversation"
        )

        try expect(
            provenance.consume(inputItemID),
            "recorded exchange did not consume its provenance"
        )
        try expect(
            !provenance.contains(inputItemID),
            "consumed provenance survived the completed exchange"
        )
    }

    private static func verifyBoundedRetentionAndCleanup() throws {
        var provenance = ToolAddressedInputProvenance(retentionLimit: 2)
        provenance.mark("oldest")
        provenance.mark("newer")
        provenance.mark("newest")

        try expect(!provenance.contains("oldest"), "retention limit did not expire oldest input")
        try expect(
            provenance.contains("newer") && provenance.contains("newest"),
            "retention trimming discarded a current input"
        )

        provenance.remove("newer")
        try expect(!provenance.contains("newer"), "per-input history trimming did not clean up")

        provenance.removeAll()
        try expect(!provenance.contains("newest"), "connection cleanup did not clear provenance")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ToolProvenanceVerificationFailure.failed(message) }
    }
}
