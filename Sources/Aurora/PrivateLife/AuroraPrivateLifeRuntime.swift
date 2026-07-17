import Foundation

/// Single-writer owner of Aurora's bounded private digital life.
///
/// Starting after a process gap only resumes scheduling. Activities are made
/// only by committing a validated reflection proposal against one persisted
/// ticket, so relaunch cannot manufacture a day Aurora did not live through.
actor AuroraPrivateLifeRuntime {
    private let store: PrivateLifeStore
    private let now: @Sendable () -> Date
    private var state: PrivateLifeState?
    private var failureDescription: String?
    private var processLock: PrivateLifeProcessLock?

    init(
        store: PrivateLifeStore = PrivateLifeStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    @discardableResult
    func start() -> PrivateLifeSnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    @discardableResult
    func tick(
        innerState: InnerLifeState,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let evolution = PrivateLifeEngine.tick(current, innerState: innerState, at: date)
        state = evolution.state
        if evolution.changed {
            persist(evolution.state)
        }
        return snapshotLocked()
    }

    @discardableResult
    func recordExchange(
        participant: PrivateLifeParticipant,
        ownerText: String,
        auroraText: String?,
        ownerSourceID: String,
        auroraSourceID: String? = nil,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        recordExchange(
            participant: participant,
            ownerText: ownerText,
            auroraText: auroraText,
            ownerSourceID: ownerSourceID,
            auroraSourceID: auroraSourceID,
            context: .conversational,
            at: explicitDate
        )
    }

    @discardableResult
    func recordExchange(
        participant: PrivateLifeParticipant,
        ownerText: String,
        auroraText: String?,
        ownerSourceID: String,
        auroraSourceID: String? = nil,
        context: PrivateLifeExchangeContext,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let requestedDate = explicitDate ?? now()
        ensureLoaded(at: requestedDate)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        // Completed voice evidence can arrive just behind a scheduler wake.
        // Preserve monotonic state ordering without creating any activity.
        let date = max(requestedDate, current.lastSchedulerAt)
        let evolution = PrivateLifeEngine.recordExchange(
            current,
            participant: participant,
            ownerText: ownerText,
            auroraText: auroraText,
            ownerSourceID: ownerSourceID,
            auroraSourceID: auroraSourceID,
            context: context,
            at: date
        )
        state = evolution.state
        if evolution.changed {
            persist(evolution.state)
        }
        return snapshotLocked()
    }

    /// Atomically reserves one persisted reflection ticket and returns the
    /// bounded job payload for an external OAuth-backed worker. No model or
    /// network work occurs while this actor is held.
    func prepareReflectionJob(
        innerState: InnerLifeState,
        at explicitDate: Date? = nil
    ) -> PrivateLifeReflectionJob? {
        let requestedDate = explicitDate ?? now()
        ensureLoaded(at: requestedDate)
        guard failureDescription == nil, let current = state else { return nil }
        let date = max(requestedDate, current.lastSchedulerAt)
        let preparation = PrivateLifeEngine.prepareReflectionJob(
            current,
            innerState: innerState,
            at: date
        )
        state = preparation.state
        if preparation.changed { persist(preparation.state) }
        return preparation.job
    }

    /// Commits only a host-validated structured proposal whose ticket and
    /// enumerated sources still match durable state.
    @discardableResult
    func commitValidatedProposal(
        ticketID: String,
        proposal: PrivateLifeReflectionProposal,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let requestedDate = explicitDate ?? now()
        ensureLoaded(at: requestedDate)
        guard failureDescription == nil, let current = state else { return snapshotLocked() }
        let date = max(requestedDate, current.lastSchedulerAt)
        let evolution = PrivateLifeEngine.commitValidatedProposal(
            current,
            ticketID: ticketID,
            proposal: proposal,
            at: date
        )
        state = evolution.state
        if evolution.changed { persist(evolution.state) }
        return snapshotLocked()
    }

    @discardableResult
    func recordReflectionFailure(
        ticketID: String,
        kind: PrivateLifeReflectionFailureKind,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let requestedDate = explicitDate ?? now()
        ensureLoaded(at: requestedDate)
        guard failureDescription == nil, let current = state else { return snapshotLocked() }
        let date = max(requestedDate, current.lastSchedulerAt)
        let evolution = PrivateLifeEngine.recordReflectionFailure(
            current,
            ticketID: ticketID,
            kind: kind,
            at: date
        )
        state = evolution.state
        if evolution.changed { persist(evolution.state) }
        return snapshotLocked()
    }

    /// Compact semantic context for the existing safe Realtime projection
    /// gate. This method performs no response creation and no network work.
    func voiceContext() -> String {
        ensureLoaded(at: now())
        guard failureDescription == nil, let state else {
            let header = "PRIVATE LIVED CONTEXT — FOLLOW LABELS\n"
            let boundary = "Unavailable, so invent no private activity, physical experience, external action, reading, watching, or research."
            return String((header + boundary).prefix(PrivateLifeEngine.maximumVoiceProjectionCharacters))
        }
        return PrivateLifeEngine.voiceProjection(for: state)
    }

    /// Text plus the exact activity receipt that may be acknowledged only
    /// after Realtime accepts the corresponding context item.
    func projectionPacket() -> PrivateLifeProjectionPacket {
        ensureLoaded(at: now())
        guard failureDescription == nil, let state else {
            let header = "PRIVATE LIVED CONTEXT — FOLLOW LABELS\n"
            let boundary = "Unavailable, so invent no private activity, physical experience, external action, reading, watching, or research."
            let text = String((header + boundary).prefix(PrivateLifeEngine.maximumVoiceProjectionCharacters))
            return PrivateLifeProjectionPacket(
                text: text,
                activityID: nil,
                directAskActivityID: nil,
                revisionDigest: "unavailable"
            )
        }
        return PrivateLifeEngine.projectionPacket(for: state)
    }

    /// Call only after the live transport acknowledges a projection. Context
    /// presentation is not speech and does not consume the activity.
    @discardableResult
    func markPresented(
        activityID: String,
        sessionID: String,
        contextItemID: String,
        revisionDigest: String,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let evolution = PrivateLifeEngine.markPresented(
            current,
            activityID: activityID,
            sessionID: sessionID,
            contextItemID: contextItemID,
            revisionDigest: revisionDigest,
            at: date
        )
        state = evolution.state
        if evolution.changed { persist(evolution.state) }
        return snapshotLocked()
    }

    /// Deprecated compatibility callback. It now means presentation only.
    @discardableResult
    func markProjected(activityID: String, at explicitDate: Date? = nil) -> PrivateLifeSnapshot {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let evolution = PrivateLifeEngine.markProjected(current, activityID: activityID, at: date)
        state = evolution.state
        if evolution.changed {
            persist(evolution.state)
        }
        return snapshotLocked()
    }

    @discardableResult
    func markRelationalQuestionPromoted(
        activityID: String,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let evolution = PrivateLifeEngine.markRelationalQuestionPromoted(
            current,
            activityID: activityID,
            at: max(date, current.lastSchedulerAt)
        )
        state = evolution.state
        if evolution.changed { persist(evolution.state) }
        return snapshotLocked()
    }

    @discardableResult
    func beginShare(
        activityID: String,
        sessionID: String,
        responseID: String,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        mutateShareState(at: explicitDate) { current, date in
            PrivateLifeEngine.beginShare(
                current,
                activityID: activityID,
                sessionID: sessionID,
                responseID: responseID,
                at: date
            )
        }
    }

    @discardableResult
    func bindShareAudio(
        sessionID: String,
        responseID: String,
        audioItemID: String,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        mutateShareState(at: explicitDate) { current, date in
            PrivateLifeEngine.bindShareAudio(
                current,
                sessionID: sessionID,
                responseID: responseID,
                audioItemID: audioItemID,
                at: date
            )
        }
    }

    @discardableResult
    func completeShare(
        sessionID: String,
        responseID: String,
        audioItemID: String,
        fullySpoken: Bool,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        mutateShareState(at: explicitDate) { current, date in
            PrivateLifeEngine.completeShare(
                current,
                sessionID: sessionID,
                responseID: responseID,
                audioItemID: audioItemID,
                fullySpoken: fullySpoken,
                at: date
            )
        }
    }

    @discardableResult
    func reconcileSpokenShare(
        sessionID: String,
        responseID: String,
        audioItemID: String,
        generatedText: String,
        fullySpoken: Bool,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        mutateShareState(at: explicitDate) { current, date in
            PrivateLifeEngine.reconcileSpokenShare(
                current,
                sessionID: sessionID,
                responseID: responseID,
                audioItemID: audioItemID,
                generatedText: generatedText,
                fullySpoken: fullySpoken,
                at: date
            )
        }
    }

    @discardableResult
    func cancelPendingShares(
        sessionID: String,
        at explicitDate: Date? = nil
    ) -> PrivateLifeSnapshot {
        mutateShareState(at: explicitDate) { current, date in
            PrivateLifeEngine.cancelPendingShares(
                current,
                sessionID: sessionID,
                at: date
            )
        }
    }

    /// Verification and integration visibility. Production voice receives only
    /// `voiceContext()` rather than raw private evidence or state fields.
    func stateForVerification() -> PrivateLifeState? {
        state
    }

    /// Returns only a completed, model-generated activity that survived the
    /// current generated-content boundary. This is the narrow bridge from
    /// GPT-5.6's background reflection into durable *private agency*; it does
    /// not promote the activity into factual/autobiographical memory. The
    /// older `promotionEligible` field intentionally remains false because an
    /// authored interpretation must never become evidence that an external
    /// event happened merely by being reflected upon.
    func activityEligibleForAgencyPromotion(_ activityID: String) -> PrivateLifeActivity? {
        ensureLoaded(at: now())
        guard failureDescription == nil else { return nil }
        return state?.activities.first(where: {
            $0.id == activityID && Self.isAgencyPromotionEligible($0)
        })
    }

    /// Bounded restart bridge. Aurora may have finished a reflection shortly
    /// before the app quit; relaunch imports only the newest few validated
    /// private positions, and the agency store's authoring-source idempotency
    /// prevents duplicates.
    func recentActivitiesEligibleForAgencyPromotion(
        limit requestedLimit: Int = 3
    ) -> [PrivateLifeActivity] {
        ensureLoaded(at: now())
        guard failureDescription == nil, let state else { return [] }
        let limit = min(4, max(1, requestedLimit))
        return Array(state.activities
            .filter(Self.isAgencyPromotionEligible)
            .sorted {
                ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
            }
            .prefix(limit))
    }

    private static func isAgencyPromotionEligible(
        _ activity: PrivateLifeActivity
    ) -> Bool {
        activity.status == .completed
            && activity.modelGenerated
            && activity.model?.hasPrefix("gpt-5.6") == true
            && activity.evidenceClass == .selfAuthoredInterpretation
            // Version-three GPT-5.6 reflections may be revalidated as
            // nonverbatim private positions. They remain ineligible for the
            // separate voice-ready share path unless the current engine has
            // already marked `projectionEligible`.
            && activity.validationVersion >= 3
            && !activity.sourceDigests.isEmpty
            && !activity.privateReflection.isEmpty
            && !PrivateLifeGeneratedContentPolicy.rejects(
                activity.privateReflection
            )
            && PrivateLifeGeneratedContentPolicy.isNaturalFirstPerson(
                activity.privateReflection
            )
            && !activity.externalActionTaken
            && !activity.outboundContactSent
    }

    private func ensureLoaded(at date: Date) {
        guard state == nil, failureDescription == nil else { return }
        do {
            if processLock == nil {
                processLock = try store.acquireExclusiveProcessLock()
            }
            let resumed: PrivateLifeState
            if let loaded = try store.load() {
                if loaded.schemaVersion < PrivateLifeState.currentSchemaVersion {
                    try store.backupStateBeforeMigrationIfNeeded(schemaVersion: loaded.schemaVersion)
                }
                resumed = PrivateLifeEngine.resume(loaded, at: date)
            } else {
                resumed = PrivateLifeEngine.defaultState(at: date)
            }
            try store.save(resumed)
            state = resumed
        } catch {
            failureDescription = error.localizedDescription
        }
    }

    private func persist(_ nextState: PrivateLifeState) {
        do {
            try store.save(nextState)
            state = nextState
        } catch {
            // Retain the in-memory value for diagnosis, but stop projecting it
            // as durable lived continuity until persistence is repaired.
            failureDescription = error.localizedDescription
        }
    }

    private func mutateShareState(
        at explicitDate: Date?,
        _ mutation: (PrivateLifeState, Date) -> PrivateLifeEvolution
    ) -> PrivateLifeSnapshot {
        let requestedDate = explicitDate ?? now()
        ensureLoaded(at: requestedDate)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let date = max(requestedDate, current.lastSchedulerAt)
        let evolution = mutation(current, date)
        state = evolution.state
        if evolution.changed { persist(evolution.state) }
        return snapshotLocked()
    }

    private func snapshotLocked() -> PrivateLifeSnapshot {
        if let failureDescription {
            return .unavailable(failureDescription)
        }
        return PrivateLifeSnapshot(available: state != nil, state: state, failureDescription: nil)
    }
}
