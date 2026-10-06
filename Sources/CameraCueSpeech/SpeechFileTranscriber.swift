import Foundation
import AVFoundation
import Speech
import TeleprompterCore

public struct FileSpeechResult: Codable, Sendable {
    public let engine: SpeechEngineID
    public let observations: [SpeechObservation]
    public let text: String
    public let words: [TimedSpeechWord]
    public let audioDuration: Double
    public let elapsedSeconds: Double
    public let realtime: Bool
    public let fastResults: Bool?
}

@MainActor public enum SpeechFileTranscriber {
    /// Real-time mode feeds original PCM at 1x speed. Offline mode measures
    /// throughput and WER only; it must never be presented as live latency.
    public static func transcribe(url: URL, engine: SpeechEngineID, realtime: Bool, allowModelDownload: Bool = false,
                                  fastResults: Bool = false, retainObservations: Bool = true, onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> FileSpeechResult {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0 else { throw SpeechSessionError.audioFormat }
        if engine == .legacy && duration > 55 { throw NSError(domain: "CameraCue.Speech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Legacy streaming evaluation clips must be 55 seconds or shorter."]) }
        var events: [SpeechObservation] = [], ledger = SpeechTranscriptLedger()
        let handler: @MainActor (SpeechObservation) -> Void = { event in
            ledger.consume(event)
            if retainObservations { events.append(event) }
        }
        let session: any StreamingSpeechSession
        if engine == .analyzer {
            guard #available(macOS 26, *) else { throw SpeechSessionError.unsupported }
            session = AnalyzerSpeechSession(fastResults: fastResults, onObservation: handler)
        } else { session = LegacySpeechSession(onObservation: handler) }
        try await session.prepare(format: format, allowModelDownload: allowModelDownload)
        defer { session.stop() }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds((realtime ? duration : 0) + max(30, duration * 2)))
            if !Task.isCancelled { session.stop() }
        }
        defer { timeout.cancel() }
        let capacity = AVAudioFrameCount(max(1, format.sampleRate * 0.08))
        var fed = 0.0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SpeechSessionError.audioFormat }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            session.append(try OwnedSpeechBuffer(copying: buffer), sourceUptime: nil)
            await session.drainInput()
            fed += Double(buffer.frameLength) / format.sampleRate
            onProgress?(min(1, fed / duration))
            if realtime {
                let remaining = fed - session.elapsed
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
        }
        try await session.finish()
        return FileSpeechResult(engine: engine, observations: retainObservations ? events : ledger.spans, text: ledger.text, words: ledger.words, audioDuration: duration,
                                elapsedSeconds: session.elapsed, realtime: realtime, fastResults: fastResults)
    }
}
