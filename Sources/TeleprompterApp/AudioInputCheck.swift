import AppKit
import AVFoundation
import CoreAudio

/// A user-started level check. It never records, transcribes, or saves audio.
@MainActor final class AudioInputCheck: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var level: Double = 0
    @Published private(set) var message = "Check your microphone before a take."
    @Published private(set) var deviceName = AudioInputCheck.defaultInputName()
    private var engine: AVAudioEngine?
    private var timer: Timer?
    private let meter = InputLevelMeter()
    private var generation = 0
    func start(onPermissionPrompt: (Bool) -> Void = { _ in }) async {
        guard !isChecking, !isPreparing else { return }
        generation += 1
        let current = generation
        isPreparing = true
        defer { isPreparing = false }
        deviceName = Self.defaultInputName()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            onPermissionPrompt(true)
            _ = await PermissionRequest.wait { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }
            onPermissionPrompt(false)
        }
        guard generation == current, !Task.isCancelled else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            message = "Allow CameraCue Studio in System Settings → Privacy & Security → Microphone to check the input."
            return
        }
        do {
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "AudioInput", code: 1) }
            let meter = meter
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in meter.measure(buffer) }
            self.engine = engine
            try engine.start()
            isChecking = true; message = "Speak a few words. This check does not save audio."
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.engine?.isRunning != true { self.stop(); self.message = "Input changed. Check the microphone and try again."; return }
                    self.level = self.meter.value
                }
            }
        } catch { stop(); message = "Microphone unavailable. Check the input in macOS Sound settings." }
    }
    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil; isChecking = false; level = 0
    }
    static func defaultInputName() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return "No input device" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "System default microphone" }
        return name?.takeRetainedValue() as String? ?? "System default microphone"
    }
}
final class InputLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return latest }
    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += channel[index] * channel[index] }
        let rms = sqrt(Double(energy) / Double(buffer.frameLength))
        let normalized = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 55))
        lock.lock(); latest = normalized; lock.unlock()
    }
}
