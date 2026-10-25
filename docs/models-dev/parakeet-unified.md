# Parakeet Unified (English)

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Parakeet Unified 0.6B, English only. One of the fastest models measured, and the most accurate English model that uses under 1 GB of memory.

## Measurements

Full FLEURS English (`en_us`), 2026-10-21 to 2026-10-23, speech 0.2 (FluidAudio 0.17.7, transcribe.cpp 0.4.1). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | speed | memory |
| --- | --- | --- | --- |
| `fluid.parakeet-unified@int8` | 4.90 | 163x | 0.70 GB |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 4.92 | 104x | 0.94 GB |
| `fluid.parakeet-unified@fp16` | 4.90 | 166x | 1.29 GB |

The two Core ML precisions give the same accuracy and speed; fp16 only uses 583 MB more memory. The ggml build matches that accuracy at about two thirds of the speed, the same result as Parakeet v3.

## When to choose it

English where speed matters. For the best English accuracy, `ggml.qwen3-asr-1.7b@q8_0` is more than a point better, at about a tenth of the speed and nearly four times the memory.

## Limits

- **English only**, and it takes no language setting.
- **Custom vocabulary works on the Core ML builds only**, through the small helper model `fluid.parakeet-ctc-110m`.
