# The `speech-mlx` helper protocol

`speech-mlx` is a separate binary that turns PCM into transcripts using MLX,
and does nothing else. It does not reach the network, decode a container, read
a manifest, score anything, or know that a catalog exists. `speech` keeps all
of that, because `speech` already has it.

The split is not tidiness. mlx-swift's Metal kernels are compiled into a
resource bundle that has to travel beside the binary, its package graph pulls in
four more packages, and the API it exposes has changed shape more than once.
Keeping it behind a five-call surface means a churn in any of that moves inside
a binary this tool can also be shipped without.

This file is the specification. It is what both sides implement, and the
examples in it are parsed and re-encoded by the test suite, so an example that
stops being true fails the build.

## Transport

- **Requests** go to the helper's stdin: one UTF-8 JSON object on one line,
  terminated by `\n`. When that object carries an integer `bytes`, exactly that
  many raw bytes follow the newline and belong to the same request.
- **Responses** come back on the helper's stdout: one JSON object per line, no
  payload, in the order the requests arrived - which is a property of the
  helper answering one request at a time on one task, not of the format.
- **Diagnostics** go to stderr. Anything the helper or its libraries print
  lands there, never on stdout.

`bytes` belongs to the framing layer. No message may use that key for anything
else.

### Why raw bytes rather than base64

A FLEURS split is about two and a half hours of audio, so one evaluation cell
moves roughly 570 MB of Float32 through this pipe. Base64 would make that 760 MB
and add an encode and a decode per utterance. The price of the raw payload is a
framing rule that has to count bytes rather than split on newlines - Float32
samples contain `0x0A` as readily as any other byte.

### Audio format

Little-endian Float32, mono, 16 kHz, nominally in [-1, 1]: what
`AudioDecoder` produces, so every engine in this project is measured on
identical samples. `samples` and `bytes` are both sent and `bytes == samples * 4`
is checked, so a short write fails instead of producing a transcript of the
truncation.

### stdout has to be taken away from the libraries

This is the one implementation rule the protocol imposes on the helper. MLX
Audio writes to stdout with plain `print`, 71 times across the two modules the
helper links, and at least one of those is on a path the helper takes:
`Qwen3ASRModel.fromModelDirectory` synthesizes a `tokenizer.json` when the
repository ships none - which the mlx-community Qwen3-ASR repositories do not -
and prints `Generated tokenizer.json at: ...` unconditionally while doing it.
That line lands in the middle of the response stream and corrupts it, on a
successful load rather than on an error path.

So the helper duplicates fd 1 to a private descriptor at startup and then points
fd 1 at stderr. Library output goes to stderr with everything else, and the
protocol writes to the descriptor it saved. A helper that writes responses with
`print` is broken and will look fine until the first model load.

## Requests

### `load`

```jsonl
{"op":"load","directory":"/path/to/models/mlx/parakeet-tdt-0.6b-v3"}
{"op":"load","directory":"/path/to/models/mlx/whisper-large-v3-turbo","type":"whisper","language":"pl"}
```

`directory` holds `config.json` and the safetensors shards. `type` is the model
type as `config.json` spells it, and may be omitted to have the helper read it
from there. `language` is a hint for the models that take one.

The helper never downloads. `speech` fetched these files through the same
resumable, LFS-object-pinned client every other row uses, into the same model
store, so there is one download path and one definition of "installed".

It can, in one case, *write*: loading a Qwen3-ASR checkpoint synthesizes a
`tokenizer.json` from `vocab.json` and `merges.txt` when the repository ships
none, which is the normal case for those repositories, and writes it into the
directory it was handed. So a row of that family grows a file after it was
installed, and a read-only store fails the load.

### `transcribe`

```jsonl
{"op":"transcribe","id":1,"samples":16000,"bytes":64000}
{"op":"transcribe","id":2,"samples":480000,"bytes":1920000,"chunk_seconds":30,"max_tokens":2048}
```

The audio follows the newline. `id` is echoed on every event this request
produces.

`chunk_seconds` is not a tuning knob. MLX Audio's default is 1200 seconds, and
its issue #248 reports that default building a roughly 7 GB KV cache and hanging
a 108-minute file on a 48 GB machine. `speech` hands over bounded buffers and
says here how the model may cut them.

