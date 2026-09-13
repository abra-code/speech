# Nemotron 3.5 ASR streaming

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

NVIDIA's Nemotron 3.5 ASR Streaming Multilingual 0.6B, covering 32 region-qualified locales. It is here for live mode, not for files.

## What it measured

Full FLEURS test splits, 2026-09-04 and 2026-09-05.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.nemotron-3.5-asr-streaming-0.6b@q8_0` | 10.36 | 17.75 | 10.29 | 50-55x | 1.03-1.05 GB |
| `fluid.nemotron-multilingual@2240` | 10.58 | 17.24 | 10.28 | 67-73x | 0.65 GB |
| `fluid.nemotron-multilingual@1120` | 10.63 | 17.39 | 10.37 | 58-76x | 0.65 GB |
| `fluid.nemotron-multilingual@560` | not measured | | | | |

**It lost to Apple in all three languages on batch files**, on both runtimes and at every chunk tier, so on a recording there is no reason to reach for it.

## Why it is still here

Streaming. This is a model designed to emit text while the audio is still arriving, and none of the rows that beat it on batch files can do that. The CoreML rows differ only in chunk size - 0.56, 1.12 and 2.24 seconds - which is a latency-against-accuracy dial that means nothing on a file and everything on a microphone.

Live mode arrives in stage 4, and it will bring its own measurements. Until then this family has a reason to exist and no evidence for it, and no engine in the current build reports `live` at all.

`fluid.nemotron-multilingual@560` has never been downloaded here, so its size is unknown. The chunk tiers are separate downloads of about 664 MB each, not one download with a setting.

## Language tags

Nemotron publishes region-qualified tags and is strict about them: it accepts `pl-PL` and rejects `pl`, which is the opposite of Canary, Qwen3-ASR and Whisper. The engine looks the request up in the loaded model's own list and hands back the model's own spelling, so either form works from the command line - that difference is the reason it has to.

It does identify its own language, which the plan had assumed it could not.
