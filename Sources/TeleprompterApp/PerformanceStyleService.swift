import Foundation
import FoundationModels
import TeleprompterCore

@MainActor enum PerformanceStyleService {
    struct Result {
        let plan: PerformanceStylePlan
        let status: String
        var needsRetry = false
    }

    static func suggest(for source: String) async -> PerformanceStylePlan {
        await suggestWithStatus(for: source).plan
    }

    static func suggestWithStatus(for source: String) async -> Result {
        let local = PerformanceLayout.localPlan(for: source).styled(.natural, intensity: 0.65)
        guard local.isValid(for: source) else { return Result(plan: local, status: "Local formatting was used.") }
        guard #available(macOS 26.0, *) else {
            return Result(plan: local, status: "This macOS version does not support on-device AI. Local formatting was used.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return Result(plan: local, status: "On-device AI is not ready. Local formatting was used.")
        }
        // Large imports can otherwise queue dozens of model requests. Keep them
        // responsive with the word-preserving local layout instead.
        if source.count > 20_000 || ScriptDocument(local.formattedBody).lines.count > 600 {
            return Result(plan: local, status: "This script is too long for one AI pass. Local formatting was used.")
        }
        do {
            let plan = try await suggestWithModel(local: local).styled(.natural, intensity: 0.65)
            return Result(plan: plan, status: plan.usedAI
                ? "Formatted with on-device AI. Your original words are unchanged."
                : "The model found no valid accents. Local formatting was used.")
        } catch {
            NSLog("CameraCue on-device styling failed: %@", String(describing: error))
            return Result(plan: local, status: "Apple's on-device model could not finish. Local formatting was used.", needsRetry: true)
        }
    }

    @available(macOS 26.0, *)
    private static func suggestWithModel(local: PerformanceStylePlan) async throws -> PerformanceStylePlan {
        let document = ScriptDocument(local.formattedBody)
        let spokenLines = document.lines.filter { !$0.spokenText.isEmpty }
        var aiMoments: [PerformanceMoment] = []
        var lastError: Error?
        for batch in stride(from: 0, to: spokenLines.count, by: 32) {
            try Task.checkCancellation()
            let lines = spokenLines[batch..<min(batch + 32, spokenLines.count)]
            let numbered = lines.map { "\($0.id): \($0.spokenText)" }.joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
                You are a restrained but playful teleprompter typographer.
                Pick performance moments that make a script fun and easy to read near a camera. Never rewrite the script.
                Return 4 to 9 lines in exactly this format: line_number|exact short phrase|treatment
                Example: 17|TEN YEARS|huge
                Copy each phrase exactly from its numbered line. Use only accent, big, huge, question, suspense, or pause as treatments.
                Use huge rarely. Keep most lines unstyled. Return at most one suggestion per line.
                Do not use Markdown, bullets, quotation marks around phrases, or explanatory text.
                """)
            do {
                let answer = try await session.respond(to: "Choose moments from these numbered lines:\n\(numbered)")
                for responseLine in answer.content.components(separatedBy: .newlines) {
                    guard let moment = parseMoment(responseLine),
                          let valid = PerformanceLayout.validatedMoment(moment, in: document),
                          lines.contains(where: { $0.id == valid.lineID }),
                          !aiMoments.contains(where: { $0.lineID == valid.lineID }) else { continue }
                    aiMoments.append(valid)
                }
            } catch {
                lastError = error
                NSLog("CameraCue style batch failed: %@", String(describing: error))
            }
        }
        guard !aiMoments.isEmpty else {
            if let lastError { throw lastError }
            return local
        }
        let chosenIDs = Set(aiMoments.map(\.lineID))
        let combined = local.moments.filter { !chosenIDs.contains($0.lineID) } + aiMoments
        return PerformanceStylePlan(sourceBody: local.sourceBody,
                                    formattedBody: local.formattedBody,
                                    moments: combined.sorted { $0.lineID < $1.lineID },
                                    usedAI: true)
    }

    private static func parseMoment(_ line: String) -> PerformanceMoment? {
        let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3,
              let lineID = Int(parts[0].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) else { return nil }
        let phrase = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"“”`"))
        let tone: PerformanceTone
        let scale: PerformanceScale
        let pause: Bool
        switch parts[2].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "` .")) {
        case "accent": tone = .cyan; scale = .regular; pause = false
        case "big": tone = .cyan; scale = .large; pause = false
        case "huge": tone = .coral; scale = .huge; pause = false
        case "question": tone = .amber; scale = .large; pause = true
        case "suspense": tone = .neutral; scale = .large; pause = true
        case "pause": tone = .neutral; scale = .regular; pause = true
        default: return nil
        }
        return PerformanceMoment(lineID: lineID,
                                 phrase: phrase,
                                 tone: tone,
                                 scale: scale,
                                 pauseAfter: pause)
    }
}
