import AppKit
import Foundation

@MainActor
final class ApprovalCenter {
    private var activeID: UUID?
    private var activeAlert: NSAlert?
    private var activeContinuation: CheckedContinuation<Bool, Never>?

    func request(command: String, reason: String) async -> Bool {
        // Multiple simultaneous shell proposals are intentionally denied. A
        // digital person should ask for one understandable action at a time.
        guard activeID == nil else { return false }
        let requestID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Aurora wants to act on this Mac"
                alert.informativeText = "\(reason)\n\n\(command)"
                alert.addButton(withTitle: "Allow once")
                alert.addButton(withTitle: "Not now")

                activeID = requestID
                activeAlert = alert
                activeContinuation = continuation
                NSApp.activate(ignoringOtherApps: true)

                if let window = NSApp.windows.first(where: {
                    !($0 is NSPanel) && $0.title == "Aurora" && $0.isVisible
                }) {
                    alert.beginSheetModal(for: window) { [weak self] response in
                        self?.finish(
                            requestID: requestID,
                            allowed: response == .alertFirstButtonReturn
                        )
                    }
                } else {
                    let allowed = alert.runModal() == .alertFirstButtonReturn
                    finish(requestID: requestID, allowed: allowed)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    private func cancel(requestID: UUID) {
        guard activeID == requestID else { return }
        if let alert = activeAlert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        finish(requestID: requestID, allowed: false)
    }

    private func finish(requestID: UUID, allowed: Bool) {
        guard activeID == requestID else { return }
        let continuation = activeContinuation
        activeID = nil
        activeAlert = nil
        activeContinuation = nil
        continuation?.resume(returning: allowed)
    }
}
