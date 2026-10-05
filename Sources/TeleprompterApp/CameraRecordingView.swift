import AppKit
import AVFoundation
import SwiftUI

struct CameraRecordingView: View {
    @ObservedObject var video: CameraRecording
    var locked: Bool
    var showsPreview = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Save a camera video", isOn: $video.enabled)
                .font(.system(size: 14, weight: .semibold)).tint(StudioPalette.violet).disabled(locked || video.isBusy)
            if video.enabled {
                if !locked {
                    Picker("Camera", selection: $video.cameraID) {
                        Text("Default camera").tag("")
                        ForEach(video.cameras) { Text($0.name).tag($0.id) }
                    }.disabled(video.isBusy)
                    Picker("Recording microphone", selection: $video.microphoneID) {
                        Text("Default microphone").tag("")
                        ForEach(video.microphones) { Text($0.name).tag($0.id) }
                    }.disabled(video.isBusy)
                }
                if !locked { Text("Voice Follow uses the Mac’s default microphone.").font(.caption2).foregroundStyle(StudioPalette.mutedInk) }
                if showsPreview && (video.state == .ready || video.isRecording) {
                    ProcessedCameraPreview(frames: video.previewFrames).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Camera preview · mirrored; saved video is not mirrored")
                }
                Toggle("Keep an original copy for later background edits", isOn: $video.keepOriginalVideo)
                    .font(.system(size: 12)).tint(StudioPalette.violet).disabled(locked || video.isBusy)
                Text("When an effect is used, saves an additional camera video with the real background. Uses more storage.")
                    .font(.caption2).foregroundStyle(StudioPalette.mutedInk)
                CameraBackgroundPicker(video: video, locked: locked)
                if video.state == .preparing || video.state == .saving { ProgressView().controlSize(.small) }
                Text(video.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(video.state == .failed ? StudioPalette.coral : StudioPalette.mutedInk)
                if !locked && !video.isBusy {
                    if showsPreview { Button(video.state == .ready ? "Hide camera preview" : "Preview camera") {
                        if video.state == .ready { video.closePreview() }
                        else { Task { _ = await video.prepare() } }
                    }.buttonStyle(StudioButtonStyle()) }
                    HStack {
                        Text("Save to \(video.folder.lastPathComponent)").font(.caption).lineLimit(1)
                        Spacer()
                        Button("Change…") { video.chooseFolder() }.buttonStyle(.plain).foregroundStyle(StudioPalette.violet)
                    }
                }
                if let saved = video.savedURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: { StudioLabel("Show recording in Finder", systemImage: "folder") }
                        .buttonStyle(StudioButtonStyle())
                }
                if let recovery = video.recoveryURL, video.state == .failed {
                    Button("Show original recording") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }.buttonStyle(StudioButtonStyle())
                    Button("Retry MP4 save") { video.retrySave() }.buttonStyle(StudioButtonStyle())
                }
                if video.state == .failed {
                    Button("Camera privacy settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }.buttonStyle(.plain)
                }
            } else {
                Text("Prompting only. You can record separately with QuickTime.").font(.caption).foregroundStyle(StudioPalette.mutedInk)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioPalette.outline))
            .onAppear { video.refreshDevices() }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in video.refreshDevices() }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in video.refreshDevices() }
    }
}
