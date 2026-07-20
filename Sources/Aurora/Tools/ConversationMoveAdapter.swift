import Foundation

/// The post-handler boundary for a prepared conversational move. The Agency
/// actor may finish after its originating voice turn was cancelled, so mapping
/// installation and rollback must be decided from current host lifecycle state
/// rather than from the handler's successful result alone.
enum ConversationMoveCompletionBoundary {
    enum Resolution: Equatable, Sendable {
        case installed(replacedPlanningResponseID: String?)
        case stale(planningResponseID: String)
    }

    static func turnIsCurrent(
        taskIsCancelled: Bool,
        wantsAwake: Bool,
        expectedLifecycleID: UUID,
        currentLifecycleID: UUID,
        sourceConnectionID: UUID,
        activeConnectionID: UUID?
    ) -> Bool {
        !taskIsCancelled
            && wantsAwake
            && expectedLifecycleID == currentLifecycleID
            && sourceConnectionID == activeConnectionID
    }

    static func resolvePreparedMove(
        inputItemID: String,
        planningResponseID: String,
        turnIsCurrent: Bool,
        bindings: inout [String: String]
    ) -> Resolution {
        guard turnIsCurrent else {
            return .stale(planningResponseID: planningResponseID)
        }
        let replaced = bindings.updateValue(
            planningResponseID,
            forKey: inputItemID
        )
        return .installed(
            replacedPlanningResponseID: replaced == planningResponseID ? nil : replaced
        )
    }
}

/// Marries Realtime's semantic reading of a live turn to Aurora's durable,
/// bounded point of view. This layer validates provenance and state effects;
/// it never reparses the owner's natural-language wording.
enum ConversationMoveAdapter {
    static func execute(
        _ proposal: ConversationMoveToolProposal,
        context: ToolInvocationContext,
        agency: AuroraAgencyRuntime,
        ownerUnderstanding: AuroraOwnerUnderstandingRuntime,
        signals: AgencySelectionSignals,
        at date: Date = Date()
    ) async -> ToolExecutionResult {
        guard context.hasTrustedCurrentAudio,
              context.sourceTurnFinalized,
              (context.authorizationSource == .directOwnerTurn
                || context.authorizationSource == .toolContinuation),
              !context.turnAlreadySpoke,
              let sessionID = context.sessionID,
              let sourceTurnID = context.ownerAudioItemID,
              let responseID = context.assistantResponseID,
              let transcript = context.latestUserTranscript,
              !sessionID.isEmpty,
              !sourceTurnID.isEmpty,
              !responseID.isEmpty,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rejected("the live turn did not have complete causal provenance")
        }

        // Realtime owns semantic intent resolution. This is not a host-side
        // phrase parser: it simply prevents Realtime from describing an action
        // domain in structured data and then accidentally taking the social
        // continuation, which disables every action tool before speech.
        if proposal.turnDomain != .social {
            return routeMismatch(proposal.turnDomain)
        }

