import Foundation
import Combine
import SwiftUI
import TeleprompterCore

@MainActor final class TeleprompterModel: ObservableObject {
    enum Mode: String, CaseIterable { case voice = "Voice Follow", manual = "Manual", rehearsal = "Rehearsal" }
    enum TimerMode: String, CaseIterable { case countUp = "Count up", countdown = "Countdown" }
    @Published var mode: Mode = .voice {
        didSet {
            guard mode != oldValue, !restoringMode else { return }
            if isRunning || isStarting {
                restoringMode = true; mode = oldValue; restoringMode = false
                return
            }
            pause()
            followedWordIndex = nil
        }
    }
    @Published var tokenIndex = 0
    @Published private(set) var followedWordIndex: Int?
    @Published var confidence: AlignmentConfidence = .low
    @Published var matchedPhrase = ""
    @Published var searchRange = 0..<0
    @Published var focusMode = false
    @Published var focusedReading = true { didSet { defaults?.set(focusedReading, forKey: "focusedReading") } }
    @Published var useCountIn = false { didSet { defaults?.set(useCountIn, forKey: "useCountIn") } }
    @Published private(set) var countInSeconds: Int?
    @Published var showAnnotations = true
    @Published var fontSize: Double = 29 { didSet { defaults?.set(fontSize, forKey: "readingFontSize") } }
    @Published var textWidth: Double = 320 { didSet { defaults?.set(textWidth, forKey: "readingWidth") } }
    @Published var responsiveness: Double = 0.55
    @Published var positionFraction: Double = 0.25
    @Published var backgroundOpacity: Double = 0.98
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRestartingTake = false
    @Published private(set) var hasPendingScriptChanges = false
    @Published var sessionStart: Date?
    @Published var timerMode: TimerMode = .countUp {
        didSet { defaults?.set(timerMode.rawValue, forKey: "presentationTimerMode") }
    }
    @Published var countdownMinutes = 5 {
        didSet { defaults?.set(countdownMinutes, forKey: "presentationCountdownMinutes") }
    }
    @Published var showPaceHints = true {
        didSet { defaults?.set(showPaceHints, forKey: "presentationPaceHints") }
    }
    @Published var displayedScrollTarget = 0
    @Published private(set) var paceWarning: PaceHint?
    private(set) var pacePulseID = 0
    @Published var selectedScriptID: UUID?
    @Published private(set) var performance: PerformanceStylePlan?
    @Published private(set) var takeInProgress = false
    @Published private(set) var summary: TakeSummary?
    private(set) var latestSummary: TakeSummary?
    @Published private(set) var trackingState: VoiceTrackingState = .listening
    @Published private(set) var presentationNotice: String?

    @Published var learnedTrackingEnabled = false { didSet {
        defaults?.set(learnedTrackingEnabled, forKey: "learnedTrackingEnabled.v1")
        if !takeInProgress {
            aligner = ScriptAligner(script: document, decisionModel: learnedTrackingEnabled ? LearnedTrackingModel.available : nil)
            aligner.reset(to: tokenIndex)
        }
    } }
    @Published var personalPacingEnabled = true { didSet {
        defaults?.set(personalPacingEnabled, forKey: "personalPacingEnabled")
        if personalPacingEnabled != oldValue { personalPaceTracker = PersonalPaceTracker() }
    } }
    @Published var saveSpeechFeedback = true { didSet {
        defaults?.set(saveSpeechFeedback, forKey: "saveSpeechFeedback")
        if !saveSpeechFeedback { speechCollector = RecordingSpeechCollector(); pendingSpeechAnalysis = nil }
    } }
    @Published private(set) var paceProfile = PersonalPaceProfile()
    private var personalPaceTracker = PersonalPaceTracker()
    private var speechCollector = RecordingSpeechCollector()
    private var pendingSpeechAnalysis: RecordingSpeechAnalysis?
    private var latestSpeechConfidence: Double?
    var personalPaceEstimate: PersonalPaceEstimate? {
        guard personalPacingEnabled, trackingState != .recovering else { return nil }
        return personalPaceTracker.estimate(remainingWords: max(0, wordCount - trackedWordCount), profile: paceProfile)
    }
    func resetPersonalPace() {
        paceProfile = PersonalPaceProfile(); personalPaceTracker = PersonalPaceTracker()
        defaults?.removeObject(forKey: "personalPaceProfile.v1")
    }

