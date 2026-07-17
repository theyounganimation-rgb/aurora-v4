import Foundation
import Network

// These value types normally live beside AuroraAudioEngine. Defining them in
// this standalone verifier keeps AVFoundation and the physical Mac audio path
// out of a transport-only test while exercising the production server itself.
struct AuroraPlaybackKey: Hashable, Sendable {
    let responseID: String
    let itemID: String
    let contentIndex: Int
}

struct AuroraPlaybackCut: Sendable, Equatable {
    let key: AuroraPlaybackKey
    let playedMilliseconds: Int
}

protocol AuroraRealtimeAudio: AnyObject {
    var onMicrophonePCM: ((Data) -> Void)? { get set }
    var onInputLevel: ((Float) -> Void)? { get set }
    var onOutputLevel: ((Float) -> Void)? { get set }
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)? { get set }
    var onPlaybackIdle: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
    func enqueuePlayback(_ pcm16Data: Data, for key: AuroraPlaybackKey)
    func markPlaybackItemComplete(_ key: AuroraPlaybackKey)
    func interruptPlayback() -> [AuroraPlaybackCut]
}

// The route verifier never selects local audio. This tiny stand-in keeps the
// production route coordinator under test without touching AVFoundation or a
// physical microphone.
final class AuroraAudioEngine: AuroraRealtimeAudio {
    var onMicrophonePCM: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)?
    var onPlaybackIdle: (() -> Void)?
    var onError: ((Error) -> Void)?

    func start() throws {}
    func stop() {}
    func enqueuePlayback(_ pcm16Data: Data, for key: AuroraPlaybackKey) {}
    func markPlaybackItemComplete(_ key: AuroraPlaybackKey) {}
    func interruptPlayback() -> [AuroraPlaybackCut] { [] }
}

private enum VerificationFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class FakePairingStore: AuroraCompanionPairingStoring {
    let storedSecret: Data
    private let lock = NSLock()
    private(set) var secretReadCount = 0

    init(secret: Data) {
        storedSecret = secret
    }

    func secret() throws -> Data {
        lock.lock()
        secretReadCount += 1
        lock.unlock()
        return storedSecret
    }

    func pairingCode(at date: Date) -> String {
        AuroraCompanionProtocol.pairingCode(secret: storedSecret, at: date)
    }
}

private final class ServerProbe {
    struct Snapshot {
        let statuses: [String]
        let wakeCount: Int
        let restCount: Int
        let disconnectCount: Int
        let microphone: [Data]
        let inputLevels: [Float]
        let outputLevels: [Float]
        let finishedKeys: [AuroraPlaybackKey]
        let idleCount: Int
        let protocolErrors: [AuroraCompanionProtocolError]
    }

    private let lock = NSLock()
    private var statuses: [String] = []
    private var wakeCount = 0
    private var restCount = 0
    private var disconnectCount = 0
    private var microphone: [Data] = []
    private var inputLevels: [Float] = []
    private var outputLevels: [Float] = []
    private var finishedKeys: [AuroraPlaybackKey] = []
    private var idleCount = 0
    private var protocolErrors: [AuroraCompanionProtocolError] = []

    func bind(to server: AuroraCompanionServer) {
        server.onStatusChanged = { [weak self] status in self?.recordStatus(status) }
        server.onWakeRequested = { [weak self] in self?.recordWake() }
        server.onRestRequested = { [weak self] in self?.recordRest() }
        server.onRemoteDisconnected = { [weak self] in self?.recordDisconnect() }
        server.onMicrophonePCM = { [weak self] data in self?.recordMicrophone(data) }
        server.onInputLevel = { [weak self] level in self?.recordInputLevel(level) }
        server.onOutputLevel = { [weak self] level in self?.recordOutputLevel(level) }
        server.onPlaybackItemFinished = { [weak self] key in self?.recordFinished(key) }
        server.onPlaybackIdle = { [weak self] in self?.recordIdle() }
        server.onError = { [weak self] error in
            guard let protocolError = error as? AuroraCompanionProtocolError else { return }
            self?.recordError(protocolError)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            statuses: statuses,
            wakeCount: wakeCount,
            restCount: restCount,
            disconnectCount: disconnectCount,
            microphone: microphone,
            inputLevels: inputLevels,
            outputLevels: outputLevels,
            finishedKeys: finishedKeys,
            idleCount: idleCount,
            protocolErrors: protocolErrors
        )
    }

    private func recordStatus(_ value: String) {
        lock.lock(); statuses.append(value); lock.unlock()
    }

    private func recordWake() {
        lock.lock(); wakeCount += 1; lock.unlock()
    }

    private func recordRest() {
        lock.lock(); restCount += 1; lock.unlock()
    }

