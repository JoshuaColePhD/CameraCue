import Foundation
import SwiftUI

/// Colors written emphasis without changing the spoken text or its line breaks.
enum EmphasisText {
    static func make(_ source: String, base: Color, emphasis: Color) -> Text {
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z])[A-Z][A-Z'’-]{1,}(?:\s+[A-Z][A-Z'’-]{1,})*"#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        var result = Text("")
        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            result = result + Text(String(source[cursor..<range.lowerBound])).foregroundColor(base)
            result = result + Text(String(source[range])).foregroundColor(emphasis).bold()
            cursor = range.upperBound
        }
        return result + Text(String(source[cursor...])).foregroundColor(base)
    }
}
