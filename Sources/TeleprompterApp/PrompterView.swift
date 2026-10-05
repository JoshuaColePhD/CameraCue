import AppKit
import SwiftUI
import TeleprompterCore

struct PrompterView: View {
    @EnvironmentObject private var model: TeleprompterModel
    @EnvironmentObject private var library: ScriptLibrary
    @State private var window: NSWindow?
    @FocusState private var keyboardFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = CuePalette.lavender

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !model.focusMode { toolbar }
                progressTrack
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.document.lines) { line in
                                lineView(line)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: geometry.size.height * 0.72)
                        }
                        .frame(maxWidth: min(model.textWidth, geometry.size.width - 32), alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.top, model.focusMode ? 18 : 12)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(model.displayedScrollTarget, anchor: .top) }
                    .onChange(of: model.displayedScrollTarget) { _, target in
                        withAnimation(ReadingScrollMotion.animation(reduceMotion: reduceMotion, responsiveness: model.responsiveness)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
                if !model.focusMode { footer }
            }
            .background(Color(red: 0.055, green: 0.065, blue: 0.09).opacity(model.backgroundOpacity))
            .overlay(alignment: .top) { if model.focusMode { Rectangle().fill(accent.opacity(0.12)).frame(height: 2) } }
            .focusable()
            .focused($keyboardFocus)
            .onMoveCommand { direction in
                switch direction {
                case .up: model.move(lines: -1)
                case .down: model.move(lines: 1)
                case .left: model.moveBeat(direction: -1)
                case .right: model.moveBeat(direction: 1)
                default: break
                }
            }
            .onAppear {
                keyboardFocus = true
                if let selected = library.selected { model.load(selected) }
            }
            .background(WindowAccessor { window = $0 })
        }
        .frame(minWidth: 300, minHeight: 210)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isRunning ? accent : CuePalette.peach)
                .frame(width: 6, height: 6)
                .shadow(color: model.isRunning ? accent.opacity(0.5) : .clear, radius: 5)
            Text(model.isRunning ? "FOLLOWING" : "READY")
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.7)
                .foregroundStyle(model.isRunning ? accent : Color.white.opacity(0.6))
            Spacer()
            Button { if let window { CameraWindow.placeBelowCamera(window) } } label: {
                CueIcon(systemName: "web.camera")
            }
            .help("Place below camera")
            Button { model.focusMode.toggle() } label: { CueIcon(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Focus mode")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.56))
        .padding(.horizontal, 16)
        .frame(height: 39)
    }

    private var progressTrack: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.07)
                accent.opacity(0.8).frame(width: bar.size.width * model.progress)
            }
        }
        .frame(height: 2)
        .accessibilityLabel("Script progress")
        .accessibilityValue("\(Int(model.progress * 100)) percent")
    }

    @ViewBuilder private func lineView(_ line: ScriptLine) -> some View {
        let active = line.id == model.activeLineID
        let isCueOnly = line.spokenText.isEmpty && line.annotation != nil
        let isEmpty = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            Color.clear.frame(height: 16)
        } else if isCueOnly {
            if model.showAnnotations {
                HStack(spacing: 6) {
                    CueIcon(systemName: line.isPause ? "pause.fill" : "sparkle")
                        .font(.system(size: 9, weight: .bold))
                    Text(line.annotation?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .textCase(.uppercase)
                        .tracking(1.15)
                }
                .foregroundStyle(line.isPause ? CuePalette.butter : accent.opacity(0.7))
                .padding(.vertical, line.isPause ? 11 : 6)
                .accessibilityLabel("Delivery cue: \(line.annotation ?? "")")
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if model.showAnnotations, let cue = line.annotation {
                    Text(cue).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent.opacity(0.7))
                }
                PerformanceText.make(line.spokenText,
                                     moments: model.performance?.displayMoments(for: line) ?? [], tokenOffset: line.tokenRange.lowerBound,
                                     base: active ? .white : .white.opacity(line.id < model.activeLineID ? 0.28 : 0.62),
                                     accent: active ? accent : accent.opacity(line.id < model.activeLineID ? 0.25 : 0.55),
                                     baseSize: model.fontSize,
                                     intensity: active ? 1 : (line.id < model.activeLineID ? 0.28 : 0.62),
                                     activeWordIndex: model.snapshot(at: .now).wordIndex)
                    .font(.system(size: model.fontSize + (line.isEmphatic ? 1 : 0), weight: active ? .semibold : (line.isEmphatic ? .medium : .regular), design: .rounded))
                    .tracking(line.isEmphatic ? 0.6 : -0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, line.isEmphatic ? 5 : 2)
            .padding(.bottom, model.performance?.pauseAfter(line) == true ? 20 : 0)
            .animation(.easeInOut(duration: 0.25), value: active)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.toggle() }
            } label: {
                CueIcon(systemName: model.isRunning ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .help(model.isRunning ? "Pause (Control–Option–Space)" : "Start (Control–Option–Space)")
            .disabled(model.isStarting || (model.mode != .manual && model.speech.isAuthorizing) || model.wordCount == 0)
            Text(model.mode.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
            Spacer()
            if model.mode == .rehearsal {
                Text("\(Int(model.progress * 100))%")
                    .monospacedDigit().font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.presentationTime(at: context.date))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(model.presentationIsOvertime(at: context.date)
                                     ? Color(red: 1, green: 0.43, blue: 0.43)
                                     : .white.opacity(0.75))
                    .accessibilityLabel(model.timerMode == .countdown ? "Time remaining" : "Presentation time")
            }
            Button { model.move(lines: -1) } label: { CueIcon(systemName: "chevron.up") }.help("Previous line")
            Button { model.move(lines: 1) } label: { CueIcon(systemName: "chevron.down") }.help("Next line")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(.white.opacity(0.035))
    }
}
