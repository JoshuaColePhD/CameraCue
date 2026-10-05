import AppKit
import AVFoundation
import CoreImage

/// A bounded latest-frame mailbox. No per-frame ObservableObject/SwiftUI updates.
final class CameraPreviewFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var pending = false
    private var sinks: [UUID: (CVPixelBuffer) -> Void] = [:]
    @MainActor func attach(_ sink: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let id = UUID(); sinks[id] = sink; return id
    }
    @MainActor func detach(_ id: UUID) { sinks.removeValue(forKey: id) }
    func push(_ buffer: CVPixelBuffer) {
        lock.lock(); latest = buffer
        let schedule = !pending; pending = true; lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let frame = self.latest; self.latest = nil; self.pending = false; self.lock.unlock()
            if let frame { for sink in self.sinks.values { sink(frame) } }
        }
    }
}

/// Frame queue only. Preserves capture timestamps for A/V synchronization.
// Timestamp/counter state is confined to its producer queue. The encoder lock
// serializes cancellation with append/finalization operations.
final class ProcessedMovieWriter: @unchecked Sendable {
    private let encoderLock = NSLock()
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let includesAudio: Bool
    private var origin: CMTime?
    private var lastVideo: CMTime?
    private var lastAudio: CMTime?
    private(set) var writtenFrames = 0
    private(set) var droppedFrames = 0
    let url: URL
    init(url: URL, width: Int, height: Int, realtime: Bool = true, includeAudio: Bool = true, transform: CGAffineTransform = .identity) throws {
        self.url = url; includesAudio = includeAudio
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
        video.expectsMediaDataInRealTime = realtime; audio.expectsMediaDataInRealTime = realtime
        video.transform = transform
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecordingFailure.message("The camera format cannot be recorded.") }
        writer.add(video); if includeAudio { writer.add(audio) }
        guard writer.startWriting() else { throw writer.error ?? RecordingFailure.message("Could not start video encoding.") }
    }
    var isVideoReady: Bool { video.isReadyForMoreMediaData }
    var failure: Error? { writer.status == .failed ? writer.error ?? RecordingFailure.message("Video encoding failed.") : nil }
    func appendVideo(_ buffer: CVPixelBuffer, time: CMTime) throws -> Bool {
        encoderLock.lock(); defer { encoderLock.unlock() }
        guard time.isValid, time.isNumeric else { return false }
        if let lastVideo, CMTimeCompare(time, lastVideo) <= 0 { return false }
        if origin == nil { writer.startSession(atSourceTime: time); origin = time }
        try checkError()
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return false }
        guard pixels.append(buffer, withPresentationTime: time) else { throw writer.error ?? RecordingFailure.message("Could not encode a video frame.") }
        lastVideo = time; writtenFrames += 1; return true
    }
    func appendAudio(_ sample: CMSampleBuffer) throws {
        encoderLock.lock(); defer { encoderLock.unlock() }
        guard includesAudio else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let origin, CMTimeCompare(time, origin) >= 0, lastAudio == nil || CMTimeCompare(time, lastAudio!) > 0 else { return }
        try checkError()
        guard audio.isReadyForMoreMediaData else { return }
        guard audio.append(sample) else { throw writer.error ?? RecordingFailure.message("Could not encode microphone audio.") }
        lastAudio = time
    }
    private func checkError() throws {
        if writer.status == .failed { throw writer.error ?? RecordingFailure.message("Video recording failed.") }
    }
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        encoderLock.lock(); defer { encoderLock.unlock() }
        guard writtenFrames > 0 else { writer.cancelWriting(); completion(.failure(RecordingFailure.message("No camera frames arrived. Check the camera and try again."))); return }
        guard writer.status == .writing else { completion(.failure(writer.error ?? RecordingFailure.message("Video recording failed."))); return }
        video.markAsFinished(); if includesAudio { audio.markAsFinished() }
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? .success(url) : .failure(writer.error ?? RecordingFailure.message("Could not finish recording.")))
        }
    }
    func cancel() { encoderLock.lock(); defer { encoderLock.unlock() }; if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
}

