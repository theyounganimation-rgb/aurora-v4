import AVFoundation
import Foundation

enum AuroraAudioEngineError: LocalizedError {
    case microphoneUnavailable
    case unsupportedInputFormat
    case converterUnavailable
    case bufferAllocationFailed
    case voiceProcessingUnavailable(Error?)
    case audioRouteChanged
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "No microphone is available."
        case .unsupportedInputFormat:
            return "The selected microphone does not expose a usable audio format."
        case .converterUnavailable:
            return "Aurora could not create the 24 kHz voice converter."
        case .bufferAllocationFailed:
            return "Aurora could not allocate an audio buffer."
        case .voiceProcessingUnavailable(let error):
            let detail = error.map { " (\($0.localizedDescription))" } ?? ""
            return "The current audio device cannot safely suppress speaker echo\(detail). Choose the Mac microphone and speakers, then try again."
        case .audioRouteChanged:
            return "The microphone or speaker changed. Aurora is reopening the voice path."
        case .engineStartFailed(let error):
            return "Aurora could not start audio: \(error.localizedDescription)"
        }
    }
}

struct AuroraPlaybackKey: Hashable, Sendable {
    let responseID: String
    let itemID: String
    let contentIndex: Int
}

struct AuroraPlaybackCut: Sendable, Equatable {
    let key: AuroraPlaybackKey
    /// Milliseconds heard from this particular assistant item.
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

/// Owns Aurora's full-duplex macOS audio path.
///
/// Microphone audio is converted to little-endian PCM16 at 24 kHz mono. Output
/// buffers retain their Realtime item identity all the way to the output
/// device, so an interruption truncates what the owner was actually hearing rather
/// than whichever network item most recently arrived.
final class AuroraAudioEngine: AuroraRealtimeAudio {
    static let sampleRate: Double = 24_000
    static let channelCount: AVAudioChannelCount = 1

    var onMicrophonePCM: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackItemFinished: ((AuroraPlaybackKey) -> Void)?
    var onPlaybackIdle: (() -> Void)?
    var onError: ((Error) -> Void)?

    private struct PlaybackSegment {
        let id: UUID
        let key: AuroraPlaybackKey
        let startFrame: Int64
        let frameCount: Int64

        var endFrame: Int64 { startFrame + frameCount }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackQueue = DispatchQueue(label: "aurora.audio.playback")
    private let stateLock = NSLock()
    private let notificationCenter: NotificationCenter

    private let realtimeFormat: AVAudioFormat
    private var inputConverter: AVAudioConverter?
    private var inputTapInstalled = false
    private var running = false
    private var configurationObserver: NSObjectProtocol?

    // All fields below are owned by playbackQueue.
    private var playbackGeneration: UInt64 = 0
    private var pendingSegments: [PlaybackSegment] = []
    private var endedItems = Set<AuroraPlaybackKey>()
    private var completedFrames: [AuroraPlaybackKey: Int64] = [:]
    private var nextTimelineFrame: Int64 = 0

    init(notificationCenter: NotificationCenter = .default) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: true
        ) else {
            preconditionFailure("PCM16 24 kHz mono must be supported on macOS")
        }

        self.notificationCenter = notificationCenter
        self.realtimeFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    deinit {
        stop()
    }

    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func start() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let input = engine.inputNode
        do {
            if !input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(true)
            }
        } catch {
            throw AuroraAudioEngineError.voiceProcessingUnavailable(error)
        }
        guard input.isVoiceProcessingEnabled else {
            throw AuroraAudioEngineError.voiceProcessingUnavailable(nil)
        }

