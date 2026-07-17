import Foundation

/// Keeps the existing Mac audio engine intact while allowing the paired
/// iPhone to become the microphone/speaker for a whole Realtime session.
/// Routes never switch mid-session, so playback truth and barge-in cannot be
/// split across two devices.
final class AuroraRoutableAudio: AuroraRealtimeAudio {
    enum Route {
        case local
        case remote
    }

    var onMicrophonePCM: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)?
    var onPlaybackIdle: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onRemoteRouteLost: (() -> Void)?

    private let local: AuroraAudioEngine
    let companionServer: AuroraCompanionServer
    private let lock = NSLock()
    private var route: Route = .local
    private var active = false
    private var remoteLeaseID: UUID?

    init(
        local: AuroraAudioEngine = AuroraAudioEngine(),
        companionServer: AuroraCompanionServer = AuroraCompanionServer()
    ) {
        self.local = local
        self.companionServer = companionServer
        bindLocal()
        bindRemote()
    }

    var isRemoteSelected: Bool {
        lock.withLock { route == .remote }
    }

    var companionAudioRoute: String {
        lock.withLock { route == .remote ? "remote" : "local" }
    }

    @discardableResult
    func selectLocal() -> Bool {
        let result = lock.withLock { () -> (Bool, UUID?) in
            guard !active else { return (route == .local, nil) }
            let releasedLease = remoteLeaseID
            remoteLeaseID = nil
            route = .local
            return (true, releasedLease)
        }
        if let leaseID = result.1 { companionServer.releaseRemoteRouteLease(leaseID) }
        return result.0
    }

    @discardableResult
    func selectRemote() -> Bool {
        let existing = lock.withLock { active ? route == .remote : nil }
        if let existing { return existing }
        guard let leaseID = companionServer.acquireRemoteRouteLease() else { return false }
        let accepted = lock.withLock { () -> Bool in
            guard !active else { return false }
            route = .remote
            remoteLeaseID = leaseID
            return true
        }
        if !accepted { companionServer.releaseRemoteRouteLease(leaseID) }
        return accepted
    }

    func start() throws {
        // Realtime deliberately performs one cleanup pass before each fresh
        // socket. That pass may have ended a previous active remote session,
        // so renew its action-scoped route lease here when needed. The first
        // wake still keeps the lease acquired by selectRemote(), closing the
        // disconnect window between the phone's wake and audio startup.
        if lock.withLock({ route == .remote && remoteLeaseID == nil }) {
            guard let renewedLease = companionServer.acquireRemoteRouteLease() else {
                throw AuroraCompanionProtocolError.unavailable
            }
            let adopted = lock.withLock { () -> Bool in
                guard route == .remote, remoteLeaseID == nil else { return false }
                remoteLeaseID = renewedLease
                return true
            }
            if !adopted {
                companionServer.releaseRemoteRouteLease(renewedLease)
            }
        }
        let selection = lock.withLock { () -> (Route, UUID?) in
            active = true
            return (route, remoteLeaseID)
        }
        do {
            switch selection.0 {
            case .local:
                try local.start()
            case .remote:
                guard let leaseID = selection.1 else {
                    throw AuroraCompanionProtocolError.unavailable
                }
                try companionServer.startRemoteAudio(leaseID: leaseID)
            }
        } catch {
            let lostLease = lock.withLock { () -> UUID? in
                active = false
                guard selection.0 == .remote else { return nil }
                let leaseID = remoteLeaseID
                remoteLeaseID = nil
                return leaseID
            }
            if let lostLease { companionServer.releaseRemoteRouteLease(lostLease) }
            if selection.0 == .remote {
                DispatchQueue.main.async { [weak self] in self?.onRemoteRouteLost?() }
            }
            throw error
        }
    }

    func stop() {
        let selection = lock.withLock { () -> (Route, UUID?, Bool) in
            // Realtime.start() begins with an idempotent stop. If the phone
            // has selected the route but audio has not started yet, that is a
            // cleanup pass—not a cancellation. Preserve the lease until the
            // upcoming start, an explicit selectLocal(), or a disconnect.
            if route == .remote, !active {
                return (route, nil, false)
            }
            active = false
            let leaseID = remoteLeaseID
            remoteLeaseID = nil
            return (route, leaseID, true)
        }
        guard selection.2 else { return }
        switch selection.0 {
        case .local:
            local.stop()
        case .remote:
            companionServer.stopRemoteAudio()
            if let leaseID = selection.1 {
                companionServer.releaseRemoteRouteLease(leaseID)
            }
        }
    }

    func enqueuePlayback(_ pcm16Data: Data, for key: AuroraPlaybackKey) {
        switch currentRoute() {
        case .local:
            local.enqueuePlayback(pcm16Data, for: key)
        case .remote:
            companionServer.enqueuePlayback(pcm16Data, for: key)
        }
    }

    func markPlaybackItemComplete(_ key: AuroraPlaybackKey) {
        switch currentRoute() {
        case .local:
            local.markPlaybackItemComplete(key)
        case .remote:
            companionServer.markPlaybackItemComplete(key)
        }
    }

    func interruptPlayback() -> [AuroraPlaybackCut] {
        switch currentRoute() {
        case .local:
            return local.interruptPlayback()
        case .remote:
            return companionServer.interruptPlayback()
        }
    }

    func publishCompanionState(_ state: AuroraCompanionServer.MirroredState) {
        companionServer.publishState(state)
    }

    private func bindLocal() {
        local.onMicrophonePCM = { [weak self] data in
            guard let self, self.shouldForward(.local) else { return }
            self.onMicrophonePCM?(data)
        }
        local.onInputLevel = { [weak self] level in
            guard let self, self.shouldForward(.local) else { return }
            self.onInputLevel?(level)
        }
        local.onOutputLevel = { [weak self] level in
            guard let self, self.shouldForward(.local) else { return }
            self.onOutputLevel?(level)
        }
        local.onPlaybackItemFinished = { [weak self] key in
            guard let self, self.shouldForward(.local) else { return }
            self.onPlaybackItemFinished?(key)
        }
        local.onPlaybackIdle = { [weak self] in
            guard let self, self.shouldForward(.local) else { return }
            self.onPlaybackIdle?()
        }
        local.onError = { [weak self] error in
            guard let self, self.shouldForward(.local) else { return }
            self.onError?(error)
        }
    }

    private func bindRemote() {
        companionServer.onMicrophonePCM = { [weak self] data in
            guard let self, self.shouldForward(.remote) else { return }
            self.onMicrophonePCM?(data)
        }
        companionServer.onInputLevel = { [weak self] level in
            guard let self, self.shouldForward(.remote) else { return }
            self.onInputLevel?(level)
        }
        companionServer.onOutputLevel = { [weak self] level in
            guard let self, self.shouldForward(.remote) else { return }
            self.onOutputLevel?(level)
        }
        companionServer.onPlaybackItemFinished = { [weak self] key in
            guard let self, self.shouldForward(.remote) else { return }
            self.onPlaybackItemFinished?(key)
        }
        companionServer.onPlaybackIdle = { [weak self] in
            guard let self, self.shouldForward(.remote) else { return }
            self.onPlaybackIdle?()
        }
        companionServer.onError = { [weak self] error in
            guard let self, self.shouldForward(.remote) else { return }
            self.onError?(error)
        }
        companionServer.onRemoteDisconnected = { [weak self] in
            guard let self else { return }
            let routeWasOwned = self.lock.withLock { () -> Bool in
                guard self.route == .remote,
                      self.active || self.remoteLeaseID != nil else { return false }
                self.active = false
                self.remoteLeaseID = nil
                return true
            }
            guard routeWasOwned else { return }
            self.onRemoteRouteLost?()
        }
    }

    private func currentRoute() -> Route {
        lock.withLock { route }
    }

    private func shouldForward(_ expected: Route) -> Bool {
        lock.withLock { active && route == expected }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
