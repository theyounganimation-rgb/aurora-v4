import Foundation

public final class URLSessionComputerUseTransport: ComputerUseTransport, @unchecked Sendable {
    private static let requestDeadlineSeconds: TimeInterval = 30
    private static let resourceDeadlineSeconds: TimeInterval = 45

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = Self.requestDeadlineSeconds
            configuration.timeoutIntervalForResource = Self.resourceDeadlineSeconds
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> ComputerUseHTTPResponse {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ComputerUseClientError.transportFailed
            }
            return ComputerUseHTTPResponse(data: data, statusCode: httpResponse.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ComputerUseClientError {
            throw error
        } catch {
            throw ComputerUseClientError.transportFailed
        }
    }
}

/// One-step client for OpenAI's GA Responses computer tool. It intentionally
/// does not execute desktop actions: the native coordinator remains the only
/// component allowed to capture Aurora's screen or inject mouse/keyboard input.
public struct ComputerUseClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!

    private static let requestDeadlineSeconds: TimeInterval = 30
    private static let maximumRequestAttempts = 2
    private static let retryDelayMilliseconds: UInt64 = 350
    private static let maximumIdentifierCharacters = 256
    private static let maximumModelCharacters = 128
    private static let maximumCoordinateMagnitude = 1_000_000
    private static let maximumDragPoints = 512
    private static let maximumKeyCount = 64
    private static let maximumKeyCharacters = 128
    private static let maximumProviderErrorCharacters = 1_000

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let transport: any ComputerUseTransport
    private let limits: ComputerUseLimits

    public init(
        apiKey: String,
        model: String = "gpt-5.6",
        endpoint: URL = ComputerUseClient.defaultEndpoint,
        transport: any ComputerUseTransport = URLSessionComputerUseTransport(),
        limits: ComputerUseLimits = ComputerUseLimits()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.transport = transport
        self.limits = limits
    }

    public func start(task: String) async throws -> DesktopTaskStep {
        let configuration = try validatedConfiguration()
        let boundedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedTask.isEmpty,
              boundedTask.count <= limits.maximumTaskCharacters,
              !boundedTask.contains("\0") else {
            throw ComputerUseClientError.invalidTask
        }

        let payload = InitialComputerRequest(
            model: configuration.model,
            tools: [ComputerTool()],
            input: boundedTask
        )
        return try await perform(payload, apiKey: configuration.apiKey)
    }

    public func submitScreenshot(
        previousResponseID: String,
        callID: String,
        pngData: Data
    ) async throws -> DesktopTaskStep {
        let configuration = try validatedConfiguration()
        let responseID = try validatedIdentifier(previousResponseID, field: "response ID")
        let callID = try validatedIdentifier(callID, field: "call ID")
        guard !pngData.isEmpty else {
            throw ComputerUseClientError.malformedResponse
        }
        guard pngData.count <= limits.maximumScreenshotBytes else {
            throw ComputerUseClientError.screenshotTooLarge(
                maximumBytes: limits.maximumScreenshotBytes
            )
        }

        try Task.checkCancellation()
        let payload = ScreenshotComputerRequest(
            model: configuration.model,
            tools: [ComputerTool()],
            previousResponseID: responseID,
            input: [
                ComputerCallOutput(
                    callID: callID,
                    output: ComputerScreenshot(
                        imageURL: "data:image/png;base64,\(pngData.base64EncodedString())"
                    )
                ),
            ]
        )
        return try await perform(payload, apiKey: configuration.apiKey)
    }

    private func perform<Payload: Encodable>(
        _ payload: Payload,
        apiKey: String
    ) async throws -> DesktopTaskStep {
        try Task.checkCancellation()

        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComputerUseClientError.requestEncodingFailed
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestDeadlineSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // A retry must represent the same logical Responses step. Reusing one
        // bounded key prevents a transient network failure from creating two
        // independent provider-side steps when the first request actually
        // reached the service before the connection was lost.
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body

        let response = try await sendWithBoundedRetry(request)

        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: response.data)
        } catch {
            throw ComputerUseClientError.malformedResponse
        }
        return try decodeStep(envelope)
    }

    private func sendWithBoundedRetry(
        _ request: URLRequest
    ) async throws -> ComputerUseHTTPResponse {
        for attempt in 1...Self.maximumRequestAttempts {
            try Task.checkCancellation()

            do {
                let response = try await transport.send(request)
                try Task.checkCancellation()
                guard response.data.count <= limits.maximumResponseBytes else {
                    throw ComputerUseClientError.responseTooLarge(
                        maximumBytes: limits.maximumResponseBytes
                    )
                }
                if (200..<300).contains(response.statusCode) {
                    return response
                }
                if Self.isTransientHTTPStatus(response.statusCode),
                   attempt < Self.maximumRequestAttempts {
                    try await retryDelay()
                    continue
                }
                throw decodedAPIError(statusCode: response.statusCode, data: response.data)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as ComputerUseClientError {
                guard error == .transportFailed,
                      attempt < Self.maximumRequestAttempts else {
                    throw error
                }
                try await retryDelay()
            } catch {
                guard attempt < Self.maximumRequestAttempts else {
                    throw ComputerUseClientError.transportFailed
                }
                try await retryDelay()
            }
        }
        throw ComputerUseClientError.transportFailed
    }

    private func retryDelay() async throws {
        try await Task.sleep(
            nanoseconds: Self.retryDelayMilliseconds * 1_000_000
        )
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func decodeStep(_ envelope: ResponseEnvelope) throws -> DesktopTaskStep {
        try Task.checkCancellation()
        let responseID = try validatedIdentifier(envelope.id, field: "response ID")
        guard envelope.output.count <= limits.maximumOutputItems else {
            throw ComputerUseClientError.responseLimitExceeded("output item")
        }

        var calls: [DesktopComputerCall] = []
        var textParts: [String] = []
        var textCharacterCount = 0

        for item in envelope.output {
            try Task.checkCancellation()
            switch item.type {
            case "computer_call":
                guard calls.count < limits.maximumComputerCalls,
                      let rawCallID = item.callID,
                      let rawActions = item.actions,
                      !rawActions.isEmpty,
                      rawActions.count <= limits.maximumActionsPerCall else {
                    throw ComputerUseClientError.responseLimitExceeded("computer call")
                }
                let callID = try validatedIdentifier(rawCallID, field: "call ID")
                let actions = try rawActions.map(decodeAction)
                calls.append(
                    DesktopComputerCall(
                        callID: callID,
                        status: boundedOptional(item.status, maximumCharacters: 128),
                        actions: actions
                    )
                )

            case "message":
                for content in item.content ?? [] where content.type == "output_text" {
                    guard let text = content.text else { continue }
                    textCharacterCount += text.count
                    guard textCharacterCount <= limits.maximumOutputTextCharacters else {
                        throw ComputerUseClientError.responseLimitExceeded("output text")
                    }
                    textParts.append(text)
                }

            default:
                continue
            }
        }

        let outputText = textParts.joined()
        return DesktopTaskStep(
            responseID: responseID,
            responseStatus: boundedOptional(envelope.status, maximumCharacters: 128),
            computerCalls: calls,
            outputText: outputText.isEmpty ? nil : outputText
        )
    }

    private func decodeAction(_ raw: ResponseAction) throws -> DesktopTaskAction {
        func coordinate(_ value: Int?, _ name: String) throws -> Int {
            guard let value,
                  value >= -Self.maximumCoordinateMagnitude,
                  value <= Self.maximumCoordinateMagnitude else {
                throw ComputerUseClientError.responseLimitExceeded("action \(name)")
            }
            return value
        }

        switch raw.type {
        case "screenshot":
            return .screenshot

        case "click":
            return .click(
                x: try coordinate(raw.x, "x coordinate"),
                y: try coordinate(raw.y, "y coordinate"),
                button: decodedButton(raw.button)
            )

        case "double_click":
            return .doubleClick(
                x: try coordinate(raw.x, "x coordinate"),
                y: try coordinate(raw.y, "y coordinate"),
                button: decodedButton(raw.button)
            )

        case "drag":
            guard let path = raw.path,
                  (2...Self.maximumDragPoints).contains(path.count),
                  path.allSatisfy({
                      $0.x >= -Self.maximumCoordinateMagnitude
                          && $0.x <= Self.maximumCoordinateMagnitude
                          && $0.y >= -Self.maximumCoordinateMagnitude
                          && $0.y <= Self.maximumCoordinateMagnitude
                  }) else {
                throw ComputerUseClientError.responseLimitExceeded("drag path")
            }
            return .drag(path: path)

        case "move":
            return .move(
                x: try coordinate(raw.x, "x coordinate"),
                y: try coordinate(raw.y, "y coordinate")
            )

        case "scroll":
            return .scroll(
                x: try coordinate(raw.x, "x coordinate"),
                y: try coordinate(raw.y, "y coordinate"),
                deltaX: try coordinate(raw.scrollX, "horizontal scroll"),
                deltaY: try coordinate(raw.scrollY, "vertical scroll")
            )

        case "keypress":
            guard let keys = raw.keys,
                  !keys.isEmpty,
                  keys.count <= Self.maximumKeyCount,
                  keys.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumKeyCharacters }) else {
                throw ComputerUseClientError.responseLimitExceeded("keypress")
            }
            return .keypress(keys: keys)

        case "type":
            guard let text = raw.text,
                  text.count <= limits.maximumActionTextCharacters else {
                throw ComputerUseClientError.responseLimitExceeded("action text")
            }
            return .type(text: text)

        case "wait":
            return .wait

        default:
            guard !raw.type.isEmpty, raw.type.count <= 128 else {
                throw ComputerUseClientError.malformedResponse
            }
            return .unsupported(type: raw.type)
        }
    }

    private func decodedButton(_ value: String?) -> DesktopMouseButton {
        switch value?.lowercased() {
        case nil, "left": return .left
        case "middle": return .middle
        case "right": return .right
        case let value?: return .unsupported(String(value.prefix(128)))
        }
    }

    private func validatedConfiguration() throws -> (apiKey: String, model: String) {
        guard limits.maximumResponseBytes > 0,
              limits.maximumScreenshotBytes > 0,
              limits.maximumTaskCharacters > 0,
              limits.maximumOutputItems > 0,
              limits.maximumComputerCalls > 0,
              limits.maximumActionsPerCall > 0,
              limits.maximumActionTextCharacters >= 0,
              limits.maximumOutputTextCharacters >= 0 else {
            throw ComputerUseClientError.invalidLimits
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.count <= 4_096,
              !key.contains("\r"),
              !key.contains("\n"),
              !key.contains("\0") else {
            throw ComputerUseClientError.missingAPIKey
        }

        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              model.count <= Self.maximumModelCharacters,
              model.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
            throw ComputerUseClientError.invalidModel
        }

        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw ComputerUseClientError.invalidEndpoint
        }
        return (key, model)
    }

    private func validatedIdentifier(_ value: String, field: String) throws -> String {
        let bounded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty,
              bounded.count <= Self.maximumIdentifierCharacters,
              !bounded.contains("\0"),
              !bounded.contains("\r"),
              !bounded.contains("\n") else {
            throw ComputerUseClientError.invalidIdentifier(field)
        }
        return bounded
    }

    private func boundedOptional(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else { return nil }
        return String(value.prefix(maximumCharacters))
    }

    private func decodedAPIError(statusCode: Int, data: Data) -> ComputerUseClientError {
        let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        let providerError = envelope?.error
        return .api(
            statusCode: statusCode,
            code: boundedOptional(providerError?.code, maximumCharacters: 128),
            type: boundedOptional(providerError?.type, maximumCharacters: 128),
            message: boundedOptional(
                providerError?.message,
                maximumCharacters: Self.maximumProviderErrorCharacters
            ) ?? "The computer-use request was rejected."
        )
    }
}

