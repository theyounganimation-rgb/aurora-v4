import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The action names emitted by OpenAI's GA `computer` tool.
public enum MacDesktopActionType: String, Codable, Sendable, Equatable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case drag
    case move
    case scroll
    case keypress
    case type
    case wait
    case screenshot
}

public enum MacDesktopMouseButton: String, Codable, Sendable, Equatable, CaseIterable {
    case left
    case middle
    case right
}

/// Coordinates are relative to the top-left of the most recent stitched
/// desktop screenshot. They intentionally do not expose macOS global offsets
/// to the model.
public struct MacDesktopPoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A direct representation of one action from a `computer_call.actions[]`
/// array. Fields that do not belong to `type` are rejected before execution.
public struct MacDesktopAction: Codable, Sendable, Equatable {
    public let type: MacDesktopActionType
    public let x: Double?
    public let y: Double?
    public let button: MacDesktopMouseButton?
    public let keys: [String]?
    public let path: [MacDesktopPoint]?
    public let scrollX: Double?
    public let scrollY: Double?
    public let text: String?

    public init(
        type: MacDesktopActionType,
        x: Double? = nil,
        y: Double? = nil,
        button: MacDesktopMouseButton? = nil,
        keys: [String]? = nil,
        path: [MacDesktopPoint]? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        text: String? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.button = button
        self.keys = keys
        self.path = path
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case type, x, y, button, keys, path, text
        case scrollX = "scroll_x"
        case scrollY = "scroll_y"
    }
}

public struct MacDesktopDisplayFrame: Codable, Sendable, Equatable {
    public let displayID: UInt32
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// Describes the exact coordinate system encoded into a screenshot. Pointer
/// actions are refused if the active display topology changes afterward.
public struct MacDesktopCoordinateSpace: Codable, Sendable, Equatable {
    public let id: String
    public let originX: Double
    public let originY: Double
    public let width: Int
    public let height: Int
    public let displays: [MacDesktopDisplayFrame]
}

/// PNG bytes exist only in this value and its data URL. This implementation
/// never writes them to a file, pasteboard, journal, or task history.
public struct MacDesktopScreenshot: Sendable, Equatable {
    public let taskID: String
    public let dataURL: String
    public let pngByteCount: Int
    public let capturedAt: Date
    public let coordinateSpace: MacDesktopCoordinateSpace
}

public struct MacDesktopActionReceipt: Sendable, Equatable {
    public let taskID: String
    public let actionType: MacDesktopActionType
    public let completedAt: Date
    public let screenshot: MacDesktopScreenshot?
}

public struct MacDesktopPermissionStatus: Sendable, Equatable {
    public let screenRecordingAllowed: Bool
    public let accessibilityAllowed: Bool
    public let eventPostingAllowed: Bool

    public init(
        screenRecordingAllowed: Bool,
        accessibilityAllowed: Bool,
        eventPostingAllowed: Bool
    ) {
        self.screenRecordingAllowed = screenRecordingAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.eventPostingAllowed = eventPostingAllowed
    }
}

/// Injectable so validation and action sequencing can be verified without
/// posting real events from a test process.
public struct MacDesktopPermissionProvider: Sendable {
    private let implementation: @Sendable () -> MacDesktopPermissionStatus

    public init(
        implementation: @escaping @Sendable () -> MacDesktopPermissionStatus
    ) {
        self.implementation = implementation
    }

    public func status() -> MacDesktopPermissionStatus {
        implementation()
    }

