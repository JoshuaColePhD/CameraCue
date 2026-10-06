import Foundation

public enum CoachingKind: String, Codable, Sendable { case fast, slow, pause, repetition, scriptDifference, filler }
public struct CoachingFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: CoachingKind
    public let start: Double
    public let end: Double
    public let title: String
    public let suggestion: String
    public let excerpt: String
    public let approximateTiming: Bool
}
public struct TakeCoachingReport: Codable, Sendable {
    public let duration: Double
    public let words: Int
    public let wordsPerMinute: Double
    public let findings: [CoachingFinding]
    public let hasEstimatedTimings: Bool
    public let scriptCompared: Bool
    public static func analyze(words source: [TimedSpeechWord], script: String?, usualWordsPerMinute: Double? = nil) -> Self {
        let words = source.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !TranscriptNormalizer.tokens($0.text).isEmpty }.sorted { $0.start < $1.start }
        let duration = words.last?.end ?? 0
        var findings: [CoachingFinding] = []
        func add(_ kind: CoachingKind, _ group: [TimedSpeechWord], _ title: String, _ suggestion: String) {
            guard let first = group.first, let last = group.last else { return }
            findings.append(CoachingFinding(id: "\(kind.rawValue)-\(first.start)", kind: kind, start: first.start, end: last.end, title: title, suggestion: suggestion,
                                            excerpt: group.map(\.text).joined(separator: " "), approximateTiming: group.contains { $0.timingSource == .estimatedWithinSegment }))
        }
        for index in words.indices.dropFirst() {
            let gap = words[index].start - words[index - 1].end
            if gap >= 2.5 {
                let first = words[index - 1], next = words[index]
                findings.append(CoachingFinding(id: "pause-\(first.end)", kind: .pause, start: first.end, end: next.start,
                                                title: String(format: "%.1f-second pause", gap), suggestion: "Listen here. Keep the pause if it gives the idea room; shorten it if it interrupts the flow.", excerpt: first.text + " … " + next.text,
                                                approximateTiming: first.timingSource == .estimatedWithinSegment || next.timingSource == .estimatedWithinSegment))
            }
        }
        let typical = usualWordsPerMinute ?? 150
        var windowStart = 0
        while windowStart < words.count {
            let start = words[windowStart].start
            let group = Array(words[windowStart...].prefix { $0.end <= start + 15 })
            if group.count >= 12, let last = group.last, last.end - start >= 6 {
                let rate = Double(group.count) * 60 / (last.end - start)
                if rate > typical * 1.3 { add(.fast, group, String(format: "Faster section · %.0f words/min", rate), "Try a breath between ideas and give the important words a little more space.") }
                else if rate < typical * 0.65 { add(.slow, group, String(format: "Slower section · %.0f words/min", rate), "Check whether the slower delivery helps this point. If it drifts, tighten the gaps between phrases.") }
            }
            windowStart += max(1, group.count)
        }
        var recent: [String: Double] = [:]
        if words.count >= 3 {
            for index in 2..<words.count {
                let group = Array(words[(index - 2)...index])
                let key = group.flatMap { TranscriptNormalizer.tokens($0.text) }.joined(separator: " ")
                if let previous = recent[key], group[0].start - previous > 0.3, group[0].start - previous < 15 {
                    add(.repetition, group, "Repeated phrase", "Listen to the repetition. Keep it for emphasis, or try the phrase once in your next take.")
                }
                recent[key] = group[0].start
            }
        }
        for word in words where ["um", "uh", "erm"].contains(word.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            add(.filler, [word], "Possible filler word", "A short silent pause can give you time to think. Check the transcript against playback first.")
        }
        if let script, !ScriptDocument(script).tokens.isEmpty {
            let aligner = ScriptAligner(script: ScriptDocument(script))
            var spoken: [String] = [], unmatched: [TimedSpeechWord] = []
            for (index, word) in words.enumerated() {
                spoken.append(word.text)
                guard index % 4 == 3 || index == words.count - 1 else { continue }
                let match = aligner.align(spoken.suffix(12).joined(separator: " "))
                if match.confidence == .low { unmatched += Array(words[max(0, index - 3)...index]) }
                else {
                    if unmatched.count >= 8 { add(.scriptDifference, unmatched, "Possible script difference", "The recognized words differ from your script here. Check playback before deciding whether to revise or rerecord.") }
                    unmatched = []
                }
            }
            if unmatched.count >= 8 { add(.scriptDifference, unmatched, "Possible script difference", "Check playback: this may be improvisation, a skipped passage, or a recognition error.") }
        }
        findings.sort { $0.start < $1.start }
        return Self(duration: duration, words: words.count, wordsPerMinute: duration > 0 ? Double(words.count) * 60 / duration : 0,
                    findings: Array(findings.prefix(100)), hasEstimatedTimings: words.contains { $0.timingSource == .estimatedWithinSegment }, scriptCompared: script != nil)
    }
}
