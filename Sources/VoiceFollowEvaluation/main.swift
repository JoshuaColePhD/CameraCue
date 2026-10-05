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
    let lagSamples: Int
    let unavailableLagSamples: Int
    let lagP95Seconds: Double
    let alignmentP95Milliseconds: Double
}
struct Report: Codable {
    var schemaVersion = 1
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
                         recoverySeconds: recovery, recoveryAttempted: attempted, lagSamples: lags.count, unavailableLagSamples: count - lags.count, lagP95Seconds: percentile(lags, 0.95), alignmentP95Milliseconds: percentile(latencies, 0.95))
}

let args = Array(CommandLine.arguments.dropFirst())
@MainActor func argument(_ key: String) -> String? { guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }; return args[index + 1] }
let split = argument("--split")
if let split, !["development", "held-out"].contains(split) { print("Unknown split: " + split); exit(2) }
let cases = try ReplayCorpus.cases(split: split)
let algorithms = ["Exact suffix baseline", "Previous CameraCue", "CameraCue"]
let metrics = cases.flatMap { replay in algorithms.map { measure(replay, algorithm: $0) } }
let eventEncoder = JSONEncoder(); eventEncoder.outputFormatting = [.sortedKeys]
func corpusDigest(_ cases: [ReplayCase]) throws -> String {
    let text = try cases.map { "\($0.speech)|\($0.seed)|\($0.scenario)|\($0.document.source)|" + String(decoding: try eventEncoder.encode($0.events), as: UTF8.self) }.joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
let digest = try corpusDigest(cases)
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
    var failures: [String] = []
    for group in ["development", "held-out"] {
        let rows = metrics.filter { $0.split == group && $0.algorithm == "CameraCue" }
        guard !rows.isEmpty else { continue }
        let url = URL(fileURLWithPath: "docs/evaluation/\(group).json")
        let reference = try JSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        guard reference.corpusVersion == ReplayCorpus.version,
              reference.corpusSHA256 == (try corpusDigest(cases.filter { $0.split == group })) else {
            print("FAIL: corpus changed for \(group); review and version fixtures explicitly"); exit(1)
        }
        let expected = reference.cases.filter { $0.algorithm == "CameraCue" }
        if rows.count != expected.count { failures.append("\(group): case count changed") }
        for row in rows {
            let key = "\(group)/\(row.speech)/\(row.scenario)/\(row.seed)"
            guard let prior = expected.first(where: { $0.speech == row.speech && $0.scenario == row.scenario && $0.seed == row.seed }) else {
                failures.append(key + ": missing reference"); continue
            }
            if row.samples != prior.samples || row.withinTwo + 0.000001 < prior.withinTwo || row.meanAbsoluteError > prior.meanAbsoluteError + 0.000001 {
                failures.append(key + ": position accuracy regressed")
            }
            if row.wrongMoves > prior.wrongMoves || row.wrongJumps > prior.wrongJumps || row.holdViolations > prior.holdViolations {
                failures.append(key + ": unsafe movement regressed")
            }
            if let seconds = prior.recoverySeconds, row.recoverySeconds == nil || row.recoverySeconds! > seconds + 0.001 {
                failures.append(key + ": recovery regressed")
            }
            if row.unavailableLagSamples > prior.unavailableLagSamples || row.lagP95Seconds > prior.lagP95Seconds + 0.001 { failures.append(key + ": modeled highlight lag regressed") }
        }
    }
    if !failures.isEmpty { for failure in failures { print("FAIL: " + failure) }; exit(1) }
    print("Voice Follow per-case regression gates passed.")
}
