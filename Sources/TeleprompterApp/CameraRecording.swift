import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

struct RecordingDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

protocol MovieCapturing: AnyObject {
    @MainActor var session: AVCaptureSession? { get }
    @MainActor var onUnexpectedFinish: ((URL?, String?) -> Void)? { get set }
    @MainActor func prepare(camera: String?, microphone: String?) async throws
    @MainActor func start(to url: URL) async throws
    @MainActor func finish() async throws -> URL
    @MainActor func originalRecording() async -> URL?
    @MainActor func closePreview()
}

extension MovieCapturing {
    @MainActor func originalRecording() async -> URL? { nil }
}

enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor final class CameraRecording: ObservableObject {
    enum State: Equatable { case idle, preparing, ready, recording, saving, saved, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var message = "Record yourself and save an MP4 with your take."
    @Published private(set) var savedURL: URL?
    @Published private(set) var saveNotice: String?
    @Published private(set) var originalSavedURL: URL?
    @Published var keepOriginalVideo: Bool { didSet { defaults?.set(keepOriginalVideo, forKey: "keepOriginalCameraVideo") } }
    @Published private(set) var recoveryURL: URL?
    @Published private(set) var cameras: [RecordingDevice] = []
    @Published private(set) var microphones: [RecordingDevice] = []
    @Published var cameraID = "" { didSet { defaults?.set(cameraID, forKey: "recordingCamera"); invalidatePreview() } }
    @Published var microphoneID = "" { didSet { defaults?.set(microphoneID, forKey: "recordingMicrophone"); invalidatePreview() } }
    @Published var enabled: Bool { didSet { defaults?.set(enabled, forKey: "recordCameraVideo"); if !enabled { closePreview() } } }
    @Published private(set) var background: CameraBackground
    @Published private(set) var backgroundMessage: String?
    @Published private(set) var changingBackground = false
    @Published private(set) var folder: URL
    var onPermissionPromptChanged: ((Bool) -> Void)?
    var onInterrupted: (() -> Void)?
    var onSaved: ((URL) -> Void)?
    private let backend: any MovieCapturing
    private let defaults: UserDefaults?
    private let authorize: () async -> Bool
    private let systemPermissions: Bool
    private let export: (URL, URL) async throws -> Void
    private var generation = 0
    private var destination: URL?
    private var takeBackground = CameraBackground()
    private var takeKeepOriginal = false
    private var saveTask: Task<Void, Never>?
    private var sleepObserver: NotificationRegistration?
    var session: AVCaptureSession? { backend.session }
    var previewFrames: CameraPreviewFrames? { (backend as? NativeMovieCapture)?.previewFrames }
    func recordingAudioLevel() async -> Double {
        guard isRecording, let native = backend as? NativeMovieCapture else { return 0 }
        return await native.audioLevel()
    }
    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .preparing || state == .recording || state == .saving }
    var canStart: Bool { !changingBackground && state != .saving && state != .preparing && state != .recording }

    init(backend: (any MovieCapturing)? = nil, defaults: UserDefaults? = .standard, folder: URL? = nil,
         authorize: (() async -> Bool)? = nil, export: ((URL, URL) async throws -> Void)? = nil) {
        self.backend = backend ?? NativeMovieCapture()
        self.defaults = defaults
        self.background = defaults?.data(forKey: "cameraBackground").flatMap { try? JSONDecoder().decode(CameraBackground.self, from: $0) } ?? CameraBackground()
        self.keepOriginalVideo = defaults?.object(forKey: "keepOriginalCameraVideo") as? Bool ?? true
        self.enabled = defaults?.object(forKey: "recordCameraVideo") as? Bool ?? (defaults != nil)
        self.folder = folder ?? defaults?.url(forKey: "recordingFolder") ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CameraCue", isDirectory: true)
        self.cameraID = defaults?.string(forKey: "recordingCamera") ?? ""
        self.microphoneID = defaults?.string(forKey: "recordingMicrophone") ?? ""
        self.systemPermissions = authorize == nil
        self.authorize = authorize ?? { false }
        self.export = export ?? Self.exportMP4
        sleepObserver = NotificationRegistration(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording { self.onInterrupted?(); self.finish() }
                else { self.closePreview() }
            }
        }
        (self.backend as? NativeMovieCapture)?.onStreamFailure = { [weak self] reason in
            guard let self, self.state == .ready else { return }; self.state = .failed; self.message = reason
        }
        self.backend.onUnexpectedFinish = { [weak self] source, reason in
            guard let self, self.state == .recording else { return }
            self.state = source == nil ? .failed : .saving
            self.onInterrupted?()
            if let source { self.save(source) }
            else { self.message = reason ?? "Recording stopped unexpectedly."; self.recoveryURL = self.destination?.deletingPathExtension().appendingPathExtension("mov") }
        }
    }
    // Observer token cleanup is independent of the main-actor lifetime.
    deinit {}
    func changeBackground(_ setting: CameraBackground) async {
        guard !isBusy, !changingBackground else { return }
        changingBackground = true; backgroundMessage = nil
        defer { changingBackground = false }
        do {
            if let native = backend as? NativeMovieCapture { try await native.setBackground(setting) }
            background = setting
            defaults?.set(try JSONEncoder().encode(setting), forKey: "cameraBackground")
        } catch { backgroundMessage = error.localizedDescription }
    }
    func chooseBackgroundImage() {
        guard !isBusy, !changingBackground else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.allowsMultipleSelection = false
        panel.prompt = "Use background"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            changingBackground = true; backgroundMessage = nil
            do {
                let imported = try await Task.detached(priority: .utility) {
                    try CameraBackground.importImage(source)
                }.value
                changingBackground = false
                var setting = background; setting.mode = .image; setting.image = "custom"; setting.customPath = imported.path
                await changeBackground(setting)
            } catch { changingBackground = false; backgroundMessage = error.localizedDescription }
        }
    }
    func refreshDevices() {
        cameras = NativeMovieCapture.devices(.video).map { RecordingDevice(id: $0.uniqueID, name: $0.localizedName) }
        microphones = NativeMovieCapture.devices(.audio).map { RecordingDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
    func prepare() async -> Bool {
        if state == .ready { return !changingBackground }
        guard canStart else { return false }
        generation += 1; let current = generation
        state = .preparing; message = "Preparing your camera…"
        let needsPrompt = systemPermissions && [.video, .audio].contains { AVCaptureDevice.authorizationStatus(for: $0) == .notDetermined }
        if needsPrompt { onPermissionPromptChanged?(true); NSApp.activate(ignoringOtherApps: true) }
        var allowed = true
        if systemPermissions {
            for type: AVMediaType in [.video, .audio] {
                guard current == generation, !Task.isCancelled else { allowed = false; break }
                if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                    guard await AVCaptureDevice.requestAccess(for: type) else { allowed = false; break }
                }
                guard current == generation, !Task.isCancelled, AVCaptureDevice.authorizationStatus(for: type) == .authorized else { allowed = false; break }
            }
        } else { allowed = await authorize() }
        if needsPrompt { onPermissionPromptChanged?(false) }
        guard current == generation else { return false }
        guard allowed else { state = .failed; message = "Allow Camera and Microphone in System Settings to record video."; return false }
        do {
            if let native = backend as? NativeMovieCapture { try await native.setBackground(background); await native.setKeepOriginal(keepOriginalVideo) }
            try await backend.prepare(camera: cameraID.isEmpty ? nil : cameraID, microphone: microphoneID.isEmpty ? nil : microphoneID)
            guard current == generation else { backend.closePreview(); return false }
            state = .ready; message = "Camera ready · Video includes microphone audio."
            return true
        } catch { if current == generation { state = .failed; message = error.localizedDescription }; return false }
    }
    func start(title: String) async -> Bool {
        guard state == .ready, !changingBackground else { return false }
        generation += 1; let current = generation
        state = .preparing; savedURL = nil; originalSavedURL = nil; saveNotice = nil; recoveryURL = nil
        takeBackground = background; takeKeepOriginal = keepOriginalVideo && background.mode != .original
        if let native = backend as? NativeMovieCapture { await native.setKeepOriginal(keepOriginalVideo) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Self.destination(folder: folder, title: title)
            destination = url
            try await backend.start(to: url.deletingPathExtension().appendingPathExtension("mov"))
            if current != generation { state = .recording; finish(); return false }
            state = .recording; message = "Recording video + audio · Pause only pauses prompting."
            return true
        } catch { state = .failed; message = error.localizedDescription; backend.closePreview(); return false }
    }
    func finish() {
        guard state == .recording else { if state == .preparing { closePreview() }; return }
        state = .saving; message = "Saving your MP4…"
        saveTask = Task {
            do { let source = try await backend.finish(); await exportSaved(source) }
            catch { state = .failed; message = error.localizedDescription; recoveryURL = destination?.deletingPathExtension().appendingPathExtension("mov") }
        }
    }
    private func save(_ source: URL) {
        state = .saving; message = "Recording stopped · Saving your MP4…"
        saveTask = Task { await exportSaved(source) }
    }
    private func exportSaved(_ source: URL) async {
        guard let destination else { state = .failed; message = "Recording destination was lost."; recoveryURL = source; return }
        recoveryURL = source
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            state = .failed; message = "The MP4 destination already exists. Your original MOV is kept."; return
        }
        do {
            try await export(source, destination)
            guard FileManager.default.fileExists(atPath: destination.path) else { throw RecordingFailure.message("The video export did not create a file.") }
            var warning: String?
            if originalSavedURL == nil, let raw = await backend.originalRecording(), FileManager.default.fileExists(atPath: raw.path) {
                let rawMP4 = raw.deletingPathExtension().appendingPathExtension("mp4")
                let ownsOutput = !FileManager.default.fileExists(atPath: rawMP4.path)
                do {
                    guard ownsOutput else { throw RecordingFailure.message("Original destination already exists.") }
                    try await export(raw, rawMP4)
                    guard FileManager.default.fileExists(atPath: rawMP4.path) else { throw RecordingFailure.message("Original export did not create a file.") }
                    originalSavedURL = rawMP4; try? FileManager.default.removeItem(at: raw)
                } catch { if ownsOutput { try? FileManager.default.removeItem(at: rawMP4) }; originalSavedURL = raw; warning = "Original kept as MOV." }
            } else if takeKeepOriginal && originalSavedURL == nil { warning = "The original copy was not saved; this video keeps its applied background." }
            let relative = originalSavedURL.map { ".Originals/" + $0.lastPathComponent }
            let metadata = RecordingBackgroundMetadata(background: takeBackground, originalRelativePath: relative, originalIsCameraSource: originalSavedURL != nil || takeBackground.mode == .original)
            do { try metadata.write(for: destination) } catch { warning = "Video saved, but original-link metadata could not be saved." }
            saveNotice = warning
            rememberFolder(destination.deletingLastPathComponent()); savedURL = destination; recoveryURL = nil; state = .saved; onSaved?(destination); message = "Recording saved · \(destination.lastPathComponent)" + (warning.map { " · " + $0 } ?? "")
            try? FileManager.default.removeItem(at: source)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            state = .failed; message = "MP4 export failed. Your original MOV is kept. \(error.localizedDescription)"
        }
    }
    func retrySave() { guard state == .failed, let recoveryURL else { return }; save(recoveryURL) }
    func waitUntilSaved() async { await saveTask?.value }
    func closePreview() {
        guard state != .recording && state != .saving else { return }
        generation += 1; backend.closePreview()
        if state == .preparing || state == .ready { state = .idle; message = "Camera preview is off." }
    }
    private func invalidatePreview() { if !isBusy { closePreview() } }
    var recordingFolders: [URL] {
        let defaultFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CameraCue", isDirectory: true)
        let previous = (defaults?.stringArray(forKey: "recordingFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return Array(Set(previous + [folder, defaultFolder]))
    }
    private func rememberFolder(_ url: URL) {
        let paths = Set(recordingFolders.map(\.path) + [url.path])
        defaults?.set(Array(paths).sorted(), forKey: "recordingFolders")
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save recordings here"; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { rememberFolder(folder); folder = url; rememberFolder(url); defaults?.set(url, forKey: "recordingFolder") }
    }
    static func destination(folder: URL, title: String, date: Date = Date(), id: UUID = UUID()) -> URL {
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = String(safe.isEmpty ? "CameraCue" : safe.prefix(80))
        return folder.appendingPathComponent("\(name) \(formatter.string(from: date)) \(id.uuidString.prefix(12)).mp4")
    }
    static func exportMP4(_ source: URL, _ destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mp4)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality) else {
            throw RecordingFailure.message("Could not prepare an MP4 export.")
        }
        try await exporter.export(to: destination, as: .mp4)
    }
}

