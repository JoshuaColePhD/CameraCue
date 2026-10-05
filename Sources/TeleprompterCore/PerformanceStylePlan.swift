import Foundation

public enum PerformanceTone: String, Codable, Sendable { case neutral, cyan, amber, coral }
public enum PerformanceScale: String, Codable, Sendable { case regular, large, huge }
public enum ReadingStylePreset: String, Codable, CaseIterable, Sendable {
    case natural = "Natural", expressive = "Expressive", minimal = "Minimal"
}
public enum PhraseTreatment { case emphasize, pause, keepTogether, deliveryCue }

public struct PerformanceMoment: Codable, Sendable, Equatable {
    public let lineID: Int
    public let phrase: String
    public let tone: PerformanceTone
    public let scale: PerformanceScale
    public let pauseAfter: Bool
    public let tokenAnchor: TokenAnchor?
    public let deliveryCue: String?

    public init(lineID: Int, phrase: String, tone: PerformanceTone, scale: PerformanceScale, pauseAfter: Bool, tokenAnchor: TokenAnchor? = nil, deliveryCue: String? = nil) {
        self.lineID = lineID
        self.phrase = phrase
        self.tone = tone
        self.scale = scale
        self.pauseAfter = pauseAfter
        self.tokenAnchor = tokenAnchor
        self.deliveryCue = deliveryCue
    }
}