private struct ComputerTool: Encodable {
    let type = "computer"
}

private struct InitialComputerRequest: Encodable {
    let model: String
    let tools: [ComputerTool]
    let input: String
}

private struct ScreenshotComputerRequest: Encodable {
    let model: String
    let tools: [ComputerTool]
    let previousResponseID: String
    let input: [ComputerCallOutput]

    enum CodingKeys: String, CodingKey {
        case model
        case tools
        case previousResponseID = "previous_response_id"
        case input
    }
}

private struct ComputerCallOutput: Encodable {
    let type = "computer_call_output"
    let callID: String
    let output: ComputerScreenshot

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }
}

private struct ComputerScreenshot: Encodable {
    let type = "computer_screenshot"
    let imageURL: String
    let detail = "original"

    enum CodingKeys: String, CodingKey {
        case type
        case imageURL = "image_url"
        case detail
    }
}

private struct ResponseEnvelope: Decodable {
    let id: String
    let status: String?
    let output: [ResponseOutputItem]
}

private struct ResponseOutputItem: Decodable {
    let type: String
    let callID: String?
    let status: String?
    let actions: [ResponseAction]?
    let content: [ResponseContent]?

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case status
        case actions
        case content
    }
}

private struct ResponseContent: Decodable {
    let type: String
    let text: String?
}

private struct ResponseAction: Decodable {
    let type: String
    let x: Int?
    let y: Int?
    let button: String?
    let path: [DesktopPoint]?
    let scrollX: Int?
    let scrollY: Int?
    let keys: [String]?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case button
        case path
        case scrollX = "scroll_x"
        case scrollY = "scroll_y"
        case keys
        case text
    }
}

private struct APIErrorEnvelope: Decodable {
    let error: ProviderError
}

private struct ProviderError: Decodable {
    let message: String?
    let type: String?
    let code: String?
}