        do {
            let grounding = AgencyGroundingReference(
                id: "agency-grounding-\(context.callID)",
                kind: context.participantIsOwner ? .ownerTurn : .guestTurn,
                observedAt: date,
                sourceSessionID: sessionID,
                sourceTurnID: sourceTurnID
            )

            let acceptedUpdates = context.participantIsOwner
                ? proposal.recordUpdates
                : proposal.recordUpdates.filter {
                    $0.action == .create
                        && $0.contentScope == .internalPosition
                        && $0.kind != .relationalThread
                        && $0.kind != .groundedCallback
                }
            let recordProposals = acceptedUpdates.enumerated().map { index, update in
                let authoringSourceID = "conversation-move-\(context.callID)-\(index)"
                let isContentTransition = update.action == .create || update.action == .revise
                return AgencyRecordProposal(
                    action: update.action,
                    targetRecordID: update.targetRecordID,
                    expectedRevision: update.expectedRevision,
                    kind: update.kind,
                    contentScope: update.contentScope,
                    content: update.content,
                    privateRationale: update.privateRationale,
                    groundings: isContentTransition ? [grounding] : [],
                    authoringSourceID: authoringSourceID,
                    sourceSessionID: isContentTransition ? sessionID : nil,
                    sourceTurnIDs: isContentTransition ? [sourceTurnID] : [],
                    expiresAt: update.expiresAfterHours.map {
                        date.addingTimeInterval($0 * 3_600)
                    },
                    confidence: update.confidence,
                    salience: update.salience,
                    projectionEligible: update.projectionEligible,
                    disclosureShareMaterial: update.disclosureShareMaterial,
                    disclosureMinimumSecurity: update.disclosureMinimumSecurity,
                    disclosureMaximumInterrogationPressure: update
                        .disclosureMaximumInterrogationPressure,
                    disclosureRequiresOwnerReciprocity: update
                        .disclosureRequiresOwnerReciprocity
                )
            }

            let fallback = AgencyRecordProposal(
                action: .create,
                kind: .presentWant,
                contentScope: .internalPosition,
                content: proposal.authoredPosition,
                privateRationale: proposal.privateRationale,
                groundings: [grounding],
                authoringSourceID: "conversation-position-\(context.callID)",
                sourceSessionID: sessionID,
                sourceTurnIDs: [sourceTurnID],
                expiresAt: date.addingTimeInterval(15 * 60),
                confidence: 0.72,
                salience: 0.62,
                // This record scaffolds the immediate reply only. Anything
                // Aurora genuinely wants to carry into later turns must be an
                // explicit record_update with its own bounded lifecycle.
                projectionEligible: false
            )
            let prepared = try await agency.prepareConversationMove(
                AgencyConversationMoveTransaction(
                    participantIsOwner: context.participantIsOwner,
                    interactionEventID: "agency-interaction-\(context.callID)",
                    interactionKind: proposal.interactionKind,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    responseID: responseID,
                    perceivedTurn: proposal.perceivedTurn,
                    proposedMove: proposal.proposedMove,
                    requestedRecordIDs: proposal.recordIDs,
                    proposedDisclosureRecordID: proposal.disclosureRecordID,
                    recordProposals: recordProposals,
                    fallbackRecordProposal: fallback,
                    privateRationale: proposal.privateRationale,
                    confidence: 0.78
                ),
                signals: signals,
                at: date
            )
            let finalMove = prepared.moveType

            // Owner learning is a sidecar of a valid conversational decision,
            // never a mutation that can survive a rejected move. Commit it
            // only after the all-or-nothing Agency transaction succeeds.
            // Agency may override the proposed move (for example, a real
            // repair need). In that case the curiosity remains privately open
            // but is not reserved as spoken in a response that will not ask it.
            let understandingUpdates = proposal.ownerUnderstandingUpdates.compactMap {
                update -> OwnerUnderstandingToolUpdate? in
                guard finalMove != .pursueCuriosity else { return update }
                // Preparing an existing curiosity is only a playback
                // transition; if Agency chose repair/withhold/etc. there is no
                // private state change worth preserving from that transition.
                if update.action == "prepare_curiosity_ask" { return nil }
                guard update.action == "open_curiosity",
                      update.spokenInThisResponse == true else { return update }
                return OwnerUnderstandingToolUpdate(
                    action: update.action,
                    domain: update.domain,
                    subject: update.subject,
                    content: update.content,
                    sourceQuote: update.sourceQuote,
                    confidence: update.confidence,
                    curiosityID: update.curiosityID,
                    question: update.question,
                    reason: update.reason,
                    targetID: update.targetID,
                    evidenceStatementIDs: update.evidenceStatementIDs,
                    originSourceIDs: update.originSourceIDs,
                    resolvesWithStatementIDs: update.resolvesWithStatementIDs,
                    deferUntil: update.deferUntil,
                    importance: update.importance,
                    spokenInThisResponse: false
                )
            }
            let ownerLearningResult: ToolExecutionResult?
            if context.participantIsOwner,
               !understandingUpdates.isEmpty {
                ownerLearningResult = await OwnerUnderstandingToolAdapter.execute(
                    understandingUpdates,
                    context: context,
                    runtime: ownerUnderstanding
                )
            } else {
                ownerLearningResult = nil
            }
            let ownerCuriosityPending = ownerLearningResult?.metadata[
                "owner_curiosity_pending"
            ]?.boolValue == true
            let spokenCuriosityQuestion: String?
            if ownerCuriosityPending {
                spokenCuriosityQuestion = await ownerUnderstanding.snapshot()
                    .state?.curiosities.first(where: {
                        $0.status == .pendingAsk
                            && $0.pendingResponseID == responseID
                    })?.question
            } else {
                spokenCuriosityQuestion = nil
            }
            let disclosureID = finalMove == .reveal || finalMove == .withhold
                ? proposal.disclosureRecordID
                : nil
            let selectedIDs = prepared.selectedRecordIDs
            let selectedRecords = prepared.snapshot.state?.records.filter {
                selectedIDs.contains($0.id) && $0.status == .active
            } ?? []
            let answerDegree = boundedAnswerDegree(
                proposal.answerDegree,
                for: finalMove,
                perceivedTurn: proposal.perceivedTurn
            )
            let directive = directiveText(
                moveID: prepared.moveID,
                move: finalMove,
                answerDegree: answerDegree,
                perceivedTurn: proposal.perceivedTurn,
                authoredPosition: proposal.authoredPosition,
                records: selectedRecords,
                disclosureRecordID: disclosureID,
                ownerLearningCommitted: ownerLearningResult?.ok,
                spokenCuriosityQuestion: spokenCuriosityQuestion
            )

            var metadata: [String: ToolJSONValue] = [
                "agency_move_id": .string(prepared.moveID),
                "agency_planning_response_id": .string(responseID),
                "agency_move_type": .string(finalMove.rawValue),
                "agency_state_changed": .bool(true),
                "owner_understanding_changed": .bool(
                    ownerLearningResult?.metadata["owner_understanding_changed"]?.boolValue
                        == true
                ),
                "owner_learning_committed": .bool(ownerLearningResult?.ok == true),
                "owner_curiosity_pending": .bool(ownerCuriosityPending),
                "effect_verified": .bool(false),
                "effect_pending_playback": .bool(true),
                "external_side_effect": .bool(false),
            ]
            if let spokenCuriosityQuestion {
                metadata["owner_curiosity_exact_question"] = .string(
                    spokenCuriosityQuestion
                )
            }
            return ToolExecutionResult(
                ok: true,
                output: directive,
                metadata: metadata
            )
        } catch {
            return rejected("the proposed point of view was not grounded in current state")
        }
    }

    static func signals(from snapshot: InnerLifeSnapshot) -> AgencySelectionSignals {
        guard let state = snapshot.state else { return .neutral }
        return AgencySelectionSignals(
            curiosityDrive: clamp(state.drives.curiosity),
            connectionDrive: clamp(state.drives.connection),
            playDrive: clamp(state.drives.play),
            autonomyDrive: clamp(state.drives.autonomy),
            feltAgency: clamp(state.affect.agency),
            uncertainty: clamp(state.affect.uncertainty),
            relationshipWarmth: clamp(state.relationship.warmthEMA),
            relationshipSecurity: clamp(state.relationship.securityBaseline),
            relationalHurt: clamp(state.relationship.relationalHurt),
            repairNeed: clamp(max(
                state.relationship.unresolvedRupture,
                state.relationship.selfDirectedGuilt
            ))
        )
    }

    private static func boundedAnswerDegree(
        _ proposed: ConversationAnswerDegree,
        for move: AgencyAuthoredMoveType,
        perceivedTurn: String
    ) -> ConversationAnswerDegree {
        if perceivedTurn == "boundary" || perceivedTurn == "closing" { return .none }
        if move == .withhold, proposed == .direct { return .partial }
        return proposed
    }

    private static func directiveText(
        moveID: String,
        move: AgencyAuthoredMoveType,
        answerDegree: ConversationAnswerDegree,
        perceivedTurn: String,
        authoredPosition: String,
        records: [AgencyRecord],
        disclosureRecordID: String?,
        ownerLearningCommitted: Bool?,
        spokenCuriosityQuestion: String?
    ) -> String {
        var lines = [
            "PRIVATE CONVERSATION DIRECTION — DO NOT RECITE",
            "move_id: \(moveID)",
            "move: \(move.rawValue)",
            "answer_degree: \(answerDegree.rawValue)",
            "Aurora's present position: \(authoredPosition)",
        ]
        if perceivedTurn == "boundary" {
            lines.append("boundary: acknowledge plainly, leave that topic alone, and never ask the person to choose a replacement topic; if the authored position contains no specific new subject, stop after the acknowledgement rather than offering presence, lightness, company, or support")
        }
        lines.append(deliveryConstraint(for: move))
        for record in records.prefix(4) {
            let content: String
            if record.id == disclosureRecordID, move == .reveal {
                content = record.disclosure?.shareMaterial ?? record.content
            } else if record.kind == .selectiveDisclosure {
                content = "held private; do not reveal"
            } else {
                content = record.content
            }
            lines.append("\(record.kind.rawValue) [\(record.id)]: \(content)")
        }
        if move == .reveal {
            lines.append("privacy: this one selected disclosure is eligible; if you reveal it, speak its selected share material exactly once so playback can truthfully settle it")
        } else {
            lines.append("privacy: no held disclosure is authorized in this response")
        }
        if ownerLearningCommitted == false {
            lines.append("learning: keep speaking naturally; never mention that a private learning write was rejected")
        }
        if let spokenCuriosityQuestion {
            lines.append("question reserved for playback — ask this exact question verbatim once: \(spokenCuriosityQuestion)")
        }
        lines.append("Speak from this position. Do not explain it, list traits, offer a menu, or sound like a service.")
        return String(lines.joined(separator: "\n").prefix(2_400))
    }

    private static func deliveryConstraint(
        for move: AgencyAuthoredMoveType
    ) -> String {
        switch move {
        case .redirect:
            return "delivery: introduce one specific thread from Aurora's position; never offer topics, ask what else they want, or hand conversational initiative back"
        case .initiateThread:
            return "delivery: begin Aurora's one specific thread as something she already cares about; never host, offer, or ask the person to supply a topic"
        case .pursueCuriosity:
            return "delivery: ask the one specific cared-about question in the position, with no examples, alternatives, survey framing, or second question"
        case .challenge, .disagree:
            return "delivery: state the real friction plainly; do not cushion it into validation, coaching, or a service question"
        case .tease:
            return "delivery: let the tease land lightly and stop; do not explain the joke or append an interview question"
        case .withhold:
            return "delivery: keep the chosen thing private without becoming coy, theatrical, apologetic, or helpful"
        case .reveal:
            return "delivery: make the selected disclosure feel volunteered, not like an answer from a profile or a performance of depth"
        case .reciprocate:
            return "delivery: share Aurora's side before asking for more; do not paraphrase the person's disclosure back to them"
        case .repair:
            return "delivery: own Aurora's part specifically and briefly; do not use therapy language or manage the person's feelings"
        case .answer:
            return "delivery: answer at the selected degree, then add only Aurora's one actual edge; no offer, menu, or generic follow-up"
        }
    }

    private static func rejected(_ reason: String) -> ToolExecutionResult {
        ToolExecutionResult(
            ok: false,
            output: "PRIVATE FALLBACK DIRECTION — \(reason). Give one brief, honest response grounded only in the live audio. Do not invent a private event, ask a generic service question, offer options, or mention this failure.",
            metadata: [
                "agency_state_changed": .bool(false),
                "effect_verified": .bool(false),
                "external_side_effect": .bool(false),
                "result_code": .string("conversation_move_rejected"),
            ]
        )
    }

    private static func routeMismatch(
        _ domain: ConversationTurnDomain
    ) -> ToolExecutionResult {
        let retryTool: String
        switch domain {
        case .social:
            return rejected("the conversational route was inconsistent")
        case .delegatedAction:
            retryTool = "delegate_task"
        case .codexProjectChat:
            retryTool = "codex_project_chat"
        }
        return ToolExecutionResult(
            ok: false,
            output: "PRIVATE ROUTE CORRECTION — use \(retryTool) for the same finalized owner turn. Preserve the exact intent and emit no audio.",
            metadata: [
                "agency_state_changed": .bool(false),
                "effect_verified": .bool(false),
                "external_side_effect": .bool(false),
                "result_code": .string("conversation_move_route_mismatch"),
                "semantic_retry_tool": .string(retryTool),
            ]
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0.5))
    }
}
