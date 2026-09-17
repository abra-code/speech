# The model inventory

`speech catalog` lists every way this build can run speech recognition: each row's model family, where its weights come from, how big they are, what the loaded model says it can do, and whether it is installed.

It is an inventory, not a recommendation. This tool does not rank the rows or score them.

## Why the ranking is not here

The tool is the right level to report what is available. It has to know all of it anyway - the engines insist on owning their own downloads and model directories, so `speech` is the only thing that knows a row's repository, its file name, its size on disk, and what the loaded model actually claims about itself.

Choosing between the rows is a different job. It depends on the language, on the recording, on how much memory the machine has, on how patient the user is, and on measurements that are only valid for one machine, one macOS version and one set of dependency versions. Scores taken on the developer's Mac in September 2026 are a starting reference point, not the truth on somebody else's laptop a year later.

So that decision belongs to Speech.app, which can re-run the measurements on the machine it is running on and against recordings the user actually cares about. See the app's development plan for the benchmarking surface. This tool provides the raw material for it: the inventory below, and `speech eval`, which is what produces a score in the first place.

The order of the rows is computed rather than chosen - families alphabetically, then by engine, then largest build first - precisely so that nobody reads a ranking into it. A unit test keeps it that way.

## Where the inventory lives

The inventory is data: JSON documents, one per engine, in the repository's `catalog/` directory. `build.sh` installs them beside the binary as `build/speech-catalog/`, the same way `CTranscribe.framework` and `speech-mlx` travel with it, and `speech` reads them at startup. A user's own documents add to them or override them - see [Catalog documents](#catalog-documents) below.

They are not a SwiftPM resource. `Bundle.module` traps rather than returning nil when its bundle is missing, and because it is a lazy `static let` it traps on first use rather than at launch. `speech` finds `speech-catalog/` the way it finds `speech-mlx`: beside the resolved binary, or wherever `SPEECH_BUILTIN_CATALOG_DIR` points. A debug build (`swift run`, `swift test`) also falls back to the repository's own `catalog/`; a release build does not, so a package shipped without its catalog fails on the developer's machine too. Without a built-in catalog every verb stops at startup and says where it looked.

`docs/models.catalog.tsv` is a generated export of the merged inventory joined with what each engine reports, which keeps one source of truth and still gives a script a file to read:

- `speech catalog --tsv` writes it.
- `docs/models.catalog.tsv` is the checked-in copy. Speech.app copies it into its own Resources so a script can read family names and ids without launching the binary.
- `test.sh` regenerates it and compares the data lines, so it cannot drift. It points `SPEECH_CATALOG_DIR` at an empty directory first, so a developer's own entries never end up in the checked-in file.

The file opens with a `# Produced by:` block naming the tool version, the Mac, the macOS version and the version of every engine that answered - FluidAudio and transcribe.cpp, with Apple's engines being the OS itself. That block matters more than it looks: `languages`, `modes`, `caps` and `min_macos` are not properties of a model, they are what a particular engine version reported on a particular OS, and stage 2 found four cases where that differed from the published claim. `size_bytes` is one revision of one repository, and these repositories are requantized in place. Without the block a table from two builds reads as a table of contradictions.

It also means the block changes whenever somebody on another machine regenerates the file, which is why `test.sh` compares the data lines and not the comments.
- The unit tests parse the checked-in copy and compare it against the built-in catalog, and separately round-trip the whole inventory through the codec under Unix, Windows and classic Mac line endings.

To refresh it after editing `catalog/`:

```sh
./build.sh && SPEECH_CATALOG_DIR=/nonexistent build/speech catalog --tsv > docs/models.catalog.tsv
```

## Catalog documents

A document is one JSON object:

```json
{
  "schema": 1,
  "note": "free text for the reader; never interpreted",
  "models": [
    {
      "engine": "ggml",
      "model": "canary-1b-v2",
      "family": "canary",
      "source": "handy-computer/canary-1b-v2-gguf",
      "params_m": 1000,
      "languages": ["bg", "hr", "cs"],
      "language_id": false,
      "variants": [
        { "variant": "q8_0", "file": "canary-1b-v2-Q8_0.gguf", "precision": "q8_0",
          "size_bytes": 1144290016, "label": "Canary 1B v2 (Q8_0)" }
      ]
    }
  ]
}
```

Each entry is one model of one engine, with its variants beneath it. A variant's id is `<engine>.<model>@<variant>`; an entry with no `variants` is one row whose id has no `@`. A variant inherits every field it does not set, so `source`, `precision`, `params_m`, `size_bytes` and `label` may sit on either level.

| field | level | meaning |
| --- | --- | --- |
| `engine`, `model`, `family` | model | required; lowercase letters, digits, `.`, `_`, `-`. `family` is any such name - a user-added model brings its own |
| `role` | model | `transcriber` (the default) or `helper` |
| `hidden` | both | `true` unlists the model or variant from `catalog` and `engines`; an id typed in full still builds and runs |
| `note` | both | free text, never interpreted - where the reasons behind a number live |
| `source` | both | the Hugging Face repository |
| `file` | both | `ggml`: the GGUF file inside `source`, required per variant |
| `params_m`, `precision`, `size_bytes`, `label` | both | as in the file format below; `precision` and `label` are required, one level or the other |
| `languages`, `language_id`, `streaming`, `word_timestamps`, `segment_timestamps` | model | `ggml` and `mlx`: what the catalog shows before a download. Advisory - the loaded model's own answers gate. A flag left out is false |
| `type` | model | `mlx`: the helper's architecture name, required |
| `files` | model | `mlx`: files to fetch from the variant's `source`, required |
| `files_from` | model | `mlx`: `{"other/repo": ["file", ...]}`, files from other repositories |
| `chunk_seconds`, `max_seconds` | model | `mlx`: passed to the helper; the longest buffer per request |
| `stream` | model | `ggml`: how the streaming decoder is driven - `{"kind": "parakeet_stream", "att_context_right": 0}`, `{"kind": "parakeet_buffered", "left_ms": ..., "chunk_ms": ..., "right_ms": ...}`, `{"kind": "voxtral_realtime", "num_delay_tokens": ..., "min_decode_interval_ms": ...}` or `{"kind": "none"}`. Each kind takes only its own settings. A kind the loaded model does not accept is refused when a live session starts, rather than quietly streamed with the library's defaults. Without it the engine picks the first extension the model accepts |

Decoding is strict, because these files are edited by hand: an unknown field is an error, since a misspelled `"langauges"` silently ignored would be a model that claims every language. A bad entry is dropped with a warning naming its file, and the rest load; a file that is not JSON, or whose `schema` is not 1, is skipped whole with a warning. A field added by a later build does not change the schema: an older build reports it as unknown and drops only that entry. The built-in documents travel with their binary, so this only affects a user's own file shared across builds.

`fluid` and `apple` entries only describe: which of their models exist is fixed by the engine (FluidAudio names its own repositories), and `speech catalog` reports an entry its engine cannot build. `ggml` and `mlx` entries are the models: a new entry with a repository and file names is a new row, with no code change.

### A user's own documents

`speech` then reads every `*.json` in `$SPEECH_CATALOG_DIR`, by default `~/Library/Application Support/Speech/Catalog`, in name order. An entry with the same `engine` and `model` as a built-in one replaces it whole, in its place; a new one is appended. So a user can hide a built-in model, correct one, or add another quantization by copying the entry from `speech-catalog/` and editing it. When two user files define the same model, the later name wins and a warning says so. Problems in user files are warnings on every run until they are fixed; they never stop a run.

`speech --json catalog` reports both directories under `catalog`, so a caller can find the file to edit.

### Adding a transcribe.cpp model

transcribe.cpp loads any GGUF whose architecture it knows, from the file alone, and reports the model's own languages, language identification, streaming support and timestamp granularity. So a model nobody wrote an entry for does not need one written by hand:

```sh
speech models add handy-computer/granite-speech-4.1-2b-gguf              # its Q8_0
speech models add handy-computer/granite-speech-4.1-2b-gguf --quant q4_k_m
speech models add someone/some-model-gguf --file model.gguf --quant f16 --model some-model
```

It lists the repository's `.gguf` files and takes the one `--file` names, else the one `--quant` names, else the only one or the Q8_0 - and asks, listing what there is, rather than guessing between several. The id is `ggml.<model>@<quant>`, with the model name taken from the file name without its quantization unless `--model` says otherwise. It downloads the file into the model store exactly as `models download` would, loads it, and writes an entry recording what the loaded model said, with the family taken from the GGUF's architecture and a `note` saying where the entry came from. A file transcribe.cpp cannot load - an architecture it does not know, a language model rather than a speech model - is refused with the library's reason, and the download is removed; nothing is written.

The entry goes to `<model>.json` in the user catalog directory, one file per model, which this command owns and rewrites. Adding another quantization of a model already in the catalog adds a variant to that entry; for a built-in model that means copying the built-in entry into the user file, which from then on replaces it. A model defined in a user file the command did not write is left alone, with a message saying to add the variant there by hand.

Only Hugging Face repositories for now. A local GGUF would need a catalog field for a path, which a later build can add without a schema change.

## What a row is, and what it is not

A row carries what the tool is authoritative about: the id, the model family, whether it transcribes or is a helper, the repository and file its weights come from, the parameter count, the precision, the download size, and a plain display name.

It deliberately does **not** carry languages, capability flags or the macOS floor. Those are the engine's own answers, read out of a GGUF or a CoreML bundle when the model loads and reported through `EngineCapabilities`. Stage 2 measured four capability facts that the published model cards had wrong - Canary reports no timestamps at all and declares a 400-second run, Nemotron does identify its own language, Qwen3-ASR declares runs of about 87 minutes (neither is a length a run survives; see docs/engines.md), and Parakeet v3 reports 25 languages where the CoreML build advertises 28 - so a second copy of those facts in a static table is a copy that will eventually lie. The exported file has the columns because a script reading the file needs them; they are filled in at export time by asking the engines, which is why only a real binary can write the file.

The label is descriptive and never evaluative: it says which build a row is, not whether it is any good. A test enforces that too.

The two halves are joined in `Sources/speech/Verbs/CatalogVerb.swift`, the one place where SpeechCore, SpeechApple, SpeechFluid and SpeechGGML are all visible. That join checks three things and refuses to write the file if any fails: a catalog row with no engine is a row nobody can run, an engine with no catalog row is a model that never gets reported, and a row whose repository or file name disagrees with the engine that would fetch it is a 404 halfway through a progress bar. The third check covers both `ggml` and `fluid` rows, each against its own engine's answer. The listing degrades with a warning instead, because one bad row must not cost a caller the other thirty-two.

A row is retired from the listing with `"hidden": true` rather than by deleting it. `fluid.canary-1b-v2@int4` is unlisted that way - the measurements are in its `note` in `catalog/fluid.json` - and the engine still builds it, so the id works when it is typed in full. Hidden ids are left out of both sides of the join, so neither check reports them.

## File format

Tab-separated, `#` comments, no header row, one row per line, ending with a single newline. `-` is a field with no value and `*` is a row that accepts any language.

The writer refuses rather than escaping, because every field is a string literal in this repository and anything that would need escaping is a mistake worth stopping for. It rejects an empty field, a tab or newline in one, an id beginning with `#` (the parser would skip the line as a comment and the row would vanish), a real `source` or `file` spelled exactly like a placeholder, a list element that is empty or contains a comma, and a number written as `+42` or `007`. Each of those is a value the parser could not hand back unchanged.

The parser normalizes CRLF and CR before splitting. Swift makes `\r\n` a single `Character`, so splitting on `\n` alone matches nothing in a Windows-encoded file: the whole file arrives as one line, that line starts with `#`, and the result is zero rows and no error. It also strips a leading byte order mark, and runs every id it reads through `EngineSpec.parse`, which is the gate that refuses a path traversal - this file is the first place in the program where a catalog id can arrive from something other than argv.

| column | meaning |
| --- | --- |
| `id` | `<engine>.<model>[@<variant>]`, the catalog id used everywhere else in the tool |
| `family` | the built-in catalog uses `apple`, `canary`, `nemotron`, `parakeet`, `parakeet-unified`, `qwen3-asr`, `silero`, `whisper`; a user-added model may bring any lowercase name |
| `engine` | `apple`, `fluid`, `ggml` or `mlx`; redundant with the id's prefix, written so a script can grep one column, and checked against the id on parse |
| `role` | `transcriber` or `helper` |
| `source` | Hugging Face repository the weights come from, `-` for the Apple rows |
| `file` | the single GGUF file inside `source`, `ggml` rows only |
| `params_m` | parameters in millions |
| `precision` | `int8`, `int4`, `fp16`, `q8_0`, `q4_k_m`, or `system` for a row the OS ships |
| `languages` | the language tags the loaded model claims, **spelled the model's way**, or `*` for any. Usually primary subtags, but not always: both `ggml.nemotron-3.5-asr-streaming-0.6b` rows publish region-qualified tags (`pl-PL`, `en-US`) and reject bare ones, so match on the primary subtag rather than on the whole string. `*` means the engine reports no list at all rather than that every language works - the three `fluid.nemotron-multilingual` rows carry it because their real list lives in a `metadata.json` inside the download |
| `modes` | `batch`, `live`, or both; `-` for a row that is neither, like the CTC spotter |
| `caps` | any of `word_ts`, `seg_ts`, `vocab`, `diarize`, `lang_id`, `lang_hint`; `-` when the row reports none |
| `min_macos` | the OS floor the engine reports for this row |
| `size_bytes` | nominal download size |
| `label` | display name |

Two of these differ from appendix C of the development plan. `role` is new: `fluid.parakeet-ctc-110m` is downloaded and managed like a model but only spots custom-vocabulary terms for the Parakeet rows, so "is not something to transcribe with" had to become data. And there is no `blurb` column - a one-sentence pitch for a model is editorial, and editorial belongs with whatever presents the choice.

### Sizes

`size_bytes` is the number of bytes this tool actually fetches, not the size of the repository.

For a `ggml` row that is one GGUF and the two agree. For a `fluid` row they do not, and the gap is large: the Nemotron CoreML repository holds about 1.27 GB per chunk tier, of which this tool downloads about 664 MB, because the rest is precisions and bundles the loader never opens. Where a row has been installed here the figure is measured from the files on disk; for the five `ggml` quantizations that have not, it is the `lfs.size` the Hugging Face tree API reports for that GGUF.

`size_bytes` may also be `-`. An uninstalled `fluid` row has no size that can be derived from the repository listing, because what gets downloaded is a subset chosen by the loader. One row is in that state today, `fluid.nemotron-multilingual@560`.

## JSON

`speech catalog --json` adds what only the running machine can answer: install state, bytes on disk, whether each engine can run here and why not, plus the chip, physical memory and macOS version.

```json
{
  "machine": {"chip": "Apple M5", "memory_bytes": 25769803776, "macos": "26.6.2"},
  "models_dir": "/Users/.../Application Support/speech/models",
  "catalog": {"builtin": ".../build/speech-catalog", "user": "/Users/.../Application Support/Speech/Catalog", "user_exists": false},
  "rows": [
    {
      "id": "ggml.canary-1b-v2@q8_0",
      "family": "canary",
      "engine": "ggml",
      "role": "transcriber",
      "label": "Canary 1B v2 (Q8_0)",
      "source": "handy-computer/canary-1b-v2-gguf",
      "file": "canary-1b-v2-Q8_0.gguf",
      "params_m": 1000,
      "precision": "q8_0",
      "size_bytes": 1144290016,
      "state": "installed",
      "installed": true,
      "installed_bytes": 1144290016,
      "available": true,
      "capabilities": ["lang_hint"],
      "modes": ["batch"],
      "languages": ["bg", "hr", "cs", "..."],
      "minimum_macos": "15.0"
    }
  ]
}
```

A key with no value is absent rather than null.
