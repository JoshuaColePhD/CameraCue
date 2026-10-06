# Real-audio pilot: AMI ES2002b

These are development results, not a claim that Voice Follow is ready for every speaker. The pilot contains sixteen approximately twenty-second clips from four speakers in one meeting: three clean clips per speaker, plus a deterministic 15 dB noise variant of the first clip. Noise variants are correlated with their clean source; they are not independent speakers or recordings.

Training speakers: MEE006 and FEE005. Validation: MEE007. Held-out: MEE008. Speaker identity comes from the corpus meeting metadata, not the A/B/C/D channel letters. No speaker crosses a split. The held-out speaker was not used to fit confidence weights or choose their threshold.

## Streaming recognition

Measured on macOS 27.0.1 using Apple's on-device SpeechAnalyzer, feeding PCM at the original 1x pace. Both configurations use volatile results; fast mode additionally requests `fastResults`. Recognition models may change with OS releases. No camera or microphone was opened.

| Held-out configuration | Normalized WER | Time within two tokens | Wrong jumps | Per-clip p95 word age |
|---|---:|---:|---:|---:|
| Standard reporting | 14.0% | 17.3% | 0 | 3.59–3.93 s |
| Fast reporting | 13.7% | 58.9% | 0 | 1.08–1.24 s |

WER is pooled over reference words. Time accuracy samples the last computed tracker position every 100 ms and is weighted by clip duration. Wrong jumps mean a movement of more than eight tokens ending over five tokens from the reference endpoint. Word age is callback delivery time minus the forced-aligned end of the highlighted reference word, conditional on a valid past endpoint. This is **not** display/render latency. ASR endpoint delivery is reported only when the recognizer supplies a precise endpoint; interpolated volatile spans are excluded. See the JSON reports for sample counts, exclusions, callback accuracy, and naturally occurring recovery episodes.

Using the same recognition traces, the simple exact-three-word suffix baseline scored 16.8% time within two tokens with standard reporting (one wrong jump), and 57.1% with fast reporting (zero wrong jumps). CameraCue's corresponding results were 17.3% and 58.9%. The reporting mode accounts for most of the gain in this small pilot; the tracker improvement over exact matching is modest.

The corpus words were human transcribed, but their timestamps were automatically forced aligned. Boundaries have **not** been manually verified. The local review tool can produce a separately identified reviewed manifest. This meeting contains conversational interruptions and crosstalk; it is not a representative presentation benchmark. One held-out speaker cannot establish accent, microphone, or demographic coverage. Legacy comparison remains unavailable in the native helper: its API returns status 0 despite an enabled and refreshed macOS grant. Stable signing is being evaluated; no legacy metrics are presented as successful. Automatic live selection retains the existing engine when available and authorized; modern fast reporting is selectable explicitly.

## Confidence model and pacing

The logistic classifier uses match quality, candidate ambiguity, coverage, context, displacement, direction, and recent misses. Training data consists of deterministic errors injected into the public transcripts, including spurious recognition of earlier phrases. It is **not audio training**. Constant features, including unavailable ASR confidence, have zero coefficients. Fit uses train speakers; threshold selection uses validation speakers. The model is opt-in and applies only to scripts at or below the largest training-script size (88 normalized tokens). It vetoes only uncertain short-phrase jumps; longer-context recovery retains the rule gates. Unrestricted use delayed legitimate restarts and failed promotion. Long-script regression tests pass through the rule tracker, so passing those tests is fallback evidence, not validation of learned behavior on long scripts. The sixteen real-ASR traces had identical tracking results with the scoped check enabled; this pilot establishes no real-ASR gain from the classifier. In the short-script error/restart simulation, held-out within-two accuracy was 2061/2196 (93.85%) versus 2030/2196 (92.44%) for the rule tracker, with 0 versus 24 wrong jumps. Both trackers recovered from all 72 held-out simulated restart/skip episodes within two callbacks (two consecutive reliable matches). Callback counts are not measured seconds. These numbers include injected errors and are not actual recognition results. The first easier simulation model failed to reject incorrect candidates; it was not promoted.

Pacing forecasts use forced-aligned reference positions and chronological prior clips from the same speaker. On the held-out speaker's twelve eligible forecast points, remaining-time MAE was 1.09 seconds versus 4.33 seconds for a fixed 150 WPM estimate. Eight points used prior personal history. This tests the forecasting calculation with reliable positions; it does not establish accuracy under recognition errors or long presentations.

## Reproduce and review

Crop offsets and source/clip checksums are recorded in the provenance and fixture manifest. Raw audio and traces live in ignored `ReviewArtifacts/MLCorpus`; they are not bundled with the app. `scripts/prepare-ami-corpus.py` prepares the clips from the original signals and annotations. Use `SpeechEvaluation --manifest corpus.json --engine analyzer --realtime --download-model` and add `--fast-results` for the second configuration. Add `--replay-directory` to recompute metrics from a saved trace without re-recognition.

Export confidence rows with `--export-training-rows rows.json`, train with `python3 scripts/train-alignment-confidence.py rows.json --output model.json`, and evaluate sequentially (including observations with no candidate) with `--replay-training-rows rows.json --decision-model model.json`. Run the existing `VoiceFollowEvaluation --decision-model model.json --check` before promotion.

For boundary review: `python3 scripts/review-speech-timing.py corpus.json --clip CLIP_ID --output review.html`. Open locally, listen and check every boundary, enter a reviewer identity, then export. Apply using `--apply reviewed.json --output corpus-reviewed.json`; the original manifest stays unchanged.

## Attribution and commercial compatibility

Source: [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/download/), AMI Consortium, manual annotations v1.6.2 and ES2002b headset signals. The signals and transcripts are [CC BY 4.0](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml). Cropping, punctuation normalization, Gaussian noise, and simulated recognition errors are CameraCue's changes; the corpus creators do not endorse CameraCue.

CC BY 4.0 permits commercial reuse with attribution, a license link, and identification of changes. Published corpus-derived evaluation data and experimental confidence weights retain that attribution and license; CameraCue source code remains MIT. User recordings are not part of this corpus and are not uploaded. Apple speech models are managed by the OS and are not redistributed by CameraCue.

The compressed-audio integration smoke test transcribed the first licensed clip after AAC encoding, preserving valid timestamp provenance and recognizing 84 normalized words (11.5% WER). This is one file-format check, not a separate broad accuracy benchmark. Local natural-pause statistics use finalized precise word times, ignore estimated spans, and reset boundaries across explicit prompting pauses/recovery; forecasts already include those gaps through observed rate, so pause duration is not added twice.
