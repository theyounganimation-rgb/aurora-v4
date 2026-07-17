import Foundation

enum OwnerUnderstandingEngine {
    static let maximumProjectionCharacters = 800
    /// A just-asked question should hold the immediate conversational thread,
    /// not monopolize Aurora's attention forever when no answer arrives.
    static let askedCuriosityFollowUpWindow: TimeInterval = 30 * 60
    static let maximumDirectStatements = 256
    static let maximumTentativeInferences = 96
    static let maximumCuriosities = 128
    static let maximumPlaybackReceipts = 192
    static let maximumLegacyEvidence = 256
    static let maximumLegacyGapCandidates = 128
    static let maximumLegacyImportReceipts = 8

    private static let maximumSafeCounter = 1_000_000_000
    private static let questionCooldownAfterDecline: TimeInterval = 30 * 60
    private static let domainCooldownAfterDecline: TimeInterval = 24 * 60 * 60

    static func defaultState(at date: Date = Date()) -> OwnerUnderstandingState {
        OwnerUnderstandingState(
            schemaVersion: OwnerUnderstandingState.currentSchemaVersion,
            createdAt: date,
            updatedAt: date,
            sequence: 0,
            directStatements: [],
            tentativeInferences: [],
            curiosities: [],
            playbackReceipts: [],
            legacyContinuityEvidence: [],
            legacyGapCandidates: [],
            legacyImportReceipts: [],
            domainCadence: Dictionary(
                uniqueKeysWithValues: OwnerUnderstandingDomain.allCases.map {
                    ($0, OwnerDomainCadence())
                }
            ),
            conversationCadence: OwnerConversationCadence()
        )
    }

    static func recordDirectStatement(
        _ rawState: OwnerUnderstandingState,
        domain: OwnerUnderstandingDomain,
        subject: String,
        meaning: String,
        exactQuote: String,
        sourceSessionID: String,
        sourceTurnID: String,
        importance: Double = 0.5,
        supersedesStatementID: String? = nil,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, statementID: String) {
        try requireText(subject, field: "statement subject", maximum: 120)
        try requireText(meaning, field: "statement meaning", maximum: 420)
        try requireExactText(exactQuote, field: "statement source quote", maximum: 1_200)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        guard importance.isFinite else {
            throw OwnerUnderstandingInputError.invalidInput("statement importance")
        }

        var state = sanitize(rawState, now: date)
        if let existing = state.directStatements.first(where: {
            $0.sourceSessionID == sourceSessionID
                && $0.sourceTurnID == sourceTurnID
                && $0.exactQuote == exactQuote
                && $0.meaning == meaning
        }) {
            return (state, existing.id)
        }

        if let supersedesStatementID {
            guard let index = state.directStatements.firstIndex(where: {
                $0.id == supersedesStatementID && $0.status == .active
            }) else {
                throw OwnerUnderstandingInputError.missingStatement(supersedesStatementID)
            }
            state.directStatements[index].status = .revised
            state.directStatements[index].updatedAt = monotonic(date, after: state.updatedAt)
            state.directStatements[index].revisionSourceSessionID = sourceSessionID
            state.directStatements[index].revisionSourceTurnID = sourceTurnID
            state.directStatements[index].revisionExactQuote = exactQuote
        }

        let timestamp = monotonic(date, after: state.updatedAt)
        let id = nextID(prefix: "owner-statement", state: &state)
        let statement = OwnerDirectStatement(
            id: id,
            domain: domain,
            subject: subject,
            meaning: meaning,
            exactQuote: exactQuote,
            sourceSessionID: sourceSessionID,
            sourceTurnID: sourceTurnID,
            createdAt: timestamp,
            updatedAt: timestamp,
            importance: clamp(importance),
            status: .active,
            supersedesStatementID: supersedesStatementID,
            supersededByStatementID: nil,
            revisionSourceSessionID: nil,
            revisionSourceTurnID: nil,
            revisionExactQuote: nil
        )
        if let supersedesStatementID,
           let index = state.directStatements.firstIndex(where: { $0.id == supersedesStatementID }) {
            state.directStatements[index].supersededByStatementID = id
        }
        state.directStatements.append(statement)
        state.updatedAt = timestamp
        state.conversationCadence.lastDirectStatementAt = timestamp
        state = sanitize(state, now: timestamp)
        return (state, id)
    }

