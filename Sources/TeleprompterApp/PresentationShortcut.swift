import AppKit
import Carbon

@MainActor final class PresentationShortcut: ObservableObject {
    enum Action: UInt32 { case toggle = 1, previousLine, nextLine, restart }
    @Published private(set) var error: String?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var action: ((Action) -> Void)?

    func register(action: @escaping (Action) -> Void) {
        self.action = action
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x43554531,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<PresentationShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                NSLog("CameraCue shortcut %u dispatched; frontmost=%@", action.rawValue, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
                owner.action?(action)
            }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installed == noErr else {
            error = "Presentation shortcuts could not be registered. Use the notch or Prompter menu."
            return
        }
        let bindings: [(Action, Int, String)] = [(.toggle, kVK_Space, "Space"), (.previousLine, kVK_UpArrow, "↑"),
                                                (.nextLine, kVK_DownArrow, "↓"), (.restart, kVK_ANSI_R, "R")]
        var conflicts: [String] = []
        for (action, key, label) in bindings {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: 0x43554531, id: action.rawValue), GetApplicationEventTarget(), 0, &hotKey)
            NSLog("CameraCue shortcut %@ registration status=%d", label, status)
            if status == noErr, let hotKey { hotKeys.append(hotKey) }
            else { conflicts.append("⌃⌥" + label) }
        }
        if !conflicts.isEmpty {
            error = "Shortcut unavailable: \(conflicts.joined(separator: ", ")). Free it in the other app, then reopen CameraCue."
        }
    }
    isolated deinit {
        NSLog("CameraCue presentation shortcuts released")
        for key in hotKeys { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
