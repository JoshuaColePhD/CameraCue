import AVFoundation
import CameraCueSpeech
import Speech
import SwiftUI
import TeleprompterCore

struct PlaybackSeekRequest: Equatable {
    let id = UUID()
    let seconds: Double
}

@MainActor final class RecordingCoachingModel: ObservableObject {
    @Published private(set) var analysis: RecordingSpeechAnalysis?
    @Published private(set) var report: TakeCoachingReport?
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    private var worker: Task<Void, Never>?
    private var generation = 0
    let url: URL
    init(url: URL) { self.url = url }
    func load() async {
        do {
            let value = try await Task.detached(priority: .utility) { [url] in try RecordingSpeechAnalysisStore.read(video: url) }.value
            guard !Task.isCancelled else { return }
            apply(value)
        } catch { self.error = "Could not read feedback. " + error.localizedDescription }
    }
    private func apply(_ value: RecordingSpeechAnalysis?) {
        analysis = value
        report = value.map { TakeCoachingReport.analyze(words: $0.words, script: $0.script) }
    }
    func analyze() {
        guard !busy else { return }
        generation += 1; let current = generation
        busy = true; progress = 0; error = nil
        let attachedScript = analysis?.script
        worker = Task {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                guard #available(macOS 26, *), await AnalyzerSpeechSession.supported() else {
                    throw RecordingFailure.message("Analyzing existing recordings requires the on-device speech engine on macOS 26 or later.")
                }
                try await RecordingAudioExtractor.extract(url, to: temporary)
                try Task.checkCancellation()
                let result = try await SpeechFileTranscriber.transcribe(url: temporary, engine: .analyzer, realtime: false, allowModelDownload: true, retainObservations: false, onProgress: { [weak self = self] value in
                    guard let self, self.generation == current else { return }; self.progress = value
                })
                try Task.checkCancellation()
                let value = RecordingSpeechAnalysis(videoFilename: url.lastPathComponent, analyzedAt: .now, engine: result.engine, words: result.words, script: attachedScript,
                                                    containsProvisionalWords: result.observations.last?.isFinal != true)
                guard generation == current else { return }
                try await Task.detached(priority: .utility) { [url] in try RecordingSpeechAnalysisStore.write(value, video: url) }.value
                guard generation == current, !Task.isCancelled else { return }
                apply(value); busy = false; worker = nil
            } catch {
                guard generation == current else { return }
                busy = false; worker = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation += 1; worker?.cancel(); worker = nil; busy = false }
    func remove() {
        guard !busy else { return }
        do {
            // Recoverable removal: put only the feedback sidecar in Trash.
            let path = RecordingSpeechAnalysisStore.sidecar(for: url)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.trashItem(at: path, resultingItemURL: nil) }
            apply(nil); error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct RecordingCoachingView: View {
    @StateObject private var model: RecordingCoachingModel
    let seek: (Double) -> Void
    init(url: URL, seek: @escaping (Double) -> Void) { _model = StateObject(wrappedValue: RecordingCoachingModel(url: url)); self.seek = seek }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review your delivery").font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.analysis?.containsProvisionalWords == true { Button("Refine transcript") { model.analyze() }.buttonStyle(StudioButtonStyle()).disabled(model.busy) }
                if model.analysis != nil { Button("Remove feedback") { model.remove() }.buttonStyle(StudioButtonStyle()).disabled(model.busy) }
            }
            Text("On-device speech estimates. Check each finding against playback; recognition mistakes can look like delivery mistakes.")
                .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
            if let analysis = model.analysis, analysis.containsProvisionalWords {
                Text("Some words were not finalized before Stop. Timing and wording may be approximate.").font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
            }
            if model.busy {
                ProgressView("Analyzing audio on this Mac…", value: model.progress)
                Button("Cancel analysis") { model.cancel() }.buttonStyle(StudioButtonStyle())
            }
            if let report = model.report {
                Text("\(report.words) recognized words · \(Int(report.wordsPerMinute)) words/min across recognized speech")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                if !report.scriptCompared { Text("No script is attached; wording comparisons are unavailable.").font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk) }
                if report.hasEstimatedTimings { Text("Some timestamps are estimated within a recognition segment.").font(.system(size: 12)) }
                if report.findings.isEmpty { Text("No delivery flags found. Listen back to decide what to improve.") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(report.findings) { finding in
                            Button { seek(finding.start) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(TakeSummary.time(finding.start)).monospacedDigit().frame(width: 52, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(finding.title).fontWeight(.semibold)
                                        Text(finding.excerpt).lineLimit(2)
                                        Text(finding.suggestion).font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "play.circle")
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel("Play at \(TakeSummary.time(finding.start)): \(finding.title)")
                        }
                    }
                }.frame(minHeight: 120, maxHeight: 220)
            } else if !model.busy {
                Text("Analyze this recording to find pacing changes, pauses, repeated phrases, and possible filler words. The transcript is saved beside the MP4; the video is unchanged.").font(.system(size: 14))
                Button("Analyze recording") { model.analyze() }.buttonStyle(StudioButtonStyle(primary: true))
            }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk) }
        }.foregroundStyle(StudioPalette.ink).task { await model.load() }.onDisappear { model.cancel() }
    }
}

@MainActor enum RecordingAudioExtractor {
    static func extract(_ video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 14_400 else { throw RecordingFailure.message("Select a recording shorter than four hours.") }
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw RecordingFailure.message("This recording has no usable audio.") }
        try await export.export(to: destination, as: .m4a)
    }
}
