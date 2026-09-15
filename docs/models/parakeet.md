# Parakeet v3

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Parakeet TDT 0.6B v3, covering 25 European languages. At least 15 percent fewer errors than Apple's engine in all three languages tested, at over 100 times real time, which makes it a good choice for long recordings.

## Measurements

Full FLEURS test sets, 2026-09-04 to 2026-09-07. Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-tdt-0.6b-v3@q8_0` | 5.42 | 7.36 | 5.21 | 106-118x | 0.98-1.00 GB |
| `fluid.parakeet-v3@int8` | 5.89 | 7.77 | 5.57 | 121-151x | 0.56-0.58 GB |
| `mlx.parakeet-tdt-0.6b-v3` | 5.38 | 7.38 | 5.18 | 98-113x | 3.93 GB |
| `ggml.parakeet-tdt-0.6b-v3@q4_k_m` | not measured | | | | |
| `fluid.parakeet-v3@int4` | 9.29 | 16.47 | 10.20 | 120-148x | 0.41-0.45 GB |

## The same model on three engines

The three builds share the same weights and were measured on the same recordings with the same scoring.

- **ggml** is a few tenths of a point more accurate than Core ML in all three languages.
- **Core ML** (`fluid.parakeet-v3@int8`) is up to 1.5 times faster, uses about 400 MB less memory, and is the only build that accepts a custom vocabulary.
- **MLX** scores within a few hundredths of the ggml build (5.38 / 7.38 / 5.18 against 5.42 / 7.36 / 5.21), which shows these scores belong to the model, not to one engine. It uses about four times the memory of the ggml build.

**`fluid.parakeet-v3@int4` is not worth the savings.** It saves about 145 MB and costs 3 to 9 WER points, which puts it behind Apple in all three languages.

## Limits

- **No language detection on the Core ML build**; the ggml build has it.
- **Custom vocabulary works on the Core ML build only**, through the small helper model `fluid.parakeet-ctc-110m`.
- **The builds list different languages.** The GGUF file lists 25, the Core ML package 28. The loaded model has the final say.
