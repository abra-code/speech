# Nemotron 3.5 ASR streaming

> Measured on an Apple M5 with macOS 26.6.2 and 27.0.1 in September and
> October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Nemotron 3.5 ASR Streaming Multilingual 0.6B, covering 32 locales. It is meant for live transcription, not for files.

## Measurements

Full FLEURS test sets, transcribed as files: the GGUF builds on 2026-10-23 and 2026-10-24 on macOS 27.0.1 (speech 0.2.1, transcribe.cpp 0.4.1), the Core ML builds on 2026-09-04 and 2026-09-05 on macOS 26.6.2. Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.nemotron-3.5-asr-streaming-0.6b@q8_0` | 10.37 | 17.78 | 10.31 | 49-56x | 1.03-1.07 GB |
| `ggml.nemotron-3.5-asr-streaming-0.6b@q4_k_m` | 10.94 | 19.12 | 11.08 | 48-54x | 0.77-0.81 GB |
| `fluid.nemotron-multilingual@2240` | 10.58 | 17.24 | 10.28 | 67-73x | 0.65 GB |
| `fluid.nemotron-multilingual@1120` | 10.63 | 17.39 | 10.37 | 58-76x | 0.65 GB |
| `fluid.nemotron-multilingual@560` | not measured | | | | |

On files it lost to Apple in all three languages, on both engines and at every chunk size, so choose another model for recordings.

## Why use it

It writes text while the audio is still arriving, which the models that beat it on files cannot do. The Core ML builds differ only in chunk size - 0.56, 1.12 and 2.24 seconds. A shorter chunk shows text sooner; a longer one is slightly more accurate. Each chunk size is a separate download of about 664 MB.

## Language tags

Nemotron requires a region: it accepts `pl-PL` and rejects `pl`, the opposite of Canary, Qwen3-ASR and Whisper. `speech` converts a tag to the model's own form, so either works. It detects the spoken language on its own.
