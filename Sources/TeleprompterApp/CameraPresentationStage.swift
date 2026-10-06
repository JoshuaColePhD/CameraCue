import AppKit
import AVFoundation
import AVKit
import SwiftUI
import TeleprompterCore

/// Studio owns framing and take review; the real notch owns the spoken script.
struct CameraPresentationStage: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var video: CameraRecording
    @State private var hidesSelfView = false
    @State private var audioLevel = 0.0
    @State private var editsBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.phase == .finished ? "TAKE REVIEW" : "CAMERA", systemImage: "video")
                    .font(.system(size: 11, weight: .bold)).tracking(1)
                Spacer()
                if video.isRecording {
                    Label("Recording", systemImage: "circle.fill").foregroundStyle(StudioPalette.coral)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            if model.phase == .finished && video.enabled && video.state == .saved, let url = video.savedURL {
                SavedTakePlayer(url: url)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.black)
                    if (video.state == .ready || video.isRecording) && !hidesSelfView {
                        ProcessedCameraPreview(frames: video.previewFrames)
                            .accessibilityLabel("Mirrored camera preview. Saved video is not mirrored.")
                    } else {
                        VStack(spacing: 14) {
                            if video.isBusy { ProgressView().tint(StudioPalette.lavender) }
                            else { Image(systemName: hidesSelfView ? "eye.slash" : "video").font(.system(size: 32)).foregroundStyle(StudioPalette.lavender) }
                            Text(stageMessage).font(.headline).foregroundStyle(.white)
                            Text(stageDetail).font(.callout).foregroundStyle(StudioPalette.lavender).multilineTextAlignment(.center)
                        }.padding(28)
                    }
                }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if video.enabled && model.phase == .ready { CameraBackgroundPicker(video: video, locked: model.displayIsLocked) }
            if video.isRecording {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill").foregroundStyle(StudioPalette.violet)
                    ProgressView(value: audioLevel).tint(StudioPalette.mint)
                        .accessibilityLabel("Recording microphone level")
                    Button(hidesSelfView ? "Show self-view" : "Hide self-view") { hidesSelfView.toggle() }
                        .buttonStyle(StudioButtonStyle())
                }
                Text("Video and audio keep recording when you pause prompting.")
                    .font(.caption).foregroundStyle(StudioPalette.mutedInk)
            } else if model.phase == .ready && video.enabled {
                HStack {
                    Button(video.state == .ready ? "Hide camera preview" : "Preview camera") {
                        hidesSelfView = false
                        if video.state == .ready { video.closePreview() }
                        else { Task { _ = await video.prepare() } }
                    }.buttonStyle(StudioButtonStyle()).disabled(video.isBusy)
                    if video.state == .preparing {
                        Button("Cancel camera setup") { video.closePreview() }.buttonStyle(StudioButtonStyle())
                    }
                    Spacer()
                    Text("Check your framing and lighting").font(.caption).foregroundStyle(StudioPalette.mutedInk)
                }
            }
            if model.phase == .finished, let summary = model.summary {
                HStack {
                    Label("\(summary.durationText) prompting", systemImage: "timer")
                    Spacer()
                    Text(summary.comparison).foregroundStyle(StudioPalette.violet)
                }.font(.callout)
                if summary.timerWasReset {
                    Text("Timer reset during this take · final segment \(TakeSummary.time(summary.timerDuration)).")
                        .font(.caption).foregroundStyle(StudioPalette.mutedInk)
                }
            }
            if model.phase == .finished && video.enabled && video.state == .saved, let url = video.savedURL {
                if let notice = video.saveNotice { Text(notice).font(.caption).foregroundStyle(StudioPalette.mutedInk) }
                Button("Change background") { editsBackground = true }.buttonStyle(StudioButtonStyle())
                if let original = video.originalSavedURL {
                    Button("Show original camera video") { NSWorkspace.shared.activateFileViewerSelecting([original]) }.buttonStyle(StudioButtonStyle())
                }
                Text(url.lastPathComponent).font(.caption).foregroundStyle(StudioPalette.mutedInk).textSelection(.enabled)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    StudioLabel("Show in Finder", systemImage: "folder")
                }.buttonStyle(StudioButtonStyle())
            }
            if video.state == .failed {
                Text(video.message).font(.callout).foregroundStyle(StudioPalette.ink)
                if video.recoveryURL != nil {
                    Button("Retry MP4 save") { video.retrySave() }.buttonStyle(StudioButtonStyle())
                    Button("Show original recording") {
                        if let url = video.recoveryURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.buttonStyle(StudioButtonStyle())
                }
            }
        }.padding(20).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 24))
            .sheet(isPresented: $editsBackground) {
                if let url = video.savedURL { RecordingReview(url: url, initiallyEditing: true, onDone: { editsBackground = false }) }
            }
            .onAppear { video.refreshDevices() }
            .task(id: video.isRecording) {
                audioLevel = 0
                guard video.isRecording else { hidesSelfView = false; return }
                while !Task.isCancelled && video.isRecording {
                    audioLevel = await video.recordingAudioLevel()
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                }
            }
    }
    private var stageMessage: String {
        if video.state == .saving { return "Saving your take…" }
        if video.state == .preparing { return "Preparing camera…" }
        if video.state == .failed { return "Camera needs attention" }
        if hidesSelfView { return "You're still recording" }
        if !video.enabled { return "Prompting only" }
        if model.phase == .finished { return "Take finished" }
        return "Find your best frame"
    }
    private var stageDetail: String {
        if video.state == .saving { return "Your MP4 will appear here when it is ready." }
        if video.state == .failed { return video.message }
        if hidesSelfView { return "Keep your eyes on the words beneath the lens." }
        if !video.enabled { return "Use QuickTime to record, and CameraCue Studio to follow your words." }
        if model.phase == .finished { return "Review your timing, then try another take." }
        return "Preview your camera before starting. Read your script in the notch."
    }
}

