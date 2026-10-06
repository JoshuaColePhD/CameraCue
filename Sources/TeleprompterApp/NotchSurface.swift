import AppKit
import SwiftUI
import QuartzCore
import TeleprompterCore

/// Fixed-layout content and independent reader, timer, and playback controls. Only layer properties animate;
/// expansion never publishes a frame tick or re-lays out the script.
@MainActor final class NotchSurface: NSView {
    var onToggleReader: (() -> Void)?
    var onRecord: (() -> Void)?
    var onAdjustTimer: ((NSView) -> Void)?
    var onAnimationFinished: (() -> Void)?
    var onReturnToScript: (() -> Void)?
    var onViewRecording: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    let resizeHandle = NotchResizeHandle()
    private(set) var hasAppeared = false
    private var expanded = false
    private var layoutSpec = NotchLayout()
    private let shell = CAShapeLayer()
    private let maskShape = CAShapeLayer()
    private let reader: NSHostingView<NotchReader>
    private let readerContainer = NotchContentContainer()
    private let toggleButton = NotchControl()
    private let playbackButton = NotchRecordControl()
    private let timerButton = NotchControl()
    private let brandButton = NotchControl()
    private let microphone = NSImageView()
    private let paceBanner = NotchPaceBanner()
    private(set) var currentPaceWarning: PaceHint?
    private var hasBanner = false
    private var lastPacePulseID = 0
    private var microphoneActive = false
    private var playbackPhase = PresentationPhase.ready

    private var transitionID = 0
    private(set) var isTransitioning = false
    var reduceMotionOverride: Bool? // Isolated acceptance tests; production follows macOS.
    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let interactive: Bool
    override var isFlipped: Bool { true }

