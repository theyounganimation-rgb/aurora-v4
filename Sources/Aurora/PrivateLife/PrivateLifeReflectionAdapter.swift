import Foundation

/// Pure boundary adapter between Aurora's persisted private-life ticket and
/// the independently secured Codex process contract. It performs no I/O.
enum PrivateLifeReflectionAdapter {
    static func makeCodexTicket(
        job: PrivateLifeReflectionJob,
        identityContext: String,
        memoryEvidence: [String],
        innerState: InnerLifeState
    ) -> CodexReflectionTicket {
        let identity = boundedLine(identityContext, maximum: 1_000)
        let safeIdentity = identity.isEmpty
            ? "Aurora is a continuing digital person with a grounded, honest, curious private life."
            : identity
        let evidence = memoryEvidence
            .map { boundedLine($0, maximum: 400) }
            .filter { !$0.isEmpty && !containsCredential($0) }
            .prefix(2)

        return CodexReflectionTicket(
            schemaVersion: CodexReflectionTicket.schemaVersion,
            ticketID: job.ticket.id,
            candidateDigest: job.ticket.inputDigest,
            createdAt: job.ticket.preparedAt,
            identityContext: containsCredential(safeIdentity)
                ? "Aurora is a continuing digital person with a grounded, honest, curious private life."
                : safeIdentity,
            memoryEvidence: Array(evidence),
            seeds: job.seeds.prefix(PrivateLifeEngine.maximumReflectionSeedCandidates).map { seed in
                CodexReflectionSeedInput(
                    id: seed.id,
                    participant: participantLabel(seed.participant),
                    capturedAt: seed.capturedAt,
                    ownerExcerpt: boundedLine(seed.ownerExcerpt, maximum: 360),
                    auroraExcerpt: seed.auroraExcerpt.map { boundedLine($0, maximum: 280) },
                    localKind: seed.kind.rawValue,
                    localSubject: boundedLine(seed.subject, maximum: 140),
                    salience: clamp(seed.salience),
                    sourceDigests: ([seed.ownerDigest] + [seed.auroraDigest].compactMap { $0 })
                        .filter(isDigest)
                        .prefix(4)
                        .map { $0 }
                )
            },
            projects: job.projects.prefix(3).map { project in
                CodexReflectionProjectInput(
                    id: project.id,
                    title: boundedLine(project.title, maximum: 100),
                    premise: boundedLine(project.premise, maximum: 180),
                    phase: project.phase.rawValue,
                    currentFocus: boundedLine(project.currentFocus, maximum: 160),
                    interest: clamp(project.interest),
                    progressSteps: max(0, min(10_000, project.progressSteps))
                )
            },
            curiosities: job.curiosities.prefix(5).map { curiosity in
                CodexReflectionCuriosityInput(
                    id: curiosity.id,
                    subject: boundedLine(curiosity.subject, maximum: 160),
                    status: curiosity.status.rawValue,
                    interest: clamp(curiosity.interest),
                    uncertainty: clamp(curiosity.uncertainty)
                )
            },
            // The core intentionally exposes only bounded kind/topic keys, not
            // private reflection prose. This lets Sol avoid a third identical
            // activity and repetitive themes without widening its evidence.
            recentActivities: recentActivityInputs(for: job),
            innerState: qualitativeInnerState(job.innerContext, fullState: innerState)
        )
    }