// Preview connection changes and session start/stop share one queue. Retain the
// layer until it is detached there: deallocation on the UI thread can otherwise
// wait for stopRunning while stopRunning waits for a main-thread callback.
enum CameraSessionWork {
    static let queue = DispatchQueue(label: "CameraCue.movie-capture")
}

// Immutable transport reference. Session work and preview connection updates
// are confined to CameraSessionWork.queue; no session operation runs here.
private final class QueuedCameraSession: @unchecked Sendable {
    let value: AVCaptureSession?
    init(_ value: AVCaptureSession?) { self.value = value }
}

final class CameraPreviewLayerReference: @unchecked Sendable {
    let layer: AVCaptureVideoPreviewLayer
    init(_ layer: AVCaptureVideoPreviewLayer) { self.layer = layer }
    func connect(_ session: AVCaptureSession?) {
        let reference = QueuedCameraSession(session)
        CameraSessionWork.queue.async { [self] in
            layer.session = reference.value
            if let connection = layer.connection {
                CameraMirroring.apply(to: connection, mirrored: true)
            }
        }
    }
}

final class CameraPreviewView: NSView {
    let preview = CameraPreviewLayerReference(AVCaptureVideoPreviewLayer())
    private var connectedSession: AVCaptureSession?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.layer.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview.layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.layer.frame = bounds
        CATransaction.commit()
    }
    func connect(_ session: AVCaptureSession?) {
        guard connectedSession !== session else { return }
        connectedSession = session
        preview.connect(session)
    }
    func disconnect() {
        connectedSession = nil
        // This queued closure keeps the layer alive beyond the view's removal.
        preview.connect(nil)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(frame: .zero) }
    func updateNSView(_ view: CameraPreviewView, context: Context) { view.connect(session) }
    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) { view.disconnect() }
}