    init(model: TeleprompterModel, interactive: Bool = true) {
        self.interactive = interactive
        reader = NSHostingView(rootView: NotchReader(model: model, isPreview: !interactive))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shell.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shell)
        readerContainer.wantsLayer = true
        layer?.mask = maskShape
        addSubview(readerContainer)
        readerContainer.addSubview(reader)
        reader.wantsLayer = true
        reader.layer?.opacity = 0
        addSubview(toggleButton)
        addSubview(playbackButton)
        addSubview(timerButton)
        addSubview(brandButton)
        addSubview(microphone)
        addSubview(resizeHandle)
        addSubview(paceBanner)
        resizeHandle.isHidden = true
        resizeHandle.allowsInteraction = interactive
        paceBanner.isHidden = true
        microphone.image = CueSymbol.microphone.image(size: 12, color: NSColor(CuePalette.mint))
        microphone.setAccessibilityLabel("Voice Follow microphone active")
        timerButton.target = self; timerButton.action = #selector(adjustTimer)
        toggleButton.target = self; toggleButton.action = #selector(toggleReader)
        brandButton.target = self; brandButton.action = #selector(toggleReader)
        playbackButton.target = self; playbackButton.action = #selector(togglePlayback)
        toggleButton.tint = .white
        brandButton.tint = .white
        reader.rootView.onReturnToScript = { [weak self] in self?.onReturnToScript?() }
        reader.rootView.onViewRecording = { [weak self] in self?.onViewRecording?() }
        reader.rootView.onOpenDashboard = { [weak self] in
            guard let self, self.interactive else { return }
            self.onOpenDashboard?()
        }
        setAccessibilityElement(false)
        for button in [toggleButton, timerButton, brandButton] { button.allowsInteraction = interactive }
        playbackButton.allowsInteraction = interactive
        updatePlaybackVisibility(expanded: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityChildren() -> [Any]? {
        let children: [NSView] = expanded
            ? [reader, paceBanner, playbackButton, brandButton, toggleButton, timerButton, resizeHandle]
            : [playbackButton, brandButton, toggleButton]
        return NSAccessibility.unignoredChildren(from: children.filter {
            !$0.isHidden && ($0 !== timerButton || timerButton.allowsInteraction) &&
            ($0 !== playbackButton || playbackButton.allowsInteraction) &&
            (!isTransitioning || ($0 !== reader && $0 !== resizeHandle && $0 !== paceBanner))
        })
    }
    @objc private func adjustTimer() { if interactive && timerButton.allowsInteraction { onAdjustTimer?(timerButton) } }
    @objc private func toggleReader() { if interactive { onToggleReader?() } }
    @objc private func togglePlayback() { if interactive && playbackButton.allowsInteraction && !playbackButton.isHidden { onRecord?() } }

    private func updatePlaybackVisibility(expanded: Bool) {
        // Opening the reader reveals Record. Keep an ongoing take's Stop,
        // Cancel, or Resume control available if the reader is collapsed.
        let visible = expanded || (playbackPhase != .ready && playbackPhase != .finished)
        playbackButton.isHidden = !visible && !isTransitioning
        playbackButton.allowsInteraction = interactive && visible && (!isTransitioning || (playbackPhase != .ready && playbackPhase != .finished))
        playbackButton.setAccessibilityHidden(!playbackButton.allowsInteraction)
        let ongoingTake = playbackPhase != .ready && playbackPhase != .finished
        if layoutSpec.hasCompactPlayback != ongoingTake {
            layoutSpec.hasCompactPlayback = ongoingTake
            if hasAppeared && !self.expanded { setExpanded(false, animated: true) }
        }
    }

    func configure(size: CGSize, housing: CGFloat, header: CGFloat, scale: CGFloat,
                   heightRange: ClosedRange<CGFloat> = NotchReaderSize.defaultHeight...NotchReaderSize.maximumHeight) {
        layoutSpec = NotchLayout(size: size, housing: housing, header: header)
        layoutSpec.hasCompactPlayback = playbackPhase != .ready && playbackPhase != .finished
        frame.size = size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shell.frame = bounds
        shell.contentsScale = scale
        readerContainer.frame = bounds
        maskShape.frame = bounds
        maskShape.contentsScale = scale
        reader.frame = CGRect(x: 0, y: header, width: size.width, height: max(0, size.height - header - NotchLayout.resizeStripHeight))
        resizeHandle.frame = layoutSpec.resizeStrip
        resizeHandle.configure(height: size.height, range: heightRange)
        window?.invalidateCursorRects(for: resizeHandle)
        isTransitioning = false
        positionHeaderControls(animated: false)
        timerButton.frame = layoutSpec.timerControl
        fadeControl(timerButton, visible: expanded, animated: false)
        fadeControl(playbackButton, visible: expanded || (playbackPhase != .ready && playbackPhase != .finished), animated: false)
        paceBanner.frame = CGRect(x: 80, y: header + 2, width: size.width - 160, height: 18)
        paceBanner.configureScale(scale)
        timerButton.isHidden = !expanded
        updatePlaybackVisibility(expanded: expanded)
        CATransaction.commit()
        if hasAppeared {
            applyShell(animated: false)
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shell.path = layoutSpec.path(state: .housing)
            maskShape.path = shell.path
            CATransaction.commit()
        }
    }

    func setExpanded(_ value: Bool, animated: Bool) {
        if !value { resizeHandle.cancelDrag() }
        expanded = value
        isTransitioning = animated && !reduceMotion
        positionHeaderControls(animated: isTransitioning)
        fadeControl(timerButton, visible: expanded, animated: isTransitioning)
        let recordVisible = expanded || (playbackPhase != .ready && playbackPhase != .finished)
        fadeControl(playbackButton, visible: recordVisible, animated: isTransitioning)
        applyShell(animated: isTransitioning)
        hasAppeared = true
        readerContainer.setAccessibilityHidden(!expanded || isTransitioning)
        timerButton.isHidden = !expanded && !isTransitioning
        timerButton.allowsInteraction = interactive && expanded && !isTransitioning
        timerButton.setAccessibilityHidden(!timerButton.allowsInteraction)
        updatePlaybackVisibility(expanded: expanded)
        microphone.isHidden = !expanded || !microphoneActive
        paceBanner.isHidden = !expanded || !hasBanner
        resizeHandle.isHidden = !expanded || isTransitioning
        resizeHandle.setAccessibilityHidden(!expanded || !interactive || isTransitioning)
        window?.invalidateCursorRects(for: resizeHandle)
    }

    private func positionHeaderControls(animated: Bool) {
        playbackButton.showsRecordingLabel = expanded
        let frames: [(NSView, CGRect)] = [
            (brandButton, layoutSpec.brandControl(expanded: expanded)),
            (toggleButton, layoutSpec.chevronControl(expanded: expanded)),
            (playbackButton, layoutSpec.recordControl(expanded: expanded)),
            (microphone, layoutSpec.listeningIndicator(expanded: expanded))
        ]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (view, frame) in frames {
            let visible = visibleFrame(of: view)
            view.frame = frame
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "headerPosition")
            if animated {
                let move = CABasicAnimation(keyPath: "position")
                // Bounds change immediately; animate origin only so the logo never scales.
                move.fromValue = CGPoint(x: visible.minX + frame.width * layer.anchorPoint.x,
                                         y: visible.minY + frame.height * layer.anchorPoint.y)
                move.toValue = layer.position
                move.duration = NotchMotion.duration(expanded: expanded)
                move.timingFunction = NotchMotion.curve
                layer.add(move, forKey: "headerPosition")
            }
        }
        CATransaction.commit()
    }

