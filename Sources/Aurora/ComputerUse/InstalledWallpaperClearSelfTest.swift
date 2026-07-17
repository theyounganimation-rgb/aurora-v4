import AppKit
import Foundation

/// Opt-in, installed-and-signed proof for the exact compound task that failed
/// during the demo preflight. Paths arrive through environment variables so
/// no personal filesystem location is compiled into the distributed app.
enum InstalledWallpaperClearSelfTest {
    struct Report: Codable {
        let ok: Bool
        let status: String
        let steps: Int
        let wallpaperApplied: Bool
        let desktopCleared: Bool
        let failure: String?
    }

    private actor ReceiptStore {
        private var value: NativeDesktopActionResult?
        func set(_ receipt: NativeDesktopActionResult) { value = receipt }
        func get() -> NativeDesktopActionResult? { value }
    }

    static func run() async -> Report {
        let environment = ProcessInfo.processInfo.environment
        guard let targetPath = environment["AURORA_WALLPAPER_TEST_TARGET"],
              let baselinePath = environment["AURORA_WALLPAPER_TEST_BASELINE"] else {
            return failed("missing_test_paths")
        }
        let target = URL(fileURLWithPath: targetPath).standardizedFileURL
        let baseline = URL(fileURLWithPath: baselinePath).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: target.path),
              FileManager.default.isReadableFile(atPath: baseline.path) else {
            return failed("test_image_missing")
        }

        do {
            try await setWallpaper(baseline)
            let baselineApplied = await wallpaperMatches(baseline)
            guard baselineApplied else { return failed("baseline_not_applied") }

            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            try await Task.sleep(for: .milliseconds(800))

            guard let apiKey = try KeychainVoiceKey.load() else {
                return failed("missing_key")
            }
            let receipts = ReceiptStore()
            let nativeControl = NativeDesktopControl()
            let coordinator = DesktopTaskCoordinator(
                finalNativeActionHandler: { action in
                    let receipt: NativeDesktopActionResult
                    switch action {
                    case .minimizeEverything:
                        receipt = try await nativeControl.perform(action: .minimizeEverything)
                    }
                    await receipts.set(receipt)
                    return receipt
                }
            )
            await coordinator.configure(apiKey: apiKey)
            let started = try await coordinator.start(
                goal: "Use the selected blue motion image in the visible Finder window as the desktop wallpaper. Do not open the image. After the wallpaper is visibly set, finish the visual task; the trusted native final step will clear the screen.",
                successCriteria: "The selected blue motion image is visibly set as the Mac desktop wallpaper.",
                finalNativeAction: .minimizeEverything,
                sessionID: "installed-wallpaper-clear-self-test"
            )

            let deadline = Date().addingTimeInterval(180)
            var terminal: DesktopTaskSnapshot?
            while Date() < deadline {
                if let current = await coordinator.status(taskID: started.taskID),
                   current.status.isTerminal {
                    terminal = current
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            if terminal == nil {
                terminal = try? await coordinator.cancel(taskID: started.taskID)
            }
            let wallpaperApplied = await waitForWallpaper(target, timeout: 4)
            let finalReceipt = await receipts.get()
            let desktopCleared = finalReceipt.map(
                DesktopTaskCoordinator.finalNativeReceiptIsVerified
            ) ?? false
            await coordinator.shutdown()
            let status = terminal?.status ?? .failed
            let ok = status == .completed && wallpaperApplied && desktopCleared
            return Report(
                ok: ok,
                status: status.rawValue,
                steps: terminal?.stepCount ?? 0,
                wallpaperApplied: wallpaperApplied,
                desktopCleared: desktopCleared,
                failure: ok ? nil : (terminal?.failureCode ?? "postcondition_missing")
            )
        } catch let error as ComputerUseClientError {
            return failed(clientErrorCode(error))
        } catch {
            return failed("wallpaper_clear_test_failed")
        }
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func setWallpaper(_ url: URL) async throws {
        try await MainActor.run {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
            }
        }
    }

    private static func wallpaperMatches(_ url: URL) async -> Bool {
        await MainActor.run {
            !NSScreen.screens.isEmpty && NSScreen.screens.allSatisfy { screen in
                NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == url
            }
        }
    }

    private static func waitForWallpaper(_ url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await wallpaperMatches(url) { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await wallpaperMatches(url)
    }

    private static func failed(_ code: String) -> Report {
        Report(
            ok: false,
            status: "failed",
            steps: 0,
            wallpaperApplied: false,
            desktopCleared: false,
            failure: String(code.prefix(160))
        )
    }

    private static func clientErrorCode(_ error: ComputerUseClientError) -> String {
        switch error {
        case .api(_, let code, let type, _): return code ?? type ?? "api_rejected"
        case .transportFailed: return "transport_or_timeout"
        default: return String(describing: error)
        }
    }
}
