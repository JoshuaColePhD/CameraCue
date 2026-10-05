import AVFoundation
import AppKit
import Speech
import Foundation

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
    var needsPrompt: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined ||
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
    var summary: String {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if speech == .denied || speech == .restricted || mic == .denied || mic == .restricted {
            return "Allow Microphone and Speech Recognition in System Settings."
        }
        return needsPrompt ? "Set up microphone and speech access before your take." : "Microphone and speech access ready"
    }
    func authorize(whileCurrent: () -> Bool) async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard whileCurrent(), speech == .authorized else { return false }
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
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
    private let permissions: any SpeechPermissionProviding
    private let captureOverride: (() throws -> Void)?
    private var tapInstalled = false
    private var recognitionGeneration = 0
    private var startupGeneration = 0
    private var consecutiveRecognitionErrors = 0
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init(permissions: (any SpeechPermissionProviding)? = nil, captureOverride: (() throws -> Void)? = nil) {
        self.permissions = permissions ?? SystemSpeechPermissions()
        self.captureOverride = captureOverride
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            // Only identity crosses to the main actor; the engine stays actor-owned.
            let changedEngineID = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, changedEngineID == ObjectIdentifier(self.engine), self.state == .listening, !self.engine.isRunning else { return }
                self.interrupt()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .listening || self.state == .requesting else { return }
                self.interrupt()
            }
        }
    }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    var readiness: String {
        if isAuthorizing { return "Waiting for microphone and speech access…" }
        if state == .interrupted { return "Audio input changed. Check your microphone, then resume prompting." }
        if state == .error { return "Audio stopped. Check your microphone, then resume prompting." }
        if recognizer?.isAvailable != true { return "Speech recognition is unavailable. You can use Manual mode." }
        return permissions.summary
    }
    var needsPermissionSetup: Bool { permissions.needsPrompt }
    func refreshReadiness() { objectWillChange.send() }

    func prepare() async { await begin(capture: false) }
    func start() async { await begin(capture: true) }

    private func begin(capture: Bool) async {
        guard state != .listening, !isAuthorizing else { return }
        startupGeneration += 1
        let generation = startupGeneration
        isAuthorizing = true
        state = .requesting
        let prompts = permissions.needsPrompt
        if prompts { onPermissionPromptChanged?(true); NSApp.activate(ignoringOtherApps: true) }
        defer {
            isAuthorizing = false
            if prompts { onPermissionPromptChanged?(false) }
        }
        let authorized = await permissions.authorize { [weak self] in self?.startupGeneration == generation }
        guard startupGeneration == generation else { return }
        if Task.isCancelled { stop(); return }
        guard authorized else { state = .denied; return }
        guard capture else { state = .idle; return }
        do {
            if let captureOverride { try captureOverride() }
            else {
                guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
                try startAudio(recognizer: recognizer)
            }
            state = .listening
        } catch {
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
        audioSink.set(nil)
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }
    private func startAudio(recognizer: SFSpeechRecognizer) throws {
        consecutiveRecognitionErrors = 0
        // A fresh engine picks up device or sample-rate changes after an interruption.
        engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "CameraCue", code: 1) }
        startRecognitionTask(recognizer: recognizer)
        let sink = audioSink
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
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
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration,
                      self.state == .listening || self.state == .requesting else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.consecutiveRecognitionErrors = 0
                    if self.state == .listening { self.onTranscript?(text) }
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
                            self.startRecognitionTask(recognizer: recognizer)
                        }
                    }
                } else if final && self.state == .listening { self.startRecognitionTask(recognizer: recognizer) }
            }
        }
    }
}

/// Audio buffers must be appended before Core Audio reuses them.
private final class AudioRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = next
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; request?.append(buffer)
    }
}
