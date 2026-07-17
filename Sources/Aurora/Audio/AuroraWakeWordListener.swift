import AVFoundation
import CoreAudio
import Foundation
import Speech

enum AuroraWakeWordPermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum AuroraWakeWordError: Error, Equatable, Sendable {
    case speechRecognitionPermissionDenied
    case speechRecognitionRestricted
    case microphonePermissionDenied
    case microphoneRestricted
    case unsupportedLocale(String)
    case onDeviceRecognitionUnsupported(String)
    case recognizerTemporarilyUnavailable
    case microphoneUnavailable
    case audioEngineStartFailed(String)
    case recognitionFailed(domain: String, code: Int)

    fileprivate var isRecoverable: Bool {
        switch self {
        case .recognizerTemporarilyUnavailable,
             .microphoneUnavailable,
             .audioEngineStartFailed,
             .recognitionFailed:
            return true
        case .speechRecognitionPermissionDenied,
             .speechRecognitionRestricted,
             .microphonePermissionDenied,
             .microphoneRestricted,
             .unsupportedLocale,
             .onDeviceRecognitionUnsupported:
            return false
        }
    }

    var diagnosticCode: String {
        switch self {
        case .speechRecognitionPermissionDenied: return "speech_permission_denied"
        case .speechRecognitionRestricted: return "speech_permission_restricted"
        case .microphonePermissionDenied: return "microphone_permission_denied"
        case .microphoneRestricted: return "microphone_restricted"
        case .unsupportedLocale: return "unsupported_locale"
        case .onDeviceRecognitionUnsupported: return "on_device_recognition_unsupported"
        case .recognizerTemporarilyUnavailable: return "recognizer_temporarily_unavailable"
        case .microphoneUnavailable: return "microphone_unavailable"
        case .audioEngineStartFailed: return "audio_engine_start_failed"
        case .recognitionFailed: return "recognition_failed"
        }
    }
}

extension AuroraWakeWordError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .speechRecognitionPermissionDenied:
            return "Speech Recognition permission is needed to hear ‘Hey Aurora’ while Aurora rests."
        case .speechRecognitionRestricted:
            return "Speech Recognition is restricted on this Mac."
        case .microphonePermissionDenied:
            return "Microphone permission is needed to hear ‘Hey Aurora’ while Aurora rests."
        case .microphoneRestricted:
            return "Microphone access is restricted on this Mac."
        case .unsupportedLocale(let identifier):
            return "On-device speech recognition is unavailable for \(identifier)."
        case .onDeviceRecognitionUnsupported(let identifier):
            return "This Mac does not support on-device speech recognition for \(identifier)."
        case .recognizerTemporarilyUnavailable:
            return "On-device speech recognition is temporarily unavailable."
        case .microphoneUnavailable:
            return "No usable microphone input is currently available."
        case .audioEngineStartFailed(let detail):
            return "The local wake-word microphone could not start: \(detail)"
        case .recognitionFailed(let domain, let code):
            return "Local wake-word recognition stopped unexpectedly (\(domain) \(code))."
        }
    }
}

enum AuroraWakeWordStatus: Equatable, Sendable {
    case stopped
    case requestingPermissions
    case starting
    case listening
    case rollingRecognition
    case recovering(error: AuroraWakeWordError, retryAfterSeconds: Double)
    case wakeDetected
    case failed(AuroraWakeWordError)
}

struct AuroraWakeWordConfiguration: Equatable, Sendable {
    var localeIdentifier: String = "en-US"
    var recognitionTaskDuration: TimeInterval = 45
    var normalRestartDelay: TimeInterval = 0.15
    var initialFailureRetryDelay: TimeInterval = 0.5
    var maximumFailureRetryDelay: TimeInterval = 8
    var minimumStableInputRouteDuration: TimeInterval = 0.35

    fileprivate var boundedTaskDuration: TimeInterval {
        min(max(recognitionTaskDuration, 10), 50)
    }

    fileprivate var boundedNormalRestartDelay: TimeInterval {
        min(max(normalRestartDelay, 0.05), 1)
    }

    fileprivate var boundedInitialFailureDelay: TimeInterval {
        min(max(initialFailureRetryDelay, 0.25), 4)
    }

