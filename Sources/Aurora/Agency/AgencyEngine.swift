import Foundation

enum AgencyEngine {
    static let maximumProjectionCharacters = 1_400
    static let maximumRecords = 96
    static let maximumAuthoredMoves = 128
    static let maximumPlaybackReceipts = 192
    static let maximumOwnerInteractionReceipts = 256

    private static let maximumGroundingsPerRecord = 12
    private static let maximumSourceTurnsPerRecord = 8
    private static let maximumSafeCounter = 1_000_000_000

    static func defaultState(at date: Date = Date()) -> AgencyState {
        AgencyState(
            schemaVersion: AgencyState.currentSchemaVersion,
            createdAt: date,
            updatedAt: date,
            sequence: 0,
            records: [],
            authoredMoves: [],
            playbackReceipts: [],
            ownerInteractionReceipts: [],
            relationalBalance: .neutral
        )
    }

    static func createRecord(
        _ rawState: AgencyState,
        kind: AgencyRecordKind,
        contentScope: AgencyContentScope,
        content: String,
        privateRationale: String,
        groundings: [AgencyGroundingReference],
        authoringSourceID: String,
        sourceSessionID: String? = nil,
        sourceTurnIDs: [String] = [],
        expiresAt: Date,
        confidence: Double,
        salience: Double,
        projectionEligible: Bool = true,
        disclosureShareMaterial: String? = nil,
        disclosureMinimumSecurity: Double = 0.5,
        disclosureMaximumInterrogationPressure: Double = 0.65,
        disclosureRequiresOwnerReciprocity: Bool = true,
        at date: Date = Date()
    ) throws -> (state: AgencyState, recordID: String) {
        let normalizedContent = try requireText(content, field: "record content", maximum: 360)
        let normalizedRationale = try requireText(
            privateRationale,
            field: "private rationale",
            maximum: 360
        )
        let normalizedGroundings = try validateGroundings(groundings)
        try requireSourceID(authoringSourceID, field: "authoring source ID")
        if let sourceSessionID {
            try requireSourceID(sourceSessionID, field: "source session ID")
        }
        let normalizedTurnIDs = try validateSourceIDs(
            sourceTurnIDs,
            field: "source turn IDs",
            maximum: maximumSourceTurnsPerRecord
        )
        try validateContentScope(contentScope, for: kind, groundings: normalizedGroundings)
        try validateExpiry(expiresAt, for: kind, from: date)
        try validateUnit(confidence, field: "confidence", minimum: 0.05)
        try validateUnit(salience, field: "salience", minimum: 0)

        let disclosure = try makeDisclosureControl(
            kind: kind,
            shareMaterial: disclosureShareMaterial,
            minimumSecurity: disclosureMinimumSecurity,
            maximumPressure: disclosureMaximumInterrogationPressure,
            requiresOwnerReciprocity: disclosureRequiresOwnerReciprocity
        )

        var state = sanitize(rawState, now: date)
        let timestamp = monotonic(date, after: state.updatedAt)
        try validateExpiry(expiresAt, for: kind, from: timestamp)
        let id = nextID(prefix: "agency-record", state: &state)
        state.records.append(
            AgencyRecord(
                id: id,
                kind: kind,
                contentScope: contentScope,
                content: normalizedContent,
                privateRationale: normalizedRationale,
                groundings: normalizedGroundings,
                authoringSourceID: authoringSourceID,
                sourceSessionID: sourceSessionID,
                sourceTurnIDs: normalizedTurnIDs,
                createdAt: timestamp,
                updatedAt: timestamp,
                expiresAt: expiresAt,
                revision: 1,
                confidence: confidence,
                salience: salience,
                status: .active,
                projectionEligible: projectionEligible,
                supersedesRecordID: nil,
                supersededByRecordID: nil,
                lastRevisionSourceID: authoringSourceID,
                disclosure: disclosure
            )
        )
        state.updatedAt = timestamp
        state = sanitize(state, now: timestamp)
        return (state, id)
    }

