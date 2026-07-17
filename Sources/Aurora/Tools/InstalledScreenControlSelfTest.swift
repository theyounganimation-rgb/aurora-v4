import AppKit
import CryptoKit
import Foundation
import ScreenCaptureKit

enum AuroraLaunchMode {
    static let screenControlSelfTest = CommandLine.arguments.contains("--screen-control-self-test")
    static let computerUseAPISelfTest = CommandLine.arguments.contains("--computer-use-api-self-test")
    static let computerUseEndToEndSelfTest = CommandLine.arguments.contains("--computer-use-end-to-end-self-test")
    static let chromeTabControlSelfTest = CommandLine.arguments.contains("--chrome-tab-control-self-test")
    static let youtubeLiveComputerUseSelfTest = CommandLine.arguments.contains("--youtube-live-computer-use-self-test")
    static let wallpaperClearSelfTest = CommandLine.arguments.contains("--wallpaper-clear-self-test")
    static let textEditWriteSelfTest = CommandLine.arguments.contains("--textedit-write-self-test")
    static let mediaControlSelfTest = CommandLine.arguments.contains("--media-control-self-test")
    static let closeTabEffectSelfTest = CommandLine.arguments.contains("--close-tab-effect-self-test")
    static let isSelfTest = screenControlSelfTest
        || computerUseAPISelfTest
        || computerUseEndToEndSelfTest
        || chromeTabControlSelfTest
        || youtubeLiveComputerUseSelfTest
        || wallpaperClearSelfTest
        || mediaControlSelfTest
        || textEditWriteSelfTest
        || closeTabEffectSelfTest
}

enum InstalledBuildIdentity {
    struct Values {
        let executablePath: String
        let executableSHA256: String
        let sourceFingerprint: String
    }

    static func current() -> Values {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executableSHA256: String
        if let data = try? Data(contentsOf: executableURL, options: .mappedIfSafe) {
            executableSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            executableSHA256 = "unreadable"
        }
        return Values(
            executablePath: executableURL.path,
            executableSHA256: executableSHA256,
            sourceFingerprint: Bundle.main.object(
                forInfoDictionaryKey: "AuroraSourceFingerprint"
            ) as? String ?? "missing"
        )
    }
}

enum InstalledMediaControlSelfTest {
    struct Report: Codable {
        let ok: Bool
        let durationMilliseconds: Int
        let fixtureProfileIsolated: Bool
        let resumeVerified: Bool
        let pauseVerified: Bool
        let desktopTaskStarted: Bool
        let failure: String?
    }

