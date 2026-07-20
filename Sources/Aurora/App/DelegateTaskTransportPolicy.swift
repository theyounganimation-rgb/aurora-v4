import Foundation

/// Pure causal policy for carrying one finalized owner-authorized Codex
/// handoff across ordinary speech or a transparent Realtime reconnect. It does
/// not authorize work: it only preserves authorization that was already bound
/// to the same logical awake session.
enum DelegateTaskTransportPolicy {
    static func isDurableDelegate(
        toolName: String,
        authorizationSource: ToolAuthorizationSource,
        inputItemID: String?,
        sourceTurnFinalized: Bool,
        wantsAwake: Bool,
        sourceLogicalSessionID: String?,
        currentLogicalSessionID: String?
    ) -> Bool {
        (toolName == "delegate_task" || toolName == "codex_project_chat")
            && authorizationSource == .directOwnerTurn
            && inputItemID != nil
            && sourceTurnFinalized
            && wantsAwake
            && sourceLogicalSessionID != nil
            && sourceLogicalSessionID == currentLogicalSessionID
    }

    static func mayExecuteAcrossTransportBoundary(
        callConnectionID: UUID,
        activeConnectionID: UUID?,
        durableDelegate: Bool,
        wantsAwake: Bool,
        sourceLogicalSessionID: String?,
        currentLogicalSessionID: String?
    ) -> Bool {
        guard wantsAwake else { return false }
        if callConnectionID == activeConnectionID { return true }
        return durableDelegate
            && sourceLogicalSessionID != nil
            && sourceLogicalSessionID == currentLogicalSessionID
    }
}