    private func visibleFrame(of view: NSView) -> CGRect { view.layer?.presentation()?.frame ?? view.frame }

    private func fadeControl(_ view: NSView, visible: Bool, animated: Bool) {
        guard let layer = view.layer else { return }
        let from = view.isHidden ? Float(0) : (layer.presentation()?.opacity ?? layer.opacity)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = visible ? 1 : 0
        layer.removeAnimation(forKey: "headerReveal")
        if animated {
            view.isHidden = false
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from; fade.toValue = layer.opacity
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + (visible ? NotchMotion.revealDelay : 0)
            fade.duration = visible ? NotchMotion.revealDuration : NotchMotion.hideDuration
            fade.fillMode = .backwards
            fade.timingFunction = NotchMotion.curve
            layer.add(fade, forKey: "headerReveal")
        }
        CATransaction.commit()
    }

    private func finishTransition(generation: Int) {
        guard generation == transitionID else { return }
        isTransitioning = false
        timerButton.isHidden = !expanded
        timerButton.allowsInteraction = interactive && expanded
        timerButton.setAccessibilityHidden(!timerButton.allowsInteraction)
        updatePlaybackVisibility(expanded: expanded)
        readerContainer.setAccessibilityHidden(!expanded)
        resizeHandle.isHidden = !expanded
        resizeHandle.setAccessibilityHidden(!expanded || !interactive)
        onAnimationFinished?()
    }

