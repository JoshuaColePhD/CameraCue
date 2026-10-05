import SwiftUI

struct TimerSettingsView: View {
    @ObservedObject var model: TeleprompterModel
    var onClose: (() -> Void)?
    private var minutes: Binding<Int> {
        Binding(get: { model.countdownMinutes }, set: { model.countdownMinutes = min(180, max(1, $0)) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(StudioPalette.violet)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your presentation timer").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Find a comfortable pace.").font(.system(size: 12)).foregroundStyle(StudioPalette.mutedInk)
                }
                Spacer(minLength: 0)
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(StudioButtonStyle()).accessibilityLabel("Close timer settings")
                        .help("Close timer settings").keyboardShortcut(.cancelAction)
                }
            }
            HStack(spacing: 8) {
                directionButton(.countUp, symbol: "arrow.up", subtitle: "Track elapsed time")
                directionButton(.countdown, symbol: "arrow.down", subtitle: "Set a time target")
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.timerMode == .countdown ? "TIME TARGET" : "ELAPSED TIME")
                            .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(StudioPalette.mutedInk)
                        if model.timerMode == .countdown {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                TextField("Minutes", value: minutes, format: .number)
                                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .textFieldStyle(.plain).frame(width: 70)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.outline))
                                    .accessibilityLabel("Countdown minutes, from 1 to 180")
                                Text("min").font(.system(size: 13)).foregroundStyle(StudioPalette.mutedInk)
                                Stepper("Countdown minutes", value: minutes, in: 1...180).labelsHidden()
                            }
                        } else {
                            Text("No time limit").font(.system(size: 19, weight: .semibold, design: .rounded))
                        }
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("ON THE NOTCH").font(.system(size: 9, weight: .semibold)).tracking(0.5)
                                .foregroundStyle(StudioPalette.mutedInk)
                            Text(model.presentationTime(at: context.date))
                                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(model.presentationIsOvertime(at: context.date) ? StudioPalette.coral : StudioPalette.ink)
                        }.accessibilityElement(children: .combine)
                    }
                }
                if model.timerMode == .countdown {
                    HStack(spacing: 6) {
                        ForEach([3, 5, 10, 15, 30], id: \.self) { value in
                            Button("\(value)m") { minutes.wrappedValue = value }
                                .buttonStyle(StudioButtonStyle(primary: model.countdownMinutes == value))
                                .accessibilityLabel("\(value) minutes")
                                .accessibilityValue(model.countdownMinutes == value ? "Selected" : "")
                        }
                    }
                    Text("After zero, the timer shows how far over you are.")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.mutedInk)
                } else {
                    Text("Starts with prompting and pauses when you pause.")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.mutedInk)
                }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .background(StudioPalette.lavenderWash.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Gentle pacing hints", isOn: $model.showPaceHints)
                        .toggleStyle(.switch).font(.system(size: 13, weight: .semibold))
                        .disabled(model.timerMode != .countdown)
                    Text(model.timerMode != .countdown
                         ? "Choose Countdown to get pacing hints for a time target."
                         : model.mode == .manual
                         ? "Available with Voice Follow. Switch following mode while paused to use hints."
                         : "The notch gently pulses to suggest speeding up, slowing down, or wrapping up. Your words still follow your voice.")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 2).frame(minHeight: 72, alignment: .topLeading)
            Rectangle().fill(StudioPalette.outline.opacity(0.65)).frame(height: 1)
            HStack {
                Button { model.resetTimer() } label: { Label("Reset timer", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(StudioButtonStyle()).help("Restart the timer without changing your reading position")
                Spacer()
                if let onClose {
                    Button("Done", action: onClose).buttonStyle(StudioButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                }
            }
            Text("Changes apply immediately. Your reading position stays put.")
                .font(.system(size: 10)).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: TimerPopoverPlacement.width).background(StudioPalette.canvas)
        .foregroundStyle(StudioPalette.ink).tint(StudioPalette.violet).preferredColorScheme(.light)
    }
    private func directionButton(_ direction: TeleprompterModel.TimerMode, symbol: String, subtitle: String) -> some View {
        Button { model.timerMode = direction } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(direction.rawValue, systemImage: symbol)
                Text(subtitle).font(.system(size: 10, weight: .regular))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(StudioButtonStyle(primary: model.timerMode == direction))
        .accessibilityValue(model.timerMode == direction ? "Selected" : "")
    }
}