    fileprivate var boundedMaximumFailureDelay: TimeInterval {
        min(max(maximumFailureRetryDelay, boundedInitialFailureDelay), 30)
    }

    fileprivate var boundedStableInputRouteDuration: TimeInterval {
        min(max(minimumStableInputRouteDuration, 0.2), 2)
    }
}

struct AuroraWakeAudioRouteSnapshot: Equatable, Sendable {
    let deviceID: AudioObjectID
    let nominalSampleRate: Double
    let inputStreamCount: Int
}

/// Core Audio can temporarily expose a stale AVAudioEngine output format while
/// the real default input has zero streams (especially during AirPods route
/// changes). This probe refuses that transitional state before AVAudioEngine's
/// Objective-C `installTap` assertion can strand the listener.
enum AuroraWakeAudioRouteProbe {
    static func currentDefaultInput() -> AuroraWakeAudioRouteSnapshot? {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        ) == noErr,
        deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &streamsAddress,
            0,
            nil,
            &streamsSize
        ) == noErr else { return nil }
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else { return nil }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &rateAddress,
            0,
            nil,
            &rateSize,
            &sampleRate
        ) == noErr,
        sampleRate.isFinite,
        sampleRate > 0 else { return nil }

        return AuroraWakeAudioRouteSnapshot(
            deviceID: deviceID,
            nominalSampleRate: sampleRate,
            inputStreamCount: streamCount
        )
    }
}

struct AuroraWakeAudioRouteStabilityGate: Sendable {
    private(set) var candidate: AuroraWakeAudioRouteSnapshot?
    private(set) var observedAt: TimeInterval?

    mutating func observe(
        _ snapshot: AuroraWakeAudioRouteSnapshot?,
        at now: TimeInterval,
        minimumDuration: TimeInterval
    ) -> Bool {
        guard let snapshot else {
            reset()
            return false
        }
        guard candidate == snapshot, let observedAt else {
            candidate = snapshot
            self.observedAt = now
            return false
        }
        return now - observedAt >= minimumDuration
    }

    mutating func reset() {
        candidate = nil
        observedAt = nil
    }
}

/// Strictly matches the adjacent words "hey" and "Aurora". Punctuation and
/// whitespace between them are accepted, but substrings such as "they Aurora"
/// and "hey Auroras" are deliberately rejected.
struct AuroraWakePhraseMatcher: Sendable {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?iu)(?<![\p{L}\p{N}])hey[\p{Z}\s\p{P}]+aurora(?![\p{L}\p{N}])"#
    )

    func matches(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return Self.expression.firstMatch(in: candidate, range: range) != nil
    }
}

protocol AuroraWakeWordAuthorizationProviding {
    func speechRecognitionPermission() -> AuroraWakeWordPermissionState
    func requestSpeechRecognitionPermission() async -> AuroraWakeWordPermissionState
    func microphonePermission() -> AuroraWakeWordPermissionState
    func requestMicrophonePermission() async -> AuroraWakeWordPermissionState
}

struct SystemAuroraWakeWordAuthorizationProvider: AuroraWakeWordAuthorizationProviding {
    func speechRecognitionPermission() -> AuroraWakeWordPermissionState {
        Self.mapSpeechPermission(SFSpeechRecognizer.authorizationStatus())
    }

