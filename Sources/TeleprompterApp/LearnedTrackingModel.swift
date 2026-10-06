import Foundation
import TeleprompterCore

/// Pilot weights are opt-in and explicitly limited to the short-script training
/// domain. Invalid/missing resources fall back to the established rule tracker.
enum LearnedTrackingModel {
    static let available: AlignmentDecisionModel? = {
        guard let url = Bundle.module.url(forResource: "AlignmentConfidence", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), bytes.count < 100_000,
              let model = try? JSONDecoder().decode(AlignmentDecisionModel.self, from: bytes),
              model.isValid, model.maximumScriptTokens != nil else { return nil }
        return model
    }()
}
