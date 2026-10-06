import AppKit
import SwiftUI
import TeleprompterCore

enum StudioStep: String, CaseIterable { case write = "Write", rehearse = "Rehearse", present = "Present" }

struct PresentationWorkspace: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var notch: NotchController
    @ObservedObject var library: ScriptLibrary
    @Binding var step: StudioStep
    @StateObject private var audio = AudioInputCheck()
    @State private var showAdjust = false

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    StudioPageHeader(title: heading, subtitle: model.scriptTitle + " · \(model.wordCount) words")
                    Spacer()
                    Button { showAdjust.toggle() } label: { StudioLabel("Adjust", systemImage: "slider.horizontal.3") }
                        .buttonStyle(StudioButtonStyle()).popover(isPresented: $showAdjust) { adjustments.padding(20).frame(width: 395) }
                }
                if step == .present {
                    if StudioLayout.stacksCamera(width: geometry.size.width) {
                        VStack(alignment: .leading, spacing: 16) {
                            CameraPresentationStage(model: model, video: model.video)
                            presentationCard
                            if model.phase == .paused { phraseRecovery }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            CameraPresentationStage(model: model, video: model.video).frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 16) {
                                presentationCard
                                if model.phase == .paused { phraseRecovery }
                            }.frame(width: 280)
                        }
                    }
                    Button { notch.show(model: model, library: library) } label: {
                        StudioLabel("Open script in the notch", .reader)
                    }.buttonStyle(StudioButtonStyle())
                } else {
                ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("LIVE NOTCH PREVIEW · CONTROLS DISABLED")
                            .font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(StudioPalette.violet)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            LiveNotchPreview(model: model, layout: notch.layout, scale: notch.display?.scale ?? 2, date: context.date)
                                .frame(width: notch.layout.size.width, height: notch.layout.size.height)
                        }.allowsHitTesting(false)
                        Text("Matches the selected display. The reader stays near your camera and follows your voice.")
                            .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                        Button { notch.show(model: model, library: library) } label: { StudioLabel("Open beneath the camera", .reader) }
                            .buttonStyle(StudioButtonStyle())
                        if model.phase == .paused { phraseRecovery }
                        if model.phase == .ready, let previous = model.latestSummary {
                            Text("Last take · \(previous.durationText) active · \(previous.comparison)")
                                .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                        }
                        if model.phase == .finished, let summary = model.summary {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(summary.durationText) active presentation time").font(.title2.bold())
                                Text(summary.comparison).foregroundStyle(StudioPalette.violet)
                                if summary.timerWasReset {
                                    Text("Timer was reset during this take. Final segment: \(TakeSummary.time(summary.timerDuration)). Total presentation time includes every active segment.")
                                        .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                                }
                                Text(model.video.enabled ? "Your camera recording saves when you finish the take." : "QuickTime keeps recording until you stop it there.").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.mint.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.frame(width: notch.layout.size.width)
                    VStack(alignment: .leading, spacing: 16) {
                        presentationCard
                    }.frame(width: 280, alignment: .leading)
                }
                VStack(spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LiveNotchPreview(model: model, layout: notch.layout, scale: notch.display?.scale ?? 2, date: context.date)
                            .frame(width: notch.layout.size.width, height: notch.layout.size.height)
                    }.allowsHitTesting(false).frame(maxWidth: .infinity)
                    Button("Open beneath the camera") { notch.show(model: model, library: library) }.buttonStyle(StudioButtonStyle())
                    presentationCard
                }
                }
                }
                if step == .rehearse && model.phase == .ready { phraseRecovery }
            }.padding(24)
        }.background(StudioPalette.canvas).foregroundStyle(StudioPalette.ink)
            .onDisappear { audio.stop(); model.video.closePreview() }
            .onChange(of: model.isStarting) { _, starting in if starting { audio.stop() } }
            .onChange(of: step) { _, _ in audio.stop() }
        }
    }
    private var heading: String {
        switch model.phase {
        case .finished: return "A take to build on."
        case .running: return "You're presenting."
        case .paused: return "Take a breath."
        case .countIn, .starting: return "Get comfortable."
        case .ready: return step == .rehearse ? "Find your comfortable read." : "Ready for your next take?"
        }
    }
    private var presentationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase == .ready {
                Text("Before you begin").font(.system(size: 18, weight: .semibold, design: .rounded))
                if step == .present && model.video.enabled {
                    Label(model.video.cameras.first { $0.id == model.video.cameraID }?.name ?? "Default camera", systemImage: "video").font(.callout)
                }
                Text(model.timerMode == .countdown ? "\(model.countdownMinutes)-minute target" : "Count up timer").foregroundStyle(StudioPalette.violet)
                if model.mode != .manual {
                    Text(audio.deviceName).font(.system(size: 13, weight: .semibold))
                    ProgressView(value: audio.level).tint(StudioPalette.violet).accessibilityLabel("Microphone input level")
                    Button {
                        if audio.isChecking { audio.stop() }
                        else { Task { await audio.start(onPermissionPrompt: notch.setPermissionPromptActive) } }
                    } label: { StudioLabel(audio.isPreparing ? "Waiting for access…" : audio.isChecking ? "Finish input check" : "Check microphone", .microphone) }
                        .buttonStyle(StudioButtonStyle()).disabled(audio.isPreparing)
                    Text(audio.message).font(.caption).foregroundStyle(StudioPalette.mutedInk)
                }
                if model.personalPacingEnabled {
                    Text(model.paceProfile.usualWordsPerMinute.map { "Personal pace calibrated · \(Int($0)) words/min" } ?? "Personal pace learns from reliable rehearsal passages on this Mac.")
                        .font(.caption).foregroundStyle(StudioPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("3-second count-in", isOn: $model.useCountIn)
                PresentationReadiness(model: model, speech: model.speech, showsSetupAction: false, showsShortcutHints: step != .present)
                PresentationStartAction(model: model, speech: model.speech) {
                    audio.stop(); notch.show(model: model, library: library)
                    Task { await model.toggle() }
                } beforeSetup: { audio.stop() }
                Text(model.video.enabled ? "Record starts your camera, microphone, prompting, and timer. Stop saves an MP4." : "Start recording in QuickTime first. CameraCue Studio starts prompting and its own timer.")
                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
            } else if model.phase == .finished {
                Text("Finished").font(.title3.bold())
                Button { model.reset() } label: { StudioLabel(model.video.enabled ? "Record another take" : "Practice again", .restart) }.buttonStyle(StudioButtonStyle(primary: true)).disabled(model.video.isBusy)
                Button { step = .write } label: { StudioLabel("Return to script", .back) }.buttonStyle(StudioButtonStyle())
                Text("Practice again returns to Ready. Your microphone stays off until you start.").font(.caption).foregroundStyle(StudioPalette.mutedInk)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let snapshot = model.snapshot(at: context.date)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshot.status).font(.title3.bold())
                        if let forecast = model.personalPaceEstimate {
                            Text("Estimated script remaining · " + TakeSummary.time(forecast.remainingSeconds))
                                .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                        }
                        Text(snapshot.timerText).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(snapshot.overtime ? StudioPalette.violet : StudioPalette.ink)
                        if let message = snapshot.problem ?? snapshot.banner {
                            Text(message).font(.callout).foregroundStyle(StudioPalette.violet)
                        }
                    }
                }
                Button { audio.stop(); Task { await model.toggle() } } label: {
                    StudioLabel(model.phase == .running ? "Pause prompting" : model.phase == .paused ? "Resume" : model.phase == .countIn ? "Cancel countdown" : "Getting ready…", model.isRunning ? .pause : .play)
                }.buttonStyle(StudioButtonStyle()).disabled(model.phase == .starting)
                if model.snapshot(at: .now).canFinish {
                    Button { model.finish() } label: { StudioLabel(model.video.isRecording ? "Stop and save video" : "Finish prompting", systemImage: "stop.fill") }.buttonStyle(StudioButtonStyle(primary: model.video.isRecording, accent: StudioPalette.coral))
                }
                Text(model.video.isRecording ? "Camera is recording, including while prompting is paused. Stop and save when you are done." : model.phase == .paused ? "Choose a phrase to recover your place, then resume when ready." : "Stay with your words. Finish prompting when your closing remarks are done.")
                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
            }
        }.padding(16).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline))
    }
    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make yourself comfortable").font(.headline)
            Text("Phrase width · \(Int(model.textWidth)) pt")
            Slider(value: $model.textWidth, in: 230...350).accessibilityLabel("Phrase width")
            Text("Text size · \(Int(model.fontSize)) pt")
            Slider(value: $model.fontSize, in: 20...32).accessibilityLabel("Reading text size")
            Toggle("Focused phrases", isOn: $model.focusedReading)
            Toggle("Delivery cues", isOn: $model.showAnnotations)
            Picker("Follow", selection: $model.mode) {
                Text("Voice Follow").tag(TeleprompterModel.Mode.voice)
                Text("Manual").tag(TeleprompterModel.Mode.manual)
            }.disabled(model.isRunning || model.isStarting)
            if model.isRunning { Text("Pause before changing following mode.").font(.caption) }
            Divider()
            if step == .present {
                CameraRecordingView(video: model.video, locked: model.takeInProgress || model.isStarting, showsPreview: false)
            }
            TimerSettingsView(model: model)
            Button("New take") { audio.stop(); model.reset(); showAdjust = false }.buttonStyle(StudioButtonStyle())
        }.foregroundStyle(StudioPalette.ink).background(StudioPalette.canvas)
    }
    private var phraseRecovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PICK UP FROM A PHRASE").font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(StudioPalette.violet)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.document.lines.filter { !$0.spokenText.isEmpty }) { line in
                        Button { model.selectPhrase(line.id) } label: {
                            HStack { CueIcon(line.id == model.activeLineID ? .play : .reader, size: 14); Text(line.spokenText); Spacer() }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.id == model.activeLineID ? StudioPalette.lavenderWash : StudioPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 150)
        }
    }
}

private struct PresentationStartAction: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var speech: SpeechFollower
    var start: () -> Void
    var beforeSetup: () -> Void
    private var needsSetup: Bool { model.mode != .manual && (speech.needsPermissionSetup || speech.state == .denied) }
    var body: some View {
        Button {
            if needsSetup && speech.state == .denied { NSWorkspace.shared.open(speech.permissionSettingsURL) }
            else if needsSetup { beforeSetup(); Task { await speech.prepare() } }
            else { start() }
        } label: { StudioLabel(needsSetup ? speech.state == .denied ? "Open Voice Follow settings" : "Set up Voice Follow" : model.video.enabled ? "Record video" : "Start prompting", needsSetup ? .microphone : .play) }
            .buttonStyle(StudioButtonStyle(primary: true, accent: needsSetup || !model.video.enabled ? StudioPalette.lavender : StudioPalette.coral)).disabled(model.wordCount == 0 || speech.isAuthorizing || (model.video.state == .saving || model.video.state == .preparing))
    }
}