    let speech: SpeechFollower
    let video: CameraRecording
    private var videoChanges: AnyCancellable?
    private var speechChanges: AnyCancellable?
    private let capture: any SpeechCapturing
    private let defaults: UserDefaults?
    private var latestScript: ScriptRecord?
    private var takeIsFrozen = false
    private var restoringMode = false
    private var startGeneration = 0
    private(set) var document = ScriptDocument("")
    private var aligner = ScriptAligner(script: ScriptDocument(""))
    private var presentationClock = PresentationClock()
    private var paceFeedback = PaceFeedback()
    private var trackedWordCount = 0
    private var paceStartWord = 0
    private var takeClock = PresentationClock()
    private var timerWasReset = false
    private var tracking = TrackingFeedback()
    private let now: () -> Date

    init(capture: (any SpeechCapturing)? = nil, video: CameraRecording? = nil, defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.video = video ?? CameraRecording(defaults: defaults)
        let speech = SpeechFollower(defaults: defaults)
        self.speech = speech
        self.capture = capture ?? speech
        self.defaults = defaults
        if let data = defaults?.data(forKey: "personalPaceProfile.v1"), let profile = try? JSONDecoder().decode(PersonalPaceProfile.self, from: data) { paceProfile = profile }
        if let value = defaults?.object(forKey: "personalPacingEnabled") as? Bool { personalPacingEnabled = value }
        if let value = defaults?.object(forKey: "learnedTrackingEnabled.v1") as? Bool { learnedTrackingEnabled = value }
        if let value = defaults?.object(forKey: "saveSpeechFeedback") as? Bool { saveSpeechFeedback = value }
        self.speech.onObservation = { [weak self] event in
            guard let self, self.isRunning else { return }
            let confidences = event.words.compactMap(\.confidence)
            self.latestSpeechConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            if self.personalPacingEnabled, event.isFinal, self.confidence != .low, self.trackingState != .recovering { self.personalPaceTracker.observePauseTimings(event.words) }
            if self.saveSpeechFeedback { self.speechCollector.consume(event) }
        }
        self.video.onSaved = { [weak self] url in
            guard let self, self.saveSpeechFeedback, let analysis = self.pendingSpeechAnalysis else { return }
            self.pendingSpeechAnalysis = nil
            Task { @MainActor in
                do { try await Task.detached(priority: .utility) { try RecordingSpeechAnalysisStore.write(analysis, video: url) }.value }
                catch { self.presentationNotice = "Video saved. Speech feedback could not be saved." }
            }
        }
        if let value = defaults?.object(forKey: "focusedReading") as? Bool { focusedReading = value }
        if let value = defaults?.object(forKey: "useCountIn") as? Bool { useCountIn = value }
        if let value = defaults?.object(forKey: "readingFontSize") as? Double { fontSize = min(32, max(20, value)) }
        if let value = defaults?.object(forKey: "readingWidth") as? Double { textWidth = min(350, max(230, value)) }
        if let savedMode = defaults?.string(forKey: "presentationTimerMode"),
           let parsedMode = TimerMode(rawValue: savedMode) { timerMode = parsedMode }
        if let savedMinutes = defaults?.object(forKey: "presentationCountdownMinutes") as? Int {
            countdownMinutes = min(max(savedMinutes, 1), 180)
        }
        if let savedHints = defaults?.object(forKey: "presentationPaceHints") as? Bool {
            showPaceHints = savedHints
        }
        speechChanges = self.speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        videoChanges = self.video.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.video.onInterrupted = { [weak self] in
            if let self, self.saveSpeechFeedback { self.pendingSpeechAnalysis = self.speechCollector.snapshot(script: self.document.source) }
            self?.pause()
            self?.presentationNotice = "Camera recording stopped · Your place is kept. Check the saved video in Studio."
        }
        self.capture.onTranscript = { [weak self] text in self?.consume(text) }
        self.capture.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.isStarting = false
            self.countInSeconds = nil
            self.startGeneration += 1
            self.displayedScrollTarget = self.scrollAnchor(forToken: self.tokenIndex)
            self.presentationClock.pause(at: self.now())
            self.takeClock.pause(at: self.now())
            if self.sessionStart == nil { self.takeInProgress = false }
            self.clearPaceFeedback()
        }
    }

    var scriptTitle: String { latestScript?.title ?? "CameraCue" }
    var activeLineID: Int { document.lineID(forToken: tokenIndex) }
    /// The detached reader can anchor on a stage direction; the notch renders only spoken rows.
    var displayedReadingLineID: Int {
        document.lines.dropFirst(displayedScrollTarget).first(where: { !$0.spokenText.isEmpty })?.id ?? activeLineID
    }
    var progress: Double { document.tokens.isEmpty ? 0 : Double(trackedWordCount) / Double(document.tokens.count) }
    var wordCount: Int { document.tokens.count }
    var phase: PresentationPhase {
        if countInSeconds != nil { return .countIn }
        if isStarting { return .starting }
        if isRunning { return .running }
        if summary != nil && !takeInProgress { return .finished }
        return takeInProgress ? .paused : .ready
    }
    var displayIsLocked: Bool { takeInProgress || isRestartingTake }
    func snapshot(at date: Date) -> PresentationSnapshot {
        let status: String
        switch phase {
        case .ready: status = "Ready"
        case .starting: status = "Getting ready"
        case .countIn: status = "Starting in \(countInSeconds ?? 0)"
        case .running: status = mode == .manual ? "Manual" : trackingState.rawValue
        case .paused: status = "Paused"
        case .finished: status = "Finished"
        }
        let line = displayedReadingLineID
        var cue = ""
        if showAnnotations, document.lines.indices.contains(line) {
            let annotation = document.lines[line].annotation ?? (line > 0 ? document.lines[line - 1].annotation : nil)
            cue = annotation?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
            if let delivery = performance?.deliveryCue(for: document.lines[line]), !delivery.isEmpty { cue = delivery }
            else if cue.isEmpty, performance?.pauseAfter(document.lines[line]) == true { cue = "Leave a little pause" }
        }
        let problem: String?
        if let presentationNotice { problem = presentationNotice }
        else if mode != .manual {
            switch capture.state {
            case .denied: problem = "Allow microphone and speech access in Settings"
            case .unavailable: problem = "Speech unavailable · Manual mode is available"
            case .error, .interrupted: problem = "Check microphone · Resume when ready"
            default: problem = nil
            }
        } else { problem = nil }
        return PresentationSnapshot(phase: phase, status: status, lineID: line,
                                    wordIndex: mode != .manual && takeInProgress ? followedWordIndex : nil,
                                    timerText: presentationTime(at: date), overtime: presentationIsOvertime(at: date),
                                    countIn: countInSeconds, warning: trackingState == .recovering ? nil : paceWarning,
                                    recovering: isRunning && mode != .manual && trackingState == .recovering,
                                    cue: cue, problem: problem, canFinish: takeInProgress && !isStarting,
                                    summary: phase == .finished ? summary : nil)
    }
    private var timerDuration: TimeInterval { TimeInterval(min(max(countdownMinutes, 1), 180) * 60) }
    func presentationTime(at date: Date) -> String {
        timerMode == .countdown
            ? presentationClock.countdownDisplay(duration: timerDuration, at: date)
            : presentationClock.display(at: date)
    }
    func presentationIsOvertime(at date: Date) -> Bool {
        timerMode == .countdown && presentationClock.elapsed(at: date) > timerDuration
    }
    func paceHint(at date: Date) -> PaceHint? {
        guard timerMode == .countdown, showPaceHints, mode != .manual,
              isRunning, wordCount > 0, trackingState != .recovering else { return nil }
        if let forecast = personalPaceEstimate, presentationClock.elapsed(at: date) >= 15 {
            return forecast.hint(remainingTarget: timerDuration - presentationClock.elapsed(at: date), threshold: max(15, timerDuration * 0.08))
        }
        let remaining = wordCount - paceStartWord
        let timerProgress = remaining > 0 ? Double(max(0, trackedWordCount - paceStartWord)) / Double(remaining) : 1
        return PaceGuidance.hint(elapsed: presentationClock.elapsed(at: date),
                                 duration: timerDuration, progress: timerProgress, previous: paceWarning)
    }
    /// Called by the notch's existing one-second clock and on speech/state changes.
    @discardableResult func refreshPaceFeedback(at date: Date) -> Bool {
        guard isRunning, timerMode == .countdown, showPaceHints, mode != .manual, trackedWordCount < wordCount, trackingState != .recovering else {
            clearPaceFeedback(); return false
        }
        let pulse = paceFeedback.update(paceHint(at: date), at: date)
        if pulse { pacePulseID += 1 }
        if paceWarning != paceFeedback.hint { paceWarning = paceFeedback.hint }
        return pulse
    }
    private func clearPaceFeedback() {
        paceFeedback.reset()
        if paceWarning != nil { paceWarning = nil }
    }

    func load(_ script: ScriptRecord) {
        latestScript = script
        let validPlan = script.performance.flatMap { $0.isValid(for: script.body) ? $0 : nil }
        let readingBody = validPlan?.formattedBody ?? PerformanceLayout.reflow(script.body, targetWidth: 26)
        let changed = selectedScriptID != script.id || document.source != readingBody || performance?.id != validPlan?.id
        guard changed else { hasPendingScriptChanges = false; return }
        if selectedScriptID == script.id && takeIsFrozen {
            hasPendingScriptChanges = true
            return
        }
        stopCapture()
        takeIsFrozen = false
        hasPendingScriptChanges = false
        presentationClock.reset(); sessionStart = nil
        takeClock.reset(); takeInProgress = false; summary = nil; timerWasReset = false
        tracking.reset(); trackingState = .listening; presentationNotice = nil
        selectedScriptID = script.id
        performance = validPlan
        document = ScriptDocument(readingBody)
        aligner = ScriptAligner(script: document, decisionModel: learnedTrackingEnabled ? LearnedTrackingModel.available : nil)
        tokenIndex = 0; confidence = .low; matchedPhrase = ""; searchRange = 0..<0
        followedWordIndex = nil
        trackedWordCount = 0; paceStartWord = 0
        displayedScrollTarget = scrollAnchor(forToken: 0)
        objectWillChange.send()
    }

    func start() async {
        if phase == .finished { reset(); return }
        guard !document.tokens.isEmpty, !isRunning, !isStarting, !video.enabled || video.canStart || video.isRecording else { return }
        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        takeInProgress = true
        presentationNotice = nil
        tracking.reset(); trackingState = .listening
        takeIsFrozen = true
        if video.enabled && !video.isRecording {
            let prepared = await video.prepare()
            guard generation == startGeneration else { video.closePreview(); return }
            if !prepared {
                isStarting = false
                if sessionStart == nil { takeInProgress = false; takeIsFrozen = false }
                presentationNotice = video.message
                return
            }
        }
        if mode != .manual { await capture.start() }
        guard generation == startGeneration else { return }
        if Task.isCancelled { pause(); return }
        var ready = mode == .manual || capture.state == .listening
        if ready && useCountIn && sessionStart == nil {
            for remaining in (1...3).reversed() {
                guard generation == startGeneration else { return }
                if Task.isCancelled { pause(); return }
                countInSeconds = remaining
                do { try await Task.sleep(for: .seconds(1)) }
                catch { if generation == startGeneration { pause() }; return }
            }
        }
        guard generation == startGeneration else { return }
        if Task.isCancelled { pause(); return }
        countInSeconds = nil
        if ready && video.enabled && !video.isRecording {
            ready = await video.start(title: scriptTitle)
            guard generation == startGeneration else { video.finish(); return }
            if !ready { capture.stop(); presentationNotice = video.message }
        }
        if !ready { video.closePreview() }
        isStarting = false
        isRunning = ready
        if isRunning {
            if sessionStart == nil {
                personalPaceTracker = PersonalPaceTracker()
                latestSpeechConfidence = nil
                speechCollector.begin(at: ProcessInfo.processInfo.systemUptime)
                pendingSpeechAnalysis = nil
            }
            presentationClock.start(at: now())
            takeClock.start(at: now())
            if sessionStart == nil { sessionStart = now() }
        } else if sessionStart == nil {
            takeInProgress = false
            takeIsFrozen = false
            if let latestScript { load(latestScript) }
        }
    }
    func toggle() async {
        if countInSeconds != nil { pause(); return }
        guard !isStarting else { return }
        if isRunning { pause() } else { await start() }
    }
    /// The notch's Record/light control finishes a take; Studio and shortcuts
    /// retain Pause/Resume for temporary interruptions. Video continues through prompting pauses.
    func performNotchRecordAction() async {
        guard !isRestartingTake else { return }
        switch phase {
        case .running: finish()
        case .starting, .countIn: pause()
        case .finished:
            reset()
            await start()
        case .paused where video.isRecording: finish()
        case .ready, .paused: await start()
        }
    }
    func pause() {
        personalPaceTracker.resetAnchor()
        startGeneration += 1
        capture.pause()
        isStarting = false; isRunning = false
        countInSeconds = nil
        presentationClock.pause(at: now())
        takeClock.pause(at: now())
        if sessionStart == nil { takeInProgress = false; video.closePreview() }
        displayedScrollTarget = scrollAnchor(forToken: tokenIndex)
        clearPaceFeedback()
        tracking.reset(); trackingState = .listening
    }
    func pauseForDisplayChange() {
        let wasInProgress = takeInProgress
        pause()
        // A display loss is an interruption, including during the count-in.
        if wasInProgress { takeInProgress = true }
        presentationNotice = "Display disconnected · Your place is kept"
    }
    func finish() {
        guard takeInProgress, !isStarting else { return }
        let date = now()
        presentationClock.pause(at: date); takeClock.pause(at: date)
        let result = TakeSummary(activeDuration: takeClock.elapsed(at: date), timerDuration: presentationClock.elapsed(at: date),
                                 targetDuration: timerMode == .countdown ? timerDuration : nil, timerWasReset: timerWasReset)
        if saveSpeechFeedback { pendingSpeechAnalysis = speechCollector.snapshot(script: document.source) }
        if personalPacingEnabled, let sample = personalPaceTracker.sample(activeSeconds: takeClock.elapsed(at: date), at: date) {
            paceProfile.record(sample)
            if let data = try? JSONEncoder().encode(paceProfile) { defaults?.set(data, forKey: "personalPaceProfile.v1") }
        }
        stopCapture()
        video.finish()
        displayedScrollTarget = scrollAnchor(forToken: tokenIndex)
        summary = result; latestSummary = result; takeInProgress = false; presentationNotice = nil
    }
    private func stopCapture() {
        startGeneration += 1
        capture.stop()
        isStarting = false; isRunning = false
        countInSeconds = nil
        clearPaceFeedback()
    }
    func stop() {
        stopCapture()
        if video.isRecording { video.finish() } else { video.closePreview() }
        followedWordIndex = nil
        takeIsFrozen = false
        takeInProgress = false; summary = nil; timerWasReset = false; presentationNotice = nil
        takeClock.reset(); tracking.reset(); trackingState = .listening
        sessionStart = nil; presentationClock.reset()
        if let latestScript { load(latestScript) }
    }
    /// Save the interrupted recording before starting a distinct new file.
    func restartTake() async {
        guard !isRestartingTake, !isStarting, !document.tokens.isEmpty else { return }
        isRestartingTake = true
        defer { isRestartingTake = false }
        if takeInProgress { finish() }
        if video.state == .saving { await video.waitUntilSaved() }
        guard !Task.isCancelled else { return }
        if video.enabled && video.state == .failed {
            presentationNotice = "Previous take could not be saved. Retry saving before restarting."
            return
        }
        reset()
        await start()
    }

    /// Return to Ready without starting capture.
    func reset() {
        stop()
        aligner.reset(); tokenIndex = 0
        trackedWordCount = 0; paceStartWord = 0
        displayedScrollTarget = scrollAnchor(forToken: 0)
        confidence = .low; matchedPhrase = ""
    }
    func move(lines: Int) {
        let spoken = document.lines.filter { !$0.spokenText.isEmpty }
        guard !spoken.isEmpty else { return }
        let current = spoken.firstIndex(where: { $0.id == activeLineID }) ?? 0
        seek(toLine: spoken[min(max(current + lines, 0), spoken.count - 1)].id)
    }
    func selectPhrase(_ lineID: Int) {
        guard !isRunning, !isStarting else { return }
        seek(toLine: lineID)
    }
    private func seek(toLine target: Int) {
        guard document.lines.indices.contains(target), !document.lines[target].spokenText.isEmpty else { return }
        let index = document.tokenIndex(forLine: target)
        personalPaceTracker.resetAnchor()
        aligner.reset(to: index)
        tokenIndex = index; displayedScrollTarget = scrollAnchor(forToken: index); confidence = .low
        followedWordIndex = nil
        trackedWordCount = index
        tracking.reset(); trackingState = .listening; clearPaceFeedback()
        if sessionStart == nil { paceStartWord = index }
    }
    func resetTimer() {
        presentationClock.reset()
        if sessionStart != nil { timerWasReset = true }
        paceStartWord = trackedWordCount
        clearPaceFeedback()
        if isRunning { presentationClock.start(at: now()); sessionStart = now() }
        objectWillChange.send()
    }
    func moveBeat(direction: Int) {
        let current = activeLineID
        let step = direction >= 0 ? 1 : -1
        var line = current + step
        while line >= 0 && line < document.lines.count {
            if document.lines[line].spokenText.trimmingCharacters(in: .whitespaces).isEmpty ||
                document.lines[line].text.trimmingCharacters(in: .whitespaces).isEmpty {
                move(lines: line - current + step)
                return
            }
            line += step
        }
        move(lines: direction * 3)
    }
    private func scrollAnchor(forToken index: Int) -> Int {
        let line = document.lineID(forToken: index)
        if line > 0, document.lines[line - 1].spokenText.isEmpty,
           document.lines[line - 1].annotation != nil { return line - 1 }
        return line
    }

    private func consume(_ text: String) {
        guard isRunning, mode != .manual else { return }
        let result = aligner.align(text, recognizerConfidence: latestSpeechConfidence)
        if personalPacingEnabled { personalPaceTracker.observe(position: result.tokenIndex, activeElapsed: takeClock.elapsed(at: now()), reliable: result.confidence != .low) }
        tracking.consume(text, confidence: result.confidence, at: now())
        if trackingState != tracking.state { trackingState = tracking.state }
        if trackingState == .recovering { clearPaceFeedback() }
        confidence = result.confidence
        matchedPhrase = result.matchedPhrase
        searchRange = result.searchRange
        if result.confidence != .low {
            trackedWordCount = result.tokenIndex + 1
            if followedWordIndex != result.tokenIndex { followedWordIndex = result.tokenIndex }
        }
        guard result.moved else { return }
        tokenIndex = result.tokenIndex
        // Deliver the latest reliable target in the same turn as the word highlight.
        // SwiftUI coalesces burst updates, and the scroll spring retargets in flight;
        // adding a debounce here makes the camera text lag behind the speaker.
        let nextLine = scrollAnchor(forToken: tokenIndex)
        if displayedScrollTarget != nextLine { displayedScrollTarget = nextLine }
    }
}
