import AppKit
import Carbon

@MainActor final class PresentationShortcut: ObservableObject {
    enum Action: UInt32 { case toggle = 1, previousLine, nextLine, restart }
    @Published private(set) var error: String?
    private let lifetime = HotkeyLifetime()
    private var action: ((Action) -> Void)?

    func register(action: @escaping (Action) -> Void) {
        self.action = action
        guard !lifetime.isRegistered else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback = ShortcutCallbackContext(owner: self)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var handler: EventHandlerRef?
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x43554531,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let callback = Unmanaged<ShortcutCallbackContext>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                NSLog("CameraCue shortcut %u dispatched; frontmost=%@", action.rawValue, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
                callback.owner?.action?(action)
            }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installed == noErr else {
            error = "Presentation shortcuts could not be registered. Use the notch or Prompter menu."
            return
        }
        lifetime.install(handler: handler, context: callback)
        let bindings: [(Action, Int, String)] = [(.toggle, kVK_Space, "Space"), (.previousLine, kVK_UpArrow, "↑"),
                                                (.nextLine, kVK_DownArrow, "↓"), (.restart, kVK_ANSI_R, "R")]
        var conflicts: [String] = []
        for (action, key, label) in bindings {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: 0x43554531, id: action.rawValue), GetApplicationEventTarget(), 0, &hotKey)
            NSLog("CameraCue shortcut %@ registration status=%d", label, status)
            if status == noErr, let hotKey { lifetime.append(hotKey) }
            else { conflicts.append("⌃⌥" + label) }
        }
        if !conflicts.isEmpty {
            error = "Shortcut unavailable: \(conflicts.joined(separator: ", ")). Free it in the other app, then reopen CameraCue."
        }
    }
    // Lifetime objects perform resource cleanup without isolated-deinit trampolines.
    deinit {}
}

@MainActor private final class ShortcutCallbackContext {
    weak var owner: PresentationShortcut?
    init(owner: PresentationShortcut) { self.owner = owner }
    deinit {}
}

/// Registration updates are serialized and callbacks retain a weak-owner context.
/// Carbon cleanup always runs on the main queue, retaining that context until the
/// native handler is removed. A queued event cannot dereference a dead owner.
private final class HotkeyLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var context: ShortcutCallbackContext?
    var isRegistered: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
    func install(handler: EventHandlerRef?, context: ShortcutCallbackContext) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; self.context = context
    }
    func append(_ key: EventHotKeyRef) { lock.lock(); keys.append(key); lock.unlock() }
    deinit {
        let cleanup = HotkeyCleanup(keys: keys, handler: handler, context: context)
        if Thread.isMainThread { MainActor.assumeIsolated { cleanup.remove() } }
        else { DispatchQueue.main.async { cleanup.remove() } }
    }
}
private final class HotkeyCleanup: @unchecked Sendable {
    private let keys: [EventHotKeyRef]
    private let handler: EventHandlerRef?
    private let context: ShortcutCallbackContext?
    init(keys: [EventHotKeyRef], handler: EventHandlerRef?, context: ShortcutCallbackContext?) {
        self.keys = keys; self.handler = handler; self.context = context
    }
    @MainActor func remove() {
        for key in keys { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
        withExtendedLifetime(context) {}
    }
}
