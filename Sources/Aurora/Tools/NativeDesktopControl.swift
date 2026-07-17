import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ChromeTabCloseResult: Sendable, Equatable {
    public let keptGmailTabs: Int
    public let closedOtherTabs: Int
    public let remainingOtherTabs: Int

    public init(keptGmailTabs: Int, closedOtherTabs: Int, remainingOtherTabs: Int) {
        self.keptGmailTabs = keptGmailTabs
        self.closedOtherTabs = closedOtherTabs
        self.remainingOtherTabs = remainingOtherTabs
    }
}

public protocol ChromeTabClosing: Sendable {
    func closeOtherTabsExceptGmail() async throws -> ChromeTabCloseResult
}

/// Uses Chrome's documented AppleScript tab objects instead of a transient
/// right-click menu. The script is fixed—no title, URL, or owner text is ever
/// interpolated into executable source—and verifies the postcondition itself.
public struct SystemChromeTabCloser: ChromeTabClosing {
    static let scriptSource = #"""
    on isGmailAddress(candidate)
        if candidate is missing value then return false
        set addressText to candidate as text
        return addressText is "https://mail.google.com" or addressText starts with "https://mail.google.com/" or addressText is "http://mail.google.com" or addressText starts with "http://mail.google.com/"
    end isGmailAddress

    tell application "Google Chrome"
        if not running then return "chrome_not_running"

        set gmailBefore to 0
        repeat with windowIndex from 1 to (count of windows)
            repeat with tabIndex from 1 to (count of tabs of window windowIndex)
                set candidateURL to URL of tab tabIndex of window windowIndex
                if my isGmailAddress(candidateURL) then set gmailBefore to gmailBefore + 1
            end repeat
        end repeat
        if gmailBefore is 0 then return "gmail_not_found"

        set closedCount to 0
        repeat with windowIndex from (count of windows) to 1 by -1
            set originalTabCount to count of tabs of window windowIndex
            repeat with tabIndex from originalTabCount to 1 by -1
                set candidateURL to URL of tab tabIndex of window windowIndex
                if not my isGmailAddress(candidateURL) then
                    close tab tabIndex of window windowIndex
                    set closedCount to closedCount + 1
                end if
            end repeat
        end repeat

