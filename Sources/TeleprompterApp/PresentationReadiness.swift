import AppKit
import SwiftUI

struct PresentationReadiness: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var speech: SpeechFollower
    var showsSetupAction = true
    var showsShortcutHints = true
    @EnvironmentObject private var shortcut: PresentationShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioLabel(model.wordCount > 0 ? "Script ready" : "Add a script before presenting",
                  systemImage: model.wordCount > 0 ? "checkmark.circle" : "doc.badge.plus")
            if model.mode != .manual {
                Text(speech.readiness).fixedSize(horizontal: false, vertical: true)
                if speech.state == .denied && showsSetupAction {
                    Button("Open Voice Follow Settings") { NSWorkspace.shared.open(speech.permissionSettingsURL) }
                } else if speech.needsPermissionSetup && showsSetupAction {
                    Button("Set up Voice Follow") { Task { await speech.prepare() } }
                        .disabled(speech.isAuthorizing || model.isStarting)
                }
            } else { Text(model.video.enabled ? "Manual reading · Video includes microphone audio" : "Manual reading · Microphone not needed") }
            if showsShortcutHints || shortcut.error != nil { Text(shortcut.error ?? (model.video.enabled ? "⌃⌥Space starts or pauses prompting. Video continues during pauses. Stop saves your MP4." : "⌃⌥Space starts or pauses prompting. ⌃⌥↑/↓ adjusts your place. QuickTime records separately."))
                .fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioPalette.mutedInk)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.lavenderWash, in: RoundedRectangle(cornerRadius: 10))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in speech.refreshReadiness() }
    }
}
