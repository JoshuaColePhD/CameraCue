# Voice Follow evaluation

## What this measures

This is an **alignment replay**, using real published speech transcripts and deterministic simulated recognizer callbacks. It does not measure actual speech recognition error rates, microphone latency, accents, room noise or end-to-end screen latency. The demo GIF is also a transcript replay, not a live microphone recording.

Corpus `speech-replay-v1` contains Lincoln's Gettysburg Address and Kennedy's Rice University address for development, with a different Kennedy speech to Congress held out. Six fixed seeds per speech produce eight profiles: clean speech, recognition errors, revised partials, recognizer resets, duplicate callbacks/silence, ad-libs, a forward skip and a backward restart. This is 144 cases and 13,638 scored callbacks per algorithm. Sources, excerpt boundaries and normalization edits are in [fixture provenance](../Sources/VoiceFollowEvaluation/Fixtures/PROVENANCE.md).

The error profile samples 8% deletions, 8% substitutions and 7% filler insertions per source token. Rates are fixture generation probabilities, not an observed WER. Speech timing is modeled at 125–175 normalized tokens/minute, callbacks every three tokens, with 250–550 ms delivery delay. Revised partials include an extra wrong final word before the corrected result. The intervention profiles are stress tests rather than a claim about typical user behavior.

Development speeches and seeds were used for tuning. The Congress transcript and its distinct seeds were run after the algorithm was frozen. The corpus is small, public and inspectable; the held-out result is not independent external validation.

## Results

Measured on an Apple Silicon Mac, release optimization, October 5, 2026. Accuracy and error pool callbacks; recovery p95 pools successful interventions. Lag is the **largest per-case p95 modeled highlight age**, not actual recognition or rendering latency.

| Split | Algorithm | Within 2 tokens | Mean absolute error (tokens) | Wrong moves / jumps | Recovered | Recovery p95 | Worst case lag p95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| development | Exact suffix baseline | 91.23% | 0.48 | 5 / 1 | 24/24 | 2.60 s | 6.35 s |
| development | Previous CameraCue | 93.64% | 5.33 | 15 / 12 | 12/24 | 5.21 s | 2.18 s |
| development | CameraCue | 99.14% | 0.29 | 3 / 0 | 24/24 | 4.02 s | 2.17 s |
| held-out | Exact suffix baseline | 89.25% | 0.61 | 2 / 1 | 12/12 | 2.87 s | 5.01 s |
| held-out | Previous CameraCue | 92.63% | 10.69 | 0 / 0 | 6/12 | 5.40 s | 89.13 s |
| held-out | CameraCue | 99.44% | 0.19 | 0 / 0 | 12/12 | 4.12 s | 1.51 s |

All three algorithms had zero movement during designated silence/duplicate/ad-lib hold events. The current tracker still made three erroneous moves in the development recognition-error profile; those moves were smaller than the jump threshold. It had no erroneous moves in the held-out split. No automatic tracker is guaranteed to stay correct through arbitrary improvisation or repeated phrases.

- **Position accuracy:** a scored callback is correct when the tracked normalized token is within two of the annotated endpoint. Mean absolute error includes stalled and incorrect positions.
- **Wrong move:** position changes and ends more than five tokens from truth. A **wrong jump** additionally moves more than eight tokens. Holding at the wrong position is captured by accuracy/error, not counted as a jump.
- **Recovery:** after the skip/restart's first delivered callback, two consecutive non-low-confidence matches must be within two tokens. Failure is reported separately, never assigned a successful recovery time. This includes waiting for more transcript context.
- **Highlight age:** modeled callback delivery time minus the last spoken time of the tracked token. Positions never spoken before that callback have no meaningful age and are excluded from this statistic. JSON records `lagSamples` and `unavailableLagSamples`; accuracy/error still count those positions. Long stalls can therefore matter even when the conditional lag statistic looks small.
- **Compute latency:** JSON includes each case's p95 aligner execution time. This excludes ASR, UI rendering and scrolling. It is informational because machines differ.

The exact three-word suffix baseline is fast and recovers quickly, but fails more often with corrupted speech. The frozen previous implementation comes from commit `54c3d25`. The revised tracker separates raw match quality from proximity ranking, requires more context for sizeable moves, ignores duplicate partials when accumulating misses, and allows strong backward restarts. Development tuning reduced wrong jumps while preserving conservative holds. The result favors safer alignment over the baseline's quicker recovery.

## Reproduce and gate

```sh
./scripts/evaluate-voice-follow.sh --check --output /tmp/voice-follow-results.json
```

[Development results](evaluation/development.json) and [held-out results](evaluation/held-out.json) are frozen references. [Initial development replay](evaluation/before-development.json) preserves the pre-tuning measurement. Each case includes the speech, profile and seed; corpus hashes identify exactly what was replayed.

CI fails on any per-case deterioration in position accuracy, mean error, erroneous movement, hold behavior, previously successful recovery time, modeled lag or unavailable lag samples. It also rejects changed fixtures/hashes. Timing tolerances accommodate floating-point rounding, not performance regressions. Legitimate algorithm changes need a reviewed explanation and reference update; do not silently regenerate references to make CI green. CI output is written elsewhere so it cannot overwrite the reference files.

## Next hardware evaluation

A genuine end-to-end evaluation remains outstanding. Record consented speech while retaining timestamped partial callbacks and manually labeled word times; include different voices, accents, speeds, pauses, repeated passages, room noise and improvisation. Compare human labels to the displayed highlight, measure recognizer delay separately from alignment and scroll delay, and report false jumps and time-to-recovery across speakers. Run on-device and supported service-backed configurations separately. Neither public transcripts nor a synthetic voice substitute for those checks.
