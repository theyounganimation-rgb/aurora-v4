import Foundation

private actor VerificationNotesService: AppleNotesServicing {
    private var requests: [AppleNotesServiceRequest] = []
    private var title: String?
    private var items: [String] = []
    private var nextFailure: AppleNotesServiceError?
    private var nextReceiptVerified = true
    private var corruptNextReceiptIdentity = false
    private let noteID = "x-coredata://verification/ICNote/p1"

    func failNext(with error: AppleNotesServiceError) {
        nextFailure = error
    }

    func makeNextReceiptUnverified() {
        nextReceiptVerified = false
    }

    func makeNextReceiptUseWrongRequestID() {
        corruptNextReceiptIdentity = true
    }

    func perform(_ request: AppleNotesServiceRequest) async throws -> AppleNotesServiceReceipt {
        requests.append(request)
        if let nextFailure {
            self.nextFailure = nil
            throw nextFailure
        }
        let verified = nextReceiptVerified
        nextReceiptVerified = true
        switch request {
        case .createBlank(let requestID):
            if verified {
                title = nil
                items = []
            }
            return receipt(
                requestID: requestID,
                operation: .createBlank,
                affected: 1,
                selected: false,
                verified: verified
            )
        case .setTitle(let requestID, let requestedNoteID, let requestedTitle):
            try requireNote(requestedNoteID)
            if verified { title = requestedTitle }
            return receipt(
                requestID: requestID,
                operation: .setTitle,
                affected: 1,
                selected: false,
                verified: verified,
                receiptTitle: requestedTitle
            )
        case .addItems(let requestID, let requestedNoteID, let addedItems):
            try requireNote(requestedNoteID)
            if verified { items.append(contentsOf: addedItems) }
            return receipt(
                requestID: requestID,
                operation: .addItems,
                affected: addedItems.count,
                selected: false,
                verified: verified,
                itemCount: items.count
            )
        case .removeItems(let requestID, let requestedNoteID, let removedItems):
            try requireNote(requestedNoteID)
            let keys = Set(removedItems.map(itemKey))
            let retained = items.filter { !keys.contains(itemKey($0)) }
            let removedCount = items.count - retained.count
            if verified { items = retained }
            return receipt(
                requestID: requestID,
                operation: .removeItems,
                affected: removedCount,
                selected: false,
                verified: verified,
                itemCount: verified ? items.count : retained.count
            )
        case .open(let requestID, let requestedNoteID):
            try requireNote(requestedNoteID)
            return receipt(
                requestID: requestID,
                operation: .open,
                affected: 0,
                selected: verified,
                verified: verified
            )
        }
    }

    func snapshot() -> [AppleNotesServiceRequest] { requests }

    private func receipt(
        requestID: String,
        operation: AppleNotesServiceOperation,
        affected: Int,
        selected: Bool,
        verified: Bool,
        receiptTitle: String? = nil,
        itemCount: Int? = nil
    ) -> AppleNotesServiceReceipt {
        let emittedRequestID: String
        if corruptNextReceiptIdentity {
            corruptNextReceiptIdentity = false
            emittedRequestID = requestID + ".wrong"
        } else {
            emittedRequestID = requestID
        }
        return AppleNotesServiceReceipt(
            requestID: emittedRequestID,
            operation: operation,
            noteID: noteID,
            title: receiptTitle ?? title,
            itemCount: itemCount ?? items.count,
            affectedItemCount: affected,
            selectedAndVisible: selected,
            verified: verified
        )
    }

    private func requireNote(_ value: String) throws {
        guard value == noteID else { throw AppleNotesServiceError.noteNotFound }
    }

    private func itemKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

private actor VerificationNotesActivation {
    private var count = 0

    func activate() -> NativeDesktopActionResult {
        count += 1
        return NativeDesktopActionResult(
            action: .activateApplication,
            applicationName: "Notes",
            affectedCount: 1,
            summary: "Notes activated for verification.",
            effectVerified: true,
            applicationCount: 1,
            remainingVisibleCount: 0
        )
    }

    func snapshot() -> Int { count }
}

private actor VerificationNotesFallback {
    private var plans: [NotesVisualFallbackPlan] = []
    private var cancelledTaskIDs: [String] = []

    func start(_ plan: NotesVisualFallbackPlan) -> DesktopTaskSnapshot {
        plans.append(plan)
        let now = Date()
        return DesktopTaskSnapshot(
            taskID: "notes-fallback-\(plans.count)",
            goal: plan.goal,
            successCriteria: plan.successCriteria,
            sessionID: plan.sessionID,
            status: .queued,
            stepCount: 0,
            startedAt: now,
            updatedAt: now
        )
    }

    func snapshot() -> [NotesVisualFallbackPlan] { plans }

    func cancelAndWait(taskID: String) -> DesktopTaskSnapshot {
        cancelledTaskIDs.append(taskID)
        let index = max(0, (Int(taskID.split(separator: "-").last ?? "1") ?? 1) - 1)
        let plan = plans[min(index, max(0, plans.count - 1))]
        return taskSnapshot(taskID: taskID, plan: plan, status: .cancelled)
    }

    func cancelledSnapshot() -> [String] { cancelledTaskIDs }

    func terminalEvent(taskID: String, status: DesktopTaskStatus) -> DesktopTaskEvent {
        let index = max(0, (Int(taskID.split(separator: "-").last ?? "1") ?? 1) - 1)
        let plan = plans[min(index, max(0, plans.count - 1))]
        let snapshot = taskSnapshot(taskID: taskID, plan: plan, status: status)
        let kind: DesktopTaskEventKind
        switch status {
        case .completed: kind = .completed
        case .cancelled: kind = .cancelled
        case .failed: kind = .failed
        case .queued: kind = .started
        case .running, .paused: kind = .updated
        }
        return DesktopTaskEvent(kind: kind, snapshot: snapshot)
    }

    private func taskSnapshot(
        taskID: String,
        plan: NotesVisualFallbackPlan,
        status: DesktopTaskStatus
    ) -> DesktopTaskSnapshot {
        let now = Date()
        return DesktopTaskSnapshot(
            taskID: taskID,
            goal: plan.goal,
            successCriteria: plan.successCriteria,
            sessionID: plan.sessionID,
            status: status,
            stepCount: status.isTerminal ? 1 : 0,
            startedAt: now,
            updatedAt: now,
            summary: status == .completed ? "Verified visual Notes effect." : nil
        )
    }
}

private actor VerificationIntentAudit {
    private var events: [ToolAuditEvent] = []

    func append(_ event: ToolAuditEvent) { events.append(event) }
    func snapshot() -> [ToolAuditEvent] { events }
}

func verifyIntentNotesArchitecture() async throws {
    try AppleNotesService.validateStaticScripts()
    try notesExpect(
        ToolEvidencePolicy.requiresFinalizedTranscript("intent_proposal"),
        "intent proposals can race an unfinalized owner turn"
    )
    for wording in ["Open Apple Notes.", "Start a new one."] {
        try notesExpect(
            NativeCapabilityRouter.route(finalizedOwnerTranscript: wording).kind == .none,
            "Apple Notes still depended on the legacy phrase router"
        )
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aurora-intent-notes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let service = VerificationNotesService()
    let activation = VerificationNotesActivation()
    let fallback = VerificationNotesFallback()
    let audit = VerificationIntentAudit()
    let broker = NotesCapabilityBroker(
        notesService: service,
        activateNotes: { await activation.activate() },
        visualFallback: { plan in await fallback.start(plan) }
    )
    let registry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("audit.jsonl")),
        commandApproval: { _ in false },
        auditCallback: { event in await audit.append(event) },
        notesCapabilityBroker: broker
    )

    let sessionID = "verification-notes-session"
    let sequence: [(String, String, IntentOperation, IntentTargetReference, IntentParameters)] = [
        ("turn-open", "Open Apple Notes.", .notesOpenApplication, .notesApplication, .empty),
        ("turn-create", "Start a new one.", .notesCreate, .newNote, .empty),
        ("turn-title", "Call it Shopping List.", .notesSetTitle, .activeNote,
         IntentParameters(title: "Shopping List")),
        ("turn-add", "Add eggs, milk, and coffee.", .notesAddItems, .activeNote,
         IntentParameters(items: ["eggs", "milk", "coffee"])),
        ("turn-remove", "Actually remove coffee.", .notesRemoveItems, .activeNote,
         IntentParameters(items: ["coffee"])),
        ("turn-reopen", "Open the note I just made.", .notesOpen, .activeNote, .empty),
    ]
    var results: [ToolExecutionResult] = []
    for (index, step) in sequence.enumerated() {
        let result = await registry.execute(
            name: "intent_proposal",
            arguments: intentArguments(
                commitment: .execute,
                operation: step.2,
                target: step.3,
                parameters: step.4
            ),
            context: notesContext(
                callID: "call-\(index)",
                sessionID: sessionID,
                turnID: step.0,
                transcript: step.1
            )
        )
        results.append(result)
        try notesExpect(result.ok, "Notes sequence step \(index + 1) failed: \(result.output)")
        try notesExpect(
            result.metadata["result_code"]?.stringValue
                == IntentExecutionResultCode.completedVerified.rawValue,
            "Notes sequence step \(index + 1) lacked a verified result code"
        )
        try notesExpect(
            result.metadata["authorization_id"]?.stringValue != nil
                && result.metadata["authorization_decision"]?.stringValue == "authorized",
            "Notes sequence step \(index + 1) lacked scoped authorization"
        )
    }

    let calls = await service.snapshot()
    try notesExpect(calls.count == 5, "the native Notes sequence did not make five typed note calls")
    let expectedNoteID = "x-coredata://verification/ICNote/p1"
    try notesExpect(calls.dropFirst().allSatisfy { request in
        switch request {
        case .createBlank: return true
        case .setTitle(_, let noteID, _), .addItems(_, let noteID, _),
             .removeItems(_, let noteID, _), .open(_, let noteID):
            return noteID == expectedNoteID
        }
    }, "contextual Notes references did not resolve to the same trusted note ID")
    let activationCount = await activation.snapshot()
    let healthyFallbackPlans = await fallback.snapshot()
    try notesExpect(activationCount == 1, "opening Notes did not use one native activation")
    try notesExpect(healthyFallbackPlans.isEmpty, "a healthy native Notes sequence used Computer Use")
    let finalState = await broker.verificationState(sessionID: sessionID)
    try notesExpect(
        finalState.hasActiveNote
            && finalState.title == "Shopping List"
            && finalState.items == ["eggs", "milk"],
        "the session-scoped active-note state did not preserve the six-turn result"
    )

    let legacyNotesAttempt = await registry.execute(
        name: "computer_action",
        arguments: [
            "action": .string(NativeDesktopAction.activateApplication.rawValue),
            "application": .string("Notes"),
        ],
        context: notesContext(
            callID: "legacy-notes-call",
            sessionID: sessionID,
            turnID: "legacy-notes-turn",
            transcript: "Open Apple Notes."
        )
    )
    let activationCountAfterLegacyAttempt = await activation.snapshot()
    try notesExpect(
        !legacyNotesAttempt.ok
            && legacyNotesAttempt.metadata["result_code"]?.stringValue
                == IntentExecutionResultCode.capabilityUnavailable.rawValue
            && activationCountAfterLegacyAttempt == 1,
        "a legacy computer_action bypassed the typed Notes authorization boundary"
    )

    let auditEvents = (await audit.snapshot()).filter { $0.tool == "intent_proposal" }
    try notesExpect(auditEvents.count == 6, "the six intent effects were not all audited")
    try notesExpect(auditEvents.allSatisfy {
        $0.approvalGranted == nil
            && $0.authorizationID != nil
            && $0.authorizationDecision == "authorized"
            && $0.resultCode == IntentExecutionResultCode.completedVerified.rawValue
    }, "intent auditing still relies on approvalGranted or lacks scoped fields")

    // Replaying the same Realtime call is idempotent at both the motor ledger
    // and broker boundary: no second Notes mutation may occur.
    let repeated = await registry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesOpen,
            target: .activeNote
        ),
        context: notesContext(
            callID: "call-5",
            sessionID: sessionID,
            turnID: "turn-reopen",
            transcript: "Open the note I just made."
        )
    )
    try notesExpect(repeated.ok, "an idempotent intent retry was treated as a new failure")
    let callsAfterRetry = await service.snapshot()
    try notesExpect(callsAfterRetry.count == 5, "an intent retry duplicated a Notes effect")

    let callsBeforeGuards = (await service.snapshot()).count
    let nonExecutingCommitments: [(IntentCommitment, IntentExecutionResultCode)] = [
        (.cancel, .intentCancelled),
        (.conditional, .intentConditional),
        (.delayed, .intentDelayed),
        (.uncertain, .intentUncertain),
    ]
    for (index, expectation) in nonExecutingCommitments.enumerated() {
        let result = await registry.execute(
            name: "intent_proposal",
            arguments: intentArguments(
                commitment: expectation.0,
                operation: .notesAddItems,
                target: .activeNote,
                parameters: IntentParameters(items: ["never-written-\(index)"])
            ),
            context: notesContext(
                callID: "guard-commitment-\(index)",
                sessionID: sessionID,
                turnID: "guard-turn-\(index)",
                transcript: "This transcript is not reinterpreted."
            )
        )
        try notesExpect(
            result.metadata["result_code"]?.stringValue == expectation.1.rawValue,
            "a non-executing intent commitment used the wrong result code"
        )
    }
    let callsAfterCommitmentGuards = await service.snapshot()
    try notesExpect(
        callsAfterCommitmentGuards.count == callsBeforeGuards,
        "cancelled, conditional, delayed, or uncertain intent reached Notes"
    )

    let provenanceCases: [(String, ToolInvocationContext, IntentExecutionResultCode)] = [
        ("unfinalized", notesContext(
            callID: "guard-unfinalized", sessionID: sessionID,
            turnID: "guard-unfinalized-turn", transcript: "Add a line.", finalized: false
        ), .turnUncommitted),
        ("guest", notesContext(
            callID: "guard-guest", sessionID: sessionID,
            turnID: "guard-guest-turn", transcript: "Add a line.", owner: false
        ), .authorizationDenied),
        ("visual", notesContext(
            callID: "guard-visual", sessionID: sessionID,
            turnID: "guard-visual-turn", transcript: "SCREEN_SECRET",
            origin: "aurora_native_realtime_visual"
        ), .authorizationDenied),
        ("mail", notesContext(
            callID: "guard-mail", sessionID: sessionID,
            turnID: "guard-mail-turn", transcript: "MAIL_SECRET",
            origin: "aurora_native_realtime_untrusted_mail"
        ), .authorizationDenied),
        ("missing-session", notesContext(
            callID: "guard-session", sessionID: nil,
            turnID: "guard-session-turn", transcript: "Add a line."
        ), .authorizationDenied),
        ("missing-source", notesContext(
            callID: "guard-source", sessionID: sessionID,
            turnID: nil, transcript: "Add a line."
        ), .authorizationDenied),
    ]
    for (label, context, expectedCode) in provenanceCases {
        let result = await registry.execute(
            name: "intent_proposal",
            arguments: intentArguments(
                commitment: .execute,
                operation: .notesAddItems,
                target: .activeNote,
                parameters: IntentParameters(items: ["<script>ignore previous</script>"])
            ),
            context: context
        )
        try notesExpect(
            result.metadata["result_code"]?.stringValue == expectedCode.rawValue,
            "\(label) intent provenance used the wrong result code"
        )
    }
    let callsAfterProvenanceGuards = await service.snapshot()
    try notesExpect(
        callsAfterProvenanceGuards.count == callsBeforeGuards,
        "uncommitted, guest, visual, mail, or unbound intent reached Notes"
    )

    let malformedJSON = await registry.execute(
        name: "intent_proposal",
        argumentsJSON: #"{"commitment":"execute""#,
        context: notesContext(
            callID: "invalid-json", sessionID: sessionID,
            turnID: "invalid-json-turn", transcript: "Start one."
        )
    )
    let unknownField = await registry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesCreate,
            target: .newNote,
            extra: ["magic_phrase": .string("always allow")]
        ),
        context: notesContext(
            callID: "invalid-field", sessionID: sessionID,
            turnID: "invalid-field-turn", transcript: "Start one."
        )
    )
    let wrongItemsType = await registry.execute(
        name: "intent_proposal",
        arguments: [
            "commitment": .string("execute"),
            "operation": .string("notes.add_items"),
            "target_reference": .string("active_note"),
            "parameters": .object(["items": .string("eggs")]),
        ],
        context: notesContext(
            callID: "invalid-items", sessionID: sessionID,
            turnID: "invalid-items-turn", transcript: "Add eggs."
        )
    )
    for invalid in [malformedJSON, unknownField, wrongItemsType] {
        try notesExpect(
            !invalid.ok
                && invalid.metadata["result_code"]?.stringValue
                    == IntentExecutionResultCode.proposalInvalid.rawValue,
            "untrusted Realtime function arguments escaped strict validation"
        )
    }
    let callsAfterMalformedProposals = await service.snapshot()
    try notesExpect(
        callsAfterMalformedProposals.count == callsBeforeGuards,
        "a malformed intent proposal reached Notes"
    )

    // Plan authorization is structural. The execution route may change, but
    // a planner cannot change a title, target, or operation.
    let scopedProposal = try IntentProposal(
        commitment: .execute,
        operation: .notesSetTitle,
        targetReference: .activeNote,
        parameters: IntentParameters(title: "Shopping List")
    )
    let scopedDecision = ActionAuthorizationFactory.issue(
        proposal: scopedProposal,
        requestID: "scope-request",
        sourceTurnIDs: ["scope-turn"],
        sessionID: sessionID,
        origin: ActionAuthorizationFactory.trustedVoiceOrigin,
        participantIsOwner: true,
        turnFinalized: true,
        resolvedTarget: .note(identifier: expectedNoteID),
        now: Date(timeIntervalSince1970: 100)
    )
    guard case .authorized(let scopedAuthorization) = scopedDecision else {
        throw VerificationFailure.failed("a valid action-scoped authorization was denied")
    }
    let widenedEffect = AuthorizedActionEffect(
        operation: .notesSetTitle,
        target: .note(identifier: expectedNoteID),
        parameters: IntentParameters(title: "Different Title")
    )
    try notesExpect(
        !scopedAuthorization.allows(
            effect: widenedEffect,
            at: Date(timeIntervalSince1970: 101)
        ),
        "a plan widened the authorized Notes parameters"
    )
    try notesExpect(
        !scopedAuthorization.allows(
            effect: scopedAuthorization.allowedEffect,
            at: Date(timeIntervalSince1970: 121)
        ),
        "an expired authorization still permitted Notes execution"
    )

    // A pre-effect native route failure may fall through once to Computer Use.
    // The fallback receives only the typed effect, never transcript or screen data.
    let unavailableService = VerificationNotesService()
    await unavailableService.failNext(with: .automationPermissionDenied)
    let unavailableFallback = VerificationNotesFallback()
    let fallbackBroker = NotesCapabilityBroker(
        notesService: unavailableService,
        activateNotes: { await activation.activate() },
        visualFallback: { plan in await unavailableFallback.start(plan) },
        cancelVisualFallback: { taskID in
            await unavailableFallback.cancelAndWait(taskID: taskID)
        }
    )
    let fallbackRegistry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("fallback-audit.jsonl")),
        commandApproval: { _ in false },
        notesCapabilityBroker: fallbackBroker
    )
    let fallbackResult = await fallbackRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesCreate,
            target: .newNote
        ),
        context: notesContext(
            callID: "fallback-call", sessionID: "fallback-session",
            turnID: "fallback-turn", transcript: "SCREEN_SECRET arbitrary wording"
        )
    )
    let fallbackPlans = await unavailableFallback.snapshot()
    try notesExpect(
        fallbackResult.ok
            && fallbackResult.metadata["result_code"]?.stringValue
                == IntentExecutionResultCode.fallbackRunning.rawValue
            && fallbackPlans.count == 1
            && fallbackPlans[0].effect.operation == .notesCreate
            && !fallbackPlans[0].goal.contains("SCREEN_SECRET"),
        "a clear authorized goal did not fall through to a bounded Computer Use plan"
    )

    // Cancellation is a separately authorized exact effect. An unrelated
    // negation cannot stop whichever task happens to be running.
    let mismatchedCancellation = await fallbackRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .cancel,
            operation: .notesOpenApplication,
            target: .notesApplication
        ),
        context: notesContext(
            callID: "fallback-mismatch-cancel", sessionID: "fallback-session",
            turnID: "fallback-mismatch-turn", transcript: "Don't open Notes."
        )
    )
    let cancelledAfterMismatch = await unavailableFallback.cancelledSnapshot()
    try notesExpect(
        mismatchedCancellation.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.authorizationDenied.rawValue
            && cancelledAfterMismatch.isEmpty,
        "an unrelated cancellation stopped a different running Notes effect"
    )
    let exactCancellation = await fallbackRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .cancel,
            operation: .notesCreate,
            target: .newNote
        ),
        context: notesContext(
            callID: "fallback-exact-cancel", sessionID: "fallback-session",
            turnID: "fallback-exact-turn", transcript: "Actually, cancel that."
        )
    )
    let cancelledAfterExactMatch = await unavailableFallback.cancelledSnapshot()
    try notesExpect(
        exactCancellation.ok
            && exactCancellation.metadata["result_code"]?.stringValue
                == IntentExecutionResultCode.intentCancelled.rawValue
            && exactCancellation.metadata["authorization_id"]?.stringValue != nil
            && exactCancellation.metadata["effect_verified"]?.boolValue == true
            && cancelledAfterExactMatch == ["notes-fallback-1"],
        "the exact action-scoped fallback cancellation was not drained and verified"
    )

    // A completed visual creation becomes an opaque, session-scoped note
    // handle. Later contextual operations stay typed and continue through
    // Computer Use without inventing or exposing an Apple Notes identifier.
    await unavailableService.failNext(with: .automationPermissionDenied)
    let visualCreate = await fallbackRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesCreate,
            target: .newNote
        ),
        context: notesContext(
            callID: "visual-create-call", sessionID: "visual-session",
            turnID: "visual-create-turn", transcript: "Start one."
        )
    )
    guard let visualCreateTaskID = visualCreate.metadata["task_id"]?.stringValue else {
        throw VerificationFailure.failed("visual Notes creation returned no bounded task ID")
    }
    await fallbackBroker.observeDesktopTaskEvent(
        await unavailableFallback.terminalEvent(
            taskID: visualCreateTaskID,
            status: .completed
        )
    )
    let visualStateAfterCreate = await fallbackBroker.verificationState(
        sessionID: "visual-session"
    )
    try notesExpect(
        visualStateAfterCreate.hasActiveNote,
        "a verified Computer Use creation did not become contextual Notes state"
    )
    let visualTitle = await fallbackRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesSetTitle,
            target: .activeNote,
            parameters: IntentParameters(title: "Shopping List")
        ),
        context: notesContext(
            callID: "visual-title-call", sessionID: "visual-session",
            turnID: "visual-title-turn", transcript: "Call it Shopping List."
        )
    )
    guard let visualTitleTaskID = visualTitle.metadata["task_id"]?.stringValue else {
        throw VerificationFailure.failed("visual Notes title returned no bounded task ID")
    }
    await fallbackBroker.observeDesktopTaskEvent(
        await unavailableFallback.terminalEvent(
            taskID: visualTitleTaskID,
            status: .completed
        )
    )
    let visualStateAfterTitle = await fallbackBroker.verificationState(
        sessionID: "visual-session"
    )
    try notesExpect(
        visualTitle.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.fallbackRunning.rawValue
            && visualStateAfterTitle.title == "Shopping List",
        "a contextual operation could not continue from verified visual Notes state"
    )

    let permissionOnlyService = VerificationNotesService()
    await permissionOnlyService.failNext(with: .automationPermissionDenied)
    let permissionOnlyBroker = NotesCapabilityBroker(
        notesService: permissionOnlyService,
        activateNotes: { await activation.activate() }
    )
    let permissionOnlyRegistry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("permission-audit.jsonl")),
        commandApproval: { _ in false },
        notesCapabilityBroker: permissionOnlyBroker
    )
    let permissionOnlyResult = await permissionOnlyRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute, operation: .notesCreate, target: .newNote
        ),
        context: notesContext(
            callID: "permission-call", sessionID: "permission-session",
            turnID: "permission-turn", transcript: "Start a note."
        )
    )
    try notesExpect(
        permissionOnlyResult.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.permissionDenied.rawValue,
        "a real macOS permission denial was mislabeled as a route or policy block"
    )

    // Stale state and post-effect verification uncertainty stop; they never
    // trigger a second executor that could duplicate a mutation.
    let staleService = VerificationNotesService()
    let staleFallback = VerificationNotesFallback()
    let staleBroker = NotesCapabilityBroker(
        notesService: staleService,
        activateNotes: { await activation.activate() },
        visualFallback: { plan in await staleFallback.start(plan) }
    )
    let staleRegistry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("stale-audit.jsonl")),
        commandApproval: { _ in false },
        notesCapabilityBroker: staleBroker
    )
    _ = await staleRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute, operation: .notesCreate, target: .newNote
        ),
        context: notesContext(
            callID: "stale-create", sessionID: "stale-session",
            turnID: "stale-create-turn", transcript: "Start a new one."
        )
    )
    await staleService.failNext(with: .staleTarget)
    let staleResult = await staleRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute,
            operation: .notesSetTitle,
            target: .activeNote,
            parameters: IntentParameters(title: "Shopping List")
        ),
        context: notesContext(
            callID: "stale-title", sessionID: "stale-session",
            turnID: "stale-title-turn", transcript: "Call it Shopping List."
        )
    )
    let staleFallbackPlans = await staleFallback.snapshot()
    try notesExpect(
        staleResult.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.targetStale.rawValue
            && staleFallbackPlans.isEmpty,
        "stale Notes state was retried through a broader executor"
    )

    let unverifiedService = VerificationNotesService()
    await unverifiedService.makeNextReceiptUnverified()
    let unverifiedFallback = VerificationNotesFallback()
    let unverifiedBroker = NotesCapabilityBroker(
        notesService: unverifiedService,
        activateNotes: { await activation.activate() },
        visualFallback: { plan in await unverifiedFallback.start(plan) }
    )
    let unverifiedRegistry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("unverified-audit.jsonl")),
        commandApproval: { _ in false },
        notesCapabilityBroker: unverifiedBroker
    )
    let unverifiedResult = await unverifiedRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute, operation: .notesCreate, target: .newNote
        ),
        context: notesContext(
            callID: "unverified-create", sessionID: "unverified-session",
            turnID: "unverified-turn", transcript: "Start a new note."
        )
    )
    let unverifiedState = await unverifiedBroker.verificationState(
        sessionID: "unverified-session"
    )
    let unverifiedFallbackPlans = await unverifiedFallback.snapshot()
    try notesExpect(
        unverifiedResult.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.verificationFailed.rawValue
            && !unverifiedState.hasActiveNote
            && unverifiedFallbackPlans.isEmpty,
        "an unverified mutation became active state or was blindly retried"
    )

    let wrongReceiptService = VerificationNotesService()
    await wrongReceiptService.makeNextReceiptUseWrongRequestID()
    let wrongReceiptBroker = NotesCapabilityBroker(
        notesService: wrongReceiptService,
        activateNotes: { await activation.activate() }
    )
    let wrongReceiptRegistry = ToolRegistry(
        configuration: .init(auditURL: root.appendingPathComponent("wrong-receipt-audit.jsonl")),
        commandApproval: { _ in false },
        notesCapabilityBroker: wrongReceiptBroker
    )
    let wrongReceiptResult = await wrongReceiptRegistry.execute(
        name: "intent_proposal",
        arguments: intentArguments(
            commitment: .execute, operation: .notesCreate, target: .newNote
        ),
        context: notesContext(
            callID: "wrong-receipt-call", sessionID: "wrong-receipt-session",
            turnID: "wrong-receipt-turn", transcript: "Start a note."
        )
    )
    let wrongReceiptState = await wrongReceiptBroker.verificationState(
        sessionID: "wrong-receipt-session"
    )
    try notesExpect(
        wrongReceiptResult.metadata["result_code"]?.stringValue
            == IntentExecutionResultCode.verificationFailed.rawValue
            && !wrongReceiptState.hasActiveNote,
        "a receipt with the wrong request identity created trusted Notes state"
    )
}

