import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Window ownership and application state. No per-frame published state: the render
/// server animates the shell while the reader is laid out only when its data changes.
@MainActor final class NotchController: NSObject, ObservableObject {
    enum Presentation { case compact, reader }
    private(set) var presentation: Presentation = .compact
    private var panel: NotchPanel?
    private var surface: NotchSurface?
    private var timerPopover: NSPopover?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var permissionPromptIsActive = false
    private var sleeping = false
    private var model: TeleprompterModel?
    private var refreshQueued = false
    @Published private(set) var display: NotchDisplay?
    @Published private(set) var preferredReaderHeight: CGFloat
    private let defaults: UserDefaults?
    private var resizeSession: NotchResizeSession?
    private var dragHeight: CGFloat?
    private var appliedLayout: NotchLayout?
    private var selection = NotchDisplaySelection()
    private weak var studioWindow: NSWindow?
    private var adoptedStudioScreen = false
    var expanded: Bool { presentation == .reader }
    var layout: NotchLayout {
        display?.layout(preferredHeight: dragHeight ?? preferredReaderHeight)
            ?? NotchLayout(size: CGSize(width: 548, height: preferredReaderHeight), housing: 0, header: 24)
    }
    var onReturnToScript: (() -> Void)?
    var shouldOpenScriptEditor = false
    var onOpenDashboard: (() -> Void)?
    var shouldOpenDashboard = false

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        preferredReaderHeight = NotchReaderSize.load(from: defaults)
        super.init()
    }

    /// Commit once at release, rather than invalidating all of Studio per drag event.
    func setReaderHeight(_ height: CGFloat) {
        let value = NotchReaderSize.validHeight(height)
        if preferredReaderHeight != value { preferredReaderHeight = value }
        defaults?.set(Double(value), forKey: NotchReaderSize.preferenceKey)
        if let display { applyGeometry(for: display) }
        updateInputRegion()
    }
    private func beginResize(at point: CGPoint) {
        guard expanded, !sleeping, !permissionPromptIsActive else { return }
        timerPopover?.close()
        resizeSession = NotchResizeSession(height: layout.size.height, screenY: point.y)
        updateInputRegion()
    }
    private func resize(to point: CGPoint) {
        guard let resizeSession, let display else { return }
        let height = display.layout(preferredHeight: resizeSession.height(atScreenY: point.y)).size.height
        guard height != layout.size.height else { return }
        dragHeight = height
        applyGeometry(for: display)
    }
    private func endResize() {
        let height = dragHeight
        resizeSession = nil
        dragHeight = nil
        if let height { setReaderHeight(height) }
        updateInputRegion()
    }

    func attachStudioWindow(_ window: NSWindow) {
        studioWindow = window
        guard !adoptedStudioScreen, model?.displayIsLocked != true, let screen = window.screen else { return }
        adoptedStudioScreen = true
        let available = NSScreen.screens.map { NotchDisplay(screen: $0) }
        let target = NotchDisplay(screen: screen)
        _ = selection.click(at: CGPoint(x: target.bounds.midX, y: target.bounds.midY), available: available)
        updateDisplay()
    }
    func returnToScript() {
        shouldOpenDashboard = false
        shouldOpenScriptEditor = true
        studioWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onReturnToScript?()
    }
    func openDashboard() {
        shouldOpenScriptEditor = false
        shouldOpenDashboard = true
        setExpanded(false)
        studioWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onOpenDashboard?()
    }
    func setPermissionPromptActive(_ active: Bool) {
        permissionPromptIsActive = active
        if active { surface?.resizeHandle.cancelDrag(); timerPopover?.close(); panel?.orderOut(nil) }
        else { setExpanded(expanded) }
    }

    func showCompact(model: TeleprompterModel, library: ScriptLibrary) {
        guard panel == nil else { return }
        createPanel(model: model)
        setExpanded(false)
    }
    func show(model: TeleprompterModel, library: ScriptLibrary) {
        if panel == nil { createPanel(model: model) }
        setExpanded(true)
    }
    func toggle(model: TeleprompterModel, library: ScriptLibrary) {
        if panel == nil { createPanel(model: model) }
        setExpanded(!expanded)
    }
    func setExpanded(_ value: Bool) {
        let changed = expanded != value
        presentation = value ? .reader : .compact
        guard let surface else { return }
        updatePanelVisibility()
        updateControls()
        surface.setExpanded(value, animated: changed || !surface.hasAppeared)
        updateInputRegion()
    }

    private func createPanel(model: TeleprompterModel) {
        self.model = model
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "CameraCue Notch"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        self.panel = panel
        let surface = NotchSurface(model: model)
        self.surface = surface
        panel.contentView = surface
        surface.onReturnToScript = { [weak self] in self?.returnToScript() }
        surface.onOpenDashboard = { [weak self] in self?.openDashboard() }
        surface.resizeHandle.onBegin = { [weak self] in self?.beginResize(at: $0) }
        surface.resizeHandle.onDrag = { [weak self] in self?.resize(to: $0) }
        surface.resizeHandle.onEnd = { [weak self] in self?.endResize() }
        surface.resizeHandle.onReset = { [weak self] in self?.setReaderHeight(NotchReaderSize.defaultHeight) }
        surface.resizeHandle.onSetHeight = { [weak self] height in
            guard let self else { return }
            self.setReaderHeight(self.display?.layout(preferredHeight: height).size.height ?? height)
        }
        surface.resizeHandle.onAdjust = { [weak self] delta in
            guard let self else { return }
            let height = self.layout.size.height + delta
            self.setReaderHeight(self.display?.layout(preferredHeight: height).size.height ?? height)
        }
        surface.onToggleReader = { [weak self] in
            guard let self else { return }; self.setExpanded(!self.expanded)
        }
        surface.onRecord = { [weak self, weak model] in
            guard let self, let model else { return }
            if model.phase == .ready || model.phase == .paused || model.phase == .finished { self.setExpanded(true) }
            Task { await model.performNotchRecordAction() }
        }
        surface.onAdjustTimer = { [weak self, weak model] anchor in
            guard let self, let model else { return }
            if self.timerPopover?.isShown == true { self.timerPopover?.close(); return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: TimerSettingsView(model: model, onClose: { [weak popover] in popover?.close() }))
            self.timerPopover = popover
            let screenAnchor = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
            let edge = anchor.window?.screen.map { TimerPopoverPlacement.edge(anchor: screenAnchor, screen: $0.visibleFrame) } ?? .maxY
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        }
        surface.onAnimationFinished = { [weak self] in self?.updateInputRegion() }
        updateDisplay()
        updateControls()

        model.objectWillChange.sink { [weak self] in self?.scheduleControlRefresh() }.store(in: &subscriptions)
        model.speech.objectWillChange.sink { [weak self] in self?.scheduleControlRefresh() }.store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateDisplay(); self?.updateControls() }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateDisplay() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateDisplay() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.surface?.resizeHandle.cancelDrag(); self?.model?.pause(); self?.sleeping = true; self?.panel?.orderOut(nil) }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false; self.updateDisplay(); self.setExpanded(self.expanded)
            }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.surface?.setExpanded(self.expanded, animated: false)
                self.updateControls()
            }
        })
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event); self?.updateInputRegion() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event); self?.updateInputRegion() }
            return event
        }
        model.video.onPermissionPromptChanged = { [weak self] requesting in self?.setPermissionPromptActive(requesting) }
        model.speech.onPermissionPromptChanged = { [weak self] requesting in
            self?.setPermissionPromptActive(requesting)
        }
    }

    private func scheduleControlRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // objectWillChange arrives before the properties have their new values.
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.updateControls()
        }
    }
    private func updateControls() {
        guard let model else { return }
        selection.setLocked(model.displayIsLocked)
        surface?.updateControls(model: model, expanded: expanded)
    }
    private func handlePointer(_ event: NSEvent) {
        guard resizeSession == nil else { return }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        selection.setLocked(model?.displayIsLocked == true)
        let screens = NSScreen.screens.map { NotchDisplay(screen: $0) }
        if selection.click(event: event, available: screens) {
            timerPopover?.close()
            updateDisplay()
        }
    }
    private func updateDisplay() {
        guard let panel, let surface else { return }
        let screens = NSScreen.screens.map { NotchDisplay(screen: $0) }
        let preferred = (studioWindow?.screen ?? NSScreen.main).map { NotchDisplay(screen: $0).id }
        selection.initialize(preferred: preferred, available: screens)
        selection.setLocked(model?.displayIsLocked == true)
        if selection.reconcile(available: screens, fallback: NSScreen.main.map { NotchDisplay(screen: $0).id }), model?.displayIsLocked == true {
            model?.pauseForDisplayChange()
            timerPopover?.close()
        }
        guard let target = screens.first(where: { $0.id == selection.selectedID }) else {
            surface.resizeHandle.cancelDrag(); panel.orderOut(nil); return
        }
        if display != target {
            surface.resizeHandle.cancelDrag()
            display = target
            appliedLayout = nil
        }
        applyGeometry(for: target)
        updatePanelVisibility()
        updateInputRegion()
    }
    private func applyGeometry(for target: NotchDisplay) {
        guard let panel, let surface else { return }
        let height = dragHeight ?? preferredReaderHeight
        let layout = target.layout(preferredHeight: height)
        let frame = target.panelFrame(preferredHeight: height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AppKit can relocate a panel while displays reconnect. Restore its actual
        // frame even if our selected display's geometry has not changed.
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if appliedLayout != layout {
            surface.configure(size: layout.size, housing: target.cameraHousing, header: layout.header,
                              scale: target.scale, heightRange: target.readerHeightRange)
            appliedLayout = layout
        }
        CATransaction.commit()
    }
    private func updatePanelVisibility() {
        guard let panel else { return }
        if permissionPromptIsActive || sleeping || (!expanded && display?.showsCompact != true) {
            panel.orderOut(nil)
        } else if !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func updateInputRegion() {
        guard let panel, let surface else { return }
        let point = CGPoint(x: NSEvent.mouseLocation.x - panel.frame.minX, y: panel.frame.maxY - NSEvent.mouseLocation.y)
        // Keep ownership through mouse-up even if the pointer exceeds a size limit.
        panel.ignoresMouseEvents = (resizeSession == nil && !surface.containsVisiblePoint(point)) || permissionPromptIsActive || sleeping
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
