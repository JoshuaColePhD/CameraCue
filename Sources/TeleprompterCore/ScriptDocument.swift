import Foundation

public struct ScriptLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let spokenText: String
    public let annotation: String?
    public let isEmphatic: Bool
    public let isPause: Bool
    public let tokenRange: Range<Int>
}

public struct ScriptDocument: Sendable {
    public let source: String
    public let lines: [ScriptLine]
    public let tokens: [String]
    public let tokenLineIDs: [Int]

    public init(_ source: String) {
        self.source = source
        var builtLines: [ScriptLine] = []
        var builtTokens: [String] = []
        var builtLineIDs: [Int] = []
        let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let bracketPattern = #"\[[^\]]+\]"#
        let regex = try! NSRegularExpression(pattern: bracketPattern)
        for (id, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let fullRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let matches = regex.matches(in: raw, range: fullRange)
            var spoken = raw
            for match in matches.reversed() {
                if let range = Range(match.range, in: spoken) {
                    spoken.removeSubrange(range)
                }
            }
            spoken = spoken.trimmingCharacters(in: .whitespaces)
            let annotation = matches.first.flatMap { Range($0.range, in: raw).map { String(raw[$0]) } }
            let start = builtTokens.count
            let lineTokens = TranscriptNormalizer.tokens(spoken)
            builtTokens.append(contentsOf: lineTokens)
            builtLineIDs.append(contentsOf: repeatElement(id, count: lineTokens.count))
            let letters = spoken.filter { $0.isLetter }
            let emphatic = letters.count >= 2 && letters == letters.uppercased() && letters != letters.lowercased()
            let pause = annotation?.lowercased().contains("pause") == true || annotation?.lowercased().contains("beat") == true || trimmed == "…"
            builtLines.append(ScriptLine(id: id, text: raw, spokenText: spoken, annotation: annotation, isEmphatic: emphatic, isPause: pause, tokenRange: start..<builtTokens.count))
        }
        self.lines = builtLines
        self.tokens = builtTokens
        self.tokenLineIDs = builtLineIDs
    }

    public func lineID(forToken index: Int) -> Int {
        guard !tokenLineIDs.isEmpty else { return 0 }
        return tokenLineIDs[min(max(index, 0), tokenLineIDs.count - 1)]
    }

    public func tokenIndex(forLine id: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        return lines[min(max(id, 0), lines.count - 1)].tokenRange.lowerBound
    }
}

public enum TranscriptNormalizer {
    private static let wordExpression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:'[\p{L}]+)?"#)
    public static func tokens(_ text: String) -> [String] {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let raw = wordExpression.matches(in: normalized, range: nsRange).compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } }
        return raw.flatMap { token -> [String] in
            switch token {
            case "they're": return ["they", "are"]
            case "we're": return ["we", "are"]
            case "you're": return ["you", "are"]
            case "it's": return ["it", "is"]
            case "that's": return ["that", "is"]
            case "what's": return ["what", "is"]
            case "i'm": return ["i", "am"]
            case "can't": return ["can", "not"]
            case "don't": return ["do", "not"]
            case "didn't": return ["did", "not"]
            case "wouldn't": return ["would", "not"]
            case "shouldn't": return ["should", "not"]
            case "10": return ["ten"]
            case "2": return ["two"]
            case "5": return ["five"]
            case "30": return ["thirty"]
            default: return [token]
            }
        }
    }
}