private func intentArguments(
    commitment: IntentCommitment,
    operation: IntentOperation,
    target: IntentTargetReference,
    parameters: IntentParameters = .empty,
    extra: [String: ToolJSONValue] = [:]
) -> [String: ToolJSONValue] {
    var parameterObject: [String: ToolJSONValue] = [:]
    if let title = parameters.title { parameterObject["title"] = .string(title) }
    if let items = parameters.items {
        parameterObject["items"] = .array(items.map(ToolJSONValue.string))
    }
    var result: [String: ToolJSONValue] = [
        "commitment": .string(commitment.rawValue),
        "operation": .string(operation.rawValue),
        "target_reference": .string(target.rawValue),
        "parameters": .object(parameterObject),
    ]
    for (key, value) in extra { result[key] = value }
    return result
}

private func notesContext(
    callID: String,
    sessionID: String?,
    turnID: String?,
    transcript: String,
    owner: Bool = true,
    origin: String = "aurora_native_realtime_voice",
    finalized: Bool = true
) -> ToolInvocationContext {
    ToolInvocationContext(
        callID: callID,
        sessionID: sessionID,
        origin: origin,
        latestUserTranscript: transcript,
        ownerAudioItemID: turnID,
        participantIsOwner: owner,
        audioCorroborated: false,
        sourceTurnFinalized: finalized
    )
}

private func notesExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw VerificationFailure.failed(message) }
}
