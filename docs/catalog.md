# The model inventory

`speech catalog` lists every way this build can run speech recognition: each row's model family, where its weights come from, how big they are, what the loaded model says it can do, and whether it is installed.

It is an inventory, not a recommendation. This tool does not rank the rows or score them.

## Why the ranking is not here

The tool is the right level to report what is available. It has to know all of it anyway - the engines insist on owning their own downloads and model directories, so `speech` is the only thing that knows a row's repository, its file name, its size on disk, and what the loaded model actually claims about itself.

Choosing between the rows is a different job. It depends on the language, on the recording, on how much memory the machine has, on how patient the user is, and on measurements that are only valid for one machine, one macOS version and one set of dependency versions. Scores taken on the developer's Mac in September 2026 are a starting reference point, not the truth on somebody else's laptop a year later.

So that decision belongs to Speech.app, which can re-run the measurements on the machine it is running on and against recordings the user actually cares about. See the app's development plan for the benchmarking surface. This tool provides the raw material for it: the inventory below, and `speech eval`, which is what produces a score in the first place.

The order of the rows is computed rather than chosen - families alphabetically, then by engine, then largest build first - precisely so that nobody reads a ranking into it. A unit test keeps it that way.

## Where the inventory lives

The inventory is Swift, in `Sources/SpeechCore/Catalog.swift`, and `docs/models.catalog.tsv` is a generated export of it.

That is the opposite of what the development plan's step 3.1 proposed - a TSV bundled as a SwiftPM resource and parsed at startup - and the reason is the shape of this program's deliverable. `build/speech` is contractually a single ad-hoc-signed binary that other repositories copy on its own; a resource bundle is a second artifact that has to travel with it, which is exactly the mistake that made every stage 2 build die at launch until `build.sh` learned to carry `CTranscribe.framework` along. `Bundle.module` is worse than a missing dylib: it traps rather than returning nil, and because it is a lazy `static let` it traps on first use rather than at launch, so a copied binary would abort partway through a session.

Generating the file rather than reading it keeps one source of truth and still gives a script a file to read:

- `speech catalog --tsv` writes it.
- `docs/models.catalog.tsv` is the checked-in copy. Speech.app copies it into its own Resources so a script can read family names and ids without launching the binary.
- `test.sh` regenerates it and compares the data lines, so it cannot drift.

The file opens with a `# Produced by:` block naming the tool version, the Mac, the macOS version and the version of every engine that answered - FluidAudio and transcribe.cpp, with Apple's engines being the OS itself. That block matters more than it looks: `languages`, `modes`, `caps` and `min_macos` are not properties of a model, they are what a particular engine version reported on a particular OS, and stage 2 found four cases where that differed from the published claim. `size_bytes` is one revision of one repository, and these repositories are requantized in place. Without the block a table from two builds reads as a table of contradictions.

It also means the block changes whenever somebody on another machine regenerates the file, which is why `test.sh` compares the data lines and not the comments.
- The unit tests parse the checked-in copy and compare it against the Swift table, and separately round-trip the whole inventory through the codec under Unix, Windows and classic Mac line endings.

To refresh it after editing the inventory:

```sh
./build.sh && build/speech catalog --tsv > docs/models.catalog.tsv
```

## What a row is, and what it is not

A row carries what the tool is authoritative about: the id, the model family, whether it transcribes or is a helper, the repository and file its weights come from, the parameter count, the precision, the download size, and a plain display name.

It deliberately does **not** carry languages, capability flags or the macOS floor. Those are the engine's own answers, read out of a GGUF or a CoreML bundle when the model loads and reported through `EngineCapabilities`. Stage 2 measured four capability facts that the published model cards had wrong - Canary reports no timestamps at all and caps a run at 400 seconds, Nemotron does identify its own language, Qwen3-ASR caps a run at about 87 minutes, and Parakeet v3 reports 25 languages where the CoreML build advertises 28 - so a second copy of those facts in a static table is a copy that will eventually lie. The exported file has the columns because a script reading the file needs them; they are filled in at export time by asking the engines, which is why only a real binary can write the file.

The label is descriptive and never evaluative: it says which build a row is, not whether it is any good. A test enforces that too.

The two halves are joined in `Sources/speech/Verbs/CatalogVerb.swift`, the one place where SpeechCore, SpeechApple, SpeechFluid and SpeechGGML are all visible. That join checks three things and refuses to write the file if any fails: a catalog row with no engine is a row nobody can run, an engine with no catalog row is a model that never gets reported, and a row whose repository or file name disagrees with the engine that would fetch it is a 404 halfway through a progress bar. The third check covers both `ggml` and `fluid` rows, each against its own engine's answer. The listing degrades with a warning instead, because one bad row must not cost a caller the other twenty-three.

## File format

Tab-separated, `#` comments, no header row, one row per line, ending with a single newline. `-` is a field with no value and `*` is a row that accepts any language.

The writer refuses rather than escaping, because every field is a string literal in this repository and anything that would need escaping is a mistake worth stopping for. It rejects an empty field, a tab or newline in one, an id beginning with `#` (the parser would skip the line as a comment and the row would vanish), a real `source` or `file` spelled exactly like a placeholder, a list element that is empty or contains a comma, and a number written as `+42` or `007`. Each of those is a value the parser could not hand back unchanged.

The parser normalizes CRLF and CR before splitting. Swift makes `\r\n` a single `Character`, so splitting on `\n` alone matches nothing in a Windows-encoded file: the whole file arrives as one line, that line starts with `#`, and the result is zero rows and no error. It also strips a leading byte order mark, and runs every id it reads through `EngineSpec.parse`, which is the gate that refuses a path traversal - this file is the first place in the program where a catalog id can arrive from something other than argv.

| column | meaning |
| --- | --- |
| `id` | `<engine>.<model>[@<variant>]`, the catalog id used everywhere else in the tool |
| `family` | `apple`, `canary`, `nemotron`, `parakeet`, `parakeet-unified`, `qwen3-asr`, `whisper` |
| `engine` | `apple`, `fluid` or `ggml`; redundant with the id's prefix, written so a script can grep one column, and checked against the id on parse |
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
