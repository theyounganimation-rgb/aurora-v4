import Foundation

private enum ToolEffectTruthVerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
private struct VerifyAppModelToolEffectTruth {
    static func main() throws {
        let staleExecutedFailure = ToolExecutionResult(
            ok: false,
            output: "Actuated but not verified.",
            metadata: ["external_side_effect": .bool(true)]
        )
        try expect(
            AuroraToolEffectTruth.shouldPreserveAfterTurn(staleExecutedFailure),
            "an explicit external effect was lost because the tool returned ok=false"
        )

        let nameOnlySuccess = ToolExecutionResult(
            ok: true,
            output: "Accepted without an authoritative external receipt."
        )
        try expect(
            !AuroraToolEffectTruth.shouldPreserveAfterTurn(nameOnlySuccess),
            "tool success without external-side-effect metadata was preserved"
        )

        let duplicate = ToolExecutionResult(
            ok: true,
            output: "Duplicate.",
            metadata: [
                "duplicate_suppressed": .bool(true),
                "external_side_effect": .bool(true),
                "effect_verified": .bool(true),
            ]
        )
        try expect(
            !AuroraToolEffectTruth.shouldPreserveAfterTurn(duplicate)
                && AuroraToolEffectTruth.completionLearning(
                    toolName: "computer_action",
                    result: duplicate
                ) == nil,
            "a duplicate-suppressed call could be preserved or learned as success"
        )

        let broadTaskCompletion = ToolExecutionResult(
            ok: true,
            output: "The visual model reported completion.",
            metadata: ["effect_verified": .bool(false)]
        )
        try expect(
            AuroraToolEffectTruth.completionLearning(
                toolName: "computer_task",
                result: broadTaskCompletion
            ) == nil,
            "an unverified broad computer task became successful tool learning"
        )
        try expect(
            AuroraToolEffectTruth.completionLearning(
                toolName: "computer_open",
                result: broadTaskCompletion
            ) == nil,
            "an accepted but unverified open became successful tool learning"
        )
        try expect(
            AuroraToolEffectTruth.completionLearning(
                toolName: "computer_visual",
                result: broadTaskCompletion
            ) == nil,
            "an unobserved pointer result became successful tool learning"
        )

        let verifiedTaskCompletion = ToolExecutionResult(
            ok: true,
            output: "Native postcondition verified.",
            metadata: ["effect_verified": .bool(true)]
        )
        try expect(
            AuroraToolEffectTruth.completionLearning(
                toolName: "computer_task",
                result: verifiedTaskCompletion
            ) == .init(succeeded: true),
            "a verified computer task could not become successful tool learning"
        )

        try expect(
            AuroraToolEffectTruth.desktopTaskEventLearning(status: .completed) == nil,
            "a broad desktop task event became success without a native receipt"
        )
        try expect(
            AuroraToolEffectTruth.desktopTaskEventLearning(status: .failed)
                == .init(succeeded: false),
            "a failed desktop task event did not remain failure learning"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ToolEffectTruthVerificationFailure.failed(message)
        }
    }
}
