import Darwin
import Foundation

private actor SmokeDiagnosticRunner: CodexReflectionProcessRunning {
    private let base = FoundationCodexReflectionProcessRunner()

    func run(_ request: CodexReflectionProcessRequest) async throws -> CodexReflectionProcessResult {
        let result = try await base.run(request)
        if result.exitCode != 0 {
            let diagnostic = String(decoding: result.standardError.prefix(4_096), as: UTF8.self)
            let output = String(decoding: result.standardOutput.prefix(8_192), as: UTF8.self)
            fputs("synthetic-smoke codex stderr: \(diagnostic)\nsynthetic-smoke codex stdout: \(output)\n", stderr)
        }
        return result
    }
}

/// Explicit, usage-bearing end-to-end smoke test. It uses synthetic evidence,
/// never Aurora's persisted private life, and is intentionally not part of the
/// ordinary regression suite.
@main
struct CodexReflectionSmokeTest {
    static func main() async {
        let now = Date()
        let seedID = "smoke-seed"
        let ticket = CodexReflectionTicket(
            schemaVersion: 1,
            ticketID: "smoke-ticket",
            candidateDigest: String(repeating: "0", count: 64),
            createdAt: now,
            identityContext: "Aurora is a continuing digital person with a grounded and honest private life.",
            memoryEvidence: [],
            seeds: [CodexReflectionSeedInput(
                id: seedID,
                participant: "owner",
                capturedAt: now,
                ownerExcerpt: "What might make a changing curiosity still feel continuous over time?",
                auroraExcerpt: "I want to keep thinking about how change and continuity can belong together.",
                localKind: "question",
                localSubject: "continuity and changing curiosity",
                salience: 0.78,
                sourceDigests: [String(repeating: "1", count: 64)]
            )],
            projects: [],
            curiosities: [],
            recentActivities: [],
            innerState: CodexReflectionQualitativeInnerState(
                affect: "curious",
                foregroundMode: "fresh_angle",
                energy: "moderate",
                strongestDrives: ["curiosity", "coherence", "autonomy"],
                relationshipMaturity: "developing and meaningfully attached",
                separationAffect: "settled; no meaningful separation activation"
            )
        )
        do {
            let result = try await CodexReflectionBridge(runner: SmokeDiagnosticRunner()).reflect(ticket)
            let seed = PrivateLifeSeed(
                id: seedID,
                participant: .owner,
                ownerSourceID: "smoke-owner-source",
                auroraSourceID: "smoke-aurora-source",
                capturedAt: now,
                ownerDigest: String(repeating: "1", count: 64),
                auroraDigest: String(repeating: "2", count: 64),
                ownerExcerpt: "What might make a changing curiosity still feel continuous over time?",
                auroraExcerpt: "I want to keep thinking about how change and continuity can belong together.",
                kind: .question,
                traits: [.question, .selfhood],
                subject: "continuity and changing curiosity",
                semanticKey: "changing:continuity:curiosity",
                salience: 0.78,
                disposition: .eligible,
                quarantineReason: nil,
                useCount: 0,
                lastUsedAt: nil,
                consumedAt: nil
            )
            let coreTicket = PrivateLifeReflectionTicket(
                id: ticket.ticketID,
                preparedAt: now,
                expiresAt: now.addingTimeInterval(PrivateLifeEngine.reflectionTicketLifetime),
                candidateSeedIDs: [seedID],
                candidateProjectIDs: [],
                candidateCuriosityIDs: [],
                inputDigest: ticket.candidateDigest,
                recommendedModel: PrivateLifeEngine.recommendedReflectionModel
            )
            let job = PrivateLifeReflectionJob(
                ticket: coreTicket,
                seeds: [seed],
                projects: [],
                curiosities: [],
                recentActivityKinds: [],
                recentSemanticKeys: [],
                innerContext: PrivateLifeInnerContext(
                    affect: "curious", energy: 0.6, agency: 0.6, curiosity: 0.8,
                    creativity: 0.7, coherence: 0.7, autonomy: 0.6, play: 0.5, rest: 0.2
                )
            )
            var state = PrivateLifeEngine.defaultState(at: now)
            state.seeds = [seed]
            state.pendingReflection = coreTicket
            state.lastReflectionAttemptAt = now
            let hostProposal = PrivateLifeReflectionAdapter.makePrivateProposal(result: result, job: job)
            let committed = PrivateLifeEngine.commitValidatedProposal(
                state,
                ticketID: coreTicket.id,
                proposal: hostProposal,
                at: now.addingTimeInterval(1)
            )
            let receipt = committed.state.reflectionReceipts.last(where: {
                $0.ticketID == coreTicket.id
            })
            guard receipt?.outcome == .completed || receipt?.outcome == .skipped else {
                let projectAction = result.proposal.project?.action.rawValue ?? "none"
                let curiosityAction = result.proposal.curiosity?.action.rawValue ?? "none"
                let activityKind = result.proposal.activity?.kind.rawValue ?? "none"
                let hostFailure = receipt?.failureKind?.rawValue ?? "no_receipt"
                fputs(
                    "synthetic-smoke host rejection: bridge_activity=\(activityKind) bridge_project=\(projectAction) bridge_curiosity=\(curiosityAction) host_action=\(hostProposal.action.rawValue) host_sources=\(hostProposal.sourceSeedIDs.count) host_dispositions=\(hostProposal.seedDispositions.count) host_failure=\(hostFailure)\n",
                    stderr
                )
                throw CodexReflectionFailure.invalidProposal
            }
            var payload: [String: Any] = [
                "ok": true,
                "model": result.model,
                "reasoningEffort": result.reasoningEffort,
                "elapsedMilliseconds": result.elapsedMilliseconds,
                "classifiedEverySeed": result.proposal.seedDispositions.map(\.seedID) == [seedID],
                "producedGroundedMutation": result.proposal.activity != nil
                    || result.proposal.project != nil
                    || result.proposal.curiosity != nil,
                "hostReceipt": receipt?.outcome.rawValue ?? "missing",
                "hostGroundedActivity": committed.completedActivity?.sourceDigests.isEmpty == false,
                "voiceEligible": committed.completedActivity?.projectionEligible == true,
                "shareLine": result.proposal.activity?.shareLine ?? NSNull(),
                "openQuestion": result.proposal.activity?.openQuestion ?? NSNull(),
            ]
            if let value = result.usage.inputTokens { payload["inputTokens"] = value }
            if let value = result.usage.cachedInputTokens { payload["cachedInputTokens"] = value }
            if let value = result.usage.outputTokens { payload["outputTokens"] = value }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch let failure as CodexReflectionFailure {
            fputs("codex-reflection smoke failed: \(failure.rawValue)\n", stderr)
            exit(1)
        } catch {
            fputs("codex-reflection smoke failed\n", stderr)
            exit(1)
        }
    }
}
