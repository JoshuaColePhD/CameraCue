# Replay corpus v1

These are published speech transcripts, not recordings from CameraCue users. The underlying speeches are public-domain U.S. presidential works (and the 1863 Lincoln text is also outside copyright). The MIT software license, if adopted, does not change their public-domain status.

| File | Source | Split |
| --- | --- | --- |
| gettysburg.txt | [Library of Congress, standard Gettysburg text](https://www.loc.gov/exhibits/gettysburg-address/ext/trans-nicolay-inscribed.html), Abraham Lincoln, 1863 | Development |
| rice.txt | [NASA, Kennedy at Rice University](https://www.nasa.gov/image-article/president-john-f-kennedy-rice-university/), John F. Kennedy, 1962 | Development |
| congress.txt | [NASA, Special Message to Congress, Section IX](https://www.nasa.gov/history/the-decision-to-go-to-the-moon/), John F. Kennedy, 1961 | Held-out speech |

Excerpts are intentionally identified as excerpts. Rice uses the opening sentence and the concluding passage, omitting intervening material. The NASA transcription's “his new sea”/“mountian” errors are corrected to “this new sea”/“mountain”. Numbers are written as spoken words; dashes/hyphens are simplified in Congress. No other words are rewritten. Corpus excerpts and deterministic corruption policies are frozen before evaluating alignment tuning on the held-out speech. Held-out replay is not evidence of unseen accents, microphones or actual Apple recognizer accuracy.

Ground-truth positions refer to normalized script tokens. Timings are **simulated** speaking times and recognizer-delivery delays, not timestamps from audio. A separate audio/manual protocol in the evaluation documentation describes how to collect actual speech-to-highlight measurements.
