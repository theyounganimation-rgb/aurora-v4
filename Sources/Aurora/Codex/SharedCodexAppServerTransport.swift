import CryptoKit
import Darwin
import Foundation
import Security

struct CodexSharedDaemonEndpoint: Sendable, Equatable {
    let executableURL: URL
    let socketURL: URL
    let version: String
}

enum CodexSharedDaemonProbeResult: Sendable, Equatable {
    case unavailable
    case compatible(CodexSharedDaemonEndpoint)
}

protocol CodexSharedDaemonProbing: Sendable {
    func probe(
        executableURL: URL,
        codexHomeURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> CodexSharedDaemonProbeResult
}

/// A read-only compatibility probe for the managed app-server daemon used by
/// Codex Desktop. It never starts, stops, installs, or rewrites daemon state.
actor FoundationCodexSharedDaemonProbe: CodexSharedDaemonProbing {
    private static let maximumVersionReportBytes = 16 * 1_024
    private static let expectedTeamID = "2DC432GLL2"

    func probe(
        executableURL: URL,
        codexHomeURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> CodexSharedDaemonProbeResult {
        guard timeout >= 0.25, timeout <= 5 else { return .unavailable }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "daemon", "version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                terminate(process)
                return .unavailable
            }
        }
        guard !process.isRunning else {
            terminate(process)
            return .unavailable
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            return .unavailable
        }

        let report = output.fileHandleForReading.readDataToEndOfFile()
        guard report.count <= Self.maximumVersionReportBytes,
              let endpoint = CodexSharedDaemonVersionReport.compatibleEndpoint(
                from: report,
                codexHomeURL: codexHomeURL
              ),
              Self.validateSocket(endpoint.socketURL),
              Self.validateManagedExecutable(
                endpoint.executableURL,
                codexHomeURL: codexHomeURL,
                version: endpoint.version
              ) else {
            return .unavailable
        }
        return .compatible(endpoint)
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private nonisolated static func validateSocket(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == getuid(),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            return false
        }
        return true
    }

    private nonisolated static func validateManagedExecutable(
        _ url: URL,
        codexHomeURL: URL,
        version: String
    ) -> Bool {
        let expectedLink = codexHomeURL
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("standalone", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
            .standardizedFileURL
        guard url.standardizedFileURL == expectedLink else { return false }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let releasesRoot = codexHomeURL
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("standalone", isDirectory: true)
            .appendingPathComponent("releases", isDirectory: true)
            .standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(releasesRoot),
              resolved.path.hasSuffix("/bin/codex"),
              resolved.path.contains("/" + version + "-") else {
            return false
        }

        var status = stat()
        guard resolved.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamID,
              dictionary[kSecCodeInfoIdentifier as String] as? String == "codex" else {
            return false
        }
        return true
    }
}

enum CodexSharedDaemonVersionReport {
    static func compatibleEndpoint(
        from data: Data,
        codexHomeURL: URL
    ) -> CodexSharedDaemonEndpoint? {
        guard !data.isEmpty,
              data.count <= 16 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "running",
              let managedPath = boundedASCII(object["managedCodexPath"] as? String, limit: 1_024),
              let socketPath = boundedASCII(object["socketPath"] as? String, limit: 1_024),
              let managedVersion = boundedVersion(object["managedCodexVersion"] as? String),
              let appServerVersion = boundedVersion(object["appServerVersion"] as? String),
              managedVersion == appServerVersion else {
            return nil
        }

        let expectedExecutable = codexHomeURL
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("standalone", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
            .standardizedFileURL
        let expectedSocket = codexHomeURL
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock", isDirectory: false)
            .standardizedFileURL
        let reportedExecutable = URL(fileURLWithPath: managedPath).standardizedFileURL
        let reportedSocket = URL(fileURLWithPath: socketPath).standardizedFileURL
        guard reportedExecutable == expectedExecutable,
              reportedSocket == expectedSocket else {
            return nil
        }
        return CodexSharedDaemonEndpoint(
            executableURL: reportedExecutable,
            socketURL: reportedSocket,
            version: managedVersion
        )
    }

    private static func boundedASCII(_ value: String?, limit: Int) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= limit,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else {
            return nil
        }
        return value
    }

    private static func boundedVersion(_ value: String?) -> String? {
        guard let value = boundedASCII(value, limit: 64),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 97...122: return true
                  default: return false
                  }
              }) else {
            return nil
        }
        return value
    }
}

