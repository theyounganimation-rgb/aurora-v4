import Foundation

/// Codex's persisted latest-turn state, kept independent from Aurora's task
/// ledger so the low-level app-server runtime can be verified on its own.
enum CodexDelegateTaskObservedStatus: String, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

/// Trusted executor evidence bound to one exact Codex turn. These value types
/// live beside reconciliation so the low-level runtime can recover receipts
/// without depending on Aurora's higher-level task store.
enum DelegateTaskEffectReceiptKind: String, Codable, Sendable, Equatable {
    case fileChange = "file_change"
    case structuredToolResult = "structured_tool_result"
    case toolSurfaceObservation = "tool_surface_observation"
    case reportedEffect = "reported_effect"
}

struct DelegateTaskEffectReceipt: Codable, Sendable, Equatable {
    let kind: DelegateTaskEffectReceiptKind
    let receiptID: String
    let executor: String
}

struct CodexDelegateTaskReconciliation: Sendable, Equatable {
    let threadID: String
    let latestTurnID: String?
    let status: CodexDelegateTaskObservedStatus?
    let resultSummary: String?
    let threadName: String?
    let workspacePath: String?
    /// Receipts recovered only from `latestTurnID`. Earlier turns are never
    /// allowed to establish the current operation's external effect.
    let effectReceipts: [DelegateTaskEffectReceipt]

    init(
        threadID: String,
        latestTurnID: String?,
        status: CodexDelegateTaskObservedStatus?,
        resultSummary: String?,
        threadName: String?,
        workspacePath: String?,
        effectReceipts: [DelegateTaskEffectReceipt] = []
    ) {
        self.threadID = threadID
        self.latestTurnID = latestTurnID
        self.status = status
        self.resultSummary = resultSummary
        self.threadName = threadName
        self.workspacePath = workspacePath
        self.effectReceipts = effectReceipts
    }
}
