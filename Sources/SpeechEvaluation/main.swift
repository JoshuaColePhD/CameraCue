import Foundation
import AppKit
import Speech
import CameraCueSpeech
import TeleprompterCore

@MainActor final class PermissionCompletion {
    private var continuation: CheckedContinuation<Int, Never>?
    init(_ continuation: CheckedContinuation<Int, Never>) { self.continuation = continuation }
    func finish(_ status: Int) { continuation?.resume(returning: status); continuation = nil }
}

struct ClipResult: Codable {
    let clipID: String
    let speakerID: String
    let split: String
    let engine: SpeechEngineID
    let wordErrors: WordErrorCounts?
    let tracking: AudioTrackingMetrics?
    var exactSuffixTracking: AudioTrackingMetrics? = nil
    let duration: Double
    let processingSeconds: Double?
    let error: String?
}
struct EvaluationReport: Codable {
    var schemaVersion = 2
    let corpusVersion: String
    let mode: String
    let analyzerFastResults: Bool
    let results: [ClipResult]
}
    struct TrainingRow: Codable {
        let speakerID: String; let split: String; let clipID: String
        let variant: Int; let step: Int; let transcript: String; let scriptTokenCount: Int
        let features: [Double]?; let label: Int?; let truth: Int; let candidate: Int
    }
