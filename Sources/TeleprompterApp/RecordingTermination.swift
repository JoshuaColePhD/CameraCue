import AppKit

@MainActor final class RecordingTermination: NSObject, NSApplicationDelegate {
    weak var model: TeleprompterModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isStarting || model.video.state == .preparing {
            let alert = NSAlert(); alert.messageText = "CameraCue Studio is getting ready"
            alert.informativeText = "Cancel the start or wait for the camera to be ready before quitting."
            alert.addButton(withTitle: "Keep CameraCue Studio open"); alert.runModal()
            return .terminateCancel
        }
        guard model.video.isRecording || model.video.state == .saving else { model.video.closePreview(); return .terminateNow }
        if model.video.isRecording {
            let alert = NSAlert(); alert.messageText = "Stop and save your recording before quitting?"
            alert.informativeText = "CameraCue Studio will finish your MP4 before closing."
            alert.addButton(withTitle: "Stop, save, and quit"); alert.addButton(withTitle: "Keep recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            model.finish()
        }
        Task { @MainActor in
            await model.video.waitUntilSaved()
            if model.video.state == .failed {
                let alert = NSAlert(); alert.messageText = "Your video needs attention"
                alert.informativeText = model.video.message + " Keep CameraCue Studio open to retry or locate the original recording."
                alert.addButton(withTitle: "Keep CameraCue Studio open"); alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            } else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
