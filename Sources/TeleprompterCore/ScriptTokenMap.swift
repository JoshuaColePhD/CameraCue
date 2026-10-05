import Foundation

public struct TokenAnchor: Codable, Equatable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int
    public var range: Range<Int> { lowerBound..<max(lowerBound, upperBound) }
    public init(_ range: Range<Int>) { lowerBound = range.lowerBound; upperBound = range.upperBound }
}

/// UTF-16 ranges match NSTextView selection while indices match the speech normalizer.
public struct ScriptTokenMap {
    private static let bracketExpression = try! NSRegularExpression(pattern: #"\[[^\]\r\n]+\]"#)
    private static let wordExpression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)
    public let ranges: [NSRange]
    public let textLength: Int
    public init(_ text: String) {
        textLength = (text as NSString).length
        let all = NSRange(location: 0, length: textLength)
        let cues = Self.bracketExpression.matches(in: text, range: all).map(\.range)
        ranges = Self.wordExpression.matches(in: text, range: all).flatMap { match -> [NSRange] in
            guard !cues.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return [] }
            return Array(repeating: match.range, count: TranscriptNormalizer.tokens((text as NSString).substring(with: match.range)).count)
        }
    }
    public func tokens(intersecting selection: NSRange) -> Range<Int>? {
        guard selection.location != NSNotFound, selection.length > 0,
              selection.location >= 0, NSMaxRange(selection) <= textLength else { return nil }
        let indices = ranges.indices.filter { NSIntersectionRange(ranges[$0], selection).length > 0 }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first..<(last + 1)
    }
    public func textRange(for tokens: Range<Int>) -> NSRange? {
        guard !tokens.isEmpty, tokens.lowerBound >= 0, tokens.upperBound <= ranges.count else { return nil }
        let first = ranges[tokens.lowerBound], last = ranges[tokens.upperBound - 1]
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
