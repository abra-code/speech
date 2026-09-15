# Parakeet Unified (English)

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Parakeet Unified 0.6B, English only. The fastest model measured, and the most accurate English model that uses under 1 GB of memory.

## Measurements

Full FLEURS English (`en_us`), 2026-09-04 and 2026-09-05. Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | speed | memory |
| --- | --- | --- | --- |
| `fluid.parakeet-unified@int8` | 4.90 | 159x | 0.70 GB |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 4.92 | 102x | 0.91 GB |
| `fluid.parakeet-unified@fp16` | 4.90 | 160x | 1.28 GB |

The two Core ML precisions give the same accuracy and speed; fp16 only uses 578 MB more memory. The ggml build matches that accuracy at about two thirds of the speed, the same result as Parakeet v3.

## When to choose it

English where speed matters. For the best English accuracy, `ggml.qwen3-asr-1.7b@q8_0` is more than a point better, at about a tenth of the speed and five times the memory.

## Limits

- **English only**, and it takes no language setting.
- **Custom vocabulary works on the Core ML builds only**, through the small helper model `fluid.parakeet-ctc-110m`.
