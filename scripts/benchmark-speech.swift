import Foundation

@main struct SpeechBenchmark {
    static func main() throws {
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let document = ScriptDocument(source)
        let aligner = ScriptAligner(script: document)
        var samples: [Double] = []
        var positions: [Int] = []
        for count in 2...document.tokens.count {
            let transcript = document.tokens.prefix(count).joined(separator: " ")
            let start = DispatchTime.now().uptimeNanoseconds
            let result = aligner.align(transcript)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            positions.append(result.tokenIndex)
        }
        let sorted = samples.sorted()
        let report: [String: Any] = ["samples": samples.count, "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count) * 0.95)], "max_ms": sorted.last!, "positions": positions]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
