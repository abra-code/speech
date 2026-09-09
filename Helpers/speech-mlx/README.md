# speech-mlx

The optional MLX helper. `speech` runs without it; with no `speech-mlx` beside
the binary the `mlx` rows report unavailable with a reason, the same way a
missing engine target already does.

The protocol it speaks is `docs/mlx-helper.md` in the repository root. That file
is the specification for both sides, and `Sources/SpeechMLXProtocol` is compiled
into both binaries rather than copied into either.

## Build

```
./build-speech-mlx.sh          # from the repository root
```

It produces `build/speech-mlx` and the resource bundles that have to sit beside
it, then proves the result completes a handshake before calling itself done.

Two prerequisites, both one-time per machine. The script offers to install the
first for you; XcodeGen you install yourself:

```
xcodebuild -downloadComponent MetalToolchain    # about 688 MB, offered by the script
brew install xcodegen                           # only to regenerate the project
```

Before building anything, the script runs `xcrun metal --version`. The compiler
has to be executed rather than located: Xcode leaves a stub at that path whether
or not the component is installed, so merely finding `metal` proves nothing. When
that fails and the message says the component is what is missing, the script
offers the download - and only then. A compiler stopped by something a download
cannot fix (an unaccepted license, a `DEVELOPER_DIR` pointing at nothing) is
reported with the tool's own message instead, as is Command Line Tools rather
than a full Xcode as the active developer directory, which has no `xcodebuild`
to fetch anything with.

Decline the offer, or run with no terminal to ask on, and it prints the command
and exits non-zero rather than hanging on a question nobody can see. "No
terminal to ask on" means either stream: the question goes to stderr, so
`2> build.log` counts as no terminal even from an interactive shell, and so, on
the safe side, does `2>&1 | tee build.log`. `--download-metal-toolchain` answers
that question with yes in advance, terminal or not - with the one exception
below, where there is no question to answer.

One state it will not guess at, flag or no flag: xcrun answers with Xcode's stub
whether or not the component is installed when it cannot write its lookup cache
and has no entry yet for this developer directory - a sandbox or container with
a read-only per-user temp directory. The script says so and stops, rather than
spending 688 MB on what may already be there.

## Why this is an Xcode project

`swift build` cannot build it. Not "is discouraged" - it links a binary that
dies on its first array operation, because SwiftPM's command line has no rule
for compiling mlx-swift's Metal kernels and so never produces
`mlx-swift_Cmlx.bundle`. Measured here, with a throwaway package that does
nothing but multiply three numbers:

```
MLX error: Failed to load the default metallib. library not found library not
found library not found library not found
  at .../Cmlx/mlx-c/mlx/c/array.cpp:232
exit 255
```

The four repetitions are the four places `load_default_library` looks. The same
program built through this project prints the answer.

### A different failure that looks like this one

An MLX binary with no GPU access - a restrictive sandbox, some CI containers -
dies earlier and much less helpfully:

```
*** Terminating app due to uncaught exception 'NSRangeException', reason:
'*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array'
3   speech-mlx   _ZN3mlx4core5metal6DeviceC2Ev + 156
```

That is `MTLCopyAllDevices()` returning an empty array and `load_device()`
taking element zero of it. It mentions neither Metal nor a missing file, and it
happens to a perfectly good build - so do not read it as a packaging problem.
`test.sh` recognizes it and skips rather than failing.

`project.yml` is the source of truth and `speech-mlx.xcodeproj` is generated
from it with `xcodegen generate`. The generated project is committed, because it
carries the resolved dependency versions, and a measurement that does not record
those is not reproducible. `build-speech-mlx.sh` regenerates it when XcodeGen is
installed - regeneration is idempotent, so an unchanged spec produces a
byte-identical project - which means a spec edit cannot be built against the
previous project by accident. Commit the regenerated project along with the
spec change.

## Memory

MLX never returns a freed buffer to the system. It keeps it in a pool for the
next allocation of that size, and the pool's default limit is the memory limit,
which mlx computes as `min(1.5 * recommended working set, 0.95 * physical
memory)` - about 24 GB on a 24 GB machine. Within one transcription that is the
right trade. Across a long run it is not: over the full FLEURS `en_us` split,
`parakeet-tdt-0.6b-v3` reached a peak footprint of 18.1 GB for a 2.5 GB model,
and `parakeet-tdt_ctc-110m` reached 8.0 GB for 459 MB of weights. None of that
is a leak and all of it is dirty memory that counts against the machine.

So the helper bounds the pool at startup, to
`SpeechMLXHelper.defaultCacheMegabytes` (512 MB), and reports the bound in its
handshake as `cache_mb`. `SPEECH_MLX_CACHE_MB` overrides it, and 0 disables the
pool entirely; sweeping that variable over a fixed slice of a corpus is how the
default was chosen. The bound is on the pool, not on the model: weights and the
working set are allocated whatever it says, so too low a value costs allocation
time rather than correctness.

## Dependency pins

