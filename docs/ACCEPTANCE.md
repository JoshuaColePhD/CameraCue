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

## Current recording-readiness check

The installed CameraCue Studio release was inspected natively in Ready. Preparing a take does not start capture. With explicit permission for a short local camera/microphone test, microphone setup remained pending without a visible dialog even though System Settings showed its grant enabled. It eventually completed; camera preview then remained in preparation and was cancelled by leaving Record. No MP4 was saved in this attempt.

Permission requests now have a bounded 30-second wait, ignore late/duplicate callbacks, and release on cancellation. Camera setup has an explicit Cancel action; failed Voice Follow setup offers System Settings. Relevant permission/capture regressions pass. The final application was built, installed and its executable hash and signature verified. Native checks confirmed unanswered microphone and camera requests return to enabled controls after the timeout; no test video has been saved. These changes make failure recoverable; they do not prove successful live recording or diagnose the OS attribution issue conclusively.

A Developer ID/hardened-runtime/notarization packaging workflow is now provided, with syntax and entitlements validation. Apple identity/profile access and actual notarization, Gatekeeper and clean-Mac acceptance remain pending. The existing personal/local certificate is not a Developer ID distribution certificate.

## Available-display checkpoint

The installed code at `6d73888` passed [Mac CI](https://github.com/JoshuaColePhD/CameraCue/actions/runs/37407906665): native tests, Voice Follow regression gates, app package/signature and the scoped learned-model gate.

An opt-in isolated native motion/popover run passed on the available **Built-in Retina Display**, backing scale 2, reported maximum refresh 120 Hz. Across twelve open/close cycles, 986 display-link callbacks had p95 interval 8.38 ms, maximum 20.85 ms, and zero gaps above 50 ms. These are main-run-loop display-link callback intervals, not measured render-server frame delivery or microphone-to-visible-highlight latency. The external display was unavailable for this run.

Timer popovers remained within the available screen at left, center and right anchors and retained their size across direction and long-target changes. The countdown snapshot was inspected for clipping. No camera/microphone was activated by these isolated fixtures. The live permission/recording acceptance above remains unfinished.

## October 6 recording crash and preview fix

A local crash report from a Record attempt identified a Swift executor assertion in `SpeechFollower.startAudio` on `RealtimeMessenger.mServiceQueue`. The modern audio tap had inherited MainActor isolation even though Core Audio invokes it on a background thread. The production tap now comes from a nonisolated factory with an explicitly Sendable callback; legacy speech and microphone-meter taps are also explicitly Sendable. A regression invokes the actual modern production callback from a detached task without microphone capture.

Ongoing balanced-quality person segmentation now runs on its own serial worker. Only one retained frame/job can be pending, cancelled generations cannot publish stale masks, and the initial mask is seeded before preview. Subsequent video frames composite using the latest completed mask. Offline accurate segmentation is unchanged.

On the same local 60-frame camera clip, frame-processing median/p95 changed from 14.43/27.58 ms to 3.35/3.98 ms in focused runs. The initial mask still cost 88 ms in the latter run; it occurs during camera startup. These are local fixture processing costs, not measured live capture FPS, AVFoundation frame drops, or saved-video frame-rate guarantees. The full native regression passed, including generated MP4 export, subject/background preservation, bounded worker/reset tests and the audio-thread regression. Installed release signature and executable equality were verified.

The patched app launches and reaches Record setup, but still reports microphone setup needed after the ad hoc rebuild. A fresh live recording and perceptual preview check remain required; the existing stable-local-signing decision is still pending. No successful recording is claimed from these tests.