    private func recordDisconnect() {
        lock.lock(); disconnectCount += 1; lock.unlock()
    }

    private func recordMicrophone(_ value: Data) {
        lock.lock(); microphone.append(value); lock.unlock()
    }

    private func recordInputLevel(_ value: Float) {
        lock.lock(); inputLevels.append(value); lock.unlock()
    }

    private func recordOutputLevel(_ value: Float) {
        lock.lock(); outputLevels.append(value); lock.unlock()
    }

    private func recordFinished(_ value: AuroraPlaybackKey) {
        lock.lock(); finishedKeys.append(value); lock.unlock()
    }

    private func recordIdle() {
        lock.lock(); idleCount += 1; lock.unlock()
    }

    private func recordError(_ value: AuroraCompanionProtocolError) {
        lock.lock(); protocolErrors.append(value); lock.unlock()
    }
}

private final class LoopbackCompanionClient {
    private let queue = DispatchQueue(label: "aurora.companion.verifier.client")
    private let lock = NSLock()
    private let connection: NWConnection
    private var decoder = AuroraCompanionFrameDecoder()
    private var inbox: [AuroraCompanionEnvelope] = []
    private var ready = false
    private var closed = false
    private var receiveError: Error?
    private var nextSequence: UInt64 = 1

    init(port: NWEndpoint.Port) {
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                setReady()
                receiveNext()
            case .failed(let error):
                setClosed(error: error)
            case .cancelled:
                setClosed(error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func waitUntilReady(timeout: TimeInterval = 2) -> Bool {
        pumpUntil(timeout: timeout) { self.isReady }
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    var lastSentSequence: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return nextSequence - 1
    }

    func send(
        _ type: AuroraCompanionMessageType,
        configure: (inout AuroraCompanionEnvelope) -> Void = { _ in }
    ) throws {
        var envelope = reserveEnvelope(type)
        configure(&envelope)
        try sendRaw(envelope)
    }

    func sendFragmented(
        _ type: AuroraCompanionMessageType,
        splitAt: Int,
        configure: (inout AuroraCompanionEnvelope) -> Void
    ) throws {
        var envelope = reserveEnvelope(type)
        configure(&envelope)
        let data = try AuroraCompanionProtocol.encode(envelope)
        guard splitAt > 0, splitAt < data.count else {
            throw VerificationFailure.failed("invalid verifier frame split")
        }
        sendData(Data(data.prefix(splitAt)))
        sendData(Data(data.dropFirst(splitAt)))
    }

    func sendCoalesced(_ types: [AuroraCompanionMessageType]) throws {
        let data = try types.reduce(into: Data()) { combined, type in
            combined.append(try AuroraCompanionProtocol.encode(reserveEnvelope(type)))
        }
        sendData(data)
    }

    func sendRaw(_ envelope: AuroraCompanionEnvelope) throws {
        let data = try AuroraCompanionProtocol.encode(envelope)
        sendData(data)
    }

    func sendProxyPrefixed(
        _ type: AuroraCompanionMessageType,
        sourceIP: String,
        configure: (inout AuroraCompanionEnvelope) -> Void
    ) throws {
        var envelope = reserveEnvelope(type)
        configure(&envelope)
        var data = Data(
            "PROXY TCP4 \(sourceIP) 127.0.0.1 53124 47821\r\n".utf8
        )
        data.append(try AuroraCompanionProtocol.encode(envelope))
        sendData(data)
    }

    private func reserveEnvelope(
        _ type: AuroraCompanionMessageType
    ) -> AuroraCompanionEnvelope {
        lock.lock()
        let sequence = nextSequence
        nextSequence &+= 1
        lock.unlock()
        return AuroraCompanionEnvelope(type: type, sequence: sequence)
    }

    private func sendData(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.setClosed(error: error) }
        })
    }

    func next(
        _ type: AuroraCompanionMessageType,
        timeout: TimeInterval = 2
    ) -> AuroraCompanionEnvelope? {
        var result: AuroraCompanionEnvelope?
        _ = pumpUntil(timeout: timeout) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let index = self.inbox.firstIndex(where: { $0.type == type }) else {
                return false
            }
            result = self.inbox.remove(at: index)
            return true
        }
        return result
    }

    func finishGracefully() {
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            do {
                if let data, !data.isEmpty {
                    let messages = try decoder.append(data)
                    lock.lock(); inbox.append(contentsOf: messages); lock.unlock()
                }
                if let error { throw error }
                if isComplete {
                    setClosed(error: nil)
                } else {
                    receiveNext()
                }
            } catch {
                setClosed(error: error)
            }
        }
    }

    private func setReady() {
        lock.lock(); ready = true; lock.unlock()
    }

    private func setClosed(error: Error?) {
        lock.lock()
        closed = true
        if let error { receiveError = error }
        lock.unlock()
    }
}

