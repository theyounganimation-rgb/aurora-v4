import Foundation

/// Single-writer boundary for Aurora's evolving understanding of the owner.
/// Speaker verification and owner/guest provenance remain the caller's job;
/// this actor requires the resulting source IDs on every mutation.
actor AuroraOwnerUnderstandingRuntime {
    private let store: OwnerUnderstandingStore
    private let now: @Sendable () -> Date
    private var state: OwnerUnderstandingState?
    private var failureDescription: String?
    private var processLock: OwnerUnderstandingProcessLock?

    init(
        store: OwnerUnderstandingStore = OwnerUnderstandingStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    @discardableResult
    func start() -> OwnerUnderstandingSnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    func snapshot() -> OwnerUnderstandingSnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    /// Applies one already-resolved, transport-neutral proposal. Function-call
    /// fields are still schema-checked here; caller provenance must already be
    /// verified and bound to the supplied turn/session.
    @discardableResult
    func apply(
        update: OwnerUnderstandingUpdate,
        sourceTurnID: String,
        sessionID: String,
        responseID: String? = nil,
        at explicitDate: Date? = nil
    ) throws -> OwnerUnderstandingApplyResult {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let result = try OwnerUnderstandingEngine.apply(
            current,
            update: update,
            sourceTurnID: sourceTurnID,
            sessionID: sessionID,
            responseID: responseID,
            at: date
        )
        try commit(result.state)
        return OwnerUnderstandingApplyResult(
            snapshot: snapshotLocked(),
            affectedID: result.affectedID
        )
    }

    /// Atomically commits all understanding proposals from one finalized owner
    /// exchange. Any supplied source quote must occur literally in the exact
    /// finalized transcript. No normalization or semantic phrase matching is
    /// performed.
    @discardableResult
    func recordExchange(
        ownerText: String,
        sourceTurnID: String,
        sessionID: String,
        updates: [OwnerUnderstandingUpdate],
        responseID: String? = nil,
        at explicitDate: Date? = nil
    ) throws -> OwnerUnderstandingSnapshot {
        guard !ownerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ownerText.count <= 16_000 else {
            throw OwnerUnderstandingInputError.invalidInput("finalized owner transcript")
        }
        guard updates.count <= 12 else {
            throw OwnerUnderstandingInputError.invalidInput("exchange update count")
        }
        let date = explicitDate ?? now()
        var candidate = try loadedState(at: date)
        var directStatementIDs: [String] = []

        for original in updates {
            if let quote = original.sourceQuote,
               ownerText.range(of: quote, options: .literal) == nil {
                throw OwnerUnderstandingInputError.invalidInput("source quote outside finalized owner turn")
            }
            var update = original
            if update.action == .answerCuriosity,
               (update.resolvesWithStatementIDs?.isEmpty ?? true),
               !directStatementIDs.isEmpty {
                update.resolvesWithStatementIDs = directStatementIDs
            }
            let result = try OwnerUnderstandingEngine.apply(
                candidate,
                update: update,
                sourceTurnID: sourceTurnID,
                sessionID: sessionID,
                responseID: responseID,
                at: date
            )
            candidate = result.state
            if update.action == .recordDirectStatement || update.action == .reviseDirectStatement,
               let id = result.affectedID {
                directStatementIDs.append(id)
            }
            if update.action == .openCuriosity,
               update.spokenInThisResponse == true,
               let curiosityID = result.affectedID {
                guard let responseID else {
                    throw OwnerUnderstandingInputError.invalidInput("Realtime response ID for spoken curiosity")
                }
                candidate = try OwnerUnderstandingEngine.prepareCuriosityForPlayback(
                    candidate,
                    curiosityID: curiosityID,
                    responseID: responseID,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                )
            }
        }
        if candidate != state { try commit(candidate) }
        return snapshotLocked()
    }

    /// Commits `asked` only when playback was fully delivered. An interrupted
    /// response returns the curiosity to `open` without incrementing cadence.
    @discardableResult
    func reconcilePlayback(
        responseID: String,
        fullyPlayed: Bool,
        playbackEventID: String,
        at explicitDate: Date? = nil
    ) throws -> OwnerUnderstandingApplyResult {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let result = try OwnerUnderstandingEngine.reconcilePlayback(
            current,
            responseID: responseID,
            fullyPlayed: fullyPlayed,
            playbackEventID: playbackEventID,
            at: date
        )
        if result.state != current { try commit(result.state) }
        return OwnerUnderstandingApplyResult(
            snapshot: snapshotLocked(),
            affectedID: result.curiosityID
        )
    }

    /// Optional one-time bridge for an existing personhood checklist. Nothing
    /// is read from disk here; the caller explicitly supplies Markdown, path,
    /// and revision. Checked lines remain legacy evidence and unchecked lines
    /// remain candidate gaps—neither becomes a direct owner quote.
    @discardableResult
    func importLegacyChecklist(
        markdown: String,
        source: OwnerLegacyChecklistSource,
        at explicitDate: Date? = nil
    ) throws -> OwnerUnderstandingSnapshot {
        let date = explicitDate ?? now()
        let current = try loadedState(at: date)
        let parsed = try OwnerUnderstandingEngine.importLegacyChecklist(
            markdown: markdown,
            source: source,
            at: date
        )
        let result = try OwnerUnderstandingEngine.commitLegacyChecklistImport(
            current,
            checklistImport: parsed,
            at: date
        )
        if result.imported { try commit(result.state) }
        return snapshotLocked()
    }

    func projectionPacket(at explicitDate: Date? = nil) -> OwnerUnderstandingProjection {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return OwnerUnderstandingProjection(
                text: "UNDERSTANDING OF OWNER — unavailable; do not invent personal knowledge or fill gaps by guessing.",
                directStatementIDs: [],
                tentativeInferenceID: nil,
                curiosityID: nil,
                cadenceDirection: .giveSpace
            )
        }
        let refreshed = OwnerUnderstandingEngine.refreshDeferred(current, at: date)
        if refreshed != current {
            do { try commit(refreshed) } catch { return unavailableProjection() }
        }
        return OwnerUnderstandingEngine.projection(for: refreshed, at: date)
    }

    func voiceProjection(at explicitDate: Date? = nil) -> String {
        projectionPacket(at: explicitDate).text
    }

    private func loadedState(at date: Date) throws -> OwnerUnderstandingState {
        ensureLoaded(at: date)
        if let failureDescription {
            throw OwnerUnderstandingInputError.persistenceUnavailable(failureDescription)
        }
        guard let state else {
            throw OwnerUnderstandingInputError.persistenceUnavailable("state did not load")
        }
        return state
    }

    private func ensureLoaded(at date: Date) {
        guard state == nil, failureDescription == nil else { return }
        do {
            processLock = try store.acquireExclusiveProcessLock()
            if let loaded = try store.load() {
                state = OwnerUnderstandingEngine.sanitize(loaded, now: date)
            } else {
                let initial = OwnerUnderstandingEngine.defaultState(at: date)
                try store.save(initial)
                state = initial
            }
        } catch {
            processLock = nil
            failureDescription = error.localizedDescription
            state = nil
        }
    }

    private func commit(_ candidate: OwnerUnderstandingState) throws {
        do {
            try store.save(candidate)
            state = candidate
        } catch {
            failureDescription = error.localizedDescription
            state = nil
            processLock = nil
            throw OwnerUnderstandingInputError.persistenceUnavailable(error.localizedDescription)
        }
    }

    private func snapshotLocked() -> OwnerUnderstandingSnapshot {
        if let failureDescription {
            return .unavailable(failureDescription)
        }
        return OwnerUnderstandingSnapshot(
            available: state != nil,
            state: state,
            failureDescription: nil
        )
    }

    private func unavailableProjection() -> OwnerUnderstandingProjection {
        OwnerUnderstandingProjection(
            text: "UNDERSTANDING OF OWNER — unavailable; do not invent personal knowledge or fill gaps by guessing.",
            directStatementIDs: [],
            tentativeInferenceID: nil,
            curiosityID: nil,
            cadenceDirection: .giveSpace
        )
    }
}
