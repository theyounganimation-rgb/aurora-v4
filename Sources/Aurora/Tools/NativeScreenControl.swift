import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The one category of visible action the owner authorized in the finalized owner
/// utterance that caused a screen observation. This is an execution scope, not
/// a risk score: screen pixels and Accessibility labels may confirm that a
/// target fits the scope, but they can never create or widen it.
public enum NativeScreenActionScope: String, Codable, Sendable, Equatable, CaseIterable {
    case ordinary
    case send
    case delete
    case purchase
    case submit
    case authenticate
    case password
    case permission
    case accountControl = "account_control"
}

/// Opaque evidence prepared by the owner-transcript boundary before a capture.
/// NativeScreenControl deliberately receives no raw transcript. It only binds
/// the approved scope to a SHA-256 digest and requires the identical pair at
/// actuation time, which prevents an image continuation from self-authorizing.
public struct NativeScreenActionAuthorization: Codable, Sendable, Equatable {
    public let scope: NativeScreenActionScope
    public let evidenceDigest: String

    public init(scope: NativeScreenActionScope, evidenceDigest: String) {
        self.scope = scope
        self.evidenceDigest = evidenceDigest.lowercased()
    }

    /// Backward-compatible ordinary navigation capability. New owner-facing
    /// call sites should provide the digest of the actual finalized utterance.
    public static let ordinary = NativeScreenActionAuthorization(
        scope: .ordinary,
        evidenceDigest: String(repeating: "0", count: 64)
    )

    fileprivate var isStructurallyValid: Bool {
        evidenceDigest.utf8.count == 64
            && evidenceDigest.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }
}

/// A Codable representation of the global macOS window bounds associated
/// with a visual observation. Coordinates use the same top-left global space
/// as ScreenCaptureKit, AX hit testing, and synthetic pointer events.
public struct NativeScreenBounds: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A single, memory-only visual observation. `imageDataURI` contains a
/// bounded JPEG and can be passed directly to an image-capable model input.
public struct NativeScreenSnapshotResult: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let imageDataURI: String
    public let mimeType: String
    public let jpegByteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let windowID: UInt32
    public let processID: Int32
    public let applicationName: String
    public let windowTitle: String
    public let bounds: NativeScreenBounds
    public let capturedAt: Date
    public let expiresAt: Date

    public init(
        snapshotID: String,
        imageDataURI: String,
        mimeType: String = "image/jpeg",
        jpegByteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        windowID: UInt32,
        processID: Int32,
        applicationName: String,
        windowTitle: String,
        bounds: NativeScreenBounds,
        capturedAt: Date,
        expiresAt: Date
    ) {
        self.snapshotID = snapshotID
        self.imageDataURI = imageDataURI
        self.mimeType = mimeType
        self.jpegByteCount = jpegByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.windowID = windowID
        self.processID = processID
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.bounds = bounds
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
    }
}

public enum NativeScreenClickMethod: String, Codable, Sendable, Equatable {
    case accessibilityPress = "accessibility_press"
    case accessibilityResolvedPointer = "accessibility_resolved_pointer"
    case coreGraphicsPointer = "core_graphics_pointer"
}

/// Current macOS consent state for Aurora's two visual capabilities. Merely
/// appearing in System Settings is not a grant; the relevant switches must be
/// on and these preflight checks must agree.
public struct NativeScreenPermissionStatus: Sendable, Equatable {
    public let screenCaptureAllowed: Bool
    public let accessibilityAllowed: Bool
    public let pointerControlAllowed: Bool

    public var canLook: Bool { screenCaptureAllowed }
    public var canClick: Bool { accessibilityAllowed && pointerControlAllowed }
}

/// A deliberately small receipt. Accessibility labels and values are never
/// copied into it, because they can contain private material even when the
/// requested control itself is harmless.
public struct NativeScreenClickResult: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let method: NativeScreenClickMethod
    public let targetDescription: String
    public let normalizedX: Int
    public let normalizedY: Int
    public let screenX: Double
    public let screenY: Double
    public let windowID: UInt32
    public let processID: Int32
    public let applicationName: String
    /// True only when macOS exposed a changed window identity or title after
    /// actuation. A false value still means the input event was posted; it
    /// deliberately does not claim that the intended page effect occurred.
    public let effectObserved: Bool

    public init(
        snapshotID: String,
        method: NativeScreenClickMethod,
        targetDescription: String,
        normalizedX: Int,
        normalizedY: Int,
        screenX: Double,
        screenY: Double,
        windowID: UInt32,
        processID: Int32,
        applicationName: String,
        effectObserved: Bool = false
    ) {
        self.snapshotID = snapshotID
        self.method = method
        self.targetDescription = targetDescription
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.screenX = screenX
        self.screenY = screenY
        self.windowID = windowID
        self.processID = processID
        self.applicationName = applicationName
        self.effectObserved = effectObserved
    }
}

public enum NativeScreenControlError: LocalizedError, Sendable, Equatable {
    case invalidAuthorizationEvidence
    case authorizationMismatch
    case actionScopeMismatch
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case pointerControlPermissionDenied
    case noEligibleWindow
    case protectedApplication
    case protectedWindow
    case snapshotUnavailable
    case snapshotMismatch
    case snapshotExpired
    case invalidCoordinate
    case invalidTargetDescription
    case windowChanged
    case captureFailed
    case imageEncodingFailed
    case captureSuperseded
    case targetCouldNotBeInspected
    case sensitiveTarget
    case consequentialTarget
    case captchaTarget
    case targetMismatch
    case clickFailed

    var diagnosticCode: String {
        switch self {
        case .invalidAuthorizationEvidence: return "invalid_authorization_evidence"
        case .authorizationMismatch: return "authorization_mismatch"
        case .actionScopeMismatch: return "action_scope_mismatch"
        case .screenRecordingPermissionDenied: return "screen_recording_permission_denied"
        case .accessibilityPermissionDenied: return "accessibility_permission_denied"
        case .pointerControlPermissionDenied: return "pointer_control_permission_denied"
        case .noEligibleWindow: return "no_eligible_window"
        case .protectedApplication: return "protected_application"
        case .protectedWindow: return "protected_window"
        case .snapshotUnavailable: return "snapshot_unavailable"
        case .snapshotMismatch: return "snapshot_mismatch"
        case .snapshotExpired: return "snapshot_expired"
        case .invalidCoordinate: return "invalid_coordinate"
        case .invalidTargetDescription: return "invalid_target_description"
        case .windowChanged: return "window_changed"
        case .captureFailed: return "capture_failed"
        case .imageEncodingFailed: return "image_encoding_failed"
        case .captureSuperseded: return "capture_superseded"
        case .targetCouldNotBeInspected: return "target_could_not_be_inspected"
        case .sensitiveTarget: return "sensitive_target"
        case .consequentialTarget: return "consequential_target"
        case .captchaTarget: return "captcha_target"
        case .targetMismatch: return "target_mismatch"
        case .clickFailed: return "click_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationEvidence:
            return "Aurora could not verify current owner authorization for that screen action."
        case .authorizationMismatch:
            return "That screen action no longer matches the owner authorization that created the view."
        case .actionScopeMismatch:
            return "The visible target does not match the exact screen action the owner authorized."
        case .screenRecordingPermissionDenied:
            return "Aurora needs Screen Recording permission before she can look at a window."
        case .accessibilityPermissionDenied:
            return "macOS currently reports Aurora's Accessibility switch is off. Turn Aurora on in Privacy & Security, Accessibility, then return to Aurora."
        case .pointerControlPermissionDenied:
            return "macOS has not allowed Aurora to control the pointer. Turn Aurora on in Privacy & Security, Accessibility, then fully reopen Aurora."
        case .noEligibleWindow:
            return "There is no visible user window Aurora can safely inspect."
        case .protectedApplication:
            return "That application requires an exact current owner authorization for this kind of screen action."
        case .protectedWindow:
            return "That window requires an exact current owner authorization for this kind of screen action."
        case .snapshotUnavailable:
            return "Aurora needs a fresh screen observation before she can click."
        case .snapshotMismatch:
            return "That click did not refer to Aurora's latest screen observation."
        case .snapshotExpired:
            return "That screen observation is too old to click safely."
        case .invalidCoordinate:
            return "Screen coordinates must be whole numbers from 0 through 1000."
        case .invalidTargetDescription:
            return "A short, non-sensitive description of the intended target is required."
        case .windowChanged:
            return "That target moved before Aurora could click it."
        case .captureFailed:
            return "macOS could not capture that window."
        case .imageEncodingFailed:
            return "Aurora could not prepare a safely bounded screen image."
        case .captureSuperseded:
            return "That screen observation was replaced before it finished."
        case .targetCouldNotBeInspected:
            return "Aurora could not verify that screen target through macOS Accessibility."
        case .sensitiveTarget:
            return "That control does not match the exact sensitive action the owner authorized."
        case .consequentialTarget:
            return "That control does not match the exact consequential action the owner authorized."
        case .captchaTarget:
            return "Aurora cannot complete a CAPTCHA or human-verification challenge."
        case .targetMismatch:
            return "The current screen target no longer matches the item Aurora intended to click."
        case .clickFailed:
            return "macOS could not safely click that target."
        }
    }