    public static let system = MacDesktopPermissionProvider {
        MacDesktopPermissionStatus(
            screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
            accessibilityAllowed: AXIsProcessTrusted(),
            eventPostingAllowed: CGPreflightPostEventAccess()
        )
    }
}

public enum MacDesktopExecutableAction: Sendable, Equatable {
    case click(point: MacDesktopPoint, button: MacDesktopMouseButton, modifiers: [String])
    case doubleClick(point: MacDesktopPoint, button: MacDesktopMouseButton, modifiers: [String])
    case drag(path: [MacDesktopPoint], modifiers: [String])
    case move(point: MacDesktopPoint, modifiers: [String])
    case scroll(point: MacDesktopPoint, deltaX: Int32, deltaY: Int32, modifiers: [String])
    case keypress(keys: [String])
    case type(text: String)
    case wait(seconds: TimeInterval)
}

public protocol MacDesktopActionPerforming: Sendable {
    func perform(_ action: MacDesktopExecutableAction) async throws
}

public enum MacDesktopEnvironmentError: LocalizedError, Sendable, Equatable {
    case invalidTaskID
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case eventPostingPermissionDenied
    case noDisplays
    case screenshotCaptureFailed
    case screenshotEncodingFailed
    case screenshotTooLarge
    case screenshotRequired
    case displayConfigurationChanged
    case unexpectedActionField(String)
    case missingActionField(String)
    case invalidCoordinate
    case coordinateOutsideDisplay
    case invalidDragPath
    case invalidScrollDelta
    case invalidText
    case invalidKeys
    case unsupportedKey(String)
    case unsupportedAction(String)
    case invalidModifier(String)
    case eventConstructionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID: return "The desktop task identifier is invalid."
        case .screenRecordingPermissionDenied: return "Aurora needs existing Screen Recording permission to capture the desktop."
        case .accessibilityPermissionDenied: return "Aurora needs existing Accessibility permission to control the desktop."
        case .eventPostingPermissionDenied: return "Aurora needs existing input-event permission to control the desktop."
        case .noDisplays: return "No active Mac display is available."
        case .screenshotCaptureFailed: return "The full desktop could not be captured."
        case .screenshotEncodingFailed: return "The desktop image could not be encoded as PNG."
        case .screenshotTooLarge: return "The active desktop is too large to capture safely."
        case .screenshotRequired: return "A current desktop screenshot is required before that pointer action."
        case .displayConfigurationChanged: return "The display arrangement changed after the last screenshot."
        case .unexpectedActionField(let field): return "The computer action contains an unexpected \(field)."
        case .missingActionField(let field): return "The computer action needs \(field)."
        case .invalidCoordinate: return "The computer action contains a non-finite or invalid coordinate."
        case .coordinateOutsideDisplay: return "The computer action coordinate is outside every active display."
        case .invalidDragPath: return "A drag path needs between 2 and 128 valid display points."
        case .invalidScrollDelta: return "The scroll delta is not finite or is too large."
        case .invalidText: return "The typed text is empty or exceeds the in-memory action limit."
        case .invalidKeys: return "The keypress action is empty or exceeds the key limit."
        case .unsupportedKey(let key): return "The key \(key) is not supported by the Mac desktop environment."
        case .unsupportedAction(let type): return "The computer action \(type) is not supported by the Mac desktop environment."
        case .invalidModifier(let key): return "The mouse modifier \(key) is not supported."
        case .eventConstructionFailed: return "macOS could not construct the requested input event."
        }
    }
}