    private func applyShell(animated: Bool) {
        let reduce = reduceMotion
        let target = layoutSpec.path(state: expanded ? .reader : .compact)
        let from = shell.presentation()?.path ?? shell.path ?? layoutSpec.path(state: .housing)
        let maskFrom = maskShape.presentation()?.path ?? maskShape.path ?? from
        let opacity = reader.layer?.presentation()?.opacity ?? reader.layer?.opacity ?? 0
        transitionID += 1
        let generation = transitionID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated && !reduce {
            CATransaction.setCompletionBlock { [weak self] in
                DispatchQueue.main.async { self?.finishTransition(generation: generation) }
            }
        }
        shell.path = target
        maskShape.path = target
        reader.layer?.opacity = expanded ? 1 : 0
        if animated && !reduce {
            let duration = NotchMotion.duration(expanded: expanded)
            // One timing curve, no simulated spring tail or first-frame layout work.
            for (layer, source) in [(shell, from), (maskShape, maskFrom)] {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = source; animation.toValue = target
                animation.duration = duration
                animation.timingFunction = NotchMotion.curve
                layer.add(animation, forKey: "shell")
            }
            if let layer = reader.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = opacity; fade.toValue = expanded ? Float(1) : Float(0)
                fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + (expanded ? NotchMotion.revealDelay : 0)
                fade.fillMode = .backwards
                fade.duration = expanded ? NotchMotion.revealDuration : NotchMotion.hideDuration
                fade.timingFunction = NotchMotion.curve
                layer.add(fade, forKey: "reveal")
            }
        } else {
            shell.removeAllAnimations(); maskShape.removeAllAnimations(); reader.layer?.removeAllAnimations()
        }
        CATransaction.commit()
        if !animated || reduce { finishTransition(generation: generation) }
    }

    func containsVisiblePoint(_ point: CGPoint) -> Bool {
        let path = shell.presentation()?.path ?? shell.path
        return path?.contains(point) ?? false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies hitTest points in the SUPERview's coordinates. The
        // window's frame view is unflipped, while this surface is flipped.
        let localPoint = convert(point, from: superview)
        guard interactive else { return nil }
        guard containsVisiblePoint(localPoint) else { return nil }
        // Hidden SwiftUI content must not intercept compact controls or scroll events.
        if !expanded {
            if visibleFrame(of: brandButton).contains(localPoint) { return brandButton }
            if visibleFrame(of: toggleButton).contains(localPoint) { return toggleButton }
            if playbackButton.allowsInteraction && !playbackButton.isHidden && visibleFrame(of: playbackButton).contains(localPoint) { return playbackButton }
            return self
        }
        if localPoint.y <= layoutSpec.header {
            if timerButton.allowsInteraction && !timerButton.isHidden && visibleFrame(of: timerButton).contains(localPoint) { return timerButton }
            if playbackButton.allowsInteraction && !playbackButton.isHidden && visibleFrame(of: playbackButton).contains(localPoint) { return playbackButton }
            if visibleFrame(of: brandButton).contains(localPoint) { return brandButton }
            if visibleFrame(of: toggleButton).contains(localPoint) { return toggleButton }
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isTransitioning && ((!timerButton.allowsInteraction && visibleFrame(of: timerButton).contains(point)) ||
            (!playbackButton.allowsInteraction && visibleFrame(of: playbackButton).contains(point))) { return }
        if interactive && point.y >= 0 && point.y <= layoutSpec.header && containsVisiblePoint(point) {
            onToggleReader?()
        } else { super.mouseDown(with: event) }
    }

    func updateControls(model: TeleprompterModel, expanded: Bool, at now: Date = .now) {
        if interactive { model.refreshPaceFeedback(at: now) }
        let pulse = model.pacePulseID != lastPacePulseID
        lastPacePulseID = model.pacePulseID
        let snapshot = model.snapshot(at: now)
        updatePacing(snapshot.warning, pulse: pulse, expanded: expanded,
                     reduceMotion: reduceMotion)
        hasBanner = snapshot.banner != nil
        if snapshot.recovering {
            paceBanner.setMessage(snapshot.banner ?? "Finding your place", color: NSColor(CuePalette.butter))
            paceBanner.isHidden = !expanded
        }
        let time = snapshot.timerText
        toggleButton.configure(title: "", symbol: expanded ? "chevron.up" : "chevron.down",
                               label: expanded ? "Collapse reader" : "Open reader",
                               help: "Open or collapse reader · Your place is kept", style: .plainCentered)
        brandButton.configure(title: "", symbol: "cameraCueMark",
                              label: expanded ? "CameraCue Studio — collapse reader" : "CameraCue Studio — open reader",
                              help: "CameraCue Studio · Open or collapse reader · Your place is kept", style: .plainCentered)
        timerButton.configure(title: time, symbol: "", label: "Adjust presentation timer",
                              help: "Adjust timer · Count up or down · " + time, style: .plain)
        timerButton.tint = model.presentationIsOvertime(at: now)
            ? NSColor(CuePalette.coral) : NSColor(CuePalette.butter)
        if let warning = currentPaceWarning { timerButton.toolTip = warning.title + " · Click to adjust timer · " + time }
        playbackButton.configure(phase: model.video.isRecording ? .running : snapshot.phase, reduceMotion: reduceMotion, recordsVideo: model.video.enabled)
        playbackPhase = model.video.isRecording ? .running : snapshot.phase
        updatePlaybackVisibility(expanded: self.expanded)
        playbackButton.isEnabled = model.wordCount > 0 && !model.isRestartingTake && model.video.state != .saving && (model.isStarting || model.video.state != .preparing)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        microphoneActive = model.speech.state == .listening
        microphone.isHidden = !expanded || !microphoneActive
        CATransaction.commit()
    }

    /// Pacing warnings pulse only in the fixed strip; the timer stays steady.
    func updatePacing(_ hint: PaceHint?, pulse: Bool, expanded: Bool, reduceMotion: Bool) {
        currentPaceWarning = hint
        let color = NSColor(hint == .slowDown ? CuePalette.mint : hint == .overtime ? CuePalette.coral : CuePalette.butter)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        paceBanner.setHint(hint, color: color)
        paceBanner.isHidden = !expanded || hint == nil
        if hint == nil || reduceMotion { paceBanner.accent.removeAnimation(forKey: "pacePulse") }
        else if pulse {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.45, 1, 0.45, 1, 0.45]
            animation.duration = 2.4
            animation.calculationMode = .cubic
            paceBanner.accent.add(animation, forKey: "pacePulse")
        }
        CATransaction.commit()
    }
}

