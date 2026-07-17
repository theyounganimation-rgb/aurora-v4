import Foundation

public struct ToolAuditEvent: Sendable, Equatable {}

@main
enum DelegateTransportVerifier {
    static func main() throws {
        let oldConnection = UUID()
        let newConnection = UUID()
        let session = "logical-owner-session"
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(
                    domain: "AuroraDelegateTransportVerification",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            checks += 1
        }

        let durable = DelegateTaskTransportPolicy.isDurableDelegate(
            toolName: "delegate_task",
            authorizationSource: .directOwnerTurn,
            inputItemID: "owner-audio-item",
            sourceTurnFinalized: true,
            wantsAwake: true,
            sourceLogicalSessionID: session,
            currentLogicalSessionID: session
        )
        try expect(durable, "a finalized direct-owner delegate was not durable")
        try expect(
            DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
                callConnectionID: oldConnection,
                activeConnectionID: newConnection,
                durableDelegate: durable,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "a committed delegate was lost across a transparent Realtime reconnect"
        )
        try expect(
            !DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
                callConnectionID: oldConnection,
                activeConnectionID: newConnection,
                durableDelegate: false,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "an ordinary stale function call crossed a Realtime reconnect"
        )
        try expect(
            DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
                callConnectionID: newConnection,
                activeConnectionID: newConnection,
                durableDelegate: false,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "a current-transport function call was rejected"
        )
        try expect(
            !DelegateTaskTransportPolicy.isDurableDelegate(
                toolName: "delegate_task",
                authorizationSource: .directOwnerTurn,
                inputItemID: "owner-audio-item",
                sourceTurnFinalized: false,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "an unfinalized delegate became durable"
        )
        try expect(
            !DelegateTaskTransportPolicy.isDurableDelegate(
                toolName: "delegate_task",
                authorizationSource: .visualContinuation,
                inputItemID: "owner-audio-item",
                sourceTurnFinalized: true,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "an untrusted visual continuation became durable"
        )
        try expect(
            !DelegateTaskTransportPolicy.isDurableDelegate(
                toolName: "computer_action",
                authorizationSource: .directOwnerTurn,
                inputItemID: "owner-audio-item",
                sourceTurnFinalized: true,
                wantsAwake: true,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "a retired native tool became durable"
        )
        try expect(
            !DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
                callConnectionID: oldConnection,
                activeConnectionID: newConnection,
                durableDelegate: true,
                wantsAwake: false,
                sourceLogicalSessionID: session,
                currentLogicalSessionID: session
            ),
            "Rest did not revoke transport durability"
        )
        try expect(
            !DelegateTaskTransportPolicy.mayExecuteAcrossTransportBoundary(
                callConnectionID: oldConnection,
                activeConnectionID: newConnection,
                durableDelegate: true,
                wantsAwake: true,
                sourceLogicalSessionID: "prior-wake",
                currentLogicalSessionID: "new-wake"
            ),
            "a prior wake session leaked a delegate into a new wake"
        )

        let payload = try JSONSerialization.data(
            withJSONObject: ["ok": true, "checks": checks],
            options: [.sortedKeys]
        )
        print(String(decoding: payload, as: UTF8.self))
    }
}
