import Foundation
import CryptoKit
import TeleprompterCore

struct SampleMetrics: Codable {
    let algorithm: String
    let split: String
    let speech: String
    let scenario: String
    let seed: UInt64
    let samples: Int
    let withinTwo: Double
    let meanAbsoluteError: Double
    let wrongMoves: Int
    let wrongJumps: Int
    let holdViolations: Int
    let recoverySeconds: Double?
    let recoveryAttempted: Bool
    let lagP95Seconds: Double
    let alignmentP95Milliseconds: Double
}
struct Report: Encodable {
    let schemaVersion = 1
    let corpusVersion: String
    let corpusSHA256: String
    let scope: String
    let cases: [SampleMetrics]
}
func percentile(_ data: [Double], _ p: Double) -> Double {
    guard !data.isEmpty else { return 0 }; let sorted = data.sorted(); return sorted[Int((Double(sorted.count - 1) * p).rounded(.up))]
}

final class ExactSuffixBaseline {
    var position = 0
    let words: [String]
    init(_ words: [String]) { self.words = words }
    func align(_ text: String) -> Bool {
        let tokens = TranscriptNormalizer.tokens(text)
        guard tokens.count >= 3, words.count >= 3 else { return false }
        let suffix = Array(tokens.suffix(3))
        let endpoints = (2..<words.count).filter { Array(words[($0 - 2)...$0]) == suffix }
        guard let endpoint = endpoints.min(by: { abs($0 - position) < abs($1 - position) }) else { return false }
        position = endpoint; return true
    }
}
func measure(_ replay: ReplayCase, algorithm: String) -> SampleMetrics {
    let tuned = ScriptAligner(script: replay.document)
    let legacy = LegacyScriptAligner(script: replay.document)
    let exact = ExactSuffixBaseline(replay.document.tokens)
    var position = 0, count = 0, correct = 0, errorSum = 0
    var wrongMoves = 0, wrongJumps = 0, holds = 0
    var latencies: [Double] = [], lags: [Double] = []
    var recoveryBegin: Double?, recovery: Double?, attempted = false, consecutive = 0
    for event in replay.events {
        if event.recoveryStart { recoveryBegin = event.deliveredAt; attempted = true; consecutive = 0 }
        let prior = position
        let start = DispatchTime.now().uptimeNanoseconds
        let reliable: Bool
        switch algorithm {
        case "CameraCue": let result = tuned.align(event.transcript); position = result.tokenIndex; reliable = result.confidence != .low
        case "Previous CameraCue": let result = legacy.align(event.transcript); position = result.tokenIndex; reliable = result.confidence != .low
        default: reliable = exact.align(event.transcript); position = exact.position
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if event.mustHold && position != prior { holds += 1 }
        guard event.scored else { continue }
        let error = abs(position - event.truth)
        count += 1; correct += error <= 2 ? 1 : 0; errorSum += error; latencies.append(milliseconds)
        if position != prior && error > 5 {
            if ProcessInfo.processInfo.environment["VOICE_EVAL_TRACE"] == "1", algorithm == "CameraCue", replay.seed == 11 { print("TRACE", replay.speech, replay.scenario, prior, position, event.truth, String(event.transcript.suffix(100))) }
            wrongMoves += 1; if abs(position - prior) > 8 { wrongJumps += 1 } }
        if let timestamp = replay.wordTimes.last(where: { $0.index == position && $0.time <= event.spokenAt })?.time {
            lags.append(max(0, event.deliveredAt - timestamp))
        }
        if let begin = recoveryBegin, recovery == nil {
            consecutive = reliable && error <= 2 ? consecutive + 1 : 0
            if consecutive >= 2 { recovery = event.deliveredAt - begin }
        }
    }
    return SampleMetrics(algorithm: algorithm, split: replay.split, speech: replay.speech, scenario: replay.scenario, seed: replay.seed, samples: count,
                         withinTwo: Double(correct) / Double(max(count, 1)), meanAbsoluteError: Double(errorSum) / Double(max(count, 1)), wrongMoves: wrongMoves, wrongJumps: wrongJumps, holdViolations: holds,
                         recoverySeconds: recovery, recoveryAttempted: attempted, lagP95Seconds: percentile(lags, 0.95), alignmentP95Milliseconds: percentile(latencies, 0.95))
}

let args = Array(CommandLine.arguments.dropFirst())
@MainActor func argument(_ key: String) -> String? { guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }; return args[index + 1] }
let split = argument("--split")
let cases = try ReplayCorpus.cases(split: split)
let algorithms = ["Exact suffix baseline", "Previous CameraCue", "CameraCue"]
let metrics = cases.flatMap { replay in algorithms.map { measure(replay, algorithm: $0) } }
let eventEncoder = JSONEncoder(); eventEncoder.outputFormatting = [.sortedKeys]
let corpusText = try cases.map { "\($0.speech)|\($0.seed)|\($0.scenario)|\($0.document.source)|" + String(decoding: try eventEncoder.encode($0.events), as: UTF8.self) }.joined(separator: "\n")
let digest = SHA256.hash(data: Data(corpusText.utf8)).map { String(format: "%02x", $0) }.joined()
let report = Report(corpusVersion: ReplayCorpus.version, corpusSHA256: digest, scope: "Published transcripts with simulated ASR errors and timing; not measured microphone or recognizer accuracy.", cases: metrics)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let output = argument("--output") ?? "docs/evaluation/results.json"
try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
for group in ["development", "held-out"] {
    for algorithm in algorithms {
        let rows = metrics.filter { $0.split == group && $0.algorithm == algorithm }
        guard !rows.isEmpty else { continue }
        let n = Double(rows.reduce(0) { $0 + $1.samples })
        let accuracy = rows.reduce(0.0) { $0 + $1.withinTwo * Double($1.samples) } / n
        let jumps = rows.reduce(0) { $0 + $1.wrongJumps }
        let holds = rows.reduce(0) { $0 + $1.holdViolations }
        let recoveries = rows.filter(\.recoveryAttempted)
        let recovered = recoveries.compactMap(\.recoverySeconds)
        print("\(group) | \(algorithm) | within2=\(String(format: "%.2f", accuracy*100))% | wrongJumps=\(jumps) | holds=\(holds) | recovered=\(recovered.count)/\(recoveries.count) | recoveryP95=\(String(format: "%.2f", percentile(recovered, 0.95)))s")
    }
}
if args.contains("--check") {
    let thresholdsPath = argument("--thresholds") ?? "docs/evaluation/thresholds.json"
    let thresholds = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: thresholdsPath))) as! [String: Double]
    var failures: [String] = []
    for group in ["development", "held-out"] {
        let rows = metrics.filter { $0.split == group && $0.algorithm == "CameraCue" }
        guard !rows.isEmpty else { continue }
        let n = Double(rows.reduce(0) { $0 + $1.samples })
        let accuracy = rows.reduce(0.0) { $0 + $1.withinTwo * Double($1.samples) } / n
        if accuracy < thresholds[group + "MinWithinTwo"]! { failures.append("\(group): tracking accuracy regressed") }
        if Double(rows.reduce(0) { $0 + $1.wrongJumps }) > thresholds[group + "MaxWrongJumps"]! { failures.append("\(group): wrong jumps regressed") }
        if Double(rows.reduce(0) { $0 + $1.holdViolations }) > thresholds[group + "MaxHoldViolations"]! { failures.append("\(group): hold behavior regressed") }
        let attempts = rows.filter(\.recoveryAttempted)
        if attempts.contains(where: { $0.recoverySeconds == nil }) { failures.append("\(group): failed to recover") }
        if percentile(attempts.compactMap(\.recoverySeconds), 0.95) > thresholds[group + "MaxRecoveryP95"]! { failures.append("\(group): recovery time regressed") }
    }
    if !failures.isEmpty { for failure in failures { print("FAIL: " + failure) }; exit(1) }
    print("Voice Follow regression gates passed.")
}