public struct PerformanceStylePlan: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sourceBody: String
    public let formattedBody: String
    public let moments: [PerformanceMoment]
    public let usedAI: Bool
    public var preset: ReadingStylePreset? = nil
    public var intensity: Double? = nil

    public init(sourceBody: String, formattedBody: String, moments: [PerformanceMoment], usedAI: Bool) {
        self.id = UUID()
        self.sourceBody = sourceBody
        self.formattedBody = formattedBody
        self.moments = moments
        self.usedAI = usedAI
    }

    public func isValid(for source: String) -> Bool {
        guard sourceBody == source else { return false }
        return ScriptDocument(source).tokens == ScriptDocument(formattedBody).tokens
    }

    public func moments(forLine id: Int) -> [PerformanceMoment] {
        let document = ScriptDocument(formattedBody)
        guard document.lines.indices.contains(id) else { return [] }
        return moments(for: document.lines[id])
    }
    public func moments(for line: ScriptLine) -> [PerformanceMoment] {
        let range = line.tokenRange
        return moments.filter { moment in
            moment.tokenAnchor.map { $0.range.overlaps(range) } ?? (moment.lineID == line.id)
        }
    }
    public func deliveryCue(forLine id: Int) -> String? {
        let document = ScriptDocument(formattedBody)
        guard document.lines.indices.contains(id) else { return nil }
        return deliveryCue(for: document.lines[id])
    }
    public func deliveryCue(for line: ScriptLine) -> String? {
        moments.last(where: {
            $0.deliveryCue != nil && ($0.tokenAnchor.map { line.tokenRange.contains($0.lowerBound) } ?? ($0.lineID == line.id))
        })?.deliveryCue
    }
    public func pauseAfter(_ line: ScriptLine) -> Bool {
        moments.contains { $0.pauseAfter && ($0.tokenAnchor.map { line.tokenRange.contains($0.upperBound - 1) } ?? ($0.lineID == line.id)) }
    }
    public func displayMoments(forLine id: Int) -> [PerformanceMoment] {
        let document = ScriptDocument(formattedBody)
        guard document.lines.indices.contains(id) else { return [] }
        return displayMoments(for: document.lines[id])
    }
    public func displayMoments(for line: ScriptLine) -> [PerformanceMoment] {
        guard preset != .minimal, (intensity ?? 1) > 0 else { return [] }
        return moments(for: line).map { moment in
            PerformanceMoment(lineID: line.id, phrase: moment.phrase, tone: moment.tone,
                              scale: preset == .natural ? .regular : moment.scale, pauseAfter: moment.pauseAfter,
                              tokenAnchor: moment.tokenAnchor, deliveryCue: moment.deliveryCue)
        }
    }

    public func styled(_ preset: ReadingStylePreset, intensity: Double) -> PerformanceStylePlan {
        var result = PerformanceStylePlan(sourceBody: sourceBody, formattedBody: formattedBody, moments: moments, usedAI: usedAI)
        result.preset = preset
        result.intensity = min(1, max(0, intensity))
        return result
    }

    public func displayMoment(forLine id: Int) -> PerformanceMoment? {
        displayMoments(forLine: id).last
    }

    public func editing(tokens: Range<Int>, treatment: PhraseTreatment, cue: String? = nil) -> PerformanceStylePlan? {
        let originalMap = ScriptTokenMap(sourceBody)
        guard let sourceRange = originalMap.textRange(for: tokens), tokens.count > 0 else { return nil }
        let originalWords = (sourceBody as NSString).substring(with: sourceRange)
        let document = ScriptDocument(formattedBody)
        guard tokens.upperBound <= document.tokens.count else { return nil }
        var body = formattedBody
        if treatment == .pause, let range = ScriptTokenMap(body).textRange(for: tokens) {
            // Split the reading phrase after its punctuation, preserving every source word.
            let ns = body as NSString
            let nextWord = ScriptTokenMap(body).ranges.dropFirst(tokens.upperBound).first?.location ?? ns.length
            let gap = ns.substring(with: NSRange(location: NSMaxRange(range), length: nextWord - NSMaxRange(range)))
            if !gap.contains("\n"), !gap.contains("[") {
                body = ns.replacingCharacters(in: NSRange(location: nextWord, length: 0), with: "\n")
            }
        }
        let next = ScriptDocument(body)
        let anchor = TokenAnchor(tokens)
        let previous = moments.last(where: { $0.tokenAnchor == anchor })
        let note = cue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if treatment == .deliveryCue && (note?.isEmpty != false || (note?.count ?? 0) > 80) { return nil }
        var adjusted = moments.filter { $0.tokenAnchor != anchor }.map { moment in
            let token = moment.tokenAnchor?.lowerBound ?? document.tokenIndex(forLine: moment.lineID)
            return PerformanceMoment(lineID: next.lineID(forToken: token), phrase: moment.phrase, tone: moment.tone,
                                     scale: moment.scale, pauseAfter: moment.pauseAfter,
                                     tokenAnchor: moment.tokenAnchor, deliveryCue: moment.deliveryCue)
        }
        adjusted.append(PerformanceMoment(lineID: next.lineID(forToken: tokens.lowerBound), phrase: originalWords,
            tone: treatment == .emphasize ? .coral : (previous?.tone ?? .neutral),
            scale: treatment == .emphasize ? .large : (previous?.scale ?? .regular),
            pauseAfter: treatment == .pause || previous?.pauseAfter == true, tokenAnchor: anchor,
            deliveryCue: treatment == .deliveryCue ? note : previous?.deliveryCue))
        var result = PerformanceStylePlan(sourceBody: sourceBody, formattedBody: body, moments: adjusted, usedAI: usedAI)
        result.preset = preset == .minimal && treatment == .emphasize ? .natural : preset
        result.intensity = treatment == .emphasize && (intensity ?? 1) <= 0 ? 0.65 : intensity
        return result.isValid(for: sourceBody) ? result : nil
    }

    /// Restrict edits to an exact phrase beginning on the chosen reading line.
    /// Only whitespace and delivery metadata change; spoken tokens are validated.
    public func editing(lineID: Int, phrase: String, treatment: PhraseTreatment) -> PerformanceStylePlan? {
        let document = ScriptDocument(formattedBody)
        guard document.lines.indices.contains(lineID), !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let lines = formattedBody.components(separatedBy: "\n")
        let offset = lines.prefix(lineID).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let ns = formattedBody as NSString
        guard let match = expression.firstMatch(in: formattedBody, range: NSRange(location: offset, length: ns.length - offset)),
              match.range.location < offset + (lines[lineID] as NSString).length else { return nil }
        let matched = ns.substring(with: match.range)
        // Bracketed directions are never merged into spoken phrases.
        guard !matched.contains("["), !matched.contains("]") else { return nil }
        var body = formattedBody
        if treatment == .keepTogether {
            guard matched.count <= 72 else { return nil }
            body = ns.replacingCharacters(in: match.range, with: matched.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))
        }
        let next = ScriptDocument(body)
        var adjusted = moments.compactMap { moment -> PerformanceMoment? in
            guard document.lines.indices.contains(moment.lineID) else { return nil }
            let newID = next.lineID(forToken: document.lines[moment.lineID].tokenRange.lowerBound)
            return PerformanceMoment(lineID: newID, phrase: moment.phrase, tone: moment.tone, scale: moment.scale, pauseAfter: moment.pauseAfter, tokenAnchor: moment.tokenAnchor, deliveryCue: moment.deliveryCue)
        }
        if treatment != .keepTogether {
            guard !matched.contains("\n") else { return nil }
            adjusted.removeAll { $0.lineID == lineID }
            adjusted.append(PerformanceMoment(lineID: lineID, phrase: matched,
                tone: treatment == .emphasize ? .coral : .neutral,
                scale: treatment == .emphasize ? .large : .regular, pauseAfter: treatment == .pause))
        }
        var result = PerformanceStylePlan(sourceBody: sourceBody, formattedBody: body, moments: adjusted, usedAI: usedAI)
        result.preset = treatment == .emphasize && preset == .minimal ? .natural : preset
        result.intensity = intensity
        return result.isValid(for: sourceBody) ? result : nil
    }
}

