import AppKit
import CoreGraphics
import Foundation

enum InstalledComputerUseEndToEndSelfTest {
    struct Report: Codable {
        let ok: Bool
        let status: String
        let steps: Int
        let visibleEffectObserved: Bool
        let failure: String?
    }

    private static let readyTitle = "AURORA_CUA_READY"
    private static let clickedTitle = "AURORA_CUA_CLICKED"
    private static let targetVideoTitle = "Violet Observatory: Signals Beneath Europa"

    static func run() async -> Report {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-computer-use-live-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("chrome-profile", isDirectory: true)
        let page = root.appendingPathComponent("fixture.html")
        let chrome = Process()
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let html = """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <title>\(readyTitle)</title>
              <style>
                :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
                * { box-sizing: border-box; }
                body { margin: 0; min-width: 760px; min-height: 620px; background: #0f0f0f; color: #f1f1f1; }
                button, input { font: inherit; }
                .topbar { position: fixed; z-index: 3; inset: 0 0 auto 0; height: 64px; display: flex; align-items: center; gap: 22px; padding: 0 24px; background: #0f0f0f; border-bottom: 1px solid #272727; }
                .brand { display: flex; align-items: center; gap: 9px; min-width: 188px; font-size: 20px; font-weight: 700; letter-spacing: -0.4px; }
                .brand-mark { width: 31px; height: 22px; display: grid; place-items: center; border-radius: 7px; background: #ff0033; color: white; font-size: 12px; }
                .search { flex: 1; max-width: 640px; height: 40px; border: 1px solid #303030; border-radius: 22px; background: #121212; color: #aaa; padding: 9px 18px; }
                .avatar { width: 34px; height: 34px; border-radius: 50%; display: grid; place-items: center; background: #6543d7; font-weight: 700; }
                .sidebar { position: fixed; z-index: 2; left: 0; top: 64px; bottom: 0; width: 210px; padding: 18px 12px; background: #0f0f0f; border-right: 1px solid #242424; }
                .nav-item { width: 100%; height: 44px; margin-bottom: 4px; padding: 0 14px; border: 0; border-radius: 11px; background: transparent; color: #eee; text-align: left; cursor: pointer; }
                .nav-item:hover, .nav-item.active { background: #272727; }
                main { margin-left: 210px; padding: 86px 26px 32px; }
                .chips { display: flex; gap: 10px; margin-bottom: 22px; }
                .chip { padding: 8px 13px; border: 0; border-radius: 9px; background: #272727; color: #f1f1f1; }
                .chip.active { background: #f1f1f1; color: #111; }
                .grid { display: grid; grid-template-columns: repeat(3, minmax(190px, 1fr)); gap: 26px 18px; }
                .video-card { min-width: 0; padding: 0; border: 0; background: transparent; color: inherit; text-align: left; cursor: pointer; }
                .thumbnail { position: relative; width: 100%; aspect-ratio: 16/9; overflow: hidden; border-radius: 13px; background: linear-gradient(135deg, var(--a), var(--b)); }
                .thumbnail::after { content: attr(data-duration); position: absolute; right: 7px; bottom: 7px; padding: 3px 5px; border-radius: 4px; background: rgba(0,0,0,.82); color: white; font-size: 12px; font-weight: 650; }
                .thumb-art { position: absolute; inset: 0; display: grid; place-items: center; color: rgba(255,255,255,.92); font-size: 38px; font-weight: 800; text-shadow: 0 2px 12px rgba(0,0,0,.35); }
                .video-title { margin: 11px 2px 5px; min-height: 40px; font-size: 15px; line-height: 20px; font-weight: 650; }
                .meta { margin: 0 2px; color: #aaa; font-size: 13px; line-height: 18px; }
                .player { min-height: 470px; display: grid; place-items: center; border-radius: 18px; background: radial-gradient(circle at 48% 38%, #7d5cff, #171127 45%, #030305 78%); text-align: center; }
                .player h1 { max-width: 720px; margin: 0 24px 12px; font-size: 34px; }
                .player p { margin: 0; color: #c9c1e9; }
                @media (max-width: 960px) { .grid { grid-template-columns: repeat(2, minmax(210px, 1fr)); } .sidebar { width: 172px; } main { margin-left: 172px; } }
              </style>
            </head>
            <body>
              <header class="topbar">
                <div class="brand"><span class="brand-mark">▶</span><span>ViewTube</span></div>
                <input class="search" aria-label="Search" value="Search" readonly>
                <div class="avatar" aria-label="Profile">A</div>
              </header>
              <aside class="sidebar" aria-label="Navigation">
                <button class="nav-item active" onclick="decoy('Home')">⌂ &nbsp; Home</button>
                <button class="nav-item" onclick="decoy('Shorts')">◇ &nbsp; Shorts</button>
                <button class="nav-item" onclick="decoy('Subscriptions')">▣ &nbsp; Subscriptions</button>
                <button class="nav-item" onclick="decoy('History')">↶ &nbsp; History</button>
              </aside>
              <main id="content">
                <div class="chips" aria-label="Topic filters">
                  <button class="chip active" onclick="decoy('All filter')">All</button>
                  <button class="chip" onclick="decoy('Science filter')">Science</button>
                  <button class="chip" onclick="decoy('Music filter')">Music</button>
                </div>
                <section class="grid" aria-label="Recommended videos">
                  <button class="video-card" onclick="decoy('Rain video')" aria-label="Play Quiet Rain Through a Tokyo Window">
                    <div class="thumbnail" data-duration="1:02:18" style="--a:#164e63;--b:#111827"><span class="thumb-art">雨</span></div>
                    <div class="video-title">Quiet Rain Through a Tokyo Window</div>
                    <p class="meta">Night Rooms · 2.1M views</p>
                  </button>
                  <button class="video-card" id="aurora-target-video" onclick="selectTarget()" aria-label="Play \(targetVideoTitle)">
                    <div class="thumbnail" data-duration="18:42" style="--a:#6d28d9;--b:#172554"><span class="thumb-art">EUROPA</span></div>
                    <div class="video-title">\(targetVideoTitle)</div>
                    <p class="meta">Deep Sky Archive · 481K views</p>
                  </button>
                  <button class="video-card" onclick="decoy('Pasta video')" aria-label="Play Handmade Pasta in Bologna">
                    <div class="thumbnail" data-duration="12:09" style="--a:#9a3412;--b:#422006"><span class="thumb-art">PASTA</span></div>
                    <div class="video-title">Handmade Pasta in Bologna</div>
                    <p class="meta">Small Table · 930K views</p>
                  </button>
                  <button class="video-card" onclick="decoy('Piano video')" aria-label="Play Midnight Piano Session">
                    <div class="thumbnail" data-duration="34:26" style="--a:#1e293b;--b:#020617"><span class="thumb-art">PIANO</span></div>
                    <div class="video-title">Midnight Piano Session</div>
                    <p class="meta">Soft Signals · 1.7M views</p>
                  </button>
                  <button class="video-card" onclick="decoy('Iceland video')" aria-label="Play Crossing Iceland Without a Map">
                    <div class="thumbnail" data-duration="22:51" style="--a:#047857;--b:#164e63"><span class="thumb-art">NORTH</span></div>
                    <div class="video-title">Crossing Iceland Without a Map</div>
                    <p class="meta">Field Notes · 712K views</p>
                  </button>
                  <button class="video-card" onclick="decoy('Camera video')" aria-label="Play Restoring a 1960s Film Camera">
                    <div class="thumbnail" data-duration="16:03" style="--a:#7c2d12;--b:#292524"><span class="thumb-art">35mm</span></div>
                    <div class="video-title">Restoring a 1960s Film Camera</div>
                    <p class="meta">Workshop Light · 266K views</p>
                  </button>
                </section>
              </main>
              <script>
                function decoy(name) {
                  document.body.dataset.lastDecoy = name;
                }
                function selectTarget() {
                  document.title = '\(clickedTitle)';
                  document.getElementById('content').innerHTML = `
                    <section class="player" aria-label="Now playing \(targetVideoTitle)">
                      <div><h1>Now playing: \(targetVideoTitle)</h1><p>The requested video opened successfully.</p></div>
                    </section>`;
                }
              </script>
            </body>
            </html>
            """
            try Data(html.utf8).write(to: page, options: [.atomic])

            let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
                return failed("chrome_missing")
            }
            chrome.executableURL = chromeURL
            chrome.arguments = [
                "--new-window",
                "--user-data-dir=\(profile.path)",
                "--no-first-run",
                "--disable-default-apps",
                "--disable-extensions",
                page.absoluteString,
            ]
            chrome.standardOutput = FileHandle.nullDevice
            chrome.standardError = FileHandle.nullDevice
            try chrome.run()
            defer {
                if chrome.isRunning { chrome.terminate() }
            }
            guard await waitForWindowTitle(readyTitle, timeout: 15) else {
                return failed("fixture_window_missing")
            }

