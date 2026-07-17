import Darwin
import Foundation

actor FoundationCodexAppServerTransport: CodexAppServerTransporting {
    private static let maximumBufferedInboundEvents = 64

    private struct BoundedRead: Sendable {
        let data: Data
        let overflowed: Bool
    }

    /// Tracks bytes retained by the stream and the runtime, not merely bytes
    /// read from the pipe. Each accepted line owns a lease that releases this
    /// reservation when its event is no longer retained.
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

            let byteCount = data.count
            return CodexAppServerInboundLine(data: data) { [weak self] in
                self?.release(byteCount: byteCount)
            }
        }

        private func release(byteCount: Int) {
            lock.lock()
            retainedBytes = max(0, retainedBytes - byteCount)
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
        guard launch.maximumInboundLineBytes >= 4_096,
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

        // Keep one extra zero-byte slot for the explicit overflow marker. The
        // byte lease controls retained payload memory; the event-count limit
        // protects against an unbounded burst of tiny notifications.
        let streamPair = AsyncStream<CodexAppServerTransportEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedInboundEvents + 1)
        )
        let inboundBudget = InboundBufferBudget(
            maximumBytes: launch.maximumBufferedInboundBytes,
            maximumEvents: Self.maximumBufferedInboundEvents
        )
        let currentGeneration = launch.generation
        do {
            try process.run()
        } catch {
            streamPair.continuation.finish()
            throw CodexTaskRuntimeError.processUnavailable
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        continuation = streamPair.continuation
        generation = currentGeneration
        expectedTermination = false
        maximumOutboundMessageBytes = launch.maximumOutboundMessageBytes
        terminationGracePeriod = launch.terminationGracePeriod

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let streamContinuation = streamPair.continuation
        let outputTask = Task.detached(priority: .utility) {
            Self.readJSONLines(
                from: outputHandle,
                maximumLineBytes: launch.maximumInboundLineBytes,
                budget: inboundBudget,
                continuation: streamContinuation
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            Self.readBounded(
                from: errorHandle,
                maximumBytes: launch.maximumStandardErrorBytes
            )
        }
        Task.detached(priority: .utility) { [weak self] in
            process.waitUntilExit()
            _ = await outputTask.value
            let standardError = await errorTask.value
            await self?.processDidTerminate(
                process,
                generation: currentGeneration,
                standardErrorOverflowed: standardError.overflowed
            )
        }
        return streamPair.stream
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
        do {
            try standardInput.write(contentsOf: message)
        } catch {
            throw CodexTaskRuntimeError.transportFailure
        }
    }

    func stop() async {
        guard let process else { return }
        expectedTermination = true
        try? standardInput?.close()
        standardInput = nil
        if process.isRunning { process.terminate() }

        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        // `Process.isRunning` can flip before the stdout/stderr readers drain
        // and the supervisor clears this generation. Wait for that cleanup so
        // an immediate restart never races the old process record.
        let cleanupDeadline = Date().addingTimeInterval(terminationGracePeriod)
        while self.process != nil, Date() < cleanupDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if self.process === process, !process.isRunning {
            let streamContinuation = continuation
            self.process = nil
            continuation = nil
            generation = nil
            expectedTermination = false
            maximumOutboundMessageBytes = 0
            streamContinuation?.yield(.terminated(
                exitCode: process.terminationStatus,
                expected: true,
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

    nonisolated private static func readJSONLines(
        from handle: FileHandle,
        maximumLineBytes: Int,
        budget: InboundBufferBudget,
        continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation
    ) -> Bool {
        var buffer = Data()
        var overflowed = false
        var overflowSignalled = false
        var sequence: UInt64 = 0
        defer { try? handle.close() }

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0a) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0d { line.removeLast() }
                guard line.count <= maximumLineBytes else {
                    overflowed = true
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
                if !line.isEmpty {
                    guard let retainedLine = budget.retain(line) else {
                        overflowed = true
                        buffer.removeAll(keepingCapacity: false)
                        break
                    }
                    switch continuation.yield(.line(sequence: sequence, data: retainedLine)) {
                    case .enqueued:
                        sequence &+= 1
                        break
                    case .dropped:
                        overflowed = true
                        buffer.removeAll(keepingCapacity: false)
                    case .terminated:
                        return false
                    @unknown default:
                        overflowed = true
                        buffer.removeAll(keepingCapacity: false)
                    }
                }
                if overflowed { break }
            }
            if overflowed { break }
            if buffer.count > maximumLineBytes {
                overflowed = true
                buffer.removeAll(keepingCapacity: false)
                break
            }
        }
        if !overflowed, !buffer.isEmpty {
            if buffer.last == 0x0d { buffer.removeLast() }
            if buffer.count <= maximumLineBytes {
                guard let retainedLine = budget.retain(buffer) else {
                    overflowed = true
                    buffer.removeAll(keepingCapacity: false)
                    if signalInboundOverflow(continuation) { overflowSignalled = true }
                    return overflowed
                }
                switch continuation.yield(.line(sequence: sequence, data: retainedLine)) {
                case .enqueued:
                    sequence &+= 1
                case .dropped:
                    overflowed = true
                case .terminated:
                    return false
                @unknown default:
                    overflowed = true
                }
            } else {
                overflowed = true
            }
        }
        if overflowed, !overflowSignalled {
            _ = signalInboundOverflow(continuation)
        }
        return overflowed
    }

    /// With bufferingOldest, a failed payload enqueue never displaces an
    /// earlier event. The reserved extra slot normally accepts this marker on
    /// the first attempt; retrying also makes the failure explicit if a future
    /// non-payload event temporarily occupies that slot.
    nonisolated private static func signalInboundOverflow(
        _ continuation: AsyncStream<CodexAppServerTransportEvent>.Continuation
    ) -> Bool {
        while true {
            switch continuation.yield(.inboundOverflow) {
            case .enqueued:
                return true
            case .dropped:
                Thread.sleep(forTimeInterval: 0.001)
            case .terminated:
                return false
            @unknown default:
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    nonisolated private static func readBounded(
        from handle: FileHandle,
        maximumBytes: Int
    ) -> BoundedRead {
        var retained = Data()
        var overflowed = false
        defer { try? handle.close() }
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            let remaining = max(0, maximumBytes - retained.count)
            if chunk.count > remaining { overflowed = true }
            if remaining > 0 { retained.append(chunk.prefix(remaining)) }
        }
        return BoundedRead(data: retained, overflowed: overflowed)
    }
}