let args = Array(CommandLine.arguments.dropFirst())
@MainActor func argument(_ key: String) -> String? { guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }; return args[index + 1] }
do {
guard let path = argument("--manifest") else {
    print("Usage: SpeechEvaluation --manifest corpus.json [--engine analyzer|legacy|both] [--realtime] [--download-model] [--authorize] [--output report.json]")
    exit(2)
}
let manifestURL = URL(fileURLWithPath: path)
let manifest = try JSONDecoder().decode(SpeechCorpusManifest.self, from: Data(contentsOf: manifestURL))
try manifest.validate()
if let rowsPath = argument("--export-training-rows") {
    var examples: [TrainingRow] = []
    // Reference-derived simulations are labeled independently of recognition
    // timing. They are NOT actual ASR outputs or evidence of live accuracy.
    for clip in manifest.clips where !clip.id.contains("noise") {
        let script = ScriptDocument(clip.script)
        for variant in 0..<18 {
            let aligner = ScriptAligner(script: script)
            var transcript: [String] = []
            for index in script.tokens.indices {
                let token = script.tokens[index]
                if variant == 0 || (index + variant) % 11 != 0 { transcript.append((index + variant) % 13 == 0 && variant > 0 ? "unrelated" : token) }
                if variant >= 2 && index % 17 == 0 { transcript.append("uh") }
                if variant >= 3 && index % 23 == 0 { transcript.append(contentsOf: ["weather", "outside", "today"]) }
                guard index % 2 == 1 else { continue }
                let spoken: String
                var truth = index
                if variant >= 12 && index > 30 && index % 30 < 12 {
                    truth = max(0, index - 20)
                    spoken = script.tokens[max(0, truth - 11)...truth].joined(separator: " ")
                } else if variant >= 6 && variant < 12 && index > 20 && index % 18 < 4 {
                    // Spurious recognition of an earlier phrase while the true
                    // speaker continues forward. This is a simulated error.
                    spoken = script.tokens.prefix(5).joined(separator: " ") + (index % 2 == 1 ? " uh" : "")
                } else { spoken = transcript.suffix(12).joined(separator: " ") }
                _ = aligner.align(spoken)
                if let candidate = aligner.lastCandidate {
                    let correct = abs(candidate.tokenIndex - truth) <= 2
                    let label = !correct ? 1 : abs(candidate.tokenIndex - candidate.positionBefore) > 8 ? 2 : 0
                    examples.append(TrainingRow(speakerID: clip.speakerID, split: clip.split, clipID: clip.id, variant: variant, step: index, transcript: spoken, scriptTokenCount: script.tokens.count, features: candidate.features,
                                               label: label, truth: truth, candidate: candidate.tokenIndex))
                } else {
                    // Keep no-candidate observations in the sequential replay;
                    // only classifier training omits their absent features.
                    examples.append(TrainingRow(speakerID: clip.speakerID, split: clip.split, clipID: clip.id, variant: variant, step: index,
                                               transcript: spoken, scriptTokenCount: script.tokens.count, features: nil, label: nil,
                                               truth: truth, candidate: aligner.position))
                }
            }
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(examples).write(to: URL(fileURLWithPath: rowsPath), options: .atomic)
    print("Exported \(examples.count) transcript-derived simulation rows; not real ASR or manually reviewed timing.")
    exit(0)
}
if let replay = argument("--replay-training-rows"), let modelPath = argument("--decision-model") {
    let model = try JSONDecoder().decode(AlignmentDecisionModel.self, from: Data(contentsOf: URL(fileURLWithPath: modelPath)))
    guard model.isValid else { throw SpeechSessionError.audioFormat }
    let rows = try JSONDecoder().decode([TrainingRow].self, from: Data(contentsOf: URL(fileURLWithPath: replay)))
    struct Comparison: Codable { var observations = 0; var baselineWithinTwo = 0; var learnedWithinTwo = 0; var baselineWrongJumps = 0; var learnedWrongJumps = 0 }
    var comparisons: [String: Comparison] = [:]
    for group in Dictionary(grouping: rows, by: { "\($0.clipID)-\($0.variant)" }).values {
        guard let first = group.first, let clip = manifest.clips.first(where: { $0.id == first.clipID }) else { continue }
        let base = ScriptAligner(script: ScriptDocument(clip.script)), learned = ScriptAligner(script: ScriptDocument(clip.script), decisionModel: model)
        var score = comparisons[first.split] ?? Comparison()
        for row in group.sorted(by: { $0.step < $1.step }) {
            let bp = base.position, lp = learned.position
            let b = base.align(row.transcript), l = learned.align(row.transcript)
            score.observations += 1
            if abs(b.tokenIndex - row.truth) <= 2 { score.baselineWithinTwo += 1 }
            if abs(l.tokenIndex - row.truth) <= 2 { score.learnedWithinTwo += 1 }
            if abs(b.tokenIndex - bp) > 8 && abs(b.tokenIndex - row.truth) > 5 { score.baselineWrongJumps += 1 }
            if abs(l.tokenIndex - lp) > 8 && abs(l.tokenIndex - row.truth) > 5 { score.learnedWrongJumps += 1 }
        }
        comparisons[first.split] = score
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(comparisons)
    if let output = argument("--output") { try data.write(to: URL(fileURLWithPath: output)) }
    print(String(decoding: data, as: UTF8.self))
    if let gate = argument("--check-model") {
        let previous = try JSONDecoder().decode([String: Comparison].self, from: Data(contentsOf: URL(fileURLWithPath: gate)))
        for (split, reference) in previous {
            guard let score = comparisons[split], score.observations == reference.observations,
                  score.learnedWithinTwo >= reference.learnedWithinTwo, score.learnedWrongJumps <= reference.learnedWrongJumps else {
                print("Learned tracking regression: " + split); exit(1)
            }
        }
    }
    exit(0)
}
if let destination = argument("--pace-evaluate") {
    struct Forecast: Codable { let clipID: String; let speakerID: String; let split: String; let atSeconds: Double; let actualRemaining: Double; let predictedRemaining: Double; let baselineRemaining: Double; let usesPersonalHistory: Bool }
    var forecasts: [Forecast] = []
    for clips in Dictionary(grouping: manifest.clips.filter { !$0.id.contains("noise") }, by: \.speakerID).values {
        var profile = PersonalPaceProfile()
        for clip in clips.sorted(by: { $0.id < $1.id }) {
            var tracker = PersonalPaceTracker(), lastForecast = 0.0
            let words = clip.referenceWords.flatMap { word in TranscriptNormalizer.tokens(word.text).map { _ in word } }
            guard let end = words.last?.end else { continue }
            for (index, word) in words.enumerated() {
                tracker.observe(position: index, activeElapsed: word.end, reliable: true)
                if word.end >= 8, word.end - lastForecast >= 3, word.end < end - 1,
                   let estimate = tracker.estimate(remainingWords: words.count - index - 1, profile: profile) {
                    forecasts.append(Forecast(clipID: clip.id, speakerID: clip.speakerID, split: clip.split, atSeconds: word.end,
                                              actualRemaining: end - word.end, predictedRemaining: estimate.remainingSeconds,
                                              baselineRemaining: Double(words.count - index - 1) * 60 / 150, usesPersonalHistory: estimate.usesPersonalHistory))
                    lastForecast = word.end
                }
            }
            if let sample = tracker.sample(activeSeconds: end, at: .distantPast) { profile.record(sample) }
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(forecasts).write(to: URL(fileURLWithPath: destination)); print("Forecasts use reference positions and forced-aligned timing, not live ASR."); exit(0)
}
var permissionWindow: NSWindow?
if Bundle.main.bundleURL.pathExtension == "app" {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.finishLaunching()
}
let authorizationRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
if args.contains("--authorize"), SFSpeechRecognizer.authorizationStatus() == .notDetermined {
    if Bundle.main.bundleURL.pathExtension == "app" {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 130), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CameraCue Speech Evaluation"
        window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Waiting for Speech Recognition access to compare selected public audio files on this Mac. This helper never opens your microphone.")
        label.frame = CGRect(x: 24, y: 28, width: 412, height: 70)
        window.contentView?.addSubview(label); window.center(); window.makeKeyAndOrderFront(nil)
        permissionWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    print("Requesting file-only Speech Recognition access for " + (Bundle.main.bundleIdentifier ?? "unidentified executable"))
    fflush(nil)
    let status = await withCheckedContinuation { continuation in
        let completion = PermissionCompletion(continuation)
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            let value = status.rawValue
            Task { @MainActor in completion.finish(value) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            completion.finish(SFSpeechRecognizer.authorizationStatus().rawValue)
        }
    }
    permissionWindow?.close(); permissionWindow = nil
    print("Speech permission status: \(status)"); fflush(nil)
}
let evaluationModel: AlignmentDecisionModel?
if let modelPath = argument("--decision-model") {
    let model = try JSONDecoder().decode(AlignmentDecisionModel.self, from: Data(contentsOf: URL(fileURLWithPath: modelPath)))
    guard model.isValid else { throw SpeechSessionError.audioFormat }; evaluationModel = model
} else { evaluationModel = nil }
let selection = argument("--engine") ?? "both"
guard ["analyzer", "legacy", "both"].contains(selection) else { print("Unknown engine"); exit(2) }
let engines: [SpeechEngineID] = selection == "both" ? [.legacy, .analyzer] : [SpeechEngineID(rawValue: selection)!]
let output = argument("--output") ?? "ReviewArtifacts/MLCorpus/results.json"
let realtime = args.contains("--realtime")
var rows: [ClipResult] = []
for clip in manifest.clips {
    let audio = manifestURL.deletingLastPathComponent().appendingPathComponent(clip.audioPath)
    for engine in engines {
        print("Evaluating \(clip.id) · \(clip.split) · \(engine.rawValue) · \(realtime ? "1x playback" : "offline")")
        fflush(nil)
        do {
            let result: FileSpeechResult
            if let replayDirectory = argument("--replay-directory") {
                let file = URL(fileURLWithPath: replayDirectory).appendingPathComponent("\(clip.id)-\(engine.rawValue)-trace.json")
                result = try JSONDecoder().decode(FileSpeechResult.self, from: Data(contentsOf: file))
                guard result.engine == engine, result.realtime == realtime else { throw SpeechSessionError.audioFormat }
            } else {
                result = try await SpeechFileTranscriber.transcribe(url: audio, engine: engine, realtime: realtime, allowModelDownload: args.contains("--download-model"), fastResults: args.contains("--fast-results"))
            }
            let wordErrors = WordErrorCounts.compare(reference: TranscriptNormalizer.tokens(clip.script), recognized: TranscriptNormalizer.tokens(result.text))
            let metrics = AudioTrackingMetrics.measure(script: clip.script, reference: clip.referenceWords, observations: result.observations, realtime: realtime, decisionModel: evaluationModel)
            rows.append(ClipResult(clipID: clip.id, speakerID: clip.speakerID, split: clip.split, engine: engine, wordErrors: wordErrors, tracking: metrics, exactSuffixTracking: AudioTrackingMetrics.measure(script: clip.script, reference: clip.referenceWords, observations: result.observations, realtime: realtime, exactSuffixBaseline: true),
                                   duration: result.audioDuration, processingSeconds: result.elapsedSeconds, error: nil))
            let trace = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("\(clip.id)-\(engine.rawValue)-trace.json")
            try FileManager.default.createDirectory(at: trace.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: trace, options: .atomic)
            print(String(format: "WER %.1f%% · within-two %.1f%% · wrong jumps %d", wordErrors.rate * 100, metrics.withinTwoTokens * 100, metrics.wrongJumps))
        } catch {
            rows.append(ClipResult(clipID: clip.id, speakerID: clip.speakerID, split: clip.split, engine: engine, wordErrors: nil, tracking: nil, duration: clip.duration, processingSeconds: nil, error: error.localizedDescription))
            print("Unavailable/failed: \(error.localizedDescription)")
        }
    }
}
let report = EvaluationReport(corpusVersion: manifest.version, mode: realtime ? "realtime" : "offline", analyzerFastResults: args.contains("--fast-results"), results: rows)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let destination = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(report).write(to: destination, options: .atomic)
if rows.contains(where: { $0.error != nil }) { exit(1) }

} catch {
    print("Evaluation failed: " + String(describing: error))
    exit(2)
}