private final class NotchPaceBanner: NSView {
    let accent = CALayer()
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        accent.cornerRadius = 7
        accent.opacity = 0.45
        layer?.addSublayer(accent)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        accent.frame = bounds
        label.frame = CGRect(x: 4, y: (bounds.height - 14) / 2, width: bounds.width - 8, height: 14)
        CATransaction.commit()
    }
    func configureScale(_ scale: CGFloat) { accent.contentsScale = scale }
    func setHint(_ hint: PaceHint?, color: NSColor) {
        setMessage(hint?.title ?? "", color: color)
    }
    func setMessage(_ message: String, color: NSColor) {
        label.stringValue = message
        label.textColor = color
        accent.backgroundColor = color.withAlphaComponent(0.20).cgColor
        setAccessibilityHidden(message.isEmpty)
    }
}

/// All states have the same path commands so Core Animation can interpolate them.
struct NotchLayout: Equatable {
    enum State { case housing, compact, reader }
    static let resizeStripHeight: CGFloat = 16
    var size = CGSize(width: 548, height: 248)
    var housing: CGFloat = 190
    var header: CGFloat = 34
    var hasCompactPlayback = false
    var controlHeight: CGFloat { min(28, max(14, header - 4)) }
    // Two extra points on each physical edge keep the whole button outside the
    // housing's curved lip. Record sits farther left, keeping both reader toggles
    // fixed while the compact bar makes room for Stop during an ongoing take.
    var controlHousing: CGFloat { housing > 0 ? housing + 4 : 0 }
    // Without a physical camera, center the unequal wordmark/chevron widths as
    // a group. A notched display must keep the camera centered instead.
    var controlCenterX: CGFloat { size.width / 2 + (housing > 0 ? 0 : 20) }
    var compactBounds: CGRect {
        if housing > 0 {
            // Fit each shoulder to its actual controls instead of mirroring the
            // wide wordmark shoulder on the chevron side. The camera and button
            // frames remain fixed; only the surrounding shell becomes narrower.
            let leading = (hasCompactPlayback ? playbackControl : leftControl).minX - 12
            return CGRect(x: leading, y: 0, width: rightControl.maxX + 12 - leading, height: header)
        }
        let width = min(size.width, hasCompactPlayback ? 340 : 220)
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: header)
    }
    var compactWidth: CGFloat { compactBounds.width }
    var leftControl: CGRect { CGRect(x: housing > 0 ? controlCenterX - controlHousing / 2 - 78 : size.width / 2 - 92, y: (header - controlHeight) / 2, width: 72, height: controlHeight) }
    // Insets clear the tapered shoulder; the digits align to the trailing edge.
    var timerControl: CGRect {
        let width: CGFloat = housing > 0 ? 52 : 68
        return CGRect(x: size.width - 32 - width, y: (header - controlHeight) / 2, width: width, height: controlHeight)
    }
    var microphoneFrame: CGRect { CGRect(x: rightControl.maxX + 8, y: header / 2 - 6, width: 12, height: 12) }
    var rightControl: CGRect { CGRect(x: housing > 0 ? controlCenterX + controlHousing / 2 + 6 : size.width / 2 + 60, y: (header - controlHeight) / 2, width: 32, height: controlHeight) }
    var playbackControl: CGRect { CGRect(x: leftControl.minX - 60, y: (header - controlHeight) / 2, width: 52, height: controlHeight) }
    // Expanded branding groups at the shell's left edge on every display.
    // Compact controls still clear the physical camera housing.
    func brandControl(expanded: Bool) -> CGRect {
        guard expanded else { return leftControl }
        return CGRect(x: 32, y: leftControl.minY, width: 32, height: controlHeight)
    }
    func chevronControl(expanded: Bool) -> CGRect {
        guard expanded else { return rightControl }
        return CGRect(x: brandControl(expanded: true).maxX + 2, y: rightControl.minY, width: 32, height: controlHeight)
    }
    func recordControl(expanded: Bool) -> CGRect {
        guard expanded else { return playbackControl }
        return CGRect(x: timerControl.minX - 8 - 86, y: playbackControl.minY, width: 86, height: controlHeight)
    }
    func listeningIndicator(expanded: Bool) -> CGRect {
        guard expanded else { return microphoneFrame }
        return CGRect(x: chevronControl(expanded: true).maxX + 8, y: header / 2 - 6, width: 12, height: 12)
    }
    var resizeStrip: CGRect { CGRect(x: 48, y: size.height - Self.resizeStripHeight, width: max(0, size.width - 96), height: Self.resizeStripHeight) }
    func path(state: State) -> CGPath {
        let width = state == .reader ? size.width : (state == .compact ? compactWidth : max(housing, 32))
        let height = state == .reader ? size.height : header
        let rect = state == .compact ? compactBounds : CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
        return NotchShape(expansion: state == .reader ? 1 : 0).path(in: rect).cgPath
    }
}

