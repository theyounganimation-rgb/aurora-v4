import Foundation

/// Single-writer owner of Aurora's persistent background-life state.
///
/// The runtime is deliberately model-free. Its clock can run while the voice
/// session rests, and catch-up is analytical after a relaunch, but it never
/// opens a network connection or forces a Realtime response.
actor AuroraInnerLifeRuntime {
    private let store: InnerLifeStore
    private let externalContactBridge: ExternalOwnerContactBridge
    private let now: @Sendable () -> Date
    private var state: InnerLifeState?
    private var failureDescription: String?
    private var processLock: InnerLifeProcessLock?

    init(
        store: InnerLifeStore = InnerLifeStore(),
        externalContactBridge: ExternalOwnerContactBridge = ExternalOwnerContactBridge(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.externalContactBridge = externalContactBridge
        self.now = now
    }

    @discardableResult
    func start() -> InnerLifeSnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    @discardableResult
    func tick(at explicitDate: Date? = nil) -> InnerLifeSnapshot {
        let date = explicitDate ?? now()
        ensureLoaded(at: date)
        guard failureDescription == nil, let current = state else {
            return snapshotLocked()
        }
        let bridged = ingestExternalOwnerContact(into: current, at: date)
        // A delayed scheduler wake may represent macOS sleep or suspension.
        // Advance continuously, but record at most the present motion rather
        // than fabricating an interval-by-interval history.
        let evolution = InnerLifeEngine.advance(
            bridged.state,
            to: date,
            recordIntermediateMotions: false
        )
        guard bridged.changed || evolution.changed else { return snapshotLocked() }
        persist(evolution.state)
        return snapshotLocked()
    }

    @discardableResult
    func record(_ event: InnerLifeEvent) -> InnerLifeSnapshot {
        record([event])
    }

    /// Applies one causally ordered turn or lifecycle batch as a single actor
    /// transaction and one atomic persistence write. The clock cannot interleave
    /// between owner speech and Aurora's matching playback outcome.
    @discardableResult
    func record(_ events: [InnerLifeEvent]) -> InnerLifeSnapshot {
        guard let first = events.first else {
            ensureLoaded(at: now())
            return snapshotLocked()
        }
        ensureLoaded(at: first.at)
        guard failureDescription == nil, var next = state else {
            return snapshotLocked()
        }
        // A verified owner message may arrive between one-minute clock ticks.
        // Ingest it before the foreground lifecycle/voice event so a wake that
        // immediately follows Telegram or owner webchat contact cannot project
        // one stale minute of separation affect into the new voice session.
        next = ingestExternalOwnerContact(into: next, at: first.at).state
        for event in events {
            let orderedEvent = InnerLifeEvent(
                id: event.id,
                at: max(event.at, next.lastClockAt),
                kind: event.kind
            )
            next = InnerLifeEngine.apply(orderedEvent, to: next).state
        }
        persist(next)
        return snapshotLocked()
    }

    func snapshot() -> InnerLifeSnapshot {
        ensureLoaded(at: now())
        return snapshotLocked()
    }

    func voiceContext() -> String {
        ensureLoaded(at: now())
        guard failureDescription == nil, let state else {
            return """
            PRIVATE INNER-LIFE CONTEXT — UNAVAILABLE
            Aurora's persisted inner-life state could not be verified, so no mood, motive, or background experience may be assumed from it. Continue naturally from the live audio, grounded memory, and explicit evidence only.
            """
        }
        return InnerLifeEngine.voiceProjection(for: state)
    }

    /// Verification-only visibility. Production conversation receives only the
    /// bounded qualitative projection returned by `voiceContext()`.
    func stateForVerification() -> InnerLifeState? {
        state
    }

    private func ensureLoaded(at date: Date) {
        guard state == nil, failureDescription == nil else { return }
        do {
            if processLock == nil {
                processLock = try store.acquireExclusiveProcessLock()
            }
            if let loaded = try store.load() {
                let sanitized = InnerLifeEngine.sanitize(loaded, now: date)
                let bridged = ingestExternalOwnerContact(into: sanitized, at: date)
                let evolution = InnerLifeEngine.advance(
                    bridged.state,
                    to: date,
                    recordIntermediateMotions: false
                )
                try store.save(evolution.state)
                state = evolution.state
            } else {
                let initial = InnerLifeEngine.defaultState(at: date)
                // Markers older than this new continuity state are ignored;
                // a newly installed runtime never fabricates prehistory.
                let bridged = ingestExternalOwnerContact(into: initial, at: date)
                try store.save(bridged.state)
                state = bridged.state
            }
        } catch {
            failureDescription = error.localizedDescription
        }
    }

    private func persist(_ nextState: InnerLifeState) {
        do {
            try store.save(nextState)
            state = nextState
        } catch {
            // Retain the last verified in-memory state for diagnostics, but stop
            // projecting it as durable continuity until persistence is repaired.
            failureDescription = error.localizedDescription
        }
    }

    private func ingestExternalOwnerContact(
        into current: InnerLifeState,
        at date: Date
    ) -> (state: InnerLifeState, changed: Bool) {
        // This auxiliary bridge can never make Aurora's primary state
        // unavailable. Unsafe, malformed, future, or stale markers are simply
        // not evidence of contact. The bridge itself validates no-follow file
        // ownership, privacy, bounded size, schema, and content-free keys.
        guard let marker = try? externalContactBridge.latestContact(referenceDate: date),
              marker.at <= date,
              marker.at > current.createdAt,
              marker.at > (current.relationship.lastExternalContactAt ?? .distantPast),
              marker.at > (current.temporal.lastOwnerContactAt ?? .distantPast),
              !current.recentEventIDs.contains(marker.eventID) else {
            return (current, false)
        }

        let evolution = InnerLifeEngine.apply(
            InnerLifeEvent(
                id: marker.eventID,
                at: marker.at,
                kind: .externalOwnerContact(sourceID: marker.source)
            ),
            to: current
        )
        return (evolution.state, evolution.changed)
    }

    private func snapshotLocked() -> InnerLifeSnapshot {
        if let failureDescription {
            return .unavailable(failureDescription)
        }
        return InnerLifeSnapshot(available: state != nil, state: state, failureDescription: nil)
    }
}