    func requestSpeechRecognitionPermission() async -> AuroraWakeWordPermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.mapSpeechPermission(status))
            }
        }
    }

    func microphonePermission() -> AuroraWakeWordPermissionState {
        Self.mapMicrophonePermission(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestMicrophonePermission() async -> AuroraWakeWordPermissionState {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
        if granted { return .authorized }
        return microphonePermission()
    }

    private static func mapSpeechPermission(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> AuroraWakeWordPermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    private static func mapMicrophonePermission(
        _ status: AVAuthorizationStatus
    ) -> AuroraWakeWordPermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}

/// A local, resting-state microphone listener for Aurora's wake phrase.
///
/// This service never contacts OpenAI and forces Apple's Speech request to stay
/// on-device. It intentionally exposes no transcript callback and retains no
/// recognized text. Every recognition task rolls before Apple's one-minute
/// ceiling, and only one audio engine, tap, request, and task may exist at once.
///
/// `onWakeWordDetected` is invoked only after the input tap, audio engine, and
/// recognition task have all been stopped. The receiver can therefore call
/// Aurora's main `wake()` path immediately without racing for the microphone.
@MainActor
final class AuroraWakeWordListener {
    typealias RecognizerFactory = (Locale) -> SFSpeechRecognizer?
    typealias AudioEngineFactory = () -> AVAudioEngine
    typealias PhraseMatcher = (String) -> Bool
    typealias AudioRouteProvider = () -> AuroraWakeAudioRouteSnapshot?
    typealias Clock = () -> TimeInterval

    var onWakeWordDetected: (() -> Void)?
    var onStatusChange: ((AuroraWakeWordStatus) -> Void)? {
        didSet { onStatusChange?(status) }
    }

    private(set) var status: AuroraWakeWordStatus = .stopped {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    private let configuration: AuroraWakeWordConfiguration
    private let authorizationProvider: any AuroraWakeWordAuthorizationProviding
    private let recognizerFactory: RecognizerFactory
    private let audioEngineFactory: AudioEngineFactory
    private let phraseMatcher: PhraseMatcher
    private let audioRouteProvider: AudioRouteProvider
    private let clock: Clock

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var engineConfigurationObserver: NSObjectProtocol?
    private var activeRecognitionID: UUID?
    private var routeStabilityGate = AuroraWakeAudioRouteStabilityGate()

    private var authorizationTask: Task<Void, Never>?
    private var rollingTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    private var wantsToListen = false
    private var lifecycleGeneration: UInt64 = 0
    private var consecutiveFailures = 0

    init(
        configuration: AuroraWakeWordConfiguration = .init(),
        authorizationProvider: any AuroraWakeWordAuthorizationProviding =
            SystemAuroraWakeWordAuthorizationProvider(),
        recognizerFactory: @escaping RecognizerFactory = { SFSpeechRecognizer(locale: $0) },
        audioEngineFactory: @escaping AudioEngineFactory = { AVAudioEngine() },
        phraseMatcher: @escaping PhraseMatcher = { AuroraWakePhraseMatcher().matches($0) },
        audioRouteProvider: @escaping AudioRouteProvider = {
            AuroraWakeAudioRouteProbe.currentDefaultInput()
        },
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.configuration = configuration
        self.authorizationProvider = authorizationProvider
        self.recognizerFactory = recognizerFactory
        self.audioEngineFactory = audioEngineFactory
        self.phraseMatcher = phraseMatcher
        self.audioRouteProvider = audioRouteProvider
        self.clock = clock
    }

    deinit {
        authorizationTask?.cancel()
        rollingTask?.cancel()
        restartTask?.cancel()
        activeRecognitionID = nil
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        if inputTapInstalled, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine?.stop()
        audioEngine?.reset()
    }

    /// Starts listening if it is not already active or preparing to become
    /// active. Permission prompts, if still needed, are handled asynchronously.
    func start() {
        guard !wantsToListen else { return }

        wantsToListen = true
        lifecycleGeneration &+= 1
        consecutiveFailures = 0
        routeStabilityGate.reset()
        let generation = lifecycleGeneration
        status = .requestingPermissions

        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            await self?.authorizeAndStart(generation: generation)
        }
    }

    /// Stops the local recognizer synchronously. When this method returns, its
    /// microphone tap and audio engine have been released for Realtime audio.
    func stopAndRelinquishMicrophone() {
        let alreadyStopped = !wantsToListen
            && authorizationTask == nil
            && rollingTask == nil
            && restartTask == nil
            && recognitionTask == nil
            && recognitionRequest == nil
            && audioEngine?.isRunning != true
        guard !alreadyStopped || status != .stopped else { return }

        wantsToListen = false
        lifecycleGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        restartTask?.cancel()
        restartTask = nil
        tearDownRecognitionPipeline()
        consecutiveFailures = 0
        status = .stopped
    }

    /// Alias for lifecycle owners that do not need to emphasize microphone
    /// handoff at the call site.
    func stop() {
        stopAndRelinquishMicrophone()
    }

    private func authorizeAndStart(generation: UInt64) async {
        let speechPermission: AuroraWakeWordPermissionState
        switch authorizationProvider.speechRecognitionPermission() {
        case .notDetermined:
            speechPermission = await authorizationProvider.requestSpeechRecognitionPermission()
        case let known:
            speechPermission = known
        }
        guard isCurrent(generation) else { return }

        switch speechPermission {
        case .authorized:
            break
        case .denied:
            failPermanently(.speechRecognitionPermissionDenied, generation: generation)
            return
        case .restricted, .notDetermined:
            failPermanently(.speechRecognitionRestricted, generation: generation)
            return
        }

        let microphonePermission: AuroraWakeWordPermissionState
        switch authorizationProvider.microphonePermission() {
        case .notDetermined:
            microphonePermission = await authorizationProvider.requestMicrophonePermission()
        case let known:
            microphonePermission = known
        }
        guard isCurrent(generation) else { return }

        switch microphonePermission {
        case .authorized:
            break
        case .denied:
            failPermanently(.microphonePermissionDenied, generation: generation)
            return
        case .restricted, .notDetermined:
            failPermanently(.microphoneRestricted, generation: generation)
            return
        }

        let locale = Locale(identifier: configuration.localeIdentifier)
        guard let recognizer = recognizerFactory(locale) else {
            failPermanently(
                .unsupportedLocale(configuration.localeIdentifier),
                generation: generation
            )
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            failPermanently(
                .onDeviceRecognitionUnsupported(configuration.localeIdentifier),
                generation: generation
            )
            return
        }

        recognizer.defaultTaskHint = .confirmation
        recognizer.queue = .main
        self.recognizer = recognizer
        authorizationTask = nil
        startRecognitionOrRecover(generation: generation)
    }

    private func startRecognitionOrRecover(generation: UInt64) {
        guard isCurrent(generation) else { return }
        status = .starting
        do {
            try beginRecognition(generation: generation)
        } catch let error as AuroraWakeWordError {
            if error.isRecoverable {
                scheduleRecovery(after: error, generation: generation)
            } else {
                failPermanently(error, generation: generation)
            }
        } catch {
            scheduleRecovery(
                after: .audioEngineStartFailed(error.localizedDescription),
                generation: generation
            )
        }
    }

    private func beginRecognition(generation: UInt64) throws {
        guard isCurrent(generation), let recognizer else { return }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AuroraWakeWordError.onDeviceRecognitionUnsupported(
                configuration.localeIdentifier
            )
        }
        guard recognizer.isAvailable else {
            throw AuroraWakeWordError.recognizerTemporarilyUnavailable
        }

        let route = audioRouteProvider()
        let routeIsStable = routeStabilityGate.observe(
            route,
            at: clock(),
            minimumDuration: configuration.boundedStableInputRouteDuration
        )
        guard let route, routeIsStable else {
            // A newly appeared route should be retried promptly rather than
            // inheriting a long backoff accumulated while no mic existed.
            if route != nil { consecutiveFailures = 0 }
            throw AuroraWakeWordError.microphoneUnavailable
        }

        tearDownRecognitionPipeline()
        guard isCurrent(generation) else { return }

        let audioEngine = audioEngineFactory()
        self.audioEngine = audioEngine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings = ["Hey Aurora"]
        request.addsPunctuation = false

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              abs(format.sampleRate - route.nominalSampleRate) < 1,
              audioRouteProvider() == route else {
            throw AuroraWakeWordError.microphoneUnavailable
        }

        recognitionRequest = request
        // `nil` binds the tap to the input node's current native output format.
        // Passing the format read above can become stale between these calls
        // during an AirPods A2DP/HFP transition and raises an Objective-C
        // exception that Swift cannot catch.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        inputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            tearDownRecognitionPipeline()
            throw AuroraWakeWordError.audioEngineStartFailed(error.localizedDescription)
        }
        installEngineConfigurationObserver(
            for: audioEngine,
            generation: generation
        )

        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.receiveRecognition(
                    result: result,
                    error: error,
                    recognitionID: recognitionID,
                    generation: generation
                )
            }
        }

        status = .listening
        rollingTask?.cancel()
        let duration = configuration.boundedTaskDuration
        rollingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: duration))
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation),
                  self.activeRecognitionID == recognitionID else { return }
            self.restartAfterNormalCompletion(generation: generation)
        }
    }

    private func receiveRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        recognitionID: UUID,
        generation: UInt64
    ) {
        guard isCurrent(generation), activeRecognitionID == recognitionID else { return }

        if let result {
            consecutiveFailures = 0
            if result.transcriptions.prefix(8).contains(where: matchesWakePhrase) {
                detectWakeWord()
                return
            }
            if result.isFinal {
                restartAfterNormalCompletion(generation: generation)
                return
            }
        }

        if let error = error as NSError? {
            scheduleRecovery(
                after: .recognitionFailed(domain: error.domain, code: error.code),
                generation: generation
            )
        }
    }

    private func matchesWakePhrase(in transcription: SFTranscription) -> Bool {
        if phraseMatcher(transcription.formattedString) { return true }
        let segments = transcription.segments
        guard segments.count >= 2 else { return false }
        for index in 0..<(segments.count - 1) {
            let left = [segments[index].substring]
                + Array(segments[index].alternativeSubstrings.prefix(8))
            let right = [segments[index + 1].substring]
                + Array(segments[index + 1].alternativeSubstrings.prefix(8))
            if left.contains(where: { first in
                right.contains(where: { second in
                    phraseMatcher("\(first) \(second)")
                })
            }) {
                return true
            }
        }
        return false
    }

    private func restartAfterNormalCompletion(generation: UInt64) {
        guard isCurrent(generation) else { return }
        consecutiveFailures = 0
        status = .rollingRecognition
        tearDownRecognitionPipeline()
        scheduleRestart(after: configuration.boundedNormalRestartDelay, generation: generation)
    }

    private func scheduleRecovery(after error: AuroraWakeWordError, generation: UInt64) {
        guard isCurrent(generation) else { return }
        consecutiveFailures = min(consecutiveFailures + 1, 16)
        let multiplier = pow(2, Double(max(0, consecutiveFailures - 1)))
        let delay = min(
            configuration.boundedMaximumFailureDelay,
            configuration.boundedInitialFailureDelay * multiplier
        )
        status = .recovering(error: error, retryAfterSeconds: delay)
        tearDownRecognitionPipeline()
        scheduleRestart(after: delay, generation: generation)
    }

    private func installEngineConfigurationObserver(
        for audioEngine: AVAudioEngine,
        generation: UInt64
    ) {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.receiveAudioRouteChange(generation: generation)
            }
        }
    }

    private func receiveAudioRouteChange(generation: UInt64) {
        guard isCurrent(generation) else { return }
        consecutiveFailures = 0
        routeStabilityGate.reset()
        status = .recovering(error: .microphoneUnavailable, retryAfterSeconds: 0.5)
        tearDownRecognitionPipeline()
        scheduleRestart(after: 0.5, generation: generation)
    }

    private func scheduleRestart(after delay: TimeInterval, generation: UInt64) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            } catch {
                return
            }
            guard let self, self.isCurrent(generation) else { return }
            self.restartTask = nil
            self.startRecognitionOrRecover(generation: generation)
        }
    }

    private func detectWakeWord() {
        guard wantsToListen else { return }

        wantsToListen = false
        lifecycleGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        restartTask?.cancel()
        restartTask = nil
        tearDownRecognitionPipeline()
        consecutiveFailures = 0
        status = .wakeDetected

        // The complete local audio pipeline is gone before this callback. The
        // app may safely start AuroraRealtimeClient from inside the closure.
        onWakeWordDetected?()
    }

    private func failPermanently(_ error: AuroraWakeWordError, generation: UInt64) {
        guard isCurrent(generation) else { return }
        wantsToListen = false
        lifecycleGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        restartTask?.cancel()
        restartTask = nil
        tearDownRecognitionPipeline()
        status = .failed(error)
    }

    private func tearDownRecognitionPipeline() {
        activeRecognitionID = nil
        rollingTask?.cancel()
        rollingTask = nil

        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        if inputTapInstalled, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.reset()
        audioEngine = nil
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        wantsToListen && generation == lifecycleGeneration
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let bounded = min(max(interval, 0), 60)
        return UInt64((bounded * 1_000_000_000).rounded())
    }
}
