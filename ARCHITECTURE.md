# CameraCue architecture

CameraCue is a native, local-first macOS app. SwiftUI handles Studio; AppKit handles text editing, windows, playback, and precise notch controls. There is no required backend, Supabase service, or cloud video upload.

## Module boundaries

| Module | Owns | Platform dependencies |
| --- | --- | --- |
| `TeleprompterCore` | Script tokenization, phrase alignment, formatting anchors, timing, recovery and pacing rules | Foundation |
| `TeleprompterApp` | Studio, local libraries, notch, permissions, speech capture, recording and exports | SwiftUI, AppKit, Speech, AVFoundation, Vision, Core Image, Foundation Models |
| `VoiceFollowEvaluation` | Deterministic transcript replay, frozen previous implementation, exact-match baseline and regression gates | Core, Foundation, CryptoKit |

## Speech to highlight

1. `SpeechFollower` captures microphone audio through AVAudioEngine and sends Apple Speech partial transcripts to the main actor. It requests on-device recognition when supported; some configurations can use Apple's service.
2. `ScriptDocument` and `TranscriptNormalizer` produce comparable spoken tokens. Bracketed delivery directions are excluded; contractions and supported numbers normalize consistently.
3. `ScriptAligner` compares the trailing transcript with overlapping script windows using fuzzy word similarity and local sequence alignment. It holds on empty/duplicate results, prefers nearby occurrences, and requires stronger evidence for large jumps or restarts. Search expands after distinct misses.
4. `TrackingFeedback` distinguishes unmatched speech from silence. Persistent unmatched results enter recovery without abandoning the last reliable position.
5. `TeleprompterModel` creates one presentation snapshot used by the notch and Studio preview. Matched words update highlighting and the reading anchor. Recovery feedback takes precedence over pacing hints.

The aligner is mutable and intentionally **not Sendable**. Production owns it on the main actor; the evaluation uses it serially. The replay evaluates this alignment boundary, not microphone quality or Apple's recognition latency. See [Voice Follow evaluation](docs/VOICE_FOLLOW_EVALUATION.md).

## Presentation and motion

`PresentationClock` separates active take duration from a resettable timer segment. Ready, starting/count-in, running, paused and finished are explicit states. Pause preserves the reading position; manual Finish freezes prompting time and finalizes an enabled camera recording. CameraCue does not control QuickTime.

`NotchDisplaySelection` selects the working display while idle and locks it during a take. `NotchDisplay` computes geometry from full screen bounds, menu-bar space and physical housing. `NotchSurface` keeps reader content mounted and coordinates native Core Animation shell, mask and control animations. `NotchMotion` is the single timing source. Reversals begin from presentation-layer values; Reduce Motion applies final geometry immediately.

## Camera and saved video

`CameraRecording` owns permission/start/stop/finalization state. Session configuration and sample-buffer processing run on dedicated queues. `CameraBackgroundProcessor` uses Vision segmentation and Core Image compositing; preview and the primary writer consume the same processed pixels. Preview alone is mirrored.

`ProcessedMovieWriter` serializes video/audio appends and finalization with a lock. Its narrowly scoped unchecked Sendable boundary exists because AVFoundation sample callbacks cross queues; it is not a blanket declaration that all AVFoundation objects are safe. `CaptureMoviePair` can retain an original camera stream. MP4 export follows writer finalization; failures retain recoverable MOV files.

`VideoBackgroundExport` creates a separate output, preserves source audio and orientation, supports cancellation and removes partial output. An optional sidecar links edited versions to their original; validated relative paths cannot escape the recording folder.

## Editing and persistence

`ScriptLibrary` saves JSON in Application Support and preserves unreadable data for recovery. `NativeScriptEditor` supplies NSTextView selection, accessibility and undo. UTF-16 selections map to token occurrences through `ScriptTokenMap`, including repeated phrases and Unicode. Formatting must preserve spoken tokens; drafts and rewrites are reviewed separately. Edits during a take queue for the next take. Import completions cannot overwrite newer wording or redirect navigation.

AI drafting/formatting use a `ScriptModelSession` captured when an action begins. `LanguageModelSettings` defaults to Foundation Models and also supports user-configured OpenAI, Anthropic, Ollama, LM Studio, and compatible custom APIs. Model IDs and API addresses are preferences; API keys are stored separately in macOS Keychain, scoped to the provider and base URL. Readiness rendering uses cached key presence; generation reads the actual key at the action boundary. Editing a server address clears the unsaved credential.

