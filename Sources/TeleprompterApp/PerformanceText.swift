import Foundation
import SwiftUI
import TeleprompterCore

enum PerformanceText {
    enum ReadingState { case upcoming, current, spoken }
    struct Segment {
        let text: String
        let moment: PerformanceMoment?
        let readingState: ReadingState
    }

    static func make(_ source: String, moment: PerformanceMoment?, base: Color, accent: Color,
                     baseSize: CGFloat, intensity: Double, strength: Double = 1, maximumScale: CGFloat = 1.43) -> Text {
        make(source, moments: moment.map { [$0] } ?? [], tokenOffset: 0, base: base, accent: accent,
             baseSize: baseSize, intensity: intensity, strength: strength, maximumScale: maximumScale)
    }

    /// Preserve the exact source, including punctuation and Unicode. A contraction
    /// may represent two recognition tokens, but highlights as one printed word.
    static func segments(_ source: String, moments: [PerformanceMoment], tokenOffset: Int,
                         activeWordIndex: Int?) -> [Segment] {
        let ns = source as NSString
        let ranges = PerformanceRanges.ranges(in: source, tokenOffset: tokenOffset, moments: moments)
        var current: NSRange?
        var spokenEnd = 0
        if let activeWordIndex, activeWordIndex >= tokenOffset {
            let words = ScriptTokenMap(source).ranges
            let localIndex = activeWordIndex - tokenOffset
            if words.indices.contains(localIndex) {
                current = words[localIndex]
                spokenEnd = words[localIndex].location
            } else if !words.isEmpty {
                spokenEnd = ns.length
            }
        }
        let wordBoundaries = current.map { [$0.location, NSMaxRange($0)] } ?? []
        let boundaries = Set([0, ns.length, spokenEnd] + wordBoundaries + ranges.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let state: ReadingState = current.map { NSLocationInRange(start, $0) } == true
                ? .current : start < spokenEnd ? .spoken : .upcoming
            return Segment(text: ns.substring(with: NSRange(location: start, length: end - start)),
                           moment: ranges.last(where: { NSLocationInRange(start, $0.range) })?.moment,
                           readingState: state)
        }
    }

    static func make(_ source: String, moments: [PerformanceMoment], tokenOffset: Int, base: Color, accent: Color,
                     baseSize: CGFloat, intensity: Double, strength: Double = 1, maximumScale: CGFloat = 1.43,
                     activeWordIndex: Int? = nil) -> Text {
        var result = Text("")
        for segment in segments(source, moments: moments, tokenOffset: tokenOffset, activeWordIndex: activeWordIndex) {
            var styled = Text(segment.text)
            var color = base
            if let moment = segment.moment {
                let tint: Color
                switch moment.tone {
                case .neutral: tint = base
                case .cyan: tint = CuePalette.sky
                case .amber: tint = CuePalette.butter
                case .coral: tint = CuePalette.coral
                }
                let multiplier: CGFloat = moment.scale == .huge ? 1.43 : moment.scale == .large ? 1.22 : 1
                styled = styled.font(.system(size: baseSize * min(1 + (multiplier - 1) * strength, maximumScale),
                                             weight: multiplier > 1 ? .bold : .semibold, design: .rounded))
                color = Color(nsColor: NSColor(base).blended(withFraction: strength, of: NSColor(tint)) ?? NSColor(tint)).opacity(intensity)
            }
            switch segment.readingState {
            case .current: color = accent
            case .spoken: color = color.opacity(0.48)
            case .upcoming: break
            }
            // Only color changes with speech. Font metrics and line wrapping remain
            // identical as the highlight passes through the existing delivery style.
            result = result + styled.foregroundColor(color)
        }
        return result
    }
}