enum CodexWebSocketCodecError: Error, Sendable, Equatable {
    case invalidHandshake
    case invalidFrame
    case messageTooLarge
    case invalidText
}

enum CodexWebSocketInboundEvent: Sendable, Equatable {
    case text(Data)
    case ping(Data)
    case pong
    case close(Data)
}

struct CodexWebSocketFrameParser: Sendable {
    private let maximumMessageBytes: Int
    private let maximumBufferedBytes: Int
    private var buffer = Data()
    private var fragmentedText: Data?

    init(maximumMessageBytes: Int, maximumBufferedBytes: Int? = nil) {
        self.maximumMessageBytes = maximumMessageBytes
        self.maximumBufferedBytes = maximumBufferedBytes ?? maximumMessageBytes + 14
    }

    mutating func append(_ data: Data) throws -> [CodexWebSocketInboundEvent] {
        guard data.count <= maximumBufferedBytes,
              buffer.count <= maximumBufferedBytes - data.count else {
            throw CodexWebSocketCodecError.messageTooLarge
        }
        buffer.append(data)
        var events: [CodexWebSocketInboundEvent] = []

        while true {
            guard buffer.count >= 2 else { break }
            let first = buffer[buffer.startIndex]
            let second = buffer[buffer.index(after: buffer.startIndex)]
            guard first & 0x70 == 0, second & 0x80 == 0 else {
                throw CodexWebSocketCodecError.invalidFrame
            }
            let final = first & 0x80 != 0
            let opcode = first & 0x0f
            var headerBytes = 2
            var payloadLength = UInt64(second & 0x7f)
            if payloadLength == 126 {
                guard buffer.count >= 4 else { break }
                payloadLength = UInt64(buffer[buffer.startIndex + 2]) << 8
                    | UInt64(buffer[buffer.startIndex + 3])
                headerBytes = 4
            } else if payloadLength == 127 {
                guard buffer.count >= 10 else { break }
                guard buffer[buffer.startIndex + 2] & 0x80 == 0 else {
                    throw CodexWebSocketCodecError.invalidFrame
                }
                payloadLength = 0
                for offset in 2..<10 {
                    payloadLength = payloadLength << 8 | UInt64(buffer[buffer.startIndex + offset])
                }
                headerBytes = 10
            }
            guard payloadLength <= UInt64(maximumMessageBytes),
                  payloadLength <= UInt64(Int.max) else {
                throw CodexWebSocketCodecError.messageTooLarge
            }
            let total = headerBytes + Int(payloadLength)
            guard buffer.count >= total else { break }
            let payload = Data(buffer[headerBytes..<total])
            buffer.removeSubrange(0..<total)

            switch opcode {
            case 0x0:
                guard var fragmentedText else {
                    throw CodexWebSocketCodecError.invalidFrame
                }
                guard fragmentedText.count <= maximumMessageBytes - payload.count else {
                    throw CodexWebSocketCodecError.messageTooLarge
                }
                fragmentedText.append(payload)
                if final {
                    guard String(data: fragmentedText, encoding: .utf8) != nil else {
                        throw CodexWebSocketCodecError.invalidText
                    }
                    events.append(.text(fragmentedText))
                    self.fragmentedText = nil
                } else {
                    self.fragmentedText = fragmentedText
                }

            case 0x1:
                guard fragmentedText == nil else {
                    throw CodexWebSocketCodecError.invalidFrame
                }
                if final {
                    guard String(data: payload, encoding: .utf8) != nil else {
                        throw CodexWebSocketCodecError.invalidText
                    }
                    events.append(.text(payload))
                } else {
                    fragmentedText = payload
                }

            case 0x8, 0x9, 0xA:
                guard final, payload.count <= 125 else {
                    throw CodexWebSocketCodecError.invalidFrame
                }
                if opcode == 0x8 {
                    guard payload.count != 1 else {
                        throw CodexWebSocketCodecError.invalidFrame
                    }
                    if payload.count >= 2 {
                        let code = UInt16(payload[payload.startIndex]) << 8
                            | UInt16(payload[payload.startIndex + 1])
                        guard Self.validCloseCode(code) else {
                            throw CodexWebSocketCodecError.invalidFrame
                        }
                    }
                    if payload.count > 2 {
                        guard String(data: payload.dropFirst(2), encoding: .utf8) != nil else {
                            throw CodexWebSocketCodecError.invalidText
                        }
                    }
                    events.append(.close(payload))
                } else if opcode == 0x9 {
                    events.append(.ping(payload))
                } else {
                    events.append(.pong)
                }

            default:
                throw CodexWebSocketCodecError.invalidFrame
            }
        }
        return events
    }