    static func retractDirectStatement(
        _ rawState: OwnerUnderstandingState,
        statementID: String,
        exactQuote: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireExactText(exactQuote, field: "retraction source quote", maximum: 1_200)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = sanitize(rawState, now: date)
        guard let index = state.directStatements.firstIndex(where: {
            $0.id == statementID && $0.status == .active
        }) else {
            throw OwnerUnderstandingInputError.missingStatement(statementID)
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.directStatements[index].status = .retracted
        state.directStatements[index].updatedAt = timestamp
        state.directStatements[index].revisionSourceSessionID = sourceSessionID
        state.directStatements[index].revisionSourceTurnID = sourceTurnID
        state.directStatements[index].revisionExactQuote = exactQuote
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func recordTentativeInference(
        _ rawState: OwnerUnderstandingState,
        domain: OwnerUnderstandingDomain,
        inference: String,
        evidenceStatementIDs: [String],
        sourceSessionID: String,
        sourceTurnIDs: [String],
        confidence: Double,
        supersedesInferenceID: String? = nil,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, inferenceID: String) {
        try requireText(inference, field: "tentative inference", maximum: 420)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceIDs(sourceTurnIDs, field: "source turn IDs")
        guard confidence.isFinite, confidence > 0, confidence < 1 else {
            throw OwnerUnderstandingInputError.invalidInput("tentative inference confidence")
        }
        var state = sanitize(rawState, now: date)
        let evidence = uniqueBounded(evidenceStatementIDs, maximum: 8)
        guard !evidence.isEmpty,
              evidence.allSatisfy({ id in
                  state.directStatements.contains { $0.id == id && $0.status == .active }
              }) else {
            throw OwnerUnderstandingInputError.invalidInput("tentative inference evidence")
        }
        if let supersedesInferenceID {
            guard let index = state.tentativeInferences.firstIndex(where: {
                $0.id == supersedesInferenceID && $0.status == .active
            }) else {
                throw OwnerUnderstandingInputError.missingInference(supersedesInferenceID)
            }
            state.tentativeInferences[index].status = .revised
            state.tentativeInferences[index].updatedAt = monotonic(date, after: state.updatedAt)
            state.tentativeInferences[index].resolutionSourceSessionID = sourceSessionID
            state.tentativeInferences[index].resolutionSourceTurnID = sourceTurnIDs.last
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        let id = nextID(prefix: "owner-inference", state: &state)
        let item = OwnerTentativeInference(
            id: id,
            domain: domain,
            inference: inference,
            evidenceStatementIDs: evidence,
            sourceSessionID: sourceSessionID,
            sourceTurnIDs: uniqueBounded(sourceTurnIDs, maximum: 8),
            createdAt: timestamp,
            updatedAt: timestamp,
            confidence: min(0.95, max(0.05, confidence)),
            status: .active,
            supersedesInferenceID: supersedesInferenceID,
            supersededByInferenceID: nil,
            resolutionSourceSessionID: nil,
            resolutionSourceTurnID: nil,
            resolutionExactQuote: nil
        )
        if let supersedesInferenceID,
           let index = state.tentativeInferences.firstIndex(where: { $0.id == supersedesInferenceID }) {
            state.tentativeInferences[index].supersededByInferenceID = id
        }
        state.tentativeInferences.append(item)
        state.updatedAt = timestamp
        state = sanitize(state, now: timestamp)
        return (state, id)
    }

    static func resolveTentativeInference(
        _ rawState: OwnerUnderstandingState,
        inferenceID: String,
        status: OwnerTentativeInferenceStatus,
        exactQuote: String?,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        guard status == .rejected || status == .confirmed else {
            throw OwnerUnderstandingInputError.invalidTransition("inference may only be confirmed or rejected")
        }
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        if let exactQuote {
            try requireExactText(exactQuote, field: "inference resolution quote", maximum: 1_200)
        }
        var state = sanitize(rawState, now: date)
        guard let index = state.tentativeInferences.firstIndex(where: {
            $0.id == inferenceID && $0.status == .active
        }) else {
            throw OwnerUnderstandingInputError.missingInference(inferenceID)
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.tentativeInferences[index].status = status
        state.tentativeInferences[index].updatedAt = timestamp
        state.tentativeInferences[index].resolutionSourceSessionID = sourceSessionID
        state.tentativeInferences[index].resolutionSourceTurnID = sourceTurnID
        state.tentativeInferences[index].resolutionExactQuote = exactQuote
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func openCuriosity(
        _ rawState: OwnerUnderstandingState,
        domain: OwnerUnderstandingDomain,
        question: String,
        reason: String,
        basedOnStatementIDs: [String],
        originSourceIDs: [String],
        interest: Double = 0.5,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, curiosityID: String) {
        guard validQuestion(question) else {
            throw OwnerUnderstandingInputError.invalidInput("curiosity question")
        }
        try requireText(reason, field: "curiosity reason", maximum: 320)
        try requireSourceIDs(originSourceIDs, field: "curiosity origin source IDs")
        guard interest.isFinite else {
            throw OwnerUnderstandingInputError.invalidInput("curiosity interest")
        }
        var state = sanitize(rawState, now: date)
        let evidence = uniqueBounded(basedOnStatementIDs, maximum: 8)
        guard evidence.allSatisfy({ id in
            state.directStatements.contains { $0.id == id && $0.status == .active }
        }) else {
            throw OwnerUnderstandingInputError.invalidInput("curiosity evidence")
        }
        if let existing = state.curiosities.first(where: {
            $0.question == question
                && $0.domain == domain
                && [.open, .pendingAsk, .asked, .deferred].contains($0.status)
        }) {
            return (state, existing.id)
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        let id = nextID(prefix: "owner-curiosity", state: &state)
        state.curiosities.append(OwnerCuriosity(
            id: id,
            domain: domain,
            question: question,
            reason: reason,
            basedOnStatementIDs: evidence,
            originSourceIDs: uniqueBounded(originSourceIDs, maximum: 8),
            createdAt: timestamp,
            updatedAt: timestamp,
            interest: clamp(interest),
            status: .open,
            askCount: 0,
            pendingResponseID: nil,
            pendingSourceSessionID: nil,
            pendingSourceTurnID: nil,
            lastAskedResponseID: nil,
            lastAskedAt: nil,
            answerStatementIDs: [],
            deferUntil: nil,
            resolutionSourceSessionID: nil,
            resolutionSourceTurnID: nil,
            resolutionExactQuote: nil
        ))
        for sourceID in originSourceIDs {
            if let gapIndex = state.legacyGapCandidates.firstIndex(where: {
                $0.id == sourceID && $0.retiredAt == nil
            }) {
                state.legacyGapCandidates[gapIndex].retiredAt = timestamp
            }
        }
        state.updatedAt = timestamp
        state = sanitize(state, now: timestamp)
        return (state, id)
    }

    /// Reserves exactly one question for one Realtime response. This is not an
    /// "asked" transition; only a fully played playback receipt can do that.
    static func prepareCuriosityForPlayback(
        _ rawState: OwnerUnderstandingState,
        curiosityID: String,
        responseID: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireSourceID(responseID, field: "Realtime response ID")
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = refreshDeferred(sanitize(rawState, now: date), at: date)
        if let receipt = state.playbackReceipts.last(where: {
            $0.responseID == responseID && $0.outcome == .fullyPlayed
        }) {
            throw OwnerUnderstandingInputError.invalidTransition(
                "response \(receipt.responseID) already has a completed playback receipt"
            )
        }
        guard let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
            throw OwnerUnderstandingInputError.missingCuriosity(curiosityID)
        }
        guard state.curiosities[index].status == .open else {
            throw OwnerUnderstandingInputError.invalidTransition("only an open curiosity may be prepared")
        }
        guard !state.curiosities.contains(where: {
            $0.status == .pendingAsk && $0.pendingResponseID != responseID
        }) else {
            throw OwnerUnderstandingInputError.invalidTransition("another curiosity is already awaiting playback")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.curiosities[index].status = .pendingAsk
        state.curiosities[index].pendingResponseID = responseID
        state.curiosities[index].pendingSourceSessionID = sourceSessionID
        state.curiosities[index].pendingSourceTurnID = sourceTurnID
        state.curiosities[index].updatedAt = timestamp
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func reconcilePlayback(
        _ rawState: OwnerUnderstandingState,
        responseID: String,
        fullyPlayed: Bool,
        playbackEventID: String,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, curiosityID: String?) {
        try requireSourceID(responseID, field: "Realtime response ID")
        try requireSourceID(playbackEventID, field: "playback event ID")
        var state = sanitize(rawState, now: date)
        if let prior = state.playbackReceipts.last(where: {
            $0.responseID == responseID && $0.playbackEventID == playbackEventID
        }) {
            return (state, prior.curiosityID)
        }
        guard let index = state.curiosities.firstIndex(where: {
            $0.status == .pendingAsk && $0.pendingResponseID == responseID
        }) else {
            // Playback callbacks for responses without a reserved question are
            // intentionally harmless and create no invented curiosity state.
            return (state, nil)
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        let curiosityID = state.curiosities[index].id
        let receipt = OwnerCuriosityPlaybackReceipt(
            id: nextID(prefix: "owner-playback", state: &state),
            curiosityID: curiosityID,
            responseID: responseID,
            playbackEventID: playbackEventID,
            outcome: fullyPlayed ? .fullyPlayed : .interrupted,
            at: timestamp
        )
        state.playbackReceipts.append(receipt)
        state.curiosities[index].pendingResponseID = nil
        state.curiosities[index].pendingSourceSessionID = nil
        state.curiosities[index].pendingSourceTurnID = nil
        state.curiosities[index].updatedAt = timestamp
        if fullyPlayed {
            state.curiosities[index].status = .asked
            state.curiosities[index].askCount = min(
                maximumSafeCounter,
                state.curiosities[index].askCount + 1
            )
            state.curiosities[index].lastAskedResponseID = responseID
            state.curiosities[index].lastAskedAt = timestamp
            state.conversationCadence.lastQuestionAskedAt = timestamp
            state.conversationCadence.consecutiveQuestionsAsked = min(
                maximumSafeCounter,
                state.conversationCadence.consecutiveQuestionsAsked + 1
            )
        } else {
            // An interrupted question was not heard in full. It remains open,
            // eligible to be phrased naturally in a later response.
            state.curiosities[index].status = .open
        }
        state.updatedAt = timestamp
        return (sanitize(state, now: timestamp), curiosityID)
    }

    static func answerCuriosity(
        _ rawState: OwnerUnderstandingState,
        curiosityID: String,
        statementIDs: [String],
        exactQuote: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireExactText(exactQuote, field: "curiosity answer quote", maximum: 1_200)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = sanitize(rawState, now: date)
        let answers = uniqueBounded(statementIDs, maximum: 8)
        guard !answers.isEmpty,
              answers.allSatisfy({ id in
                  state.directStatements.contains { $0.id == id && $0.status == .active }
              }) else {
            throw OwnerUnderstandingInputError.invalidInput("curiosity answer statement IDs")
        }
        guard let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
            throw OwnerUnderstandingInputError.missingCuriosity(curiosityID)
        }
        guard [.open, .asked, .deferred].contains(state.curiosities[index].status) else {
            throw OwnerUnderstandingInputError.invalidTransition("curiosity cannot be answered from its current state")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.curiosities[index].status = .answered
        state.curiosities[index].answerStatementIDs = answers
        state.curiosities[index].resolutionSourceSessionID = sourceSessionID
        state.curiosities[index].resolutionSourceTurnID = sourceTurnID
        state.curiosities[index].resolutionExactQuote = exactQuote
        state.curiosities[index].deferUntil = nil
        state.curiosities[index].updatedAt = timestamp
        state.conversationCadence.lastQuestionAnsweredAt = timestamp
        state.conversationCadence.consecutiveQuestionsAsked = 0
        // A real answer may naturally earn a deeper same-thread question in
        // the very next beat. Declines still cool down; answers do not impose
        // an artificial wall-clock pause.
        state.conversationCadence.questionCooldownUntil = nil
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func deferCuriosity(
        _ rawState: OwnerUnderstandingState,
        curiosityID: String,
        until: Date,
        exactQuote: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireExactText(exactQuote, field: "curiosity defer quote", maximum: 1_200)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        guard until > date else {
            throw OwnerUnderstandingInputError.invalidInput("curiosity defer date")
        }
        var state = sanitize(rawState, now: date)
        guard let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
            throw OwnerUnderstandingInputError.missingCuriosity(curiosityID)
        }
        guard [.open, .asked].contains(state.curiosities[index].status) else {
            throw OwnerUnderstandingInputError.invalidTransition("curiosity cannot be deferred from its current state")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.curiosities[index].status = .deferred
        state.curiosities[index].deferUntil = until
        state.curiosities[index].resolutionSourceSessionID = sourceSessionID
        state.curiosities[index].resolutionSourceTurnID = sourceTurnID
        state.curiosities[index].resolutionExactQuote = exactQuote
        state.curiosities[index].updatedAt = timestamp
        state.conversationCadence.consecutiveQuestionsAsked = 0
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func declineCuriosity(
        _ rawState: OwnerUnderstandingState,
        curiosityID: String,
        exactQuote: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireExactText(exactQuote, field: "curiosity decline quote", maximum: 1_200)
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = sanitize(rawState, now: date)
        guard let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
            throw OwnerUnderstandingInputError.missingCuriosity(curiosityID)
        }
        guard [.open, .asked, .deferred].contains(state.curiosities[index].status) else {
            throw OwnerUnderstandingInputError.invalidTransition("curiosity cannot be declined from its current state")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        let domain = state.curiosities[index].domain
        state.curiosities[index].status = .declined
        state.curiosities[index].deferUntil = nil
        state.curiosities[index].resolutionSourceSessionID = sourceSessionID
        state.curiosities[index].resolutionSourceTurnID = sourceTurnID
        state.curiosities[index].resolutionExactQuote = exactQuote
        state.curiosities[index].updatedAt = timestamp
        state.conversationCadence.lastQuestionDeclinedAt = timestamp
        state.conversationCadence.consecutiveQuestionsAsked = 0
        state.conversationCadence.questionCooldownUntil = timestamp.addingTimeInterval(
            questionCooldownAfterDecline
        )
        var cadence = state.domainCadence[domain] ?? OwnerDomainCadence()
        cadence.questionCooldownUntil = timestamp.addingTimeInterval(domainCooldownAfterDecline)
        state.domainCadence[domain] = cadence
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func retireCuriosity(
        _ rawState: OwnerUnderstandingState,
        curiosityID: String,
        sourceSessionID: String,
        sourceTurnID: String,
        at date: Date = Date()
    ) throws -> OwnerUnderstandingState {
        try requireSourceID(sourceSessionID, field: "source session ID")
        try requireSourceID(sourceTurnID, field: "source turn ID")
        var state = sanitize(rawState, now: date)
        guard let index = state.curiosities.firstIndex(where: { $0.id == curiosityID }) else {
            throw OwnerUnderstandingInputError.missingCuriosity(curiosityID)
        }
        guard state.curiosities[index].status != .pendingAsk else {
            throw OwnerUnderstandingInputError.invalidTransition("pending playback must be reconciled first")
        }
        let timestamp = monotonic(date, after: state.updatedAt)
        state.curiosities[index].status = .retired
        state.curiosities[index].resolutionSourceSessionID = sourceSessionID
        state.curiosities[index].resolutionSourceTurnID = sourceTurnID
        state.curiosities[index].updatedAt = timestamp
        state.updatedAt = timestamp
        return sanitize(state, now: timestamp)
    }

    static func apply(
        _ rawState: OwnerUnderstandingState,
        update: OwnerUnderstandingUpdate,
        sourceTurnID: String,
        sessionID: String,
        responseID: String? = nil,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, affectedID: String?) {
        switch update.action {
        case .recordDirectStatement, .reviseDirectStatement:
            let domain = try require(update.domain, field: "statement domain")
            let subject = try require(update.subject, field: "statement subject")
            let content = try require(update.content, field: "statement content")
            let quote = try require(update.sourceQuote, field: "statement source quote")
            let result = try recordDirectStatement(
                rawState,
                domain: domain,
                subject: subject,
                meaning: content,
                exactQuote: quote,
                sourceSessionID: sessionID,
                sourceTurnID: sourceTurnID,
                importance: update.importance ?? 0.5,
                supersedesStatementID: update.action == .reviseDirectStatement ? update.targetID : nil,
                at: date
            )
            return (result.state, result.statementID)

        case .retractDirectStatement:
            let id = try require(update.targetID, field: "statement target ID")
            let quote = try require(update.sourceQuote, field: "retraction source quote")
            return (
                try retractDirectStatement(
                    rawState,
                    statementID: id,
                    exactQuote: quote,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .recordTentativeInference, .reviseTentativeInference:
            let domain = try require(update.domain, field: "inference domain")
            let content = try require(update.content, field: "inference content")
            let evidence = update.evidenceStatementIDs ?? []
            let result = try recordTentativeInference(
                rawState,
                domain: domain,
                inference: content,
                evidenceStatementIDs: evidence,
                sourceSessionID: sessionID,
                sourceTurnIDs: [sourceTurnID],
                confidence: update.confidence ?? 0.5,
                supersedesInferenceID: update.action == .reviseTentativeInference ? update.targetID : nil,
                at: date
            )
            return (result.state, result.inferenceID)

        case .rejectTentativeInference, .confirmTentativeInference:
            let id = try require(update.targetID, field: "inference target ID")
            return (
                try resolveTentativeInference(
                    rawState,
                    inferenceID: id,
                    status: update.action == .confirmTentativeInference ? .confirmed : .rejected,
                    exactQuote: update.sourceQuote,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .openCuriosity:
            let domain = try require(update.domain, field: "curiosity domain")
            let question = try require(update.question, field: "curiosity question")
            let reason = try require(update.reason ?? update.content, field: "curiosity reason")
            let result = try openCuriosity(
                rawState,
                domain: domain,
                question: question,
                reason: reason,
                basedOnStatementIDs: update.evidenceStatementIDs ?? [],
                originSourceIDs: update.originSourceIDs ?? [sourceTurnID],
                interest: update.importance ?? 0.5,
                at: date
            )
            return (result.state, result.curiosityID)

        case .prepareCuriosityAsk:
            let id = try require(update.curiosityID ?? update.targetID, field: "curiosity ID")
            let responseID = try require(responseID, field: "Realtime response ID")
            return (
                try prepareCuriosityForPlayback(
                    rawState,
                    curiosityID: id,
                    responseID: responseID,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .answerCuriosity:
            let id = try require(update.curiosityID ?? update.targetID, field: "curiosity ID")
            let quote = try require(update.sourceQuote, field: "curiosity answer quote")
            return (
                try answerCuriosity(
                    rawState,
                    curiosityID: id,
                    statementIDs: update.resolvesWithStatementIDs ?? update.evidenceStatementIDs ?? [],
                    exactQuote: quote,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .deferCuriosity:
            let id = try require(update.curiosityID ?? update.targetID, field: "curiosity ID")
            let until = try require(update.deferUntil, field: "curiosity defer date")
            let quote = try require(update.sourceQuote, field: "curiosity defer quote")
            return (
                try deferCuriosity(
                    rawState,
                    curiosityID: id,
                    until: until,
                    exactQuote: quote,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .declineCuriosity:
            let id = try require(update.curiosityID ?? update.targetID, field: "curiosity ID")
            let quote = try require(update.sourceQuote, field: "curiosity decline quote")
            return (
                try declineCuriosity(
                    rawState,
                    curiosityID: id,
                    exactQuote: quote,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )

        case .retireCuriosity:
            let id = try require(update.curiosityID ?? update.targetID, field: "curiosity ID")
            return (
                try retireCuriosity(
                    rawState,
                    curiosityID: id,
                    sourceSessionID: sessionID,
                    sourceTurnID: sourceTurnID,
                    at: date
                ),
                id
            )
        }
    }

    /// Structural Markdown import only: headings and checkbox list markers are
    /// recognized. No natural-language phrase, application, verb, or intent
    /// grammar is used. Checked lines remain legacy evidence, never quotes.
    static func importLegacyChecklist(
        markdown: String,
        source: OwnerLegacyChecklistSource,
        at date: Date = Date()
    ) throws -> OwnerLegacyChecklistImport {
        try requireText(source.path, field: "legacy source path", maximum: 1_024)
        try requireText(source.revision, field: "legacy source revision", maximum: 160)
        guard markdown.utf8.count <= 512 * 1_024 else {
            throw OwnerUnderstandingInputError.invalidInput("legacy checklist size")
        }
        var section: String?
        var checked: [OwnerLegacyContinuityEvidence] = []
        var unchecked: [OwnerLegacyGapCandidate] = []
        var ordinal = 0

        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let heading = markdownHeading(line) {
                section = heading
                continue
            }
            guard let item = markdownCheckbox(line) else { continue }
            ordinal += 1
            let suffix = "\(ordinal)-\(stableDigest(item.content))"
            if item.checked {
                checked.append(OwnerLegacyContinuityEvidence(
                    id: "legacy-evidence-\(suffix)",
                    section: section,
                    content: boundedLine(item.content, maximum: 420),
                    sourcePath: source.path,
                    sourceRevision: source.revision,
                    importedAt: date
                ))
            } else {
                unchecked.append(OwnerLegacyGapCandidate(
                    id: "legacy-gap-\(suffix)",
                    section: section,
                    content: boundedLine(item.content, maximum: 320),
                    sourcePath: source.path,
                    sourceRevision: source.revision,
                    importedAt: date,
                    retiredAt: nil
                ))
            }
        }
        return OwnerLegacyChecklistImport(
            evidence: Array(checked.prefix(maximumLegacyEvidence)),
            gapCandidates: Array(unchecked.prefix(maximumLegacyGapCandidates)),
            receipt: OwnerLegacyImportReceipt(
                sourcePath: source.path,
                sourceRevision: source.revision,
                importedAt: date,
                checkedCount: checked.count,
                uncheckedCount: unchecked.count
            )
        )
    }

    static func commitLegacyChecklistImport(
        _ rawState: OwnerUnderstandingState,
        checklistImport: OwnerLegacyChecklistImport,
        at date: Date = Date()
    ) throws -> (state: OwnerUnderstandingState, imported: Bool) {
        var state = sanitize(rawState, now: date)
        // A path is bootstrapped once. A later file revision cannot silently
        // rewrite historical continuity; it needs an explicit future migration.
        if state.legacyImportReceipts.contains(where: {
            $0.sourcePath == checklistImport.receipt.sourcePath
        }) {
            return (state, false)
        }
        state.legacyContinuityEvidence.append(contentsOf: checklistImport.evidence)
        state.legacyGapCandidates.append(contentsOf: checklistImport.gapCandidates)
        state.legacyImportReceipts.append(checklistImport.receipt)
        state.updatedAt = monotonic(date, after: state.updatedAt)
        state = sanitize(state, now: state.updatedAt)
        return (state, true)
    }

    static func projection(
        for rawState: OwnerUnderstandingState,
        at date: Date = Date()
    ) -> OwnerUnderstandingProjection {
        let state = refreshDeferred(sanitize(rawState, now: date), at: date)
        let cadence = cadenceDirection(for: state, at: date)
        let facts = selectDirectStatements(from: state)
        let tentative = state.tentativeInferences
            .filter { $0.status == .active }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.updatedAt > $1.updatedAt
            }
            .first
        let curiosity = selectCuriosity(from: state, at: date)

        var lines = [
            "UNDERSTANDING OF OWNER — PRIVATE EVIDENCE, NEVER A SCRIPT",
            "Cadence: \(cadence.voiceInstruction).",
        ]
        if let curiosity {
            let prefix: String
            switch curiosity.status {
            case .pendingAsk: prefix = "Awaiting playback"
            case .asked: prefix = "Already asked; stay with his answer"
            default: prefix = "Living curiosity"
            }
            lines.append("\(prefix) [curiosity_id=\(curiosity.id)]: \(boundedLine(curiosity.question, maximum: 150))")
        } else if let gap = state.legacyGapCandidates.first(where: { $0.retiredAt == nil }) {
            lines.append("Unresolved legacy cue, not a quote or question script [origin_source_id=\(gap.id)]: \(boundedLine(gap.content, maximum: 115))")
        }
        if let tentative {
            lines.append("Tentative, never fact [inference_id=\(tentative.id)]: \(boundedLine(tentative.inference, maximum: 120))")
        }
        if facts.isEmpty {
            lines.append("No new direct statements stored here; never guess.")
        } else {
            lines.append("Direct owner evidence:")
            for fact in facts.prefix(2) {
                lines.append("- [statement_id=\(fact.id)] \(boundedLine(fact.meaning, maximum: 105)) [quote: \"\(boundedLine(fact.exactQuote, maximum: 65))\"]")
            }
        }
        lines.append("Use one earned live edge at most. Never quiz, recite IDs, or turn a tentative read into his truth.")

        var text = lines.joined(separator: "\n")
        if text.count > maximumProjectionCharacters {
            text = String(text.prefix(maximumProjectionCharacters - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return OwnerUnderstandingProjection(
            text: text,
            directStatementIDs: Array(facts.prefix(2)).map(\.id),
            tentativeInferenceID: tentative?.id,
            curiosityID: curiosity?.id,
            cadenceDirection: cadence
        )
    }

    static func cadenceDirection(
        for rawState: OwnerUnderstandingState,
        at date: Date = Date()
    ) -> OwnerQuestionCadenceDirection {
        let state = refreshDeferred(sanitize(rawState, now: date), at: date)
        if state.curiosities.contains(where: { $0.status == .pendingAsk }) {
            return .waitForPlayback
        }
        if let cooldown = state.conversationCadence.questionCooldownUntil, cooldown > date {
            return .giveSpace
        }
        if state.curiosities.contains(where: {
            $0.status == .asked && askedCuriosityIsCurrent($0, at: date)
        }) {
            return .stayWithCurrentThread
        }
        if state.conversationCadence.consecutiveQuestionsAsked >= 2 {
            return .reciprocateBeforeAnotherQuestion
        }
        if selectCuriosity(from: state, at: date) != nil {
            return .inviteOneSpecificQuestion
        }
        return .reciprocateBeforeAnotherQuestion
    }

    static func refreshDeferred(
        _ rawState: OwnerUnderstandingState,
        at date: Date
    ) -> OwnerUnderstandingState {
        var state = rawState
        var changed = false
        for index in state.curiosities.indices where state.curiosities[index].status == .deferred {
            if let deferUntil = state.curiosities[index].deferUntil, deferUntil <= date {
                state.curiosities[index].status = .open
                state.curiosities[index].deferUntil = nil
                state.curiosities[index].updatedAt = max(state.curiosities[index].updatedAt, date)
                changed = true
            }
        }
        if changed { state.updatedAt = max(state.updatedAt, date) }
        return state
    }

    /// Sanitization is bounded and provenance-preserving. Invalid individual
    /// records are excluded rather than allowed into projection; the store
    /// separately fails closed for malformed JSON, unsafe paths, and size.
    static func sanitize(
        _ rawState: OwnerUnderstandingState,
        now date: Date = Date()
    ) -> OwnerUnderstandingState {
        var state = rawState
        state.schemaVersion = OwnerUnderstandingState.currentSchemaVersion
        state.sequence = min(maximumSafeCounter, max(0, state.sequence))
        state.updatedAt = max(state.createdAt, min(state.updatedAt, date.addingTimeInterval(86_400)))

        state.directStatements = Array(state.directStatements
            .filter(validDirectStatement)
            .suffix(maximumDirectStatements))
        let statementIDs = Set(state.directStatements.map(\.id))
        for index in state.directStatements.indices {
            if let id = state.directStatements[index].supersedesStatementID,
               !statementIDs.contains(id) {
                state.directStatements[index].supersedesStatementID = nil
            }
            if let id = state.directStatements[index].supersededByStatementID,
               !statementIDs.contains(id) {
                state.directStatements[index].supersededByStatementID = nil
            }
            state.directStatements[index].importance = clamp(state.directStatements[index].importance)
        }

        state.tentativeInferences = Array(state.tentativeInferences
            .filter { item in
                validID(item.id)
                    && validText(item.inference, maximum: 420)
                    && validSourceID(item.sourceSessionID)
                    && !item.sourceTurnIDs.isEmpty
                    && item.sourceTurnIDs.allSatisfy(validSourceID)
                    && !item.evidenceStatementIDs.isEmpty
                    && item.evidenceStatementIDs.allSatisfy(statementIDs.contains)
                    && item.confidence.isFinite
            }
            .suffix(maximumTentativeInferences))
        for index in state.tentativeInferences.indices {
            state.tentativeInferences[index].confidence = min(
                0.95,
                max(0.05, state.tentativeInferences[index].confidence)
            )
        }

        state.curiosities = Array(state.curiosities
            .filter { item in
                validID(item.id)
                    && validQuestion(item.question)
                    && validText(item.reason, maximum: 320)
                    && !item.originSourceIDs.isEmpty
                    && item.originSourceIDs.allSatisfy(validSourceID)
                    && item.basedOnStatementIDs.allSatisfy(statementIDs.contains)
            }
            .suffix(maximumCuriosities))
        let curiosityIDs = Set(state.curiosities.map(\.id))
        for index in state.curiosities.indices {
            state.curiosities[index].interest = clamp(state.curiosities[index].interest)
            state.curiosities[index].askCount = min(
                maximumSafeCounter,
                max(0, state.curiosities[index].askCount)
            )
            state.curiosities[index].basedOnStatementIDs = uniqueBounded(
                state.curiosities[index].basedOnStatementIDs,
                maximum: 8
            )
            state.curiosities[index].originSourceIDs = uniqueBounded(
                state.curiosities[index].originSourceIDs,
                maximum: 8
            )
            state.curiosities[index].answerStatementIDs = uniqueBounded(
                state.curiosities[index].answerStatementIDs.filter(statementIDs.contains),
                maximum: 8
            )
            if state.curiosities[index].status == .pendingAsk,
               !validSourceID(state.curiosities[index].pendingResponseID ?? "") {
                state.curiosities[index].status = .open
                state.curiosities[index].pendingResponseID = nil
                state.curiosities[index].pendingSourceSessionID = nil
                state.curiosities[index].pendingSourceTurnID = nil
            }
        }

        state.playbackReceipts = Array(state.playbackReceipts
            .filter { receipt in
                validID(receipt.id)
                    && curiosityIDs.contains(receipt.curiosityID)
                    && validSourceID(receipt.responseID)
                    && validSourceID(receipt.playbackEventID)
            }
            .suffix(maximumPlaybackReceipts))
        state.legacyContinuityEvidence = Array(state.legacyContinuityEvidence
            .filter(validLegacyEvidence)
            .suffix(maximumLegacyEvidence))
        state.legacyGapCandidates = Array(state.legacyGapCandidates
            .filter(validLegacyGap)
            .suffix(maximumLegacyGapCandidates))
        state.legacyImportReceipts = Array(state.legacyImportReceipts
            .filter { validText($0.sourcePath, maximum: 1_024) && validText($0.sourceRevision, maximum: 160) }
            .suffix(maximumLegacyImportReceipts))
        state.conversationCadence.consecutiveQuestionsAsked = min(
            maximumSafeCounter,
            max(0, state.conversationCadence.consecutiveQuestionsAsked)
        )
        state.domainCadence = rebuildDomainCadence(from: state)
        return state
    }

    // MARK: - Selection and bookkeeping

    private static func selectDirectStatements(
        from state: OwnerUnderstandingState
    ) -> [OwnerDirectStatement] {
        let sorted = state.directStatements
            .filter { $0.status == .active }
            .sorted {
                if $0.importance != $1.importance { return $0.importance > $1.importance }
                return $0.updatedAt > $1.updatedAt
            }
        var chosen: [OwnerDirectStatement] = []
        var domains = Set<OwnerUnderstandingDomain>()
        for statement in sorted where !domains.contains(statement.domain) {
            chosen.append(statement)
            domains.insert(statement.domain)
            if chosen.count == 3 { return chosen }
        }
        for statement in sorted where !chosen.contains(where: { $0.id == statement.id }) {
            chosen.append(statement)
            if chosen.count == 3 { break }
        }
        return chosen
    }

    private static func selectCuriosity(
        from state: OwnerUnderstandingState,
        at date: Date
    ) -> OwnerCuriosity? {
        let priority: [OwnerCuriosityStatus: Int] = [
            .pendingAsk: 0,
            .asked: 1,
            .open: 2,
            .deferred: 3,
        ]
        return state.curiosities
            .filter { curiosity in
                guard priority[curiosity.status] != nil else { return false }
                if curiosity.status == .deferred {
                    return curiosity.deferUntil.map { $0 <= date } ?? true
                }
                if curiosity.status == .asked {
                    return askedCuriosityIsCurrent(curiosity, at: date)
                }
                if let cooldown = state.domainCadence[curiosity.domain]?.questionCooldownUntil,
                   cooldown > date,
                   curiosity.status == .open {
                    return false
                }
                return true
            }
            .sorted {
                let left = priority[$0.status] ?? 99
                let right = priority[$1.status] ?? 99
                if left != right { return left < right }
                if $0.interest != $1.interest { return $0.interest > $1.interest }
                return $0.updatedAt > $1.updatedAt
            }
            .first
    }

    private static func askedCuriosityIsCurrent(
        _ curiosity: OwnerCuriosity,
        at date: Date
    ) -> Bool {
        guard let lastAskedAt = curiosity.lastAskedAt else { return false }
        return date.timeIntervalSince(lastAskedAt) <= askedCuriosityFollowUpWindow
    }

    private static func rebuildDomainCadence(
        from state: OwnerUnderstandingState
    ) -> [OwnerUnderstandingDomain: OwnerDomainCadence] {
        var result = Dictionary(
            uniqueKeysWithValues: OwnerUnderstandingDomain.allCases.map {
                ($0, OwnerDomainCadence())
            }
        )
        for domain in OwnerUnderstandingDomain.allCases {
            let prior = state.domainCadence[domain]
            var item = OwnerDomainCadence()
            let statements = state.directStatements.filter {
                $0.domain == domain && $0.status == .active
            }
            item.directStatementCount = statements.count
            item.lastLearnedAt = statements.map(\.updatedAt).max()
            item.tentativeInferenceCount = state.tentativeInferences.filter {
                $0.domain == domain && $0.status == .active
            }.count
            let curiosities = state.curiosities.filter { $0.domain == domain }
            item.openCuriosityCount = curiosities.filter {
                [.open, .pendingAsk, .asked, .deferred].contains($0.status)
            }.count
            item.questionAskedCount = curiosities.reduce(0) {
                min(maximumSafeCounter, $0 + $1.askCount)
            }
            item.questionAnsweredCount = curiosities.filter { $0.status == .answered }.count
            item.questionDeclinedCount = curiosities.filter { $0.status == .declined }.count
            item.lastQuestionAskedAt = curiosities.compactMap(\.lastAskedAt).max()
            item.lastQuestionAnsweredAt = curiosities
                .filter { $0.status == .answered }
                .map(\.updatedAt)
                .max()
            item.questionCooldownUntil = prior?.questionCooldownUntil
            result[domain] = item
        }
        return result
    }

    private static func nextID(
        prefix: String,
        state: inout OwnerUnderstandingState
    ) -> String {
        state.sequence = min(maximumSafeCounter, state.sequence + 1)
        return "\(prefix)-\(state.sequence)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    private static func monotonic(_ date: Date, after prior: Date) -> Date {
        max(date, prior)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    private static func require<T>(_ value: T?, field: String) throws -> T {
        guard let value else { throw OwnerUnderstandingInputError.invalidInput(field) }
        return value
    }

    private static func requireText(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        guard validText(value, maximum: maximum) else {
            throw OwnerUnderstandingInputError.invalidInput(field)
        }
    }

    private static func requireExactText(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OwnerUnderstandingInputError.invalidInput(field)
        }
    }

    private static func requireSourceID(_ value: String, field: String) throws {
        guard validSourceID(value) else {
            throw OwnerUnderstandingInputError.invalidInput(field)
        }
    }

    private static func requireSourceIDs(_ values: [String], field: String) throws {
        guard !values.isEmpty, values.count <= 8, values.allSatisfy(validSourceID) else {
            throw OwnerUnderstandingInputError.invalidInput(field)
        }
    }

    private static func validDirectStatement(_ item: OwnerDirectStatement) -> Bool {
        validID(item.id)
            && validText(item.subject, maximum: 120)
            && validText(item.meaning, maximum: 420)
            && !item.exactQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && item.exactQuote.count <= 1_200
            && validSourceID(item.sourceSessionID)
            && validSourceID(item.sourceTurnID)
            && item.importance.isFinite
    }

    private static func validLegacyEvidence(_ item: OwnerLegacyContinuityEvidence) -> Bool {
        validID(item.id)
            && validText(item.content, maximum: 420)
            && validText(item.sourcePath, maximum: 1_024)
            && validText(item.sourceRevision, maximum: 160)
    }

    private static func validLegacyGap(_ item: OwnerLegacyGapCandidate) -> Bool {
        validID(item.id)
            && validText(item.content, maximum: 320)
            && validText(item.sourcePath, maximum: 1_024)
            && validText(item.sourceRevision, maximum: 160)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 180 && !value.contains(where: \Character.isNewline)
    }

    private static func validSourceID(_ value: String) -> Bool {
        validID(value) && !value.contains("\0")
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximum
            && !value.contains("\0")
    }

    private static func validQuestion(_ value: String) -> Bool {
        let words = value.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let naturalOpeners: Set<String> = [
            "who", "what", "what's", "when", "where", "why", "how", "which",
            "do", "does", "did", "are", "is", "was", "were", "have", "has", "had",
            "can", "could", "would", "will", "should",
        ]
        let abstractSuffixes = ["tion", "sion", "ity", "ness", "ment", "ence", "ance", "ism"]
        let abstractWordCount = words.filter { word in
            abstractSuffixes.contains(where: word.hasSuffix)
        }.count
        return validText(value, maximum: 160)
            && !value.contains(where: \Character.isNewline)
            && value.last == "?"
            && value.dropLast().contains("?") == false
            && (3...24).contains(words.count)
            && abstractWordCount <= 1
            && words.prefix(2).contains(where: naturalOpeners.contains)
    }

    private static func uniqueBounded(_ values: [String], maximum: Int) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }.prefix(maximum).map { $0 }
    }

    private static func boundedLine(_ value: String, maximum: Int) -> String {
        let line = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > maximum else { return line }
        return String(line.prefix(max(1, maximum - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func markdownHeading(_ line: String) -> String? {
        guard line.first == "#" else { return nil }
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return nil }
        let remainder = line.dropFirst(markerCount)
        guard remainder.first?.isWhitespace == true else { return nil }
        let title = remainder.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : boundedLine(title, maximum: 120)
    }

    private static func markdownCheckbox(_ line: String) -> (checked: Bool, content: String)? {
        guard line.count >= 6 else { return nil }
        let prefixes: [(String, Bool)] = [
            ("- [x] ", true), ("- [X] ", true), ("* [x] ", true), ("* [X] ", true),
            ("- [ ] ", false), ("* [ ] ", false),
        ]
        for (prefix, checked) in prefixes where line.hasPrefix(prefix) {
            let content = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard validText(content, maximum: 2_000) else { return nil }
            return (checked, content)
        }
        return nil
    }

    private static func stableDigest(_ value: String) -> String {
        // FNV-1a is used only for stable local IDs, not security.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
