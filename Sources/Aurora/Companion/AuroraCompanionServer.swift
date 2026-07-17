import Foundation
import Network

final class AuroraCompanionServer {
    struct MirroredState: Equatable {
        var phase = "resting"
        var detail: String?
        var audioRoute = "local"
        var sessionOwner = "none"
        var inputLevel: Float = 0
        var outputLevel: Float = 0
    }

    var onWakeRequested: (() -> Void)?
    var onRestRequested: (() -> Void)?
    var onRemoteDisconnected: (() -> Void)?
    var onMicrophonePCM: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)?
    var onPlaybackIdle: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private final class Client {
        let connection: NWConnection
        var decoder = AuroraCompanionFrameDecoder()
        var prelude = Data()
        var preludeResolved = false
        var sourceIPv4: String?
        var authenticated = false
        var serverNonce = AuroraCompanionProtocol.randomData(count: 24).base64EncodedString()
        var serverSessionID = UUID().uuidString.lowercased()
        var deviceID: String?
        var lastInboundSequence: UInt64 = 0
        var nextOutboundSequence: UInt64 = 1
        var pendingOutboundBytes = 0
        var pairingAttempts = 0
        var lastPongAt = Date()
        var preAuthenticationDeadline: DispatchWorkItem?
        var closing = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "aurora.companion.server")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let pairingStore: AuroraCompanionPairingStoring
    private let listenHost: NWEndpoint.Host
    private let listenPort: NWEndpoint.Port
    private let allowDirectLoopback: Bool
    private let preAuthenticationTimeout: TimeInterval
    private let listenerRetryBaseDelay: TimeInterval
    private let listenerRetryMaximumDelay: TimeInterval
    private let listenerFactory: (() throws -> NWListener)?
    private var listener: NWListener?
    private var listenerReady = false
    private var listenerRetry: DispatchWorkItem?
    private var listenerRetryAttempt = 0
    private var client: Client?
    private var heartbeat: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var mirroredState = MirroredState()
    private var stateSendScheduled = false
    private var activeAudioGeneration: String?
    private var sentFrames: [AuroraPlaybackKey: Int64] = [:]
    private var acknowledgedFrames: [AuroraPlaybackKey: Int64] = [:]
    private var endedItems = Set<AuroraPlaybackKey>()
    private var playbackOrder: [AuroraPlaybackKey] = []
    private struct RemoteRouteLease {
        let id: UUID
        let serverSessionID: String
    }
    private var remoteRouteLease: RemoteRouteLease?
    private var running = false

    init(
        pairingStore: AuroraCompanionPairingStoring = AuroraCompanionPairingStore(),
        listenHost: NWEndpoint.Host = "127.0.0.1",
        listenPort: NWEndpoint.Port = NWEndpoint.Port(
            rawValue: AuroraCompanionProtocol.port
        )!,
        allowDirectLoopback: Bool = false,
        preAuthenticationTimeout: TimeInterval = AuroraCompanionProtocol
            .interactiveAuthenticationTimeoutSeconds,
        listenerRetryBaseDelay: TimeInterval = 0.5,
        listenerRetryMaximumDelay: TimeInterval = 8,
        listenerFactory: (() throws -> NWListener)? = nil
    ) {
        self.pairingStore = pairingStore
        self.listenHost = listenHost
        self.listenPort = listenPort
        #if DEBUG
        let debugLoopbackAllowance = ProcessInfo.processInfo.environment[
            "AURORA_ALLOW_DIRECT_COMPANION_LOOPBACK"
        ] == "1"
        #else
        let debugLoopbackAllowance = false
        #endif
        self.allowDirectLoopback = allowDirectLoopback || debugLoopbackAllowance
        self.preAuthenticationTimeout = max(0.1, preAuthenticationTimeout)
        let boundedRetryBase = max(0.01, listenerRetryBaseDelay)
        self.listenerRetryBaseDelay = boundedRetryBase
        self.listenerRetryMaximumDelay = max(
            boundedRetryBase,
            listenerRetryMaximumDelay
        )
        self.listenerFactory = listenerFactory
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    var pairingCode: String {
        pairingStore.pairingCode()
    }

    var isAuthenticated: Bool {
        syncOnQueue { client?.authenticated == true }
    }

    /// The actual listener port. Passing `.any` at construction keeps the
    /// loopback verifier isolated from a running copy of Aurora.
    var boundPort: NWEndpoint.Port? {
        syncOnQueue { listener?.port }
    }

    var isListening: Bool {
        syncOnQueue { listenerReady }
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        syncOnQueue {
            guard running else { return }
            running = false
            listenerRetry?.cancel()
            listenerRetry = nil
            listenerRetryAttempt = 0
            heartbeat?.cancel()
            heartbeat = nil
            client?.preAuthenticationDeadline?.cancel()
            client?.connection.cancel()
            client = nil
            listener?.cancel()
            listener = nil
            listenerReady = false
            remoteRouteLease = nil
            clearPlaybackLocked()
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }

    func publishState(_ state: MirroredState) {
        queue.async { [weak self] in
            guard let self else { return }
            mirroredState = state
            guard !stateSendScheduled else { return }
            stateSendScheduled = true
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                stateSendScheduled = false
                sendStateLocked()
            }
        }
    }

    /// Reserves the currently authenticated client before AppModel crosses
    /// its wake boundary. The lease closes the selectRemote -> audio.start
    /// race: a disconnect in that window is still a route-loss event.
    func acquireRemoteRouteLease() -> UUID? {
        syncOnQueue {
            guard let client,
                  client.authenticated,
                  !client.closing else { return nil }
            if let remoteRouteLease,
               remoteRouteLease.serverSessionID == client.serverSessionID {
                return remoteRouteLease.id
            }
            let lease = RemoteRouteLease(
                id: UUID(),
                serverSessionID: client.serverSessionID
            )
            remoteRouteLease = lease
            return lease.id
        }
    }

    func releaseRemoteRouteLease(_ leaseID: UUID) {
        syncOnQueue {
            guard remoteRouteLease?.id == leaseID else { return }
            remoteRouteLease = nil
        }
    }

    func startRemoteAudio(leaseID: UUID) throws {
        try syncOnQueue {
            guard let client,
                  client.authenticated,
                  !client.closing,
                  remoteRouteLease?.id == leaseID,
                  remoteRouteLease?.serverSessionID == client.serverSessionID else {
                throw AuroraCompanionProtocolError.unavailable
            }
            let generation = UUID().uuidString.lowercased()
            activeAudioGeneration = generation
            clearPlaybackLocked(keepGeneration: true)
            var envelope = makeEnvelope(.audioStart)
            envelope.generation = generation
            try sendLocked(envelope)
        }
    }

    func stopRemoteAudio() {
        syncOnQueue {
            if activeAudioGeneration != nil,
               client?.authenticated == true {
                var envelope = makeEnvelope(.audioStop)
                envelope.generation = activeAudioGeneration
                try? sendLocked(envelope)
            }
            activeAudioGeneration = nil
            clearPlaybackLocked()
        }
    }

    func enqueuePlayback(_ data: Data, for key: AuroraPlaybackKey) {
        queue.async { [weak self] in
            guard let self,
                  let generation = activeAudioGeneration,
                  client?.authenticated == true,
                  !data.isEmpty,
                  data.count <= AuroraCompanionProtocol.maximumAudioBytes else { return }
            let frames = Int64(data.count / MemoryLayout<Int16>.size)
            guard frames > 0 else { return }
            if sentFrames[key] == nil { playbackOrder.append(key) }
            sentFrames[key, default: 0] += frames
            var envelope = makeEnvelope(.playback)
            envelope.generation = generation
            envelope.audio = data
            apply(key, to: &envelope)
            do {
                try sendLocked(envelope)
            } catch {
                failClientLocked(error)
            }
        }
    }

    func markPlaybackItemComplete(_ key: AuroraPlaybackKey) {
        queue.async { [weak self] in
            guard let self,
                  let generation = activeAudioGeneration,
                  client?.authenticated == true else { return }
            if sentFrames[key] == nil {
                sentFrames[key] = 0
                playbackOrder.append(key)
            }
            endedItems.insert(key)
            var envelope = makeEnvelope(.playbackItemComplete)
            envelope.generation = generation
            apply(key, to: &envelope)
            do {
                try sendLocked(envelope)
            } catch {
                failClientLocked(error)
            }
        }
    }

    func interruptPlayback() -> [AuroraPlaybackCut] {
        syncOnQueue {
            guard activeAudioGeneration != nil else { return [] }
            let cuts = playbackOrder.compactMap { key -> AuroraPlaybackCut? in
                guard sentFrames[key] != nil else { return nil }
                let heardFrames = max(0, acknowledgedFrames[key] ?? 0)
                return AuroraPlaybackCut(
                    key: key,
                    playedMilliseconds: Int((heardFrames * 1_000) / 24_000)
                )
            }
            if client?.authenticated == true {
                var envelope = makeEnvelope(.playbackInterrupt)
                envelope.generation = activeAudioGeneration
                try? sendLocked(envelope)
            }
            clearPlaybackLocked(keepGeneration: true)
            return cuts
        }
    }

    private func startLocked() {
        guard !running else { return }
        do {
            _ = try pairingStore.secret()
            running = true
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Keep Aurora reachable from her paired iPhone"
            )
            startHeartbeatLocked()
            startListenerLocked()
        } catch {
            running = false
            publishStatus("iPhone connection unavailable")
            onError?(error)
        }
    }

    private func startListenerLocked() {
        guard running, listener == nil, listenerRetry == nil else { return }
        do {
            let listener = try makeListenerLocked()
            self.listener = listener
            listenerReady = false
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.acceptLocked(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    listenerReady = true
                    listenerRetryAttempt = 0
                    publishStatus("Ready for iPhone over Tailscale")
                case .failed(let error):
                    handleListenerFailureLocked(listener, error: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            scheduleListenerRebindLocked(after: error)
        }
    }

    private func makeListenerLocked() throws -> NWListener {
        if let listenerFactory { return try listenerFactory() }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: listenHost,
            port: listenPort
        )
        return try NWListener(using: parameters)
    }

    private func handleListenerFailureLocked(_ failedListener: NWListener, error: Error) {
        guard listener === failedListener else { return }
        failedListener.cancel()
        listener = nil
        listenerReady = false
        scheduleListenerRebindLocked(after: error)
    }

    private func scheduleListenerRebindLocked(after error: Error) {
        guard running, listenerRetry == nil else { return }
        listener?.cancel()
        listener = nil
        listenerReady = false
        publishStatus("Restoring iPhone connection…")
        // A failed listener does not invalidate an already-authenticated audio
        // connection. Report the bind error only while no phone owns the route.
        if client?.authenticated != true { onError?(error) }

        let exponent = min(listenerRetryAttempt, 8)
        let delay = min(
            listenerRetryMaximumDelay,
            listenerRetryBaseDelay * pow(2, Double(exponent))
        )
        listenerRetryAttempt = min(listenerRetryAttempt + 1, 8)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            listenerRetry = nil
            startListenerLocked()
        }
        listenerRetry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func acceptLocked(_ connection: NWConnection) {
        guard running, client == nil else {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        self.client = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client, self.client === client else { return }
            switch state {
            case .ready:
                var challenge = makeEnvelope(.challenge)
                challenge.nonce = client.serverNonce
                challenge.serverSessionID = client.serverSessionID
                do {
                    try sendLocked(challenge)
                    armPreAuthenticationDeadlineLocked(client)
                    receiveNextLocked(client)
                } catch {
                    failClientLocked(error)
                }
            case .failed(let error):
                failClientLocked(error)
            case .cancelled:
                dropClientLocked(client, reportDisconnect: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNextLocked(_ client: Client) {
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak client] data, _, isComplete, error in
            guard let self,
                  let client,
                  self.client === client,
                  !client.closing else { return }
            do {
                if let data, !data.isEmpty {
                    try consumeIncomingLocked(data, from: client)
                }
                if let error { throw error }
                if isComplete {
                    dropClientLocked(client, reportDisconnect: true)
                    return
                }
                receiveNextLocked(client)
            } catch let protocolError as AuroraCompanionProtocolError
                where !client.authenticated {
                switch protocolError {
                case .authenticationFailed:
                    closePreAuthenticationLocked(
                        client,
                        detail: "authentication_failed",
                        error: protocolError
                    )
                case .untrustedTransport:
                    closePreAuthenticationLocked(
                        client,
                        detail: "untrusted_transport",
                        error: protocolError
                    )
                case .authenticationProtocol:
                    closePreAuthenticationLocked(
                        client,
                        detail: "authentication_protocol_error",
                        error: protocolError
                    )
                default:
                    failClientLocked(protocolError)
                }
            } catch {
                failClientLocked(error)
            }
        }
    }

    private func consumeIncomingLocked(_ data: Data, from client: Client) throws {
        var framed = data
        if !client.preludeResolved {
            client.prelude.append(data)
            guard client.prelude.count >= 4 else { return }
            let prefix = String(data: client.prelude.prefix(4), encoding: .utf8)
            if prefix == "PROX" {
                guard let end = client.prelude.range(of: Data([13, 10])) else {
                    guard client.prelude.count <= 220 else {
                        throw AuroraCompanionProtocolError.untrustedTransport
                    }
                    return
                }
                guard end.lowerBound <= 220 else {
                    throw AuroraCompanionProtocolError.untrustedTransport
                }
                let header = String(
                    data: client.prelude[..<end.lowerBound],
                    encoding: .utf8
                ) ?? ""
                let fields = header.split(separator: " ")
                let sourceIP = fields.count >= 3 ? String(fields[2]) : ""
                let allowedSource = AuroraCompanionProtocol
                    .allowedTailscalePeerAddresses
                    .contains(sourceIP)
                guard fields.count >= 6,
                      fields[0] == "PROXY",
                      (fields[1] == "TCP4" || fields[1] == "TCP6"),
                      allowedSource else {
                    throw AuroraCompanionProtocolError.untrustedTransport
                }
                client.sourceIPv4 = String(fields[2])
                let remainingStart = end.upperBound
                framed = remainingStart < client.prelude.endIndex
                    ? Data(client.prelude[remainingStart...])
                    : Data()
                client.prelude.removeAll(keepingCapacity: false)
                client.preludeResolved = true
            } else {
                // Production fails closed: every phone connection must arrive
                // through the Tailscale TCP proxy and its authenticated source
                // header. Tests (and opt-in debug simulator runs) inject an
                // explicit direct-loopback allowance.
                guard allowDirectLoopback else {
                    throw AuroraCompanionProtocolError.untrustedTransport
                }
                framed = client.prelude
                client.prelude.removeAll(keepingCapacity: false)
                client.preludeResolved = true
                client.sourceIPv4 = "127.0.0.1"
            }
        }
        guard !framed.isEmpty else { return }
        for envelope in try client.decoder.append(framed) {
            guard self.client === client, !client.closing else { break }
            guard envelope.sequence > client.lastInboundSequence else {
                throw AuroraCompanionProtocolError.outOfOrderSequence
            }
            client.lastInboundSequence = envelope.sequence
            try handleLocked(envelope, from: client)
        }
    }

    private func handleLocked(_ envelope: AuroraCompanionEnvelope, from client: Client) throws {
        if !client.authenticated {
            switch envelope.type {
            case .pairRequest:
                try handlePairRequestLocked(envelope, from: client)
            case .authenticate:
                try handleAuthenticationLocked(envelope, from: client)
            case .pong:
                client.lastPongAt = Date()
            default:
                throw AuroraCompanionProtocolError.authenticationProtocol
            }
            return
        }

        switch envelope.type {
        case .wake:
            DispatchQueue.main.async { [weak self] in self?.onWakeRequested?() }
        case .rest:
            DispatchQueue.main.async { [weak self] in self?.onRestRequested?() }
        case .microphone:
            try handleMicrophoneLocked(envelope)
        case .playbackProgress:
            try handlePlaybackProgressLocked(envelope)
        case .playbackFinished:
            try handlePlaybackFinishedLocked(envelope)
        case .playbackIdle:
            guard envelope.generation == activeAudioGeneration else { return }
            onPlaybackIdle?()
        case .outputLevel:
            guard envelope.generation == activeAudioGeneration else { return }
            onOutputLevel?(Self.boundedLevel(envelope.outputLevel))
        case .ping:
            var pong = makeEnvelope(.pong)
            pong.generation = activeAudioGeneration
            try sendLocked(pong)
        case .pong:
            client.lastPongAt = Date()
        case .error:
            // An authenticated phone only reports this when its audio route is
            // no longer usable. Treat that as route loss, not a conversational
            // error that can leave AppModel awake without a microphone.
            failClientLocked(AuroraCompanionProtocolError.connectionLost)
        default:
            throw AuroraCompanionProtocolError.malformedFrame
        }
    }

    private func handlePairRequestLocked(
        _ envelope: AuroraCompanionEnvelope,
        from client: Client
    ) throws {
        client.pairingAttempts += 1
        guard client.pairingAttempts <= 5,
              let code = envelope.pairingCode,
              let deviceID = envelope.deviceID,
              !deviceID.isEmpty,
              deviceID.count <= 128,
              let clientNonce = envelope.clientNonce,
              clientNonce.count <= 128 else {
            throw AuroraCompanionProtocolError.pairingFailed
        }
        let secret = try pairingStore.secret()
        guard AuroraCompanionProtocol.acceptsPairingCode(code, secret: secret) else {
            var failure = makeEnvelope(.error)
            failure.detail = "pairing_failed"
            try sendLocked(failure)
            return
        }
        client.deviceID = deviceID
        var accepted = makeEnvelope(.pairAccepted)
        accepted.clientNonce = clientNonce
        accepted.pairingSecret = secret.base64EncodedString()
        try sendLocked(accepted)
    }

    private func handleAuthenticationLocked(
        _ envelope: AuroraCompanionEnvelope,
        from client: Client
    ) throws {
        guard let deviceID = envelope.deviceID,
              !deviceID.isEmpty,
              deviceID.count <= 128,
              let clientNonce = envelope.clientNonce,
              clientNonce.count <= 128,
              let proof = envelope.proof else {
            throw AuroraCompanionProtocolError.authenticationFailed
        }
        let secret = try pairingStore.secret()
        let expected = AuroraCompanionProtocol.clientProof(
            secret: secret,
            serverNonce: client.serverNonce,
            clientNonce: clientNonce,
            deviceID: deviceID
        )
        guard AuroraCompanionProtocol.constantTimeEqual(proof, expected) else {
            throw AuroraCompanionProtocolError.authenticationFailed
        }
        client.deviceID = deviceID
        client.authenticated = true
        client.preAuthenticationDeadline?.cancel()
        client.preAuthenticationDeadline = nil
        client.lastPongAt = Date()
        var response = makeEnvelope(.authenticated)
        response.proof = AuroraCompanionProtocol.serverProof(
            secret: secret,
            serverNonce: client.serverNonce,
            clientNonce: clientNonce,
            deviceID: deviceID
        )
        try sendLocked(response)
        sendStateLocked()
        publishStatus("iPhone connected")
    }

    private func handleMicrophoneLocked(_ envelope: AuroraCompanionEnvelope) throws {
        guard let generation = activeAudioGeneration,
              envelope.generation == generation,
              let audio = envelope.audio,
              !audio.isEmpty,
              audio.count <= AuroraCompanionProtocol.maximumAudioBytes else { return }
        onInputLevel?(Self.boundedLevel(envelope.inputLevel))
        onMicrophonePCM?(audio)
    }

    private func handlePlaybackProgressLocked(_ envelope: AuroraCompanionEnvelope) throws {
        guard envelope.generation == activeAudioGeneration,
              let key = playbackKey(from: envelope),
              let frames = envelope.frameCount,
              frames >= 0,
              let sent = sentFrames[key],
              frames <= sent else { return }
        acknowledgedFrames[key] = max(acknowledgedFrames[key] ?? 0, frames)
    }

    private func handlePlaybackFinishedLocked(_ envelope: AuroraCompanionEnvelope) throws {
        guard envelope.generation == activeAudioGeneration,
              let key = playbackKey(from: envelope),
              endedItems.contains(key),
              let sent = sentFrames[key] else { return }
        let heard = max(acknowledgedFrames[key] ?? 0, envelope.frameCount ?? 0)
        guard heard == sent else { return }
        acknowledgedFrames[key] = heard
        sentFrames.removeValue(forKey: key)
        acknowledgedFrames.removeValue(forKey: key)
        endedItems.remove(key)
        playbackOrder.removeAll { $0 == key }
        onPlaybackItemFinished?(key)
    }

    private func sendStateLocked() {
        guard client?.authenticated == true else { return }
        var envelope = makeEnvelope(.state)
        envelope.phase = mirroredState.phase
        envelope.detail = mirroredState.detail
        envelope.audioRoute = mirroredState.audioRoute
        envelope.sessionOwner = mirroredState.sessionOwner
        envelope.inputLevel = mirroredState.inputLevel
        envelope.outputLevel = mirroredState.outputLevel
        try? sendLocked(envelope)
    }

    private func makeEnvelope(_ type: AuroraCompanionMessageType) -> AuroraCompanionEnvelope {
        let sequence = client?.nextOutboundSequence ?? 1
        client?.nextOutboundSequence &+= 1
        return AuroraCompanionEnvelope(type: type, sequence: sequence)
    }

    private func sendLocked(_ envelope: AuroraCompanionEnvelope) throws {
        guard let client else { throw AuroraCompanionProtocolError.unavailable }
        let data = try AuroraCompanionProtocol.encode(envelope)
        guard client.pendingOutboundBytes + data.count <= 2 * 1_024 * 1_024 else {
            throw AuroraCompanionProtocolError.frameTooLarge
        }
        client.pendingOutboundBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            self.queue.async {
                guard self.client === client else { return }
                client.pendingOutboundBytes = max(0, client.pendingOutboundBytes - data.count)
                if let error { self.failClientLocked(error) }
            }
        })
    }

    private func startHeartbeatLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, let client else { return }
            if client.authenticated,
               Date().timeIntervalSince(client.lastPongAt) > 35 {
                failClientLocked(AuroraCompanionProtocolError.connectionLost)
                return
            }
            if client.authenticated {
                try? sendLocked(makeEnvelope(.ping))
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func armPreAuthenticationDeadlineLocked(_ client: Client) {
        client.preAuthenticationDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak client] in
            guard let self,
                  let client,
                  self.client === client,
                  !client.authenticated,
                  !client.closing else { return }
            closePreAuthenticationLocked(
                client,
                detail: "authentication_timeout",
                error: AuroraCompanionProtocolError.authenticationTimeout
            )
        }
        client.preAuthenticationDeadline = deadline
        queue.asyncAfter(
            deadline: .now() + preAuthenticationTimeout,
            execute: deadline
        )
    }

    /// Pre-authentication failures are wire-visible and machine-readable, but
    /// deliberately contain no nonce, proof, device identifier, or secret.
    /// Only an actually received invalid authenticate message uses
    /// `authentication_failed`; an idle human pairing window uses
    /// `authentication_timeout` so the phone never discards a valid secret.
    private func closePreAuthenticationLocked(
        _ rejectedClient: Client,
        detail: String,
        error: AuroraCompanionProtocolError
    ) {
        guard client === rejectedClient, !rejectedClient.closing else { return }
        rejectedClient.closing = true
        rejectedClient.preAuthenticationDeadline?.cancel()
        rejectedClient.preAuthenticationDeadline = nil

        var failure = makeEnvelope(.error)
        failure.detail = detail
        let data: Data
        do {
            data = try AuroraCompanionProtocol.encode(failure)
        } catch {
            failClientLocked(error)
            return
        }
        rejectedClient.pendingOutboundBytes += data.count
        rejectedClient.connection.send(
            content: data,
            completion: .contentProcessed { [weak self, weak rejectedClient] sendError in
                guard let self, let rejectedClient else { return }
                self.queue.async {
                    guard self.client === rejectedClient else { return }
                    rejectedClient.pendingOutboundBytes = max(
                        0,
                        rejectedClient.pendingOutboundBytes - data.count
                    )
                    self.onError?(sendError ?? error)
                    self.dropClientLocked(rejectedClient, reportDisconnect: false)
                }
            }
        )
    }

    private func failClientLocked(_ error: Error) {
        onError?(error)
        if let client { dropClientLocked(client, reportDisconnect: true) }
    }

    private func dropClientLocked(_ client: Client, reportDisconnect: Bool) {
        guard self.client === client else { return }
        let wasAuthenticated = client.authenticated
        let hadActiveAudio = activeAudioGeneration != nil
        let heldRouteLease = remoteRouteLease?.serverSessionID == client.serverSessionID
        client.preAuthenticationDeadline?.cancel()
        client.preAuthenticationDeadline = nil
        client.connection.cancel()
        self.client = nil
        if heldRouteLease { remoteRouteLease = nil }
        activeAudioGeneration = nil
        clearPlaybackLocked()
        publishStatus(
            listenerReady
                ? "Ready for iPhone over Tailscale"
                : "Restoring iPhone connection…"
        )
        if reportDisconnect, wasAuthenticated, (hadActiveAudio || heldRouteLease) {
            DispatchQueue.main.async { [weak self] in self?.onRemoteDisconnected?() }
        }
    }

    private func clearPlaybackLocked(keepGeneration: Bool = false) {
        sentFrames.removeAll()
        acknowledgedFrames.removeAll()
        endedItems.removeAll()
        playbackOrder.removeAll()
        if !keepGeneration { activeAudioGeneration = nil }
    }

    private func publishStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChanged?(status) }
    }

    private func apply(_ key: AuroraPlaybackKey, to envelope: inout AuroraCompanionEnvelope) {
        envelope.responseID = key.responseID
        envelope.itemID = key.itemID
        envelope.contentIndex = key.contentIndex
    }

    private func playbackKey(from envelope: AuroraCompanionEnvelope) -> AuroraPlaybackKey? {
        guard let responseID = envelope.responseID,
              let itemID = envelope.itemID,
              let contentIndex = envelope.contentIndex else { return nil }
        return AuroraPlaybackKey(
            responseID: responseID,
            itemID: itemID,
            contentIndex: contentIndex
        )
    }

    private static func boundedLevel(_ value: Float?) -> Float {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func syncOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
