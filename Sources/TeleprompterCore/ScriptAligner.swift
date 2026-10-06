import Foundation

public enum AlignmentConfidence: String, Sendable { case high, medium, low }

public struct AlignmentUpdate: Sendable {
    public let tokenIndex: Int
    public let confidence: AlignmentConfidence
    public let score: Double
    public let matchedPhrase: String
    public let searchRange: Range<Int>
    public let moved: Bool
}

/// Aligns the trailing words of a partial speech transcript to the script.
/// The search expands only after repeated misses; silence never calls this API.
public final class ScriptAligner {
    public private(set) var position = 0
    public private(set) var misses = 0
    public var maximumAutomaticJump = 42
    public private(set) var lastCandidate: AlignmentCandidate?
    public private(set) var lastPrediction: AlignmentDecisionPrediction?
    private let decisionModel: AlignmentDecisionModel?
    private var lastTranscript = ""
    private let script: ScriptDocument

    public init(script: ScriptDocument, decisionModel: AlignmentDecisionModel? = nil) { self.script = script; self.decisionModel = decisionModel?.applies(to: script.tokens.count) == true ? decisionModel : nil }

    public func reset(to position: Int = 0) {
        self.position = min(max(position, 0), max(script.tokens.count - 1, 0))
        misses = 0
        lastTranscript = ""
    }

    public func align(_ transcript: String, recognizerConfidence: Double? = nil) -> AlignmentUpdate {
        lastCandidate = nil; lastPrediction = nil
        let spoken = TranscriptNormalizer.tokens(transcript)
        guard !spoken.isEmpty, !script.tokens.isEmpty else { return hold(0..<script.tokens.count) }
        let normalized = spoken.joined(separator: " ")
        guard normalized != lastTranscript else { return hold(0..<script.tokens.count) }
        lastTranscript = normalized
        let tail = Array(spoken.suffix(10))
        let back = misses >= 2 ? 80 : 20
        let ahead = misses >= 4 ? 260 : (misses >= 2 ? 120 : 42)
        let range = max(0, position - back)..<min(script.tokens.count, position + ahead + 1)
        // Candidate windows overlap heavily. Compute fuzzy word comparisons once
        // per transcript rather than repeating edit distance in every DP cell.
        let contextStart = max(0, range.lowerBound - 15)
        let context = Array(script.tokens[contextStart..<range.upperBound])
        let similarities = tail.map { word in context.map { similarity(word, $0) } }
        var best = (score: -Double.infinity, endpoint: position, matches: 0, phrase: "", quality: 0.0)
        var secondScore = -Double.infinity
        for endpoint in range {
            let start = max(0, endpoint - 15)
            let candidate = Array(script.tokens[start...endpoint])
            let result = localAlignment(tail, candidate, similarities: similarities, offset: start - contextStart)
            guard result.matches >= 2 else { continue }
            // Ambiguous repeated phrases are resolved toward the current position.
            let distance = abs(endpoint - position)
            let proximityPenalty = min(0.20, Double(distance) * 0.008)
            let backwardPenalty = endpoint < position - 4 ? 0.18 : 0
            let total = result.quality - proximityPenalty - backwardPenalty
            if total > best.score { secondScore = best.score; best = (total, endpoint, result.matches, result.phrase, result.quality) }
            else if total > secondScore { secondScore = total }
        }
        if best.matches > 0 {
            let candidate = AlignmentCandidate(positionBefore: position, tokenIndex: best.endpoint, quality: best.quality,
                                               margin: secondScore.isFinite ? best.score - secondScore : 1,
                                               matches: best.matches, tailCount: tail.count, misses: misses, recognizerConfidence: recognizerConfidence)
            lastCandidate = candidate
            lastPrediction = decisionModel?.predict(candidate)
            // The pilot classifier is a conservative veto for an ambiguous
            // short-phrase jump only. Longer-context recovery retains the
            // existing rule gates until broader real-ASR validation exists.
            if candidate.tailCount <= 6, abs(candidate.tokenIndex - position) > 8,
               let model = decisionModel, let prediction = lastPrediction, prediction.probabilityCorrect < model.holdThreshold {
                misses += 1
                return hold(range, score: best.score)
            }
        }
        let required = misses >= 3 ? 0.47 : 0.42
        guard best.score >= required else {
            misses += 1
            return hold(range, score: max(0, best.score))
        }
        let jump = best.endpoint - position
        // Short phrases recur often. Require more context before a sizeable move.
        if abs(jump) > 8 && best.matches < 4 {
            misses += 1
            return hold(range, score: best.score)
        }
        if jump > maximumAutomaticJump && (best.quality < 0.85 || best.matches < 4 || misses < 2) {
            misses += 1
            return hold(range, score: best.score)
        }
        if jump < -6 && (best.quality < 0.90 || best.matches < 4) {
            misses += 1
            return hold(range, score: best.score)
        }
        let prior = position
        // A recognized phrase identifies a stable phrase end. Small backwards corrections
        // are allowed for restarts, while filler and ad-libs leave the position unchanged.
        position = best.endpoint
        misses = 0
        lastTranscript = normalized
        let confidence: AlignmentConfidence = best.quality >= 0.85 ? .high : .medium
        return AlignmentUpdate(tokenIndex: position, confidence: confidence, score: best.score, matchedPhrase: best.phrase, searchRange: range, moved: prior != position)
    }

    private func hold(_ range: Range<Int>, score: Double = 0) -> AlignmentUpdate {
        AlignmentUpdate(tokenIndex: position, confidence: .low, score: score, matchedPhrase: "", searchRange: range, moved: false)
    }

    private func localAlignment(_ spoken: [String], _ script: [String], similarities: [[Double]], offset: Int) -> (quality: Double, matches: Int, phrase: String) {
        let m = spoken.count, n = script.count
        var dp = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        var matched = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        var maxScore = 0.0, maxMatches = 0, maxI = 0, maxJ = 0
        for i in 1...m {
            for j in 1...n {
                let sim = similarities[i - 1][offset + j - 1]
                let diagonal = dp[i - 1][j - 1] + (sim >= 0.72 ? 1.0 * sim : -0.85)
                let up = dp[i - 1][j] - 0.42
                let left = dp[i][j - 1] - 0.38
                let score = max(0, diagonal, up, left)
                dp[i][j] = score
                matched[i][j] = score == diagonal ? matched[i - 1][j - 1] + (sim >= 0.72 ? 1 : 0) : (score == up ? matched[i - 1][j] : (score == left ? matched[i][j - 1] : 0))
                // Favor matches ending at the actual trailing spoken phrase and script endpoint.
                if i == m && j == n && score > maxScore {
                    maxScore = score; maxMatches = matched[i][j]; maxI = i; maxJ = j
                }
            }
        }
        guard maxMatches >= 2 else { return (0, 0, "") }
        let coverage = Double(maxMatches) / Double(min(m, 8))
        let quality = min(1, maxScore / Double(maxMatches)) * min(1, coverage + 0.22)
        let start = max(0, maxJ - maxMatches)
        let phrase = script[start..<maxJ].joined(separator: " ")
        _ = maxI
        return (quality, maxMatches, phrase)
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard min(a.count, b.count) >= 4 else { return 0 }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...x.count {
            var next = Array(repeating: 0, count: y.count + 1)
            next[0] = i
            for j in 1...y.count {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            row = next
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }
}
