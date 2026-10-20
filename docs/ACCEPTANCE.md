# Verification and remaining acceptance work

Updated October 20, 2026. This file is tracked so verification references remain accessible from a fresh clone. Machine-specific logs and private media are intentionally not published.

## Source publication review — October 20

A clean checkout of the application code at `141bd36` was verified with Xcode 27.1 and Swift 6.4:

- Native suite: 194 tests, 7 skipped, zero failures across three targets. Opt-in and private-fixture skips retain their documented boundaries.
- The documented release build produced a local app package and passed `codesign --verify --deep --strict`. The build left the checkout clean.
- Voice Follow's frozen per-case regression gates passed. This remains transcript replay with simulated recognizer errors.
- The scoped confidence-model simulation matched its versioned regression totals; no speech recognition or model download was needed.
- Gitleaks 8.30.1 found no secrets in the reachable Git history or commit messages. Historical filenames contained no raw recordings, private script-library files, or credential files. Documentation image versions were inspected and use sample content.
- Local documentation links and existing asset/corpus attribution were checked. The README now makes the source-build status and on-device AI requirements explicit.

Both AI services use Apple's on-device Foundation Models integration. No hosted LLM account or API key is included or required; macOS manages the language-model download. External providers and bring-your-own API keys are not implemented. Core editing, recording, and manual prompting remain available without the language model.

No live camera or microphone session was started for this review. The remaining hardware and distribution checks below still apply; no notarized installer has been produced.

## Current checkpoint — October 7

### Compact Studio iteration — October 8

Workflow navigation now uses equal left/right regions so Write, Rehearse and Record stay centered between workspaces. Below 720 points of detail width, camera settings use a labeled accessible icon with a tooltip. The Preview toggle has a visible selected state. The production native workflow control was measured at 666- and 996-point detail widths across every step, within one point of center; 22 focused layout/placement/notch tests passed.

The host currently reports only the LS24A600U external display (2560 × 1440 points, scale 1, 75 Hz, no physical camera housing). Compact-window checks do not count as a physical MacBook display check. Built-in display measurements and notch inspection remain pending; no camera/microphone capture was started for this iteration. Release signature and installed-executable equality were verified; native inspection of the installed Write and Record workspaces confirmed stationary workflow navigation and the Preview selected state.

The user completed short recordings on October 6 after the audio-tap and preview fixes. Native inspection confirmed a saved take in the recordings library, and another completed take showed a 22-second duration, **Video saved**, **Saved to Movies → CameraCue**, playback and Finder actions in Studio. This establishes that short-take recording/export completed on the development Mac. Audio synchronization, sustained live frame rate and speech-to-highlight latency were not measured in these checks.

The latest implementation at `79b5139` passed [Mac CI](https://github.com/JoshuaColePhD/CameraCue/actions/runs/37472080601), including native tests, Voice Follow regression gates, package/signature verification and the scoped confidence-model gate. Earlier permission failures below are historical findings, not the current recording outcome. Developer ID notarization and wider hardware acceptance remain pending.

The October 7 polish pass also reran the full native suite and frozen Voice Follow gate locally with zero failures. Production Home screenshots at 1230 × 800 and 900 × 680 and the reader screenshot were rendered from isolated sample scripts and inspected; the transcript-replay GIF was regenerated. No private script or recording was included in the documentation media. The completed-take setup action now says **Prepare another take**, matching its behavior.

## Completed in this pass

### On-device AI checkpoint — October 7

Apple's on-device model reported available on the development Mac. The installed app's Draft with AI generated a 215-word script from a fictional gardening-club brief; the result was inspected and cancelled without saving. An opt-in production-service check generated a 45-word revision, added delivery cues without changing spoken tokens, and produced six AI formatting moments with a valid word-preserving plan. Input validation, formatting fallback, dashboard formatting, local pacing and coaching/tracking fixtures also passed. No camera or microphone was activated. These checks establish successful local inference and source-preservation safeguards, not factual accuracy or universal model availability. Luna is not integrated.

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

## Earlier recording-readiness check — October 5

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
## Save confirmation and pacing feedback — October 6, 2026

- Restart take: refresh control in the expanded notch footer and Studio during a take. It saves the previous MP4, resets script/timing, then starts a distinct recording with the existing count-in preference. Navigation stays locked during restart; duplicate requests are ignored. Save failure prevents another capture and preserves recovery. Verified with isolated capture/export fixtures (25 focused recording/presentation tests passed); no new live recording was made for this change.

- The notch observes MP4 export separately from prompting completion: Saving video, Video saved with View recording, or an error with Retry save when the original is recoverable.
- Successful export schedules a smooth collapse after three seconds. Failed export stays expanded. Manual toggling and review navigation cancel pending collapse; a new take invalidates it.
- Studio retains the saved player, actual destination folder, Play video, and Show in Finder. Reduced Motion disables the success fade and uses the existing immediate shell transition.
- Countdown pacing cues retain progress/forecast guidance, three-second confirmation, twelve-second reminder spacing, pause suppression and tracking-recovery priority. Behind-target cues are amber; overtime is coral; ahead-of-target is mint. The timer and reading position stay stationary during the cue pulse.
- Verification: 28 focused capture/presentation/pacing tests passed, including save-success collapse, failed-export persistence and manual-reopening cancellation. Capture was mocked; no new live camera/microphone session was run for this UI pass.
