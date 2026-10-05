import SwiftUI
import TeleprompterCore

struct ScriptReadingPreview: View {
    let script: ScriptRecord?
    private let accent = CuePalette.lavender

    var body: some View {
        let source = script?.performance?.formattedBody ?? script?.body ?? ""
        let document = ScriptDocument(source)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Capsule().fill(.white.opacity(0.17)).frame(width: 43, height: 7)
                Spacer()
            }
            .frame(height: 26)
            accent.frame(height: 2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Your words will appear here, close to the camera.")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(document.lines) { line in
                        if let annotation = line.annotation, line.spokenText.isEmpty {
                            Text(annotation.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(0.8).foregroundStyle(accent.opacity(0.85))
                        } else if line.spokenText.isEmpty {
                            Color.clear.frame(height: 6)
                        } else {
                            PerformanceText.make(line.spokenText,
                                                 moments: script?.performance?.displayMoments(for: line) ?? [], tokenOffset: line.tokenRange.lowerBound,
                                                 base: .white.opacity(0.9), accent: accent,
                                                 baseSize: 21, intensity: 1)
                                .font(.system(size: 21, weight: .medium, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(17)
            }
            .scrollIndicators(.hidden)
        }
        .background(.black, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CuePalette.lavender.opacity(0.45)))
    }
}