    var permissionFailureCode: String? {
        switch self {
        case .screenRecordingPermissionDenied: return "screen_capture"
        case .accessibilityPermissionDenied: return "accessibility"
        case .pointerControlPermissionDenied: return "pointer_control"
        default: return nil
        }
    }
}

/// Native visual control is deliberately snapshot-bound: observation creates
/// one short-lived capability and every click consumes it, whether the click
/// succeeds or fails. Nothing in this actor writes image or AX data to disk.
public actor NativeScreenControl {
    public struct Configuration: Sendable, Equatable {
        public var maximumSnapshotAge: TimeInterval
        public var maximumJPEGBytes: Int
        public var maximumPixelDimension: Int

        public init(
            maximumSnapshotAge: TimeInterval = 12,
            maximumJPEGBytes: Int = 65 * 1_024,
            maximumPixelDimension: Int = 1_440
        ) {
            // Twelve seconds and roughly 65 KiB are hard safety ceilings, not
            // merely defaults callers can accidentally widen.
            self.maximumSnapshotAge = min(max(maximumSnapshotAge, 1), 12)
            self.maximumJPEGBytes = min(max(maximumJPEGBytes, 8 * 1_024), 65 * 1_024)
            self.maximumPixelDimension = min(max(maximumPixelDimension, 320), 1_920)
        }
    }

    private struct SnapshotContext: Sendable {
        let snapshotID: String
        let windowID: CGWindowID
        let processID: pid_t
        let applicationName: String
        let bundleIdentifier: String
        let windowTitle: String
        let bounds: CGRect
        let capturedAt: Date
        let authorization: NativeScreenActionAuthorization
        let windowActionScopes: Set<NativeScreenActionScope>
    }

    private struct OnscreenWindowRecord: Sendable, Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    private struct SelectedWindow {
        let window: SCWindow
        let record: OnscreenWindowRecord
        let applicationName: String
        let bundleIdentifier: String
        let title: String
        let actionScopes: Set<NativeScreenActionScope>
    }

    private struct AccessibilityInspection {
        let hierarchy: [AXUIElement]
        let labels: [String]
        let pressableElement: AXUIElement?
        let windowElement: AXUIElement?
        let actionScopes: Set<NativeScreenActionScope>
    }

    private struct SemanticAccessibilityCandidate {
        let element: AXUIElement
        let score: Int
        let distance: CGFloat
    }

    private let configuration: Configuration
    private var latestSnapshot: SnapshotContext?
    private var captureGeneration: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Prompts for Screen Recording only when an observation is explicitly
    /// requested, then captures just the frontmost eligible non-Aurora window.
    public func captureFrontmostWindow(
        authorization: NativeScreenActionAuthorization = .ordinary,
        preferDominantWindow: Bool = false
    ) async throws -> NativeScreenSnapshotResult {
        captureGeneration &+= 1
        let generation = captureGeneration
        latestSnapshot = nil
        guard authorization.isStructurallyValid else {
            throw NativeScreenControlError.invalidAuthorizationEvidence
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NativeScreenControlError.screenRecordingPermissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw NativeScreenControlError.captureFailed
        }

        let selected = try selectFrontmostWindow(
            from: content,
            authorization: authorization,
            preferDominantWindow: preferDominantWindow
        )
        let filter = SCContentFilter(desktopIndependentWindow: selected.window)
        let streamConfiguration = SCStreamConfiguration()

        let scale = max(Double(SCShareableContent.info(for: filter).pointPixelScale), 1)
        let nativeWidth = max(selected.record.bounds.width * scale, 1)
        let nativeHeight = max(selected.record.bounds.height * scale, 1)
        let dimensionScale = min(
            1,
            Double(configuration.maximumPixelDimension) / max(nativeWidth, nativeHeight)
        )
        streamConfiguration.width = max(Int((nativeWidth * dimensionScale).rounded()), 1)
        streamConfiguration.height = max(Int((nativeHeight * dimensionScale).rounded()), 1)
        streamConfiguration.scalesToFit = true
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = false
        streamConfiguration.ignoreShadowsSingleWindow = true

        let capturedImage: CGImage
        do {
            capturedImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: streamConfiguration
            )
        } catch {
            throw NativeScreenControlError.captureFailed
        }

        let encoded: (data: Data, image: CGImage)
        do {
            encoded = try Self.boundedJPEG(
                from: capturedImage,
                maximumBytes: configuration.maximumJPEGBytes,
                maximumDimension: configuration.maximumPixelDimension
            )
        } catch {
            throw NativeScreenControlError.imageEncodingFailed
        }

        let now = Date()
        guard generation == captureGeneration, !Task.isCancelled else {
            throw NativeScreenControlError.captureSuperseded
        }
        let snapshotID = UUID().uuidString.lowercased()
        let context = SnapshotContext(
            snapshotID: snapshotID,
            windowID: selected.record.windowID,
            processID: selected.record.processID,
            applicationName: Self.boundedText(selected.applicationName, maximumCharacters: 120),
            bundleIdentifier: Self.boundedText(selected.bundleIdentifier, maximumCharacters: 240),
            windowTitle: Self.boundedText(selected.title, maximumCharacters: 240),
            bounds: selected.record.bounds,
            capturedAt: now,
            authorization: authorization,
            windowActionScopes: selected.actionScopes
        )
        latestSnapshot = context

        return NativeScreenSnapshotResult(
            snapshotID: snapshotID,
            imageDataURI: "data:image/jpeg;base64,\(encoded.data.base64EncodedString())",
            jpegByteCount: encoded.data.count,
            pixelWidth: encoded.image.width,
            pixelHeight: encoded.image.height,
            windowID: selected.record.windowID,
            processID: selected.record.processID,
            applicationName: context.applicationName,
            windowTitle: context.windowTitle,
            bounds: NativeScreenBounds(context.bounds),
            capturedAt: now,
            expiresAt: now.addingTimeInterval(configuration.maximumSnapshotAge)
        )
    }

    /// Consumes the latest snapshot and attempts exactly one click. The window
    /// identity and geometry are checked before permissions, after any prompt,
    /// and again before pointer-event fallback.
    public func click(
        snapshotID: String,
        normalizedX: Int,
        normalizedY: Int,
        targetDescription: String,
        authorization: NativeScreenActionAuthorization = .ordinary
    ) async throws -> NativeScreenClickResult {
        guard let snapshot = latestSnapshot else {
            throw NativeScreenControlError.snapshotUnavailable
        }
        guard snapshot.snapshotID == snapshotID else {
            throw NativeScreenControlError.snapshotMismatch
        }

        // Matching snapshots are one-use capabilities. Clearing immediately
        // also covers cancellation and every failure path below.
        latestSnapshot = nil
        captureGeneration &+= 1
        let actuationGeneration = captureGeneration

        guard authorization.isStructurallyValid else {
            throw NativeScreenControlError.invalidAuthorizationEvidence
        }
        guard authorization == snapshot.authorization else {
            throw NativeScreenControlError.authorizationMismatch
        }
        guard Self.isNormalizedCoordinate(normalizedX),
              Self.isNormalizedCoordinate(normalizedY) else {
            throw NativeScreenControlError.invalidCoordinate
        }
        let target = targetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTargetDescription(target) else {
            throw NativeScreenControlError.invalidTargetDescription
        }
        guard Self.isSnapshotFresh(
            capturedAt: snapshot.capturedAt,
            now: Date(),
            maximumAge: configuration.maximumSnapshotAge
        ) else {
            throw NativeScreenControlError.snapshotExpired
        }

        guard var point = Self.normalizedPoint(
            x: normalizedX,
            y: normalizedY,
            in: snapshot.bounds
        ) else {
            throw NativeScreenControlError.invalidCoordinate
        }

        // Revalidation is point-specific. A non-overlapping browser popover
        // or a higher-layer macOS surface such as Dock must not make an
        // otherwise visible target look stale.
        try revalidate(snapshot, point: point)
        try requireClickPermissionsWithoutPrompt()
        try revalidate(snapshot, point: point)

        let inspection: AccessibilityInspection?
        do {
            inspection = try inspectAccessibilityTarget(
                processID: snapshot.processID,
                point: point
            )
        } catch NativeScreenControlError.targetCouldNotBeInspected
                    where authorization.scope == .ordinary {
            // Some canvases, video surfaces, and browser-owned regions expose
            // no usable element at the visual coordinate. A current ordinary
            // owner request remains coordinate-capable under the one-use view.
            inspection = nil
        }
        if Self.requiresAccessibilityLabelMatch(for: authorization.scope) {
            guard let inspection,
                  Self.targetDescription(target, matchesAny: inspection.labels) else {
                throw NativeScreenControlError.targetMismatch
            }
        }
        var usedSemanticPointerResolution = false
        if authorization.scope == .ordinary,
           let inspection,
           Self.ordinaryVideoTargetConflictsWithNavigationLabels(
               targetDescription: target,
               labels: inspection.labels
           ) {
            throw NativeScreenControlError.targetMismatch
        }
        guard !Self.containsCAPTCHAChallenge(target),
              !(inspection?.labels.contains(where: Self.containsCAPTCHAChallenge) ?? false) else {
            throw NativeScreenControlError.captchaTarget
        }
        let targetScopes = Self.actionScopes(in: target).union(inspection?.actionScopes ?? [])
        guard Self.actionScopeMatches(
            authorization.scope,
            targetScopes: targetScopes,
            windowScopes: snapshot.windowActionScopes
        ) else {
            throw NativeScreenControlError.actionScopeMismatch
        }

        // Browser thumbnails commonly expose only an unlabeled AXGroup at the
        // pictured coordinate while the adjacent title is an exact, pressable
        // AXLink. For ordinary navigation, resolve a distinctive requested
        // title within this same captured window before falling back to raw
        // pixels. Generic requests such as "a random video" deliberately do
        // not qualify for semantic actuation.
        if authorization.scope == .ordinary,
           let semanticTarget = semanticAccessibilityTarget(
               snapshot: snapshot,
               inspection: inspection,
               targetDescription: target,
               preferredPoint: point
           ) {
            // Chrome can report AXPress success for a web link without
            // dispatching the page action. Resolve the exact semantic frame,
            // then perform one pointer actuation below. Never AXPress and then
            // pointer-click the same control merely because a generic title
            // heuristic did not change; same-page controls could otherwise
            // send, toggle, or purchase twice.
            if let semanticFrame = Self.axBounds(semanticTarget) {
                let semanticPoint = CGPoint(x: semanticFrame.midX, y: semanticFrame.midY)
                if snapshot.bounds.contains(semanticPoint) {
                    point = semanticPoint
                    usedSemanticPointerResolution = true
                }
            }
            if !usedSemanticPointerResolution {
                guard actuationGeneration == captureGeneration else {
                    throw NativeScreenControlError.snapshotMismatch
                }
                try revalidate(snapshot, point: point)
                let effectBaseline = Self.onscreenWindowIdentities(
                    processID: snapshot.processID
                )
                let pressResult = try Self.performActuationIfNotCancelled {
                    AXUIElementPerformAction(semanticTarget, kAXPressAction as CFString)
                }
                guard pressResult == .success else {
                    throw NativeScreenControlError.clickFailed
                }
                let effectObserved = await observeWindowEffect(
                    processID: snapshot.processID,
                    baseline: effectBaseline
                )
                return makeClickResult(
                    snapshot: snapshot,
                    target: target,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    point: point,
                    method: .accessibilityPress,
                    effectObserved: effectObserved
                )
            }
        }

        // Visual ordinary navigation should behave like a human pointer at the
        // chosen pixels. Pressing an arbitrary AX ancestor can activate a
        // different nested browser control than the screenshot target.
        if authorization.scope != .ordinary,
           let pressable = inspection?.pressableElement {
            guard actuationGeneration == captureGeneration else {
                throw NativeScreenControlError.snapshotMismatch
            }
            let effectBaseline = Self.onscreenWindowIdentities(
                processID: snapshot.processID
            )
            let pressResult = try Self.performActuationIfNotCancelled {
                AXUIElementPerformAction(pressable, kAXPressAction as CFString)
            }
            if pressResult == .success {
                let effectObserved = await observeWindowEffect(
                    processID: snapshot.processID,
                    baseline: effectBaseline
                )
                return makeClickResult(
                    snapshot: snapshot,
                    target: target,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    point: point,
                    method: .accessibilityPress,
                    effectObserved: effectObserved
                )
            }
        }

        // Some visual surfaces (video thumbnails and canvases in particular)
        // expose a safe AX hierarchy but no AXPress action. Raise the same AX
        // window, activate its app, revalidate, then use a normal pointer click.
        try Task.checkCancellation()
        if let windowElement = inspection?.windowElement {
            _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        }
        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: snapshot.processID)?.activate(
                options: [.activateAllWindows]
            ) == true
        }
        guard activated else {
            throw NativeScreenControlError.clickFailed
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        guard actuationGeneration == captureGeneration else {
            throw NativeScreenControlError.snapshotMismatch
        }
        let targetIsFrontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID
        }
        guard targetIsFrontmost else {
            throw NativeScreenControlError.windowChanged
        }
        try revalidate(snapshot, point: point)

        guard CGPreflightPostEventAccess(),
              let move = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            throw NativeScreenControlError.clickFailed
        }
        let effectBaseline = Self.onscreenWindowIdentities(
            processID: snapshot.processID
        )
        try Self.performActuationIfNotCancelled {
            move.post(tap: .cghidEventTap)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        let effectObserved = await observeWindowEffect(
            processID: snapshot.processID,
            baseline: effectBaseline
        )
        return makeClickResult(
            snapshot: snapshot,
            target: target,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            point: point,
            method: usedSemanticPointerResolution
                ? .accessibilityResolvedPointer
                : .coreGraphicsPointer,
            effectObserved: effectObserved
        )
    }

    public func invalidateSnapshot() {
        captureGeneration &+= 1
        latestSnapshot = nil
    }

    /// A no-prompt status read used before spending an image/model turn on a
    /// click request that macOS cannot currently execute.
    public func permissionStatus() -> NativeScreenPermissionStatus {
        NativeScreenPermissionStatus(
            screenCaptureAllowed: CGPreflightScreenCaptureAccess(),
            accessibilityAllowed: AXIsProcessTrusted(),
            pointerControlAllowed: CGPreflightPostEventAccess()
        )
    }

    /// Request and verify click readiness before capturing a view for a click.
    /// This never grants its own authority; macOS and the owner remain the consent
    /// boundaries.
    public func prepareForClick() throws {
        try requestClickPermissions()
    }

    private func selectFrontmostWindow(
        from content: SCShareableContent,
        authorization: NativeScreenActionAuthorization,
        preferDominantWindow: Bool
    ) throws -> SelectedWindow {
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

        var frontmostCandidate: SelectedWindow?

        for record in Self.onscreenWindowRecords() {
            guard record.layer == 0,
                  record.alpha > 0,
                  record.processID > 0,
                  record.bounds.width >= 120,
                  record.bounds.height >= 80,
                  let window = windowsByID[record.windowID],
                  window.isOnScreen,
                  let application = window.owningApplication,
                  application.processID == record.processID,
                  Self.boundsMatch(record.bounds, window.frame) else {
                continue
            }

            let name = application.applicationName
            let bundleIdentifier = application.bundleIdentifier
            if Self.isAuroraApplication(
                name: name,
                bundleIdentifier: bundleIdentifier,
                processID: record.processID
            ) {
                continue
            }

            var applicationScopes = Self.applicationActionScopes(
                name: name,
                bundleIdentifier: bundleIdentifier
            )
            if Self.isSystemUI(name: name, bundleIdentifier: bundleIdentifier) {
                let systemScopes = Self.systemUIActionScopes(
                    name: name,
                    bundleIdentifier: bundleIdentifier
                )
                // Background shell surfaces such as Dock and WindowServer are
                // not eligible windows. Authentication and permission surfaces
                // remain eligible only under their pre-existing owner scope.
                guard !systemScopes.isEmpty else { continue }
                applicationScopes.formUnion(systemScopes)
            }
            if !applicationScopes.isEmpty,
               !applicationScopes.contains(authorization.scope) {
                throw NativeScreenControlError.protectedApplication
            }
            let title = window.title ?? ""
            // System Settings and password managers are ordinary applications
            // for navigation purposes. Their actual password fields,
            // authentication buttons, permission controls, and other
            // consequential targets remain classified from AX at the point of
            // action; the application/window shell itself does not block a
            // harmless click.
            let permitsOrdinaryApplicationNavigation =
                authorization.scope == .ordinary
                && Self.permitsOrdinaryApplicationNavigation(
                    name: name,
                    bundleIdentifier: bundleIdentifier
                )
            let windowScopes = permitsOrdinaryApplicationNavigation
                ? []
                : Self.windowActionScopes(title)
            if !windowScopes.isEmpty,
               !windowScopes.contains(authorization.scope) {
                throw NativeScreenControlError.protectedWindow
            }
            let candidate = SelectedWindow(
                window: window,
                record: record,
                applicationName: name,
                bundleIdentifier: bundleIdentifier,
                title: title,
                actionScopes: applicationScopes.union(windowScopes)
            )

            guard preferDominantWindow,
                  authorization.scope == .ordinary else {
                return candidate
            }

            guard let frontmostCandidate else {
                frontmostCandidate = candidate
                continue
            }

            // Dominant selection never clicks through a different app. It
            // only replaces a small transient window with a substantially
            // larger content window belonging to that same frontmost app.
            guard candidate.record.processID == frontmostCandidate.record.processID else {
                return frontmostCandidate
            }
            if Self.shouldPreferDominantWindow(
                frontmost: frontmostCandidate.record.bounds,
                candidate: candidate.record.bounds
            ) {
                return candidate
            }
        }
        if let frontmostCandidate { return frontmostCandidate }
        throw NativeScreenControlError.noEligibleWindow
    }

    private func requestClickPermissions() throws {
        var accessibilityTrusted = AXIsProcessTrusted()
        if !accessibilityTrusted {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            accessibilityTrusted = AXIsProcessTrustedWithOptions(
                [promptKey: true] as CFDictionary
            )
        }

        guard accessibilityTrusted else {
            throw NativeScreenControlError.accessibilityPermissionDenied
        }

        var postEventTrusted = CGPreflightPostEventAccess()
        if !postEventTrusted {
            postEventTrusted = CGRequestPostEventAccess()
        }
        guard postEventTrusted else {
            throw NativeScreenControlError.pointerControlPermissionDenied
        }
    }

    private func requireClickPermissionsWithoutPrompt() throws {
        guard AXIsProcessTrusted() else {
            throw NativeScreenControlError.accessibilityPermissionDenied
        }
        guard CGPreflightPostEventAccess() else {
            throw NativeScreenControlError.pointerControlPermissionDenied
        }
    }

    private func revalidate(
        _ snapshot: SnapshotContext,
        requireFrontmost: Bool = true,
        point: CGPoint? = nil
    ) throws {
        guard Self.isSnapshotFresh(
            capturedAt: snapshot.capturedAt,
            now: Date(),
            maximumAge: configuration.maximumSnapshotAge
        ) else {
            throw NativeScreenControlError.snapshotExpired
        }

        let records = Self.onscreenWindowRecords()
        guard let current = records.first(where: { $0.windowID == snapshot.windowID }),
              current.processID == snapshot.processID,
              current.layer == 0,
              current.alpha > 0,
              Self.boundsMatch(current.bounds, snapshot.bounds) else {
            throw NativeScreenControlError.windowChanged
        }

        guard requireFrontmost, let point else { return }
        for record in records.prefix(while: { $0.windowID != snapshot.windowID }) {
            guard Self.windowRecordCanOccludeClick(
                layer: record.layer,
                alpha: record.alpha,
                bounds: record.bounds,
                point: point
            ) else { continue }
            guard let running = NSRunningApplication(processIdentifier: record.processID) else {
                continue
            }
            let name = running.localizedName ?? ""
            let bundle = running.bundleIdentifier ?? ""
            if Self.isAuroraApplication(
                name: name,
                bundleIdentifier: bundle,
                processID: record.processID
            ) || Self.isSystemUI(name: name, bundleIdentifier: bundle) {
                continue
            }
            throw NativeScreenControlError.windowChanged
        }
    }

    private func inspectAccessibilityTarget(
        processID: pid_t,
        point: CGPoint
    ) throws -> AccessibilityInspection {
        let application = AXUIElementCreateApplication(processID)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement else {
            throw NativeScreenControlError.targetCouldNotBeInspected
        }

        var hierarchy: [AXUIElement] = []
        var collectedLabels: [String] = []
        var current: AXUIElement? = hitElement
        var seen = Set<CFHashCode>()
        var windowElement: AXUIElement?
        var collectedActionableLabels = false
        var collectedActionScopes = Set<NativeScreenActionScope>()

        while let element = current, hierarchy.count < 12 {
            let identity = CFHash(element)
            guard seen.insert(identity).inserted else { break }
            hierarchy.append(element)

            let role = Self.axString(element, attribute: kAXRoleAttribute as CFString) ?? ""
            let subrole = Self.axString(element, attribute: kAXSubroleAttribute as CFString) ?? ""
            var labels = [
                Self.axString(element, attribute: kAXTitleAttribute as CFString),
                Self.axString(element, attribute: kAXDescriptionAttribute as CFString),
                Self.axString(element, attribute: kAXHelpAttribute as CFString),
                Self.axString(element, attribute: kAXRoleDescriptionAttribute as CFString),
                Self.axString(element, attribute: kAXIdentifierAttribute as CFString),
                Self.axString(element, attribute: kAXPlaceholderValueAttribute as CFString),
            ].compactMap { $0 }

            if let titleElement = Self.axElement(
                element,
                attribute: kAXTitleUIElementAttribute as CFString
            ) {
                labels.append(contentsOf: [
                    Self.axString(titleElement, attribute: kAXTitleAttribute as CFString),
                    Self.axString(titleElement, attribute: kAXDescriptionAttribute as CFString),
                    Self.axString(titleElement, attribute: kAXPlaceholderValueAttribute as CFString),
                ].compactMap { $0 })
            }
            let elementIsPressable = Self.axActionNames(element).contains(kAXPressAction as String)
            if hierarchy.count == 1 || (!collectedActionableLabels && elementIsPressable) {
                collectedLabels.append(contentsOf: labels)
                collectedActionScopes.formUnion(Self.accessibilityActionScopes(
                    role: role,
                    subrole: subrole,
                    labels: labels
                ))
                if elementIsPressable { collectedActionableLabels = true }
            }
            if role.caseInsensitiveCompare(kAXWindowRole as String) == .orderedSame {
                windowElement = element
            }
            current = Self.axElement(element, attribute: kAXParentAttribute as CFString)
        }

        let pressable = hierarchy.first { element in
            guard Self.axBoolean(element, attribute: kAXEnabledAttribute as CFString) != false else {
                return false
            }
            return Self.axActionNames(element).contains(kAXPressAction as String)
        }
        return AccessibilityInspection(
            hierarchy: hierarchy,
            labels: collectedLabels,
            pressableElement: pressable,
            windowElement: windowElement,
            actionScopes: collectedActionScopes
        )
    }

    /// Searches only the Accessibility subtree belonging to the captured
    /// window. The search is bounded by both node count and wall time so a
    /// complex browser document cannot stall the live voice turn.
    private func semanticAccessibilityTarget(
        snapshot: SnapshotContext,
        inspection: AccessibilityInspection?,
        targetDescription: String,
        preferredPoint: CGPoint
    ) -> AXUIElement? {
        guard !Self.semanticDistinctiveTokens(targetDescription).isEmpty,
              let window = accessibilityWindow(
                snapshot: snapshot,
                inspectedWindow: inspection?.windowElement
              ) else { return nil }

        let startedAt = Date()
        let maximumNodes = 3_000
        let maximumSearchDuration: TimeInterval = 0.65
        var queue = [window]
        var cursor = 0
        var seen = Set<CFHashCode>()
        var candidates: [SemanticAccessibilityCandidate] = []

        while cursor < queue.count,
              cursor < maximumNodes,
              Date().timeIntervalSince(startedAt) <= maximumSearchDuration {
            let element = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }

            let role = Self.axString(
                element,
                attribute: kAXRoleAttribute as CFString
            ) ?? ""
            let subrole = Self.axString(
                element,
                attribute: kAXSubroleAttribute as CFString
            ) ?? ""
            let labels = Self.accessibilityLabels(element)
            let actionNames = Self.axActionNames(element)

            if let score = Self.semanticPressMatchScore(
                targetDescription: targetDescription,
                candidateLabels: labels,
                role: role,
                actionNames: actionNames
            ),
               Self.axBoolean(element, attribute: kAXEnabledAttribute as CFString) != false,
               Self.axBoolean(element, attribute: kAXHiddenAttribute as CFString) != true,
               let frame = Self.axBounds(element),
               frame.width >= 1,
               frame.height >= 1,
               frame.intersects(snapshot.bounds),
               !labels.contains(where: Self.containsCAPTCHAChallenge),
               !Self.isSensitiveAccessibility(
                    role: role,
                    subrole: subrole,
                    labels: labels
               ),
               !Self.isConsequentialAccessibility(role: role, labels: labels) {
                let candidateScopes = Self.accessibilityActionScopes(
                    role: role,
                    subrole: subrole,
                    labels: labels
                )
                if Self.actionScopeMatches(
                    .ordinary,
                    targetScopes: candidateScopes,
                    windowScopes: snapshot.windowActionScopes
                ) {
                    candidates.append(SemanticAccessibilityCandidate(
                        element: element,
                        score: score,
                        distance: Self.distance(from: preferredPoint, to: frame)
                    ))
                }
            }

            let visibleChildren = Self.axElements(
                element,
                attribute: kAXVisibleChildrenAttribute as CFString
            )
            queue.append(contentsOf: visibleChildren.isEmpty
                ? Self.axElements(element, attribute: kAXChildrenAttribute as CFString)
                : visibleChildren)
        }

        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.distance < $1.distance
        }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1,
           candidates[1].score == best.score,
           abs(candidates[1].distance - best.distance) < 18 {
            // Two equivalently strong, equivalently close controls are an
            // actual ambiguity; leave the click to the already bounded pointer
            // path instead of guessing which semantic element the owner meant.
            return nil
        }
        return best.element
    }

    private func accessibilityWindow(
        snapshot: SnapshotContext,
        inspectedWindow: AXUIElement?
    ) -> AXUIElement? {
        if let inspectedWindow,
           let frame = Self.axBounds(inspectedWindow),
           Self.boundsMatch(frame, snapshot.bounds, tolerance: 8) {
            return inspectedWindow
        }

        let application = AXUIElementCreateApplication(snapshot.processID)
        let windows = Self.axElements(
            application,
            attribute: kAXWindowsAttribute as CFString
        )
        if let exactFrame = windows.first(where: {
            guard let frame = Self.axBounds($0) else { return false }
            return Self.boundsMatch(frame, snapshot.bounds, tolerance: 8)
        }) {
            return exactFrame
        }

        let normalizedTitle = Self.normalizedText(snapshot.windowTitle)
        guard !normalizedTitle.isEmpty else { return nil }
        let titleMatches = windows.filter {
            Self.normalizedText(
                Self.axString($0, attribute: kAXTitleAttribute as CFString) ?? ""
            ) == normalizedTitle
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private func makeClickResult(
        snapshot: SnapshotContext,
        target: String,
        normalizedX: Int,
        normalizedY: Int,
        point: CGPoint,
        method: NativeScreenClickMethod,
        effectObserved: Bool
    ) -> NativeScreenClickResult {
        NativeScreenClickResult(
            snapshotID: snapshot.snapshotID,
            method: method,
            targetDescription: target,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            screenX: point.x,
            screenY: point.y,
            windowID: snapshot.windowID,
            processID: snapshot.processID,
            applicationName: snapshot.applicationName,
            effectObserved: effectObserved
        )
    }

    /// Polls only the bounded, non-content window metadata macOS already
    /// exposes. This avoids a second screenshot/model turn and keeps the click
    /// receipt honest: an input event is not treated as proof of an effect.
    private func observeWindowEffect(
        processID: pid_t,
        baseline: [(windowID: CGWindowID, title: String)]
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            let observations = Self.onscreenWindowIdentities(
                processID: processID
            )
            if Self.observableWindowEffect(
                previousWindows: baseline,
                currentWindows: observations
            ) {
                return true
            }
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 90_000_000)
        } while true
    }

    // MARK: - Internal pure helpers

    nonisolated static func isNormalizedCoordinate(_ value: Int) -> Bool {
        (0 ... 1_000).contains(value)
    }

    nonisolated static func isValidTargetDescription(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 200,
              trimmed.utf8.count <= 512 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// Ordinary navigation is already bounded by the owner's current request, the
    /// one-use screenshot, exact window identity, a fresh coordinate, and the
    /// native action-scope classifier. Chrome often exposes a generic AXWebArea
    /// at a visually correct video coordinate instead of the visible title, so
    /// requiring the model's words to equal the hit element made normal web
    /// clicks impossible. Consequential controls keep the stricter semantic
    /// Accessibility-label match.
    nonisolated static func requiresAccessibilityLabelMatch(
        for scope: NativeScreenActionScope
    ) -> Bool {
        scope != .ordinary
    }

    /// Removes request scaffolding while preserving the identifying words in a
    /// title or control label. An empty result means the request is generic and
    /// must never choose an Accessibility element semantically.
    nonisolated static func semanticDistinctiveTokens(_ value: String) -> Set<String> {
        let ignored: Set<String> = [
            "a", "an", "and", "any", "button", "choose", "click", "first",
            "for", "from", "image", "item", "link", "me", "of", "on", "one",
            "open", "pick", "play", "press", "random", "screen", "select",
            "some", "that", "the", "this", "thumbnail", "thumbnails", "to",
            "video", "videos", "visible", "you", "youtube",
        ]
        return Set(normalizedText(value).split(separator: " ").compactMap { raw in
            let token = String(raw)
            guard !ignored.contains(token),
                  token.count >= 2,
                  token.unicodeScalars.contains(where: CharacterSet.letters.contains)
            else { return nil }
            return token
        })
    }

    /// Pure, conservative semantic matcher used by the live bounded AX search
    /// and native verification. It accepts only pressable links/buttons and
    /// requires substantial overlap with one candidate label.
    nonisolated static func semanticPressMatchScore(
        targetDescription: String,
        candidateLabels: [String],
        role: String,
        actionNames: [String]
    ) -> Int? {
        let compactRole = compactIdentifier(role)
        guard compactRole == "axlink" || compactRole == "axbutton",
              actionNames.contains(kAXPressAction as String),
              !containsCAPTCHAChallenge(targetDescription),
              !containsSensitiveText(targetDescription) else { return nil }

        let targetTokens = semanticDistinctiveTokens(targetDescription)
        guard !targetTokens.isEmpty else { return nil }
        if targetTokens.count == 1,
           (targetTokens.first?.count ?? 0) < 8 {
            return nil
        }

        var bestScore: Int?
        for label in candidateLabels {
            guard !containsCAPTCHAChallenge(label),
                  !containsSensitiveText(label) else { continue }
            let candidateTokens = semanticDistinctiveTokens(label)
            let overlap = targetTokens.intersection(candidateTokens).count
            let requiredOverlap: Int
            if targetTokens.count == 1 {
                requiredOverlap = 1
            } else if targetTokens.count == 2 {
                requiredOverlap = 2
            } else {
                requiredOverlap = max(2, Int(ceil(Double(targetTokens.count) * 0.65)))
            }
            guard overlap >= requiredOverlap else { continue }

            let missing = targetTokens.count - overlap
            let normalizedTarget = normalizedText(targetDescription)
            let normalizedLabel = normalizedText(label)
            let phraseBonus = normalizedLabel.contains(normalizedTarget)
                || normalizedTarget.contains(normalizedLabel) ? 40 : 0
            let score = overlap * 100 - missing * 30 + phraseBonus
            if score > (bestScore ?? Int.min) { bestScore = score }
        }
        return bestScore
    }

    /// Reject a visually requested video/thumbnail when the actual AX hit is
    /// clearly one of YouTube's navigation controls. This is intentionally
    /// narrow: words such as "history" inside a real video title do not match;
    /// the label must canonicalize to a navigation item.
    nonisolated static func ordinaryVideoTargetConflictsWithNavigationLabels(
        targetDescription: String,
        labels: [String]
    ) -> Bool {
        let targetWords = Set(normalizedText(targetDescription).split(separator: " ").map(String.init))
        guard !targetWords.isDisjoint(with: [
            "video", "videos", "thumbnail", "thumbnails",
        ]) else { return false }

        let navigationLabels: Set<String> = [
            "home", "shorts", "subscriptions", "custom feed", "history",
            "library", "explore", "search",
        ]
        let removableAffixes: Set<String> = [
            "button", "link", "menu", "menuitem", "navigation", "tab",
            "toolbar", "youtube",
        ]
        return labels.contains { label in
            var words = normalizedText(label).split(separator: " ").map(String.init)
            while let first = words.first, removableAffixes.contains(first) {
                words.removeFirst()
            }
            while let last = words.last, removableAffixes.contains(last) {
                words.removeLast()
            }
            return navigationLabels.contains(words.joined(separator: " "))
        }
    }

    /// Pure comparison used by the short post-click poll and native tests.
    /// Both inputs must be in front-to-back order for the same process.
    nonisolated static func observableWindowEffect(
        previousWindows: [(windowID: CGWindowID, title: String)],
        currentWindows: [(windowID: CGWindowID, title: String)]
    ) -> Bool {
        guard previousWindows.count == currentWindows.count else { return true }
        for (index, previous) in previousWindows.enumerated() {
            let current = currentWindows[index]
            if previous.windowID != current.windowID
                || normalizedText(previous.title) != normalizedText(current.title) {
                return true
            }
        }
        return false
    }

    nonisolated static func containsCAPTCHAChallenge(_ text: String) -> Bool {
        let value = normalizedText(text)
        let padded = " \(value) "
        return [
            " captcha ", " hcaptcha ", " recaptcha ",
            " i am not a robot ", " im not a robot ",
            " prove you are human ", " verify you are human ",
            " verify you re human ", " human verification challenge ",
        ].contains(where: padded.contains)
    }

    /// Every native click site goes through this final cancellation gate. It
    /// is intentionally exposed internally so verification can prove that a
    /// superseded voice turn cannot cross the actuation boundary.
    nonisolated static func performActuationIfNotCancelled<T>(
        _ action: () throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        return try action()
    }

    nonisolated static func normalizedPoint(x: Int, y: Int, in bounds: CGRect) -> CGPoint? {
        guard isNormalizedCoordinate(x),
              isNormalizedCoordinate(y),
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width >= 1,
              bounds.height >= 1 else { return nil }

        let rawX = bounds.minX + (Double(x) / 1_000) * bounds.width
        let rawY = bounds.minY + (Double(y) / 1_000) * bounds.height
        let insetX = min(0.5, bounds.width / 2)
        let insetY = min(0.5, bounds.height / 2)
        return CGPoint(
            x: min(max(rawX, bounds.minX + insetX), bounds.maxX - insetX),
            y: min(max(rawY, bounds.minY + insetY), bounds.maxY - insetY)
        )
    }

    nonisolated static func isSnapshotFresh(
        capturedAt: Date,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        let boundedMaximumAge = min(max(maximumAge, 0), 12)
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= boundedMaximumAge
    }

    nonisolated static func boundsMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard tolerance >= 0 else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    nonisolated static func windowRecordCanOccludeClick(
        layer: Int,
        alpha: Double,
        bounds: CGRect,
        point: CGPoint
    ) -> Bool {
        layer == 0
            && alpha > 0
            && bounds.width >= 1
            && bounds.height >= 1
            && bounds.contains(point)
    }

    nonisolated static func shouldPreferDominantWindow(
        frontmost: CGRect,
        candidate: CGRect
    ) -> Bool {
        let frontmostArea = max(frontmost.width, 0) * max(frontmost.height, 0)
        let candidateArea = max(candidate.width, 0) * max(candidate.height, 0)
        guard frontmostArea > 0,
              candidate.width >= 600,
              candidate.height >= 400 else { return false }
        return candidateArea >= frontmostArea * 1.5
            && ((frontmost.width <= 800 && frontmost.height <= 600)
                || frontmostArea <= candidateArea * 0.55)
    }

    nonisolated static func isAuroraApplication(
        name: String,
        bundleIdentifier: String,
        processID: pid_t
    ) -> Bool {
        if processID == ProcessInfo.processInfo.processIdentifier { return true }
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        return normalizedName == "aurora"
            || bundle == "ai.aurora.voice"
            || bundle.hasPrefix("ai.aurora.voice.")
    }

    nonisolated static func isSystemUI(name: String, bundleIdentifier: String) -> Bool {
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        let blockedNames: Set<String> = [
            "control center", "dock", "loginwindow", "notification center",
            "screencaptureui", "systemuiserver", "windowserver",
        ]
        if blockedNames.contains(normalizedName) { return true }
        return [
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.loginwindow",
            "com.apple.notificationcenterui",
            "com.apple.screencaptureui",
            "com.apple.systemuiserver",
            "com.apple.windowserver",
        ].contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    /// Returns the action categories visibly represented by one target. This
    /// classification can only narrow a pre-existing owner authorization.
    nonisolated static func actionScopes(in text: String) -> Set<NativeScreenActionScope> {
        let normalized = normalizedText(text)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "&", with: " and ")
        guard !normalized.isEmpty else { return [] }
        let compact = compactIdentifier(text)
        func opensWith(_ phrases: [String]) -> Bool {
            phrases.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
        }

        var scopes = Set<NativeScreenActionScope>()
        if opensWith([
            "send", "send email", "send message", "send now",
        ]) || ["sendbutton", "sendmessage"].contains(where: compact.contains) {
            scopes.insert(.send)
        }
        if opensWith([
            "delete", "discard", "erase", "move to trash", "remove", "trash",
        ]) || [
            "deletebutton", "discardbutton", "erasebutton", "movetotrash",
            "removebutton", "trashbutton",
        ].contains(where: compact.contains) {
            scopes.insert(.delete)
        }
        if opensWith([
            "buy", "buy now", "checkout", "confirm order", "confirm purchase",
            "make payment", "pay", "payment", "place order", "purchase",
            "submit order", "subscribe", "transfer",
        ]) || opensWith([
            "bank account", "card number", "credit card", "cvc", "cvv",
            "routing number",
        ]) || [
            "buybutton", "checkoutbutton", "paybutton", "placeorder",
            "purchasebutton", "transferbutton",
        ].contains(where: compact.contains) {
            scopes.insert(.purchase)
        }
        if opensWith([
            "post", "publish", "sign document", "submit", "upload",
        ]) || [
            "postbutton", "publishbutton", "submitbutton", "uploadbutton",
        ].contains(where: compact.contains) {
            scopes.insert(.submit)
        }
        if opensWith([
            "approve", "authenticate", "authentication", "authorize",
            "continue with", "log in", "login", "sign in",
        ]) || opensWith([
            "enter verification code", "one time code", "one time password",
            "two factor", "verification code",
        ]) || [
            "approvebutton", "authorizebutton", "loginbutton", "signinbutton",
        ].contains(where: compact.contains) {
            scopes.insert(.authenticate)
        }
        if opensWith([
            "access token", "api key", "backup code", "copy password",
            "credential", "enter password", "passcode", "password", "private key",
            "recovery code", "recovery phrase", "secret key", "security code",
            "security pin", "seed phrase", "show password", "two factor code",
            "verification code",
        ]) || [
            "passwordfield", "securetextfield", "showpassword",
        ].contains(where: compact.contains) {
            scopes.insert(.password)
        }
        if opensWith([
            "allow", "approve", "grant access", "permission",
        ]) || opensWith([
            "accessibility", "camera access", "full disk access",
            "microphone access", "notification access", "privacy and security",
            "screen recording",
        ]) || [
            "allowbutton", "permissionbutton", "privacyandsecurity",
        ].contains(where: compact.contains) {
            scopes.insert(.permission)
        }
        if opensWith([
            "account settings", "delete account", "log out", "logout",
            "manage account", "profile settings", "remove account",
            "saved passwords", "security settings", "sign out",
        ]) || [
            "accountsettings", "deleteaccount", "manageaccount", "removeaccount",
        ].contains(where: compact.contains) {
            scopes.insert(.accountControl)
        }
        return scopes
    }

    /// The target itself wins over its surrounding window. Window scope is a
    /// fallback only for generic controls such as a checkout dialog's Confirm
    /// button, preventing an authorized checkout window from laundering an
    /// unrelated Delete target.
    nonisolated static func actionScopeMatches(
        _ authorized: NativeScreenActionScope,
        targetScopes: Set<NativeScreenActionScope>,
        windowScopes: Set<NativeScreenActionScope>
    ) -> Bool {
        if !targetScopes.isEmpty {
            return authorized != .ordinary && targetScopes.contains(authorized)
        }
        if !windowScopes.isEmpty {
            return authorized != .ordinary && windowScopes.contains(authorized)
        }
        return authorized == .ordinary
    }

    nonisolated static func accessibilityActionScopes(
        role: String,
        subrole: String,
        labels: [String]
    ) -> Set<NativeScreenActionScope> {
        var scopes = labels.reduce(into: Set<NativeScreenActionScope>()) {
            $0.formUnion(actionScopes(in: $1))
        }
        let compactRole = compactIdentifier(role)
        let compactSubrole = compactIdentifier(subrole)
        if compactRole.contains("securetextfield")
            || compactSubrole.contains("securetextfield") {
            scopes.insert(.password)
            scopes.insert(.authenticate)
        }
        return scopes
    }

    nonisolated static func applicationActionScopes(
        name: String,
        bundleIdentifier: String
    ) -> Set<NativeScreenActionScope> {
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        if permitsOrdinaryApplicationNavigation(
            name: name,
            bundleIdentifier: bundleIdentifier
        ) {
            return []
        }
        if normalizedName == "securityagent"
            || bundle == "com.apple.securityagent" {
            return [.authenticate, .password, .permission]
        }
        if isBlockedApplication(name: name, bundleIdentifier: bundleIdentifier) {
            return [.accountControl, .authenticate, .permission]
        }
        return []
    }

    nonisolated static func permitsOrdinaryApplicationNavigation(
        name: String,
        bundleIdentifier: String
    ) -> Bool {
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        if normalizedName == "system preferences"
            || normalizedName == "system settings"
            || bundle == "com.apple.systempreferences" {
            return true
        }
        let passwordNames = [
            "1password", "bitwarden", "dashlane", "enpass", "keeper",
            "keychain access", "keepassxc", "lastpass", "nordpass", "passwords",
            "proton pass", "secrets", "strongbox",
        ]
        let passwordBundles = [
            "com.1password.", "com.agilebits.", "com.apple.keychainaccess",
            "com.apple.passwords", "com.bitwarden.", "com.dashlane.",
            "com.lastpass.", "com.nordpass.", "com.proton.pass",
        ]
        return passwordNames.contains(where: normalizedName.contains)
            || passwordBundles.contains(where: bundle.hasPrefix)
    }

    nonisolated static func systemUIActionScopes(
        name: String,
        bundleIdentifier: String
    ) -> Set<NativeScreenActionScope> {
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        if normalizedName == "loginwindow" || bundle == "com.apple.loginwindow" {
            return [.authenticate, .password]
        }
        if normalizedName == "control center"
            || normalizedName == "systemuiserver"
            || bundle == "com.apple.controlcenter"
            || bundle == "com.apple.systemuiserver" {
            return [.permission, .accountControl]
        }
        if normalizedName == "screencaptureui"
            || bundle == "com.apple.screencaptureui" {
            return [.permission]
        }
        return []
    }

    nonisolated static func windowActionScopes(_ title: String) -> Set<NativeScreenActionScope> {
        let value = normalizedText(title)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "&", with: " and ")
        guard !value.isEmpty else { return [] }
        var scopes = Set<NativeScreenActionScope>()
        let authenticationOpenings = [
            "authentication", "authorize", "log in", "login", "sign in",
            "two factor authentication", "verify your identity",
        ]
        if authenticationOpenings.contains(where: value.hasPrefix) {
            scopes.insert(.authenticate)
        }
        let passwordOpenings = [
            "keychain access", "password", "passwords", "saved passwords",
        ]
        if passwordOpenings.contains(where: value.hasPrefix) {
            scopes.insert(.password)
        }
        let permissionOpenings = [
            "accessibility", "camera access", "full disk access",
            "microphone access", "permission", "privacy and security",
            "screen recording",
        ]
        if permissionOpenings.contains(where: value.hasPrefix) {
            scopes.insert(.permission)
        }
        let purchaseOpenings = [
            "checkout", "confirm order", "confirm purchase", "order review",
            "payment", "place order", "purchase",
        ]
        if purchaseOpenings.contains(where: value.hasPrefix) {
            scopes.insert(.purchase)
        }
        let accountOpenings = [
            "account settings", "delete account", "manage account",
            "profile settings", "remove account", "security settings",
        ]
        if accountOpenings.contains(where: value.hasPrefix) {
            scopes.insert(.accountControl)
        }
        return scopes
    }

    nonisolated static func isBlockedApplication(
        name: String,
        bundleIdentifier: String
    ) -> Bool {
        let normalizedName = normalizedText(name)
        let bundle = bundleIdentifier.lowercased()
        if permitsOrdinaryApplicationNavigation(
            name: name,
            bundleIdentifier: bundleIdentifier
        ) {
            return false
        }
        let exactNames: Set<String> = [
            "1password", "avast security", "avg antivirus", "bitwarden",
            "crowdstrike falcon", "dashlane", "enpass", "keeper",
            "keychain access", "keepassxc", "lastpass", "little snitch",
            "malwarebytes", "mcafee", "nordpass", "norton 360", "passwords",
            "proton pass", "secrets", "securityagent", "sentinelone",
            "sophos endpoint", "strongbox", "system preferences", "system settings",
        ]
        if exactNames.contains(normalizedName) { return true }

        let namePhrases = [
            "antivirus", "endpoint security", "internet security",
            "password manager", "password safe", "security agent",
            "security suite", "security",
        ]
        if namePhrases.contains(where: normalizedName.contains) { return true }

        let exactBundles: Set<String> = [
            "2buaw8t4d2.com.agilebits.onepassword-osx-helper",
            "com.1password.1password",
            "com.apple.keychainaccess",
            "com.apple.passwords",
            "com.apple.securityagent",
            "com.apple.systempreferences",
            "com.bitwarden.desktop",
            "com.dashlane.dashlanephonefinal",
            "com.lastpass.lastpass",
            "com.malwarebytes.mbam.frontend.agent",
            "com.proton.pass",
        ]
        if exactBundles.contains(bundle) { return true }
        return [
            "at.obdev.littlesnitch", "com.1password.", "com.agilebits.",
            "com.avast.", "com.avg.", "com.bitwarden.", "com.crowdstrike.",
            "com.dashlane.", "com.lastpass.", "com.malwarebytes.",
            "com.mcafee.", "com.nordpass.", "com.sentinelone.",
            "com.sophos.", "com.symantec.",
        ].contains(where: bundle.hasPrefix)
    }

    nonisolated static func isSensitiveWindowTitle(_ title: String) -> Bool {
        let value = normalizedText(title)
        guard !value.isEmpty else { return false }
        let exactTitles: Set<String> = [
            "authentication", "keychain access", "login", "passwords",
            "privacy & security", "saved passwords", "security settings",
            "sign in", "two-factor authentication",
        ]
        if exactTitles.contains(value) { return true }
        let protectedOpenings = [
            "authentication ", "keychain access ", "log in ", "login ",
            "passwords ", "saved passwords ", "security settings ",
            "sign in ", "two-factor authentication ",
        ]
        if protectedOpenings.contains(where: value.hasPrefix) { return true }
        let protectedProducts = [
            "1password", "bitwarden", "dashlane", "lastpass", "nordpass",
            "proton pass", "web vault",
        ]
        return protectedProducts.contains(where: value.contains)
    }

    nonisolated static func isSensitiveAccessibility(
        role: String,
        subrole: String,
        labels: [String]
    ) -> Bool {
        let compactRole = compactIdentifier(role)
        let compactSubrole = compactIdentifier(subrole)
        if compactRole.contains("securetextfield")
            || compactSubrole.contains("securetextfield") {
            return true
        }
        return labels.contains(where: containsSensitiveText)
    }

    nonisolated static func isConsequentialAccessibility(
        role: String,
        labels: [String]
    ) -> Bool {
        let compactRole = compactIdentifier(role)
        let actionableRole = [
            "button", "checkbox", "link", "menuitem", "radiobutton",
            "switch", "tab", "toolbarbutton",
        ].contains { compactRole.contains($0) }
        return actionableRole && labels.contains(where: containsConsequentialActionText)
    }

    nonisolated static func containsSensitiveText(_ text: String) -> Bool {
        let value = normalizedText(text)
        guard !value.isEmpty else { return false }
        let phrases = [
            "api key", "access token", "backup code", "bank account",
            "card number", "copy password", "credit card", "cvc", "cvv",
            "one time code", "one-time code", "passcode", "password",
            "private key", "recovery code", "recovery phrase", "routing number",
            "secret key", "security code", "security pin", "seed phrase",
            "show password", "social security", "ssn", "two factor code",
            "two-factor code", "verification code",
        ]
        return phrases.contains(where: value.contains)
    }

    nonisolated static func containsConsequentialActionText(_ text: String) -> Bool {
        let value = normalizedText(text)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "&", with: " and ")
        guard !value.isEmpty else { return false }
        let padded = " \(value) "
        let phrases = [
            "allow", "approve", "authorize", "buy", "buy now", "checkout",
            "confirm order", "confirm purchase", "delete", "delete account",
            "discard", "erase", "make payment", "move to trash", "pay", "place order", "post",
            "publish", "purchase", "remove account", "send", "send message",
            "sign", "submit", "subscribe", "transfer", "trash", "upload",
        ]
        if phrases.contains(where: { padded.contains(" \($0) ") }) { return true }
        let compact = compactIdentifier(text)
        let consequentialIdentifiers = [
            "allowbutton", "approvebutton", "authorizebutton", "buybutton",
            "deletebutton", "erasebutton", "movetotrash", "paybutton",
            "placeorder", "publishbutton", "purchasebutton", "sendbutton",
            "submitbutton", "transferbutton", "trashbutton", "uploadbutton",
        ]
        return consequentialIdentifiers.contains(where: compact.contains)
    }

    nonisolated static func targetDescription(
        _ target: String,
        matchesAny labels: [String]
    ) -> Bool {
        let ignored: Set<String> = [
            "a", "an", "button", "click", "first", "fourth", "image", "item",
            "link", "on", "result", "second", "select", "the", "third",
            "thumbnail", "target", "that", "this", "video", "visible",
        ]
        let targetTokens = Set(normalizedText(target).split(separator: " ").map(String.init))
            .subtracting(ignored)
            .filter { $0.count >= 2 }
        guard !targetTokens.isEmpty else { return false }
        let labelTokens = Set(labels.flatMap {
            normalizedText($0).split(separator: " ").map(String.init)
        })
        let overlapCount = targetTokens.intersection(labelTokens).count
        return targetTokens.count == 1 ? overlapCount == 1 : overlapCount >= 2
    }

    nonisolated static func normalizedText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "&- ")).inverted)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    nonisolated static func compactIdentifier(_ value: String) -> String {
        String(normalizedText(value).filter { $0.isLetter || $0.isNumber })
    }

    nonisolated static func boundedText(_ value: String, maximumCharacters: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max(maximumCharacters, 0)))
    }

    // MARK: - Native helpers

    private nonisolated static func onscreenWindowRecords() -> [OnscreenWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return OnscreenWindowRecord(
                windowID: windowNumber,
                processID: processID,
                bounds: bounds,
                layer: layer,
                alpha: alpha
            )
        }
    }

    private nonisolated static func onscreenWindowIdentities(
        processID: pid_t
    ) -> [(windowID: CGWindowID, title: String)] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 120,
                  bounds.height >= 80,
                  let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                return nil
            }
            let title = entry[kCGWindowName as String] as? String ?? ""
            return (windowID: windowID, title: title)
        }
    }

    private nonisolated static func axString(
        _ element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private nonisolated static func axElements(
        _ element: AXUIElement,
        attribute: CFString
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func accessibilityLabels(
        _ element: AXUIElement
    ) -> [String] {
        var labels = [
            axString(element, attribute: kAXTitleAttribute as CFString),
            axString(element, attribute: kAXDescriptionAttribute as CFString),
            axString(element, attribute: kAXHelpAttribute as CFString),
            axString(element, attribute: kAXRoleDescriptionAttribute as CFString),
            axString(element, attribute: kAXIdentifierAttribute as CFString),
            axString(element, attribute: kAXPlaceholderValueAttribute as CFString),
            axString(element, attribute: kAXValueAttribute as CFString),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let titleElement = axElement(
            element,
            attribute: kAXTitleUIElementAttribute as CFString
        ) {
            labels.append(contentsOf: [
                axString(titleElement, attribute: kAXTitleAttribute as CFString),
                axString(titleElement, attribute: kAXDescriptionAttribute as CFString),
                axString(titleElement, attribute: kAXPlaceholderValueAttribute as CFString),
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        return Array(Set(labels))
    }

    private nonisolated static func axBounds(_ element: AXUIElement) -> CGRect? {
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

    private nonisolated static func distance(
        from point: CGPoint,
        to rect: CGRect
    ) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private nonisolated static func axBoolean(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private nonisolated static func axElement(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func axActionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let actions else { return [] }
        return actions as? [String] ?? []
    }

    private nonisolated static func jpegData(
        from image: CGImage,
        compression: Double
    ) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: min(max(compression, 0.05), 1)]
        )
    }

    private nonisolated static func resizedImage(
        _ image: CGImage,
        maximumDimension: Int
    ) -> CGImage? {
        let maximumDimension = max(maximumDimension, 1)
        let largest = max(image.width, image.height)
        guard largest > maximumDimension else { return image }
        let scale = Double(maximumDimension) / Double(largest)
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private nonisolated static func boundedJPEG(
        from source: CGImage,
        maximumBytes: Int,
        maximumDimension: Int
    ) throws -> (data: Data, image: CGImage) {
        let byteLimit = min(max(maximumBytes, 1), 65 * 1_024)
        guard var image = resizedImage(source, maximumDimension: maximumDimension) else {
            throw NativeScreenControlError.imageEncodingFailed
        }

        let qualities: [Double] = [0.74, 0.64, 0.54, 0.44, 0.34, 0.26, 0.18, 0.12]
        for _ in 0 ..< 8 {
            for quality in qualities {
                if let data = jpegData(from: image, compression: quality),
                   data.count <= byteLimit {
                    return (data, image)
                }
            }

            guard let smallest = jpegData(from: image, compression: qualities.last ?? 0.12),
                  max(image.width, image.height) > 96 else { break }
            let estimatedScale = sqrt(Double(byteLimit) / Double(max(smallest.count, 1))) * 0.88
            let nextScale = min(max(estimatedScale, 0.45), 0.82)
            let nextDimension = max(Int(Double(max(image.width, image.height)) * nextScale), 96)
            guard let smaller = resizedImage(image, maximumDimension: nextDimension),
                  smaller.width < image.width || smaller.height < image.height else { break }
            image = smaller
        }
        throw NativeScreenControlError.imageEncodingFailed
    }
}
