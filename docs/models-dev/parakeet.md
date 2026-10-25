# Parakeet v3

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Parakeet TDT 0.6B v3, covering 25 European languages. At least 15 percent fewer errors than Apple's engine in all three languages tested, at 90 to 180 times real time, which makes it a good choice for long recordings.

## Measurements

Full FLEURS test sets, 2026-10-21 to 2026-10-25, speech 0.2 (FluidAudio 0.17.7, transcribe.cpp 0.4.1, mlx-audio-swift 0.1.6). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-tdt-0.6b-v3@q8_0` | 5.42 | 7.38 | 5.15 | 89-98x | 0.99-1.01 GB |
| `fluid.parakeet-v3@int8` | 5.95 | 7.75 | 5.56 | 156-178x | 0.56-0.58 GB |
| `mlx.parakeet-tdt-0.6b-v3` | 5.43 | 7.45 | 5.13 | 144-168x | 3.93-3.94 GB |
| `ggml.parakeet-tdt-0.6b-v3@q4_k_m` | 5.52 | 7.58 | 5.14 | 85-98x | 0.74-0.76 GB |
| `fluid.parakeet-v3@int4` | 9.27 | 16.46 | 9.99 | 153-171x | 0.42-0.43 GB |

## The same model on three engines

The three builds share the same weights and were measured on the same recordings with the same scoring.

- **ggml** is a few tenths of a point more accurate than Core ML in all three languages.
- **Core ML** (`fluid.parakeet-v3@int8`) is about 1.8 times faster, uses about 430 MB less memory, and is the only build that accepts a custom vocabulary.
- **MLX** scores within a tenth of a point of the ggml build (5.43 / 7.45 / 5.13 against 5.42 / 7.38 / 5.15), which shows these scores belong to the model, not to one engine. It is about 1.6 times faster than the ggml build and uses about four times its memory.

**`fluid.parakeet-v3@int4` is not worth the savings.** It saves about 145 MB and costs 3 to 9 WER points, which puts it behind Apple in all three languages.

## Limits

- **No language detection on the Core ML build**; the ggml build has it.
- **Custom vocabulary works on the Core ML build only**, through the small helper model `fluid.parakeet-ctc-110m`.
- **The builds list different languages.** The GGUF file lists 25, the Core ML package 28. The loaded model has the final say.
- **The ggml and MLX builds transcribe long recordings in 30-second pieces**, cut at quiet points. Given 20 minutes at once the ggml build needs more memory than a 24 GB Mac has, and even under that limit long pieces drop whole sentences: on 5-minute recordings, 30-second pieces scored 6.7% WER in English and 8.8% in Polish, against 47.5% and 10.1% for the whole 5 minutes (2026-10-22). The MLX build ran the same corpora in September and came out the same way, 8.9% and 9.1% at 30 seconds against 37.6% and 12.9% at the two minutes it used until 2026-09-17; the small `mlx.parakeet-tdt_ctc-110m` loses more in a long piece and gets 15 seconds. 30 seconds was also the fastest length on both builds (docs/engines.md). The Core ML build feeds the model its own way and is not affected.
