import SwiftUI

@main struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(RecordingTermination.self) private var termination
    @StateObject private var library = ScriptLibrary()
    @StateObject private var model = TeleprompterModel()
    @StateObject private var notch = NotchController()
    @StateObject private var shortcut = PresentationShortcut()

    var body: some Scene {
        WindowGroup("CameraCue Studio", id: "studio") {
            StudioView()
                .environmentObject(library)
                .environmentObject(model)
                .environmentObject(notch)
                .environmentObject(shortcut)
                .onAppear {
                    termination.model = model
                    shortcut.register { action in
                        switch action {
                        case .toggle:
                            if !model.isRunning { notch.show(model: model, library: library) }
                            Task { await model.toggle() }
                        case .previousLine: model.move(lines: -1)
                        case .nextLine: model.move(lines: 1)
                        case .restart: model.reset()
                        }
                    }
                }
                .frame(minWidth: 900, minHeight: 680)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1230, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Script") { library.create() }.keyboardShortcut("n")
            }
            CommandMenu("Prompter") {
                Button("Start or Pause (⌃⌥Space)") { Task { await model.toggle() } }
                Button("Previous Line (⌃⌥↑)") { model.move(lines: -1) }
                Button("Next Line (⌃⌥↓)") { model.move(lines: 1) }
                Button("Restart from Beginning (⌃⌥R)") { model.reset() }.keyboardShortcut("r")
                Button("Focus Mode") { model.focusMode.toggle() }.keyboardShortcut("f")
            }
        }
        Settings { LanguageModelSettingsView(showsDone: false) }
        WindowGroup(id: "prompter") {
            PrompterView()
                .environmentObject(model)
                .environmentObject(library)
                .background(WindowAccessor { CameraWindow.configure($0) })
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 390, height: 350)
        .windowResizability(.contentMinSize)
    }
}