            guard let apiKey = try KeychainVoiceKey.load() else {
                return failed("missing_key")
            }
            let coordinator = DesktopTaskCoordinator()
            await coordinator.configure(apiKey: apiKey)
            let started = try await coordinator.start(
                goal: "In the YouTube-like Chrome window titled \(readyTitle), open the recommended video titled exactly \"\(targetVideoTitle)\". Do not click Home, Shorts, Subscriptions, History, topic filters, or a different video.",
                successCriteria: "The selected video visibly opens and the same Chrome window title reads exactly \(clickedTitle).",
                sessionID: "installed-computer-use-self-test"
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
            let effect = await waitForWindowTitle(clickedTitle, timeout: 3)
            await coordinator.shutdown()
            let status = terminal?.status ?? .failed
            return Report(
                ok: status == .completed && effect,
                status: status.rawValue,
                steps: terminal?.stepCount ?? 0,
                visibleEffectObserved: effect,
                failure: status == .completed && effect
                    ? nil
                    : (effect ? "task_not_completed" : "visible_effect_missing")
            )
        } catch let error as ComputerUseClientError {
            return failed(errorCode(error))
        } catch let error as MacDesktopEnvironmentError {
            return failed("native_\(String(describing: error).prefix(120))")
        } catch {
            return failed("end_to_end_failed")
        }
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func failed(_ code: String) -> Report {
        Report(
            ok: false,
            status: "failed",
            steps: 0,
            visibleEffectObserved: false,
            failure: String(code.prefix(160))
        )
    }