        // A tap reads the input node's output bus. Using inputFormat here can
        // yield silent or incompatible buffers after voice processing changes
        // the engine graph even though the engine itself reports as running.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AuroraAudioEngineError.microphoneUnavailable
        }
        guard let converter = Self.makeInputConverter(from: inputFormat, to: realtimeFormat) else {
            throw AuroraAudioEngineError.converterUnavailable
        }

        stateLock.lock()
        inputConverter = converter
        // The tap may deliver its first processed buffer synchronously while
        // AVAudioEngine.start() is still returning. Mark capture live before
        // that boundary so the beginning of the stream is not discarded.
        running = true
        stateLock.unlock()

        let tapFrames = AVAudioFrameCount(max(256, inputFormat.sampleRate * 0.02))
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] buffer, _ in
            self?.consumeMicrophoneBuffer(buffer)
        }
        inputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
            stateLock.lock()
            running = false
            inputConverter = nil
            stateLock.unlock()
            throw AuroraAudioEngineError.engineStartFailed(error)
        }
        installConfigurationObserver()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()

        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        playbackQueue.sync {
            playbackGeneration &+= 1
            pendingSegments.removeAll()
            endedItems.removeAll()
            completedFrames.removeAll()
            nextTimelineFrame = 0
            player.stop()
            player.reset()
        }

        if wasRunning || engine.isRunning {
            engine.stop()
        }
        engine.reset()
        stateLock.lock()
        inputConverter = nil
        stateLock.unlock()
        onInputLevel?(0)
        onOutputLevel?(0)
    }

    func enqueuePlayback(_ pcm16Data: Data, for key: AuroraPlaybackKey) {
        let usableByteCount = pcm16Data.count - (pcm16Data.count % MemoryLayout<Int16>.size)
        guard usableByteCount > 0 else { return }
        let data = Data(pcm16Data.prefix(usableByteCount))
        let level = Self.level(forPCM16: data)

        playbackQueue.async { [weak self] in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(usableByteCount / MemoryLayout<Int16>.size)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: self.realtimeFormat,
                frameCapacity: frameCount
            ) else {
                self.onError?(AuroraAudioEngineError.bufferAllocationFailed)
                return
            }

            buffer.frameLength = frameCount
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let destination = audioBuffers.first?.mData else {
                self.onError?(AuroraAudioEngineError.bufferAllocationFailed)
                return
            }
            data.withUnsafeBytes { source in
                if let sourceAddress = source.baseAddress {
                    memcpy(destination, sourceAddress, usableByteCount)
                }
            }
            audioBuffers[0].mDataByteSize = UInt32(usableByteCount)

            let segment = PlaybackSegment(
                id: UUID(),
                key: key,
                startFrame: self.nextTimelineFrame,
                frameCount: Int64(frameCount)
            )
            self.nextTimelineFrame = segment.endFrame
            self.pendingSegments.append(segment)
            let generation = self.playbackGeneration

            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.playbackQueue.async {
                    self.completeSegment(segment, generation: generation)
                }
            }

            if !self.player.isPlaying {
                self.player.play()
            }
            self.onOutputLevel?(level)
        }
    }

    func markPlaybackItemComplete(_ key: AuroraPlaybackKey) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.endedItems.insert(key)
            self.finishItemIfDrained(key)
            self.finishTimelineIfIdle()
        }
    }

    /// Stops all unheard output and identifies every item affected. The first
    /// cut is the item at the output device; later queued items have 0 ms heard.
    @discardableResult
    func interruptPlayback() -> [AuroraPlaybackCut] {
        playbackQueue.sync {
            guard !pendingSegments.isEmpty else { return [] }

            let renderedFrame = currentRenderedFrameLocked()
            var order: [AuroraPlaybackKey] = []
            for segment in pendingSegments where !order.contains(segment.key) {
                order.append(segment.key)
            }

            var cuts: [AuroraPlaybackCut] = []
            for key in order {
                let completed = completedFrames[key] ?? 0
                let partial = pendingSegments
                    .filter { $0.key == key }
                    .reduce(Int64(0)) { total, segment in
                        guard renderedFrame > segment.startFrame else { return total }
                        return total + min(segment.frameCount, renderedFrame - segment.startFrame)
                    }
                let heardFrames = max(0, completed + partial)
                let milliseconds = Int((Double(heardFrames) / Self.sampleRate * 1_000).rounded(.down))
                cuts.append(AuroraPlaybackCut(key: key, playedMilliseconds: milliseconds))
            }

            playbackGeneration &+= 1
            pendingSegments.removeAll()
            endedItems.removeAll()
            completedFrames.removeAll()
            nextTimelineFrame = 0
            player.stop()
            player.reset()
            onOutputLevel?(0)
            onPlaybackIdle?()
            return cuts
        }
    }

    private func completeSegment(_ segment: PlaybackSegment, generation: UInt64) {
        guard generation == playbackGeneration,
              let index = pendingSegments.firstIndex(where: { $0.id == segment.id }) else { return }
        pendingSegments.remove(at: index)
        completedFrames[segment.key, default: 0] += segment.frameCount
        finishItemIfDrained(segment.key)
        finishTimelineIfIdle()
    }

    private func finishItemIfDrained(_ key: AuroraPlaybackKey) {
        guard endedItems.contains(key),
              !pendingSegments.contains(where: { $0.key == key }) else { return }
        endedItems.remove(key)
        completedFrames.removeValue(forKey: key)
        onPlaybackItemFinished?(key)
    }

    private func finishTimelineIfIdle() {
        guard pendingSegments.isEmpty else { return }
        nextTimelineFrame = 0
        player.stop()
        player.reset()
        onOutputLevel?(0)
        onPlaybackIdle?()
    }

    private func currentRenderedFrameLocked() -> Int64 {
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime) else {
            return pendingSegments.first?.startFrame ?? 0
        }
        return max(0, Int64(playerTime.sampleTime))
    }

    private func installConfigurationObserver() {
        guard configurationObserver == nil else { return }
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let shouldReport = self.running
            self.stateLock.unlock()
            if shouldReport {
                self.onError?(AuroraAudioEngineError.audioRouteChanged)
            }
        }
    }

    /// Voice processing can expose multiple deinterleaved channels on macOS.
    /// AVAudioConverter otherwise accepts that graph but may silently emit
    /// zeroed mono PCM. Channel zero is the processed microphone signal; map it
    /// explicitly before sample-rate and sample-format conversion.
    static func makeInputConverter(
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        if inputFormat.channelCount > outputFormat.channelCount {
            converter.channelMap = (0..<Int(outputFormat.channelCount)).map { NSNumber(value: $0) }
        }
        return converter
    }

    private func consumeMicrophoneBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let converter = running ? inputConverter : nil
        stateLock.unlock()
        guard let converter else { return }

        let ratio = Self.sampleRate / inputBuffer.format.sampleRate
        let estimatedFrames = ceil(Double(inputBuffer.frameLength) * ratio) + 32
        let capacity = AVAudioFrameCount(max(1, estimatedFrames))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: realtimeFormat,
            frameCapacity: capacity
        ) else {
            onError?(AuroraAudioEngineError.bufferAllocationFailed)
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            if let conversionError { onError?(conversionError) }
            return
        }
        guard outputBuffer.frameLength > 0 else { return }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
        guard let source = audioBuffers.first?.mData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: source, count: byteCount)
        onInputLevel?(Self.level(forPCM16: data))
        onMicrophonePCM?(data)
    }

    private static func level(forPCM16 data: Data) -> Float {
        guard data.count >= MemoryLayout<Int16>.size else { return 0 }
        let bytes = [UInt8](data)
        var sumSquares = 0.0
        var sampleCount = 0

        for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let sample = Double(Int16(bitPattern: bits)) / Double(Int16.max)
            sumSquares += sample * sample
            sampleCount += 1
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return Float(min(1, sqrt(rms)))
    }
}
