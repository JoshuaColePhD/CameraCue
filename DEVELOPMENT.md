# Developing CameraCue

## Toolchain

Use macOS 15+ and Xcode 26+ with Swift 6.2 or later selected. The package builds in Swift 6 language mode, including strict concurrency checks. Foundation Models code requires a macOS 26+ SDK; on older supported systems its availability is checked at runtime.

```sh
swift --version
xcodebuild -version
swift test --disable-sandbox
./scripts/evaluate-voice-follow.sh --check --output /tmp/voice-follow-results.json
./build-app.sh release
codesign --verify --deep --strict dist/CameraCue.app
```

The build script obtains SwiftPM's binary path instead of assuming one Xcode version's output layout. It creates an ad hoc signed app for local use. Developer ID signing and notarization are separate distribution work.

## Code map

See [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries, speech alignment, concurrency, capture/export state and storage decisions. [Voice Follow evaluation](docs/VOICE_FOLLOW_EVALUATION.md) describes the corpus, baselines, metrics and regression gates. [Acceptance status](docs/ACCEPTANCE.md) distinguishes automated verification from outstanding hardware checks. [Background asset provenance](Assets/Backgrounds.md) covers bundled image assets.

- `TeleprompterCore`: token normalization, alignment, formatting, timing, recovery and pacing.
- `TeleprompterApp`: Studio, native editor, display selection, notch, speech and video integration.
- `VoiceFollowEvaluation`: deterministic replay CLI and frozen comparison algorithms.
- `Tests`: core logic, capture fixtures, generated media, native controls and opt-in documentation rendering.

## Motion and display geometry

`NotchMotion` is the single specification: **300 ms opening, 240 ms closing**, with a shared smooth easing curve. `NotchSurface` animates native shell/mask paths and moving controls from their current presentation-layer values. Generation guards prevent old completion callbacks from changing a reversed transition. Reader content remains mounted; no animation frames are published through SwiftUI. Reduce Motion applies final geometry immediately.

Display selection is separate from geometry. While idle the notch follows the clicked working display; count-in, running and paused takes lock it. Display disconnection pauses and relocates for explicit Resume. Full screen bounds anchor the notch to the menu-bar top; camera housing, menu-band availability and backing scale determine compact geometry. Expanded layout helpers are shared with the noninteractive preview.

Do not duplicate coordinates or timing constants in documentation. Use `NotchLayout`, `NotchDisplay` and `NotchMotion` when changing behavior. Existing reader-height preferences remain local.

## Verification and CI

[macOS CI](https://github.com/JoshuaColePhD/CameraCue/actions/workflows/macos-ci.yml) runs XCTest, Voice Follow per-case regression gates, and a release package/signature check. Logs and JSON results are uploaded as job artifacts. Test totals are extracted from all target-level suite results by `scripts/test-summary.py`; no manual README count is maintained.

Graphics/encoding tests need macOS services and a logged-in WindowServer locally. A filesystem/process sandbox may prevent those services even with `swift test --disable-sandbox` (which disables SwiftPM's build sandbox only). Private clip tests skip when their fixture is absent. Tests use generated frames or injected capture and do not activate a live camera or microphone.

To inspect native motion frame intervals, use `CAMERACUE_PROFILE_MOTION=1` with `NotchMotionTests`. Those intervals are not a guarantee of product FPS. Use `CAMERACUE_TIMER_SNAPSHOTS=1` with `TimerPopoverTests` for an isolated timer render. A physical dual-display check is still needed for menu containment, input routing and real refresh behavior.

## Rebuild documentation media

```sh
CAMERACUE_DOC_MEDIA="$PWD/docs/media" swift test --disable-sandbox --filter DocumentationMediaTests
```

This opt-in renderer mounts production views with an isolated temporary script library and a fake speech source. It produces Studio/reader screenshots and a transcript-driven highlighting GIF. It does not touch the user's scripts or record camera/audio. The GIF is labeled as simulated in the README. Inspect the generated images before committing them.

## Contribution hygiene

Keep commits focused: implementation, relevant tests, and an explanation of measured behavior. Never commit recordings, personal scripts, credentials or machine-specific traces. Fixtures used for public evaluation must have documented provenance. Keep the evaluation references frozen unless a reviewed algorithm/corpus change justifies replacing them. The repository's MIT license covers project code; transcript and asset provenance remain documented separately.