Two direct dependencies, declared in `project.yml` with `exactVersion` rather
than a range. Exact, because a floating minor would change the runtime under a
recorded measurement: the numbers in the SpeechApp repository's `reference/`
are only reproducible if the graph is. The resolved set is committed in
`speech-mlx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
which is the file that actually makes a build reproducible - review it in diffs.

| package | version | why it is in the graph |
| --- | --- | --- |
| `mlx-audio-swift` | 0.1.3 | direct: the eight speech-to-text model implementations the helper exposes |
| `mlx-swift` | 0.31.6 | direct: MLX itself, and the Metal shaders that make `mlx-swift_Cmlx.bundle` |
| `mlx-swift-lm` | 3.31.4 | via mlx-audio-swift: `MLXLMCommon` is imported by six of the eight model types, and the language-model half of Qwen3-ASR and Voxtral is its own |
| `swift-transformers` | 1.3.4 | via mlx-audio-swift: tokenizers for Whisper and Qwen3-ASR |
| `swift-huggingface` | 0.10.0 | via mlx-audio-swift and swift-transformers: the Hub client. The helper never calls it - downloads are the CLI's job - but it links |
| `swift-jinja` | 2.4.2 | via swift-transformers: chat templates |
| `swift-crypto` | 4.5.2 | via swift-transformers and swift-huggingface. On Apple platforms its Crypto product is CryptoKit; the BoringSSL it vendors is compiled only where there is no CryptoKit |
| `swift-asn1` | 1.7.2 | via swift-crypto |
| `swift-collections` | 1.6.0 | via swift-transformers and swift-jinja |
| `swift-numerics` | 1.1.1 | via mlx-swift |
| `swift-argument-parser` | 1.8.2 | via mlx-swift |
| `swift-syntax` | 603.0.2 | via mlx-swift-lm: backs a compiler macro plugin, so it is build-time only |
| `yyjson` | 0.12.0 | via swift-transformers |
| `eventsource` | 1.5.1 | via swift-huggingface |

Fourteen, and that is fewer than the manifests name: `swift-docc-plugin`,
`swift-xet`, `swift-nio` and `async-http-client` appear in dependency manifests
in the graph and do not resolve into it. Read the pins, not the manifests.

## Third-party notices

`build/speech-mlx` statically links most of those fourteen - swift-syntax backs
a compiler macro plugin and is build-time only - and several of them vendor C
and C++ of their own: mlx-swift's `Cmlx` carries Apple's MLX, mlx-c, fmt,
nlohmann/json, metal-cpp and pocketfft. It also redistributes the resource
bundles beside the binary. Every one of those licenses requires its notice to
accompany the binary form.

`build-speech-mlx.sh` writes that notice as
`build/speech-mlx-THIRD-PARTY-NOTICES.txt`, and whatever ships the helper ships
it alongside. It is generated rather than maintained:

```
Helpers/speech-mlx/tools/generate-third-party-notices.sh --bundles build --output <file>
```

The generator reads the resolution the build just used and the SPM checkouts it
left behind, and refuses to run when SPM's own `workspace-state.json` says the
two disagree - so the file cannot label one resolution's licenses with another
resolution's version numbers, which is what "describes an older graph" looks
like when it happens. Anything that would make it quietly short - a package with no license text,
a checkout with no pin, a missing supplemental - is a hard error, because an
incomplete notices file passes every check that only asks whether one exists.
`tools/notices-supplemental/` carries what a file-name search cannot find: a
license that exists only as a comment at the top of a source file. Four of
those are compiled into this binary and none has a license file anywhere -
`small_vector.h` (the V8 project's, included by `mlx/array.h`, so in every
translation unit), `pocketfft.h` (included by both FFT backends), `expm1f.h`
and `cexpf.h` (both compiled into the Metal library) - so all four are vendored
there. BoringSSL is a fifth, kept as over-reporting, since swift-crypto does
not compile it on Apple platforms. pocketfft is also the reason
`ACKNOWLEDGMENTS*` is searched for and the reason that was not enough on its
own: mlx reproduces a PocketFFT notice there, but an older one than the header
of the copy it ships.

**A file-name search finds license files, and the most-used third-party code in
this graph does not have one.** When a pin moves, grep the new sources for
`Copyright` - `grep -rIl -i copyright --include='*.h' --include='*.hpp'
--include='*.cpp' --include='*.metal'` over the checkouts - and read what comes
back. The supplemental bodies are verbatim, which is why two of them are the
only non-ASCII text in this repository: a copyright line is not ours to
transliterate. `test.sh` regenerates the file
and compares, so a stale one fails the suite.

The models are not covered by it. They are downloaded at the user's request,
are not redistributed with the binary, and carry their own licenses on Hugging
Face.

## Code coverage

Off, and stated in the scheme rather than assumed, because the level matters:
coverage is a scheme setting that applies to the whole build graph, so a
per-target setting cannot control it and leaves a mixed binary that reads as
success. An instrumented helper is bigger, slower in the decode loop, and
writes a multi-megabyte `default.profraw` into its working directory on every
run - which, for a helper an app spawns, is wherever the app is running from.

There are no test targets in this project, so nothing turns it on today, and
`NO` is Xcode's default - the `gatherCoverageData: false` in `project.yml` is
for whoever adds a test bundle to the scheme later. Check the artifact rather
than the setting:

```
otool -l build/speech-mlx | grep -c __llvm_prf_cnts     # 0 when clean
```

Use that, not `nm | grep __llvm_prf`: `nm` reports nothing for a small
instrumented binary and reads as a false clean.

## Why it is not a product of the root Package.swift

SwiftPM resolves every declared dependency whether or not the product that uses
it is being built. A `speech-mlx` product in the root manifest would therefore
put mlx-swift, mlx-swift-lm, swift-transformers and swift-huggingface into the
graph of `swift build` for the main binary, which is the opposite of optional.
