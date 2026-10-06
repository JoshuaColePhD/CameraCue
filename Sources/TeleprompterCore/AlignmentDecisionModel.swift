import Foundation

public enum LearnedTrackingAction: String, Codable, Sendable, CaseIterable { case advance, hold, recover }
public struct AlignmentCandidate: Codable, Equatable, Sendable {
    public let positionBefore: Int
    public let tokenIndex: Int
    public let quality: Double
    public let margin: Double
    public let matches: Int
    public let tailCount: Int
    public let misses: Int
    public let recognizerConfidence: Double?
    public static let featureNames = ["quality", "margin", "coverage", "context", "distance", "backward", "misses", "asrConfidence", "asrConfidenceKnown"]
    public var features: [Double] {
        [quality, min(1, max(0, margin)), min(1, Double(matches) / Double(max(1, tailCount))), min(1, Double(tailCount) / 10),
         min(1, Double(abs(tokenIndex - positionBefore)) / 120), tokenIndex < positionBefore ? 1 : 0,
         min(1, Double(misses) / 4), min(1, max(0, recognizerConfidence ?? 0.5)), recognizerConfidence == nil ? 0 : 1]
    }
}
public struct AlignmentDecisionPrediction: Equatable, Sendable {
    public let action: LearnedTrackingAction
    public let probabilities: [Double]
    public var probabilityCorrect: Double { probabilities[0] + probabilities[2] }
}
/// Small multinomial logistic classifier. Weights are trained externally from
/// timestamped observations, versioned and evaluated before app promotion.
public struct AlignmentDecisionModel: Codable, Sendable {
    public let version: String
    public let featureNames: [String]
    public let coefficients: [[Double]]
    public let trainingSpeakers: [String]
    public let validationSpeakers: [String]
    public let heldOutSpeakers: [String]
    public let trainingRows: Int
    public let sourceCorpus: String
    public let holdThreshold: Double
    public var maximumScriptTokens: Int? = nil
    public func applies(to tokenCount: Int) -> Bool { isValid && tokenCount <= (maximumScriptTokens ?? Int.max) }
    public var isValid: Bool {
        (maximumScriptTokens == nil || maximumScriptTokens! > 0) && featureNames == AlignmentCandidate.featureNames && coefficients.count == 3 &&
        coefficients.allSatisfy { $0.count == featureNames.count + 1 && $0.allSatisfy(\.isFinite) } &&
        trainingRows >= 50 && !trainingSpeakers.isEmpty && !heldOutSpeakers.isEmpty && !version.isEmpty &&
        Set(trainingSpeakers).isDisjoint(with: Set(validationSpeakers + heldOutSpeakers)) &&
        Set(validationSpeakers).isDisjoint(with: Set(heldOutSpeakers)) && holdThreshold.isFinite && (0...1).contains(holdThreshold)
    }
    public func predict(_ candidate: AlignmentCandidate) -> AlignmentDecisionPrediction? {
        guard isValid, candidate.features.allSatisfy(\.isFinite) else { return nil }
        let features = [1.0] + candidate.features
        let logits = coefficients.map { zip($0, features).reduce(0) { $0 + $1.0 * $1.1 } }
        guard logits.allSatisfy(\.isFinite) else { return nil }
        let peak = logits.max()!
        let exponentials = logits.map { exp($0 - peak) }
        let sum = exponentials.reduce(0, +)
        let probabilities = exponentials.map { $0 / sum }
        let index = probabilities.indices.max { probabilities[$0] < probabilities[$1] }!
        return AlignmentDecisionPrediction(action: LearnedTrackingAction.allCases[index], probabilities: probabilities)
    }
}
