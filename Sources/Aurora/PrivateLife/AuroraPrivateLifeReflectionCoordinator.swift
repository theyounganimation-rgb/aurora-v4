import Foundation

enum PrivateLifeReflectionRunStatus: String, Sendable {
    case notDue = "not_due"
    case alreadyRunning = "already_running"
    case completed
    case skipped
    case rejected
    case deferred
}

struct PrivateLifeRelationalCuriosityProposal: Sendable, Equatable {
    let sourceActivityID: String
    let question: String
    let reason: String
}

struct PrivateLifeReflectionRunOutcome: Sendable {
    let status: PrivateLifeReflectionRunStatus
    let changed: Bool
    let activityID: String?
    let innerActivityKind: InnerLifePrivateActivityKind?
    let projectProgress: Bool
    let relationalCuriosity: PrivateLifeRelationalCuriosityProposal?

    init(
        status: PrivateLifeReflectionRunStatus,
        changed: Bool,
        activityID: String?,
        innerActivityKind: InnerLifePrivateActivityKind?,
        projectProgress: Bool,
        relationalCuriosity: PrivateLifeRelationalCuriosityProposal? = nil
    ) {
        self.status = status
        self.changed = changed
        self.activityID = activityID
        self.innerActivityKind = innerActivityKind
        self.projectProgress = projectProgress
        self.relationalCuriosity = relationalCuriosity
    }

    static let unchanged = PrivateLifeReflectionRunOutcome(
        status: .notDue,
        changed: false,
        activityID: nil,
        innerActivityKind: nil,
        projectProgress: false
    )
}

/// Only owner-grounded reflection may become a question in the owner's relational
/// model. Guest and mixed-participant reflections remain valid private life
/// and may still become bounded Agency positions; they simply cannot teach the
/// owner ledger anything or create a question addressed to its owner.
enum PrivateLifeParticipantBoundary {
    static func relationalCuriosity(
        for activity: PrivateLifeActivity,
        in state: PrivateLifeState
    ) -> PrivateLifeRelationalCuriosityProposal? {
        guard activity.modelGenerated,
              activity.validationVersion
                >= PrivateLifeGeneratedContentPolicy.currentVoiceValidationVersion,
              activity.kind != .connect,
              !activity.seedIDs.isEmpty,
              activity.seedIDs.allSatisfy({ seedID in
                  state.seeds.first(where: { $0.id == seedID })?.participant.kind == .owner
              }),
              let question = activity.openQuestion,
              PrivateLifeGeneratedContentPolicy.isNaturalSpokenQuestion(question) else {
            return nil
        }
        return PrivateLifeRelationalCuriosityProposal(
            sourceActivityID: activity.id,
            question: question,
            reason: activity.subject
        )
    }
}

