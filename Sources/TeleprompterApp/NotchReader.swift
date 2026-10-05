import SwiftUI
import TeleprompterCore

/// The live reader and exact-size rehearsal preview share the same layout.
struct NotchReader: View {
    @ObservedObject var model: TeleprompterModel
    var isPreview = false
    var onReturnToScript: () -> Void = {}
    var onOpenDashboard: () -> Void = {}
    var body: some View {
        let snapshot = model.snapshot(at: .now)
        VStack(spacing: 0) {
            if let summary = snapshot.summary {
                VStack(spacing: 7) {
                    Text("Take complete").font(.system(size: 12, weight: .medium)).foregroundStyle(CuePalette.mint)
                    Text(summary.durationText).font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(CuePalette.cream)
                    Text("Active presentation time").font(.caption).foregroundStyle(.white.opacity(0.65))
                    Text(summary.comparison).font(.caption).foregroundStyle(CuePalette.peach)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let remaining = snapshot.countIn {
                VStack(spacing: 10) {
                    Text("Get comfortable").font(.system(size: 12, weight: .medium)).foregroundStyle(CuePalette.peach)
                    Text("\(remaining)").font(.system(size: 60, weight: .medium, design: .rounded)).foregroundStyle(CuePalette.cream)
                    Text("Your timer starts after the countdown").font(.caption).foregroundStyle(.white.opacity(0.6))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.document.tokens.isEmpty && !isPreview {
                Button(action: onOpenDashboard) {
                    Text("Choose a script in Studio")
                        .foregroundStyle(CuePalette.lavender)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the CameraCue dashboard to choose or create a script")
                .accessibilityLabel("Choose a script in Studio — open dashboard")
            } else {
                ReadingStage(document: model.document, performance: model.performance,
                    activeLineID: snapshot.lineID, textWidth: model.textWidth, fontSize: model.fontSize,
                    activeWordIndex: snapshot.wordIndex,
                    showAnnotations: snapshot.banner == nil, focused: model.focusedReading,
                    canSelect: !isPreview && !model.isRunning && !model.isStarting,
                    cueOverride: snapshot.cue, onSelect: model.selectPhrase)
            }
            HStack(spacing: 8) {
                Text(snapshot.problem ?? snapshot.status).lineLimit(1)
                    .foregroundStyle(snapshot.problem == nil ? .white.opacity(0.55) : CuePalette.butter)
                Spacer(minLength: 10)
                if snapshot.canFinish {
                    if isPreview { Text("Finish").foregroundStyle(CuePalette.lavender) }
                    else {
                        Button("Finish") { model.finish() }.buttonStyle(.plain)
                            .foregroundStyle(CuePalette.lavender)
                            .help("Finish prompting and freeze the timer. QuickTime keeps recording.")
                    }
                } else if snapshot.phase == .finished {
                    if isPreview { Text("Return to script").foregroundStyle(CuePalette.lavender) }
                    else {
                        Button("Return to script", action: onReturnToScript).buttonStyle(.plain)
                            .foregroundStyle(CuePalette.lavender)
                    }
                } else {
                    Text(model.scriptTitle).lineLimit(1).foregroundStyle(.white.opacity(0.35))
                }
            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 42).frame(height: 27)
        }.background(.black)
    }
}

struct ReadingStage: View {
    let document: ScriptDocument
    let performance: PerformanceStylePlan?
    let activeLineID: Int
    var textWidth: Double = 320
    var fontSize: Double = 29
    var activeWordIndex: Int? = nil
    var showAnnotations = true
    var focused = true
    var canSelect = false
    var cueOverride: String? = nil
    var onSelect: (Int) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var lines: [ScriptLine] { document.lines.filter { !$0.spokenText.isEmpty } }
    private var cue: String {
        guard showAnnotations, document.lines.indices.contains(activeLineID) else { return "" }
        if let cueOverride { return cueOverride }
        if let delivery = performance?.deliveryCue(for: document.lines[activeLineID]) { return delivery }
        if let annotation = document.lines[activeLineID].annotation { return annotation.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        if activeLineID > 0, let annotation = document.lines[activeLineID-1].annotation { return annotation.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        return performance?.pauseAfter(document.lines[activeLineID]) == true ? "Leave a little pause" : ""
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if !cue.isEmpty { CueIcon(.sparkle, size: 10); Text(cue).lineLimit(1) }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(CuePalette.peach)
                .frame(height: 22).frame(maxWidth: .infinity).help(cue)
            if lines.isEmpty {
                Text("Choose a script in Studio").foregroundStyle(CuePalette.lavender)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                  ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: focused ? 16 : 10) {
                            ForEach(lines) { line in
                                phrase(line, active: line.id == activeLineID).id(line.id)
                            }
                            // Keep even the final phrase at the reading anchor in
                            // a tall reader; a fixed spacer capped its scroll range.
                            Color.clear.frame(height: max(190, geometry.size.height))
                        }.frame(width: min(max(textWidth,230),350)).frame(maxWidth: .infinity)
                    }.scrollIndicators(.hidden)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .black, location: 0.82),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .onAppear { proxy.scrollTo(activeLineID, anchor: .top) }
                        .onChange(of: activeLineID) { _, id in
                            // A spring can retarget while still moving, without a
                            // fresh ease-out stop/start for every speech callback.
                            withAnimation(ReadingScrollMotion.animation(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                        // Wheel gestures cannot pull the reader away from the voice during a take.
                        .scrollDisabled(!canSelect)
                  }
                }
            }
        }.background(.black)
    }
    @ViewBuilder private func phrase(_ line: ScriptLine, active: Bool) -> some View {
        // Normalize progress per row so every word update doesn't rebuild all of
        // the visible upcoming/past phrases and re-run their typography work.
        let word = activeWordIndex.flatMap { index -> Int? in
            index < line.tokenRange.lowerBound ? nil : min(index, line.tokenRange.upperBound)
        }
        ReadingPhrase(lineID: line.id, spokenText: line.spokenText,
                      tokenOffset: line.tokenRange.lowerBound,
                      moments: performance?.displayMoments(for: line) ?? [],
                      size: min(32, max(20, fontSize)), strength: performance?.intensity ?? 0.65,
                      maximumScale: 1 + 0.06 * (performance?.intensity ?? 1),
                      wordIndex: word,
                      opacity: active || activeWordIndex.map(line.tokenRange.contains) == true ? 1 : (focused ? 0.62 : 0.7),
                      canSelect: canSelect, onSelect: onSelect).equatable()
    }
}

enum ReadingScrollMotion {
    static func animation(reduceMotion: Bool, responsiveness: Double = 0.55) -> Animation? {
        guard !reduceMotion else { return nil }
        return .interpolatingSpring(duration: 0.18 + (1 - min(1, max(0, responsiveness))) * 0.12, bounce: 0)
    }
}

private struct ReadingPhrase: View, Equatable {
    let lineID: Int
    let spokenText: String
    let tokenOffset: Int
    let moments: [PerformanceMoment]
    let size: Double
    let strength: Double
    let maximumScale: Double
    let wordIndex: Int?
    let opacity: Double
    let canSelect: Bool
    let onSelect: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lineID == rhs.lineID && lhs.spokenText == rhs.spokenText && lhs.tokenOffset == rhs.tokenOffset &&
        lhs.moments == rhs.moments && lhs.size == rhs.size && lhs.strength == rhs.strength &&
        lhs.maximumScale == rhs.maximumScale && lhs.wordIndex == rhs.wordIndex &&
        lhs.opacity == rhs.opacity && lhs.canSelect == rhs.canSelect
    }

    @ViewBuilder var body: some View {
        let text = PerformanceText.make(spokenText, moments: moments, tokenOffset: tokenOffset,
                base: CuePalette.cream, accent: CuePalette.lavender,
                baseSize: size, intensity: 1, strength: strength,
                maximumScale: maximumScale, activeWordIndex: wordIndex)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .opacity(opacity)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
        if canSelect {
            Button { onSelect(lineID) } label: { text }
                .buttonStyle(.plain).help("Continue from this phrase").accessibilityLabel(spokenText)
        } else { text.accessibilityLabel(spokenText) }
    }
}