    private static func validCloseCode(_ code: UInt16) -> Bool {
        if (1_000...1_014).contains(code) {
            return ![1_004, 1_005, 1_006].contains(code)
        }
        return (3_000...4_999).contains(code)
    }
}

enum CodexWebSocketCodec {
    private static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func makeHandshake() -> (request: Data, expectedAccept: String) {
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let key = nonce.base64EncodedString()
        let digest = Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))
        let expectedAccept = Data(digest).base64EncodedString()
        let request = [
            "GET /rpc HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            "",
        ].joined(separator: "\r\n")
        return (Data(request.utf8), expectedAccept)
    }

    static func validateHandshakeResponse(_ data: Data, expectedAccept: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexWebSocketCodecError.invalidHandshake
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first,
              status.hasPrefix("HTTP/1.1 101 ") || status == "HTTP/1.1 101" else {
            throw CodexWebSocketCodecError.invalidHandshake
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw CodexWebSocketCodecError.invalidHandshake
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased()
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .contains("upgrade") == true,
              headers["sec-websocket-accept"] == expectedAccept else {
            throw CodexWebSocketCodecError.invalidHandshake
        }
    }

    static func encodeClientText(_ payload: Data) -> Data {
        encodeClientFrame(opcode: 0x1, payload: payload)
    }

    static func encodeClientPong(_ payload: Data) -> Data {
        encodeClientFrame(opcode: 0xA, payload: payload)
    }

    static func encodeClientClose(_ payload: Data = Data()) -> Data {
        encodeClientFrame(opcode: 0x8, payload: payload)
    }

    private static func encodeClientFrame(opcode: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        var generator = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        return frame
    }
}

private final class CodexWebSocketHandshakeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int
    private var buffer = Data()
    private var continuation: CheckedContinuation<(header: Data, remainder: Data), Error>?
    private var completed = false

    init(handle: FileHandle, maximumBytes: Int = 16 * 1_024) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    func read(timeout: TimeInterval) async throws -> (header: Data, remainder: Data) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            handle.readabilityHandler = { [weak self] readable in
                self?.consume(from: readable)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                self.finish(.failure(CodexTaskRuntimeError.requestTimedOut(
                    method: "websocket/upgrade"
                )))
            }
        }
    }

    private func consume(from readable: FileHandle) {
        lock.lock()
        let shouldRead = !completed
        lock.unlock()
        guard shouldRead else { return }
        consume(readable.availableData)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            finish(.failure(CodexWebSocketCodecError.invalidHandshake))
            return
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        buffer.append(data)
        if buffer.count > maximumBytes {
            lock.unlock()
            finish(.failure(CodexWebSocketCodecError.invalidHandshake))
            return
        }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            lock.unlock()
            return
        }
        let header = Data(buffer[..<end.upperBound])
        let remainder = Data(buffer[end.upperBound...])
        lock.unlock()
        finish(.success((header, remainder)))
    }

    private func finish(
        _ result: Result<(header: Data, remainder: Data), Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        handle.readabilityHandler = nil
        continuation?.resume(with: result)
    }
}

