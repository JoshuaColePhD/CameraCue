import Foundation
import TeleprompterCore

struct ReplayEvent: Codable, Sendable {
    let transcript: String
    let truth: Int
    let spokenAt: Double
    let deliveredAt: Double
    let scored: Bool
    let mustHold: Bool
    let recoveryStart: Bool
}
struct ReplayCase: Sendable {
    let speech: String
    let split: String
    let scenario: String
    let seed: UInt64
    let document: ScriptDocument
    let events: [ReplayEvent]
    let wordTimes: [(index: Int, time: Double)]
}
struct SeededRandom {
    var value: UInt64
    mutating func next() -> UInt64 { value = value &* 6364136223846793005 &+ 1442695040888963407; return value }
    mutating func fraction() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

enum ReplayCorpus {
    static let version = "speech-replay-v1"
    static let speeches = [("gettysburg", "development"), ("rice", "development"), ("congress", "held-out")]
    static let scenarios = ["clean", "recognition-errors", "partial-revisions", "recognizer-reset", "duplicates-and-silence", "ad-lib", "skip-forward", "restart"]
    static let developmentSeeds: [UInt64] = [11, 29, 47, 83, 101, 131]
    static let heldOutSeeds: [UInt64] = [211, 239, 263, 293, 317, 349]
    static func cases(split: String? = nil) throws -> [ReplayCase] {
        var result: [ReplayCase] = []
        for (speech, group) in speeches where split == nil || group == split {
            guard let url = Bundle.module.url(forResource: speech, withExtension: "txt") else { throw CocoaError(.fileNoSuchFile) }
            let document = ScriptDocument(try String(contentsOf: url, encoding: .utf8))
            for seed in (group == "development" ? developmentSeeds : heldOutSeeds) {
                for scenario in scenarios { result.append(make(speech: speech, split: group, scenario: scenario, seed: seed, document: document)) }
            }
        }
        return result
    }
    static func make(speech: String, split: String, scenario: String, seed: UInt64, document: ScriptDocument) -> ReplayCase {
        var random = SeededRandom(value: seed)
        var events: [ReplayEvent] = [], wordTimes: [(Int, Double)] = []
        var transcript: [String] = []
        let secondsPerWord = 60.0 / (125 + Double(seed % 51))
        var time = 0.0, index = 0, spokenCount = 0, changed = false
        var pendingRecovery = false
        let intervention = document.tokens.count / 3
        while index < document.tokens.count {
            if !changed && index >= intervention {
                changed = true
                switch scenario {
                case "skip-forward": index = min(document.tokens.count - 10, index + 55); transcript = []; pendingRecovery = true
                case "restart": index = max(0, index - 18); transcript = []; pendingRecovery = true
                case "recognizer-reset": transcript = []
                case "duplicates-and-silence":
                    time += 2.4
                    events.append(ReplayEvent(transcript: "", truth: index - 1, spokenAt: time, deliveredAt: time, scored: false, mustHold: true, recoveryStart: false))
                case "ad-lib":
                    // Non-script material, with common pronouns but no genuine phrase.
                    for phrase in ["purple submarine beneath a rainbow", "honestly my coffee spilled on the desk", "anyway let us get back to the presentation"] {
                        time += 0.7
                        events.append(ReplayEvent(transcript: phrase, truth: index - 1, spokenAt: time, deliveredAt: time + 0.35, scored: false, mustHold: true, recoveryStart: false))
                    }
                    transcript = []
                default: break
                }
            }
            let token = document.tokens[index]
            time += secondsPerWord
            wordTimes.append((index, time)); spokenCount += 1
            if scenario == "recognition-errors" {
                let p = random.fraction()
                if p < 0.08 { /* deletion */ }
                else if p < 0.16 {
                    let substitutions = ["their": "there", "to": "too", "four": "for", "our": "are", "new": "knew"]
                    if let replacement = substitutions[token] { transcript.append(replacement) }
                    else if token.count >= 5 { transcript.append(String(token.dropLast()) + "s") }
                    else { transcript.append("uh") }
                } else {
                    if p < 0.23 { transcript.append("um") }
                    transcript.append(token)
                }
            } else { transcript.append(token) }
            let endpoint = index; index += 1
            guard spokenCount % 3 == 0 || index == document.tokens.count else { continue }
            let delay = 0.25 + random.fraction() * 0.30
            let text = transcript.joined(separator: " ")
            if scenario == "partial-revisions", transcript.count > 3, spokenCount % 12 == 0 {
                var revision = transcript; revision[revision.count - 1] = "unrelated"
                events.append(ReplayEvent(transcript: revision.joined(separator: " "), truth: endpoint, spokenAt: time, deliveredAt: time + delay, scored: true, mustHold: false, recoveryStart: false))
            }
            events.append(ReplayEvent(transcript: text, truth: endpoint, spokenAt: time, deliveredAt: time + delay + (scenario == "partial-revisions" ? 0.15 : 0), scored: true, mustHold: false, recoveryStart: pendingRecovery))
            pendingRecovery = false
            if scenario == "duplicates-and-silence" {
                events.append(ReplayEvent(transcript: text, truth: endpoint, spokenAt: time, deliveredAt: time + delay + 0.03, scored: false, mustHold: true, recoveryStart: false))
            }
        }
        return ReplayCase(speech: speech, split: split, scenario: scenario, seed: seed, document: document, events: events, wordTimes: wordTimes)
    }
}
