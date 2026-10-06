import AVFoundation
import AppKit
import Speech
import Foundation
import CameraCueSpeech
import TeleprompterCore

@MainActor protocol SpeechCapturing: AnyObject {
    var state: SpeechFollower.State { get }
    var onTranscript: ((String) -> Void)? { get set }
    var onUnexpectedStop: (() -> Void)? { get set }
    func start() async
    func pause()
    func stop()
}

@MainActor protocol SpeechPermissionProviding {
    var needsPrompt: Bool { get }
    var summary: String { get }
    func authorize(whileCurrent: () -> Bool) async -> Bool
}

@MainActor struct SystemSpeechPermissions: SpeechPermissionProviding {
    var requiresLegacySpeechAuthorization = true
    var needsPrompt: Bool {
        (requiresLegacySpeechAuthorization && SFSpeechRecognizer.authorizationStatus() == .notDetermined) ||
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
    var summary: String {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .restricted || (requiresLegacySpeechAuthorization && (speech == .denied || speech == .restricted)) {
            return requiresLegacySpeechAuthorization ? "Allow Microphone and Speech Recognition in System Settings." : "Allow Microphone in System Settings for live Voice Follow."
        }
        if !requiresLegacySpeechAuthorization { return needsPrompt ? "Set up microphone access for on-device Voice Follow." : "Microphone access ready · on-device Voice Follow" }
        return needsPrompt ? "Set up microphone and speech access before your take." : "Microphone and speech access ready"
    }
    func authorize(whileCurrent: () -> Bool) async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if requiresLegacySpeechAuthorization && speech == .notDetermined {
            let allowed = await PermissionRequest.wait { callback in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in callback(status == .authorized) }
            }
            guard allowed == true else { return false }
            speech = .authorized
        }
        guard whileCurrent(), !requiresLegacySpeechAuthorization || speech == .authorized else { return false }
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphone = await PermissionRequest.wait { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) } == true
        }
        return whileCurrent() && microphone
    }
}

@MainActor final class SpeechFollower: ObservableObject, SpeechCapturing {
    enum State: String {
        case idle = "Ready", requesting = "Requesting access", listening = "Listening", paused = "Paused"
        case denied = "Permission needed", unavailable = "Speech unavailable", error = "Audio error"
        case interrupted = "Audio input changed"
    }
    enum EngineChoice: String, CaseIterable { case automatic = "Automatic", analyzer = "Modern on-device", legacy = "Legacy" }
    @Published private(set) var engineChoice: EngineChoice { didSet { defaults?.set(engineChoice.rawValue, forKey: "speechEngineChoice") } }
    @Published private(set) var activeEngine: SpeechEngineID = .legacy
    @Published private(set) var setupMessage: String?
    var onObservation: ((SpeechObservation) -> Void)?
    private let defaults: UserDefaults?
    private var modernSession: (any StreamingSpeechSession)?
    private var transcriptLedger = SpeechTranscriptLedger()
    @Published private(set) var state: State = .idle
    @Published private(set) var isAuthorizing = false
    private(set) var transcript = ""
    var onTranscript: ((String) -> Void)?
    var onPermissionPromptChanged: ((Bool) -> Void)?
    var onUnexpectedStop: (() -> Void)?

    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioSink = AudioRequestSink()
    private let permissionOverride: (any SpeechPermissionProviding)?
    @Published private(set) var modernAvailable = false
    private var startWithModern = false
    private var prefersModern: Bool {
        Self.usesModern(choice: engineChoice, modernAvailable: modernAvailable, legacyAvailable: recognizer?.isAvailable == true,
                        legacyAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized)
    }
    static func usesModern(choice: EngineChoice, modernAvailable: Bool, legacyAvailable: Bool, legacyAuthorized: Bool) -> Bool {
        guard modernAvailable, choice != .legacy else { return false }
        return choice == .analyzer || !legacyAvailable || !legacyAuthorized
    }
    private var permissions: any SpeechPermissionProviding {
        permissionOverride ?? SystemSpeechPermissions(requiresLegacySpeechAuthorization: !prefersModern)
    }
    private let captureOverride: (() throws -> Void)?
    private var tapInstalled = false
    private var recognitionGeneration = 0
    private var startupGeneration = 0
    private var consecutiveRecognitionErrors = 0
    private var configurationObserver: NotificationRegistration?
    private var sleepObserver: NotificationRegistration?

