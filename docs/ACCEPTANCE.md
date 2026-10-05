# Verification and remaining acceptance work

Updated October 5, 2026. This file is tracked so verification references remain accessible from a fresh clone. Machine-specific logs and private media are intentionally not published.

## Completed in this pass

- Compiled the native app and test targets in Swift 6 language mode.
- Ran all XCTest targets with macOS graphics/encoding access: zero failures. Documentation rendering and motion profiling are opt-in and skip in an ordinary run. Current totals are generated in CI, rather than maintained in prose.
- Compared the production aligner with an exact suffix baseline and the frozen earlier aligner on published transcripts with simulated errors. Tuned only the development corpus and evaluated the distinct held-out speech afterward. See [results and limitations](VOICE_FOLLOW_EVALUATION.md).
- Rendered production Studio and notch views with isolated sample scripts. Inspected screenshots; generated a transcript-replay GIF. No camera or microphone was started.
- Added Mac CI with per-case replay regression checks, full XCTest, release packaging and ad hoc signature verification. See the workflow badge/run for the current server result.

## Remaining hardware and distribution checks

- End-to-end live Voice Follow with timestamped audio, recognizer callbacks and visual highlights across speakers, accents, room noise and improvisation. Replay does not establish microphone/recognizer latency.
- Live recording after permissions, long takes, audio synchronization by listening, interruption recovery and concurrent QuickTime use.
- Physical MacBook/external-display placement at varied scales, arrangements, auto-hidden menu bars, sleep/wake and disconnection. Automated geometry fixtures do not prove all monitor configurations.
- Perceptual motion profiling on actual display refresh rates and segmentation quality around hair, hands and changing backgrounds.
- Developer ID signing/notarization and a customer installer. The current build is for local testing.

The code and replay results provide specific evidence, not a claim that every UI flow or hardware configuration is flawless.
