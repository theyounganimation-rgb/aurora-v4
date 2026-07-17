import Foundation

/// Converts only already schema-validated transport values into the
/// persistence model. Realtime owns the semantic proposal; deterministic code
/// preserves provenance, validates IDs, and never reinterprets natural words.
enum OwnerUnderstandingToolAdapter {
    static func execute(
        _ values: [OwnerUnderstandingToolUpdate],
        context: ToolInvocationContext,
        runtime: AuroraOwnerUnderstandingRuntime
    ) async -> ToolExecutionResult {
        guard context.hasTrustedCurrentOwnerAudio,
              context.sourceTurnFinalized,
              (context.authorizationSource == .directOwnerTurn
                || context.authorizationSource == .toolContinuation),
              let ownerText = context.latestUserTranscript,
              let sourceTurnID = context.ownerAudioItemID,
              let sessionID = context.sessionID else {
            return rejected("trusted finalized owner provenance was unavailable")
        }
        do {
            let snapshot = await runtime.snapshot()
            guard snapshot.available, let state = snapshot.state else {
                return rejected("the private understanding store was unavailable")
            }
            let validLegacyOriginIDs = Set(state.legacyGapCandidates.map(\.id))
            let updates = try values.map { value -> OwnerUnderstandingUpdate in
                guard let action = OwnerUnderstandingUpdateAction(rawValue: value.action) else {
                    throw OwnerUnderstandingInputError.invalidInput("understanding action")
                }
                let domain: OwnerUnderstandingDomain?
                if let rawDomain = value.domain {
                    guard let parsed = OwnerUnderstandingDomain(rawValue: rawDomain) else {
                        throw OwnerUnderstandingInputError.invalidInput("understanding domain")
                    }
                    domain = parsed
                } else {
                    domain = nil
                }
                if let originIDs = value.originSourceIDs,
                   !originIDs.allSatisfy(validLegacyOriginIDs.contains) {
                    throw OwnerUnderstandingInputError.invalidInput("curiosity origin IDs")
                }
                return OwnerUnderstandingUpdate(
                    action: action,
                    domain: domain,
                    subject: value.subject,
                    content: value.content,
                    sourceQuote: value.sourceQuote,
                    confidence: value.confidence,
                    curiosityID: value.curiosityID,
                    question: value.question,
                    reason: value.reason,
                    targetID: value.targetID,
                    evidenceStatementIDs: value.evidenceStatementIDs,
                    originSourceIDs: value.originSourceIDs,
                    resolvesWithStatementIDs: value.resolvesWithStatementIDs,
                    deferUntil: value.deferUntil,
                    importance: value.importance,
                    spokenInThisResponse: value.spokenInThisResponse
                )
            }
            let next = try await runtime.recordExchange(
                ownerText: ownerText,
                sourceTurnID: sourceTurnID,
                sessionID: sessionID,
                updates: updates,
                responseID: context.assistantResponseID
            )
            let pending = next.state?.curiosities.contains(where: {
                $0.status == .pendingAsk
                    && $0.pendingResponseID == context.assistantResponseID
            }) == true
            return ToolExecutionResult(
                ok: true,
                output: "Aurora's private relational understanding was updated.",
                metadata: [
                    "terminal": .bool(true),
                    "owner_understanding_changed": .bool(true),
                    "owner_curiosity_pending": .bool(pending),
                    "effect_verified": .bool(true),
                    "external_side_effect": .bool(false),
                ]
            )
        } catch {
            return rejected("the proposed evidence or lifecycle transition was invalid")
        }
    }

    private static func rejected(_ reason: String) -> ToolExecutionResult {
        ToolExecutionResult(
            ok: false,
            output: "Aurora kept the conversation natural, but \(reason).",
            metadata: [
                "terminal": .bool(true),
                "owner_understanding_changed": .bool(false),
                "effect_verified": .bool(false),
                "external_side_effect": .bool(false),
                "result_code": .string("owner_understanding_rejected"),
            ]
        )
    }
}