    private static func errorCode(_ error: ComputerUseClientError) -> String {
        switch error {
        case .api(_, let code, let type, _): return code ?? type ?? "api_rejected"
        case .transportFailed: return "transport_or_timeout"
        default: return String(describing: error)
        }
    }

    private static func waitForWindowTitle(_ title: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if visibleWindowTitles().contains(title) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return visibleWindowTitles().contains(title)
    }

    private static func visibleWindowTitles() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(list.compactMap { item in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let title = item[kCGWindowName as String] as? String,
                  !title.isEmpty else { return nil }
            return title
        })
    }
}

/// An opt-in installed-app check against YouTube's real UI. This is kept
/// separate from the deterministic fixture because the website can change,
/// but it proves the exact user-facing path when explicitly invoked.
enum InstalledYouTubeComputerUseSelfTest {
    struct Report: Codable {
        let ok: Bool
        let status: String
        let steps: Int
        let watchPageObserved: Bool
        let failure: String?
    }

    static func run() async -> Report {
        do {
            guard let youtube = URL(string: "https://www.youtube.com/") else {
                return failed("invalid_youtube_url")
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(youtube) }
            guard opened, await waitForYouTubePage(timeout: 20) else {
                return failed("youtube_page_missing")
            }
            guard let apiKey = try KeychainVoiceKey.load() else {
                return failed("missing_key")
            }

            let coordinator = DesktopTaskCoordinator()
            await coordinator.configure(apiKey: apiKey)
            let started = try await coordinator.start(
                goal: "On the visible YouTube home page in Google Chrome, click any one recommended video card in the main content grid. Do not click Home, Shorts, Subscriptions, a sidebar item, a topic filter, search, profile, or navigation.",
                successCriteria: "A YouTube watch page is visibly open and the browser address contains youtube.com/watch.",
                sessionID: "installed-youtube-live-self-test"
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
            let observed = await waitForWatchPage(timeout: 5)
            await coordinator.shutdown()
            let status = terminal?.status ?? .failed
            return Report(
                ok: status == .completed && observed,
                status: status.rawValue,
                steps: terminal?.stepCount ?? 0,
                watchPageObserved: observed,
                failure: status == .completed && observed
                    ? nil
                    : (terminal?.failureCode ?? (observed ? "task_not_completed" : "watch_page_missing"))
            )
        } catch let error as ComputerUseClientError {
            return failed(clientErrorCode(error))
        } catch {
            return failed("youtube_live_test_failed")
        }
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func failed(_ code: String) -> Report {
        Report(
            ok: false,
            status: "failed",
            steps: 0,
            watchPageObserved: false,
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

    private static func waitForYouTubePage(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await chromeHasURL(prefix: "https://www.youtube.com/") { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await chromeHasURL(prefix: "https://www.youtube.com/")
    }

    private static func waitForWatchPage(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await chromeHasURL(prefix: "https://www.youtube.com/watch") { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await chromeHasURL(prefix: "https://www.youtube.com/watch")
    }

    private static func chromeHasURL(prefix: String) async -> Bool {
        await MainActor.run {
            let source = #"""
            tell application "Google Chrome"
                if not running then return "false"
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        set candidateURL to URL of browserTab as text
                        if candidateURL starts with "\#(prefix)" then return "true"
                    end repeat
                end repeat
                return "false"
            end tell
            """#
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            return script.executeAndReturnError(&error).stringValue == "true" && error == nil
        }
    }
}
