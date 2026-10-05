import Foundation

/// UTF-16 ranges for rendering a reading line. Anchors identify an occurrence, not a phrase search.
public enum PerformanceRanges {
    public struct Match {
        public let range: NSRange
        public let moment: PerformanceMoment
    }
    public static func ranges(in text: String, tokenOffset: Int, moments: [PerformanceMoment]) -> [Match] {
        let map = ScriptTokenMap(text)
        let lineTokens = tokenOffset..<(tokenOffset + map.ranges.count)
        return moments.compactMap { moment in
            let range: NSRange?
            if let anchor = moment.tokenAnchor {
                let lower = max(anchor.lowerBound, lineTokens.lowerBound)
                let upper = min(anchor.upperBound, lineTokens.upperBound)
                guard lower < upper else { return nil }
                range = map.textRange(for: (lower - tokenOffset)..<(upper - tokenOffset))
            } else {
                range = text.range(of: moment.phrase, options: [.caseInsensitive, .diacriticInsensitive]).map { NSRange($0, in: text) }
            }
            return range.map { Match(range: $0, moment: moment) }
        }
    }
}
