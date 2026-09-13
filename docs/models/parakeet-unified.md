# Parakeet Unified (English)

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

NVIDIA's Parakeet Unified 0.6B, English only. The most accurate English row in this battery that stayed under a gigabyte of memory, and the fastest row measured.

## What it measured

Full FLEURS `en_us`, 2026-09-04 and 2026-09-05.

| row | en | speed | memory |
| --- | --- | --- | --- |
| `fluid.parakeet-unified@int8` | 4.90 | 159x | 0.70 GB |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 4.92 | 102x | 0.91 GB |
| `fluid.parakeet-unified@fp16` | 4.90 | 160x | 1.28 GB |

The two CoreML precisions tie on accuracy to two decimal places and differ by three tenths of a percent on speed, which is inside run-to-run variation. fp16 costs 578 MB more for that, so fp16 is worth having for comparison rather than for use.

The ggml build matches the CoreML build's accuracy to two decimal places at about two thirds of its speed, which is a cleaner runtime comparison than any other family offers - and the same answer Parakeet v3 gives.

## When to pick it

English work where speed matters. For English accuracy alone `ggml.qwen3-asr-1.7b@q8_0` is more than a point better, at about a tenth of the speed and five times the memory.

## What it cannot do

- **English only.** No other language, no language hint - the model takes none at all.
- Custom vocabulary works on the CoreML rows through the CTC spotter, not on the ggml row.