    /// Revision creates a new record and retains the old one as provenance.
    /// This prevents a changing position from silently rewriting its history.
    static func reviseRecord(
        _ rawState: AgencyState,
        recordID: String,
        content: String,
        privateRationale: String,
        groundings: [AgencyGroundingReference],
        revisionSourceID: String,
        sourceSessionID: String? = nil,
        sourceTurnIDs: [String] = [],
        expiresAt: Date,
        confidence: Double,
        salience: Double,
        disclosureShareMaterial: String? = nil,
        at date: Date = Date()
    ) throws -> (state: AgencyState, recordID: String) {
        var state = sanitize(rawState, now: date)
        guard let oldIndex = state.records.firstIndex(where: {
            $0.id == recordID && $0.status == .active
        }) else {
            throw AgencyInputError.missingRecord(recordID)
        }
        let old = state.records[oldIndex]
        let disclosure = old.disclosure
        if disclosure?.status == .pendingPlayback {
            throw AgencyInputError.invalidTransition("a pending disclosure cannot be revised")
        }

        let created = try createRecord(
            state,
            kind: old.kind,
            contentScope: old.contentScope,
            content: content,
            privateRationale: privateRationale,
            groundings: groundings,
            authoringSourceID: revisionSourceID,
            sourceSessionID: sourceSessionID,
            sourceTurnIDs: sourceTurnIDs,
            expiresAt: expiresAt,
            confidence: confidence,
            salience: salience,
            projectionEligible: old.projectionEligible,
            disclosureShareMaterial: disclosureShareMaterial ?? disclosure?.shareMaterial,
            disclosureMinimumSecurity: disclosure?.minimumRelationshipSecurity ?? 0.5,
            disclosureMaximumInterrogationPressure: disclosure?.maximumInterrogationPressure ?? 0.65,
            disclosureRequiresOwnerReciprocity: disclosure?.requiresOwnerReciprocity ?? true,
            at: date
        )
        state = created.state
        guard let currentOldIndex = state.records.firstIndex(where: { $0.id == recordID }),
              let newIndex = state.records.firstIndex(where: { $0.id == created.recordID }) else {
            throw AgencyInputError.invalidTransition("revision lost its provenance chain")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.records[currentOldIndex].status = .superseded
        state.records[currentOldIndex].updatedAt = timestamp
        state.records[currentOldIndex].supersededByRecordID = created.recordID
        state.records[currentOldIndex].revision = increment(
            state.records[currentOldIndex].revision
        )
        state.records[currentOldIndex].lastRevisionSourceID = revisionSourceID
        state.records[newIndex].supersedesRecordID = recordID
        state.records[newIndex].revision = min(maximumSafeCounter, old.revision + 1)
        state.records[newIndex].lastRevisionSourceID = revisionSourceID
        state.updatedAt = timestamp
        return (sanitize(state, now: timestamp), created.recordID)
    }

    static func retireRecord(
        _ rawState: AgencyState,
        recordID: String,
        revisionSourceID: String,
        fulfilled: Bool = false,
        at date: Date = Date()
    ) throws -> AgencyState {
        try requireSourceID(revisionSourceID, field: "revision source ID")
        var state = sanitize(rawState, now: date)
        guard let index = state.records.firstIndex(where: {
            $0.id == recordID && $0.status == .active
        }) else {
            throw AgencyInputError.missingRecord(recordID)
        }
        guard state.records[index].disclosure?.status != .pendingPlayback else {
            throw AgencyInputError.invalidTransition("a pending disclosure cannot be retired")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.records[index].status = fulfilled ? .fulfilled : .retired
        state.records[index].projectionEligible = false
        state.records[index].updatedAt = timestamp
        state.records[index].revision = min(maximumSafeCounter, state.records[index].revision + 1)
        state.records[index].lastRevisionSourceID = revisionSourceID
        if state.records[index].disclosure != nil {
            state.records[index].disclosure?.status = .retired
        }
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    /// Interaction classification is supplied by the conversational intent
    /// layer. Deterministic code updates numerical balance only; it does not
    /// inspect words, verbs, app names, or magic phrases.
    static func recordOwnerInteraction(
        _ rawState: AgencyState,
        eventID: String,
        kind: AgencyOwnerInteractionKind,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> AgencyState {
        try requireSourceID(eventID, field: "interaction event ID")
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = sanitize(rawState, now: date)
        if state.ownerInteractionReceipts.contains(where: {
            $0.id == eventID
                || ($0.sourceSessionID == sourceSessionID && $0.sourceTurnID == sourceTurnID)
        }) {
            return state
        }

        let timestamp = monotonic(date, after: state.updatedAt)
        var balance = state.relationalBalance
        switch kind {
        case .question:
            balance.ownerQuestionCount = increment(balance.ownerQuestionCount)
            balance.consecutiveOwnerQuestions = increment(balance.consecutiveOwnerQuestions)
            let repeatedPressure = Double(max(0, balance.consecutiveOwnerQuestions - 2)) * 0.08
            balance.interrogationPressure = clamp01(
                balance.interrogationPressure * 0.82 + 0.13 + repeatedPressure
            )
        case .disclosure:
            balance.ownerDisclosureCount = increment(balance.ownerDisclosureCount)
            balance.consecutiveOwnerQuestions = 0
            balance.interrogationPressure = clamp01(balance.interrogationPressure * 0.55)
            balance.lastOwnerDisclosureAt = timestamp
        case .boundary:
            balance.consecutiveOwnerQuestions = 0
            balance.interrogationPressure = clamp01(balance.interrogationPressure * 0.65)
        case .challenge:
            balance.consecutiveOwnerQuestions = 0
            balance.interrogationPressure = clamp01(balance.interrogationPressure * 0.90 + 0.04)
        case .warmth:
            balance.consecutiveOwnerQuestions = 0
            balance.interrogationPressure = clamp01(balance.interrogationPressure * 0.70)
        case .other:
            balance.consecutiveOwnerQuestions = 0
            balance.interrogationPressure = clamp01(balance.interrogationPressure * 0.85)
        }
        recomputeReciprocity(&balance)
        state.relationalBalance = balance
        state.ownerInteractionReceipts.append(
            AgencyOwnerInteractionReceipt(
                id: eventID,
                kind: kind,
                sourceSessionID: sourceSessionID,
                sourceTurnID: sourceTurnID,
                at: timestamp
            )
        )
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func select(
        from rawState: AgencyState,
        signals: AgencySelectionSignals,
        at date: Date = Date()
    ) throws -> AgencySelection {
        try validate(signals: signals)
        let state = sanitize(rawState, now: date)
        let candidates = state.records.filter {
            $0.status == .active
                && $0.projectionEligible
                && $0.expiresAt > date
                && $0.confidence >= 0.20
                && $0.groundings.contains(where: { $0.kind.canGroundPresentTruth })
                && ($0.kind != .selectiveDisclosure
                    || disclosureIsEligible($0, state: state, signals: signals))
        }

        var selected: [AgencyRecord] = []
        for kind in AgencyRecordKind.allCases {
            let best = candidates
                .filter { $0.kind == kind }
                .sorted {
                    let left = selectionScore($0, signals: signals)
                    let right = selectionScore($1, signals: signals)
                    if left != right { return left > right }
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id < $1.id
                }
                .first
            if let best { selected.append(best) }
        }
        selected.sort {
            let left = selectionScore($0, signals: signals)
            let right = selectionScore($1, signals: signals)
            if left != right { return left > right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }

        let disclosureID = selected.first(where: { $0.kind == .selectiveDisclosure })?.id
        let moves = suggestedMoves(
            selected: selected,
            signals: signals,
            balance: state.relationalBalance,
            disclosureID: disclosureID
        )
        return AgencySelection(
            records: selected,
            suggestedMoves: moves,
            eligibleDisclosureRecordID: disclosureID,
            interrogationPressure: state.relationalBalance.interrogationPressure,
            disclosureReciprocity: state.relationalBalance.disclosureReciprocity
        )
    }

    static func projection(
        for rawState: AgencyState,
        signals: AgencySelectionSignals,
        at date: Date = Date()
    ) throws -> AgencyProjection {
        let selection = try select(from: rawState, signals: signals, at: date)
        var lines = [
            "AURORA AGENCY — grounded positions, not canned dialogue or action authority.",
            "Choose a move; answering is optional. Never invent an event or turn an interpretation into a fact.",
            "RELATIONAL BALANCE interrogation=\(fixedDecimal(selection.interrogationPressure)) reciprocity=\(signedFixedDecimal(selection.disclosureReciprocity))",
            "AVAILABLE MOVES: " + selection.suggestedMoves.map(\.rawValue).joined(separator: ", "),
        ]
        var includedIDs: [String] = []

        for record in selection.records {
            let label: String
            switch record.kind {
            case .activeStance: label = "STANCE"
            case .selfThread: label = "SELF THREAD"
            case .relationalThread: label = "RELATIONAL THREAD"
            case .presentWant: label = "PRESENT WANT"
            case .selectiveDisclosure: label = "HELD DISCLOSURE — reveal or withhold"
            case .groundedCallback: label = "CALLBACK"
            }
            let material = record.kind == .selectiveDisclosure
                ? (record.disclosure?.shareMaterial ?? record.content)
                : record.content
            let line = "\(label) [id=\(record.id) rev=\(record.revision) confidence=\(fixedDecimal(record.confidence)) scope=\(record.contentScope.rawValue)]: \(material)"
            let candidate = (lines + [line]).joined(separator: "\n")
            if candidate.count <= maximumProjectionCharacters {
                lines.append(line)
                includedIDs.append(record.id)
            }
        }

        var text = lines.joined(separator: "\n")
        if text.count > maximumProjectionCharacters {
            // Mandatory lines are deliberately short; this is a defensive
            // fail-closed fallback and never truncates record prose.
            lines = Array(lines.prefix(3))
            text = lines.joined(separator: "\n")
            includedIDs = []
        }
        return AgencyProjection(
            text: text,
            recordIDs: includedIDs,
            suggestedMoves: selection.suggestedMoves,
            eligibleDisclosureRecordID: includedIDs.contains(selection.eligibleDisclosureRecordID ?? "")
                ? selection.eligibleDisclosureRecordID
                : nil
        )
    }

    /// Resolves a model-authored social move from typed live state. Natural
    /// language interpretation remains in Realtime; this only applies bounded
    /// agency and relationship-state constraints to an already-understood turn.
    static func resolveConversationMove(
        proposed: AgencyAuthoredMoveType,
        perceivedTurn: String,
        signals: AgencySelectionSignals,
        projection: AgencyProjection,
        interrogationPressure: Double
    ) -> AgencyAuthoredMoveType {
        if perceivedTurn == "boundary" || perceivedTurn == "closing" {
            return proposed == .reveal ? .withhold : proposed
        }
        if signals.repairNeed >= 0.55, projection.suggestedMoves.contains(.repair) {
            return .repair
        }
        if proposed == .repair,
           signals.repairNeed < 0.30,
           perceivedTurn != "correction" {
            return .answer
        }
        if interrogationPressure >= 0.62,
           proposed == .answer || proposed == .reveal || proposed == .reciprocate {
            return projection.suggestedMoves.contains(.withhold) ? .withhold : .challenge
        }
        return proposed
    }

    /// A move is bound to the exact response and Aurora source turn before
    /// playback. A reveal additionally binds its held disclosure record.
    static func prepareAuthoredMove(
        _ rawState: AgencyState,
        type: AgencyAuthoredMoveType,
        responseID: String,
        sourceSessionID: String,
        sourceTurnID: String,
        recordIDs: [String],
        disclosureRecordID: String? = nil,
        privateRationale: String,
        confidence: Double,
        signals: AgencySelectionSignals,
        at date: Date = Date()
    ) throws -> (state: AgencyState, moveID: String) {
        try requireSourceID(responseID, field: "response ID")
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        let rationale = try requireText(privateRationale, field: "move rationale", maximum: 300)
        try validateUnit(confidence, field: "move confidence", minimum: 0.05)
        try validate(signals: signals)
        let uniqueRecordIDs = try validateSourceIDs(recordIDs, field: "move record IDs", maximum: 6)
        guard !uniqueRecordIDs.isEmpty else {
            throw AgencyInputError.invalidInput("move record IDs")
        }
        var state = sanitize(rawState, now: date)
        let timestamp = monotonic(date, after: state.updatedAt)

        if let existing = state.authoredMoves.first(where: { $0.responseID == responseID }) {
            guard existing.type == type,
                  existing.sourceSessionID == sourceSessionID,
                  existing.sourceTurnID == sourceTurnID,
                  existing.recordIDs == uniqueRecordIDs,
                  existing.disclosureRecordID == disclosureRecordID else {
                throw AgencyInputError.invalidTransition("a response already has another authored move")
            }
            return (state, existing.id)
        }
        let activeRecords = uniqueRecordIDs.compactMap { id in
            state.records.first(where: {
                $0.id == id && $0.status == .active && $0.expiresAt > timestamp
            })
        }
        guard activeRecords.count == uniqueRecordIDs.count else {
            throw AgencyInputError.invalidInput("active move record IDs")
        }

        if type == .reveal {
            guard let disclosureRecordID,
                  uniqueRecordIDs.contains(disclosureRecordID),
                  let recordIndex = state.records.firstIndex(where: { $0.id == disclosureRecordID }),
                  disclosureIsEligible(state.records[recordIndex], state: state, signals: signals) else {
                throw AgencyInputError.invalidTransition("the selected disclosure is not eligible")
            }
        } else if disclosureRecordID != nil && type != .withhold {
            throw AgencyInputError.invalidInput("disclosure binding for a non-disclosure move")
        }

        let moveID = nextID(prefix: "agency-move", state: &state)
        state.authoredMoves.append(
            AgencyAuthoredMove(
                id: moveID,
                type: type,
                responseID: responseID,
                sourceSessionID: sourceSessionID,
                sourceTurnID: sourceTurnID,
                recordIDs: uniqueRecordIDs,
                disclosureRecordID: disclosureRecordID,
                privateRationale: rationale,
                preparedAt: timestamp,
                updatedAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(10 * 60),
                revision: 1,
                confidence: confidence,
                status: .pendingPlayback,
                playbackEventID: nil
            )
        )
        if type == .reveal, let disclosureRecordID,
           let index = state.records.firstIndex(where: { $0.id == disclosureRecordID }) {
            state.records[index].disclosure?.status = .pendingPlayback
            state.records[index].disclosure?.pendingMoveID = moveID
            state.records[index].disclosure?.pendingResponseID = responseID
            state.records[index].updatedAt = timestamp
            state.records[index].revision = increment(state.records[index].revision)
        }
        state.updatedAt = timestamp
        return (sanitize(state, now: timestamp), moveID)
    }

    /// Only completed audio counts as delivery of an authored move.
    /// `fullyPlayed` is delivery truth for non-verbatim social moves, not a
    /// deterministic semantic classifier. Consequential disclosure and
    /// curiosity effects additionally require their own content evidence.
    static func reconcilePlayback(
        _ rawState: AgencyState,
        responseID: String,
        fullyPlayed: Bool,
        generatedText: String? = nil,
        curiosityEffectEvidence: AgencyCuriosityEffectEvidence = .unavailable,
        playbackEventID: String,
        at date: Date = Date()
    ) throws -> AgencyState {
        try requireSourceID(responseID, field: "response ID")
        try requireSourceID(playbackEventID, field: "playback event ID")
        var state = sanitize(rawState, now: date)
        if state.playbackReceipts.contains(where: { $0.playbackEventID == playbackEventID }) {
            return state
        }
        guard let moveIndex = state.authoredMoves.firstIndex(where: {
            $0.responseID == responseID && $0.status == .pendingPlayback
        }) else {
            throw AgencyInputError.invalidTransition("no pending authored move matches the response")
        }
        let selectedMove = state.authoredMoves[moveIndex]
        let deliveryFullyPlayed = fullyPlayed
        let effectOutcome: AgencyPlaybackEffectOutcome
        switch selectedMove.type {
        case .reveal:
            guard deliveryFullyPlayed else {
                effectOutcome = .notDelivered
                break
            }
            guard let disclosureID = selectedMove.disclosureRecordID,
                  let disclosure = state.records.first(where: { $0.id == disclosureID })?
                    .disclosure else {
                effectOutcome = .unverifiable
                break
            }
            let expected = normalizedTranscript(disclosure.shareMaterial)
            let verified = !expected.isEmpty
                && generatedText.map { normalizedTranscript($0).contains(expected) } == true
            effectOutcome = verified ? .verified : .omitted
        case .pursueCuriosity:
            guard deliveryFullyPlayed else {
                effectOutcome = .notDelivered
                break
            }
            switch curiosityEffectEvidence {
            case .matched: effectOutcome = .verified
            case .omitted: effectOutcome = .omitted
            case .unavailable: effectOutcome = .unverifiable
            }
        default:
            effectOutcome = deliveryFullyPlayed ? .unverifiable : .notDelivered
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        let moveID = state.authoredMoves[moveIndex].id
        let outcome: AgencyPlaybackOutcome = deliveryFullyPlayed ? .fullyPlayed : .interrupted
        state.authoredMoves[moveIndex].status = deliveryFullyPlayed ? .fullyPlayed : .interrupted
        state.authoredMoves[moveIndex].updatedAt = timestamp
        state.authoredMoves[moveIndex].revision = increment(state.authoredMoves[moveIndex].revision)
        state.authoredMoves[moveIndex].playbackEventID = playbackEventID

        if let disclosureID = state.authoredMoves[moveIndex].disclosureRecordID,
           let recordIndex = state.records.firstIndex(where: { $0.id == disclosureID }),
           state.records[recordIndex].disclosure?.pendingMoveID == moveID {
            if effectOutcome == .verified
                && state.authoredMoves[moveIndex].type == .reveal {
                state.records[recordIndex].disclosure?.status = .disclosed
                state.records[recordIndex].disclosure?.disclosedAt = timestamp
                state.records[recordIndex].disclosure?.disclosedResponseID = responseID
                state.relationalBalance.auroraDisclosureCount = increment(
                    state.relationalBalance.auroraDisclosureCount
                )
                state.relationalBalance.lastAuroraDisclosureAt = timestamp
            } else {
                state.records[recordIndex].disclosure?.status = .held
            }
            state.records[recordIndex].disclosure?.pendingMoveID = nil
            state.records[recordIndex].disclosure?.pendingResponseID = nil
            state.records[recordIndex].updatedAt = timestamp
            state.records[recordIndex].revision = increment(state.records[recordIndex].revision)
        }
        if effectOutcome == .verified
            && state.authoredMoves[moveIndex].type == .pursueCuriosity {
            state.relationalBalance.auroraQuestionCount = increment(
                state.relationalBalance.auroraQuestionCount
            )
        }
        recomputeReciprocity(&state.relationalBalance)
        let receiptID = nextID(prefix: "agency-playback", state: &state)
        state.playbackReceipts.append(
            AgencyPlaybackReceipt(
                id: receiptID,
                moveID: moveID,
                responseID: responseID,
                playbackEventID: playbackEventID,
                outcome: outcome,
                effectOutcome: effectOutcome,
                at: timestamp
            )
        )
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    private static func normalizedTranscript(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// App restart means no pre-restart response can still finish playing.
    /// Durable positions remain; only pending presentation is rolled back.
    static func rollbackPendingMovesAfterRestart(
        _ rawState: AgencyState,
        sourceID: String,
        at date: Date = Date()
    ) throws -> AgencyState {
        try requireSourceID(sourceID, field: "restart source ID")
        var state = sanitize(rawState, now: date)
        let pendingMoveIDs = Set(
            state.authoredMoves.filter { $0.status == .pendingPlayback }.map(\.id)
        )
        guard !pendingMoveIDs.isEmpty else { return state }
        let timestamp = monotonic(date, after: state.updatedAt)
        for index in state.authoredMoves.indices
        where pendingMoveIDs.contains(state.authoredMoves[index].id) {
            state.authoredMoves[index].status = .cancelled
            state.authoredMoves[index].updatedAt = timestamp
            state.authoredMoves[index].revision = increment(state.authoredMoves[index].revision)
        }
        for index in state.records.indices {
            guard let pendingMoveID = state.records[index].disclosure?.pendingMoveID,
                  pendingMoveIDs.contains(pendingMoveID) else { continue }
            state.records[index].disclosure?.status = .held
            state.records[index].disclosure?.pendingMoveID = nil
            state.records[index].disclosure?.pendingResponseID = nil
            state.records[index].updatedAt = timestamp
            state.records[index].revision = increment(state.records[index].revision)
            state.records[index].lastRevisionSourceID = sourceID
        }
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func sanitize(_ rawState: AgencyState, now: Date) -> AgencyState {
        var state = rawState
        var lifecycleChanged = false
        state.sequence = min(maximumSafeCounter, max(0, state.sequence))
        state.updatedAt = max(state.createdAt, state.updatedAt)
        state.relationalBalance.ownerDisclosureCount = boundedCounter(
            state.relationalBalance.ownerDisclosureCount
        )
        state.relationalBalance.auroraDisclosureCount = boundedCounter(
            state.relationalBalance.auroraDisclosureCount
        )
        state.relationalBalance.ownerQuestionCount = boundedCounter(
            state.relationalBalance.ownerQuestionCount
        )
        state.relationalBalance.auroraQuestionCount = boundedCounter(
            state.relationalBalance.auroraQuestionCount
        )
        state.relationalBalance.consecutiveOwnerQuestions = boundedCounter(
            state.relationalBalance.consecutiveOwnerQuestions
        )
        state.relationalBalance.interrogationPressure = clamp01(
            state.relationalBalance.interrogationPressure
        )
        recomputeReciprocity(&state.relationalBalance)

        var seenRecordIDs = Set<String>()
        state.records = state.records.filter { record in
            guard !seenRecordIDs.contains(record.id),
                  recordIsStructurallyValid(record) else {
                return false
            }
            seenRecordIDs.insert(record.id)
            return true
        }
        for index in state.records.indices {
            // conversation-position records were historically projected for
            // eight hours even though they are fallback scaffolding for one
            // response. Migrate them by provenance—not by inspecting their
            // natural-language content—so an old task failure cannot hijack a
            // later greeting or unrelated turn.
            if state.records[index].authoringSourceID.hasPrefix("conversation-position-"),
               state.records[index].projectionEligible {
                state.records[index].projectionEligible = false
                state.records[index].updatedAt = max(state.records[index].updatedAt, now)
                state.records[index].revision = increment(state.records[index].revision)
                state.records[index].lastRevisionSourceID = "agency-one-turn-position-migration"
                lifecycleChanged = true
            }
            state.records[index].confidence = min(1, max(0.05, state.records[index].confidence))
            state.records[index].salience = clamp01(state.records[index].salience)
            state.records[index].revision = min(maximumSafeCounter, state.records[index].revision)
            state.records[index].groundings = uniqueGroundings(state.records[index].groundings)
            state.records[index].sourceTurnIDs = uniqueStrings(
                state.records[index].sourceTurnIDs,
                maximum: maximumSourceTurnsPerRecord
            )
            if state.records[index].kind != .selectiveDisclosure {
                state.records[index].disclosure = nil
            }
            if state.records[index].status == .active,
               state.records[index].expiresAt <= now,
               state.records[index].disclosure?.status != .pendingPlayback {
                state.records[index].status = .expired
                state.records[index].projectionEligible = false
                state.records[index].updatedAt = max(state.records[index].updatedAt, now)
                state.records[index].revision = increment(state.records[index].revision)
                state.records[index].lastRevisionSourceID = "agency-expiry"
                lifecycleChanged = true
            }
        }

        var seenMoveIDs = Set<String>()
        var seenResponseIDs = Set<String>()
        state.authoredMoves = state.authoredMoves.filter { move in
            guard !seenMoveIDs.contains(move.id), !seenResponseIDs.contains(move.responseID),
                  isValidSourceID(move.id), isValidSourceID(move.responseID),
                  isValidSourceID(move.sourceSessionID), isValidSourceID(move.sourceTurnID),
                  move.revision >= 1, move.confidence.isFinite else { return false }
            seenMoveIDs.insert(move.id)
            seenResponseIDs.insert(move.responseID)
            return true
        }
        for index in state.authoredMoves.indices {
            if state.authoredMoves[index].status == .pendingPlayback,
               state.authoredMoves[index].expiresAt <= now {
                state.authoredMoves[index].status = .cancelled
                state.authoredMoves[index].updatedAt = max(
                    state.authoredMoves[index].updatedAt,
                    now
                )
                state.authoredMoves[index].revision = increment(
                    state.authoredMoves[index].revision
                )
                lifecycleChanged = true
            }
            state.authoredMoves[index].confidence = min(
                1,
                max(0.05, state.authoredMoves[index].confidence)
            )
            state.authoredMoves[index].revision = min(
                maximumSafeCounter,
                state.authoredMoves[index].revision
            )
            state.authoredMoves[index].recordIDs = uniqueStrings(
                state.authoredMoves[index].recordIDs,
                maximum: 6
            )
        }

        let pendingMoveIDs = Set(
            state.authoredMoves.filter { $0.status == .pendingPlayback }.map(\.id)
        )
        for index in state.records.indices where state.records[index].disclosure?.status == .pendingPlayback {
            if let pending = state.records[index].disclosure?.pendingMoveID,
               pendingMoveIDs.contains(pending) {
                continue
            }
            state.records[index].disclosure?.status = .held
            state.records[index].disclosure?.pendingMoveID = nil
            state.records[index].disclosure?.pendingResponseID = nil
            state.records[index].updatedAt = max(state.records[index].updatedAt, now)
            state.records[index].revision = increment(state.records[index].revision)
            if state.records[index].status == .active,
               state.records[index].expiresAt <= now {
                state.records[index].status = .expired
                state.records[index].projectionEligible = false
                state.records[index].lastRevisionSourceID = "agency-expiry"
            } else {
                state.records[index].lastRevisionSourceID = "agency-presentation-recovery"
            }
            lifecycleChanged = true
        }

        if lifecycleChanged { state.updatedAt = max(state.updatedAt, now) }

        state.records = boundedRecords(state.records)
        state.authoredMoves = boundedMoves(state.authoredMoves)
        state.playbackReceipts = uniqueSuffix(
            state.playbackReceipts,
            id: { $0.playbackEventID },
            maximum: maximumPlaybackReceipts
        )
        state.ownerInteractionReceipts = uniqueSuffix(
            state.ownerInteractionReceipts,
            id: { $0.id },
            maximum: maximumOwnerInteractionReceipts
        )
        return state
    }

    /// Decode success alone is not enough for a personal-state file. This
    /// semantic check lets persistence fail closed instead of quietly
    /// projecting a hand-edited legacy cue or an unverified external claim.
    static func persistedStateIsStructurallyValid(_ state: AgencyState) -> Bool {
        guard state.schemaVersion == AgencyState.currentSchemaVersion,
              state.createdAt <= state.updatedAt,
              state.sequence >= 0,
              state.records.count <= maximumRecords,
              state.authoredMoves.count <= maximumAuthoredMoves,
              state.playbackReceipts.count <= maximumPlaybackReceipts,
              state.ownerInteractionReceipts.count <= maximumOwnerInteractionReceipts,
              countersAndBalanceAreValid(state.relationalBalance) else { return false }

        var recordIDs = Set<String>()
        guard state.records.allSatisfy({ record in
            recordIDs.insert(record.id).inserted && recordIsStructurallyValid(record)
        }) else { return false }

        var moveIDs = Set<String>()
        var responseIDs = Set<String>()
        guard state.authoredMoves.allSatisfy({ move in
            moveIDs.insert(move.id).inserted
                && responseIDs.insert(move.responseID).inserted
                && moveIsStructurallyValid(move)
        }) else { return false }

        var playbackIDs = Set<String>()
        guard state.playbackReceipts.allSatisfy({ receipt in
            playbackIDs.insert(receipt.playbackEventID).inserted
                && isValidSourceID(receipt.id)
                && isValidSourceID(receipt.moveID)
                && isValidSourceID(receipt.responseID)
                && isValidSourceID(receipt.playbackEventID)
        }) else { return false }

        var ownerEventIDs = Set<String>()
        guard state.ownerInteractionReceipts.allSatisfy({ receipt in
            ownerEventIDs.insert(receipt.id).inserted
                && isValidSourceID(receipt.sourceSessionID)
                && isValidSourceID(receipt.sourceTurnID)
        }) else { return false }

        let pendingMoveIDs = Set(
            state.authoredMoves.filter { $0.status == .pendingPlayback }.map(\.id)
        )
        return state.records.allSatisfy { record in
            guard record.disclosure?.status == .pendingPlayback else { return true }
            guard let moveID = record.disclosure?.pendingMoveID,
                  let responseID = record.disclosure?.pendingResponseID else { return false }
            return pendingMoveIDs.contains(moveID)
                && state.authoredMoves.contains {
                    $0.id == moveID
                        && $0.responseID == responseID
                        && $0.disclosureRecordID == record.id
                }
        }
    }

    private static func validateContentScope(
        _ scope: AgencyContentScope,
        for kind: AgencyRecordKind,
        groundings: [AgencyGroundingReference]
    ) throws {
        let allowed: Set<AgencyContentScope>
        switch kind {
        case .activeStance, .selfThread, .presentWant, .selectiveDisclosure:
            allowed = [.internalPosition]
        case .relationalThread:
            allowed = [.relationalInterpretation]
        case .groundedCallback:
            allowed = [.conversationCallback, .verifiedExternalOutcome]
        }
        guard allowed.contains(scope) else {
            throw AgencyInputError.invalidInput("content scope for \(kind.rawValue)")
        }
        guard groundings.contains(where: { $0.kind.canGroundPresentTruth }) else {
            throw AgencyInputError.invalidInput("legacy-only grounding")
        }
        if scope == .verifiedExternalOutcome,
           !groundings.contains(where: { $0.kind == .verifiedToolOutcome }) {
            throw AgencyInputError.invalidInput("unverified external outcome")
        }
        if scope == .conversationCallback {
            let callbackKinds: Set<AgencyGroundingKind> = [
                .ownerTurn, .guestTurn, .auroraTurn, .ownerUnderstanding,
                .autobiographicalMemory,
            ]
            guard groundings.contains(where: { callbackKinds.contains($0.kind) }) else {
                throw AgencyInputError.invalidInput("ungrounded conversation callback")
            }
        }
    }

    private static func recordIsStructurallyValid(_ record: AgencyRecord) -> Bool {
        guard isValidSourceID(record.id),
              isValidSourceID(record.authoringSourceID),
              isValidSourceID(record.lastRevisionSourceID),
              record.sourceSessionID.map(isValidSourceID) ?? true,
              record.sourceTurnIDs.count <= maximumSourceTurnsPerRecord,
              record.sourceTurnIDs.allSatisfy(isValidSourceID),
              record.revision >= 1,
              record.revision <= maximumSafeCounter,
              record.confidence.isFinite,
              (0.05...1).contains(record.confidence),
              record.salience.isFinite,
              (0...1).contains(record.salience),
              record.createdAt <= record.updatedAt,
              record.expiresAt > record.createdAt,
              isSafeStoredText(record.content, maximum: 360),
              isSafeStoredText(record.privateRationale, maximum: 360),
              !record.groundings.isEmpty,
              record.groundings.count <= maximumGroundingsPerRecord,
              Set(record.groundings.map(\.id)).count == record.groundings.count,
              record.groundings.allSatisfy({ grounding in
                  isValidSourceID(grounding.id)
                      && (grounding.sourceSessionID.map(isValidSourceID) ?? true)
                      && (grounding.sourceTurnID.map(isValidSourceID) ?? true)
                      && grounding.observedAt <= record.updatedAt.addingTimeInterval(300)
              }),
              contentScopeIsValid(
                  record.contentScope,
                  for: record.kind,
                  groundings: record.groundings
              ) else { return false }

        if record.kind == .selectiveDisclosure {
            guard let disclosure = record.disclosure,
                  isSafeStoredText(disclosure.shareMaterial, maximum: 220),
                  disclosure.minimumRelationshipSecurity.isFinite,
                  (0...1).contains(disclosure.minimumRelationshipSecurity),
                  disclosure.maximumInterrogationPressure.isFinite,
                  (0...1).contains(disclosure.maximumInterrogationPressure) else { return false }
            switch disclosure.status {
            case .held:
                return disclosure.pendingMoveID == nil && disclosure.pendingResponseID == nil
            case .pendingPlayback:
                return disclosure.pendingMoveID.map(isValidSourceID) ?? false
                    && (disclosure.pendingResponseID.map(isValidSourceID) ?? false)
            case .disclosed:
                return disclosure.pendingMoveID == nil
                    && disclosure.pendingResponseID == nil
                    && disclosure.disclosedAt != nil
                    && (disclosure.disclosedResponseID.map(isValidSourceID) ?? false)
            case .retired:
                return disclosure.pendingMoveID == nil && disclosure.pendingResponseID == nil
            }
        }
        return record.disclosure == nil
    }

    private static func moveIsStructurallyValid(_ move: AgencyAuthoredMove) -> Bool {
        isValidSourceID(move.id)
            && isValidSourceID(move.responseID)
            && isValidSourceID(move.sourceSessionID)
            && isValidSourceID(move.sourceTurnID)
            && !move.recordIDs.isEmpty
            && move.recordIDs.count <= 6
            && Set(move.recordIDs).count == move.recordIDs.count
            && move.recordIDs.allSatisfy(isValidSourceID)
            && (move.disclosureRecordID.map(isValidSourceID) ?? true)
            && isSafeStoredText(move.privateRationale, maximum: 300)
            && move.preparedAt <= move.updatedAt
            && move.expiresAt > move.preparedAt
            && move.revision >= 1
            && move.revision <= maximumSafeCounter
            && move.confidence.isFinite
            && (0.05...1).contains(move.confidence)
            && (move.playbackEventID.map(isValidSourceID) ?? true)
    }

    private static func contentScopeIsValid(
        _ scope: AgencyContentScope,
        for kind: AgencyRecordKind,
        groundings: [AgencyGroundingReference]
    ) -> Bool {
        guard groundings.contains(where: { $0.kind.canGroundPresentTruth }) else { return false }
        switch (kind, scope) {
        case (.activeStance, .internalPosition),
             (.selfThread, .internalPosition),
             (.presentWant, .internalPosition),
             (.selectiveDisclosure, .internalPosition),
             (.relationalThread, .relationalInterpretation):
            return true
        case (.groundedCallback, .conversationCallback):
            let kinds: Set<AgencyGroundingKind> = [
                .ownerTurn, .guestTurn, .auroraTurn, .ownerUnderstanding,
                .autobiographicalMemory,
            ]
            return groundings.contains { kinds.contains($0.kind) }
        case (.groundedCallback, .verifiedExternalOutcome):
            return groundings.contains { $0.kind == .verifiedToolOutcome }
        default:
            return false
        }
    }

    private static func countersAndBalanceAreValid(_ balance: AgencyRelationalBalance) -> Bool {
        let counters = [
            balance.ownerDisclosureCount, balance.auroraDisclosureCount,
            balance.ownerQuestionCount, balance.auroraQuestionCount,
            balance.consecutiveOwnerQuestions,
        ]
        return counters.allSatisfy { (0...maximumSafeCounter).contains($0) }
            && balance.interrogationPressure.isFinite
            && (0...1).contains(balance.interrogationPressure)
            && balance.disclosureReciprocity.isFinite
            && (-1...1).contains(balance.disclosureReciprocity)
    }

    private static func isSafeStoredText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximum
            && value.rangeOfCharacter(from: .newlines) == nil
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func validateExpiry(
        _ expiry: Date,
        for kind: AgencyRecordKind,
        from date: Date
    ) throws {
        let maximumLifetime: TimeInterval
        switch kind {
        case .activeStance: maximumLifetime = 72 * 3_600
        case .selfThread: maximumLifetime = 45 * 86_400
        case .relationalThread: maximumLifetime = 30 * 86_400
        case .presentWant: maximumLifetime = 48 * 3_600
        case .selectiveDisclosure: maximumLifetime = 30 * 86_400
        case .groundedCallback: maximumLifetime = 21 * 86_400
        }
        guard expiry > date, expiry.timeIntervalSince(date) <= maximumLifetime else {
            throw AgencyInputError.invalidInput("record expiry")
        }
    }

    private static func makeDisclosureControl(
        kind: AgencyRecordKind,
        shareMaterial: String?,
        minimumSecurity: Double,
        maximumPressure: Double,
        requiresOwnerReciprocity: Bool
    ) throws -> AgencyDisclosureControl? {
        guard kind == .selectiveDisclosure else {
            guard shareMaterial == nil else {
                throw AgencyInputError.invalidInput("disclosure material on a non-disclosure record")
            }
            return nil
        }
        guard let shareMaterial else {
            throw AgencyInputError.invalidInput("selective disclosure material")
        }
        let normalized = try requireText(
            shareMaterial,
            field: "selective disclosure material",
            maximum: 220
        )
        try validateUnit(minimumSecurity, field: "minimum relationship security", minimum: 0)
        try validateUnit(maximumPressure, field: "maximum interrogation pressure", minimum: 0)
        return AgencyDisclosureControl(
            status: .held,
            shareMaterial: normalized,
            minimumRelationshipSecurity: minimumSecurity,
            maximumInterrogationPressure: maximumPressure,
            requiresOwnerReciprocity: requiresOwnerReciprocity,
            pendingMoveID: nil,
            pendingResponseID: nil,
            disclosedAt: nil,
            disclosedResponseID: nil
        )
    }

    private static func disclosureIsEligible(
        _ record: AgencyRecord,
        state: AgencyState,
        signals: AgencySelectionSignals
    ) -> Bool {
        guard record.kind == .selectiveDisclosure,
              record.status == .active,
              let disclosure = record.disclosure,
              disclosure.status == .held,
              signals.relationshipSecurity >= disclosure.minimumRelationshipSecurity,
              state.relationalBalance.interrogationPressure <= disclosure.maximumInterrogationPressure else {
            return false
        }
        return !disclosure.requiresOwnerReciprocity
            || state.relationalBalance.ownerDisclosureCount
                > state.relationalBalance.auroraDisclosureCount
    }

    private static func selectionScore(
        _ record: AgencyRecord,
        signals: AgencySelectionSignals
    ) -> Double {
        let pressure: Double
        switch record.kind {
        case .activeStance:
            pressure = 0.45 * signals.feltAgency + 0.35 * signals.autonomyDrive
        case .selfThread:
            pressure = 0.40 * signals.curiosityDrive + 0.35 * signals.uncertainty
        case .relationalThread:
            pressure = 0.30 * signals.connectionDrive
                + 0.25 * signals.relationshipWarmth
                + 0.25 * max(signals.relationalHurt, signals.repairNeed)
        case .presentWant:
            pressure = 0.25 * signals.autonomyDrive
                + 0.25 * signals.connectionDrive
                + 0.20 * signals.playDrive
        case .selectiveDisclosure:
            pressure = 0.35 * signals.connectionDrive + 0.35 * signals.relationshipSecurity
        case .groundedCallback:
            pressure = 0.35 * signals.connectionDrive + 0.25 * signals.curiosityDrive
        }
        return 0.35 * record.confidence + 0.35 * record.salience + pressure
    }

    private static func suggestedMoves(
        selected: [AgencyRecord],
        signals: AgencySelectionSignals,
        balance: AgencyRelationalBalance,
        disclosureID: String?
    ) -> [AgencyAuthoredMoveType] {
        var moves: [AgencyAuthoredMoveType] = []
        func add(_ move: AgencyAuthoredMoveType) {
            if !moves.contains(move), moves.count < 5 { moves.append(move) }
        }
        if signals.repairNeed >= 0.55 { add(.repair) }
        if balance.interrogationPressure >= 0.62 {
            add(.withhold)
            add(.challenge)
            add(.redirect)
        }
        if signals.playDrive >= 0.60 { add(.tease) }
        if signals.autonomyDrive >= 0.58 || signals.feltAgency >= 0.68 {
            add(.disagree)
            add(.challenge)
        }
        if disclosureID != nil && signals.connectionDrive >= 0.52 {
            add(.reveal)
            add(.reciprocate)
        }
        if signals.curiosityDrive >= 0.52 { add(.pursueCuriosity) }
        if selected.contains(where: { $0.kind == .relationalThread || $0.kind == .selfThread }) {
            add(.initiateThread)
        }
        if moves.isEmpty { add(.answer) }
        return moves
    }

    private static func validate(signals: AgencySelectionSignals) throws {
        let values = [
            signals.curiosityDrive, signals.connectionDrive, signals.playDrive,
            signals.autonomyDrive, signals.feltAgency, signals.uncertainty,
            signals.relationshipWarmth, signals.relationshipSecurity,
            signals.relationalHurt, signals.repairNeed,
        ]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AgencyInputError.invalidInput("selection signals")
        }
    }

    private static func validateGroundings(
        _ values: [AgencyGroundingReference]
    ) throws -> [AgencyGroundingReference] {
        guard !values.isEmpty, values.count <= maximumGroundingsPerRecord else {
            throw AgencyInputError.invalidInput("record groundings")
        }
        var seen = Set<String>()
        var result: [AgencyGroundingReference] = []
        for value in values {
            try requireSourceID(value.id, field: "grounding source ID")
            if let sessionID = value.sourceSessionID {
                try requireSourceID(sessionID, field: "grounding session ID")
            }
            if let turnID = value.sourceTurnID {
                try requireSourceID(turnID, field: "grounding turn ID")
            }
            if seen.insert(value.id).inserted { result.append(value) }
        }
        return result
    }

    private static func validateSourceIDs(
        _ values: [String],
        field: String,
        maximum: Int
    ) throws -> [String] {
        guard values.count <= maximum else { throw AgencyInputError.invalidInput(field) }
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            try requireSourceID(value, field: field)
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }

    private static func requireText(
        _ value: String,
        field: String,
        maximum: Int
    ) throws -> String {
        guard value.rangeOfCharacter(from: .newlines) == nil else {
            throw AgencyInputError.invalidInput(field)
        }
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximum,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AgencyInputError.invalidInput(field)
        }
        return normalized
    }

    private static func requireSourceID(_ value: String, field: String) throws {
        guard isValidSourceID(value) else { throw AgencyInputError.invalidInput(field) }
    }

    private static func isValidSourceID(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized == value
            && normalized.count <= 180
            && normalized.rangeOfCharacter(from: .newlines) == nil
            && normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func validateUnit(
        _ value: Double,
        field: String,
        minimum: Double
    ) throws {
        guard value.isFinite, value >= minimum, value <= 1 else {
            throw AgencyInputError.invalidInput(field)
        }
    }

    private static func uniqueGroundings(
        _ values: [AgencyGroundingReference]
    ) -> [AgencyGroundingReference] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
            .prefix(maximumGroundingsPerRecord)
            .map { $0 }
    }

    private static func uniqueStrings(_ values: [String], maximum: Int) -> [String] {
        var seen = Set<String>()
        return values.filter { isValidSourceID($0) && seen.insert($0).inserted }
            .prefix(maximum)
            .map { $0 }
    }

    private static func boundedRecords(_ values: [AgencyRecord]) -> [AgencyRecord] {
        guard values.count > maximumRecords else { return values }
        let pending = values.filter { $0.disclosure?.status == .pendingPlayback }
        let active = values.filter {
            $0.status == .active && $0.disclosure?.status != .pendingPlayback
        }.sorted { $0.updatedAt > $1.updatedAt }
        let historical = values.filter {
            $0.status != .active && $0.disclosure?.status != .pendingPlayback
        }.sorted { $0.updatedAt > $1.updatedAt }
        let selected = Array((pending + active + historical).prefix(maximumRecords))
        let ids = Set(selected.map(\.id))
        return values.filter { ids.contains($0.id) }
    }

    private static func boundedMoves(_ values: [AgencyAuthoredMove]) -> [AgencyAuthoredMove] {
        guard values.count > maximumAuthoredMoves else { return values }
        let pending = values.filter { $0.status == .pendingPlayback }
        let complete = values.filter { $0.status != .pendingPlayback }
            .sorted { $0.updatedAt > $1.updatedAt }
        let selected = Array((pending + complete).prefix(maximumAuthoredMoves))
        let ids = Set(selected.map(\.id))
        return values.filter { ids.contains($0.id) }
    }

    private static func uniqueSuffix<T>(
        _ values: [T],
        id: (T) -> String,
        maximum: Int
    ) -> [T] {
        var seen = Set<String>()
        let reversed = values.reversed().filter { seen.insert(id($0)).inserted }
        return Array(reversed.prefix(maximum).reversed())
    }

    private static func recomputeReciprocity(_ balance: inout AgencyRelationalBalance) {
        let owner = balance.ownerDisclosureCount
        let aurora = balance.auroraDisclosureCount
        let total = max(1, owner + aurora)
        balance.disclosureReciprocity = min(
            1,
            max(-1, Double(owner - aurora) / Double(total))
        )
    }

    private static func nextID(prefix: String, state: inout AgencyState) -> String {
        state.sequence = increment(state.sequence)
        return "\(prefix)-\(state.sequence)"
    }

    private static func increment(_ value: Int) -> Int {
        min(maximumSafeCounter, max(0, value) + 1)
    }

    private static func boundedCounter(_ value: Int) -> Int {
        min(maximumSafeCounter, max(0, value))
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func fixedDecimal(_ value: Double) -> String {
        String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private static func signedFixedDecimal(_ value: Double) -> String {
        let prefix = value >= 0 ? "+" : ""
        return prefix + fixedDecimal(value)
    }

    private static func monotonic(_ proposed: Date, after existing: Date) -> Date {
        max(proposed, existing)
    }
}