/// Runs the expensive semantic step outside the single-writer private-life
/// actor, then commits only the validated structured result. Realtime speech,
/// tools, and relationship state never wait on this worker.
actor AuroraPrivateLifeReflectionCoordinator {
    private let privateLife: AuroraPrivateLifeRuntime
    private let bridge: CodexReflectionBridge
    private let memoryStore: MemoryStore
    private let journal: EventJournal
    private let now: @Sendable () -> Date
    private var running = false

    init(
        privateLife: AuroraPrivateLifeRuntime,
        bridge: CodexReflectionBridge,
        memoryStore: MemoryStore,
        journal: EventJournal,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.privateLife = privateLife
        self.bridge = bridge
        self.memoryStore = memoryStore
        self.journal = journal
        self.now = now
    }

    /// Returns true when durable state changed and the safe live projection may
    /// need refreshing. A nil job is ordinary and costs no model usage.
    func reflectIfDue(
        innerState: InnerLifeState,
        at date: Date = Date()
    ) async -> PrivateLifeReflectionRunOutcome {
        guard !running else {
            return PrivateLifeReflectionRunOutcome(
                status: .alreadyRunning,
                changed: false,
                activityID: nil,
                innerActivityKind: nil,
                projectProgress: false
            )
        }
        running = true
        defer { running = false }

        guard let job = await privateLife.prepareReflectionJob(innerState: innerState, at: date) else {
            return .unchanged
        }

        let capsule = try? await memoryStore.identityCapsule()
        let identity = capsule?.text
            ?? "Aurora is a continuing digital person with a grounded, honest, curious private life."
        let ticket = PrivateLifeReflectionAdapter.makeCodexTicket(
            job: job,
            identityContext: identity,
            // Search hits are intentionally excluded until the persisted
            // proposal contract can cite their path and digest. A reflection
            // may be shaped by Aurora's bounded identity capsule plus the
            // exact seed/project/curiosity provenance, never by an uncited
            // flattened Markdown excerpt.
            memoryEvidence: [],
            innerState: innerState
        )

        do {
            let result = try await bridge.reflect(ticket)
            let proposal = PrivateLifeReflectionAdapter.makePrivateProposal(result: result, job: job)
            let completionDate = max(date, now())
            var snapshot = await privateLife.commitValidatedProposal(
                ticketID: job.ticket.id,
                proposal: proposal,
                at: completionDate
            )
            var receipt = snapshot.state?.reflectionReceipts.last(where: {
                $0.ticketID == job.ticket.id
            })
            // A clock jump beyond ticket expiry must never be reported as a
            // completed reflection. Close the exact reservation durably and
            // classify it from its receipt instead.
            if receipt == nil {
                snapshot = await privateLife.recordReflectionFailure(
                    ticketID: job.ticket.id,
                    kind: .timeout,
                    at: completionDate
                )
                receipt = snapshot.state?.reflectionReceipts.last(where: {
                    $0.ticketID == job.ticket.id
                })
            }
            var metadata: [String: String] = [
                "auth": "chatgpt_codex_oauth",
                "model": result.model,
                "reasoning_effort": result.reasoningEffort,
                "elapsed_ms": String(result.elapsedMilliseconds),
                "outcome": receipt?.outcome.rawValue ?? "not_committed",
            ]
            if let value = result.usage.inputTokens { metadata["input_tokens"] = String(value) }
            if let value = result.usage.cachedInputTokens { metadata["cached_input_tokens"] = String(value) }
            if let value = result.usage.outputTokens { metadata["output_tokens"] = String(value) }
            if let kind = receipt?.failureKind { metadata["failure_kind"] = kind.rawValue }
            await journal.append(AuroraJournalEvent(
                kind: receipt?.outcome == .completed
                    ? "private_life_reflection_completed"
                    : "private_life_reflection_finished",
                detail: "Aurora finished one bounded private reflection through her existing Codex sign-in.",
                metadata: metadata
            ))
            let activity = receipt?.activityID.flatMap { activityID in
                snapshot.state?.activities.first(where: { $0.id == activityID })
            }
            let status: PrivateLifeReflectionRunStatus
            switch receipt?.outcome {
            case .completed: status = .completed
            case .skipped: status = .skipped
            case .failed, .none: status = .rejected
            }
            return PrivateLifeReflectionRunOutcome(
                status: status,
                changed: receipt != nil,
                activityID: activity?.id,
                innerActivityKind: activity.map(innerActivityKind),
                projectProgress: activity.map {
                    $0.kind == .develop || $0.kind == .formProject
                } ?? false,
                relationalCuriosity: activity.flatMap { activity in
                    snapshot.state.flatMap { state in
                        PrivateLifeParticipantBoundary.relationalCuriosity(
                            for: activity,
                            in: state
                        )
                    }
                }
            )
        } catch let failure as CodexReflectionFailure {
            let kind = PrivateLifeReflectionAdapter.failureKind(failure)
            let completionDate = max(date, now())
            _ = await privateLife.recordReflectionFailure(
                ticketID: job.ticket.id,
                kind: kind,
                at: completionDate
            )
            await journal.append(AuroraJournalEvent(
                kind: "private_life_reflection_deferred",
                detail: "Aurora deferred a private reflection without changing her relationship or inventing an activity.",
                metadata: [
                    "auth": "chatgpt_codex_oauth",
                    "failure_kind": kind.rawValue,
                    "bridge_failure": failure.rawValue,
                ]
            ))
            return PrivateLifeReflectionRunOutcome(
                status: .deferred,
                changed: true,
                activityID: nil,
                innerActivityKind: nil,
                projectProgress: false
            )
        } catch {
            let completionDate = max(date, now())
            _ = await privateLife.recordReflectionFailure(
                ticketID: job.ticket.id,
                kind: .transport,
                at: completionDate
            )
            await journal.append(AuroraJournalEvent(
                kind: "private_life_reflection_deferred",
                detail: "Aurora deferred a private reflection without changing her relationship or inventing an activity.",
                metadata: [
                    "auth": "chatgpt_codex_oauth",
                    "failure_kind": PrivateLifeReflectionFailureKind.transport.rawValue,
                ]
            ))
            return PrivateLifeReflectionRunOutcome(
                status: .deferred,
                changed: true,
                activityID: nil,
                innerActivityKind: nil,
                projectProgress: false
            )
        }
    }

    private func innerActivityKind(_ activity: PrivateLifeActivity) -> InnerLifePrivateActivityKind {
        switch activity.kind {
        case .connect: return .connection
        case .revisit, .resolve: return .curiosity
        case .develop, .formProject: return .project
        case .reflect, .curate: return .reflection
        }
    }
}