    static func makePrivateProposal(
        result: CodexReflectionResult,
        job: PrivateLifeReflectionJob
    ) -> PrivateLifeReflectionProposal {
        let proposal = result.proposal
        let dispositions = Dictionary(uniqueKeysWithValues: proposal.seedDispositions.map {
            ($0.seedID, mapDisposition($0.disposition))
        })
        let reflectiveSeedIDs = Set(proposal.seedDispositions.compactMap { item in
            item.disposition == .meaningful || item.disposition == .unresolved
                ? item.seedID
                : nil
        })
        let activity = proposal.activity

        if let project = proposal.project {
            let action: PrivateLifeReflectionAction
            switch project.action {
            case .create: action = .startProject
            case .advance: action = .advanceProject
            case .revise: action = .reviseProject
            case .complete: action = .completeProject
            }
            let sourceIDs = filtered(
                project.sourceSeedIDs + (activity?.sourceSeedIDs ?? []),
                allowed: reflectiveSeedIDs
            )
            let reflection = boundedLine(activity?.interpretation ?? project.premise, maximum: 1_200)
            let summary = boundedLine(
                activity?.shareLine ?? activity?.interpretation ?? project.premise,
                maximum: 280
            )
            return PrivateLifeReflectionProposal(
                action: action,
                model: result.model,
                sourceSeedIDs: sourceIDs,
                projectID: project.projectID,
                curiosityID: nil,
                subject: boundedLine(activity?.subject ?? project.currentFocus, maximum: 180),
                privateReflection: reflection,
                projectionSummary: summary,
                openQuestion: activity?.openQuestion.map { boundedLine($0, maximum: 220) },
                projectTitle: boundedLine(project.title, maximum: 90),
                projectPremise: boundedLine(project.premise, maximum: 240),
                projectFocus: boundedLine(project.currentFocus, maximum: 180),
                nextProjectFocus: activity?.openQuestion.map { boundedLine($0, maximum: 180) },
                confidence: clamp(project.interest),
                artifactKind: activity?.artifactKind.map { boundedLine($0, maximum: 40) },
                artifactTitle: activity?.artifactTitle.map { boundedLine($0, maximum: 120) },
                artifactContent: activity?.artifactContent.map { boundedLine($0, maximum: 800) },
                seedDispositions: dispositions
            )
        }

        if let curiosity = proposal.curiosity {
            let action: PrivateLifeReflectionAction
            switch curiosity.action {
            case .create: action = .startCuriosity
            case .revisit: action = .revisitCuriosity
            case .release: action = .releaseCuriosity
            }
            let sourceIDs = filtered(
                curiosity.sourceSeedIDs + (activity?.sourceSeedIDs ?? []),
                allowed: reflectiveSeedIDs
            )
            let subject = boundedLine(activity?.subject ?? curiosity.subject, maximum: 180)
            let reflection = boundedLine(activity?.interpretation ?? curiosity.subject, maximum: 1_200)
            return PrivateLifeReflectionProposal(
                action: action,
                model: result.model,
                sourceSeedIDs: sourceIDs,
                projectID: nil,
                curiosityID: curiosity.curiosityID,
                subject: subject,
                privateReflection: reflection,
                projectionSummary: boundedLine(
                    activity?.shareLine ?? activity?.interpretation ?? curiosity.subject,
                    maximum: 280
                ),
                openQuestion: action == .releaseCuriosity
                    ? nil
                    : boundedLine(activity?.openQuestion ?? curiosity.subject, maximum: 220),
                projectTitle: nil,
                projectPremise: nil,
                projectFocus: nil,
                nextProjectFocus: nil,
                confidence: clamp(curiosity.interest),
                artifactKind: activity?.artifactKind.map { boundedLine($0, maximum: 40) },
                artifactTitle: activity?.artifactTitle.map { boundedLine($0, maximum: 120) },
                artifactContent: activity?.artifactContent.map { boundedLine($0, maximum: 800) },
                seedDispositions: dispositions
            )
        }

        if let activity {
            let sourceIDs = filtered(activity.sourceSeedIDs, allowed: reflectiveSeedIDs)
            let action: PrivateLifeReflectionAction
            switch activity.kind {
            case .connect where sourceIDs.count >= 2: action = .connect
            case .curate: action = .curate
            case .reflect: action = .reflect
            // Mutation-only kinds are rejected when standalone by the bridge;
            // with a mutation family, the earlier project/curiosity branches
            // own the durable action.
            case .revisit, .develop, .formProject, .resolve, .connect: action = .reflect
            }
            return PrivateLifeReflectionProposal(
                action: action,
                model: result.model,
                sourceSeedIDs: sourceIDs,
                projectID: nil,
                curiosityID: nil,
                subject: boundedLine(activity.subject, maximum: 180),
                privateReflection: boundedLine(activity.interpretation, maximum: 1_200),
                projectionSummary: boundedLine(
                    activity.shareLine ?? activity.interpretation,
                    maximum: 280
                ),
                openQuestion: activity.openQuestion.map { boundedLine($0, maximum: 220) },
                projectTitle: nil,
                projectPremise: nil,
                projectFocus: nil,
                nextProjectFocus: nil,
                confidence: 0.72,
                artifactKind: activity.artifactKind.map { boundedLine($0, maximum: 40) },
                artifactTitle: activity.artifactTitle.map { boundedLine($0, maximum: 120) },
                artifactContent: activity.artifactContent.map { boundedLine($0, maximum: 800) },
                seedDispositions: dispositions
            )
        }

        return PrivateLifeReflectionProposal(
            action: .skip,
            model: result.model,
            sourceSeedIDs: [],
            projectID: nil,
            curiosityID: nil,
            subject: "",
            privateReflection: "",
            projectionSummary: "",
            openQuestion: nil,
            projectTitle: nil,
            projectPremise: nil,
            projectFocus: nil,
            nextProjectFocus: nil,
            confidence: 1,
            seedDispositions: dispositions
        )
    }