struct SavedTakePlayer: View {
    let url: URL
    var seekRequest: PlaybackSeekRequest? = nil
    @State private var player: AVPlayer?
    @State private var pendingSeek: PlaybackSeekRequest?
    @State private var duration: String?
    @State private var playbackError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SavedVideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Saved take playback")
            if let playbackError { Text(playbackError).font(.system(size: 14)).foregroundStyle(StudioPalette.mutedInk) }
            if let duration { Text("Video duration · \(duration)").font(.caption).foregroundStyle(StudioPalette.mutedInk) }
        }.task(id: url) {
            player?.pause(); player = nil
            pendingSeek = seekRequest
            playbackError = nil
            guard (try? await AVURLAsset(url: url).load(.isPlayable)) == true else {
                player = nil; duration = nil
                playbackError = "This recording is missing or cannot be played. Use Show in Finder to check the file."
                return
            }
            guard !Task.isCancelled else { return }
            player = AVPlayer(url: url)
            if let pendingSeek {
                player?.seek(to: CMTime(seconds: max(0, pendingSeek.seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { @Sendable _ in })
                player?.play()
                self.pendingSeek = nil
            }
            duration = nil
            if let time = try? await AVURLAsset(url: url).load(.duration), time.seconds.isFinite {
                duration = TakeSummary.time(time.seconds)
            }
        }.onChange(of: seekRequest, initial: true) { _, request in
            guard let request, request.seconds.isFinite else { return }
            pendingSeek = player == nil ? request : nil
            player?.seek(to: CMTime(seconds: max(0, request.seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { @Sendable _ in })
            player?.play()
        }.onDisappear { player?.pause(); player = nil }
    }
}

/// Use AVPlayerView directly; the SDK's generic SwiftUI VideoPlayer wrapper
/// aborts during metadata initialization on the target macOS runtime.
struct SavedVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
