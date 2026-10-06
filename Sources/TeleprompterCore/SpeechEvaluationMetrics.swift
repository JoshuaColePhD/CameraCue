import Foundation

public struct WordErrorCounts: Codable, Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceCount: Int
    public var rate: Double { Double(substitutions + deletions + insertions) / Double(max(1, referenceCount)) }
    public static func compare(reference: [String], recognized: [String]) -> Self {
        struct Cell { var cost = 0; var s = 0; var d = 0; var i = 0 }
        var row = (0...recognized.count).map { Cell(cost: $0, i: $0) }
        for (r, word) in reference.enumerated() {
            var next = Array(repeating: Cell(), count: recognized.count + 1)
            next[0] = Cell(cost: r + 1, d: r + 1)
            for j in recognized.indices.map({ $0 + 1 }) {
                var diagonal = row[j - 1]
                if word != recognized[j - 1] { diagonal.cost += 1; diagonal.s += 1 }
                var deletion = row[j]; deletion.cost += 1; deletion.d += 1
                var insertion = next[j - 1]; insertion.cost += 1; insertion.i += 1
                next[j] = [diagonal, deletion, insertion].min { $0.cost < $1.cost }!
            }
            row = next
        }
        let last = row.last!
        return Self(substitutions: last.s, deletions: last.d, insertions: last.i, referenceCount: reference.count)
    }
}
public struct AudioTrackingMetrics: Codable, Sendable {
    public var callbacks: Int
    public var withinTwoTokens: Double
    public var meanAbsoluteTokenError: Double
    public var wrongJumps: Int
    public var highlightAgeP95: Double?
    public var ageSampleCount: Int
    public var unavailableAgeSamples: Int
    public var recognizerDeliveryP95: Double?
    public var preciseDeliverySamples: Int
    public var timeWeightedWithinTwo: Double?
    public var recoveryP95: Double?
    public var recoveredEpisodes: Int
    public var unresolvedEpisodes: Int
    public var displayLatencyMeasured = false
    public var alignerComputeP95Milliseconds: Double
    public var isRealtime: Bool
    public var hasManuallyReviewedTimings: Bool
    public static func measure(script: String, reference: [TimedSpeechWord], observations: [SpeechObservation], realtime: Bool, decisionModel: AlignmentDecisionModel? = nil, exactSuffixBaseline: Bool = false) -> Self {
        let document = ScriptDocument(script), aligner = ScriptAligner(script: document, decisionModel: decisionModel)
        let timedTokens = reference.flatMap { word in TranscriptNormalizer.tokens(word.text).map { (word: $0, start: word.start, end: word.end) } }
        var ledger = SpeechTranscriptLedger(), correct = 0, totalError = 0, jumps = 0, count = 0
        var ages: [Double] = [], deliveries: [Double] = [], compute: [Double] = []
        var positions: [(time: Double, index: Int)] = [(0, 0)]
        var recoveryStart: Double?, recoveries: [Double] = []
        var lastText = "", exactPosition = 0
        for event in observations where event.isValid {
            ledger.consume(event)
            guard ledger.recentText != lastText else { continue }
            lastText = ledger.recentText
            let before = exactSuffixBaseline ? exactPosition : aligner.position
            let started = DispatchTime.now().uptimeNanoseconds
            let update: AlignmentUpdate
            if exactSuffixBaseline {
                let suffix = Array(TranscriptNormalizer.tokens(ledger.recentText).suffix(3))
                let endpoints = document.tokens.count >= 3 && suffix.count == 3 ? (2..<document.tokens.count).filter { Array(document.tokens[($0 - 2)...$0]) == suffix } : []
                let endpoint = endpoints.min { abs($0 - exactPosition) < abs($1 - exactPosition) }
                if let endpoint { exactPosition = endpoint }
                update = AlignmentUpdate(tokenIndex: exactPosition, confidence: endpoint == nil ? .low : .high, score: endpoint == nil ? 0 : 1,
                                         matchedPhrase: "", searchRange: 0..<document.tokens.count, moved: before != exactPosition)
            } else { update = aligner.align(ledger.recentText) }
            compute.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let truthTime = realtime ? event.deliveredAt : event.audioEnd
            guard let truth = timedTokens.lastIndex(where: { $0.end <= truthTime }) else { continue }
            positions.append((event.deliveredAt, update.tokenIndex))
            let error = abs(update.tokenIndex - truth)
            if realtime {
                if error > 5 && recoveryStart == nil { recoveryStart = event.deliveredAt }
                if error <= 2, let start = recoveryStart { recoveries.append(event.deliveredAt - start); recoveryStart = nil }
            }
            count += 1; correct += error <= 2 ? 1 : 0; totalError += error
            if update.moved && abs(update.tokenIndex - before) > 8 && error > 5 { jumps += 1 }
            if realtime {
                // Volatile Analyzer ranges can include future words in the same
                // audio segment. Only precise recognized endpoint timing is used.
                if let last = event.words.last, last.timingSource == .recognizer, last.end <= event.deliveredAt {
                    deliveries.append(event.deliveredAt - last.end)
                }
                if timedTokens.indices.contains(update.tokenIndex), timedTokens[update.tokenIndex].end <= event.deliveredAt {
                    ages.append(event.deliveredAt - timedTokens[update.tokenIndex].end)
                }
            }
        }
        var timeCorrect = 0, timeSamples = 0, visible = 0
        if realtime, let end = timedTokens.last?.end {
            var time = 0.0
            while time <= end {
                while visible + 1 < positions.count && positions[visible + 1].time <= time { visible += 1 }
                if let truth = timedTokens.lastIndex(where: { $0.end <= time }) {
                    timeSamples += 1; if abs(positions[visible].index - truth) <= 2 { timeCorrect += 1 }
                }
                time += 0.1
            }
        }
        return Self(callbacks: count, withinTwoTokens: Double(correct) / Double(max(count, 1)), meanAbsoluteTokenError: Double(totalError) / Double(max(count, 1)), wrongJumps: jumps,
                    highlightAgeP95: realtime && !ages.isEmpty ? percentile(ages) : nil, ageSampleCount: ages.count, unavailableAgeSamples: realtime ? count - ages.count : 0,
                    recognizerDeliveryP95: realtime && !deliveries.isEmpty ? percentile(deliveries) : nil, preciseDeliverySamples: deliveries.count, timeWeightedWithinTwo: realtime ? Double(timeCorrect) / Double(max(1, timeSamples)) : nil,
                    recoveryP95: recoveries.isEmpty ? nil : percentile(recoveries), recoveredEpisodes: recoveries.count, unresolvedEpisodes: recoveryStart == nil ? 0 : 1,
                    alignerComputeP95Milliseconds: percentile(compute), isRealtime: realtime,
                    hasManuallyReviewedTimings: reference.allSatisfy { $0.timingSource == .manualReviewed })
    }
    private static func percentile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }; let sorted = values.sorted(); return sorted[Int(ceil(Double(sorted.count - 1) * 0.95))]
    }
}
