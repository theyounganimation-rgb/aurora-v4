import Foundation

/// Limits applied before computer-use data crosses Aurora's native boundary.
/// They keep provider responses, screenshots, and model-authored action text
/// from becoming an unbounded memory allocation in the voice application.
public struct ComputerUseLimits: Sendable, Equatable {
    public let maximumResponseBytes: Int
    public let maximumScreenshotBytes: Int
    public let maximumTaskCharacters: Int
    public let maximumOutputItems: Int
    public let maximumComputerCalls: Int
    public let maximumActionsPerCall: Int
    public let maximumActionTextCharacters: Int
    public let maximumOutputTextCharacters: Int

    public init(
        maximumResponseBytes: Int = 8 * 1_024 * 1_024,
        maximumScreenshotBytes: Int = 16 * 1_024 * 1_024,
        maximumTaskCharacters: Int = 20_000,
        maximumOutputItems: Int = 128,
        maximumComputerCalls: Int = 16,
        maximumActionsPerCall: Int = 128,
        maximumActionTextCharacters: Int = 100_000,
        maximumOutputTextCharacters: Int = 32_000
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumScreenshotBytes = maximumScreenshotBytes
        self.maximumTaskCharacters = maximumTaskCharacters
        self.maximumOutputItems = maximumOutputItems
        self.maximumComputerCalls = maximumComputerCalls
        self.maximumActionsPerCall = maximumActionsPerCall
        self.maximumActionTextCharacters = maximumActionTextCharacters
        self.maximumOutputTextCharacters = maximumOutputTextCharacters
    }
}

public struct ComputerUseHTTPResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

/// Injectable so verification can inspect the exact request without making a
/// paid or state-changing network call.
public protocol ComputerUseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ComputerUseHTTPResponse
}

public struct DesktopPoint: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public enum DesktopMouseButton: Sendable, Equatable {
    case left
    case middle
    case right
    case unsupported(String)
}

/// One action from the GA Responses API `computer_call.actions[]` array.
public enum DesktopTaskAction: Sendable, Equatable {
    case screenshot
    case click(x: Int, y: Int, button: DesktopMouseButton)
    case doubleClick(x: Int, y: Int, button: DesktopMouseButton)
    case drag(path: [DesktopPoint])
    case move(x: Int, y: Int)
    case scroll(x: Int, y: Int, deltaX: Int, deltaY: Int)
    case keypress(keys: [String])
    case type(text: String)
    case wait

    /// Preserves forward compatibility without silently executing a new action
    /// that Aurora's native harness has not explicitly implemented.
    case unsupported(type: String)
}

public struct DesktopComputerCall: Sendable, Equatable {
    public let callID: String
    public let status: String?
    public let actions: [DesktopTaskAction]

    public init(callID: String, status: String? = nil, actions: [DesktopTaskAction]) {
        self.callID = callID
        self.status = status
        self.actions = actions
    }
}

/// A single provider response. The coordinator, rather than this transport
/// model, owns task lifetime, screen execution, retries, and cancellation.
public struct DesktopTaskStep: Sendable, Equatable {
    public let responseID: String
    public let responseStatus: String?
    public let computerCalls: [DesktopComputerCall]
    public let outputText: String?

    public init(
        responseID: String,
        responseStatus: String? = nil,
        computerCalls: [DesktopComputerCall],
        outputText: String? = nil
    ) {
        self.responseID = responseID
        self.responseStatus = responseStatus
        self.computerCalls = computerCalls
        self.outputText = outputText
    }

    public var isComplete: Bool {
        guard computerCalls.isEmpty else { return false }
        guard let responseStatus else { return true }
        return responseStatus.lowercased() == "completed"
    }
}

public enum ComputerUseClientError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case invalidModel
    case invalidLimits
    case invalidTask
    case invalidIdentifier(String)
    case screenshotTooLarge(maximumBytes: Int)
    case responseTooLarge(maximumBytes: Int)
    case responseLimitExceeded(String)
    case malformedResponse
    case requestEncodingFailed
    case transportFailed
    case api(statusCode: Int, code: String?, type: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Aurora needs an OpenAI API key for computer use."
        case .invalidEndpoint:
            return "Aurora's computer-use endpoint is invalid."
        case .invalidModel:
            return "Aurora's computer-use model is invalid."
        case .invalidLimits:
            return "Aurora's computer-use limits are invalid."
        case .invalidTask:
            return "Aurora received an invalid computer task."
        case .invalidIdentifier(let field):
            return "Aurora received an invalid computer-use \(field)."
        case .screenshotTooLarge(let maximumBytes):
            return "The desktop screenshot exceeded Aurora's \(maximumBytes)-byte computer-use limit."
        case .responseTooLarge(let maximumBytes):
            return "The computer-use response exceeded Aurora's \(maximumBytes)-byte limit."
        case .responseLimitExceeded(let field):
            return "The computer-use response exceeded Aurora's \(field) limit."
        case .malformedResponse:
            return "Aurora received an unreadable computer-use response."
        case .requestEncodingFailed:
            return "Aurora could not encode the computer-use request."
        case .transportFailed:
            return "Aurora could not reach the computer-use service."
        case .api(let statusCode, let code, _, let message):
            let label = code.flatMap { $0.isEmpty ? nil : $0 } ?? "HTTP \(statusCode)"
            return "Computer-use error \(label): \(message)"
        }
    }
}
