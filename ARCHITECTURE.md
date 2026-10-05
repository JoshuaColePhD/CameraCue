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

AI drafting/formatting use Foundation Models when available. Local formatting is an explicitly labeled fallback, not an LLM invocation. Videos remain ordinary files under the selected recording folder.

## Verification boundaries

Swift 6 language mode enables strict concurrency checking. Tests inject speech/capture fixtures, generate media, and exercise native controls without activating a camera or microphone. The Mac CI job runs tests, per-case Voice Follow gates and signed-package verification. Live ASR, long takes, perceptual audio sync, segmentation quality and physical display configurations remain separate hardware acceptance work.

## AI-assisted development

Joshua Cole directed the product requirements, visual iterations and workflow decisions. Codex assisted with implementation, debugging, regression tests, evaluation tooling and documentation. This is not a claim that every generated line received an independent human review.

Verification evidence is the compiler, automated tests, deterministic replay results and documented native-view checks. Synthetic replay is useful for alignment regressions; it does not establish human speaking performance. The project is under active development, is locally ad hoc signed, and does not yet ship a notarized customer installer.
