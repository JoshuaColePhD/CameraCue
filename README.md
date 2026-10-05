# CameraCue

A native macOS script studio, voice-following teleprompter, and camera recorder. Warm white Studio surfaces and pastel accents pair with a calm camera-centered notch reader.

## Features

- **Write, rehearse, present:** native editing, selection-based emphasis/pauses/delivery cues, undo/redo, autosave, and reviewable AI formatting and drafting.
- **Voice Follow:** tracks spoken words, highlights the latest reliable match, holds through silence, and offers recovery when speech loses its place. Manual prompting is also available.
- **Notch reader:** tapered shell, native Core Animation transitions, compact controls, adjustable reader height, and placement for notched and external displays.
- **Presentation timer:** count up or down, negative overtime, pacing hints, optional count-in, pause/resume, and manual Finish.
- **Camera recording:** mirrored self-view, unmirrored H.264/AAC MP4 output, device selection, audio meter, saved-take playback, and a recording library. Prompting can pause while video continues.
- **Background effects:** Original, Blur, five pastel colors, three bundled image presets, and custom image upload. Processing uses Apple's Vision and Core Image on the Mac.
- **Background edits after recording:** preview an effect and export a new MP4 while preserving the existing recording and its audio. Optional camera originals allow restoring the real background.

AI uses Apple's on-device model when available. Formatting falls back to clearly identified local styling when that model is unavailable. CameraCue does not upload scripts or videos and does not control QuickTime.

## Requirements

- macOS 15 or later.
- Xcode with a Swift 6-capable toolchain and command-line tools selected.
- Python 3 for app-icon packaging, using the standard library and macOS `sips`.
- Camera, microphone, and speech permissions only when those features are requested.
- Apple's on-device AI features additionally require compatible hardware, OS, and model availability.

## Build

```sh
./build-app.sh release
```

The app is written to `dist/CameraCue.app` and signed ad hoc for local use. A Developer ID certificate and notarization are required for normal distribution to other Macs. The source repository does not contain personal scripts, recordings, or built app bundles.

To install a local build, quit an idle CameraCue instance, then:

```sh
ditto dist/CameraCue.app /Applications/CameraCue.app
codesign --verify --deep --strict /Applications/CameraCue.app
```

## Test

```sh
swift test --disable-sandbox
```

The suite covers alignment, timers, formatting, library persistence, capture lifecycle, background processing/export, display layout, native notch controls, and editor selection. Some graphics and encoder tests require access to macOS WindowServer/encoding services. Local camera-clip checks skip when their private fixture is unavailable. No test starts a live camera or microphone.

Real camera and microphone permissions, live dual-stream recording performance, lengthy recordings, and different monitor arrangements still need hardware acceptance checks.

## Local data

| Data | Default location |
| --- | --- |
| Script library | `~/Library/Application Support/CameraCue/scripts.json` |
| Saved MP4 videos | `~/Movies/CameraCue/` (changeable in Camera & recording) |
| Original camera copies | `.Originals/` inside the recording folder |
| Background-edited videos | New MP4 files beside the existing recording |
| Recording source links | Optional `.mp4.cameracue.json` files beside videos |
| Uploaded background images | `~/Library/Application Support/CameraCue/Backgrounds/` |
| UI/device preferences | macOS UserDefaults |

Keep a recording's sidecar and original folder together if you move it. A video remains playable without those files, but background restoration can no longer use the original camera copy. GitHub stores development source only; it does not synchronize this local data.

## Code layout

- `Sources/TeleprompterCore/`: alignment, token anchors, formatting metadata, timing, and tracking/pacing logic.
- `Sources/TeleprompterApp/`: native Studio, notch, speech capture, camera capture, recording library, and video background editor.
- `Tests/`: generated-data regression fixtures and unit/integration tests.
- `Assets/`: selected icon and background asset provenance.
- `scripts/`: packaging and local benchmarking utilities.

See [DEVELOPMENT.md](DEVELOPMENT.md) for implementation details and [Assets/Backgrounds.md](Assets/Backgrounds.md) for the bundled image prompts. Historical review reports and recordings remain local and are excluded from Git.