/// Bridges the daemon's WebSocket-over-Unix-socket protocol through the
/// official `codex app-server proxy` subprocess while preserving the runtime's
/// existing bounded JSON-message transport contract.
actor SharedCodexAppServerTransport: CodexAppServerTransporting {
    private static let maximumBufferedInboundEvents = 64

    private final class InboundBufferBudget: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private let maximumEvents: Int
        private var retainedBytes = 0
        private var retainedEvents = 0
        private var overflowed = false

        init(maximumBytes: Int, maximumEvents: Int) {
            self.maximumBytes = maximumBytes
            self.maximumEvents = maximumEvents
        }

        func retain(_ data: Data) -> CodexAppServerInboundLine? {
            lock.lock()
            guard !overflowed,
                  data.count <= maximumBytes,
                  retainedBytes <= maximumBytes - data.count,
                  retainedEvents < maximumEvents else {
                overflowed = true
                lock.unlock()
                return nil
            }
            retainedBytes += data.count
            retainedEvents += 1
            lock.unlock()
            let count = data.count
            return CodexAppServerInboundLine(data: data) { [weak self] in
                self?.release(count)
            }
        }

        private func release(_ count: Int) {
            lock.lock()
            retainedBytes = max(0, retainedBytes - count)
            retainedEvents = max(0, retainedEvents - 1)
            lock.unlock()
        }
    }

    private var process: Process?
    private var standardInput: FileHandle?
    private var continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation?
    private var generation: UUID?
    private var expectedTermination = false
    private var maximumOutboundMessageBytes = 0
    private var terminationGracePeriod: TimeInterval = 0.75

    func start(_ launch: CodexAppServerLaunch) async throws -> AsyncStream<CodexAppServerTransportEvent> {
        guard process == nil else { throw CodexTaskRuntimeError.processUnavailable }
        guard launch.arguments.count == 4,
              launch.arguments[0...1] == ["app-server", "proxy"],
              launch.arguments[2] == "--sock",
              launch.arguments[3].hasPrefix("/"),
              launch.maximumInboundLineBytes >= 4_096,
              launch.maximumBufferedInboundBytes >= launch.maximumInboundLineBytes,
              launch.maximumBufferedInboundBytes <= 64 * 1_024 * 1_024,
              launch.maximumOutboundMessageBytes >= 4_096,
              launch.maximumStandardErrorBytes >= 1_024 else {
            throw CodexTaskRuntimeError.invalidConfiguration
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let streamPair = AsyncStream<CodexAppServerTransportEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedInboundEvents + 1)
        )
        let inboundBudget = InboundBufferBudget(
            maximumBytes: launch.maximumBufferedInboundBytes,
            maximumEvents: Self.maximumBufferedInboundEvents
        )
        do {
            try process.run()
        } catch {
            streamPair.continuation.finish()
            throw CodexTaskRuntimeError.processUnavailable
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        generation = launch.generation
        expectedTermination = false
        maximumOutboundMessageBytes = launch.maximumOutboundMessageBytes
        terminationGracePeriod = launch.terminationGracePeriod

        let errorHandle = errorPipe.fileHandleForReading
        let errorTask = Task.detached(priority: .utility) {
            Self.readBounded(
                from: errorHandle,
                maximumBytes: launch.maximumStandardErrorBytes
            )
        }

        let handshake = CodexWebSocketCodec.makeHandshake()
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: handshake.request)
            let reader = CodexWebSocketHandshakeReader(
                handle: outputPipe.fileHandleForReading
            )
            let response = try await reader.read(
                timeout: min(5, max(1, launch.terminationGracePeriod * 4))
            )
            try CodexWebSocketCodec.validateHandshakeResponse(
                response.header,
                expectedAccept: handshake.expectedAccept
            )

            continuation = streamPair.continuation
            let currentGeneration = launch.generation
            let outputHandle = outputPipe.fileHandleForReading
            let outputContinuation = streamPair.continuation
            let outputTask = Task.detached(priority: .utility) { [weak self] in
                await Self.readFrames(
                    from: outputHandle,
                    initialData: response.remainder,
                    maximumMessageBytes: launch.maximumInboundLineBytes,
                    maximumBufferedBytes: launch.maximumBufferedInboundBytes,
                    budget: inboundBudget,
                    generation: currentGeneration,
                    continuation: outputContinuation,
                    owner: self
                )
            }
            Task.detached(priority: .utility) { [weak self] in
                process.waitUntilExit()
                _ = await outputTask.value
                let stderr = await errorTask.value
                await self?.processDidTerminate(
                    process,
                    generation: currentGeneration,
                    standardErrorOverflowed: stderr
                )
            }
            return streamPair.stream
        } catch {
            streamPair.continuation.finish()
            await terminateActiveProcess()
            _ = await errorTask.value
            throw CodexTaskRuntimeError.processUnavailable
        }
    }

    func send(_ message: Data, generation expectedGeneration: UUID) async throws {
        guard let process,
              process.isRunning,
              let standardInput,
              generation == expectedGeneration else {
            throw CodexTaskRuntimeError.transportFailure
        }
        guard !message.isEmpty,
              message.count <= maximumOutboundMessageBytes,
              message.last == 0x0a else {
            throw CodexTaskRuntimeError.outboundMessageTooLarge
        }
        let payload = message.dropLast()
        let frame = CodexWebSocketCodec.encodeClientText(Data(payload))
        do {
            try standardInput.write(contentsOf: frame)
        } catch {
            throw CodexTaskRuntimeError.transportFailure
        }
    }

    func stop() async {
        guard process != nil else { return }
        expectedTermination = true
        if let standardInput {
            try? standardInput.write(contentsOf: CodexWebSocketCodec.encodeClientClose())
        }
        await terminateActiveProcess()
    }

    nonisolated private static func readFrames(
        from handle: FileHandle,
        initialData: Data,
        maximumMessageBytes: Int,
        maximumBufferedBytes: Int,
        budget: InboundBufferBudget,
        generation expectedGeneration: UUID,
        continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation,
        owner: SharedCodexAppServerTransport?
    ) async {
        var parser = CodexWebSocketFrameParser(
            maximumMessageBytes: maximumMessageBytes,
            maximumBufferedBytes: maximumBufferedBytes
        )
        var sequence: UInt64 = 0
        var nextData = initialData
        defer { try? handle.close() }

        while true {
            if nextData.isEmpty { nextData = handle.availableData }
            guard !nextData.isEmpty else { return }
            do {
                for event in try parser.append(nextData) {
                    switch event {
                    case .text(let payload):
                        guard let retained = budget.retain(payload) else {
                            await signal(.inboundOverflow, continuation: continuation)
                            return
                        }
                        switch continuation.yield(.line(sequence: sequence, data: retained)) {
                        case .enqueued:
                            sequence &+= 1
                        case .dropped:
                            await signal(.inboundOverflow, continuation: continuation)
                            return
                        case .terminated:
                            return
                        @unknown default:
                            await signal(.inboundOverflow, continuation: continuation)
                            return
                        }

                    case .ping(let payload):
                        await owner?.sendPong(payload, generation: expectedGeneration)

                    case .pong:
                        break

                    case .close(let payload):
                        await owner?.acknowledgeClose(payload, generation: expectedGeneration)
                        return
                    }
                }
            } catch CodexWebSocketCodecError.messageTooLarge {
                await signal(.inboundOverflow, continuation: continuation)
                return
            } catch {
                await signal(.protocolFailure, continuation: continuation)
                return
            }
            nextData = Data()
        }
    }

    private func sendPong(_ payload: Data, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, let standardInput else { return }
        try? standardInput.write(contentsOf: CodexWebSocketCodec.encodeClientPong(payload))
    }

    private func acknowledgeClose(_ payload: Data, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, let standardInput else { return }
        try? standardInput.write(contentsOf: CodexWebSocketCodec.encodeClientClose(payload))
        try? standardInput.close()
        self.standardInput = nil
    }

    private func terminateActiveProcess() async {
        guard let process else { return }
        try? standardInput?.close()
        standardInput = nil
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        let cleanupDeadline = Date().addingTimeInterval(terminationGracePeriod)
        while self.process != nil, process.isRunning, Date() < cleanupDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if self.process === process, !process.isRunning {
            let streamContinuation = continuation
            let expected = expectedTermination
            self.process = nil
            continuation = nil
            generation = nil
            maximumOutboundMessageBytes = 0
            expectedTermination = false
            streamContinuation?.yield(.terminated(
                exitCode: process.terminationStatus,
                expected: expected,
                standardErrorOverflowed: false
            ))
            streamContinuation?.finish()
        }
    }

    private func processDidTerminate(
        _ endedProcess: Process,
        generation endedGeneration: UUID,
        standardErrorOverflowed: Bool
    ) {
        guard generation == endedGeneration,
              process === endedProcess else { return }
        let expected = expectedTermination
        let streamContinuation = continuation
        process = nil
        standardInput = nil
        continuation = nil
        generation = nil
        expectedTermination = false
        maximumOutboundMessageBytes = 0
        streamContinuation?.yield(.terminated(
            exitCode: endedProcess.terminationStatus,
            expected: expected,
            standardErrorOverflowed: standardErrorOverflowed
        ))
        streamContinuation?.finish()
    }

    nonisolated private static func signal(
        _ event: CodexAppServerTransportEvent,
        continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation
    ) async {
        while true {
            switch continuation.yield(event) {
            case .enqueued, .terminated:
                return
            case .dropped:
                try? await Task.sleep(for: .milliseconds(1))
            @unknown default:
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    nonisolated private static func readBounded(
        from handle: FileHandle,
        maximumBytes: Int
    ) -> Bool {
        var retainedBytes = 0
        var overflowed = false
        defer { try? handle.close() }
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            if chunk.count > max(0, maximumBytes - retainedBytes) {
                overflowed = true
            }
            retainedBytes = min(maximumBytes, retainedBytes + chunk.count)
        }
        return overflowed
    }
}
