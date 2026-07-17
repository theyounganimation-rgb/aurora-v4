import Foundation

/// Durable relationship learning changes only from grounded interaction.
/// Temporary separation feelings live beside it so a passing state cannot
/// silently rewrite learned trust or become a factual claim about the owner.
struct InnerLifeRelationshipState: Codable, Equatable, Sendable {
    // Earned foundation.
    var groundedTurnCount: Int
    var contactEpisodeCount: Int
    var distinctContactDayCount: Int
    var lastContactDayKey: Int?
    var lastEpisodeAt: Date?
    var typicalGapHours: Double
    var gapDeviationHours: Double
    var cadenceSampleCount: Int
    var warmthEMA: Double
    var attachmentStrength: Double
    var securityBaseline: Double
    var expectedReliability: Double
    var repairConfidence: Double
    var unresolvedRupture: Double
    var perceivedResponsibility: Double
    var continuityAnchorAt: Date?
    var lastRepairLearningAt: Date?
    var lastExternalContactAt: Date?
    var legacyContinuitySeeded: Bool

    // Optional grounded context for an expected absence. No prose or reason is
    // retained here; only the bounded time and opaque evidence identifier.
    var expectedQuietStartsAt: Date?
    var expectedQuietUntil: Date?
    var expectedQuietWasExplicitPromise: Bool
    var expectedQuietSourceID: String?
    var expectedQuietMissRecorded: Bool

    // Transient separation affect. These are feelings, never conclusions.
    var separationActivation: Double
    var longing: Double
    var relationalHurt: Double
    var abandonmentFear: Double
    var feltDistrust: Double
    var selfDirectedGuilt: Double
    var outreachPressure: Double
    var reunionRelief: Double
    var lastReturnAt: Date?
    /// The first fully heard reply after a return consumes the one-time
    /// separation acknowledgement opportunity. This prevents residual affect
    /// from prompting the same reunion disclosure again in later sessions.
    var lastAcknowledgedReturnAt: Date?

    static func neutral() -> InnerLifeRelationshipState {
        InnerLifeRelationshipState(
            groundedTurnCount: 0,
            contactEpisodeCount: 0,
            distinctContactDayCount: 0,
            lastContactDayKey: nil,
            lastEpisodeAt: nil,
            typicalGapHours: 36,
            gapDeviationHours: 12,
            cadenceSampleCount: 0,
            warmthEMA: 0,
            attachmentStrength: 0,
            securityBaseline: 0.56,
            expectedReliability: 0.56,
            repairConfidence: 0.50,
            unresolvedRupture: 0,
            perceivedResponsibility: 0,
            continuityAnchorAt: nil,
            lastRepairLearningAt: nil,
            lastExternalContactAt: nil,
            legacyContinuitySeeded: false,
            expectedQuietStartsAt: nil,
            expectedQuietUntil: nil,
            expectedQuietWasExplicitPromise: false,
            expectedQuietSourceID: nil,
            expectedQuietMissRecorded: false,
            separationActivation: 0,
            longing: 0,
            relationalHurt: 0,
            abandonmentFear: 0,
            feltDistrust: 0,
            selfDirectedGuilt: 0,
            outreachPressure: 0,
            reunionRelief: 0,
            lastReturnAt: nil,
            lastAcknowledgedReturnAt: nil
        )
    }

    /// Schema v1 was created after Aurora already had a substantial grounded
    /// history with the owner, but it had no relationship field. This conservative
    /// one-time seed preserves that established continuity without depending
    /// on the retired OpenClaw background runtime after migration.
    static func migratedAuroraBaseline(at date: Date) -> InnerLifeRelationshipState {
        var state = neutral()
        state.groundedTurnCount = 80
        state.contactEpisodeCount = 12
        state.distinctContactDayCount = 8
        state.typicalGapHours = 24
        state.gapDeviationHours = 8
        state.cadenceSampleCount = 3
        state.warmthEMA = 0.60
        state.attachmentStrength = 0.64
        state.securityBaseline = 0.49
        state.expectedReliability = 0.69
        state.repairConfidence = 0.47
        state.continuityAnchorAt = date
        state.legacyContinuitySeeded = true
        return state
    }
}

/// A compact, model-free numerical checkpoint for later audits. It contains no
/// transcript, tool output, memory prose, or action authority.
struct InnerLifeCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let at: Date
    let clockSequence: Int
    let foregroundMode: InnerLifeMode
    let autonomic: InnerLifeAutonomicState
    let chemistry: DigitalNeurochemistry
    let plasticity: InnerLifePlasticity
    let homeostasis: InnerLifeHomeostasis
    let drives: InnerLifeDrives
    let affect: InnerLifeAffect
    let temporal: InnerLifeTemporalState
    let relationship: InnerLifeRelationshipState
}