struct NotchShape: Shape {
    var expansion: CGFloat
    func path(in rect: CGRect) -> Path {
        let inset = 10 + 10 * expansion
        let shoulder = min(20 + 10 * expansion, rect.height * 0.6)
        let radius = min(11 + 17 * expansion, rect.height * 0.38)
        let left = rect.minX + inset, right = rect.maxX - inset
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                      control1: CGPoint(x: right, y: rect.minY), control2: CGPoint(x: right, y: rect.minY + shoulder * 0.4))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addCurve(to: CGPoint(x: right - radius, y: rect.maxY),
                      control1: CGPoint(x: right, y: rect.maxY - radius * 0.35), control2: CGPoint(x: right - radius * 0.35, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addCurve(to: CGPoint(x: left, y: rect.maxY - radius),
                      control1: CGPoint(x: left + radius * 0.35, y: rect.maxY), control2: CGPoint(x: left, y: rect.maxY - radius * 0.35))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                      control1: CGPoint(x: left, y: rect.minY + shoulder * 0.4), control2: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Native button tracking and accessibility; render-server hover/press feedback.
private final class NotchControl: NSButton {
    enum Style { case subtle, plain, plainCentered }
    var allowsInteraction = true
    override func isAccessibilityEnabled() -> Bool { allowsInteraction && !isHiddenOrHasHiddenAncestor && super.isAccessibilityEnabled() }
    override func accessibilityPerformPress() -> Bool { allowsInteraction && !isHiddenOrHasHiddenAncestor && super.accessibilityPerformPress() }
    var tint = NSColor.white { didSet { if tint != oldValue { updateAppearance() } } }
    private var style = Style.subtle
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    private var symbolName = ""
    private var text = ""
    private var cachedSymbols: [NSColor: [String: NSImage]] = [:]
    private var contentKey = ""
    private var contentColor: NSColor?
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { alphaValue = isEnabled ? 1 : 0.4 } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = NotchControlCell(textCell: "")
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        imagePosition = .imageLeading
        imageHugsTitle = true
        layer?.cornerRadius = 13
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(title: String, symbol: String, label: String, help: String, style: Style = .subtle) {
        setAccessibilityLabel(label)
        toolTip = help
        guard text != title || symbolName != symbol || self.style != style else { return }
        text = title; symbolName = symbol; self.style = style
        updateAppearance()
    }
    private func updateAppearance() {
        // Plain controls retain native hit areas and focus rings without pills.
        let foreground = style != .subtle
            ? tint.withAlphaComponent(pressed ? 0.65 : (hovered ? 1 : 0.9)) : tint
        let key = symbolName + "|" + text + "|\(style)"
        if key != contentKey || foreground != contentColor {
            contentKey = key; contentColor = foreground
            imagePosition = symbolName.isEmpty ? .noImage : text.isEmpty ? .imageOnly : .imageLeading
            alignment = style == .plain ? .right : .center
            attributedTitle = NSAttributedString(string: text.isEmpty || symbolName.isEmpty ? text : " " + text, attributes: [
                .font: text.contains(":") ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) : NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: foreground
            ])
            if !symbolName.isEmpty && cachedSymbols[foreground] == nil {
                var symbols: [String: NSImage] = [:]
                for name in ["chevron.down", "chevron.up", "play.fill", "pause.fill", "ellipsis", "timer", "xmark", "arrow.counterclockwise"] {
                    symbols[name] = CueSymbol(systemName: name).image(size: 13, color: foreground)
                }
                cachedSymbols[foreground] = symbols
            }
            (cell as? NotchControlCell)?.isLogo = symbolName == "cameraCueMark"
            image = symbolName == "cameraCueMark" ? CameraCueMark.image : cachedSymbols[foreground]?[symbolName]
        }
        let color = style != .subtle ? NSColor.clear : tint.withAlphaComponent(pressed ? 0.22 : (hovered ? 0.13 : 0.055))
        guard let layer else { return }
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from; fade.toValue = color.cgColor; fade.duration = 0.12
        if style != .subtle || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer.removeAnimation(forKey: "hover") }
        else { layer.add(fade, forKey: "hover") }
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
    override func mouseDown(with event: NSEvent) {
        guard allowsInteraction && !isHiddenOrHasHiddenAncestor else { return }
        if layer?.animation(forKey: "headerPosition") != nil { performClick(nil); return }
        pressed = true; updateAppearance()
        super.mouseDown(with: event)
        pressed = false; updateAppearance()
    }
}

private final class NotchControlCell: NSButtonCell {
    var isLogo = false
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard isLogo else { return super.imageRect(forBounds: rect) }
        let size = min(22, rect.height)
        return CGRect(x: rect.minX + CameraCueMark.leadingInset, y: rect.midY - size / 2, width: size, height: size)
    }
}

private final class NotchContentContainer: NSView {
    override var isFlipped: Bool { true }
}