        delay 0.2
        set gmailAfter to 0
        set otherAfter to 0
        set focusedGmail to false
        repeat with windowIndex from 1 to (count of windows)
            repeat with tabIndex from 1 to (count of tabs of window windowIndex)
                set candidateURL to URL of tab tabIndex of window windowIndex
                if my isGmailAddress(candidateURL) then
                    set gmailAfter to gmailAfter + 1
                    if not focusedGmail then
                        set active tab index of window windowIndex to tabIndex
                        set index of window windowIndex to 1
                        set focusedGmail to true
                    end if
                else
                    set otherAfter to otherAfter + 1
                end if
            end repeat
        end repeat
        activate
        return (gmailAfter as text) & "|" & (closedCount as text) & "|" & (otherAfter as text)
    end tell
    """#

    public init() {}

    public func closeOtherTabsExceptGmail() async throws -> ChromeTabCloseResult {
        try await MainActor.run {
            guard let script = NSAppleScript(source: Self.scriptSource) else {
                throw NativeDesktopControlError.chromeAutomationFailed
            }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            if let error {
                let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                    ?? (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
                if number == -1_743 {
                    throw NativeDesktopControlError.chromeAutomationPermissionDenied
                }
                throw NativeDesktopControlError.chromeAutomationFailed
            }
            guard let value = descriptor.stringValue else {
                throw NativeDesktopControlError.chromeAutomationFailed
            }
            if value == "chrome_not_running" {
                throw NativeDesktopControlError.applicationNotFound
            }
            if value == "gmail_not_found" {
                throw NativeDesktopControlError.gmailTabNotFound
            }
            let parts = value.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let kept = Int(parts[0]),
                  let closed = Int(parts[1]),
                  let remaining = Int(parts[2]),
                  kept > 0,
                  closed >= 0,
                  remaining >= 0 else {
                throw NativeDesktopControlError.chromeAutomationFailed
            }
            guard remaining == 0 else {
                throw NativeDesktopControlError.chromeTabPostconditionFailed
            }
            return ChromeTabCloseResult(
                keptGmailTabs: kept,
                closedOtherTabs: closed,
                remainingOtherTabs: remaining
            )
        }
    }
}

/// A bounded desktop action Aurora can perform directly through macOS APIs.
/// These actions never invoke a shell and never present an Aurora approval UI.
public enum NativeDesktopAction: String, Codable, Sendable, Equatable, CaseIterable {
    case minimizeFrontWindow = "minimize_front_window"
    case minimizeAllWindows = "minimize_all_windows"
    case minimizeEverything = "minimize_everything"
    case closeFrontWindow = "close_front_window"
    case closeAllWindows = "close_all_windows"
    case hideFrontApplication = "hide_front_application"
    case showDesktop = "show_desktop"
    case openSettings = "open_settings"
    case activateApplication = "activate_application"
    case back
    case forward
    case refresh
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case closeOtherTabsExceptGmail = "close_other_tabs_except_gmail"
    case reopenClosedTab = "reopen_closed_tab"
    case pauseCurrentMedia = "pause_current_media"
    case resumeCurrentMedia = "resume_current_media"
    case writeTextEditDocument = "write_textedit_document"

    public var requiresApplicationName: Bool {
        self == .activateApplication
    }

    public var isBrowserShortcut: Bool {
        switch self {
        case .back, .forward, .refresh, .newTab, .closeTab, .reopenClosedTab:
            return true
        default:
            return false
        }
    }
}

/// A privacy-bounded native action receipt. It deliberately contains no
/// window titles, URLs, Accessibility labels, keystrokes, or screen content.
public struct NativeDesktopActionResult: Codable, Sendable, Equatable {
    public let action: NativeDesktopAction
    public let applicationName: String
    public let affectedCount: Int
    public let summary: String
    /// Native actions always populate this value. The optional type remains
    /// for source and persisted-receipt compatibility with older builds.
    public let effectVerified: Bool?
    public let applicationCount: Int?
    public let remainingVisibleCount: Int?

    public init(
        action: NativeDesktopAction,
        applicationName: String,
        affectedCount: Int,
        summary: String,
        effectVerified: Bool? = false,
        applicationCount: Int? = nil,
        remainingVisibleCount: Int? = nil
    ) {
        self.action = action
        self.applicationName = Self.bounded(applicationName, maximumCharacters: 120)
        self.affectedCount = min(max(affectedCount, 0), 1_000)
        self.summary = Self.bounded(summary, maximumCharacters: 280)
        self.effectVerified = effectVerified ?? false
        self.applicationCount = applicationCount.map { min(max($0, 0), 1_000) }
        self.remainingVisibleCount = remainingVisibleCount.map { min(max($0, 0), 1_000) }
    }

    private static func bounded(_ value: String, maximumCharacters: Int) -> String {
        String(value.prefix(maximumCharacters))
    }
}

public enum NativeDesktopControlError: LocalizedError, Sendable, Equatable {
    case accessibilityPermissionDenied
    case eventPostingPermissionDenied
    case noEligibleApplication
    case noEligibleWindow
    case applicationNameRequired
    case invalidApplicationName
    case applicationNotFound
    case unsupportedBrowser
    case gmailTabNotFound
    case chromeAutomationPermissionDenied
    case chromeAutomationFailed
    case chromeTabPostconditionFailed
    case mediaControlNotFound
    case mediaControlVerificationFailed
    case actionFailed

    public var diagnosticCode: String {
        switch self {
        case .accessibilityPermissionDenied: return "accessibility_permission_denied"
        case .eventPostingPermissionDenied: return "event_posting_permission_denied"
        case .noEligibleApplication: return "no_eligible_application"
        case .noEligibleWindow: return "no_eligible_window"
        case .applicationNameRequired: return "application_name_required"
        case .invalidApplicationName: return "invalid_application_name"
        case .applicationNotFound: return "application_not_found"
        case .unsupportedBrowser: return "unsupported_browser"
        case .gmailTabNotFound: return "gmail_tab_not_found"
        case .chromeAutomationPermissionDenied: return "chrome_automation_permission_denied"
        case .chromeAutomationFailed: return "chrome_automation_failed"
        case .chromeTabPostconditionFailed: return "chrome_tab_postcondition_failed"
        case .mediaControlNotFound: return "media_control_not_found"
        case .mediaControlVerificationFailed: return "media_control_verification_failed"
        case .actionFailed: return "action_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "macOS Accessibility permission is needed for that window action."
        case .eventPostingPermissionDenied:
            return "macOS Accessibility permission is needed for that keyboard action."
        case .noEligibleApplication:
            return "There is no current non-Aurora application to control."
        case .noEligibleWindow:
            return "That application has no available window for this action."
        case .applicationNameRequired:
            return "An application name is required."
        case .invalidApplicationName:
            return "That application name is not valid."
        case .applicationNotFound:
            return "That application could not be found."
        case .unsupportedBrowser:
            return "The current application is not a supported web browser."
        case .gmailTabNotFound:
            return "Aurora could not find an open Gmail tab, so she left every Chrome tab unchanged."
        case .chromeAutomationPermissionDenied:
            return "macOS has not allowed Aurora to manage Chrome tabs yet."
        case .chromeAutomationFailed:
            return "Aurora could not finish managing Chrome's tabs."
        case .chromeTabPostconditionFailed:
            return "Aurora stopped because Chrome still had another non-Gmail tab open."
        case .mediaControlNotFound:
            return "Aurora could not find a visible play or pause control in the current browser page."
        case .mediaControlVerificationFailed:
            return "The browser accepted the media control, but Aurora could not verify that playback changed."
        case .actionFailed:
            return "macOS could not complete that desktop action."
        }
    }
}

/// Native desktop control for direct owner-requested actions. The actor keeps
/// action execution serialized while AppKit work is confined to MainActor.
public actor NativeDesktopControl {
    private enum ProcessScope: Sendable, Equatable {
        case allEligible
        case onlyProcessIDs(Set<pid_t>)

        func contains(_ processID: pid_t) -> Bool {
            switch self {
            case .allEligible:
                return true
            case let .onlyProcessIDs(processIDs):
                return processIDs.contains(processID)
            }
        }
    }

    private struct ApplicationRecord: Sendable, Equatable {
        let processID: pid_t
        let name: String
        let bundleIdentifier: String
        let isRegularApplication: Bool
    }

    private struct WindowRecord: Sendable, Equatable {
        let processID: pid_t
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    struct Shortcut: Sendable, Equatable {
        let keyCode: CGKeyCode
        let command: Bool
        let shift: Bool
    }

    /// Pure recovery decision used by native activation and its focused
    /// verifier. Activation is not complete merely because an application is
    /// frontmost: a running app with only minimized windows still needs to be
    /// restored before the owner can use it.
    enum ApplicationActivationRecoveryStep: String, Sendable, Equatable {
        case verified
        case restoreAndActivate
        case reopenExistingApplication
        case failed
    }

    static func applicationActivationRecoveryStep(
        isRunning: Bool,
        isFrontmost: Bool,
        isHidden: Bool,
        accessibilityWindowCount: Int,
        minimizedWindowCount: Int,
        visibleWindowCount: Int,
        directAttempts: Int,
        maximumDirectAttempts: Int = 3,
        reopenAttempted: Bool
    ) -> ApplicationActivationRecoveryStep {
        guard isRunning else { return .failed }
        let boundedWindowCount = max(accessibilityWindowCount, 0)
        let boundedMinimizedCount = min(
            max(minimizedWindowCount, 0),
            boundedWindowCount
        )
        let hasUnminimizedWindow = boundedWindowCount > 0
            && boundedMinimizedCount < boundedWindowCount
        let hasUsableWindow = hasUnminimizedWindow && visibleWindowCount > 0
        if isFrontmost, !isHidden, hasUsableWindow {
            return .verified
        }
        let boundedMaximum = max(maximumDirectAttempts, 0)
        if max(directAttempts, 0) < boundedMaximum {
            return .restoreAndActivate
        }
        if !reopenAttempted {
            return .reopenExistingApplication
        }
        return .failed
    }

    private struct ApplicationActivationObservation: Sendable, Equatable {
        let isRunning: Bool
        let isFrontmost: Bool
        let isHidden: Bool
        let accessibilityWindowCount: Int
        let minimizedWindowCount: Int
        let visibleWindowCount: Int

        var isVerified: Bool {
            NativeDesktopControl.applicationActivationRecoveryStep(
                isRunning: isRunning,
                isFrontmost: isFrontmost,
                isHidden: isHidden,
                accessibilityWindowCount: accessibilityWindowCount,
                minimizedWindowCount: minimizedWindowCount,
                visibleWindowCount: visibleWindowCount,
                directAttempts: 0,
                maximumDirectAttempts: 0,
                reopenAttempted: true
            ) == .verified
        }
    }

    /// Privacy-bounded browser state used to verify keyboard actions without
    /// recording tab titles, URLs, or page content in a receipt.
    struct BrowserObservation: Sendable, Equatable {
        let tabCount: Int?
        let windowCount: Int
        let focusedWindowIdentity: Int?
        let documentIdentity: Int?
        let documentURL: String?
        let windowTitle: String?
        let isBusy: Bool?

        init(
            tabCount: Int?,
            windowCount: Int,
            focusedWindowIdentity: Int? = nil,
            documentIdentity: Int? = nil,
            documentURL: String? = nil,
            windowTitle: String? = nil,
            isBusy: Bool? = nil
        ) {
            self.tabCount = tabCount
            self.windowCount = max(windowCount, 0)
            self.focusedWindowIdentity = focusedWindowIdentity
            self.documentIdentity = documentIdentity
            self.documentURL = documentURL
            self.windowTitle = windowTitle
            self.isBusy = isBusy
        }
    }

    private struct WindowActionObservation: Sendable, Equatable {
        let verified: Bool
        let affectedCount: Int
        let remainingCount: Int
        let remainingSelectedIdentities: Set<Int>
    }

    /// The semantic state exposed by a page's current media control. A
    /// `Pause` button means media is playing; a `Play` button means it is
    /// paused. Keeping this small classifier free of AX objects gives native
    /// verification a deterministic test seam.
    enum MediaPlaybackState: String, Sendable, Equatable {
        case playing
        case paused
    }

    private struct MediaControlMatch {
        let element: AXUIElement
        let state: MediaPlaybackState
    }

    private struct MediaAccessibilityQueueEntry {
        let element: AXUIElement
        let depth: Int
    }

    private static let maximumMediaAccessibilityNodes = 2_500
    private static let maximumMediaAccessibilityDepth = 40
    private static let maximumMediaAccessibilityScanDuration: TimeInterval = 0.45
    private static let maximumBrowserObservationNodes = 2_500
    private static let maximumBrowserObservationDepth = 40
    private static let maximumBrowserObservationDuration: TimeInterval = 0.35

    private let processScope: ProcessScope
    private let chromeTabCloser: any ChromeTabClosing

    public init() {
        processScope = .allEligible
        chromeTabCloser = SystemChromeTabCloser()
    }

    /// Test-only process boundary for installed native verification. An empty
    /// set fails closed and never falls back to production-wide control.
    init(
        onlyProcessIDs processIDs: Set<pid_t>,
        chromeTabCloser: any ChromeTabClosing = SystemChromeTabCloser()
    ) {
        processScope = .onlyProcessIDs(processIDs)
        self.chromeTabCloser = chromeTabCloser
    }

    public func perform(
        action: NativeDesktopAction,
        applicationName: String? = nil,
        text: String? = nil
    ) async throws -> NativeDesktopActionResult {
        try Task.checkCancellation()
        switch action {
        case .minimizeFrontWindow:
            return try await performWindowAction(
                action,
                allWindows: false,
                close: false,
                requestedApplicationName: applicationName
            )
        case .minimizeAllWindows:
            return try await performWindowAction(
                action,
                allWindows: true,
                close: false,
                requestedApplicationName: applicationName
            )
        case .minimizeEverything:
            return try await minimizeEverything()
        case .closeFrontWindow:
            return try await performWindowAction(
                action,
                allWindows: false,
                close: true,
                requestedApplicationName: applicationName
            )
        case .closeAllWindows:
            return try await performWindowAction(
                action,
                allWindows: true,
                close: true,
                requestedApplicationName: applicationName
            )
        case .hideFrontApplication:
            return try await hideFrontApplication(named: applicationName)
        case .showDesktop:
            return try await showDesktop()
        case .openSettings:
            return try await openSettings()
        case .activateApplication:
            return try await activateApplication(named: applicationName)
        case .closeOtherTabsExceptGmail:
            return try await closeOtherTabsExceptGmail()
        case .writeTextEditDocument:
            return try await writeTextEditDocument(text)
        case .pauseCurrentMedia, .resumeCurrentMedia:
            return try await performCurrentMediaAction(
                action,
                requestedBrowserName: applicationName
            )
        case .back, .forward, .refresh, .newTab, .closeTab, .reopenClosedTab:
            return try await performBrowserShortcut(
                action,
                requestedBrowserName: applicationName
            )
        }
    }

    /// Controls the current browser page through its semantic Accessibility
    /// play/pause button. This is intentionally state-aware: repeated pause or
    /// resume requests become verified no-ops instead of accidentally toggling
    /// playback in the opposite direction. It never captures the screen or
    /// invokes Computer Use.
    private func performCurrentMediaAction(
        _ action: NativeDesktopAction,
        requestedBrowserName: String?
    ) async throws
        -> NativeDesktopActionResult {
        guard action == .pauseCurrentMedia || action == .resumeCurrentMedia else {
            throw NativeDesktopControlError.actionFailed
        }
        guard AXIsProcessTrusted() else {
            throw NativeDesktopControlError.accessibilityPermissionDenied
        }

        let requestedState: MediaPlaybackState = action == .pauseCurrentMedia
            ? .paused
            : .playing
        let (target, initiallyVisibleControl) = try await currentBrowserMediaTarget(
            named: requestedBrowserName,
            requestedState: requestedState
        )
        // A semantic Play/Pause control is the authority for state. Merely
        // finding a player-shaped group is not proof that media is currently
        // playing and must never select a different visible browser.
        let initialState = initiallyVisibleControl.state

        if initialState == requestedState {
            let summary = requestedState == .paused
                ? "The current browser video was already paused."
                : "The current browser video was already playing."
            return NativeDesktopActionResult(
                action: action,
                applicationName: target.name,
                affectedCount: 0,
                summary: summary,
                effectVerified: true,
                applicationCount: 1
            )
        }

        guard CGPreflightPostEventAccess() else {
            throw NativeDesktopControlError.eventPostingPermissionDenied
        }
        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: target.processID)?.activate(
                options: []
            ) == true
        }
        guard activated else { throw NativeDesktopControlError.actionFailed }
        try await Task.sleep(for: .milliseconds(120))
        guard await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
        }) else { throw NativeDesktopControlError.actionFailed }

        let actuationPoint: CGPoint
        if let bounds = Self.axBounds(initiallyVisibleControl.element),
           bounds.width >= 1,
           bounds.height >= 1 {
            actuationPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        } else if let playerPoint = Self.currentMediaPlayerPoint(
            processID: target.processID
        ) {
            actuationPoint = playerPoint
        } else {
            throw NativeDesktopControlError.mediaControlNotFound
        }
        guard Self.postLeftClick(at: actuationPoint) else {
            throw NativeDesktopControlError.actionFailed
        }
        try await Task.sleep(for: .milliseconds(220))
        let verifiedState = try await waitForCurrentMediaState(
            processID: target.processID,
            requestedState: requestedState,
            until: Date().addingTimeInterval(1.1)
        )
        guard verifiedState == requestedState else {
            throw NativeDesktopControlError.mediaControlVerificationFailed
        }

        return NativeDesktopActionResult(
            action: action,
            applicationName: target.name,
            affectedCount: 1,
            summary: requestedState == .paused
                ? "Paused the current browser video."
                : "Resumed the current browser video.",
            effectVerified: true,
            applicationCount: 1
        )
    }

    /// Selects only a browser whose current page exposes a semantic Play/Pause
    /// state. An explicitly named browser is binding. Without one, the
    /// frontmost/visible ordering is authoritative. A background browser must
    /// never win merely because changing it would produce a non-no-op result.
    private func currentBrowserMediaTarget(
        named requestedName: String?,
        requestedState: MediaPlaybackState
    ) async throws -> (ApplicationRecord, MediaControlMatch) {
        let applications = await runningApplications()
        let applicationsByPID = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.processID, $0) }
        )
        var candidates: [ApplicationRecord] = []
        var seen = Set<pid_t>()

        if let requestedName {
            let requestedBrowser = try await browserTarget(named: requestedName)
            guard let control = Self.currentMediaControl(
                processID: requestedBrowser.processID
            ) else {
                throw NativeDesktopControlError.mediaControlNotFound
            }
            return (requestedBrowser, control)
        }

        let frontmostPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let frontmostPID,
           let frontmost = applicationsByPID[frontmostPID],
           Self.isEligibleTarget(frontmost),
           Self.isSupportedBrowser(frontmost),
           processScope.contains(frontmost.processID),
           seen.insert(frontmost.processID).inserted {
            candidates.append(frontmost)
        }
        for window in Self.onscreenWindowRecords() where Self.isEligibleWindow(window) {
            guard let application = applicationsByPID[window.processID],
                  Self.isEligibleTarget(application),
                  Self.isSupportedBrowser(application),
                  processScope.contains(application.processID),
                  seen.insert(application.processID).inserted else { continue }
            candidates.append(application)
        }

        var observed: [(ApplicationRecord, MediaControlMatch)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            if let control = Self.currentMediaControl(processID: candidate.processID) {
                observed.append((candidate, control))
            }
        }
        guard let index = Self.preferredMediaTargetIndex(
            observedStates: observed.map { $0.1.state },
            requestedState: requestedState
        ) else {
            throw NativeDesktopControlError.mediaControlNotFound
        }
        return observed[index]
    }

    private func waitForCurrentMediaState(
        processID: pid_t,
        requestedState: MediaPlaybackState,
        until deadline: Date
    ) async throws -> MediaPlaybackState? {
        var state = Self.currentMediaControl(processID: processID)?.state
        while state != requestedState, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(55))
            state = Self.currentMediaControl(processID: processID)?.state
        }
        return state
    }

    /// Pure selection seam used by installed verification. Unknown state is
    /// never a target. A deterministically observed state that needs changing
    /// wins; an already-satisfied target is a verified no-op fallback.
    static func preferredMediaTargetIndex(
        observedStates: [MediaPlaybackState?],
        requestedState: MediaPlaybackState
    ) -> Int? {
        if let needsChange = observedStates.firstIndex(where: { state in
            guard let state else { return false }
            return state != requestedState
        }) {
            return needsChange
        }
        return observedStates.firstIndex(where: { $0 == requestedState })
    }

    /// Creates or reuses a truly blank TextEdit document, inserts the exact
    /// owner-dictated text through Accessibility, and verifies the resulting
    /// document value. This avoids screenshots, the Computer Use model,
    /// Apple Events, shell commands, and pasteboard mutation.
    private func writeTextEditDocument(_ requestedText: String?) async throws
        -> NativeDesktopActionResult {
        guard AXIsProcessTrusted() else {
            throw NativeDesktopControlError.accessibilityPermissionDenied
        }
        guard let requestedText else {
            throw NativeDesktopControlError.actionFailed
        }
        let text = requestedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else {
            throw NativeDesktopControlError.actionFailed
        }

        let target = try await ensureTextEditApplication()
        guard processScope.contains(target.processID) else {
            throw NativeDesktopControlError.noEligibleApplication
        }
        try await waitForFrontmostApplication(processID: target.processID)

        var textArea = Self.focusedTextArea(processID: target.processID)
        if textArea.flatMap(Self.axStringValue)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty != true {
            guard CGPreflightPostEventAccess(),
                  Self.post(Shortcut(keyCode: 45, command: true, shift: false)) else {
                throw NativeDesktopControlError.eventPostingPermissionDenied
            }
            textArea = try await waitForBlankTextArea(processID: target.processID)
        }
        guard let textArea else {
            throw NativeDesktopControlError.noEligibleWindow
        }

        var settable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(
            textArea,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
        let setResult = canSetValue
            ? AXUIElementSetAttributeValue(
                textArea,
                kAXValueAttribute as CFString,
                text as CFString
            )
            : .attributeUnsupported

        if setResult != .success {
            guard CGPreflightPostEventAccess() else {
                throw NativeDesktopControlError.eventPostingPermissionDenied
            }
            _ = AXUIElementPerformAction(textArea, kAXPressAction as CFString)
            try await SystemMacDesktopActionPerformer().perform(.type(text: text))
        }

        let verificationDeadline = Date().addingTimeInterval(1.25)
        var verifiedValue = Self.focusedTextArea(processID: target.processID)
            .flatMap(Self.axStringValue)
        while verifiedValue != text, Date() < verificationDeadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
            verifiedValue = Self.focusedTextArea(processID: target.processID)
                .flatMap(Self.axStringValue)
        }
        guard verifiedValue == text else {
            throw NativeDesktopControlError.actionFailed
        }
        return NativeDesktopActionResult(
            action: .writeTextEditDocument,
            applicationName: "TextEdit",
            affectedCount: 1,
            summary: "Opened a blank TextEdit document and entered the requested text.",
            effectVerified: true,
            applicationCount: 1,
            remainingVisibleCount: 0
        )
    }

    private func ensureTextEditApplication() async throws -> ApplicationRecord {
        let applications = await runningApplications()
        if let running = applications.first(where: {
            $0.bundleIdentifier == "com.apple.TextEdit"
        }) {
            _ = await MainActor.run {
                NSRunningApplication(processIdentifier: running.processID)?.activate(
                    options: [.activateAllWindows]
                )
            }
            return running
        }

        guard let applicationURL = await MainActor.run(body: {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit"
            )
        }) else {
            throw NativeDesktopControlError.applicationNotFound
        }
        let openedApplication: NSRunningApplication? = await withCheckedContinuation {
            continuation in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { application, _ in
                    continuation.resume(returning: application)
                }
            }
        }
        guard let openedApplication else {
            throw NativeDesktopControlError.applicationNotFound
        }
        return await MainActor.run {
            ApplicationRecord(
                processID: openedApplication.processIdentifier,
                name: String((openedApplication.localizedName ?? "TextEdit").prefix(120)),
                bundleIdentifier: String(
                    (openedApplication.bundleIdentifier ?? "com.apple.TextEdit").prefix(240)
                ),
                isRegularApplication: openedApplication.activationPolicy == .regular
            )
        }
    }

    private func waitForFrontmostApplication(processID: pid_t) async throws {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            try Task.checkCancellation()
            if await MainActor.run(body: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
            }) {
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw NativeDesktopControlError.actionFailed
    }

    private func waitForBlankTextArea(processID: pid_t) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            try Task.checkCancellation()
            if let textArea = Self.focusedTextArea(processID: processID),
               Self.axStringValue(textArea)?.trimmingCharacters(
                in: .whitespacesAndNewlines
               ).isEmpty == true {
                return textArea
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw NativeDesktopControlError.noEligibleWindow
    }

    private func closeOtherTabsExceptGmail() async throws -> NativeDesktopActionResult {
        let result = try await chromeTabCloser.closeOtherTabsExceptGmail()
        let affected = result.closedOtherTabs
        let summary = affected == 1
            ? "Closed 1 other Chrome tab and kept Gmail open."
            : "Closed \(affected) other Chrome tabs and kept Gmail open."
        return NativeDesktopActionResult(
            action: .closeOtherTabsExceptGmail,
            applicationName: "Google Chrome",
            affectedCount: affected,
            summary: summary,
            effectVerified: result.keptGmailTabs > 0 && result.remainingOtherTabs == 0,
            applicationCount: 1,
            remainingVisibleCount: result.remainingOtherTabs
        )
    }

    /// Minimize every window belonging to every currently visible regular
    /// application, while leaving Aurora and macOS system UI untouched. The
    /// receipt is based on a bounded native postcondition check, not merely on
    /// successful Accessibility API calls.
    private func minimizeEverything() async throws -> NativeDesktopActionResult {
        guard AXIsProcessTrusted() else {
            throw NativeDesktopControlError.accessibilityPermissionDenied
        }

        if case let .onlyProcessIDs(processIDs) = processScope, processIDs.isEmpty {
            throw NativeDesktopControlError.noEligibleApplication
        }

        let applications = await runningApplications()
        let initialVisibleWindows = Self.onscreenWindowRecords().filter(Self.isEligibleWindow)
        let visibleProcessIDs = Set(initialVisibleWindows.map(\.processID))
        let candidates = applications.filter {
            Self.isEligibleTarget($0)
                && processScope.contains($0.processID)
                && visibleProcessIDs.contains($0.processID)
        }

        let candidateProcessIDs = Set(candidates.map(\.processID))
        let originalVisibleWindows = initialVisibleWindows.filter {
            candidateProcessIDs.contains($0.processID)
        }
        guard !originalVisibleWindows.isEmpty else {
            return NativeDesktopActionResult(
                action: .minimizeEverything,
                applicationName: "Mac",
                affectedCount: 0,
                summary: "Everything eligible was already minimized.",
                effectVerified: true,
                applicationCount: 0,
                remainingVisibleCount: 0
            )
        }

        for candidate in candidates {
            try Task.checkCancellation()
            Self.minimizeAXWindows(for: candidate.processID)
        }

        // Accessibility changes can settle asynchronously. Poll for no more
        // than 1.5 seconds and make one bounded retry against processes that
        // still own an eligible visible window.
        let verificationDeadline = Date().addingTimeInterval(1.5)
        var didRetry = false
        var remainingWindows = Self.visibleWindows(for: candidateProcessIDs)
        while !remainingWindows.isEmpty, Date() < verificationDeadline {
            try Task.checkCancellation()
            if !didRetry {
                didRetry = true
                for processID in Set(remainingWindows.map(\.processID)) {
                    Self.minimizeAXWindows(for: processID)
                }
            }
            if remainingWindows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
            remainingWindows = Self.visibleWindows(for: candidateProcessIDs)
        }
        // Take one final observation even when the deadline elapsed during the
        // sleep so a just-completed native transition is credited correctly.
        remainingWindows = Self.visibleWindows(for: candidateProcessIDs)

        let originalCountByProcess = Dictionary(grouping: originalVisibleWindows, by: \.processID)
            .mapValues(\.count)
        let remainingCountByProcess = Dictionary(grouping: remainingWindows, by: \.processID)
            .mapValues(\.count)
        let affectedApplicationCount = originalCountByProcess.reduce(into: 0) { count, entry in
            if (remainingCountByProcess[entry.key] ?? 0) < entry.value {
                count += 1
            }
        }
        let remainingCount = remainingWindows.count
        let affectedCount = max(originalVisibleWindows.count - remainingCount, 0)
        let effectVerified = remainingCount == 0
        let windowWord = affectedCount == 1 ? "window" : "windows"
        let applicationWord = affectedApplicationCount == 1 ? "application" : "applications"
        let summary: String
        if effectVerified {
            summary = "Minimized \(affectedCount) \(windowWord) across \(affectedApplicationCount) \(applicationWord)."
        } else {
            let remainingWord = remainingCount == 1 ? "window remains" : "windows remain"
            summary = "Minimized \(affectedCount) of \(originalVisibleWindows.count) visible windows across \(affectedApplicationCount) \(applicationWord); \(remainingCount) \(remainingWord) visible."
        }
        return NativeDesktopActionResult(
            action: .minimizeEverything,
            applicationName: "Mac",
            affectedCount: affectedCount,
            summary: summary,
            effectVerified: effectVerified,
            applicationCount: affectedApplicationCount,
            remainingVisibleCount: remainingCount
        )
    }

    private func performWindowAction(
        _ action: NativeDesktopAction,
        allWindows: Bool,
        close: Bool,
        requestedApplicationName: String?
    ) async throws -> NativeDesktopActionResult {
        guard AXIsProcessTrusted() else {
            throw NativeDesktopControlError.accessibilityPermissionDenied
        }
        let target = try await desktopApplicationTarget(named: requestedApplicationName)
        let applicationElement = AXUIElementCreateApplication(target.processID)
        let windows = Self.axElements(applicationElement, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { throw NativeDesktopControlError.noEligibleWindow }

        let selectedWindows: [AXUIElement]
        if allWindows {
            selectedWindows = windows
        } else if let front = Self.frontWindow(
            for: target.processID,
            applicationElement: applicationElement,
            windows: windows
        ) {
            selectedWindows = [front]
        } else {
            throw NativeDesktopControlError.noEligibleWindow
        }

        let selectedIdentities = Set(selectedWindows.map(Self.axIdentity))
        let initiallyActionableIdentities = close
            ? selectedIdentities
            : Set(selectedWindows.compactMap { window in
                Self.axBool(window, attribute: kAXMinimizedAttribute) == true
                    ? nil
                    : Self.axIdentity(window)
            })
        for window in selectedWindows {
            try Task.checkCancellation()
            Self.actuateWindow(window, close: close)
        }

        let deadline = Date().addingTimeInterval(1.5)
        let retryAfter = Date().addingTimeInterval(0.3)
        var didRetry = false
        var observation = Self.windowActionObservation(
            processID: target.processID,
            selectedIdentities: selectedIdentities,
            initiallyActionableIdentities: initiallyActionableIdentities,
            allWindows: allWindows,
            close: close
        )
        while !observation.verified, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(70))
            observation = Self.windowActionObservation(
                processID: target.processID,
                selectedIdentities: selectedIdentities,
                initiallyActionableIdentities: initiallyActionableIdentities,
                allWindows: allWindows,
                close: close
            )
            if !observation.verified, !didRetry, Date() >= retryAfter {
                didRetry = true
                let currentWindows = Self.axElements(
                    AXUIElementCreateApplication(target.processID),
                    attribute: kAXWindowsAttribute
                )
                for window in currentWindows
                    where observation.remainingSelectedIdentities.contains(Self.axIdentity(window)) {
                    Self.actuateWindow(window, close: close)
                }
            }
        }
        observation = Self.windowActionObservation(
            processID: target.processID,
            selectedIdentities: selectedIdentities,
            initiallyActionableIdentities: initiallyActionableIdentities,
            allWindows: allWindows,
            close: close
        )

        let verb = close ? "Closed" : "Minimized"
        let object = observation.affectedCount == 1 ? "window" : "windows"
        let summary = observation.verified
            ? "\(verb) \(observation.affectedCount) \(object) in \(target.name)."
            : "\(verb) \(observation.affectedCount) \(object) in \(target.name), but \(observation.remainingCount) could not be verified."
        return NativeDesktopActionResult(
            action: action,
            applicationName: target.name,
            affectedCount: observation.affectedCount,
            summary: summary,
            effectVerified: observation.verified,
            applicationCount: 1,
            remainingVisibleCount: observation.remainingCount
        )
    }

    private func hideFrontApplication(
        named requestedApplicationName: String?
    ) async throws -> NativeDesktopActionResult {
        let target = try await desktopApplicationTarget(named: requestedApplicationName)
        let initialVisibleWindows = Self.onscreenWindowRecords().filter {
            $0.processID == target.processID && Self.isEligibleWindow($0)
        }.count
        let hidden = await MainActor.run {
            guard let running = NSRunningApplication(processIdentifier: target.processID) else {
                return false
            }
            return running.isHidden || running.hide()
        }
        guard hidden else { throw NativeDesktopControlError.actionFailed }

        let deadline = Date().addingTimeInterval(1.25)
        var isHidden = false
        var remainingVisibleWindows = initialVisibleWindows
        while Date() < deadline {
            try Task.checkCancellation()
            isHidden = await MainActor.run {
                NSRunningApplication(processIdentifier: target.processID)?.isHidden == true
            }
            remainingVisibleWindows = Self.visibleWindows(for: [target.processID]).count
            if isHidden && remainingVisibleWindows == 0 { break }
            try await Task.sleep(for: .milliseconds(55))
        }
        isHidden = await MainActor.run {
            NSRunningApplication(processIdentifier: target.processID)?.isHidden == true
        }
        remainingVisibleWindows = Self.visibleWindows(for: [target.processID]).count
        let effectVerified = isHidden && remainingVisibleWindows == 0
        let affected = max(initialVisibleWindows - remainingVisibleWindows, 0)
        return NativeDesktopActionResult(
            action: .hideFrontApplication,
            applicationName: target.name,
            affectedCount: affected,
            summary: effectVerified
                ? "Hid \(target.name)."
                : "Asked macOS to hide \(target.name), but its windows are still visible.",
            effectVerified: effectVerified,
            applicationCount: effectVerified ? 1 : 0,
            remainingVisibleCount: remainingVisibleWindows
        )
    }

    private func showDesktop() async throws -> NativeDesktopActionResult {
        let applications = await runningApplications()
        let initialVisibleWindows = Self.onscreenWindowRecords().filter(Self.isEligibleWindow)
        let initiallyVisibleProcessIDs = Set(initialVisibleWindows.map(\.processID))
        let candidates = applications.filter {
            $0.isRegularApplication
                && $0.bundleIdentifier != "com.apple.finder"
                && !Self.isAuroraApplication($0)
                && !Self.isSystemUI($0)
                && processScope.contains($0.processID)
                && initiallyVisibleProcessIDs.contains($0.processID)
        }
        let candidateProcessIDs = Set(candidates.map(\.processID))
        guard !candidateProcessIDs.isEmpty else {
            return NativeDesktopActionResult(
                action: .showDesktop,
                applicationName: "Desktop",
                affectedCount: 0,
                summary: "The desktop was already visible.",
                effectVerified: true,
                applicationCount: 0,
                remainingVisibleCount: 0
            )
        }
        for application in candidates {
            try Task.checkCancellation()
            _ = await MainActor.run {
                guard let running = NSRunningApplication(
                    processIdentifier: application.processID
                ), !running.isHidden else { return false }
                return running.hide()
            }
        }

        let deadline = Date().addingTimeInterval(1.5)
        var remainingWindows = Self.visibleWindows(for: candidateProcessIDs)
        while !remainingWindows.isEmpty, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(70))
            remainingWindows = Self.visibleWindows(for: candidateProcessIDs)
        }
        remainingWindows = Self.visibleWindows(for: candidateProcessIDs)
        let remainingProcessIDs = Set(remainingWindows.map(\.processID))
        let hiddenCount = candidateProcessIDs.subtracting(remainingProcessIDs).count
        let effectVerified = remainingWindows.isEmpty
        return NativeDesktopActionResult(
            action: .showDesktop,
            applicationName: "Desktop",
            affectedCount: hiddenCount,
            summary: effectVerified
                ? (hiddenCount == 1
                    ? "Showed the desktop by hiding 1 application."
                    : "Showed the desktop by hiding \(hiddenCount) applications.")
                : "Hid \(hiddenCount) applications, but \(remainingWindows.count) visible windows remain.",
            effectVerified: effectVerified,
            applicationCount: hiddenCount,
            remainingVisibleCount: remainingWindows.count
        )
    }

    private func openSettings() async throws -> NativeDesktopActionResult {
        guard let url = URL(string: "x-apple.systempreferences:") else {
            throw NativeDesktopControlError.actionFailed
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw NativeDesktopControlError.actionFailed }

        let deadline = Date().addingTimeInterval(2.5)
        var settingsApplication: ApplicationRecord?
        var visibleWindowCount = 0
        while Date() < deadline {
            try Task.checkCancellation()
            settingsApplication = await runningApplications().first(where: {
                $0.bundleIdentifier == "com.apple.systempreferences"
                    || Self.normalizedApplicationName($0.name) == "system settings"
            })
            if let settingsApplication {
                visibleWindowCount = Self.visibleWindows(
                    for: [settingsApplication.processID]
                ).count
                if visibleWindowCount > 0 { break }
            }
            try await Task.sleep(for: .milliseconds(70))
        }
        if let settingsApplication {
            visibleWindowCount = Self.visibleWindows(for: [settingsApplication.processID]).count
        }
        let effectVerified = settingsApplication != nil && visibleWindowCount > 0
        return NativeDesktopActionResult(
            action: .openSettings,
            applicationName: "System Settings",
            affectedCount: effectVerified ? 1 : 0,
            summary: effectVerified
                ? "Opened System Settings."
                : "Asked macOS to open System Settings, but no settings window appeared.",
            effectVerified: effectVerified,
            applicationCount: effectVerified ? 1 : 0,
            remainingVisibleCount: effectVerified ? 0 : 1
        )
    }

    private func activateApplication(named requestedName: String?) async throws
        -> NativeDesktopActionResult {
        guard let requestedName else {
            throw NativeDesktopControlError.applicationNameRequired
        }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidApplicationName(name) else {
            throw NativeDesktopControlError.invalidApplicationName
        }

        let applications = await runningApplications().filter {
            Self.isEligibleTarget($0) && processScope.contains($0.processID)
        }
        if let running = Self.preferredApplication(in: applications, named: name) {
            let observation = try await restoreAndActivateRunningApplication(running)
            let effectVerified = observation.isVerified
            return NativeDesktopActionResult(
                action: .activateApplication,
                applicationName: running.name,
                affectedCount: effectVerified ? 1 : 0,
                summary: effectVerified
                    ? "Brought \(running.name) forward."
                    : "Asked macOS to bring \(running.name) forward, but no usable window appeared.",
                effectVerified: effectVerified,
                applicationCount: effectVerified ? 1 : 0,
                remainingVisibleCount: effectVerified ? 0 : 1
            )
        }

        guard let applicationURL = await MainActor.run(body: {
            Self.installedApplicationURL(named: name)
        }) else {
            throw NativeDesktopControlError.applicationNotFound
        }

        let openedApplication: NSRunningApplication? = await withCheckedContinuation {
            continuation in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { application, _ in
                    continuation.resume(returning: application)
                }
            }
        }
        guard let openedApplication else {
            throw NativeDesktopControlError.actionFailed
        }
        guard processScope.contains(openedApplication.processIdentifier) else {
            throw NativeDesktopControlError.noEligibleApplication
        }
        let openedRecord = await MainActor.run {
            ApplicationRecord(
                processID: openedApplication.processIdentifier,
                name: openedApplication.localizedName
                    ?? applicationURL.deletingPathExtension().lastPathComponent,
                bundleIdentifier: openedApplication.bundleIdentifier ?? "",
                isRegularApplication: openedApplication.activationPolicy == .regular
            )
        }
        let observation = try await restoreAndActivateRunningApplication(
            openedRecord
        )
        let effectVerified = observation.isVerified
        return NativeDesktopActionResult(
            action: .activateApplication,
            applicationName: openedRecord.name,
            affectedCount: effectVerified ? 1 : 0,
            summary: effectVerified
                ? "Opened \(openedRecord.name)."
                : "Opened \(openedRecord.name), but no usable window appeared.",
            effectVerified: effectVerified,
            applicationCount: effectVerified ? 1 : 0
        )
    }

    /// Restores a running application's existing windows before activation.
    /// `NSRunningApplication.activate` alone can make a minimized application
    /// frontmost while leaving every window in the Dock, which looks like a
    /// failed command. Recovery is bounded and remains pinned to the original
    /// process ID throughout.
    private func restoreAndActivateRunningApplication(
        _ target: ApplicationRecord
    ) async throws -> ApplicationActivationObservation {
        guard processScope.contains(target.processID) else {
            throw NativeDesktopControlError.noEligibleApplication
        }

        let maximumDirectAttempts = 3
        let overallDeadline = Date().addingTimeInterval(4.25)
        var directAttempts = 0
        var reopenAttempted = false
        var observation = await applicationActivationObservation(
            processID: target.processID
        )

        while Date() < overallDeadline {
            try Task.checkCancellation()
            let step = Self.applicationActivationRecoveryStep(
                isRunning: observation.isRunning,
                isFrontmost: observation.isFrontmost,
                isHidden: observation.isHidden,
                accessibilityWindowCount: observation.accessibilityWindowCount,
                minimizedWindowCount: observation.minimizedWindowCount,
                visibleWindowCount: observation.visibleWindowCount,
                directAttempts: directAttempts,
                maximumDirectAttempts: maximumDirectAttempts,
                reopenAttempted: reopenAttempted
            )

            switch step {
            case .verified, .failed:
                return observation
            case .restoreAndActivate:
                directAttempts += 1
                _ = await requestApplicationRestoreAndActivation(
                    processID: target.processID
                )
                observation = try await waitForApplicationActivationObservation(
                    processID: target.processID,
                    until: min(
                        overallDeadline,
                        Date().addingTimeInterval(0.72)
                    )
                )
            case .reopenExistingApplication:
                reopenAttempted = true
                guard await reopenExistingApplication(target) else {
                    return observation
                }
                // Reopen is an activation request, but explicitly restoring
                // and raising the original process's AX windows makes the
                // postcondition deterministic for apps such as Xcode, Notes,
                // and Calendar.
                _ = await requestApplicationRestoreAndActivation(
                    processID: target.processID
                )
                observation = try await waitForApplicationActivationObservation(
                    processID: target.processID,
                    until: min(
                        overallDeadline,
                        Date().addingTimeInterval(1.15)
                    )
                )
            }
        }
        return await applicationActivationObservation(processID: target.processID)
    }

    private func applicationActivationObservation(
        processID: pid_t
    ) async -> ApplicationActivationObservation {
        let applicationState = await MainActor.run { () -> (Bool, Bool, Bool) in
            guard let running = NSRunningApplication(processIdentifier: processID),
                  !running.isTerminated else {
                return (false, false, false)
            }
            return (
                true,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                running.isHidden
            )
        }
        let windows = Self.axElements(
            AXUIElementCreateApplication(processID),
            attribute: kAXWindowsAttribute
        )
        let minimizedWindowCount = windows.reduce(into: 0) { count, window in
            if Self.axBool(window, attribute: kAXMinimizedAttribute) == true {
                count += 1
            }
        }
        return ApplicationActivationObservation(
            isRunning: applicationState.0,
            isFrontmost: applicationState.1,
            isHidden: applicationState.2,
            accessibilityWindowCount: windows.count,
            minimizedWindowCount: minimizedWindowCount,
            visibleWindowCount: Self.visibleWindows(for: [processID]).count
        )
    }

    private func waitForApplicationActivationObservation(
        processID: pid_t,
        until deadline: Date
    ) async throws -> ApplicationActivationObservation {
        var observation = await applicationActivationObservation(processID: processID)
        while !observation.isVerified, observation.isRunning, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(55))
            observation = await applicationActivationObservation(processID: processID)
        }
        return observation
    }

    /// Best-effort restoration of the original process only. This never
    /// resolves a new target and never broadens a test-only process scope.
    @MainActor
    private func requestApplicationRestoreAndActivation(processID: pid_t) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: processID),
              !running.isTerminated else { return false }

        if running.isHidden {
            _ = running.unhide()
        }
        let applicationElement = AXUIElementCreateApplication(processID)
        let windows = Self.axElements(
            applicationElement,
            attribute: kAXWindowsAttribute
        )
        let preferredWindow = Self.frontWindow(
            for: processID,
            applicationElement: applicationElement,
            windows: windows
        ) ?? windows.first

        for window in windows {
            if Self.axBool(window, attribute: kAXMinimizedAttribute) == true {
                _ = AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }
        }

        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        let activated = running.activate(options: [.activateAllWindows])
        if let preferredWindow {
            _ = AXUIElementSetAttributeValue(
                preferredWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                preferredWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(
                preferredWindow,
                kAXRaiseAction as CFString
            )
        }
        return activated
    }

    /// As a final bounded recovery, asks LaunchServices to reopen the already
    /// running app. `createsNewApplicationInstance = false` and original-PID
    /// verification prevent this fallback from widening into a duplicate app
    /// instance or a different process.
    private func reopenExistingApplication(_ target: ApplicationRecord) async -> Bool {
        guard processScope.contains(target.processID) else { return false }
        let applicationURL = await MainActor.run { () -> URL? in
            guard let running = NSRunningApplication(
                processIdentifier: target.processID
            ), !running.isTerminated else { return nil }
            return running.bundleURL
                ?? Self.installedApplicationURL(named: target.bundleIdentifier)
                ?? Self.installedApplicationURL(named: target.name)
        }
        guard let applicationURL else { return false }

        let reopenedProcessID: pid_t? = await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard NSRunningApplication(processIdentifier: target.processID) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { application, _ in
                    continuation.resume(returning: application?.processIdentifier)
                }
            }
        }
        return reopenedProcessID == target.processID
    }

    private func performBrowserShortcut(
        _ action: NativeDesktopAction,
        requestedBrowserName: String?
    ) async throws
        -> NativeDesktopActionResult {
        guard let shortcut = Self.shortcut(for: action) else {
            throw NativeDesktopControlError.actionFailed
        }
        let target = try await browserTarget(named: requestedBrowserName)
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw NativeDesktopControlError.eventPostingPermissionDenied
        }
        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: target.processID)?.activate(
                options: [.activateAllWindows]
            ) == true
        }
        guard activated else { throw NativeDesktopControlError.actionFailed }
        try await Task.sleep(nanoseconds: 80_000_000)
        guard await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
        }) else {
            throw NativeDesktopControlError.actionFailed
        }
        let before = Self.browserObservation(processID: target.processID)
        try Task.checkCancellation()
        guard Self.post(shortcut) else {
            throw NativeDesktopControlError.actionFailed
        }

        let deadline = Date().addingTimeInterval(1.75)
        var after = Self.browserObservation(processID: target.processID)
        var sawBusyState = after.isBusy == true
        var effectVerified = Self.browserShortcutEffectObserved(
            action: action,
            before: before,
            after: after,
            sawBusyState: sawBusyState
        )
        while !effectVerified, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(55))
            after = Self.browserObservation(processID: target.processID)
            sawBusyState = sawBusyState || after.isBusy == true
            effectVerified = Self.browserShortcutEffectObserved(
                action: action,
                before: before,
                after: after,
                sawBusyState: sawBusyState
            )
        }
        return NativeDesktopActionResult(
            action: action,
            applicationName: target.name,
            affectedCount: effectVerified ? 1 : 0,
            summary: effectVerified
                ? "Performed \(Self.spokenName(for: action)) in \(target.name)."
                : "Sent \(Self.spokenName(for: action)) to \(target.name), but the browser did not show the expected change.",
            effectVerified: effectVerified,
            applicationCount: 1,
            remainingVisibleCount: effectVerified ? 0 : 1
        )
    }

    /// Resolves a browser before focus is changed. An explicit owner-supplied
    /// browser name is binding; without one, the frontmost supported browser
    /// wins, followed by supported browsers in visible-window order. An
    /// unrelated foreground application is never used as a shortcut target.
    private func browserTarget(named requestedName: String?) async throws -> ApplicationRecord {
        let applications = await runningApplications()
        let eligibleBrowsers = applications.filter {
            Self.isEligibleTarget($0)
                && Self.isSupportedBrowser($0)
                && processScope.contains($0.processID)
        }
        guard !eligibleBrowsers.isEmpty else {
            throw NativeDesktopControlError.unsupportedBrowser
        }

        if let requestedName {
            let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidApplicationName(name) else {
                throw NativeDesktopControlError.invalidApplicationName
            }
            let exactNameMatch = eligibleBrowsers.first(where: {
                Self.normalizedApplicationName($0.name)
                    == Self.normalizedApplicationName(name)
            })
            let preferredBundleMatch = Self.browserBundleIdentifierPreference(
                for: name
            ).lazy.compactMap { bundleIdentifier in
                eligibleBrowsers.first(where: {
                    $0.bundleIdentifier.lowercased() == bundleIdentifier
                })
            }.first
            guard let requestedBrowser = exactNameMatch
                ?? preferredBundleMatch
                ?? eligibleBrowsers.first(where: { Self.browser($0, matches: name) }) else {
                throw NativeDesktopControlError.applicationNotFound
            }
            return requestedBrowser
        }

        let applicationsByPID = Dictionary(
            uniqueKeysWithValues: eligibleBrowsers.map { ($0.processID, $0) }
        )
        let frontmostPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let frontmostPID, let frontmostBrowser = applicationsByPID[frontmostPID] {
            return frontmostBrowser
        }
        for window in Self.onscreenWindowRecords() where Self.isEligibleWindow(window) {
            if let visibleBrowser = applicationsByPID[window.processID] {
                return visibleBrowser
            }
        }
        return eligibleBrowsers[0]
    }

    private func waitForApplicationActivation(
        processID: pid_t,
        until deadline: Date
    ) async -> Bool {
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await MainActor.run(body: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(45))
        }
        return await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        }
    }

    private func currentNonAuroraApplication() async throws -> ApplicationRecord {
        let applications = await runningApplications()
        let applicationsByPID = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.processID, $0) }
        )
        let frontmostPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let frontmostPID,
           let frontmost = applicationsByPID[frontmostPID],
           Self.isEligibleTarget(frontmost),
           processScope.contains(frontmost.processID) {
            return frontmost
        }
        for window in Self.onscreenWindowRecords() where Self.isEligibleWindow(window) {
            if let application = applicationsByPID[window.processID],
               Self.isEligibleTarget(application),
               processScope.contains(application.processID) {
                return application
            }
        }
        throw NativeDesktopControlError.noEligibleApplication
    }

    /// Resolves an owner-named application before consulting focus. This is the
    /// shared target boundary for window and hide actions: a foreground app can
    /// never replace an explicit Chrome, Safari, or other supported app name.
    private func desktopApplicationTarget(
        named requestedName: String?
    ) async throws -> ApplicationRecord {
        guard let requestedName else {
            return try await currentNonAuroraApplication()
        }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidApplicationName(name) else {
            throw NativeDesktopControlError.invalidApplicationName
        }
        let applications = await runningApplications().filter {
            Self.isEligibleTarget($0) && processScope.contains($0.processID)
        }
        guard let target = Self.preferredApplication(in: applications, named: name) else {
            throw NativeDesktopControlError.applicationNotFound
        }
        return target
    }

    private func runningApplications() async -> [ApplicationRecord] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map {
                ApplicationRecord(
                    processID: $0.processIdentifier,
                    name: String(($0.localizedName ?? "Application").prefix(120)),
                    bundleIdentifier: String(($0.bundleIdentifier ?? "").prefix(240)),
                    isRegularApplication: $0.activationPolicy == .regular
                )
            }
        }
    }

    static func shortcut(for action: NativeDesktopAction) -> Shortcut? {
        switch action {
        case .back:
            return Shortcut(keyCode: 33, command: true, shift: false)
        case .forward:
            return Shortcut(keyCode: 30, command: true, shift: false)
        case .refresh:
            return Shortcut(keyCode: 15, command: true, shift: false)
        case .newTab:
            return Shortcut(keyCode: 17, command: true, shift: false)
        case .closeTab:
            return Shortcut(keyCode: 13, command: true, shift: false)
        case .reopenClosedTab:
            return Shortcut(keyCode: 17, command: true, shift: true)
        default:
            return nil
        }
    }

    /// Bundle identifiers accepted for a human browser name. Keeping aliases
    /// here makes explicit targets such as "Chrome" bind to Google Chrome
    /// without allowing fuzzy matches to an unrelated application.
    static func browserBundleIdentifierCandidates(for requestedName: String) -> Set<String> {
        Set(browserBundleIdentifierPreference(for: requestedName))
    }

    private static func browserBundleIdentifierPreference(
        for requestedName: String
    ) -> [String] {
        let normalized = normalizedApplicationName(requestedName)
        switch normalized {
        case "safari", "com.apple.safari":
            return ["com.apple.safari"]
        case "chrome", "google chrome", "com.google.chrome":
            return ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary"]
        case "chrome beta", "google chrome beta", "com.google.chrome.beta":
            return ["com.google.chrome.beta"]
        case "chrome canary", "google chrome canary", "com.google.chrome.canary":
            return ["com.google.chrome.canary"]
        case "edge", "microsoft edge", "com.microsoft.edgemac":
            return ["com.microsoft.edgemac"]
        case "edge beta", "microsoft edge beta", "com.microsoft.edgemac.beta":
            return ["com.microsoft.edgemac.beta"]
        case "edge canary", "microsoft edge canary", "com.microsoft.edgemac.canary":
            return ["com.microsoft.edgemac.canary"]
        case "brave", "brave browser", "com.brave.browser":
            return ["com.brave.browser"]
        case "arc", "company.thebrowser.browser":
            return ["company.thebrowser.browser"]
        case "firefox", "mozilla firefox", "org.mozilla.firefox":
            return ["org.mozilla.firefox"]
        case "firefox developer edition", "org.mozilla.firefoxdeveloperedition":
            return ["org.mozilla.firefoxdeveloperedition"]
        case "firefox nightly", "org.mozilla.nightly":
            return ["org.mozilla.nightly"]
        case "opera", "com.operasoftware.opera":
            return ["com.operasoftware.opera"]
        case "vivaldi", "com.vivaldi.vivaldi":
            return ["com.vivaldi.vivaldi"]
        default:
            return []
        }
    }

    private static func browser(
        _ application: ApplicationRecord,
        matches requestedName: String
    ) -> Bool {
        let candidates = browserBundleIdentifierCandidates(for: requestedName)
        if !candidates.isEmpty {
            return candidates.contains(application.bundleIdentifier.lowercased())
        }
        return normalizedApplicationName(application.name)
            == normalizedApplicationName(requestedName)
    }

    /// Pure postcondition classifier used both by native execution and the
    /// focused verifier. Tab actions require a directional tab/window-count
    /// change; navigation requires a changed document; refresh requires a
    /// loading transition or a replaced Accessibility document.
    static func browserShortcutEffectObserved(
        action: NativeDesktopAction,
        before: BrowserObservation,
        after: BrowserObservation,
        sawBusyState: Bool = false
    ) -> Bool {
        switch action {
        case .newTab, .reopenClosedTab:
            if let beforeCount = before.tabCount,
               let afterCount = after.tabCount,
               afterCount > beforeCount {
                return true
            }
            return after.windowCount > before.windowCount
        case .closeTab:
            if let beforeCount = before.tabCount,
               let afterCount = after.tabCount,
               afterCount < beforeCount {
                return true
            }
            return after.windowCount < before.windowCount
        case .back, .forward:
            if let beforeURL = before.documentURL,
               let afterURL = after.documentURL,
               !beforeURL.isEmpty,
               !afterURL.isEmpty,
               beforeURL != afterURL {
                return true
            }
            if let beforeDocument = before.documentIdentity,
               let afterDocument = after.documentIdentity,
               beforeDocument != afterDocument {
                return true
            }
            if let beforeTitle = before.windowTitle,
               let afterTitle = after.windowTitle,
               !beforeTitle.isEmpty,
               !afterTitle.isEmpty,
               beforeTitle != afterTitle {
                return true
            }
            return false
        case .refresh:
            if sawBusyState, after.isBusy != true { return true }
            if let beforeDocument = before.documentIdentity,
               let afterDocument = after.documentIdentity,
               beforeDocument != afterDocument {
                return true
            }
            return false
        default:
            return false
        }
    }

    private static func browserObservation(processID: pid_t) -> BrowserObservation {
        let application = AXUIElementCreateApplication(processID)
        let windows = axElements(application, attribute: kAXWindowsAttribute)
        let focusedWindow = frontWindow(
            for: processID,
            applicationElement: application,
            windows: windows
        )
        guard let focusedWindow else {
            return BrowserObservation(tabCount: nil, windowCount: windows.count)
        }

        let deadline = Date().addingTimeInterval(maximumBrowserObservationDuration)
        var queue = [MediaAccessibilityQueueEntry(element: focusedWindow, depth: 0)]
        var nextIndex = 0
        var visited = Set<CFHashCode>()
        var tabIdentities = Set<Int>()
        var attributedTabCount: Int?
        var documentIdentity: Int?
        var documentURL: String?
        var observedBusy: Bool?

        while nextIndex < queue.count,
              nextIndex < maximumBrowserObservationNodes,
              Date() < deadline {
            let entry = queue[nextIndex]
            nextIndex += 1
            let identity = CFHash(entry.element)
            guard visited.insert(identity).inserted else { continue }

            let role = axString(entry.element, attribute: kAXRoleAttribute)
            let subrole = axString(entry.element, attribute: kAXSubroleAttribute)
            if subrole == "AXTabButton" {
                tabIdentities.insert(Int(identity))
            }
            let tabs = axElements(entry.element, attribute: kAXTabsAttribute)
            if !tabs.isEmpty {
                attributedTabCount = max(attributedTabCount ?? 0, tabs.count)
            }
            if role == "AXWebArea" {
                if documentIdentity == nil { documentIdentity = Int(identity) }
                if documentURL == nil {
                    documentURL = axURLString(entry.element, attribute: kAXURLAttribute)
                }
                if let busy = axBool(entry.element, attribute: kAXElementBusyAttribute) {
                    observedBusy = (observedBusy == true) || busy
                }
            }

            guard entry.depth < maximumBrowserObservationDepth else { continue }
            let remainingCapacity = maximumBrowserObservationNodes - queue.count
            guard remainingCapacity > 0 else { continue }
            queue.append(contentsOf: axElements(
                entry.element,
                attribute: kAXChildrenAttribute
            ).prefix(remainingCapacity).map {
                MediaAccessibilityQueueEntry(element: $0, depth: entry.depth + 1)
            })
        }

        let tabCount = tabIdentities.isEmpty ? attributedTabCount : tabIdentities.count
        return BrowserObservation(
            tabCount: tabCount,
            windowCount: windows.count,
            focusedWindowIdentity: axIdentity(focusedWindow),
            documentIdentity: documentIdentity,
            documentURL: documentURL,
            windowTitle: axString(focusedWindow, attribute: kAXTitleAttribute),
            isBusy: observedBusy
        )
    }

    private static func actuateWindow(_ window: AXUIElement, close: Bool) {
        if close {
            guard let closeButton = axElement(window, attribute: kAXCloseButtonAttribute) else {
                return
            }
            _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            return
        }
        guard axBool(window, attribute: kAXMinimizedAttribute) != true else { return }
        _ = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private static func windowActionObservation(
        processID: pid_t,
        selectedIdentities: Set<Int>,
        initiallyActionableIdentities: Set<Int>,
        allWindows: Bool,
        close: Bool
    ) -> WindowActionObservation {
        let currentWindows = axElements(
            AXUIElementCreateApplication(processID),
            attribute: kAXWindowsAttribute
        )
        let currentIdentities = Set(currentWindows.map(axIdentity))
        let remainingSelectedIdentities: Set<Int>
        let remainingCount: Int
        let verified: Bool
        if close {
            remainingSelectedIdentities = selectedIdentities.intersection(currentIdentities)
            remainingCount = allWindows
                ? currentWindows.count
                : remainingSelectedIdentities.count
            verified = remainingCount == 0
        } else {
            let unminimizedIdentities = Set(currentWindows.compactMap { window in
                axBool(window, attribute: kAXMinimizedAttribute) == true
                    ? nil
                    : axIdentity(window)
            })
            remainingSelectedIdentities = initiallyActionableIdentities
                .intersection(unminimizedIdentities)
            remainingCount = allWindows
                ? unminimizedIdentities.count
                : remainingSelectedIdentities.count
            verified = remainingCount == 0
        }
        return WindowActionObservation(
            verified: verified,
            affectedCount: max(
                initiallyActionableIdentities.count - remainingSelectedIdentities.count,
                0
            ),
            remainingCount: remainingCount,
            remainingSelectedIdentities: remainingSelectedIdentities
        )
    }

    private static func axIdentity(_ element: AXUIElement) -> Int {
        Int(CFHash(element))
    }

    static func isValidApplicationName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 120 else { return false }
        return !name.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0 == "/" || $0 == "\\"
        }
    }

    private static func application(
        _ application: ApplicationRecord,
        matches requestedName: String
    ) -> Bool {
        applicationTargetMatches(
            applicationName: application.name,
            bundleIdentifier: application.bundleIdentifier,
            requestedName: requestedName
        )
    }

    /// Human browser aliases can match several installed channels. Prefer an
    /// exact display name, then the stable bundle ordering, before falling back
    /// to the exact general-app identity rule.
    private static func preferredApplication(
        in applications: [ApplicationRecord],
        named requestedName: String
    ) -> ApplicationRecord? {
        if let exactName = applications.first(where: {
            normalizedApplicationName($0.name)
                == normalizedApplicationName(requestedName)
        }) {
            return exactName
        }
        for bundleIdentifier in browserBundleIdentifierPreference(for: requestedName) {
            if let preferredBrowser = applications.first(where: {
                $0.bundleIdentifier.lowercased() == bundleIdentifier
            }) {
                return preferredBrowser
            }
        }
        return applications.first(where: { application($0, matches: requestedName) })
    }

    /// Pure test seam for the exact application identity rule used by native
    /// window/hide targeting. Deliberately no fuzzy or substring matching.
    static func applicationTargetMatches(
        applicationName: String,
        bundleIdentifier: String,
        requestedName: String
    ) -> Bool {
        let requested = normalizedApplicationName(requestedName)
        let normalizedBundleIdentifier = bundleIdentifier.lowercased()
        return normalizedApplicationName(applicationName) == requested
            || normalizedBundleIdentifier == requestedName.lowercased()
            || browserBundleIdentifierCandidates(for: requestedName)
                .contains(normalizedBundleIdentifier)
    }

    private static func normalizedApplicationName(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if result.hasSuffix(".app") { result.removeLast(4) }
        return result
    }

    @MainActor
    private static func installedApplicationURL(named name: String) -> URL? {
        if name.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        let expected = normalizedApplicationName(name)
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            if let match = children.first(where: {
                $0.pathExtension.lowercased() == "app"
                    && normalizedApplicationName($0.lastPathComponent) == expected
            }) {
                return match
            }
        }
        return nil
    }

    private static func isEligibleTarget(_ application: ApplicationRecord) -> Bool {
        application.isRegularApplication
            && !isAuroraApplication(application)
            && !isSystemUI(application)
    }

    private static func isAuroraApplication(_ application: ApplicationRecord) -> Bool {
        NativeScreenControl.isAuroraApplication(
            name: application.name,
            bundleIdentifier: application.bundleIdentifier,
            processID: application.processID
        )
    }

    private static func isSystemUI(_ application: ApplicationRecord) -> Bool {
        NativeScreenControl.isSystemUI(
            name: application.name,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private static func isSupportedBrowser(_ application: ApplicationRecord) -> Bool {
        let bundle = application.bundleIdentifier.lowercased()
        if [
            "com.apple.safari",
            "com.google.chrome",
            "com.google.chrome.beta",
            "com.google.chrome.canary",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.beta",
            "com.microsoft.edgemac.canary",
            "com.brave.browser",
            "company.thebrowser.browser",
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi",
        ].contains(bundle) {
            return true
        }
        let name = normalizedApplicationName(application.name)
        return [
            "safari", "google chrome", "chrome", "google chrome beta",
            "google chrome canary", "microsoft edge", "edge",
            "microsoft edge beta", "microsoft edge canary",
            "brave browser", "brave", "arc", "firefox",
            "firefox developer edition", "firefox nightly", "opera", "vivaldi",
        ].contains(name)
    }

    /// Classifies only exact, enabled, pressable play/pause buttons. Nearby
    /// text such as "Play next" or "Pause notifications" deliberately does
    /// not qualify, which prevents an Accessibility search from pressing an
    /// unrelated page control.
    static func semanticMediaPlaybackState(
        role: String?,
        labels: [String],
        isEnabled: Bool,
        supportsPress: Bool
    ) -> MediaPlaybackState? {
        let normalizedLabels = Set(labels.map(normalizedSemanticLabel))
        if normalizedLabels.contains("pause keyboard shortcut k") {
            return .playing
        }
        if normalizedLabels.contains("play keyboard shortcut k") {
            return .paused
        }
        guard role == (kAXButtonRole as String), isEnabled, supportsPress else {
            return nil
        }
        if !normalizedLabels.isDisjoint(with: ["pause", "pause (k)"]) {
            return .playing
        }
        if !normalizedLabels.isDisjoint(with: ["play", "play (k)"]) {
            return .paused
        }
        return nil
    }

    /// Searches only the browser's current front/focused window and stops at
    /// strict node, depth, and wall-clock bounds. Browser Accessibility trees
    /// normally expose only the active tab beneath that window, so this avoids
    /// changing media in a background tab or another browser window.
    private static func currentMediaControl(processID: pid_t) -> MediaControlMatch? {
        let application = AXUIElementCreateApplication(processID)
        let windows = axElements(application, attribute: kAXWindowsAttribute)
        guard let root = frontWindow(
            for: processID,
            applicationElement: application,
            windows: windows
        ) else { return nil }

        let deadline = Date().addingTimeInterval(maximumMediaAccessibilityScanDuration)
        var queue = [MediaAccessibilityQueueEntry(element: root, depth: 0)]
        var nextIndex = 0
        var visited = Set<CFHashCode>()
        var fallbackMatch: MediaControlMatch?

        while nextIndex < queue.count,
              nextIndex < maximumMediaAccessibilityNodes,
              Date() < deadline {
            let entry = queue[nextIndex]
            nextIndex += 1
            let identity = CFHash(entry.element)
            guard visited.insert(identity).inserted else { continue }

            let labels = [
                axString(entry.element, attribute: kAXTitleAttribute),
                axString(entry.element, attribute: kAXDescriptionAttribute),
                axString(entry.element, attribute: kAXHelpAttribute),
            ].compactMap { $0 }
            if let state = semanticMediaPlaybackState(
                role: axString(entry.element, attribute: kAXRoleAttribute),
                labels: labels,
                isEnabled: axBool(entry.element, attribute: kAXEnabledAttribute) != false,
                supportsPress: axActionNames(entry.element).contains(kAXPressAction as String)
            ) {
                let normalizedLabels = Set(labels.map(normalizedSemanticLabel))
                let match = MediaControlMatch(element: entry.element, state: state)
                // YouTube can retain an enabled but visually hidden central
                // "Play" overlay while the real player control says
                // "Pause (k)". Prefer the keyboard-labelled control, which
                // is the authoritative current playback state.
                if normalizedLabels.contains("pause (k)")
                    || normalizedLabels.contains("play (k)")
                    || normalizedLabels.contains("pause keyboard shortcut k")
                    || normalizedLabels.contains("play keyboard shortcut k") {
                    return match
                }
                if fallbackMatch == nil { fallbackMatch = match }
            }

            guard entry.depth < maximumMediaAccessibilityDepth else { continue }
            let remainingCapacity = maximumMediaAccessibilityNodes - queue.count
            guard remainingCapacity > 0 else { continue }
            let children = axElements(entry.element, attribute: kAXChildrenAttribute)
            queue.append(contentsOf: children.prefix(remainingCapacity).map {
                MediaAccessibilityQueueEntry(element: $0, depth: entry.depth + 1)
            })
        }
        return fallbackMatch
    }

    /// Returns the center of YouTube's semantic player group. Clicking this
    /// bounded native target toggles playback and exposes an accessible
    /// Play/Pause state without screenshots or model-directed coordinates.
    private static func currentMediaPlayerPoint(processID: pid_t) -> CGPoint? {
        let application = AXUIElementCreateApplication(processID)
        let windows = axElements(application, attribute: kAXWindowsAttribute)
        guard let root = frontWindow(
            for: processID,
            applicationElement: application,
            windows: windows
        ) else { return nil }

        let deadline = Date().addingTimeInterval(maximumMediaAccessibilityScanDuration)
        var queue = [MediaAccessibilityQueueEntry(element: root, depth: 0)]
        var nextIndex = 0
        var visited = Set<CFHashCode>()
        while nextIndex < queue.count,
              nextIndex < maximumMediaAccessibilityNodes,
              Date() < deadline {
            let entry = queue[nextIndex]
            nextIndex += 1
            guard visited.insert(CFHash(entry.element)).inserted else { continue }
            let labels = [
                axString(entry.element, attribute: kAXTitleAttribute),
                axString(entry.element, attribute: kAXDescriptionAttribute),
                axString(entry.element, attribute: kAXHelpAttribute),
            ].compactMap { $0 }.map(normalizedSemanticLabel)
            if labels.contains("youtube video player"),
               let bounds = axBounds(entry.element),
               bounds.width >= 40,
               bounds.height >= 40 {
                return CGPoint(
                    x: bounds.midX,
                    y: bounds.midY
                )
            }
            guard entry.depth < maximumMediaAccessibilityDepth else { continue }
            let remainingCapacity = maximumMediaAccessibilityNodes - queue.count
            guard remainingCapacity > 0 else { continue }
            queue.append(contentsOf: axElements(
                entry.element,
                attribute: kAXChildrenAttribute
            ).prefix(remainingCapacity).map {
                MediaAccessibilityQueueEntry(element: $0, depth: entry.depth + 1)
            })
        }
        return nil
    }

    private static func normalizedSemanticLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func axActionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let value else { return [] }
        return value as? [String] ?? []
    }

    private static func onscreenWindowRecords() -> [WindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return raw.compactMap { window in
            guard let processID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowRecord(
                processID: processID.int32Value,
                bounds: bounds,
                layer: layer.intValue,
                alpha: alpha
            )
        }
    }

    private static func visibleWindows(for processIDs: Set<pid_t>) -> [WindowRecord] {
        guard !processIDs.isEmpty else { return [] }
        return onscreenWindowRecords().filter {
            processIDs.contains($0.processID) && isEligibleWindow($0)
        }
    }

    /// Minimize all unminimized AX windows for an application that had at
    /// least one eligible visible window when the action began. We deliberately
    /// avoid activating applications, which would steal focus or reorder the
    /// user's desktop while the system-wide action is in progress.
    private static func minimizeAXWindows(for processID: pid_t) {
        let applicationElement = AXUIElementCreateApplication(processID)
        for window in axElements(applicationElement, attribute: kAXWindowsAttribute) {
            if axBool(window, attribute: kAXMinimizedAttribute) == true {
                continue
            }
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    private static func isEligibleWindow(_ window: WindowRecord) -> Bool {
        window.processID > 0
            && window.layer == 0
            && window.alpha > 0
            && window.bounds.width >= 120
            && window.bounds.height >= 80
    }

    private static func frontWindow(
        for processID: pid_t,
        applicationElement: AXUIElement,
        windows: [AXUIElement]
    ) -> AXUIElement? {
        // Prefer the application's own focused window. Matching solely by
        // bounds is ambiguous when two browser windows share the same size
        // and previously selected a background Chrome window.
        if let focused = axElement(
            applicationElement,
            attribute: kAXFocusedWindowAttribute
        ) {
            return focused
        }
        if let visibleBounds = onscreenWindowRecords().first(where: {
            $0.processID == processID && isEligibleWindow($0)
        })?.bounds,
           let match = windows.first(where: {
               guard let bounds = axBounds($0) else { return false }
               return boundsApproximatelyMatch(bounds, visibleBounds)
           }) {
            return match
        }
        return windows.first
    }

    private static func axElements(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func focusedTextArea(processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        if let focused = axElement(
            application,
            attribute: kAXFocusedUIElementAttribute
        ), let textArea = firstTextArea(in: focused, remainingDepth: 3) {
            return textArea
        }
        if let focusedWindow = axElement(
            application,
            attribute: kAXFocusedWindowAttribute
        ) {
            return firstTextArea(in: focusedWindow, remainingDepth: 8)
        }
        return nil
    }

    private static func firstTextArea(
        in element: AXUIElement,
        remainingDepth: Int
    ) -> AXUIElement? {
        if axString(element, attribute: kAXRoleAttribute) == (kAXTextAreaRole as String) {
            return element
        }
        guard remainingDepth > 0 else { return nil }
        for child in axElements(element, attribute: kAXChildrenAttribute) {
            if let match = firstTextArea(in: child, remainingDepth: remainingDepth - 1) {
                return match
            }
        }
        return nil
    }

    private static func axStringValue(_ element: AXUIElement) -> String? {
        axString(element, attribute: kAXValueAttribute)
    }

    private static func axString(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func axURLString(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func axElement(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private static func axBounds(_ element: AXUIElement) -> CGRect? {
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionReference
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeReference
        ) == .success,
        let positionReference,
        let sizeReference,
        CFGetTypeID(positionReference) == AXValueGetTypeID(),
        CFGetTypeID(sizeReference) == AXValueGetTypeID() else { return nil }

        let positionValue = positionReference as! AXValue
        let sizeValue = sizeReference as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func boundsApproximatelyMatch(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 4
            && abs(first.minY - second.minY) <= 4
            && abs(first.width - second.width) <= 8
            && abs(first.height - second.height) <= 8
    }

    private static func post(_ shortcut: Shortcut) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: shortcut.keyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: shortcut.keyCode,
                  keyDown: false
              ) else { return false }
        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.shift { flags.insert(.maskShift) }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postLeftClick(at point: CGPoint) -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func spokenName(for action: NativeDesktopAction) -> String {
        switch action {
        case .back: return "Back"
        case .forward: return "Forward"
        case .refresh: return "Refresh"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reopenClosedTab: return "Reopen Closed Tab"
        default: return "the requested action"
        }
    }
}