/// Session configuration and frame processing use separate serial queues. Neither
/// queue synchronously waits on the main thread or on each other.
final class NativeMovieCapture: NSObject, MovieCapturing, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = CameraSessionWork.queue
    private let frames = DispatchQueue(label: "CameraCue.background-frames", qos: .userInitiated)
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let processor = CameraBackgroundProcessor()
    let previewFrames = CameraPreviewFrames()
    private var writer: CaptureMoviePair?
    private var ready: CheckedContinuation<Void, Error>?
    private var starting: CheckedContinuation<Void, Error>?
    private var finishing: CheckedContinuation<URL, Error>?
    private var completed: Result<URL, Error>?
    private var finalization: UUID?
    private var lastSize = CGSize.zero
    private var level = 0.0
    private var observing: [NSObjectProtocol] = []
    private var streamFailed = false
    private var keepOriginal = false
    private var hasEffect = false
    private var savedOriginal: URL?
    @MainActor var session: AVCaptureSession? { captureSession }
    @MainActor var onUnexpectedFinish: ((URL?, String?) -> Void)?
    override init() {
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observing.append(NotificationCenter.default.addObserver(forName: name, object: captureSession, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.frames.async { self.fail(RecordingFailure.message("Camera disconnected or was interrupted.")) }
            })
        }
    }
    deinit { observing.forEach(NotificationCenter.default.removeObserver) }
    @MainActor func setBackground(_ setting: CameraBackground) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            frames.async {
                guard self.writer == nil, self.finishing == nil, self.finalization == nil else { continuation.resume(throwing: RecordingFailure.message("Finish the take before changing backgrounds.")); return }
                do { try self.processor.configure(setting); self.hasEffect = setting.mode != .original; self.streamFailed = false; continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor func setKeepOriginal(_ keep: Bool) async {
        await withCheckedContinuation { continuation in frames.async { self.keepOriginal = keep; continuation.resume() } }
    }
    @MainActor func originalRecording() async -> URL? {
        await withCheckedContinuation { continuation in frames.async { continuation.resume(returning: self.savedOriginal) } }
    }
    @MainActor func prepare(camera: String?, microphone: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.captureSession.stopRunning()
                do {
                    self.captureSession.beginConfiguration()
                    do {
                        for input in self.captureSession.inputs { self.captureSession.removeInput(input) }
                        for output in self.captureSession.outputs { self.captureSession.removeOutput(output) }
                        self.captureSession.sessionPreset = .high
                        let video = camera == nil ? AVCaptureDevice.default(for: .video) : Self.devices(.video).first { $0.uniqueID == camera }
                        let audio = microphone == nil ? AVCaptureDevice.default(for: .audio) : Self.devices(.audio).first { $0.uniqueID == microphone }
                        guard let video, let audio else { throw RecordingFailure.message("The selected camera or microphone is unavailable.") }
                        for device in [video, audio] {
                            let input = try AVCaptureDeviceInput(device: device)
                            guard self.captureSession.canAddInput(input) else { throw RecordingFailure.message("Camera or microphone is busy. Close other recording apps and try again.") }
                            self.captureSession.addInput(input)
                        }
                        if self.captureSession.canSetSessionPreset(.hd1920x1080) { self.captureSession.sessionPreset = .hd1920x1080 }
                        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        self.videoOutput.alwaysDiscardsLateVideoFrames = true
                        self.videoOutput.setSampleBufferDelegate(self, queue: self.frames)
                        self.audioOutput.setSampleBufferDelegate(self, queue: self.frames)
                        for output: AVCaptureOutput in [self.videoOutput, self.audioOutput] {
                            guard self.captureSession.canAddOutput(output) else { throw RecordingFailure.message("Video processing is unavailable with these devices.") }
                            self.captureSession.addOutput(output)
                        }
                        if let connection = self.videoOutput.connection(with: .video) { CameraMirroring.apply(to: connection, mirrored: false) }
                        // Bound source rate, preserving support for unusual camera formats.
                        if video.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                            try video.lockForConfiguration()
                            video.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                            video.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                            video.unlockForConfiguration()
                        }
                        self.captureSession.commitConfiguration()
                    } catch { self.captureSession.commitConfiguration(); throw error }
                    self.frames.async {
                        self.ready = continuation; self.lastSize = .zero
                        self.frames.asyncAfter(deadline: .now() + 10) {
                            guard let ready = self.ready else { return }
                            self.ready = nil
                            ready.resume(throwing: RecordingFailure.message("No camera frames arrived. Check your camera and try again."))
                            self.queue.async { self.captureSession.stopRunning() }
                        }
                        self.queue.async { self.captureSession.startRunning() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor func start(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            frames.async {
                guard self.writer == nil, self.starting == nil, self.finishing == nil, self.finalization == nil, self.lastSize.width > 0, !self.streamFailed else {
                    continuation.resume(throwing: RecordingFailure.message("Camera frames are not ready. Preview the camera and try again.")); return
                }
                do {
                    let writer = try CaptureMoviePair(url: url, width: Int(self.lastSize.width), height: Int(self.lastSize.height), keepOriginal: self.keepOriginal && self.hasEffect)
                    self.writer = writer; self.savedOriginal = nil; self.completed = nil; self.starting = continuation
                    self.frames.asyncAfter(deadline: .now() + 10) {
                        guard self.writer === writer, self.starting != nil else { return }
                        self.fail(RecordingFailure.message("The camera did not start recording."))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            frames.async {
                if let completed = self.completed { continuation.resume(with: completed); return }
                guard self.writer != nil, self.finishing == nil else { continuation.resume(throwing: RecordingFailure.message("There is no video to save.")); return }
                self.finishing = continuation
                self.finishWriter(unexpected: false)
            }
        }
    }
    private func finishWriter(unexpected: Bool) {
        guard let writer else { return }
        self.writer = nil
        let token = UUID(); finalization = token
        frames.asyncAfter(deadline: .now() + 20) {
            guard self.finalization == token else { return }
            self.finalization = nil; writer.cancel()
            let error = RecordingFailure.message("Video encoding did not finish. The original MOV has been kept.")
            self.completed = .failure(error)
            self.finishing?.resume(throwing: error); self.finishing = nil
            self.queue.async { self.captureSession.stopRunning() }
            if unexpected { Task { @MainActor in self.onUnexpectedFinish?(nil, error.localizedDescription) } }
        }
        writer.finish { result in
            self.frames.async {
                guard self.finalization == token else { return }
                self.finalization = nil
                self.savedOriginal = writer.originalURL
                self.completed = result
                let pending = self.finishing; self.finishing = nil
                pending?.resume(with: result)
                self.queue.async { self.captureSession.stopRunning() }
                if unexpected {
                    Task { @MainActor in
                        switch result { case .success(let url): self.onUnexpectedFinish?(url, "Camera stopped unexpectedly."); case .failure(let error): self.onUnexpectedFinish?(nil, error.localizedDescription) }
                    }
                }
            }
        }
    }
    private func fail(_ error: Error) {
        streamFailed = true
        if let ready { self.ready = nil; ready.resume(throwing: error) }
        if let starting {
            self.starting = nil; writer?.cancel(); writer = nil; starting.resume(throwing: error)
            queue.async { self.captureSession.stopRunning() }
        } else if writer != nil { finishWriter(unexpected: true) }
        else {
            queue.async { self.captureSession.stopRunning() }
            Task { @MainActor in self.onStreamFailure?(error.localizedDescription) }
        }
    }
    @MainActor var onStreamFailure: ((String) -> Void)?
    @MainActor func closePreview() {
        frames.async {
            guard self.writer == nil, self.finishing == nil, self.finalization == nil else { return }
            self.lastSize = .zero
            if let ready = self.ready { self.ready = nil; ready.resume(throwing: CancellationError()) }
            self.queue.async { self.captureSession.stopRunning() }
        }
    }
    @MainActor func audioLevel() async -> Double {
        await withCheckedContinuation { continuation in frames.async { continuation.resume(returning: self.level) } }
    }
    static func normalizedAudioLevel(_ decibels: Double) -> Double { guard decibels.isFinite else { return 0 }; return min(1, max(0, (decibels + 60) / 60)) }
    static func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: type, position: .unspecified).devices
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !streamFailed else { return }
        autoreleasepool {
            do {
                if output === videoOutput, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let processed = try processor.process(buffer, time: time.seconds)
                    lastSize = CGSize(width: CVPixelBufferGetWidth(processed), height: CVPixelBufferGetHeight(processed))
                    previewFrames.push(processed)
                    if let ready { self.ready = nil; ready.resume() }
                    if let writer, try writer.appendVideo(processed, original: buffer, time: time), let starting { self.starting = nil; starting.resume() }
                } else if output === audioOutput {
                    level = connection.audioChannels.map { Self.normalizedAudioLevel(Double($0.averagePowerLevel)) }.max() ?? 0
                    try writer?.appendAudio(sampleBuffer)
                }
            } catch { fail(error) }
        }
    }
}

final class ProcessedCameraPreviewView: NSView {
    let display = AVSampleBufferDisplayLayer()
    private var hub: CameraPreviewFrames?
    private var subscription: UUID?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        display.videoGravity = .resizeAspectFill; layer?.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        display.frame = bounds; display.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)); CATransaction.commit()
    }
    @MainActor func connect(_ hub: CameraPreviewFrames?) {
        guard self.hub !== hub else { return }
        disconnect(); self.hub = hub
        subscription = hub?.attach { [weak self] buffer in self?.show(buffer) }
    }
    @MainActor func disconnect() { if let subscription { hub?.detach(subscription) }; subscription = nil; hub = nil; display.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    private func show(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }
        if display.sampleBufferRenderer.isReadyForMoreMediaData { display.sampleBufferRenderer.enqueue(sample) }
    }
}

import SwiftUI
struct ProcessedCameraPreview: NSViewRepresentable {
    let frames: CameraPreviewFrames?
    func makeNSView(context: Context) -> ProcessedCameraPreviewView { ProcessedCameraPreviewView(frame: .zero) }
    func updateNSView(_ view: ProcessedCameraPreviewView, context: Context) { view.connect(frames) }
    static func dismantleNSView(_ view: ProcessedCameraPreviewView, coordinator: ()) { view.disconnect() }
}