    init(permissions: (any SpeechPermissionProviding)? = nil, captureOverride: (() throws -> Void)? = nil, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        engineChoice = defaults?.string(forKey: "speechEngineChoice").flatMap(EngineChoice.init(rawValue:)) ?? .automatic
        self.permissionOverride = permissions
        self.captureOverride = captureOverride
        Task { @MainActor [weak self] in
            guard #available(macOS 26, *) else { return }
            let supported = await AnalyzerSpeechSession.supported()
            self?.modernAvailable = supported
        }
        configurationObserver = NotificationRegistration(name: .AVAudioEngineConfigurationChange) { [weak self] notification in
            // Only identity crosses to the main actor; the engine stays actor-owned.
            let changedEngineID = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, changedEngineID == ObjectIdentifier(self.engine), self.state == .listening, !self.engine.isRunning else { return }
                self.interrupt()
            }
        }
        sleepObserver = NotificationRegistration(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .listening || self.state == .requesting else { return }
                self.interrupt()
            }
        }
    }

    // Explicit nonisolated teardown avoids the Swift 6.2 back-deployment bug
    // (swiftlang/swift#88036). Registration objects remove their own tokens.
    deinit {}

    var readiness: String {
        if let setupMessage { return setupMessage }
        if isAuthorizing { return "Check the macOS permission dialog. Setup will return if no response arrives." }
        if state == .denied { return "Voice Follow access is not ready. Open System Settings to allow access, then return and try again." }
        if state == .interrupted { return "Audio input changed. Check your microphone, then resume prompting." }
        if state == .error { return "Audio stopped. Check your microphone, then resume prompting." }
        if permissionOverride == nil, engineChoice == .analyzer, !modernAvailable { return "Modern on-device speech is unavailable on this Mac or for this language." }
        if permissionOverride == nil, !prefersModern, recognizer?.isAvailable != true { return "Speech recognition is unavailable. You can use Manual mode." }
        return permissions.summary
    }
    var permissionSettingsURL: URL {
        let pane = !prefersModern && SFSpeechRecognizer.authorizationStatus() != .authorized ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!
    }
    var needsPermissionSetup: Bool { permissions.needsPrompt }
    func selectEngine(_ choice: EngineChoice) {
        guard state != .listening, !isAuthorizing else { return }
        engineChoice = choice
    }
    func refreshReadiness() {
        if permissionOverride == nil, state == .denied,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           prefersModern || SFSpeechRecognizer.authorizationStatus() == .authorized { state = .idle }
        objectWillChange.send()
    }

    func prepare() async { await begin(capture: false) }
    func start() async { await begin(capture: true) }

    private func begin(capture: Bool) async {
        guard state != .listening, !isAuthorizing else { return }
        startupGeneration += 1
        let generation = startupGeneration
        isAuthorizing = true
        state = .requesting
        if captureOverride == nil, #available(macOS 26, *) { modernAvailable = await AnalyzerSpeechSession.supported() }
        guard startupGeneration == generation else { isAuthorizing = false; return }
        if captureOverride == nil, engineChoice == .analyzer, !modernAvailable {
            isAuthorizing = false; state = .unavailable; return
        }
        startWithModern = prefersModern
        let selectedPermissions = permissionOverride ?? SystemSpeechPermissions(requiresLegacySpeechAuthorization: !startWithModern)
        let prompts = selectedPermissions.needsPrompt
        if prompts { onPermissionPromptChanged?(true); NSApp.activate(ignoringOtherApps: true) }
        defer {
            isAuthorizing = false
            if prompts { onPermissionPromptChanged?(false) }
        }
        let authorized = await selectedPermissions.authorize { [weak self] in self?.startupGeneration == generation }
        guard startupGeneration == generation else { return }
        if Task.isCancelled { stop(); return }
        guard authorized else { state = .denied; return }
        guard capture else { state = .idle; return }
        do {
            if let captureOverride { try captureOverride() }
            else {
                try await startAudio(generation: generation)
            }
            guard startupGeneration == generation else { return }
            setupMessage = nil
            state = .listening
        } catch {
            guard startupGeneration == generation else { return }
            setupMessage = error.localizedDescription
            stopAudio()
            state = .error
        }
    }

    func pause() {
        startupGeneration += 1
        stopAudio()
        state = .paused
    }
    func stop() {
        startupGeneration += 1
        stopAudio()
        state = .idle
    }
    private func interrupt() {
        stop()
        state = .interrupted
        onUnexpectedStop?()
    }
    private func stopAudio() {
        recognitionGeneration += 1
        modernSession?.stop(); modernSession = nil
        transcriptLedger = SpeechTranscriptLedger()
        setupMessage = nil
        audioSink.set(nil)
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }
    private func startAudio(generation: Int) async throws {
        consecutiveRecognitionErrors = 0
        // A fresh engine picks up device or sample-rate changes after an interruption.
        engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "CameraCue", code: 1) }
        if startWithModern, #available(macOS 26, *) {
            setupMessage = "Preparing the on-device speech model…"
            let session = AnalyzerSpeechSession(fastResults: true, onObservation: { [weak self] observation in
                guard let self, generation == self.startupGeneration, self.state == .listening else { return }
                self.transcriptLedger.consume(observation)
                let text = self.transcriptLedger.recentText
                self.onObservation?(observation)
                if text != self.transcript { self.transcript = text; self.onTranscript?(text) }
            }, onFailure: { [weak self] reason in
                guard let self, generation == self.startupGeneration else { return }
                self.setupMessage = reason
                self.stopAudio(); self.state = .error; self.onUnexpectedStop?()
            })
            do {
                try await session.prepare(format: format, allowModelDownload: true)
                guard generation == startupGeneration else { session.stop(); throw CancellationError() }
                modernSession = session; activeEngine = .analyzer
                let receiver = session.receiver()
                let bufferFailure: @Sendable () -> Void = { [weak self] in
                    Task { @MainActor in
                        guard let self, generation == self.startupGeneration else { return }
                        self.stopAudio(); self.state = .error; self.onUnexpectedStop?()
                    }
                }
                node.installTap(onBus: 0, bufferSize: 1024, format: format,
                    block: Self.makeModernAudioTap(receiver: receiver, failure: bufferFailure))
            } catch {
                session.stop()
                guard engineChoice == .automatic, generation == startupGeneration, SFSpeechRecognizer.authorizationStatus() == .authorized else { throw error }
                setupMessage = "Using the available legacy speech engine"
                try installLegacyTap(node: node, format: format)
            }
        } else {
            if engineChoice == .analyzer { throw SpeechSessionError.unsupported }
            try installLegacyTap(node: node, format: format)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }
    nonisolated static func makeModernAudioTap(
        receiver: @escaping @Sendable (OwnedSpeechBuffer, Double?) -> Void,
        failure: @escaping @Sendable () -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, time in
            do {
                let origin = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                receiver(try OwnedSpeechBuffer(copying: buffer), origin)
            } catch { failure() }
        }
    }

    private func installLegacyTap(node: AVAudioInputNode, format: AVAudioFormat) throws {
        guard let recognizer, recognizer.isAvailable else { throw SpeechSessionError.unsupported }
        activeEngine = .legacy
        audioSink.resetCaptureClock()
        startRecognitionTask(recognizer: recognizer)
        let sink = audioSink
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, time in sink.append(buffer, time: time) }
    }
    private func startRecognitionTask(recognizer: SFSpeechRecognizer) {
        recognitionGeneration += 1
        let generation = recognitionGeneration
        task?.cancel()
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = next
        audioSink.set(next)
        let origin = audioSink.currentSeconds
        task = recognizer.recognitionTask(with: next) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let words = result?.bestTranscription.segments.map {
                TimedSpeechWord(text: $0.substring, start: origin + $0.timestamp, end: origin + $0.timestamp + $0.duration,
                                confidence: $0.confidence > 0 ? Double($0.confidence) : nil)
            } ?? []
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration,
                      self.state == .listening || self.state == .requesting else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.consecutiveRecognitionErrors = 0
                    if self.state == .listening {
                        let sourceOrigin = self.audioSink.sourceOrigin
                        self.onObservation?(SpeechObservation(engine: .legacy, text: text, audioStart: origin, audioEnd: words.last?.end ?? origin,
                                                              deliveredAt: max(0, ProcessInfo.processInfo.systemUptime - (sourceOrigin ?? ProcessInfo.processInfo.systemUptime)),
                                                              isFinal: final, words: words, sourceUptimeOrigin: sourceOrigin))
                        self.onTranscript?(text)
                    }
                }
                if error != nil && self.state == .listening {
                    self.consecutiveRecognitionErrors += 1
                    if self.consecutiveRecognitionErrors >= 3 {
                        self.stop(); self.state = .error; self.onUnexpectedStop?()
                    } else {
                        self.recognitionGeneration += 1
                        let retryGeneration = self.recognitionGeneration
                        self.audioSink.set(nil)
                        self.request?.endAudio(); self.task?.cancel()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400 * self.consecutiveRecognitionErrors))
                            guard self.state == .listening, self.recognitionGeneration == retryGeneration else { return }
                            if let currentRecognizer = self.recognizer { self.startRecognitionTask(recognizer: currentRecognizer) }
                        }
                    }
                } else if final && self.state == .listening { if let currentRecognizer = self.recognizer { self.startRecognitionTask(recognizer: currentRecognizer) } }
            }
        }
    }
}

/// Audio buffers must be appended before Core Audio reuses them.
private final class AudioRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var seconds = 0.0
    private var origin: Double?
    var currentSeconds: Double { lock.lock(); defer { lock.unlock() }; return seconds }
    var sourceOrigin: Double? { lock.lock(); defer { lock.unlock() }; return origin }
    func resetCaptureClock() { lock.lock(); seconds = 0; origin = nil; lock.unlock() }
    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = next
    }
    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { origin = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime }
        seconds += Double(buffer.frameLength) / buffer.format.sampleRate
        request?.append(buffer)
    }
}
