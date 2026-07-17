import Foundation

/// Single-writer boundary for Aurora's durable agency. Intent resolution and
/// speaker verification remain upstream responsibilities; this actor requires
/// provenance on every mutation and never reinterprets natural-language text.
actor AuroraAgencyRuntime {
    private let store: AgencyStore
    private let now: @Sendable () -> Date
    private var state: AgencyState?
    private var failureDescription: String?
    private var processLock: AgencyProcessLock?

    init(
        store: AgencyStore = AgencyStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    @discardableResult
    func start() -> AgencySnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    func snapshot() -> AgencySnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    /// Applies model-authored structured arguments only after validating every
    /// required field and the optimistic record revision.
    @discardableResult
    func propose(
        _ proposal: AgencyRecordProposal,
        at explicitDate: Date? = nil
    ) throws -> AgencyProposalResult {
        let result = try propose([proposal], at: explicitDate)
        return AgencyProposalResult(
            snapshot: result.snapshot,
            affectedRecordID: result.affectedRecordIDs.first
        )
    }

    /// Applies at most two related transitions against one candidate and
    /// persists exactly once. If either proposal is invalid, neither reaches
    /// disk.
    @discardableResult
    func propose(
        _ proposals: [AgencyRecordProposal],
        at explicitDate: Date? = nil
    ) throws -> (snapshot: AgencySnapshot, affectedRecordIDs: [String]) {
        guard (1...2).contains(proposals.count) else {
            throw AgencyInputError.invalidInput("agency proposal batch count")
        }
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        var candidate = current
        var affectedIDs: [String] = []
        for proposal in proposals {
            let result = try apply(proposal, to: candidate, at: date)
            candidate = result.state
            if let affectedID = result.affectedID { affectedIDs.append(affectedID) }
        }
        if candidate != current { try commit(candidate) }
        return (snapshotLocked(), affectedIDs)
    }

    private func apply(
        _ proposal: AgencyRecordProposal,
        to current: AgencyState,
        at date: Date
    ) throws -> (state: AgencyState, affectedID: String?) {
        let candidate: AgencyState
        let affectedID: String?

        switch proposal.action {
        case .create:
            guard proposal.targetRecordID == nil,
                  proposal.expectedRevision == nil,
                  let kind = proposal.kind,
                  let contentScope = proposal.contentScope,
                  let content = proposal.content,
                  let privateRationale = proposal.privateRationale,
                  let expiresAt = proposal.expiresAt,
                  let confidence = proposal.confidence,
                  let salience = proposal.salience else {
                throw AgencyInputError.invalidInput("create-record proposal shape")
            }
            if kind != .selectiveDisclosure,
               proposal.disclosureShareMaterial != nil
                || proposal.disclosureMinimumSecurity != nil
                || proposal.disclosureMaximumInterrogationPressure != nil
                || proposal.disclosureRequiresOwnerReciprocity != nil {
                throw AgencyInputError.invalidInput("disclosure fields on non-disclosure record")
            }
            let result = try AgencyEngine.createRecord(
                current,
                kind: kind,
                contentScope: contentScope,
                content: content,
                privateRationale: privateRationale,
                groundings: proposal.groundings,
                authoringSourceID: proposal.authoringSourceID,
                sourceSessionID: proposal.sourceSessionID,
                sourceTurnIDs: proposal.sourceTurnIDs,
                expiresAt: expiresAt,
                confidence: confidence,
                salience: salience,
                projectionEligible: proposal.projectionEligible ?? true,
                disclosureShareMaterial: proposal.disclosureShareMaterial,
                disclosureMinimumSecurity: proposal.disclosureMinimumSecurity ?? 0.5,
                disclosureMaximumInterrogationPressure: proposal.disclosureMaximumInterrogationPressure ?? 0.65,
                disclosureRequiresOwnerReciprocity: proposal.disclosureRequiresOwnerReciprocity ?? true,
                at: date
            )
            candidate = result.state
            affectedID = result.recordID

        case .revise:
            guard let targetID = proposal.targetRecordID,
                  let expectedRevision = proposal.expectedRevision,
                  proposal.kind == nil,
                  proposal.contentScope == nil,
                  proposal.projectionEligible == nil,
                  proposal.disclosureMinimumSecurity == nil,
                  proposal.disclosureMaximumInterrogationPressure == nil,
                  proposal.disclosureRequiresOwnerReciprocity == nil,
                  let content = proposal.content,
                  let privateRationale = proposal.privateRationale,
                  let expiresAt = proposal.expiresAt,
                  let confidence = proposal.confidence,
                  let salience = proposal.salience,
                  let existing = current.records.first(where: { $0.id == targetID }),
                  existing.revision == expectedRevision else {
                throw AgencyInputError.invalidInput("revise-record proposal shape or revision")
            }
            let result = try AgencyEngine.reviseRecord(
                current,
                recordID: targetID,
                content: content,
                privateRationale: privateRationale,
                groundings: proposal.groundings,
                revisionSourceID: proposal.authoringSourceID,
                sourceSessionID: proposal.sourceSessionID,
                sourceTurnIDs: proposal.sourceTurnIDs,
                expiresAt: expiresAt,
                confidence: confidence,
                salience: salience,
                disclosureShareMaterial: proposal.disclosureShareMaterial,
                at: date
            )
            candidate = result.state
            affectedID = result.recordID

        case .retire, .fulfill:
            guard let targetID = proposal.targetRecordID,
                  let expectedRevision = proposal.expectedRevision,
                  proposal.kind == nil,
                  proposal.contentScope == nil,
                  proposal.content == nil,
                  proposal.privateRationale == nil,
                  proposal.groundings.isEmpty,
                  proposal.sourceSessionID == nil,
                  proposal.sourceTurnIDs.isEmpty,
                  proposal.expiresAt == nil,
                  proposal.confidence == nil,
                  proposal.salience == nil,
                  proposal.projectionEligible == nil,
                  proposal.disclosureShareMaterial == nil,
                  proposal.disclosureMinimumSecurity == nil,
                  proposal.disclosureMaximumInterrogationPressure == nil,
                  proposal.disclosureRequiresOwnerReciprocity == nil,
                  let existing = current.records.first(where: { $0.id == targetID }),
                  existing.revision == expectedRevision else {
                throw AgencyInputError.invalidInput("retire-record proposal shape or revision")
            }
            candidate = try AgencyEngine.retireRecord(
                current,
                recordID: targetID,
                revisionSourceID: proposal.authoringSourceID,
                fulfilled: proposal.action == .fulfill,
                at: date
            )
            affectedID = targetID
        }

        return (candidate, affectedID)
    }

    func projection(
        signals: AgencySelectionSignals,
        at explicitDate: Date? = nil
    ) -> AgencyProjection {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return unavailableProjection()
        }
        do {
            return try AgencyEngine.projection(for: current, signals: signals, at: date)
        } catch {
            return AgencyProjection(
                text: "AURORA AGENCY — invalid live signals; do not invent a position or event.",
                recordIDs: [],
                suggestedMoves: [.answer],
                eligibleDisclosureRecordID: nil
            )
        }
    }

    @discardableResult
    func recordOwnerInteraction(
        eventID: String,
        kind: AgencyOwnerInteractionKind,
        sourceSessionID: String,
        sourceTurnID: String,
        at explicitDate: Date? = nil
    ) throws -> AgencySnapshot {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let candidate = try AgencyEngine.recordOwnerInteraction(
            current,
            eventID: eventID,
            kind: kind,
            sourceSessionID: sourceSessionID,
            sourceTurnID: sourceTurnID,
            at: date
        )
        if candidate != current { try commit(candidate) }
        return snapshotLocked()
    }

    /// Atomically prepares one conversation_move. Every candidate mutation is
    /// applied in memory first; the interaction receipt, record transitions,
    /// fallback position, and pending authored move reach disk in one commit
    /// only after move preparation succeeds.
    @discardableResult
    func prepareConversationMove(
        _ transaction: AgencyConversationMoveTransaction,
        signals: AgencySelectionSignals,
        at explicitDate: Date? = nil
    ) throws -> AgencyConversationMovePreparation {
        guard transaction.recordProposals.count <= 2 else {
            throw AgencyInputError.invalidInput("agency proposal batch count")
        }
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        var candidate = current

        if transaction.participantIsOwner {
            candidate = try AgencyEngine.recordOwnerInteraction(
                candidate,
                eventID: transaction.interactionEventID,
                kind: transaction.interactionKind,
                sourceSessionID: transaction.sourceSessionID,
                sourceTurnID: transaction.sourceTurnID,
                at: date
            )
        }

        let initialProjection = transaction.participantIsOwner
            ? try AgencyEngine.projection(for: candidate, signals: signals, at: date)
            : AgencyProjection(
                text: "Guest turn: owner-private agency is not projected.",
                recordIDs: [],
                suggestedMoves: [.answer],
                eligibleDisclosureRecordID: nil
            )
        let initiallyVisibleIDs = Set(initialProjection.recordIDs)
        var affectedRecordIDs: [String] = []
        for proposal in transaction.recordProposals {
            if proposal.action != .create {
                guard let targetID = proposal.targetRecordID,
                      initiallyVisibleIDs.contains(targetID) else {
                    throw AgencyInputError.invalidInput("non-projected record target")
                }
            }
            let applied = try apply(proposal, to: candidate, at: date)
            candidate = applied.state
            if let affectedID = applied.affectedID { affectedRecordIDs.append(affectedID) }
        }

        var projection = transaction.participantIsOwner
            ? try AgencyEngine.projection(for: candidate, signals: signals, at: date)
            : initialProjection
        var permittedIDs = Set(projection.recordIDs)
        permittedIDs.formUnion(affectedRecordIDs)
        var selectedIDs = transaction.requestedRecordIDs.filter(permittedIDs.contains)
        selectedIDs.append(contentsOf: affectedRecordIDs.filter {
            !selectedIDs.contains($0)
        })

        if selectedIDs.isEmpty {
            guard transaction.fallbackRecordProposal.action == .create else {
                throw AgencyInputError.invalidInput("fallback agency record")
            }
            let applied = try apply(transaction.fallbackRecordProposal, to: candidate, at: date)
            candidate = applied.state
            guard let recordID = applied.affectedID else {
                throw AgencyInputError.invalidTransition("authored position was not persisted")
            }
            selectedIDs = [recordID]
            permittedIDs.insert(recordID)
            if transaction.participantIsOwner {
                projection = try AgencyEngine.projection(
                    for: candidate,
                    signals: signals,
                    at: date
                )
            }
        }

        let finalMove = AgencyEngine.resolveConversationMove(
            proposed: transaction.proposedMove,
            perceivedTurn: transaction.perceivedTurn,
            signals: signals,
            projection: projection,
            interrogationPressure: candidate.relationalBalance.interrogationPressure
        )
        let disclosureID: String?
        if finalMove == .reveal {
            guard let proposedDisclosureID = transaction.proposedDisclosureRecordID,
                  proposedDisclosureID == projection.eligibleDisclosureRecordID,
                  permittedIDs.contains(proposedDisclosureID) else {
                throw AgencyInputError.invalidTransition("held disclosure was not eligible")
            }
            disclosureID = proposedDisclosureID
            if !selectedIDs.contains(proposedDisclosureID) {
                selectedIDs.append(proposedDisclosureID)
            }
        } else if finalMove == .withhold,
                  let proposedDisclosureID = transaction.proposedDisclosureRecordID,
                  permittedIDs.contains(proposedDisclosureID) {
            disclosureID = proposedDisclosureID
            if !selectedIDs.contains(proposedDisclosureID) {
                selectedIDs.append(proposedDisclosureID)
            }
        } else {
            disclosureID = nil
        }

        let prepared = try AgencyEngine.prepareAuthoredMove(
            candidate,
            type: finalMove,
            responseID: transaction.responseID,
            sourceSessionID: transaction.sourceSessionID,
            sourceTurnID: transaction.sourceTurnID,
            recordIDs: Array(selectedIDs.prefix(6)),
            disclosureRecordID: disclosureID,
            privateRationale: transaction.privateRationale,
            confidence: transaction.confidence,
            signals: signals,
            at: date
        )
        candidate = prepared.state
        if candidate != current { try commit(candidate) }
        return AgencyConversationMovePreparation(
            snapshot: snapshotLocked(),
            moveID: prepared.moveID,
            moveType: finalMove,
            selectedRecordIDs: Array(selectedIDs.prefix(6))
        )
    }

    @discardableResult
    func prepareMove(
        _ proposal: AgencyMoveProposal,
        signals: AgencySelectionSignals,
        at explicitDate: Date? = nil
    ) throws -> (snapshot: AgencySnapshot, moveID: String) {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let result = try AgencyEngine.prepareAuthoredMove(
            current,
            type: proposal.type,
            responseID: proposal.responseID,
            sourceSessionID: proposal.sourceSessionID,
            sourceTurnID: proposal.sourceTurnID,
            recordIDs: proposal.recordIDs,
            disclosureRecordID: proposal.disclosureRecordID,
            privateRationale: proposal.privateRationale,
            confidence: proposal.confidence,
            signals: signals,
            at: date
        )
        if result.state != current { try commit(result.state) }
        return (snapshotLocked(), result.moveID)
    }

    @discardableResult
    func settlePlayback(
        responseID: String,
        generatedText: String? = nil,
        curiosityEffectEvidence: AgencyCuriosityEffectEvidence = .unavailable,
        playbackEventID: String,
        at explicitDate: Date? = nil
    ) throws -> AgencySnapshot {
        try reconcilePlayback(
            responseID: responseID,
            fullyPlayed: true,
            generatedText: generatedText,
            curiosityEffectEvidence: curiosityEffectEvidence,
            playbackEventID: playbackEventID,
            at: explicitDate
        )
    }

    @discardableResult
    func interruptPlayback(
        responseID: String,
        playbackEventID: String,
        at explicitDate: Date? = nil
    ) throws -> AgencySnapshot {
        try reconcilePlayback(
            responseID: responseID,
            fullyPlayed: false,
            generatedText: nil,
            curiosityEffectEvidence: .unavailable,
            playbackEventID: playbackEventID,
            at: explicitDate
        )
    }

    private func reconcilePlayback(
        responseID: String,
        fullyPlayed: Bool,
        generatedText: String?,
        curiosityEffectEvidence: AgencyCuriosityEffectEvidence,
        playbackEventID: String,
        at explicitDate: Date?
    ) throws -> AgencySnapshot {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let candidate = try AgencyEngine.reconcilePlayback(
            current,
            responseID: responseID,
            fullyPlayed: fullyPlayed,
            generatedText: generatedText,
            curiosityEffectEvidence: curiosityEffectEvidence,
            playbackEventID: playbackEventID,
            at: date
        )
        if candidate != current { try commit(candidate) }
        return snapshotLocked()
    }

    private func loadedState(at date: Date) throws -> AgencyState {
        ensureLoaded(at: date)
        if let failureDescription {
            throw AgencyInputError.persistenceUnavailable(failureDescription)
        }
        guard let state else {
            throw AgencyInputError.persistenceUnavailable("state did not load")
        }
        return state
    }

    private func ensureLoaded(at date: Date) {
        guard state == nil, failureDescription == nil else { return }
        do {
            processLock = try store.acquireExclusiveProcessLock()
            if let loaded = try store.load() {
                let sanitized = AgencyEngine.sanitize(loaded, now: date)
                let recovered = try AgencyEngine.rollbackPendingMovesAfterRestart(
                    sanitized,
                    sourceID: "agency-runtime-restart",
                    at: date
                )
                if recovered != loaded { try store.save(recovered) }
                state = recovered
            } else {
                let initial = AgencyEngine.defaultState(at: date)
                try store.save(initial)
                state = initial
            }
        } catch {
            processLock = nil
            failureDescription = error.localizedDescription
            state = nil
        }
    }

    private func commit(_ candidate: AgencyState) throws {
        do {
            try store.save(candidate)
            state = candidate
        } catch {
            failureDescription = error.localizedDescription
            state = nil
            processLock = nil
            throw AgencyInputError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private func snapshotLocked() -> AgencySnapshot {
        if let failureDescription { return .unavailable(failureDescription) }
        return AgencySnapshot(
            available: state != nil,
            state: state,
            failureDescription: nil
        )
    }

    private func unavailableProjection() -> AgencyProjection {
        AgencyProjection(
            text: "AURORA AGENCY — unavailable; do not invent a position, private experience, or external event.",
            recordIDs: [],
            suggestedMoves: [.answer],
            eligibleDisclosureRecordID: nil
        )
    }
}
