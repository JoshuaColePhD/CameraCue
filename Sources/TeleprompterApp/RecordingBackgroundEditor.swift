import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class RecordingBackgroundEditorModel: ObservableObject {
    @Published private(set) var source: RecordingBackgroundSource?
    @Published private(set) var preview: CGImage?
    @Published var background = CameraBackground()
    @Published private(set) var preparing = false
    @Published private(set) var exporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    private let recording: URL
    private var frame: CGImage?
    private var renderTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = 0
    private var exportToken: UUID?
    init(recording: URL) { self.recording = recording }
    var canExport: Bool { frame != nil && preview != nil && !preparing && !exporting && error == nil }
    func load() async {
        preparing = true; error = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) { [recording] in
                let source = RecordingBackgroundSource.resolve(recording)
                let asset = AVURLAsset(url: source.url)
                let duration = try await asset.load(.duration)
                guard duration.seconds.isFinite, duration.seconds > 0 else { throw RecordingFailure.message("This recording is empty.") }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1280, height: 1280)
                let (image, _) = try await generator.image(at: CMTime(seconds: min(1, duration.seconds / 3), preferredTimescale: 600))
                return (source, image)
            }.value
            guard !Task.isCancelled else { preparing = false; return }
            source = result.0; frame = result.1; preview = result.1; preparing = false
        } catch { preparing = false; self.error = "Could not preview this recording. " + error.localizedDescription }
    }
    func change(_ value: CameraBackground) {
        guard !exporting else { return }
        background = value; savedURL = nil; error = nil
        generation += 1; let current = generation
        renderTask?.cancel()
        guard let frame else { return }
        preparing = true
        renderTask = Task {
            do {
                let setting = value
                let result = try await Task.detached(priority: .userInitiated) {
                    if setting.mode == .original { return frame }
                    let processor = CameraBackgroundProcessor(offline: true)
                    try processor.configure(setting)
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(nil, frame.width, frame.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw RecordingFailure.message("Could not create the preview.") }
                    processor.context.render(CIImage(cgImage: frame), to: buffer)
                    let processed = try processor.process(buffer, time: 0)
                    guard let image = processor.context.createCGImage(CIImage(cvPixelBuffer: processed), from: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)) else { throw RecordingFailure.message("Could not render the preview.") }
                    return image
                }.value
                guard current == generation, !Task.isCancelled else { return }
                preview = result; preparing = false
            } catch { if current == generation { preparing = false; self.error = error.localizedDescription } }
        }
    }
    func upload() {
        guard !preparing, !exporting else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.allowsMultipleSelection = false; panel.prompt = "Use background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preparing = true; error = nil
        Task {
            do {
                let imported = try await Task.detached(priority: .utility) { try CameraBackground.importImage(url) }.value
                preparing = false
                var setting = background; setting.mode = .image; setting.image = "custom"; setting.customPath = imported.path
                change(setting)
            } catch { preparing = false; self.error = error.localizedDescription }
        }
    }
    func startExport() {
        guard canExport else { return }
        exporting = true; progress = 0; error = nil; savedURL = nil
        let input = recording, setting = background
        let token = UUID(); exportToken = token
        let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
            guard let owner = self else { return }
            Task { @MainActor in if owner.exportToken == token { owner.progress = value } }
        }
        exportTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try await VideoBackgroundExport.export(recording: input, background: setting, destination: VideoBackgroundExport.destination(for: input), progress: reportProgress)
            }
            do {
                let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                savedURL = output; progress = 1
            } catch is CancellationError { error = nil }
            catch { self.error = Task.isCancelled ? nil : "Export failed. Your recording is unchanged. " + error.localizedDescription }
            exporting = false; exportTask = nil; exportToken = nil
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func close() { generation += 1; renderTask?.cancel(); cancelExport() }
}

struct RecordingBackgroundEditor: View {
    @StateObject private var editor: RecordingBackgroundEditorModel
    var onDone: () -> Void
    var onExport: (URL) -> Void
    init(recording: URL, onDone: @escaping () -> Void, onExport: @escaping (URL) -> Void) {
        _editor = StateObject(wrappedValue: RecordingBackgroundEditorModel(recording: recording))
        self.onDone = onDone; self.onExport = onExport
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Change background").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Done") { onDone() }.buttonStyle(StudioButtonStyle()).disabled(editor.exporting).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        Color.black
                        if let image = editor.preview { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                        if editor.preparing { ProgressView("Preparing preview…").padding(12).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10)) }
                    }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Background preview frame")
                    Text(editor.source?.isCameraOriginal == true ? "Using your original camera video. You can also restore its real background." : "Using the recorded video. A previously applied background cannot restore the real room without an original copy.")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
                    BackgroundOptions(setting: editor.background, disabled: editor.preparing || editor.exporting, busy: editor.preparing,
                                      message: editor.error, detail: "Exports a new MP4 with the recorded audio. Your existing video stays unchanged.",
                                      originalLabel: editor.source?.isCameraOriginal == true ? "Original" : "Recorded", change: editor.change, upload: editor.upload)
                    if editor.exporting {
                        ProgressView(value: editor.progress).tint(StudioPalette.violet)
                        HStack {
                            Text("Exporting · \(Int(editor.progress * 100))%").font(.system(size: 12))
                            Spacer()
                            Button("Cancel export") { editor.cancelExport() }.buttonStyle(StudioButtonStyle())
                        }
                    }
                    if let url = editor.savedURL {
                        StudioStatusLabel(title: "New video saved", success: true)
                        Text(url.lastPathComponent).font(.system(size: 12)).textSelection(.enabled)
                        HStack {
                            Button("Play new video") { onExport(url) }.buttonStyle(StudioButtonStyle(primary: true))
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(StudioButtonStyle())
                        }
                    }
                }.padding(.trailing, 2)
            }.frame(maxHeight: 570)
            if editor.savedURL == nil {
                Button("Export new MP4") { editor.startExport() }.buttonStyle(StudioButtonStyle(primary: true)).disabled(!editor.canExport)
            }
        }.padding(24).frame(width: 640).background(StudioPalette.canvas).foregroundStyle(StudioPalette.ink)
            .task { await editor.load() }
            .onDisappear { editor.close() }
    }
}

struct RecordingReview: View {
    let url: URL
    var onDone: () -> Void
    var onChanged: () -> Void = {}
    @State private var editsBackground = false
    @State private var currentURL: URL?
    init(url: URL, initiallyEditing: Bool = false, onDone: @escaping () -> Void, onChanged: @escaping () -> Void = {}) {
        self.url = url; self.onDone = onDone; self.onChanged = onChanged
        _editsBackground = State(initialValue: initiallyEditing)
    }
    var body: some View {
        Group {
            if editsBackground {
                RecordingBackgroundEditor(recording: currentURL ?? url, onDone: { editsBackground = false; onChanged() }, onExport: { output in currentURL = output; editsBackground = false; onChanged() })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text((currentURL ?? url).deletingPathExtension().lastPathComponent).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                        Spacer()
                        Button("Done", action: onDone).buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                    }
                    SavedTakePlayer(url: currentURL ?? url)
                    HStack {
                        Button("Change background") { editsBackground = true }.buttonStyle(StudioButtonStyle(primary: true))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([currentURL ?? url]) }.buttonStyle(StudioButtonStyle())
                    }
                }.padding(24).frame(width: 700).background(StudioPalette.canvas).foregroundStyle(StudioPalette.ink)
            }
        }
    }
}