/// A task-bound native environment for OpenAI's computer-use loop. Construct
/// one instance per desktop task; the bound task identifier is copied into
/// every screenshot and receipt so results cannot be confused across tasks.
public actor MacDesktopEnvironment {
    public struct Configuration: Sendable, Equatable {
        public var maximumScreenshotPixels: Int
        public var maximumTypedUTF16Units: Int
        public var maximumTypedUTF8Bytes: Int
        public var maximumKeyCount: Int
        public var maximumKeyCharacters: Int
        public var maximumDragPoints: Int
        public var maximumAbsoluteScrollDelta: Double
        public var waitDuration: TimeInterval

        public init(
            maximumScreenshotPixels: Int = 32_000_000,
            maximumTypedUTF16Units: Int = 16_384,
            maximumTypedUTF8Bytes: Int = 64_000,
            maximumKeyCount: Int = 32,
            maximumKeyCharacters: Int = 48,
            maximumDragPoints: Int = 128,
            maximumAbsoluteScrollDelta: Double = 100_000,
            waitDuration: TimeInterval = 2
        ) {
            self.maximumScreenshotPixels = min(max(maximumScreenshotPixels, 1_000_000), 64_000_000)
            self.maximumTypedUTF16Units = min(max(maximumTypedUTF16Units, 1), 32_768)
            self.maximumTypedUTF8Bytes = min(max(maximumTypedUTF8Bytes, 1), 128_000)
            self.maximumKeyCount = min(max(maximumKeyCount, 1), 64)
            self.maximumKeyCharacters = min(max(maximumKeyCharacters, 1), 80)
            self.maximumDragPoints = min(max(maximumDragPoints, 2), 256)
            self.maximumAbsoluteScrollDelta = min(max(maximumAbsoluteScrollDelta, 1), 1_000_000)
            self.waitDuration = min(max(waitDuration, 0.05), 10)
        }
    }

    private struct DisplayRecord {
        let display: SCDisplay
        let bounds: CGRect
    }

    public nonisolated let taskID: String
    private let configuration: Configuration
    private let permissionProvider: MacDesktopPermissionProvider
    private let actionPerformer: any MacDesktopActionPerforming
    private var latestCoordinateSpace: MacDesktopCoordinateSpace?
    private var latestDisplayTopology: String?

    public init(
        taskID: String,
        configuration: Configuration = Configuration(),
        permissionProvider: MacDesktopPermissionProvider = .system,
        actionPerformer: any MacDesktopActionPerforming = SystemMacDesktopActionPerformer()
    ) throws {
        let trimmed = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw MacDesktopEnvironmentError.invalidTaskID
        }
        self.taskID = trimmed
        self.configuration = configuration
        self.permissionProvider = permissionProvider
        self.actionPerformer = actionPerformer
    }

    public nonisolated func permissionStatus() -> MacDesktopPermissionStatus {
        permissionProvider.status()
    }

    /// Captures every active display, stitches them into one logical-point PNG,
    /// and keeps all image bytes in memory. Gaps between displays are black.
    public func captureScreenshot() async throws -> MacDesktopScreenshot {
        try Task.checkCancellation()
        guard permissionProvider.status().screenRecordingAllowed else {
            throw MacDesktopEnvironmentError.screenRecordingPermissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw MacDesktopEnvironmentError.screenshotCaptureFailed
        }
        let activeDisplayIDs = Set(try Self.activeDisplayRecords().map(\.id))
        let records = content.displays.compactMap { display -> DisplayRecord? in
            guard activeDisplayIDs.contains(display.displayID) else { return nil }
            let bounds = CGDisplayBounds(display.displayID)
            guard Self.validDisplayBounds(bounds) else { return nil }
            return DisplayRecord(display: display, bounds: bounds)
        }.sorted { $0.display.displayID < $1.display.displayID }
        guard !records.isEmpty else { throw MacDesktopEnvironmentError.noDisplays }

        let virtualBounds = records.dropFirst().reduce(records[0].bounds) {
            $0.union($1.bounds)
        }
        let width = Int(ceil(virtualBounds.width))
        let height = Int(ceil(virtualBounds.height))
        guard width > 0,
              height > 0,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= configuration.maximumScreenshotPixels else {
            throw MacDesktopEnvironmentError.screenshotTooLarge
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MacDesktopEnvironmentError.screenshotCaptureFailed
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        for record in records {
            try Task.checkCancellation()
            let filter = SCContentFilter(
                display: record.display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let stream = SCStreamConfiguration()
            stream.width = max(Int(ceil(record.bounds.width)), 1)
            stream.height = max(Int(ceil(record.bounds.height)), 1)
            stream.scalesToFit = true
            stream.showsCursor = true
            stream.capturesAudio = false

            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: stream
                )
            } catch {
                throw MacDesktopEnvironmentError.screenshotCaptureFailed
            }
            let relativeX = record.bounds.minX - virtualBounds.minX
            let relativeTopY = record.bounds.minY - virtualBounds.minY
            let destination = CGRect(
                x: relativeX,
                y: Double(height) - relativeTopY - record.bounds.height,
                width: record.bounds.width,
                height: record.bounds.height
            )
            context.draw(image, in: destination)
        }
        guard let composite = context.makeImage() else {
            throw MacDesktopEnvironmentError.screenshotCaptureFailed
        }
        let representation = NSBitmapImageRep(cgImage: composite)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw MacDesktopEnvironmentError.screenshotEncodingFailed
        }

        let displayFrames = records.map { record in
            MacDesktopDisplayFrame(
                displayID: record.display.displayID,
                x: record.bounds.minX - virtualBounds.minX,
                y: record.bounds.minY - virtualBounds.minY,
                width: record.bounds.width,
                height: record.bounds.height
            )
        }
        let coordinateSpace = MacDesktopCoordinateSpace(
            id: UUID().uuidString.lowercased(),
            originX: virtualBounds.minX,
            originY: virtualBounds.minY,
            width: width,
            height: height,
            displays: displayFrames
        )
        latestCoordinateSpace = coordinateSpace
        latestDisplayTopology = Self.topology(
            records.map { (id: $0.display.displayID, bounds: $0.bounds) }
        )
        return MacDesktopScreenshot(
            taskID: taskID,
            dataURL: "data:image/png;base64,\(png.base64EncodedString())",
            pngByteCount: png.count,
            capturedAt: Date(),
            coordinateSpace: coordinateSpace
        )
    }

    public func execute(_ action: MacDesktopAction) async throws -> MacDesktopActionReceipt {
        try Task.checkCancellation()
        if action.type == .screenshot {
            try requireNoFields(action)
            let screenshot = try await captureScreenshot()
            return MacDesktopActionReceipt(
                taskID: taskID,
                actionType: .screenshot,
                completedAt: Date(),
                screenshot: screenshot
            )
        }

        let executable = try validatedExecutableAction(action)
        let permissions = permissionProvider.status()
        guard permissions.accessibilityAllowed else {
            throw MacDesktopEnvironmentError.accessibilityPermissionDenied
        }
        guard permissions.eventPostingAllowed else {
            throw MacDesktopEnvironmentError.eventPostingPermissionDenied
        }
        try Task.checkCancellation()
        try await actionPerformer.perform(executable)
        try Task.checkCancellation()
        return MacDesktopActionReceipt(
            taskID: taskID,
            actionType: action.type,
            completedAt: Date(),
            screenshot: nil
        )
    }

    /// Direct adapter for the provider-facing action type decoded by
    /// `ComputerUseClient`. Keeping it here leaves the coordinator responsible
    /// for task sequencing rather than action-shape translation.
    public func execute(_ action: DesktopTaskAction) async throws -> MacDesktopActionReceipt {
        let native: MacDesktopAction
        switch action {
        case .screenshot:
            native = MacDesktopAction(type: .screenshot)
        case .click(let x, let y, let button):
            native = MacDesktopAction(
                type: .click,
                x: Double(x),
                y: Double(y),
                button: try nativeButton(button)
            )
        case .doubleClick(let x, let y, let button):
            native = MacDesktopAction(
                type: .doubleClick,
                x: Double(x),
                y: Double(y),
                button: try nativeButton(button)
            )
        case .drag(let path):
            native = MacDesktopAction(
                type: .drag,
                path: path.map { MacDesktopPoint(x: Double($0.x), y: Double($0.y)) }
            )
        case .move(let x, let y):
            native = MacDesktopAction(type: .move, x: Double(x), y: Double(y))
        case .scroll(let x, let y, let deltaX, let deltaY):
            native = MacDesktopAction(
                type: .scroll,
                x: Double(x),
                y: Double(y),
                scrollX: Double(deltaX),
                scrollY: Double(deltaY)
            )
        case .keypress(let keys):
            native = MacDesktopAction(type: .keypress, keys: keys)
        case .type(let text):
            native = MacDesktopAction(type: .type, text: text)
        case .wait:
            native = MacDesktopAction(type: .wait)
        case .unsupported(let type):
            throw MacDesktopEnvironmentError.unsupportedAction(type)
        }
        return try await execute(native)
    }

    private func validatedExecutableAction(
        _ action: MacDesktopAction
    ) throws -> MacDesktopExecutableAction {
        switch action.type {
        case .click, .doubleClick:
            try rejectFields(action, allowing: ["x", "y", "button", "keys"])
            let point = try globalPoint(x: action.x, y: action.y)
            let button = action.button ?? .left
            let modifiers = try validatedMouseModifiers(action.keys ?? [])
            if action.type == .click {
                return .click(point: point, button: button, modifiers: modifiers)
            }
            return .doubleClick(point: point, button: button, modifiers: modifiers)

        case .drag:
            try rejectFields(action, allowing: ["path", "keys"])
            guard let path = action.path,
                  path.count >= 2,
                  path.count <= configuration.maximumDragPoints else {
                throw MacDesktopEnvironmentError.invalidDragPath
            }
            let globalPath = try path.map { point in
                do {
                    return try globalPoint(x: point.x, y: point.y)
                } catch {
                    throw MacDesktopEnvironmentError.invalidDragPath
                }
            }
            return .drag(
                path: globalPath,
                modifiers: try validatedMouseModifiers(action.keys ?? [])
            )

        case .move:
            try rejectFields(action, allowing: ["x", "y", "keys"])
            return .move(
                point: try globalPoint(x: action.x, y: action.y),
                modifiers: try validatedMouseModifiers(action.keys ?? [])
            )

        case .scroll:
            try rejectFields(action, allowing: ["x", "y", "scroll_x", "scroll_y", "keys"])
            let deltaX = try validatedScrollDelta(action.scrollX ?? 0)
            let deltaY = try validatedScrollDelta(action.scrollY ?? 0)
            return .scroll(
                point: try globalPoint(x: action.x, y: action.y),
                deltaX: deltaX,
                deltaY: deltaY,
                modifiers: try validatedMouseModifiers(action.keys ?? [])
            )

        case .keypress:
            try rejectFields(action, allowing: ["keys"])
            let keys = try validatedKeys(action.keys)
            for key in keys {
                try SystemMacDesktopActionPerformer.validateKeyExpression(key)
            }
            return .keypress(keys: keys)

        case .type:
            try rejectFields(action, allowing: ["text"])
            guard let text = action.text,
                  !text.isEmpty,
                  text.utf16.count <= configuration.maximumTypedUTF16Units,
                  text.utf8.count <= configuration.maximumTypedUTF8Bytes,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw MacDesktopEnvironmentError.invalidText
            }
            return .type(text: text)

        case .wait:
            try requireNoFields(action)
            return .wait(seconds: configuration.waitDuration)

        case .screenshot:
            fatalError("screenshot is handled before executable-action validation")
        }
    }

    private func nativeButton(_ button: DesktopMouseButton) throws -> MacDesktopMouseButton {
        switch button {
        case .left: return .left
        case .middle: return .middle
        case .right: return .right
        case .unsupported(let value):
            throw MacDesktopEnvironmentError.unsupportedAction("mouse button \(value)")
        }
    }

    private func globalPoint(x: Double?, y: Double?) throws -> MacDesktopPoint {
        guard let x else { throw MacDesktopEnvironmentError.missingActionField("x") }
        guard let y else { throw MacDesktopEnvironmentError.missingActionField("y") }
        guard x.isFinite, y.isFinite else { throw MacDesktopEnvironmentError.invalidCoordinate }
        guard let coordinateSpace = latestCoordinateSpace,
              let expectedTopology = latestDisplayTopology else {
            throw MacDesktopEnvironmentError.screenshotRequired
        }
        let current = try Self.activeDisplayRecords()
        guard Self.topology(current) == expectedTopology else {
            latestCoordinateSpace = nil
            latestDisplayTopology = nil
            throw MacDesktopEnvironmentError.displayConfigurationChanged
        }
        guard x >= 0,
              y >= 0,
              x < Double(coordinateSpace.width),
              y < Double(coordinateSpace.height) else {
            throw MacDesktopEnvironmentError.invalidCoordinate
        }
        guard coordinateSpace.displays.contains(where: { frame in
            x >= frame.x && y >= frame.y
                && x < frame.x + frame.width
                && y < frame.y + frame.height
        }) else {
            throw MacDesktopEnvironmentError.coordinateOutsideDisplay
        }
        return MacDesktopPoint(
            x: coordinateSpace.originX + x,
            y: coordinateSpace.originY + y
        )
    }

    private func validatedScrollDelta(_ value: Double) throws -> Int32 {
        guard value.isFinite,
              abs(value) <= configuration.maximumAbsoluteScrollDelta,
              value >= Double(Int32.min),
              value <= Double(Int32.max) else {
            throw MacDesktopEnvironmentError.invalidScrollDelta
        }
        return Int32(value.rounded())
    }

    private func validatedKeys(_ keys: [String]?) throws -> [String] {
        guard let keys,
              !keys.isEmpty,
              keys.count <= configuration.maximumKeyCount else {
            throw MacDesktopEnvironmentError.invalidKeys
        }
        let trimmed = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ key in
            !key.isEmpty
                && key.count <= configuration.maximumKeyCharacters
                && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }) else {
            throw MacDesktopEnvironmentError.invalidKeys
        }
        return trimmed
    }

    private func validatedMouseModifiers(_ keys: [String]) throws -> [String] {
        if keys.isEmpty { return [] }
        let validated = try validatedKeys(keys)
        return try validated.map { key in
            guard let normalized = SystemMacDesktopActionPerformer.normalizedModifier(key) else {
                throw MacDesktopEnvironmentError.invalidModifier(key)
            }
            return normalized
        }
    }

    private func requireNoFields(_ action: MacDesktopAction) throws {
        try rejectFields(action, allowing: [])
    }

    private func rejectFields(_ action: MacDesktopAction, allowing: Set<String>) throws {
        let populated: [(String, Bool)] = [
            ("x", action.x != nil),
            ("y", action.y != nil),
            ("button", action.button != nil),
            ("keys", action.keys != nil),
            ("path", action.path != nil),
            ("scroll_x", action.scrollX != nil),
            ("scroll_y", action.scrollY != nil),
            ("text", action.text != nil),
        ]
        if let unexpected = populated.first(where: { $0.1 && !allowing.contains($0.0) }) {
            throw MacDesktopEnvironmentError.unexpectedActionField(unexpected.0)
        }
    }

    private nonisolated static func validDisplayBounds(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width >= 1 && bounds.height >= 1
    }

    private nonisolated static func activeDisplayRecords() throws -> [(id: UInt32, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0 else {
            throw MacDesktopEnvironmentError.noDisplays
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actualCount: UInt32 = 0
        guard CGGetActiveDisplayList(count, &displayIDs, &actualCount) == .success else {
            throw MacDesktopEnvironmentError.noDisplays
        }
        return displayIDs.prefix(Int(actualCount)).compactMap { id in
            let bounds = CGDisplayBounds(id)
            return validDisplayBounds(bounds) ? (id: id, bounds: bounds) : nil
        }.sorted { $0.id < $1.id }
    }

    private nonisolated static func topology(
        _ records: [(id: UInt32, bounds: CGRect)]
    ) -> String {
        records.map { record in
            [
                String(record.id),
                String(format: "%.3f", record.bounds.minX),
                String(format: "%.3f", record.bounds.minY),
                String(format: "%.3f", record.bounds.width),
                String(format: "%.3f", record.bounds.height),
            ].joined(separator: ":")
        }.joined(separator: "|")
    }
}

/// Default CoreGraphics implementation. It never uses the pasteboard: typed
/// content is delivered as bounded Unicode keyboard events and then released.
public struct SystemMacDesktopActionPerformer: MacDesktopActionPerforming {
    public init() {}

    public func perform(_ action: MacDesktopExecutableAction) async throws {
        try Task.checkCancellation()
        switch action {
        case .click(let point, let button, let modifiers):
            try await withModifiers(modifiers) {
                try postClick(point: point, button: button, count: 1)
            }
        case .doubleClick(let point, let button, let modifiers):
            try await withModifiers(modifiers) {
                try postClick(point: point, button: button, count: 1)
                try await Task.sleep(for: .milliseconds(70))
                try postClick(point: point, button: button, count: 2)
            }
        case .drag(let path, let modifiers):
            try await withModifiers(modifiers) {
                try await postDrag(path: path)
            }
        case .move(let point, let modifiers):
            try await withModifiers(modifiers) {
                try postMouseMove(point)
            }
        case .scroll(let point, let deltaX, let deltaY, let modifiers):
            try await withModifiers(modifiers) {
                try postMouseMove(point)
                guard let event = CGEvent(
                    scrollWheelEvent2Source: eventSource(),
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: -deltaY,
                    wheel2: -deltaX,
                    wheel3: 0
                ) else {
                    throw MacDesktopEnvironmentError.eventConstructionFailed
                }
                event.flags = Self.modifierFlags(modifiers)
                event.post(tap: .cghidEventTap)
            }
        case .keypress(let keys):
            for key in keys {
                try Task.checkCancellation()
                try postKeyExpression(key)
            }
        case .type(let text):
            try postUnicodeText(text)
        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    static func normalizedModifier(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CMD", "COMMAND", "META": return "META"
        case "CTRL", "CONTROL": return "CTRL"
        case "ALT", "OPTION": return "ALT"
        case "SHIFT": return "SHIFT"
        case "FN", "FUNCTION", "GLOBE": return "FN"
        default: return nil
        }
    }

    static func validateKeyExpression(_ raw: String) throws {
        _ = try parsedKeyExpression(raw)
    }

    private struct ParsedKeyExpression {
        let modifiers: [String]
        let keyCode: CGKeyCode
    }

    private static func parsedKeyExpression(_ raw: String) throws -> ParsedKeyExpression {
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !parts.isEmpty,
              parts.count <= 6,
              parts.allSatisfy({ !$0.isEmpty }) else {
            throw MacDesktopEnvironmentError.invalidKeys
        }
        var modifiers: [String] = []
        for modifier in parts.dropLast() {
            guard let normalized = normalizedModifier(modifier) else {
                throw MacDesktopEnvironmentError.unsupportedKey(raw)
            }
            modifiers.append(normalized)
        }
        let final = parts[parts.count - 1]
        if let modifier = normalizedModifier(final), parts.count == 1 {
            guard let keyCode = modifierKeyCode(modifier) else {
                throw MacDesktopEnvironmentError.unsupportedKey(raw)
            }
            return ParsedKeyExpression(modifiers: [], keyCode: keyCode)
        }
        guard let keyCode = virtualKeyCode(final) else {
            throw MacDesktopEnvironmentError.unsupportedKey(raw)
        }
        return ParsedKeyExpression(modifiers: modifiers, keyCode: keyCode)
    }

    private func withModifiers(
        _ modifiers: [String],
        operation: () async throws -> Void
    ) async throws {
        let normalized = modifiers.compactMap(Self.normalizedModifier)
        try pressModifiers(normalized, keyDown: true)
        do {
            try await operation()
            try pressModifiers(normalized.reversed(), keyDown: false)
        } catch {
            try? pressModifiers(normalized.reversed(), keyDown: false)
            throw error
        }
    }

    private func pressModifiers<S: Sequence>(_ modifiers: S, keyDown: Bool) throws where S.Element == String {
        for modifier in modifiers {
            guard let code = Self.modifierKeyCode(modifier),
                  let event = CGEvent(
                    keyboardEventSource: eventSource(),
                    virtualKey: code,
                    keyDown: keyDown
                  ) else {
                throw MacDesktopEnvironmentError.eventConstructionFailed
            }
            event.flags = Self.modifierFlags([modifier])
            event.post(tap: .cghidEventTap)
        }
    }

    private func postClick(
        point: MacDesktopPoint,
        button: MacDesktopMouseButton,
        count: Int64
    ) throws {
        try postMouseMove(point)
        let types: (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case .left: types = (.leftMouseDown, .leftMouseUp, .left)
        case .right: types = (.rightMouseDown, .rightMouseUp, .right)
        case .middle: types = (.otherMouseDown, .otherMouseUp, .center)
        }
        guard let down = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: types.0,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: types.2
        ), let up = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: types.1,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: types.2
        ) else {
            throw MacDesktopEnvironmentError.eventConstructionFailed
        }
        down.setIntegerValueField(.mouseEventClickState, value: count)
        up.setIntegerValueField(.mouseEventClickState, value: count)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMouseMove(_ point: MacDesktopPoint) throws {
        guard let move = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: .left
        ) else {
            throw MacDesktopEnvironmentError.eventConstructionFailed
        }
        move.post(tap: .cghidEventTap)
    }

    private func postDrag(path: [MacDesktopPoint]) async throws {
        guard let first = path.first, let last = path.last else {
            throw MacDesktopEnvironmentError.invalidDragPath
        }
        try postMouseMove(first)
        guard let down = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: first.x, y: first.y),
            mouseButton: .left
        ) else {
            throw MacDesktopEnvironmentError.eventConstructionFailed
        }
        down.post(tap: .cghidEventTap)
        do {
            for point in path.dropFirst() {
                try Task.checkCancellation()
                guard let drag = CGEvent(
                    mouseEventSource: eventSource(),
                    mouseType: .leftMouseDragged,
                    mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                    mouseButton: .left
                ) else {
                    throw MacDesktopEnvironmentError.eventConstructionFailed
                }
                drag.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(8))
            }
        } catch {
            postMouseUp(at: last)
            throw error
        }
        postMouseUp(at: last)
    }

    private func postMouseUp(at point: MacDesktopPoint) {
        CGEvent(
            mouseEventSource: eventSource(),
            mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private func postKeyExpression(_ raw: String) throws {
        let parsed = try Self.parsedKeyExpression(raw)
        try postParsedKeyExpression(parsed)
    }

    private func postParsedKeyExpression(_ parsed: ParsedKeyExpression) throws {
        try pressModifiers(parsed.modifiers, keyDown: true)
        let flags = Self.modifierFlags(parsed.modifiers)
        do {
            guard let down = CGEvent(
                keyboardEventSource: eventSource(),
                virtualKey: parsed.keyCode,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: eventSource(),
                virtualKey: parsed.keyCode,
                keyDown: false
            ) else {
                throw MacDesktopEnvironmentError.eventConstructionFailed
            }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try pressModifiers(parsed.modifiers.reversed(), keyDown: false)
        } catch {
            try? pressModifiers(parsed.modifiers.reversed(), keyDown: false)
            throw error
        }
    }

    private func postUnicodeText(_ text: String) throws {
        var units = Array(text.utf16)
        var cursor = 0
        while cursor < units.count {
            try Task.checkCancellation()
            var end = min(cursor + 20, units.count)
            if end < units.count,
               end > cursor,
               (0xD800 ... 0xDBFF).contains(units[end - 1]),
               (0xDC00 ... 0xDFFF).contains(units[end]) {
                end -= 1
            }
            let count = end - cursor
            guard count > 0,
                  let down = CGEvent(
                    keyboardEventSource: eventSource(),
                    virtualKey: 0,
                    keyDown: true
                  ), let up = CGEvent(
                    keyboardEventSource: eventSource(),
                    virtualKey: 0,
                    keyDown: false
                  ) else {
                throw MacDesktopEnvironmentError.eventConstructionFailed
            }
            units.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(
                    stringLength: count,
                    unicodeString: base.advanced(by: cursor)
                )
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            cursor = end
        }
    }

    private func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func modifierFlags(_ modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch normalizedModifier(modifier) {
            case "META": flags.insert(.maskCommand)
            case "CTRL": flags.insert(.maskControl)
            case "ALT": flags.insert(.maskAlternate)
            case "SHIFT": flags.insert(.maskShift)
            case "FN": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
    }

    private static func modifierKeyCode(_ modifier: String) -> CGKeyCode? {
        switch normalizedModifier(modifier) {
        case "META": return 55
        case "SHIFT": return 56
        case "ALT": return 58
        case "CTRL": return 59
        case "FN": return 63
        default: return nil
        }
    }

    private static func virtualKeyCode(_ raw: String) -> CGKeyCode? {
        let key = raw.uppercased()
        let special: [String: CGKeyCode] = [
            "RETURN": 36, "ENTER": 36, "TAB": 48, "SPACE": 49,
            "BACKSPACE": 51, "ESC": 53, "ESCAPE": 53,
            "DELETE": 117, "DEL": 117, "HOME": 115, "END": 119,
            "PAGEUP": 116, "PAGEDOWN": 121,
            "LEFT": 123, "ARROWLEFT": 123, "RIGHT": 124, "ARROWRIGHT": 124,
            "DOWN": 125, "ARROWDOWN": 125, "UP": 126, "ARROWUP": 126,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118,
            "F5": 96, "F6": 97, "F7": 98, "F8": 100,
            "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        ]
        if let code = special[key] { return code }
        let printable: [String: CGKeyCode] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
            "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
            "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35,
            "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "`": 50,
        ]
        return printable[key]
    }
}