`max_tokens` means different things to different models, measured in v0.1.3
rather than assumed: Qwen3-ASR, Cohere and Voxtral decrement a single budget
across every chunk of a buffer, so it is a total for the whole request and
running out truncates the tail silently (MLX Audio issue #249); Whisper
recomputes a fresh budget for each 30-second window, so it is a per-window cap;
and Parakeet never reads it at all, its decode being bounded by symbols per
frame instead. Send it as a safety limit, not as a length control.

### `unload` and `bye`

```jsonl
{"op":"unload"}
{"op":"bye"}
```

`unload` drops the weights and keeps the process. `bye` exits 0, and so does
end of stdin - a parent that dies takes the helper with it without needing to
signal. Anything sent behind `bye` in the same write is discarded without a
reply, including a request whose payload had not finished arriving; `bye` means
stop, not "finish what you have".

## Responses

### `ready`

Sent unprompted, once, before any request is read.

```jsonl
{"event":"ready","helper":"0.1.0","mlx_audio":"0.1.3","mlx_swift":"0.31.6","types":["parakeet","whisper","qwen3_asr"]}
```

It is emitted only after the helper has run a trivial MLX operation, which makes
it answer the question that is most expensive to answer late: whether this build
can reach the GPU at all. A binary that lost its Metal bundle links, launches,
and then dies on its first array operation with `Failed to load the default
metallib`; a process with no GPU access dies differently, with an
`NSRangeException` out of `mlx::core::metal::Device::Device()` that says nothing
about Metal. Proving it at startup turns either into a handshake that fails
rather than a measurement that stops halfway.

`types` are model types this build can construct, not a capability table.
Languages and flags are properties of a checkpoint rather than of a type, so
they are reported by `loaded`, after the weights have been read.

### `loaded`

```jsonl
{"event":"loaded","type":"whisper","seconds":1.52,"languages":["en","pl"],"language_hint":true}
{"event":"loaded","type":"parakeet","seconds":0.91,"languages":[],"language_hint":false}
```

What the model says about itself, read from the loaded weights rather than from
a table in either process. An empty `languages` means the checkpoint does not
say - which is not the same as "no languages", and `speech` reports it as the
former rather than inventing a list. Only Whisper's generation config names its
languages today, so most rows answer with an empty list.

There is deliberately no `segment_timestamps` here. Whether a model produces
timings is measured per request by `synthesized` on `done`, and a flag asserted
at load time would be a claim rather than an observation.

### `segment`

```jsonl
{"event":"segment","id":1,"index":0,"start":0.0,"end":2.48,"text":"the first utterance"}
```

Times are seconds from the start of the buffer that was handed over, never from
the start of a recording. The helper is not told where its buffer came from;
offsetting is `speech`'s job, because `speech` is the only side that knows.

### `done`

```jsonl
{"event":"done","id":1,"seconds":0.41,"segments":2,"synthesized":false,"peak_memory_gb":1.25}
```

`synthesized` is true when the model returned no timings and the helper covered
the buffer with a single span. That is the difference between a measured
timestamp and an assumed one, and a row that always synthesizes has no segment
timestamps whatever its model card says. Measured across the eight types in
v0.1.3: Parakeet and Nemotron return real spans from their own alignment,
Whisper and Qwen3-ASR return one span per decoding chunk, and Cohere,
FireRedASR2, SenseVoice and Voxtral return either nothing or a dictionary with
no `start` and `end` at all - so those four always synthesize.

`synthesized: false` therefore means "the model said", not "finely". A Whisper
span is a 30-second window and a Qwen3-ASR span is a `chunk_seconds` window,
which is a very different thing from Parakeet's sentence-level alignment even
though both arrive through the same field.

`peak_memory_gb` is MLX's own opinion and is recorded rather than trusted:
`peak_memory_bytes` in `speech` is this project's instrument, and stage 1 spent
a day learning what an inherited memory number is worth. It is omitted entirely
when the model reports nothing - Parakeet reports 0.0, and zero gigabytes is not
a measurement.

### `ok`

```jsonl
{"event":"ok","op":"unload"}
```

Every request gets exactly one terminal reply, and this is the reply for the
ones with nothing to report. The alternative - `unload` answering with silence -
means the reader has to know which requests reply and which do not, and a reader
that gets that wrong blocks forever on a message nobody is going to send.

### `error`

```jsonl
{"event":"error","op":"load","message":"no config.json in /path/to/models/mlx/whisper-large-v3-turbo"}
{"event":"error","op":"transcribe","id":3,"message":"generation failed"}
```

Never fatal on its own. The helper stays up and reads the next request, because
a model that fails on one utterance of a 700-row split should cost that row and
not the other 699. `op` is the request that failed, or one of three values that name no request:
`startup` for a failure before any request was read, `framing` for a stream that
stopped being this protocol's, and `request` for a line that framed correctly
and then would not decode. The first two end the run; a `request` failure does
not, but it does make the exit code non-zero, because a request the helper could
not parse is a protocol violation whenever it happens.

## Lifecycle

1. `speech` spawns the helper and reads one line. Anything but `ready` - or a
   silence past the handshake timeout - means the engine reports itself
   unavailable with that reason, and no row of this family runs.
2. `load` once per model.
3. `transcribe` per utterance. Replies arrive in order; `id` makes that
   checkable rather than assumed.
4. `bye`, or close stdin.

There is no cancel request. MLX generation is a synchronous call that does not
come back early, so a cancel would be a message the helper could not act on
until it no longer mattered. `speech` kills the process instead, after verifying
the pid is the one it spawned.
