import AppKit
import QuartzCore

/// Record becomes an animated status and an explicit stop target beside the timer.
final class NotchRecordControl: NSButton {
    var allowsInteraction = true
    let recordLight = CALayer()
    private let recordingLabel = NSTextField(labelWithString: "Recording")
    var showsRecordingLabel = false {
        didSet { if showsRecordingLabel != oldValue { updateAppearance(); needsLayout = true } }
    }
    private var phase: PresentationPhase?
    private var recordsVideo = false
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        imagePosition = .noImage
        recordLight.backgroundColor = NSColor(CuePalette.coral).cgColor
        recordLight.cornerRadius = 2
        recordLight.shadowColor = NSColor(CuePalette.coral).cgColor
        recordLight.shadowRadius = 4
        recordLight.shadowOffset = .zero
        recordLight.shadowOpacity = 0.28
        recordLight.isHidden = true
        layer?.addSublayer(recordLight)
        recordingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        recordingLabel.textColor = NSColor(CuePalette.coral)
        recordingLabel.wantsLayer = true
        recordingLabel.isHidden = true
        addSubview(recordingLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { allowsInteraction && !isHiddenOrHasHiddenAncestor && super.isAccessibilityEnabled() }
    override func accessibilityPerformPress() -> Bool { allowsInteraction && !isHiddenOrHasHiddenAncestor && super.accessibilityPerformPress() }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { alphaValue = isEnabled ? 1 : 0.4 } } }

    func configure(phase: PresentationPhase, reduceMotion: Bool, recordsVideo: Bool = false) {
        if self.recordsVideo != recordsVideo { self.phase = nil; self.recordsVideo = recordsVideo }
        if self.phase != phase {
            self.phase = phase
            switch phase {
            case .running:
                setAccessibilityLabel(recordsVideo ? "Stop and save video" : "Stop prompting")
                toolTip = recordsVideo ? "Stop camera recording and prompting, then save an MP4." : "Stop prompting and finish this take. QuickTime keeps recording."
            case .starting, .countIn:
                setAccessibilityLabel("Cancel starting")
                toolTip = recordsVideo ? "Cancel starting this recording." : "Cancel starting this take. QuickTime records separately."
            case .paused:
                setAccessibilityLabel("Resume presentation")
                toolTip = recordsVideo ? "Resume prompting from your place." : "Resume prompting from your place. QuickTime records separately."
            case .ready, .finished:
                setAccessibilityLabel(recordsVideo ? "Record camera video and start prompting" : "Record — start prompting")
                toolTip = recordsVideo ? "Record your camera and microphone, and start prompting. Stop saves an MP4." : "Start CameraCue Studio prompting and its timer. Record video separately in QuickTime."
            }
            updateAppearance()
            if phase == .running && showsRecordingLabel && !reduceMotion {
                let arrival = CABasicAnimation(keyPath: "opacity")
                arrival.fromValue = 0; arrival.toValue = 1; arrival.duration = NotchMotion.revealDuration
                arrival.timingFunction = NotchMotion.curve
                recordingLabel.layer?.add(arrival, forKey: "arrival")
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0; appear.toValue = 1; appear.duration = NotchMotion.revealDuration
                appear.timingFunction = NotchMotion.curve
                recordLight.add(appear, forKey: "arrival")
            }
        }
        // Refreshing speech/timer state must not restart the breathing cycle.
        if phase == .running && !reduceMotion {
            if recordLight.animation(forKey: "recordPulse") == nil {
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [1, 0.55, 1]
                pulse.keyTimes = [0, 0.5, 1]
                pulse.duration = 2.6
                pulse.repeatCount = .infinity
                pulse.calculationMode = .cubic
                recordLight.add(pulse, forKey: "recordPulse")
            }
            if recordingLabel.layer?.animation(forKey: "recordPulse") == nil {
                if let pulse = recordLight.animation(forKey: "recordPulse") {
                    recordingLabel.layer?.add(pulse, forKey: "recordPulse")
                }
            }
        } else {
            recordLight.removeAnimation(forKey: "recordPulse")
            if reduceMotion { recordLight.removeAnimation(forKey: "arrival") }
            recordingLabel.layer?.removeAllAnimations()
        }
    }
    private func updateAppearance() {
        let text: String
        switch phase {
        case .running: text = ""
        case .paused: text = "Resume"
        case .starting, .countIn: text = "Cancel"
        default: text = "Record"
        }
        let color = text == "Record" ? NSColor(CuePalette.coral) : NSColor(CuePalette.lavender)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(pressed ? 0.65 : text == "Record" || hovered ? 1 : 0.9)
        ])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        recordLight.isHidden = phase != .running
        recordingLabel.isHidden = phase != .running || !showsRecordingLabel
        alignment = showsRecordingLabel ? .right : .center
        recordLight.backgroundColor = NSColor(CuePalette.coral).withAlphaComponent(pressed ? 0.7 : 1).cgColor
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        recordLight.frame = CGRect(x: showsRecordingLabel ? 5 : bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
        recordingLabel.frame = CGRect(x: 28, y: bounds.midY - 7, width: 58, height: 16)
        recordLight.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
    override func mouseDown(with event: NSEvent) {
        guard allowsInteraction && !isHiddenOrHasHiddenAncestor else { return }
        let visibleFrame = layer?.presentation()?.frame ?? frame
        let localX = superview.map { $0.convert(event.locationInWindow, from: nil).x - visibleFrame.minX }
            ?? convert(event.locationInWindow, from: nil).x
        if phase == .running && showsRecordingLabel && localX > 26 { return }
        if layer?.animation(forKey: "headerPosition") != nil { performClick(nil); return }
        pressed = true; updateAppearance()
        super.mouseDown(with: event)
        pressed = false; updateAppearance()
    }
}