public enum PerformanceLayout {
    /// Preserve intentional short lines and stage directions. Wrap long prose at natural beats.
    public static func reflow(_ source: String, targetWidth: Int = 20) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count > targetWidth + 3,
                      !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else { return [line] }
                // Treat bracketed delivery cues as atomic units, so reflow cannot
                // accidentally turn a split cue into spoken words.
                let expression = try! NSRegularExpression(pattern: #"\[[^\]]*\]|[^\s]+"#)
                let words = expression.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
                    .compactMap { Range($0.range, in: trimmed).map { String(trimmed[$0]) } }
                guard words.count > 1 else { return [line] }
                var result: [String] = []
                var current: [String] = []
                for word in words {
                    let length = current.joined(separator: " ").count
                    if !current.isEmpty && length + word.count + 1 > targetWidth {
                        result.append(current.joined(separator: " "))
                        current = []
                    }
                    current.append(word)
                    if current.joined(separator: " ").count >= 24,
                       word.last.map({ ".?!…—;".contains($0) }) == true {
                        result.append(current.joined(separator: " "))
                        current = []
                    }
                }
                if !current.isEmpty { result.append(current.joined(separator: " ")) }
                return result.isEmpty ? [line] : result
            }
            .joined(separator: "\n")
    }

    public static func validatedMoment(_ moment: PerformanceMoment, in document: ScriptDocument) -> PerformanceMoment? {
        guard document.lines.indices.contains(moment.lineID) else { return nil }
        let line = document.lines[moment.lineID]
        guard !line.spokenText.isEmpty else { return nil }
        let phrase = moment.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 36,
              line.spokenText.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
        return PerformanceMoment(lineID: moment.lineID, phrase: phrase, tone: moment.tone, scale: moment.scale, pauseAfter: moment.pauseAfter)
    }

    public static func localPlan(for source: String) -> PerformanceStylePlan {
        let formatted = reflow(source)
        let document = ScriptDocument(formatted)
        var moments: [PerformanceMoment] = []
        for line in document.lines {
            let text = line.spokenText
            guard !text.isEmpty else { continue }
            let upper = text.range(of: #"(?<![A-Za-z])[A-Z][A-Z'’-]{2,}(?:\s+[A-Z][A-Z'’-]{2,})*"#, options: .regularExpression)
            let phrase = upper.map { String(text[$0]) } ?? text
            let dramatic = line.isEmphatic || upper != nil
            let shortQuestion = text.hasSuffix("?") && text.count <= 42
            let pause = text.hasSuffix("…") || text.hasSuffix("?") || text.hasSuffix("—")
            let punchWord = upper.map { text.count <= String(text[$0]).count + 2 && String(text[$0]).count <= 12 } ?? false
            if dramatic || shortQuestion || pause {
                moments.append(PerformanceMoment(
                    lineID: line.id,
                    phrase: String(phrase.prefix(36)),
                    tone: dramatic ? .cyan : (shortQuestion ? .amber : .neutral),
                    scale: punchWord ? .huge : (dramatic || shortQuestion ? .large : .regular),
                    pauseAfter: pause
                ))
            }
        }
        return PerformanceStylePlan(sourceBody: source, formattedBody: formatted, moments: moments, usedAI: false)
    }
}