@discardableResult
private func pumpUntil(
    timeout: TimeInterval,
    condition: @escaping () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        _ = RunLoop.current.run(
            mode: .default,
            before: min(deadline, Date().addingTimeInterval(0.01))
        )
    } while Date() < deadline
    return condition()
}

@main
private enum VerifyCompanionServer {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }

        let secret = Data((0..<32).map { UInt8($0 ^ 0xa5) })
        let pairingStore = FakePairingStore(secret: secret)
        let server = AuroraCompanionServer(
            pairingStore: pairingStore,
            listenPort: .any,
            allowDirectLoopback: true
        )
        let probe = ServerProbe()
        probe.bind(to: server)
        server.publishState(.init(
            phase: "listening",
            detail: "Aurora is here",
            audioRoute: "remote",
            sessionOwner: "iphone",
            inputLevel: 0.18,
            outputLevel: 0.07
        ))
        server.start()
        defer { server.stop() }

        try expect(
            pumpUntil(timeout: 2) {
                probe.snapshot().statuses.contains("Ready for iPhone over Tailscale")
                    && server.boundPort != nil
            },
            "the production NWListener never became ready"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("the ready listener had no bound port")
        }
        try expect(port != .any, "the loopback listener did not receive an ephemeral port")

        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "the loopback NWConnection never became ready")

        guard let challenge = client.next(.challenge),
              let serverNonce = challenge.nonce,
              let serverSessionID = challenge.serverSessionID else {
            throw VerificationFailure.failed("the server did not send a complete challenge")
        }
        try expect(!serverNonce.isEmpty, "the challenge omitted its nonce")
        try expect(!serverSessionID.isEmpty, "the challenge omitted its session ID")
        try expect(challenge.sequence == 1, "the server challenge did not start its sequence")

        let deviceID = "aurora-verifier-iphone"
        let pairingNonce = "pairing-client-nonce"
        // Deliberately split the first inbound frame before its four-byte
        // length prefix is complete, proving the real listener's prelude and
        // frame decoder survive TCP fragmentation.
        try client.sendFragmented(.pairRequest, splitAt: 2) { envelope in
            envelope.pairingCode = pairingStore.pairingCode()
            envelope.deviceID = deviceID
            envelope.clientNonce = pairingNonce
        }
        guard let pairAccepted = client.next(.pairAccepted) else {
            throw VerificationFailure.failed("the real server rejected its fake-store pairing code")
        }
        try expect(
            pairAccepted.clientNonce == pairingNonce,
            "pairing did not bind the acceptance to the client nonce"
        )
        try expect(
            pairAccepted.pairingSecret == secret.base64EncodedString(),
            "pairing did not return the fake store's secret"
        )

        let authenticationNonce = "authentication-client-nonce"
        try client.send(.authenticate) { envelope in
            envelope.deviceID = deviceID
            envelope.clientNonce = authenticationNonce
            envelope.proof = AuroraCompanionProtocol.clientProof(
                secret: secret,
                serverNonce: serverNonce,
                clientNonce: authenticationNonce,
                deviceID: deviceID
            )
        }
        guard let authenticated = client.next(.authenticated) else {
            throw VerificationFailure.failed("the real server did not authenticate the client")
        }
        let expectedServerProof = AuroraCompanionProtocol.serverProof(
            secret: secret,
            serverNonce: serverNonce,
            clientNonce: authenticationNonce,
            deviceID: deviceID
        )
        try expect(
            authenticated.proof == expectedServerProof,
            "the client could not mutually authenticate the server's HMAC proof"
        )
        try expect(server.isAuthenticated, "the server did not retain authenticated state")
        guard let initialState = client.next(.state) else {
            throw VerificationFailure.failed("authentication did not deliver mirrored state")
        }
        try expect(initialState.phase == "listening", "mirrored phase was not synchronized")
        try expect(initialState.detail == "Aurora is here", "mirrored detail was not synchronized")
        try expect(initialState.audioRoute == "remote", "mirrored audio route was not synchronized")
        try expect(initialState.sessionOwner == "iphone", "mirrored session owner was not synchronized")
        try expect(initialState.inputLevel == 0.18, "mirrored input level was not synchronized")
        try expect(initialState.outputLevel == 0.07, "mirrored output level was not synchronized")

        // Deliberately place two frames in one TCP write as the inverse case.
        try client.sendCoalesced([.wake, .rest])
        try expect(
            pumpUntil(timeout: 2) {
                let snapshot = probe.snapshot()
                return snapshot.wakeCount == 1 && snapshot.restCount == 1
            },
            "wake/rest callbacks did not cross the real connection"
        )

        // Realtime performs an idempotent audio stop immediately before every
        // fresh socket. Prove that this cleanup cannot consume the phone's
        // pre-start lease, and that a later whole-session stop can be followed
        // by a renewed remote session without reselecting the route in UI code.
        let routableAudio = AuroraRoutableAudio(
            local: AuroraAudioEngine(),
            companionServer: server
        )
        try expect(routableAudio.selectRemote(), "route coordinator rejected the paired iPhone")
        routableAudio.stop()
        try routableAudio.start()
        guard let cleanupSafeStart = client.next(.audioStart),
              cleanupSafeStart.generation?.isEmpty == false else {
            throw VerificationFailure.failed(
                "Realtime's pre-start cleanup consumed the phone audio lease"
            )
        }
        checks += 1
        routableAudio.stop()
        try expect(
            client.next(.audioStop)?.generation == cleanupSafeStart.generation,
            "the first routed session did not close its exact audio generation"
        )

        try routableAudio.start()
        guard let renewedStart = client.next(.audioStart),
              renewedStart.generation?.isEmpty == false else {
            throw VerificationFailure.failed(
                "a subsequent remote session did not renew its released route lease"
            )
        }
        checks += 1
        try expect(
            renewedStart.generation != cleanupSafeStart.generation,
            "the renewed remote session reused a stale audio generation"
        )
        routableAudio.stop()
        try expect(
            client.next(.audioStop)?.generation == renewedStart.generation,
            "the renewed routed session did not close cleanly"
        )
        try expect(routableAudio.selectLocal(), "the route coordinator did not return to the Mac")
        probe.bind(to: server)

        guard let firstRouteLease = server.acquireRemoteRouteLease() else {
            throw VerificationFailure.failed("authenticated client could not acquire a route lease")
        }
        try server.startRemoteAudio(leaseID: firstRouteLease)
        guard let firstAudioStart = client.next(.audioStart),
              let firstGeneration = firstAudioStart.generation else {
            throw VerificationFailure.failed("remote audio did not start")
        }
        try expect(!firstGeneration.isEmpty, "remote audio start omitted its generation")

        // 2,400 PCM16 mono frames are exactly 100 ms at Aurora's 24 kHz rate.
        let firstMicrophonePCM = Data((0..<4_800).map { UInt8($0 & 0xff) })
        try client.send(.microphone) { envelope in
            envelope.generation = firstGeneration
            envelope.audio = firstMicrophonePCM
            envelope.inputLevel = 0.25
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().microphone.count == 1 },
            "24 kHz microphone PCM did not reach the server callback"
        )
        var snapshot = probe.snapshot()
        try expect(snapshot.microphone == [firstMicrophonePCM], "microphone PCM changed in transit")
        try expect(snapshot.inputLevels == [0.25], "microphone level changed in transit")

        server.stopRemoteAudio()
        guard let audioStop = client.next(.audioStop) else {
            throw VerificationFailure.failed("remote audio stop was not sent")
        }
        try expect(
            audioStop.generation == firstGeneration,
            "remote audio stop did not close the active generation"
        )
        try server.startRemoteAudio(leaseID: firstRouteLease)
        guard let secondAudioStart = client.next(.audioStart),
              let secondGeneration = secondAudioStart.generation else {
            throw VerificationFailure.failed("replacement remote audio did not start")
        }
        try expect(
            secondGeneration != firstGeneration,
            "replacement audio reused a stale generation"
        )

        let staleKey = AuroraPlaybackKey(
            responseID: "stale-response",
            itemID: "stale-item",
            contentIndex: 0
        )
        try client.send(.microphone) { envelope in
            envelope.generation = firstGeneration
            envelope.audio = Data(repeating: 0x7f, count: 4_800)
            envelope.inputLevel = 0.99
        }
        try client.send(.playbackProgress) { envelope in
            envelope.generation = firstGeneration
            apply(staleKey, to: &envelope)
            envelope.frameCount = 2_400
        }
        try client.send(.playbackFinished) { envelope in
            envelope.generation = firstGeneration
            apply(staleKey, to: &envelope)
            envelope.frameCount = 2_400
        }
        try client.send(.playbackIdle) { envelope in
            envelope.generation = firstGeneration
        }
        try client.send(.outputLevel) { envelope in
            envelope.generation = firstGeneration
            envelope.outputLevel = 0.99
        }
        // A valid same-stream event is the barrier proving every stale frame
        // ahead of it has already been evaluated on the server queue.
        try client.send(.outputLevel) { envelope in
            envelope.generation = secondGeneration
            envelope.outputLevel = 0.55
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().outputLevels == [0.55] },
            "the valid generation barrier did not arrive"
        )
        snapshot = probe.snapshot()
        try expect(snapshot.microphone.count == 1, "stale-generation microphone audio was accepted")
        try expect(snapshot.finishedKeys.isEmpty, "stale-generation playback completion was accepted")
        try expect(snapshot.idleCount == 0, "stale-generation idle was accepted")

        let secondMicrophonePCM = Data(repeating: 0x31, count: 4_800)
        try client.send(.microphone) { envelope in
            envelope.generation = secondGeneration
            envelope.audio = secondMicrophonePCM
            envelope.inputLevel = 0.70
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().microphone.count == 2 },
            "the current generation microphone path stopped after stale input"
        )
        snapshot = probe.snapshot()
        try expect(snapshot.microphone.last == secondMicrophonePCM, "current microphone PCM changed")
        try expect(snapshot.inputLevels.last == 0.70, "current microphone level changed")

        let completedKey = AuroraPlaybackKey(
            responseID: "response-complete",
            itemID: "item-complete",
            contentIndex: 2
        )
        let playbackA = Data(repeating: 0x12, count: 4_800)
        let playbackB = Data(repeating: 0x34, count: 4_800)
        server.enqueuePlayback(playbackA, for: completedKey)
        server.enqueuePlayback(playbackB, for: completedKey)
        server.markPlaybackItemComplete(completedKey)
        guard let outboundPlaybackA = client.next(.playback),
              let outboundPlaybackB = client.next(.playback),
              let outboundComplete = client.next(.playbackItemComplete) else {
            throw VerificationFailure.failed("keyed playback frames were not delivered")
        }
        let outboundPlayback = [outboundPlaybackA, outboundPlaybackB]
        try expect(
            outboundPlayback.map(\.audio) == [playbackA, playbackB],
            "playback PCM changed or reordered in transit"
        )
        try expect(
            outboundPlayback.allSatisfy {
                $0.generation == secondGeneration && key(from: $0) == completedKey
            },
            "playback lost its generation or exact Realtime key"
        )
        try expect(
            outboundComplete.generation == secondGeneration
                && key(from: outboundComplete) == completedKey,
            "playback completion lost its generation or exact Realtime key"
        )
        let completedFrameCount = Int64((playbackA.count + playbackB.count) / 2)
        try client.send(.playbackProgress) { envelope in
            envelope.generation = secondGeneration
            apply(completedKey, to: &envelope)
            envelope.frameCount = completedFrameCount
        }
        try client.send(.playbackFinished) { envelope in
            envelope.generation = secondGeneration
            apply(completedKey, to: &envelope)
            envelope.frameCount = completedFrameCount
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().finishedKeys == [completedKey] },
            "full keyed playback did not produce exact finished truth"
        )
        try client.send(.playbackIdle) { envelope in
            envelope.generation = secondGeneration
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().idleCount == 1 },
            "playback idle did not cross the connection"
        )

        let interruptedKey = AuroraPlaybackKey(
            responseID: "response-interrupted",
            itemID: "item-interrupted",
            contentIndex: 1
        )
        // 24,000 PCM16 frames are exactly one second at 24 kHz.
        let interruptedPCM = Data(repeating: 0x55, count: 48_000)
        server.enqueuePlayback(interruptedPCM, for: interruptedKey)
        guard let interruptedPlayback = client.next(.playback) else {
            throw VerificationFailure.failed("interruptible playback was not delivered")
        }
        try expect(
            key(from: interruptedPlayback) == interruptedKey,
            "interruptible playback lost its exact key"
        )
        try client.send(.playbackProgress) { envelope in
            envelope.generation = secondGeneration
            apply(interruptedKey, to: &envelope)
            envelope.frameCount = 6_000
        }
        try client.send(.outputLevel) { envelope in
            envelope.generation = secondGeneration
            envelope.outputLevel = 0.33
        }
        try expect(
            pumpUntil(timeout: 2) { probe.snapshot().outputLevels == [0.55, 0.33] },
            "the interruption progress barrier did not arrive"
        )
        let cuts = server.interruptPlayback()
        try expect(
            cuts == [AuroraPlaybackCut(key: interruptedKey, playedMilliseconds: 250)],
            "interruption did not derive its cut from 6,000 heard frames at 24 kHz"
        )
        guard let interrupt = client.next(.playbackInterrupt) else {
            throw VerificationFailure.failed("the phone was not told to cut playback")
        }
        try expect(
            interrupt.generation == secondGeneration,
            "playback interrupt targeted the wrong generation"
        )

        // Reusing the last accepted sequence must drop the authenticated
        // connection before the duplicate command can execute.
        let duplicateSequence = client.lastSentSequence
        try client.sendRaw(AuroraCompanionEnvelope(type: .wake, sequence: duplicateSequence))
        try expect(
            pumpUntil(timeout: 2) {
                let latest = probe.snapshot()
                return latest.protocolErrors.contains(.outOfOrderSequence)
                    && latest.disconnectCount == 1
                    && !server.isAuthenticated
            },
            "duplicate inbound sequence was not rejected and disconnected"
        )
        try expect(
            probe.snapshot().wakeCount == 1,
            "the rejected duplicate sequence executed its wake command"
        )

        // A fresh connection can authenticate with the paired secret, then a
        // graceful network close must tear down active remote audio exactly
        // like a phone leaving Tailscale coverage.
        let reconnect = LoopbackCompanionClient(port: port)
        reconnect.start()
        defer { reconnect.cancel() }
        try expect(reconnect.waitUntilReady(), "a clean reconnect could not reach the server")
        guard let reconnectChallenge = reconnect.next(.challenge),
              let reconnectServerNonce = reconnectChallenge.nonce else {
            throw VerificationFailure.failed("reconnect did not receive a challenge")
        }
        let reconnectNonce = "reconnect-client-nonce"
        try reconnect.send(.authenticate) { envelope in
            envelope.deviceID = deviceID
            envelope.clientNonce = reconnectNonce
            envelope.proof = AuroraCompanionProtocol.clientProof(
                secret: secret,
                serverNonce: reconnectServerNonce,
                clientNonce: reconnectNonce,
                deviceID: deviceID
            )
        }
        guard let reconnectAuthenticated = reconnect.next(.authenticated) else {
            throw VerificationFailure.failed("paired reconnect did not authenticate")
        }
        try expect(
            reconnectAuthenticated.proof == AuroraCompanionProtocol.serverProof(
                secret: secret,
                serverNonce: reconnectServerNonce,
                clientNonce: reconnectNonce,
                deviceID: deviceID
            ),
            "reconnect did not mutually authenticate the server"
        )
        _ = reconnect.next(.state)
        guard let reconnectRouteLease = server.acquireRemoteRouteLease() else {
            throw VerificationFailure.failed("reconnected client could not acquire a route lease")
        }
        try server.startRemoteAudio(leaseID: reconnectRouteLease)
        try expect(reconnect.next(.audioStart) != nil, "reconnected remote audio did not start")
        reconnect.finishGracefully()
        try expect(
            pumpUntil(timeout: 2) {
                probe.snapshot().disconnectCount == 2 && !server.isAuthenticated
            },
            "graceful network disconnect did not tear down active remote audio"
        )
        try expect(pairingStore.secretReadCount > 0, "the injected fake pairing store was unused")

        try verifyLeaseLossBeforeAudioStart(
            server: server,
            port: port,
            secret: secret,
            deviceID: deviceID,
            probe: probe,
            expectedDisconnectCount: 3,
            checks: &checks
        )
        try verifyAuthenticationFailureIsStructured(secret: secret, checks: &checks)
        try verifyTrustedProxyAuthentication(secret: secret, checks: &checks)
        try verifyInvalidProofIsStructured(secret: secret, checks: &checks)
        try verifyInteractivePairingWindow(secret: secret, checks: &checks)
        try verifyPreAuthenticationDeadline(secret: secret, checks: &checks)
        try verifyListenerRebind(secret: secret, checks: &checks)

        print("Aurora companion server verification passed (\(checks) checks).")
    }

    private static func verifyLeaseLossBeforeAudioStart(
        server: AuroraCompanionServer,
        port: NWEndpoint.Port,
        secret: Data,
        deviceID: String,
        probe: ServerProbe,
        expectedDisconnectCount: Int,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "lease-window client could not connect")
        guard let challenge = client.next(.challenge),
              let serverNonce = challenge.nonce else {
            throw VerificationFailure.failed("lease-window client received no challenge")
        }
        let clientNonce = "lease-window-client-nonce"
        try client.send(.authenticate) { envelope in
            envelope.deviceID = deviceID
            envelope.clientNonce = clientNonce
            envelope.proof = AuroraCompanionProtocol.clientProof(
                secret: secret,
                serverNonce: serverNonce,
                clientNonce: clientNonce,
                deviceID: deviceID
            )
        }
        try expect(client.next(.authenticated) != nil, "lease-window client did not authenticate")
        _ = client.next(.state)
        guard let leaseID = server.acquireRemoteRouteLease() else {
            throw VerificationFailure.failed("lease-window route reservation failed")
        }
        client.finishGracefully()
        try expect(
            pumpUntil(timeout: 2) {
                probe.snapshot().disconnectCount == expectedDisconnectCount
                    && !server.isAuthenticated
            },
            "disconnect between route selection and audio start was not route loss"
        )
        do {
            try server.startRemoteAudio(leaseID: leaseID)
            throw VerificationFailure.failed("stale route lease started remote audio")
        } catch AuroraCompanionProtocolError.unavailable {
            checks += 1
        }
    }

    private static func verifyAuthenticationFailureIsStructured(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let server = AuroraCompanionServer(
            pairingStore: FakePairingStore(secret: secret),
            listenPort: .any
        )
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "fail-closed server did not bind"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("fail-closed server had no port")
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "unauthorized loopback could not connect")
        try expect(client.next(.challenge) != nil, "unauthorized loopback received no challenge")
        try client.send(.authenticate) { envelope in
            envelope.deviceID = "untrusted-loopback"
            envelope.clientNonce = "not-authorized"
            envelope.proof = "not-a-proof"
        }
        guard let failure = client.next(.error) else {
            throw VerificationFailure.failed("invalid authentication closed without an error envelope")
        }
        try expect(
            failure.detail == "untrusted_transport",
            "untrusted loopback returned the wrong reason code"
        )
        try expect(
            failure.proof == nil
                && failure.pairingSecret == nil
                && failure.nonce == nil
                && failure.serverSessionID == nil
                && failure.clientNonce == nil
                && failure.deviceID == nil
                && failure.pairingCode == nil,
            "untrusted transport response leaked authentication material"
        )
        try expect(
            pumpUntil(timeout: 2) { client.isClosed },
            "untrusted transport was not closed after its error envelope"
        )
        try expect(!server.isAuthenticated, "invalid loopback became authenticated")
    }

    private static func verifyPreAuthenticationDeadline(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let server = AuroraCompanionServer(
            pairingStore: FakePairingStore(secret: secret),
            listenPort: .any,
            allowDirectLoopback: true,
            preAuthenticationTimeout: 0.1
        )
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "deadline server did not bind"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("deadline server had no port")
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "idle pre-auth client could not connect")
        try expect(client.next(.challenge) != nil, "idle pre-auth client received no challenge")
        guard let failure = client.next(.error, timeout: 2) else {
            throw VerificationFailure.failed("pre-auth deadline sent no structured failure")
        }
        try expect(
            failure.detail == "authentication_timeout",
            "pre-auth deadline returned the wrong reason code"
        )
        try expect(
            failure.detail != "authentication_failed",
            "an idle pairing timeout told iOS to discard valid credentials"
        )
        try expect(
            failure.proof == nil
                && failure.pairingSecret == nil
                && failure.nonce == nil
                && failure.clientNonce == nil,
            "pre-auth timeout leaked authentication material"
        )
        try expect(
            pumpUntil(timeout: 2) { client.isClosed },
            "idle pre-auth connection survived its deadline"
        )
    }

    private static func verifyInteractivePairingWindow(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let pairingStore = FakePairingStore(secret: secret)
        let server = AuroraCompanionServer(
            pairingStore: pairingStore,
            listenPort: .any,
            allowDirectLoopback: true
        )
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "interactive-pairing server did not bind"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("interactive-pairing server had no port")
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "interactive-pairing client could not connect")
        guard let challenge = client.next(.challenge),
              let serverNonce = challenge.nonce else {
            throw VerificationFailure.failed("interactive-pairing client received no challenge")
        }

        // This is deliberately wall-clock time against a real NWListener. It
        // prevents a regression back to the former ten-second machine-only
        // deadline that expired while Alex was still entering the code.
        let closedWithinHumanEntryWindow = pumpUntil(timeout: 10.25) {
            client.isClosed
        }
        try expect(
            !closedWithinHumanEntryWindow && !client.isClosed,
            "pairing socket closed before a human could enter the code"
        )

        let deviceID = "slow-human-pairing-iphone"
        let pairingNonce = "slow-human-pairing-nonce"
        try client.send(.pairRequest) { envelope in
            envelope.pairingCode = pairingStore.pairingCode()
            envelope.deviceID = deviceID
            envelope.clientNonce = pairingNonce
        }
        guard let accepted = client.next(.pairAccepted) else {
            throw VerificationFailure.failed("valid pairing failed after the ten-second mark")
        }
        try expect(
            accepted.pairingSecret == secret.base64EncodedString(),
            "delayed pairing returned the wrong secret"
        )

        let authenticationNonce = "slow-human-authentication-nonce"
        try client.send(.authenticate) { envelope in
            envelope.deviceID = deviceID
            envelope.clientNonce = authenticationNonce
            envelope.proof = AuroraCompanionProtocol.clientProof(
                secret: secret,
                serverNonce: serverNonce,
                clientNonce: authenticationNonce,
                deviceID: deviceID
            )
        }
        try expect(
            client.next(.authenticated) != nil && server.isAuthenticated,
            "delayed human pairing did not complete authentication"
        )
    }

    private static func verifyInvalidProofIsStructured(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let server = AuroraCompanionServer(
            pairingStore: FakePairingStore(secret: secret),
            listenPort: .any,
            allowDirectLoopback: true
        )
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "invalid-proof server did not bind"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("invalid-proof server had no port")
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "invalid-proof client could not connect")
        try expect(client.next(.challenge) != nil, "invalid-proof client received no challenge")
        try client.send(.authenticate) { envelope in
            envelope.deviceID = "paired-device-shape"
            envelope.clientNonce = "invalid-proof-nonce"
            envelope.proof = Data(repeating: 0xff, count: 32).base64EncodedString()
        }
        guard let failure = client.next(.error) else {
            throw VerificationFailure.failed("invalid HMAC proof closed without a structured error")
        }
        try expect(
            failure.detail == "authentication_failed",
            "invalid HMAC proof returned the wrong reason code"
        )
        try expect(
            failure.proof == nil
                && failure.pairingSecret == nil
                && failure.nonce == nil
                && failure.serverSessionID == nil
                && failure.clientNonce == nil
                && failure.deviceID == nil,
            "invalid HMAC proof response leaked authentication material"
        )
        try expect(
            pumpUntil(timeout: 2) { client.isClosed },
            "invalid HMAC proof connection remained open"
        )
    }

    private static func verifyTrustedProxyAuthentication(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let server = AuroraCompanionServer(
            pairingStore: FakePairingStore(secret: secret),
            listenPort: .any
        )
        server.publishState(.init(
            phase: "resting",
            audioRoute: "local",
            sessionOwner: "none"
        ))
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "trusted-proxy server did not bind"
        )
        guard let port = server.boundPort else {
            throw VerificationFailure.failed("trusted-proxy server had no port")
        }
        let client = LoopbackCompanionClient(port: port)
        client.start()
        defer { client.cancel() }
        try expect(client.waitUntilReady(), "trusted-proxy client could not connect")
        guard let challenge = client.next(.challenge),
              let serverNonce = challenge.nonce else {
            throw VerificationFailure.failed("trusted-proxy client received no challenge")
        }
        let deviceID = "trusted-tailscale-iphone"
        let clientNonce = String(repeating: "n", count: 96)
        try client.sendProxyPrefixed(
            .authenticate,
            sourceIP: AuroraCompanionProtocol.allowedTailscalePeerIPv4
        ) { envelope in
            envelope.deviceID = deviceID
            envelope.clientNonce = clientNonce
            envelope.proof = AuroraCompanionProtocol.clientProof(
                secret: secret,
                serverNonce: serverNonce,
                clientNonce: clientNonce,
                deviceID: deviceID
            )
        }
        try expect(
            client.next(.authenticated) != nil,
            "trusted Tailscale PROXY header did not authenticate"
        )
        guard let state = client.next(.state) else {
            throw VerificationFailure.failed("trusted proxy received no mirrored state")
        }
        try expect(
            state.audioRoute == "local" && state.sessionOwner == "none",
            "trusted proxy received incorrect route ownership"
        )
        try expect(server.isAuthenticated, "trusted proxy was not retained as authenticated")
    }

    private static func verifyListenerRebind(
        secret: Data,
        checks: inout Int
    ) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VerificationFailure.failed(message) }
            checks += 1
        }
        let lock = NSLock()
        var attempts = 0
        let server = AuroraCompanionServer(
            pairingStore: FakePairingStore(secret: secret),
            listenPort: .any,
            allowDirectLoopback: true,
            listenerRetryBaseDelay: 0.02,
            listenerRetryMaximumDelay: 0.04,
            listenerFactory: {
                lock.lock()
                attempts += 1
                let attempt = attempts
                lock.unlock()
                if attempt == 1 { throw AuroraCompanionProtocolError.unavailable }
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: "127.0.0.1",
                    port: .any
                )
                return try NWListener(using: parameters)
            }
        )
        server.start()
        defer { server.stop() }
        try expect(
            pumpUntil(timeout: 2) { server.isListening && server.boundPort != nil },
            "listener did not recover from its first bind failure"
        )
        lock.lock()
        let finalAttempts = attempts
        lock.unlock()
        try expect(finalAttempts == 2, "listener retry was not bounded to the required rebind")
    }

    private static func apply(
        _ key: AuroraPlaybackKey,
        to envelope: inout AuroraCompanionEnvelope
    ) {
        envelope.responseID = key.responseID
        envelope.itemID = key.itemID
        envelope.contentIndex = key.contentIndex
    }

    private static func key(from envelope: AuroraCompanionEnvelope) -> AuroraPlaybackKey? {
        guard let responseID = envelope.responseID,
              let itemID = envelope.itemID,
              let contentIndex = envelope.contentIndex else { return nil }
        return AuroraPlaybackKey(
            responseID: responseID,
            itemID: itemID,
            contentIndex: contentIndex
        )
    }
}
