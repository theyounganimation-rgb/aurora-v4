import Foundation

enum InstalledComputerUseAPISelfTest {
    struct Report: Codable {
        let ok: Bool
        let model: String
        let receivedComputerCall: Bool
        let actionTypes: [String]
        let failure: String?
    }

    static func run() async -> Report {
        do {
            guard let apiKey = try KeychainVoiceKey.load() else {
                return failed("missing_key")
            }
            let client = ComputerUseClient(apiKey: apiKey)
            let step = try await withThrowingTaskGroup(of: DesktopTaskStep.self) { group in
                group.addTask {
                    try await client.start(
                        task: "Use the computer tool. Request exactly one screenshot and take no other action."
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    throw ComputerUseClientError.transportFailed
                }
                guard let first = try await group.next() else {
                    throw ComputerUseClientError.transportFailed
                }
                group.cancelAll()
                return first
            }
            let actions = step.computerCalls.flatMap(\.actions).map(actionName)
            let receivedCall = !step.computerCalls.isEmpty
            return Report(
                ok: receivedCall && actions == ["screenshot"],
                model: "gpt-5.6",
                receivedComputerCall: receivedCall,
                actionTypes: actions,
                failure: receivedCall && actions == ["screenshot"] ? nil : "unexpected_response_shape"
            )
        } catch let error as ComputerUseClientError {
            let code: String
            switch error {
            case .api(_, let providerCode, let providerType, _):
                code = providerCode ?? providerType ?? "api_rejected"
            case .missingAPIKey: code = "missing_key"
            case .transportFailed: code = "transport_or_timeout"
            default: code = String(describing: error)
            }
            return failed(String(code.prefix(160)))
        } catch {
            return failed("self_test_failed")
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
            model: "gpt-5.6",
            receivedComputerCall: false,
            actionTypes: [],
            failure: code
        )
    }

    private static func actionName(_ action: DesktopTaskAction) -> String {
        switch action {
        case .screenshot: return "screenshot"
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .drag: return "drag"
        case .move: return "move"
        case .scroll: return "scroll"
        case .keypress: return "keypress"
        case .type: return "type"
        case .wait: return "wait"
        case .unsupported(let type): return "unsupported:\(String(type.prefix(80)))"
        }
    }
}