    static func run() async -> Report {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aurora-media-control-self-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let page = root.appendingPathComponent("media.html")
        let profile = root.appendingPathComponent("chrome-profile", isDirectory: true)
        let readyTitle = "AURORA_MEDIA_CONTROL_FIXTURE"
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(readyTitle)</title>
            <style>html,body{height:100%;margin:0;background:#10131a}body{display:grid;place-items:center}button{width:320px;height:180px;border:0;border-radius:28px;font:42px -apple-system}</style>
            </head><body><button id="media" aria-label="Play">Play</button>
            <script>const b=document.getElementById('media');b.addEventListener('click',()=>{const n=b.getAttribute('aria-label')==='Play'?'Pause':'Play';b.setAttribute('aria-label',n);b.textContent=n;});</script>
            </body></html>
            """
            try Data(html.utf8).write(to: page, options: .atomic)
        } catch {
            return failed("fixture_write_failed")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let chromeURL = URL(
            fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            return failed("chrome_missing")
        }
        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--user-data-dir=\(profile.path)",
            "--force-renderer-accessibility",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-extensions",
            "--use-mock-keychain",
            "--new-window",
            "--window-position=120,120",
            "--window-size=1000,700",
            page.absoluteString,
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        do {
            try chrome.run()
        } catch {
            return failed("chrome_launch_failed")
        }
        defer {
            if chrome.isRunning { chrome.terminate() }
        }
        guard await waitForWindow(
            processID: chrome.processIdentifier,
            title: readyTitle
        ) else {
            return failed("fixture_window_not_ready")
        }
        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: chrome.processIdentifier)?.activate(
                options: [.activateAllWindows]
            ) == true
        }
        guard activated else { return failed("fixture_activation_failed") }
        try? await Task.sleep(for: .milliseconds(350))

        let started = Date()
        let coordinator = DesktopTaskCoordinator()
        let auditURL = root.appendingPathComponent("tool-audit.jsonl")
        let registry = ToolRegistry(
            configuration: .init(auditURL: auditURL),
            commandApproval: { _ in false },
            desktopTaskCoordinator: coordinator
        )
        let resume = await registry.execute(
            name: "computer_action",
            argumentsJSON: #"{"action":"resume_current_media"}"#,
            context: ToolInvocationContext(
                callID: "installed-media-resume-self-test",
                sessionID: "installed-media-control-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Please resume the YouTube video.",
                ownerAudioItemID: "installed-media-resume-owner-audio"
            )
        )
        let pause = await registry.execute(
            name: "computer_action",
            argumentsJSON: #"{"action":"pause_current_media"}"#,
            context: ToolInvocationContext(
                callID: "installed-media-pause-self-test",
                sessionID: "installed-media-control-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Aurora, can you pause the video for me?",
                ownerAudioItemID: "installed-media-pause-owner-audio"
            )
        )
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1_000))
        let taskStarted = await coordinator.status() != nil
        let resumeVerified = resume.ok
            && resume.metadata["effect_verified"]?.boolValue == true
            && resume.metadata["desktop_action"]?.stringValue == "resume_current_media"
            && resume.metadata["affected_count"]?.intValue == 1
        let pauseVerified = pause.ok
            && pause.metadata["effect_verified"]?.boolValue == true
            && pause.metadata["desktop_action"]?.stringValue == "pause_current_media"
            && pause.metadata["affected_count"]?.intValue == 1
        try? FileManager.default.removeItem(at: auditURL)
        let failure: String?
        if !resume.ok {
            failure = String(resume.output.prefix(200))
        } else if !pause.ok {
            failure = String(pause.output.prefix(200))
        } else {
            failure = nil
        }
        return Report(
            ok: resumeVerified && pauseVerified && !taskStarted && elapsed < 4_000,
            durationMilliseconds: elapsed,
            fixtureProfileIsolated: true,
            resumeVerified: resumeVerified,
            pauseVerified: pauseVerified,
            desktopTaskStarted: taskStarted,
            failure: failure
        )
    }

    private static func failed(_ reason: String) -> Report {
        Report(
            ok: false,
            durationMilliseconds: 0,
            fixtureProfileIsolated: false,
            resumeVerified: false,
            pauseVerified: false,
            desktopTaskStarted: false,
            failure: reason
        )
    }

    private static func waitForWindow(processID: pid_t, title: String) async -> Bool {
        for _ in 0..<80 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ), content.windows.contains(where: {
                $0.owningApplication?.processID == processID
                    && ($0.title ?? "").contains(title)
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

enum InstalledTextEditWriteSelfTest {
    struct Report: Codable {
        let ok: Bool
        let durationMilliseconds: Int
        let effectVerified: Bool
        let desktopTaskStarted: Bool
        let failure: String?
    }

    static func run() async -> Report {
        let started = Date()
        let coordinator = DesktopTaskCoordinator()
        let auditURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aurora-textedit-self-test-\(UUID().uuidString).jsonl"
        )
        let registry = ToolRegistry(
            configuration: .init(auditURL: auditURL),
            commandApproval: { _ in false },
            desktopTaskCoordinator: coordinator
        )
        let result = await registry.execute(
            name: "computer_action",
            argumentsJSON: #"{"action":"write_textedit_document","text":"Voice is the interface."}"#,
            context: ToolInvocationContext(
                callID: "installed-textedit-write-self-test",
                sessionID: "installed-textedit-write-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Open a blank TextEdit document and type: Voice is the interface.",
                ownerAudioItemID: "installed-textedit-owner-audio"
            )
        )
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1_000))
        let taskStarted = await coordinator.status() != nil
        let effectVerified = result.metadata["effect_verified"]?.boolValue == true
        try? FileManager.default.removeItem(at: auditURL)
        return Report(
            ok: result.ok && effectVerified && !taskStarted && elapsed < 3_000,
            durationMilliseconds: elapsed,
            effectVerified: effectVerified,
            desktopTaskStarted: taskStarted,
            failure: result.ok ? nil : String(result.output.prefix(200))
        )
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

enum InstalledChromeTabControlSelfTest {
    struct Report: Codable {
        let ok: Bool
        let keptGmailTabs: Int
        let closedOtherTabs: Int
        let remainingOtherTabs: Int
        let failure: String?
    }

    static func run() async -> Report {
        do {
            let result = try await SystemChromeTabCloser().closeOtherTabsExceptGmail()
            return Report(
                ok: result.keptGmailTabs > 0 && result.remainingOtherTabs == 0,
                keptGmailTabs: result.keptGmailTabs,
                closedOtherTabs: result.closedOtherTabs,
                remainingOtherTabs: result.remainingOtherTabs,
                failure: nil
            )
        } catch let error as NativeDesktopControlError {
            return Report(
                ok: false,
                keptGmailTabs: 0,
                closedOtherTabs: 0,
                remainingOtherTabs: -1,
                failure: error.diagnosticCode
            )
        } catch {
            return Report(
                ok: false,
                keptGmailTabs: 0,
                closedOtherTabs: 0,
                remainingOtherTabs: -1,
                failure: "unexpected_failure"
            )
        }
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Installed-bundle proof for the exact close-current-tab path. The test owns a
/// unique Chrome process, profile, remote-debugging endpoint, and two local
/// pages. NativeDesktopControl is PID-scoped to that process, so the test cannot
/// select or close a tab from the owner's normal Chrome session.
enum InstalledCloseTabEffectSelfTest {
    struct Report: Codable {
        let ok: Bool
        let installedExecutable: String
        let executableSHA256: String
        let sourceFingerprint: String
        let fixtureProfileIsolated: Bool
        let preconditionTabCount: Int
        let postconditionTabCount: Int
        let closeTargetRemoved: Bool
        let keepTargetPreserved: Bool
        let toolReportedSuccess: Bool
        let toolReportedEffectVerified: Bool
        let durationMilliseconds: Int
        let failure: String?
    }

    private struct DevToolsTarget: Decodable {
        let id: String
        let title: String
        let url: String
        let type: String
    }

    private static let keepTitle = "AURORA_CLOSE_TAB_KEEP"
    private static let closeTitle = "AURORA_CLOSE_TAB_CLOSE"

    static func run() async -> Report {
        let started = Date()
        let identity = InstalledBuildIdentity.current()
        let environment = ProcessInfo.processInfo.environment
        let expectedExecutableSHA256 = environment["AURORA_EXPECTED_EXECUTABLE_SHA256"] ?? ""
        let expectedSourceFingerprint = environment["AURORA_EXPECTED_SOURCE_FINGERPRINT"] ?? ""
        let identityMatches = expectedExecutableSHA256.count == 64
            && expectedSourceFingerprint.count == 64
            && identity.executableSHA256 == expectedExecutableSHA256
            && identity.sourceFingerprint == expectedSourceFingerprint
        guard identityMatches else {
            return failed(
                identity: identity,
                started: started,
                code: "build_identity_mismatch"
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aurora-close-tab-effect-\(UUID().uuidString)",
            isDirectory: true
        )
        let profile = root.appendingPathComponent("chrome-profile", isDirectory: true)
        let keepPage = root.appendingPathComponent("keep.html")
        let closePage = root.appendingPathComponent("close.html")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("<!doctype html><title>\(keepTitle)</title><h1>Keep fixture tab</h1>".utf8)
                .write(to: keepPage, options: .atomic)
            try Data("<!doctype html><title>\(closeTitle)</title><h1>Close fixture tab</h1>".utf8)
                .write(to: closePage, options: .atomic)
        } catch {
            return failed(identity: identity, started: started, code: "fixture_write_failed")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let chromeURL = URL(
            fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            return failed(identity: identity, started: started, code: "chrome_missing")
        }

        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-port=0",
            "--new-window",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-sync",
            "--metrics-recording-only",
            "--no-service-autorun",
            "--use-mock-keychain",
            keepPage.absoluteString,
            closePage.absoluteString,
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        do {
            try chrome.run()
        } catch {
            return failed(identity: identity, started: started, code: "chrome_launch_failed")
        }
        defer {
            if chrome.isRunning {
                chrome.terminate()
            }
        }

        guard let port = await waitForDevToolsPort(profile: profile, timeout: 10) else {
            return failed(identity: identity, started: started, code: "devtools_port_missing")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let preconditionTargets = await waitForTargets(
            port: port,
            session: session,
            timeout: 12,
            condition: { targets in
                targets.contains { $0.title == keepTitle }
                    && targets.contains { $0.title == closeTitle }
            }
        ), let keepTarget = preconditionTargets.first(where: { $0.title == keepTitle }),
           let closeTarget = preconditionTargets.first(where: { $0.title == closeTitle }) else {
            return failed(identity: identity, started: started, code: "fixture_tabs_missing")
        }
        let fixtureTargetsBefore = preconditionTargets.filter {
            $0.id == keepTarget.id || $0.id == closeTarget.id
        }
        guard fixtureTargetsBefore.count == 2,
              await activate(targetID: closeTarget.id, port: port, session: session) else {
            return failed(identity: identity, started: started, code: "close_tab_activation_failed")
        }
        _ = await MainActor.run {
            NSRunningApplication(processIdentifier: chrome.processIdentifier)?.activate(
                options: [.activateAllWindows]
            )
        }
        guard await waitForWindowTitle(
            closeTitle,
            processID: chrome.processIdentifier,
            timeout: 5
        ) else {
            return failed(identity: identity, started: started, code: "close_tab_not_frontmost")
        }

        let registry = ToolRegistry(
            configuration: .init(auditURL: root.appendingPathComponent("tool-audit.jsonl")),
            commandApproval: { _ in false },
            desktopControl: NativeDesktopControl(
                onlyProcessIDs: Set([chrome.processIdentifier])
            )
        )
        let result = await registry.execute(
            name: "computer_action",
            arguments: ["action": .string(NativeDesktopAction.closeTab.rawValue)],
            context: ToolInvocationContext(
                callID: "installed-close-tab-effect-self-test",
                sessionID: "installed-close-tab-effect-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Awesome. Could you just close out the Chrome tab, please?",
                ownerAudioItemID: "installed-close-tab-owner-audio",
                participantIsOwner: true
            )
        )

        let postconditionTargets = await waitForTargets(
            port: port,
            session: session,
            timeout: 6,
            condition: { targets in
                !targets.contains { $0.id == closeTarget.id }
                    && targets.contains { $0.id == keepTarget.id }
            }
        ) ?? []
        let closeTargetRemoved = !postconditionTargets.contains { $0.id == closeTarget.id }
        let keepTargetPreserved = postconditionTargets.contains { $0.id == keepTarget.id }
        let fixtureTargetsAfter = postconditionTargets.filter {
            $0.id == keepTarget.id || $0.id == closeTarget.id
        }
        let toolReportedEffectVerified = result.metadata["effect_verified"]?.boolValue == true
        let toolReportedSuccess = result.ok
            && result.metadata["desktop_action"]?.stringValue
                == NativeDesktopAction.closeTab.rawValue
        let ok = toolReportedSuccess
            && toolReportedEffectVerified
            && closeTargetRemoved
            && keepTargetPreserved
            && fixtureTargetsAfter.count == 1
        return Report(
            ok: ok,
            installedExecutable: identity.executablePath,
            executableSHA256: identity.executableSHA256,
            sourceFingerprint: identity.sourceFingerprint,
            fixtureProfileIsolated: profile.path.hasPrefix(root.path + "/"),
            preconditionTabCount: fixtureTargetsBefore.count,
            postconditionTabCount: fixtureTargetsAfter.count,
            closeTargetRemoved: closeTargetRemoved,
            keepTargetPreserved: keepTargetPreserved,
            toolReportedSuccess: toolReportedSuccess,
            toolReportedEffectVerified: toolReportedEffectVerified,
            durationMilliseconds: elapsedMilliseconds(since: started),
            failure: ok ? nil : "close_tab_postcondition_failed"
        )
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func waitForDevToolsPort(
        profile: URL,
        timeout: TimeInterval
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        let file = profile.appendingPathComponent("DevToolsActivePort")
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               let firstLine = contents.split(whereSeparator: \.isNewline).first,
               let port = Int(firstLine) {
                return port
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func waitForTargets(
        port: Int,
        session: URLSession,
        timeout: TimeInterval,
        condition: ([DevToolsTarget]) -> Bool
    ) async -> [DevToolsTarget]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let targets = try? await targets(port: port, session: session),
               condition(targets) {
                return targets
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func targets(port: Int, session: URLSession) async throws
        -> [DevToolsTarget] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([DevToolsTarget].self, from: data).filter {
            $0.type == "page"
        }
    }

    private static func activate(
        targetID: String,
        port: Int,
        session: URLSession
    ) async -> Bool {
        guard let encodedID = targetID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "http://127.0.0.1:\(port)/json/activate/\(encodedID)") else {
            return false
        }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func waitForWindowTitle(
        _ title: String,
        processID: pid_t,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ), content.windows.contains(where: {
                $0.owningApplication?.processID == processID
                    && ($0.title ?? "").contains(title)
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func failed(
        identity: InstalledBuildIdentity.Values,
        started: Date,
        code: String
    ) -> Report {
        Report(
            ok: false,
            installedExecutable: identity.executablePath,
            executableSHA256: identity.executableSHA256,
            sourceFingerprint: identity.sourceFingerprint,
            fixtureProfileIsolated: false,
            preconditionTabCount: 0,
            postconditionTabCount: 0,
            closeTargetRemoved: false,
            keepTargetPreserved: false,
            toolReportedSuccess: false,
            toolReportedEffectVerified: false,
            durationMilliseconds: elapsedMilliseconds(since: started),
            failure: String(code.prefix(160))
        )
    }

    private static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

enum InstalledScreenControlSelfTest {
    struct CaseResult: Codable {
        let name: String
        let passed: Bool
        let normalizedX: Int?
        let normalizedY: Int?
        let clickMethod: String?
        let reason: String?
    }

    struct Report: Codable {
        let ok: Bool
        let installedExecutable: String
        let screenCaptureAllowed: Bool
        let accessibilityAllowed: Bool
        let pointerControlAllowed: Bool
        let cases: [CaseResult]
    }

    private struct FixtureCase {
        let name: String
        let readyTitle: String
        let clickedTitle: String
        let targetDescription: String
        let html: String
    }

    static func run() async -> Report {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-installed-screen-control-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return Report(
                ok: false,
                installedExecutable: executable,
                screenCaptureAllowed: false,
                accessibilityAllowed: false,
                pointerControlAllowed: false,
                cases: [CaseResult(
                    name: "setup",
                    passed: false,
                    normalizedX: nil,
                    normalizedY: nil,
                    clickMethod: nil,
                    reason: "fixture_directory_failed"
                )]
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let screenControl = NativeScreenControl()
        let permissions = await screenControl.permissionStatus()
        guard permissions.canLook, permissions.canClick else {
            return Report(
                ok: false,
                installedExecutable: executable,
                screenCaptureAllowed: permissions.screenCaptureAllowed,
                accessibilityAllowed: permissions.accessibilityAllowed,
                pointerControlAllowed: permissions.pointerControlAllowed,
                cases: []
            )
        }

        let registry = ToolRegistry(
            configuration: .init(auditURL: root.appendingPathComponent("tool-audit.jsonl")),
            commandApproval: { _ in false },
            screenControl: screenControl
        )
        var results: [CaseResult] = []
        for fixture in fixtures {
            results.append(await runCase(
                fixture,
                root: root,
                registry: registry,
                screenControl: screenControl
            ))
        }
        results.append(await verifyDirectMinimizeEverything(root: root))
        results.append(await verifyCurrentYouTubeSelection(root: root, registry: registry))
        return Report(
            ok: results.allSatisfy(\.passed),
            installedExecutable: executable,
            screenCaptureAllowed: permissions.screenCaptureAllowed,
            accessibilityAllowed: permissions.accessibilityAllowed,
            pointerControlAllowed: permissions.pointerControlAllowed,
            cases: results
        )
    }

    static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func runCase(
        _ fixture: FixtureCase,
        root: URL,
        registry: ToolRegistry,
        screenControl: NativeScreenControl
    ) async -> CaseResult {
        let htmlURL = root.appendingPathComponent(fixture.name + ".html")
        let profileURL = root.appendingPathComponent("chrome-" + fixture.name, isDirectory: true)
        do {
            try Data(fixture.html.utf8).write(to: htmlURL, options: .atomic)
        } catch {
            return failed(fixture.name, "fixture_write_failed")
        }

        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            return failed(fixture.name, "chrome_missing")
        }

        let process = Process()
        process.executableURL = chromeURL
        process.arguments = [
            "--user-data-dir=" + profileURL.path,
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-extensions",
            "--new-window",
            "--window-position=80,80",
            "--window-size=1200,850",
            htmlURL.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return failed(fixture.name, "chrome_launch_failed")
        }
        defer {
            if process.isRunning { process.terminate() }
        }

        guard await waitForWindow(processID: process.processIdentifier, title: fixture.readyTitle) else {
            return failed(fixture.name, "fixture_window_not_ready")
        }
        _ = await MainActor.run {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(
                options: [.activateAllWindows]
            )
        }
        try? await Task.sleep(for: .milliseconds(250))

        let mistranscribedOwnerAudio = fixture.name == "mistranscribed_owner_audio"
        if !mistranscribedOwnerAudio {
            return await runDirectScreenControlCase(
                fixture,
                processID: process.processIdentifier,
                screenControl: screenControl
            )
        }

        let transcript = "It's like a random video."
        let ownerAudioItemID = "item_installed_self_test_owner_audio"
        let look = await registry.execute(
            name: "computer_visual",
            arguments: [
                "action": .string("look"),
                "scope": .string("ordinary"),
            ],
            context: ToolInvocationContext(
                callID: "self-test-look-" + fixture.name,
                sessionID: "installed-screen-control-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: transcript,
                ownerAudioItemID: ownerAudioItemID,
                audioCorroborated: true
            )
        )
        guard look.ok, let view = look.visualContext else {
            return failed(fixture.name, "visual_capture_failed")
        }
        guard view.instruction.contains(fixture.readyTitle) else {
            return failed(fixture.name, "dominant_window_not_selected")
        }
        guard
              let point = locateMagentaTarget(in: view.imageDataURL) else {
            return failed(fixture.name, "visual_target_not_found")
        }

        let click = await registry.execute(
            name: "computer_visual",
            arguments: [
                "action": .string("click"),
                "snapshot_id": .string(view.snapshotID),
                "x": .integer(point.x),
                "y": .integer(point.y),
                "target": .string(fixture.targetDescription),
                "scope": .string("ordinary"),
            ],
            context: ToolInvocationContext(
                callID: "self-test-click-" + fixture.name,
                sessionID: "installed-screen-control-self-test",
                origin: "aurora_native_realtime_visual",
                latestUserTranscript: transcript,
                ownerAudioItemID: ownerAudioItemID,
                audioCorroborated: true
            )
        )
        let titleChanged = await waitForWindow(
            processID: process.processIdentifier,
            title: fixture.clickedTitle
        )
        let method = click.metadata["click_method"]?.stringValue
        let acceptedMethods = [
            NativeScreenClickMethod.accessibilityPress.rawValue,
            NativeScreenClickMethod.accessibilityResolvedPointer.rawValue,
            NativeScreenClickMethod.coreGraphicsPointer.rawValue,
        ]
        guard click.ok,
              click.metadata["external_side_effect"]?.boolValue == true,
              method.map(acceptedMethods.contains) == true,
              titleChanged else {
            return CaseResult(
                name: fixture.name,
                passed: false,
                normalizedX: point.x,
                normalizedY: point.y,
                clickMethod: method,
                reason: titleChanged ? "click_result_failed" : "visible_title_unchanged"
            )
        }
        return CaseResult(
            name: fixture.name,
            passed: true,
            normalizedX: point.x,
            normalizedY: point.y,
            clickMethod: method,
            reason: nil
        )
    }

    /// Proves the installed executable can capture and actuate the actual
    /// macOS surface. Voice routing is verified separately; routing a normal
    /// click fixture through ToolRegistry would intentionally start the
    /// Computer Use coordinator and would not be a screen-control primitive
    /// test at all.
    private static func runDirectScreenControlCase(
        _ fixture: FixtureCase,
        processID: pid_t,
        screenControl: NativeScreenControl
    ) async -> CaseResult {
        do {
            try await screenControl.prepareForClick()
            let snapshot = try await screenControl.captureFrontmostWindow(
                authorization: .ordinary
            )
            guard snapshot.processID == processID,
                  snapshot.windowTitle.contains(fixture.readyTitle) else {
                return failed(fixture.name, "fixture_window_not_selected")
            }
            guard let point = locateMagentaTarget(in: snapshot.imageDataURI) else {
                return failed(fixture.name, "visual_target_not_found")
            }
            let receipt = try await screenControl.click(
                snapshotID: snapshot.snapshotID,
                normalizedX: point.x,
                normalizedY: point.y,
                targetDescription: fixture.targetDescription,
                authorization: .ordinary
            )
            let titleChanged = await waitForWindow(
                processID: processID,
                title: fixture.clickedTitle
            )
            guard titleChanged else {
                return CaseResult(
                    name: fixture.name,
                    passed: false,
                    normalizedX: point.x,
                    normalizedY: point.y,
                    clickMethod: receipt.method.rawValue,
                    reason: "visible_title_unchanged"
                )
            }
            return CaseResult(
                name: fixture.name,
                passed: true,
                normalizedX: point.x,
                normalizedY: point.y,
                clickMethod: receipt.method.rawValue,
                reason: nil
            )
        } catch let error as NativeScreenControlError {
            return failed(fixture.name, error.diagnosticCode)
        } catch {
            return failed(fixture.name, "unexpected_screen_control_failure")
        }
    }

    private static func waitForWindow(processID: pid_t, title: String) async -> Bool {
        for _ in 0..<80 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ), content.windows.contains(where: {
                $0.owningApplication?.processID == processID
                    && ($0.title ?? "").contains(title)
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func verifyDirectMinimizeEverything(root: URL) async -> CaseResult {
        let htmlURL = root.appendingPathComponent("direct-minimize-everything-a.html")
        let secondHTMLURL = root.appendingPathComponent("direct-minimize-everything-b.html")
        let profileURL = root.appendingPathComponent("chrome-direct-minimize-everything-a", isDirectory: true)
        let secondProfileURL = root.appendingPathComponent("chrome-direct-minimize-everything-b", isDirectory: true)
        let readyTitle = "AURORA_TEST_READY_DIRECT_MINIMIZE_EVERYTHING_A"
        let secondReadyTitle = "AURORA_TEST_READY_DIRECT_MINIMIZE_EVERYTHING_B"
        do {
            try Data("<!doctype html><title>\(readyTitle)</title><body>Direct global minimize test A</body>".utf8)
                .write(to: htmlURL, options: .atomic)
            try Data("<!doctype html><title>\(secondReadyTitle)</title><body>Direct global minimize test B</body>".utf8)
                .write(to: secondHTMLURL, options: .atomic)
        } catch {
            return failed("direct_minimize_everything", "fixture_write_failed")
        }
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            return failed("direct_minimize_everything", "chrome_missing")
        }
        let process = Process()
        process.executableURL = chromeURL
        process.arguments = [
            "--user-data-dir=" + profileURL.path,
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-extensions",
            "--new-window",
            "--window-position=120,120",
            "--window-size=1000,720",
            htmlURL.absoluteString,
        ]
        let secondProcess = Process()
        secondProcess.executableURL = chromeURL
        secondProcess.arguments = [
            "--user-data-dir=" + secondProfileURL.path,
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-extensions",
            "--new-window",
            "--window-position=240,180",
            "--window-size=900,640",
            secondHTMLURL.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        secondProcess.standardOutput = FileHandle.nullDevice
        secondProcess.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try secondProcess.run()
        } catch {
            if process.isRunning { process.terminate() }
            return failed("direct_minimize_everything", "chrome_launch_failed")
        }
        defer {
            if process.isRunning { process.terminate() }
            if secondProcess.isRunning { secondProcess.terminate() }
        }
        guard await waitForWindow(processID: process.processIdentifier, title: readyTitle),
              await waitForWindow(processID: secondProcess.processIdentifier, title: secondReadyTitle) else {
            return failed("direct_minimize_everything", "fixture_window_not_ready")
        }

        let scopedRegistry = ToolRegistry(
            configuration: .init(
                auditURL: root.appendingPathComponent("global-minimize-tool-audit.jsonl")
            ),
            commandApproval: { _ in false },
            desktopControl: NativeDesktopControl(
                onlyProcessIDs: Set([process.processIdentifier, secondProcess.processIdentifier])
            )
        )
        let result = await scopedRegistry.execute(
            name: "computer_action",
            arguments: ["action": .string(NativeDesktopAction.minimizeEverything.rawValue)],
            context: ToolInvocationContext(
                callID: "self-test-direct-minimize-everything",
                sessionID: "installed-screen-control-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Minimize everything on my Mac so I can see my wallpaper.",
                ownerAudioItemID: "owner-audio-direct-minimize-everything"
            )
        )
        var bothMinimized = false
        for _ in 0..<30 {
            let firstVisible = await waitForWindowOnce(
                processID: process.processIdentifier,
                title: readyTitle
            )
            let secondVisible = await waitForWindowOnce(
                processID: secondProcess.processIdentifier,
                title: secondReadyTitle
            )
            if !firstVisible, !secondVisible {
                bothMinimized = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard result.ok,
              result.metadata["external_side_effect"]?.boolValue == true,
              result.metadata["effect_verified"]?.boolValue == true,
              (result.metadata["affected_count"]?.intValue ?? 0) >= 2,
              (result.metadata["application_count"]?.intValue ?? 0) >= 2,
              result.metadata["remaining_visible_count"]?.intValue == 0,
              bothMinimized else {
            return failed(
                "direct_minimize_everything",
                bothMinimized ? "action_receipt_failed" : "fixture_window_still_visible"
            )
        }

        // Reproduce the live regression as one sequence, not two isolated
        // component checks: an already-running application whose windows were
        // just minimized must be restored by activate_application. The old
        // implementation called NSRunningApplication.activate once and left
        // every window in the Dock.
        let activation = await scopedRegistry.execute(
            name: "computer_action",
            arguments: [
                "action": .string(NativeDesktopAction.activateApplication.rawValue),
                "application": .string("Google Chrome"),
            ],
            context: ToolInvocationContext(
                callID: "self-test-reactivate-after-minimize",
                sessionID: "installed-screen-control-self-test",
                origin: "aurora_native_realtime_voice",
                latestUserTranscript: "Bring up Chrome.",
                ownerAudioItemID: "owner-audio-reactivate-after-minimize"
            )
        )
        var restoredVisibleWindow = false
        for _ in 0..<35 {
            let firstVisible = await waitForWindowOnce(
                processID: process.processIdentifier,
                title: readyTitle
            )
            let secondVisible = await waitForWindowOnce(
                processID: secondProcess.processIdentifier,
                title: secondReadyTitle
            )
            if firstVisible || secondVisible {
                restoredVisibleWindow = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard activation.ok,
              activation.metadata["desktop_action"]?.stringValue
                == NativeDesktopAction.activateApplication.rawValue,
              activation.metadata["effect_verified"]?.boolValue == true,
              activation.metadata["native_fallback_to_visual"]?.boolValue != true,
              restoredVisibleWindow else {
            return failed(
                "direct_minimize_everything",
                restoredVisibleWindow
                    ? "reactivation_receipt_failed"
                    : "reactivation_window_still_minimized"
            )
        }
        return CaseResult(
            name: "direct_minimize_everything",
            passed: true,
            normalizedX: nil,
            normalizedY: nil,
            clickMethod: "native_desktop_action",
            reason: nil
        )
    }

    private static func waitForWindowOnce(processID: pid_t, title: String) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) else { return true }
        return content.windows.contains {
            $0.owningApplication?.processID == processID
                && ($0.title ?? "").contains(title)
        }
    }

    private static func verifyCurrentYouTubeSelection(
        root: URL,
        registry: ToolRegistry
    ) async -> CaseResult {
        let title = "YouTube - AURORA_TEST_ISOLATED_SELECTION"
        let page = root.appendingPathComponent("isolated-youtube-selection.html")
        let profile = root.appendingPathComponent(
            "chrome-isolated-youtube-selection",
            isDirectory: true
        )
        do {
            try Data("<!doctype html><title>\(title)</title><h1>YouTube fixture</h1>".utf8)
                .write(to: page, options: .atomic)
        } catch {
            return failed("current_youtube_selection", "fixture_write_failed")
        }
        let chromeURL = URL(
            fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            return failed("current_youtube_selection", "chrome_missing")
        }
        let process = Process()
        process.executableURL = chromeURL
        process.arguments = [
            "--user-data-dir=" + profile.path,
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-extensions",
            "--new-window",
            "--window-position=100,100",
            "--window-size=1100,760",
            page.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return failed("current_youtube_selection", "chrome_launch_failed")
        }
        defer {
            if process.isRunning { process.terminate() }
        }
        guard await waitForWindow(processID: process.processIdentifier, title: title) else {
            return failed("current_youtube_selection", "fixture_window_missing")
        }

        _ = await MainActor.run {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(
                options: [.activateAllWindows]
            )
        }
        try? await Task.sleep(for: .milliseconds(250))
        await registry.invalidateEphemeralControl()
        let transcript = "What do you see on the YouTube screen?"
        let look = await registry.execute(
            name: "computer_visual",
            arguments: [
                "action": .string("look"),
                "scope": .string("ordinary"),
            ],
            context: ToolInvocationContext(
                callID: "self-test-current-youtube-look",
                sessionID: "installed-screen-control-self-test",
                origin: "installed_screen_control_self_test",
                latestUserTranscript: transcript
            )
        )
        guard look.ok, let view = look.visualContext else {
            return failed("current_youtube_selection", "visual_capture_failed")
        }
        guard view.instruction.localizedCaseInsensitiveContains("window="),
              view.instruction.localizedCaseInsensitiveContains(
                "aurora_test_isolated_selection"
              ) else {
            return failed("current_youtube_selection", "dominant_youtube_window_not_selected")
        }
        return CaseResult(
            name: "current_youtube_selection",
            passed: true,
            normalizedX: nil,
            normalizedY: nil,
            clickMethod: "selection_only",
            reason: nil
        )
    }

    private static func locateMagentaTarget(in dataURL: String) -> (x: Int, y: Int)? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else { return nil }

        var sumX = 0.0
        var sumY = 0.0
        var count = 0.0
        let step = 3
        let minY = bitmap.pixelsHigh / 8
        for y in stride(from: minY, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.72,
                   color.greenComponent < 0.46,
                   color.blueComponent > 0.48 {
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }
        guard count >= 120 else { return nil }
        return (
            x: min(1_000, max(0, Int((sumX / count / Double(bitmap.pixelsWide) * 1_000).rounded()))),
            y: min(1_000, max(0, Int((sumY / count / Double(bitmap.pixelsHigh) * 1_000).rounded())))
        )
    }

    private static func failed(_ name: String, _ reason: String) -> CaseResult {
        CaseResult(
            name: name,
            passed: false,
            normalizedX: nil,
            normalizedY: nil,
            clickMethod: nil,
            reason: reason
        )
    }

    private static var fixtures: [FixtureCase] {
        [
            fixture(
                name: "button",
                ready: "AURORA_TEST_READY_BUTTON",
                clicked: "AURORA_TEST_CLICKED_BUTTON",
                left: 28,
                top: 34,
                markup: #"<button class="target" onclick="document.title='AURORA_TEST_CLICKED_BUTTON'">Aurora visual test target</button>"#
            ),
            fixture(
                name: "nested_thumbnail",
                ready: "AURORA_TEST_READY_NESTED",
                clicked: "AURORA_TEST_CLICKED_NESTED",
                left: 70,
                top: 48,
                markup: #"<a class="target" href="javascript:void(0)" onclick="document.title='AURORA_TEST_CLICKED_NESTED'"><span class="thumb"><span>Aurora nested video thumbnail</span></span></a>"#
            ),
            fixture(
                name: "canvas",
                ready: "AURORA_TEST_READY_CANVAS",
                clicked: "AURORA_TEST_CLICKED_CANVAS",
                left: 48,
                top: 70,
                markup: #"<canvas id="target" class="target" width="340" height="190" aria-label="Aurora visual test target"></canvas><script>const c=document.getElementById('target');const g=c.getContext('2d');g.fillStyle='#ff3da5';g.fillRect(0,0,c.width,c.height);c.addEventListener('click',()=>document.title='AURORA_TEST_CLICKED_CANVAS');</script>"#
            ),
            fixture(
                name: "mistranscribed_owner_audio",
                ready: "AURORA_TEST_READY_MISTRANSCRIBED",
                clicked: "AURORA_TEST_CLICKED_MISTRANSCRIBED",
                left: 56,
                top: 58,
                markup: #"<button class="target" onclick="document.title='AURORA_TEST_CLICKED_MISTRANSCRIBED'">Aurora mistranscribed owner audio target</button>"#
            ),
            fixture(
                name: "youtube_semantic_title",
                ready: "AURORA_TEST_READY_YOUTUBE_SEMANTIC",
                clicked: "AURORA_TEST_CLICKED_YOUTUBE_SEMANTIC",
                left: 56,
                top: 48,
                targetDescription: "Aurora Semantic YouTube Video Title",
                markup: #"<div class="target"><span>video thumbnail</span></div><a class="semantic-title" href="javascript:void(0)" onclick="document.title='AURORA_TEST_CLICKED_YOUTUBE_SEMANTIC'">Aurora Semantic YouTube Video Title</a>"#
            ),
        ]
    }

    private static func fixture(
        name: String,
        ready: String,
        clicked: String,
        left: Int,
        top: Int,
        targetDescription: String = "Aurora visual test target",
        markup: String
    ) -> FixtureCase {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(ready)</title>
        <style>
        html,body{width:100%;height:100%;margin:0;background:#111827;overflow:hidden}
        .target{position:fixed;left:\(left)%;top:\(top)%;transform:translate(-50%,-50%);width:340px;height:190px;border:0;border-radius:20px;background:#ff3da5;color:white;font:700 24px system-ui;display:flex;align-items:center;justify-content:center;text-decoration:none;cursor:pointer;box-sizing:border-box}
        .thumb{width:100%;height:100%;display:flex;align-items:center;justify-content:center}
        .semantic-title{position:fixed;left:(left)%;top:calc((top)% + 125px);transform:translateX(-50%);width:340px;color:white;font:600 20px system-ui;text-decoration:none}
        </style></head><body>\(markup)</body></html>
        """
        return FixtureCase(
            name: name,
            readyTitle: ready,
            clickedTitle: clicked,
            targetDescription: targetDescription,
            html: html
        )
    }
}
