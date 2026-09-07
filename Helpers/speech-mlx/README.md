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

Two prerequisites, both one-time per machine:

```
xcodebuild -downloadComponent MetalToolchain    # about 688 MB
brew install xcodegen                           # only to regenerate the project
```

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

## Why it is not a product of the root Package.swift

SwiftPM resolves every declared dependency whether or not the product that uses
it is being built. A `speech-mlx` product in the root manifest would therefore
put mlx-swift, mlx-swift-lm, swift-transformers and swift-huggingface into the
graph of `swift build` for the main binary, which is the opposite of optional.