`RemoteScriptModelClient` uses stateless text requests, an ephemeral URLSession, timeouts, no response cache, no automatic retries, and a redirect delegate that declines forwarding. OpenAI uses Chat Completions with `max_completion_tokens` and `store: false`; compatible servers use `max_tokens`. Anthropic uses Messages, its version/key headers, and an optional workspace ID. HTTP errors are mapped to actionable messages without exposing response bodies, credentials, or script text in logs. Truncated output is rejected. One action retains its provider snapshot even if settings change while it runs.

Automatic import formatting stays local when an external model is selected. Explicit generation and formatting actions may send relevant script text directly to the user's configured server; model discovery and connection tests run only on explicit actions. Local formatting is an explicitly labeled fallback, not an LLM invocation. Videos remain ordinary files under the selected recording folder and are not sent to language-model APIs.

## Verification boundaries

Swift 6 language mode enables strict concurrency checking. Tests inject speech/capture fixtures, generate media, and exercise native controls without activating a camera or microphone. The Mac CI job runs tests, per-case Voice Follow gates and signed-package verification. Live ASR, long takes, perceptual audio sync, segmentation quality and physical display configurations remain separate hardware acceptance work.

## AI-assisted development

Joshua Cole directed the product requirements, visual iterations and workflow decisions. Codex assisted with implementation, debugging, regression tests, evaluation tooling and documentation. This is not a claim that every generated line received an independent human review.

Verification evidence is the compiler, automated tests, deterministic replay results and documented native-view checks. Synthetic replay is useful for alignment regressions; it does not establish human speaking performance. The project is under active development, is locally ad hoc signed, and does not yet ship a notarized customer installer.

## Speech evaluation and local learning

`CameraCueSpeech` separates file/live transcription from app navigation. On macOS 26 or later, `AnalyzerSpeechSession` uses SpeechAnalyzer and SpeechTranscriber with explicit asset availability and installation. Live modern mode requests fast volatile results; file coaching uses the accurate default reporting configuration. Automatic live selection retains the existing recognizer when available and authorized until comparative acceptance is complete. Legacy file evaluation requires on-device support and never falls back to a server.

Audio taps synchronously copy borrowed PCM into `OwnedSpeechBuffer`. A serial conversion sink feeds a bounded async input sequence; overflow fails explicitly rather than silently losing audio. No audio frame is published through SwiftUI. Recognition callbacks create Sendable value snapshots before crossing to the main actor. SDK callbacks with unspecified executor behavior are explicitly Sendable, preventing Swift from imposing an incorrect main-actor runtime assertion.

`SpeechTranscriptLedger` replaces overlapping volatile results and protects finalized spans. Evaluation distinguishes recognition text, audio timestamps, callback delivery, tracking position, and screen latency (currently unmeasured). Public pilot reference times retain their forced-alignment provenance. Offline throughput is never labeled live latency.

`PersonalPaceTracker` learns from short reliable forward progress, excluding jumps and rebasing across pauses/recovery. Recent window rates blend with a local median profile. Existing pacing hysteresis/pulse logic remains responsible for stable warnings. Profiles and reset controls are local; no recording or telemetry is uploaded.

`AlignmentDecisionModel` is a small multinomial logistic classifier trained on public transcript-error simulations. Its optional pilot veto applies only to uncertain short-phrase jumps in scripts within the training-size domain. Longer scripts retain the established tracker. The pilot is off by default, with corpus attribution bundled alongside weights; invalid resources fall back safely.

Recording feedback is stored in a bounded `.cameracue.speech.json` sidecar. Its transcript timestamps are shifted onto the video's continuous timeline, including prompting pauses. Provisional words and estimated timing are disclosed. Existing MP4 analysis extracts a temporary audio copy and runs on-device transcription. Coaching findings link to native playback; removing feedback moves only the sidecar to Trash. The recording is unchanged.

Modern live transcription requires microphone access and installed model assets. Legacy recognition additionally requires Speech Recognition authorization. Readiness and startup choose the same policy; unavailable modern engines fail before requesting unrelated permissions. Automatic selection prefers modern when legacy access is unavailable, while retaining an available authorized legacy engine.