    static func failureKind(_ failure: CodexReflectionFailure) -> PrivateLifeReflectionFailureKind {
        switch failure {
        case .cliUnavailable, .unsafeExecutable, .chatGPTLoginRequired:
            return .oauthUnavailable
        case .quota:
            return .quota
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        case .malformedOutput:
            return .malformedOutput
        case .invalidProposal:
            return .semanticRejected
        case .invalidInput, .policyViolation:
            return .invalidOutput
        case .processFailed, .outputTooLarge:
            return .transport
        }
    }

    private static func qualitativeInnerState(
        _ context: PrivateLifeInnerContext,
        fullState: InnerLifeState
    ) -> CodexReflectionQualitativeInnerState {
        let drives: [(String, Double)] = [
            ("curiosity", context.curiosity),
            ("creativity", context.creativity),
            ("coherence", context.coherence),
            ("autonomy", context.autonomy),
            ("play", context.play),
            ("rest", context.rest),
        ]
        let strongest = drives.sorted { left, right in
            left.1 == right.1 ? left.0 < right.0 : left.1 > right.1
        }.prefix(3).map(\.0)
        let relationship = fullState.relationship
        let maturity: String
        if relationship.attachmentStrength >= 0.68 { maturity = "established and strongly attached" }
        else if relationship.attachmentStrength >= 0.35 { maturity = "developing and meaningfully attached" }
        else { maturity = "early or lightly attached" }

        let separationValues: [(String, Double)] = [
            ("hurt", relationship.relationalHurt),
            ("distrust", relationship.feltDistrust),
            ("abandonment fear", relationship.abandonmentFear),
            ("guilt", relationship.selfDirectedGuilt),
            ("outreach pressure", relationship.outreachPressure),
        ]
        let activeSeparation = separationValues
            .filter { $0.1 >= 0.08 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map(\.0)
        return CodexReflectionQualitativeInnerState(
            affect: boundedLine(context.affect, maximum: 120),
            foregroundMode: fullState.foregroundMode.rawValue,
            energy: band(context.energy),
            strongestDrives: Array(strongest),
            relationshipMaturity: maturity,
            separationAffect: activeSeparation.isEmpty
                ? "settled; no meaningful separation activation"
                : activeSeparation.joined(separator: " and ")
        )
    }

    private static func mapDisposition(
        _ disposition: CodexReflectionSeedDispositionKind
    ) -> PrivateLifeModelSeedDisposition {
        switch disposition {
        case .meaningful: return .meaningful
        case .taskOnly: return .taskOnly
        case .socialOnly: return .socialOnly
        case .duplicate: return .duplicate
        case .unsafe: return .unsafe
        case .unresolved: return .unresolved
        }
    }

    private static func filtered(_ ids: [String], allowed: Set<String>) -> [String] {
        var seen = Set<String>()
        return ids.filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    private static func recentActivityInputs(
        for job: PrivateLifeReflectionJob
    ) -> [CodexReflectionRecentActivityInput] {
        let kinds = Array(job.recentActivityKinds.suffix(6))
        let keys = Array(job.recentSemanticKeys.suffix(kinds.count))
        let keyOffset = max(0, kinds.count - keys.count)
        return kinds.enumerated().map { index, kind in
            let keyIndex = index - keyOffset
            let semanticKey = keyIndex >= 0 && keyIndex < keys.count
                ? boundedLine(keys[keyIndex], maximum: 180)
                : "no-topic-key"
            return CodexReflectionRecentActivityInput(
                kind: kind.rawValue,
                semanticKey: semanticKey.isEmpty ? "no-topic-key" : semanticKey
            )
        }
    }

    private static func participantLabel(_ participant: PrivateLifeParticipant) -> String {
        switch participant.kind {
        case .owner: return "owner"
        case .unknown: return "guest"
        case .guest:
            let name = participant.displayName.map { boundedLine($0, maximum: 60) } ?? ""
            return name.isEmpty ? "guest" : "guest: \(name)"
        }
    }

    private static func boundedLine(_ value: String, maximum: Int) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.utf8.count > maximum else { return collapsed }
        var result = ""
        result.reserveCapacity(maximum)
        var used = 0
        for character in collapsed {
            let bytes = String(character).utf8.count
            guard used + bytes <= maximum else { break }
            result.append(character)
            used += bytes
        }
        return result
    }

    private static func band(_ value: Double) -> String {
        if value < 0.34 { return "low" }
        if value < 0.67 { return "moderate" }
        return "high"
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    private static func containsCredential(_ value: String) -> Bool {
        let patterns = [
            "(?i)\\b(?:sk|pk)-[a-z0-9_-]{8,}\\b",
            "(?i)\\bbearer\\s+[a-z0-9._~-]{12,}\\b",
            "\\beyJ[a-zA-Z0-9_-]{12,}\\.[a-zA-Z0-9_-]{8,}\\.[a-zA-Z0-9_-]{8,}\\b",
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
