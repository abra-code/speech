# Live mode

`speech stream --model <catalog-id>` transcribes the microphone until told to
stop. It emits `segment.partial` while you are still speaking, `segment.final`
when an utterance closes, and - with `--refine` - `segment.refined` carrying the
same id once a second, better engine has re-heard the same audio.

Only rows whose capability record says `live` can be driven this way.
`speech engines` prints the flag; the catalog's `modes` column carries it too.

```
speech stream --model apple.transcriber --language en-US
speech stream --model apple.transcriber --refine apple.dictation --language en-US
speech stream --list-devices
```

## The parts, and why they are separate

Live mode is the only command with no end of its own, so it is not "read,
compute, write" but a set of concurrent parts:

| part | file | job |
| --- | --- | --- |
| the tap | `SpeechCore/Microphone.swift` | opens a device, copies each callback's buffer |
| the pump | `SpeechCore/LivePump.swift` | converts, feeds the session, fills the refine buffer |
| the session | each engine's `LiveSession` | the draft engine; emits partials and finals |
| the refine queue | `SpeechCore/RefinementQueue.swift` | a second engine, one utterance at a time |
| the audio buffer | `SpeechCore/LiveAudioBuffer.swift` | recent audio, addressable by seconds |
| the stop controller | `speech/StopController.swift` | signals, stdin, the parent watchdog |

The rule that shapes all of it: **nothing on the path from the tap to the draft
engine may block on anything slower than the draft engine.** A refine engine at
12x real time sits off to the side and the audio keeps flowing past it.

## Formats

The hardware picks its own rate and channel count. A MacBook's built-in
microphone is 48 kHz mono; an aggregate device can be 44.1 kHz with eight
channels. Every engine wants something else:

- Apple's modules accept only the format `SpeechAnalyzer.bestAvailableAudioFormat`
  names for the module set in use.
- ggml streaming wants the project's canonical 16 kHz mono Float32, which is
  also what every batch measurement here was taken on.
- FluidAudio's streaming managers resample internally and are better handed the
  hardware's own buffers than audio resampled twice.

So `LiveSession` has a `preferredFormat`, the tap is installed with the node's
own format (`format: nil`, the only one guaranteed to be accepted), and the pump
converts. Answering `nil` for `preferredFormat` is not the same as answering
`LiveAudioFormat.canonical`: the difference is a real resampling pass over every
buffer.

Conversion happens in the pump rather than in the tap for two reasons. A run
with `--refine` needs the same audio in two formats at once, and
`AVAudioConverter` is stateful and has no business on a real-time thread.

**The resampler has a delay line.** Converting 48 kHz stereo to 16 kHz mono in
half-second buffers, the first call yields about 1180 frames fewer than the
arithmetic says and the converter keeps them. Nothing is lost - they come out
later - but with an output buffer sized exactly, "later" is one frame per call
and the stream runs a permanent 74 ms behind. `AudioFormatConverter` therefore
allocates 4096 frames of headroom so the backlog flushes in the next call or
two. The unit tests assert the property that matters: total output tracks total
input, and the shortfall does not grow with the number of buffers.

## Refinement

`--refine <catalog-id>` names a second engine. Each time the draft engine
finalizes an utterance, the samples for that span are sliced out of
`LiveAudioBuffer` and queued; the refine engine transcribes them and the result
is published as `segment.refined` with the id of the final it replaces.

This is what lets live mode be both fast and accurate: the draft can be Parakeet
at 100x real time while the refinement is Qwen3-ASR at 12x. Observed on this
machine with `--model apple.transcriber --refine apple.dictation`, the draft
heard "The quick **ground** fox jumps over the lazy dog" and the refinement
corrected it to "brown".

Four rules the queue enforces:

- **Serial.** One refinement at a time. Two at once contend with the draft
  engine for the same GPU, and the live path is the one that visibly suffers.
- **Never blocking capture.** `submit` returns immediately, always.
- **Bounded.** Past 120 seconds of queued audio the backlog is dropped
  oldest-first with a warning. A refine engine at 12x against a speaker who does
  not pause cannot keep up, and a queue holding every utterance of a
  forty-minute meeting is a memory leak wearing a feature's clothes.
- **Single-use.** Draining or canceling closes the queue, and a later `submit`
  is refused with a `refine_closed` warning rather than accepted. Ending a run
  cancels the worker without waiting for the inference inside it, because that
  inference is not interruptible; if a later submission could start a second
  worker, it would run concurrently with the abandoned one - which is exactly
  what the serial rule exists to prevent, and which the caller would have no way
  to notice. One queue per live session.
- **An empty refinement is discarded**, never published. The draft engine heard
  something; a refine engine returning nothing for the same audio is far more
  likely to have hit a bad chunk than to have correctly heard silence, and
  overwriting real text with "" is the one failure a user cannot undo.

Word timings are dropped from a refined segment. They came from the draft
engine's clock and describe different text now; keeping them would place the new
words at the old words' times, which reads as correct and is not.

On stop, the queue gets ten seconds to finish. Whatever is still outstanding is
abandoned and **reported** - a transcript missing three refinements is a
different artifact from a complete one.

That cap bounds the *queue*, not the engine. Canceling the worker stops it
taking new work; it does not reach inside an inference already running, and
every engine here is an actor, so releasing the refine engine's weights queues
behind that inference for however long it takes. The tool says so
(`refine_draining`) rather than pausing silently, and a second Ctrl-C works
throughout - see Stopping.

If a buffer cannot be converted to the canonical format, silence of the same
duration is appended to the refinement buffer and a `refine_conversion` warning
is emitted once. That looks wasteful and is not: the buffer's clock is nothing
but the count of samples appended to it, so skipping a buffer would put it
permanently behind the session's clock, and from then on *every* slice would
hand the refine engine audio offset from the text it is replacing. The cost of a
failed conversion has to stay one bad refinement, not all of them.

A live session that fails at the very end keeps its transcript. `finish()`
throws `LiveSessionFailure`, which carries the segments alongside the message, so
`done` reports what the run actually produced rather than zero segments for a
session that emitted forty of them and then stumbled on its last flush.

## Memory

`LiveAudioBuffer` holds the recent audio so a finalized segment can be re-heard.
At 16 kHz Float32 an hour of dictation is 230 MB, and a live session is expected
to run for exactly that long, so two independent caps bound it: the consumer
drops everything behind each finalized segment, and the buffer itself retains no
more than 300 seconds no matter what the consumer does. The second cap exists
because an engine that never emits a final - a dead stream, a model that hung -
must not also become a memory leak.

Audio is addressed by seconds since capture started, never by index into an
array whose front keeps being dropped. A non-finite timestamp is clamped rather
than converted, because `Int(Double)` traps on NaN and on anything past
`Int.max`, and these timestamps come from whichever model the session is running.

The ceiling trims in chunks, down to 80 percent, rather than exactly to the line.
`removeFirst` shifts everything behind it, so trimming to the line would memmove
the whole retained window on every append once the ceiling is reached - about
225 MB/s of pure copying, for as long as a stalled session runs.

## Stopping

Six ways in, one way out. All of them resolve to a single value delivered to one
`await`, because a signal handler runs on a thread that must not allocate and so
cannot stop a tap, finalize a session or flush a queue.

| how | what it is |
| --- | --- |
| `q` then Return on stdin | the applet's normal, tidy path |
| end of stdin | the applet died without saying goodbye |
| SIGINT | Ctrl-C in a terminal |
| SIGTERM | the applet closing the run |
| SIGHUP | the terminal window closing |
| `--parent-pid <n>` | polls `getppid()` once a second |

The watchdog exists because the other five can all be missed at once: a parent
that is SIGKILLed sends nothing, closes nothing on a pty, and leaves a child
holding the microphone with the recording light on.

**The first stop hands the signals back to the kernel**, so the second one is
fatal. Shutdown is not instant - it finalizes a session, drains refinements and
releases a gigabyte of weights - and an engine can take longer over that than the
person waiting is willing to. If the handled signals stayed ignored for that
whole window, a second Ctrl-C would do nothing, `kill` from another terminal
would do nothing, and the only way out would be SIGKILL with the microphone still
open. First stop graceful, second stop fatal, which is what every long-running
unix tool does.

Because end of stdin stops the run, `speech stream < /dev/null` ends
immediately. Use `--no-stdin` for a run with no controlling process.

A clean stop exits 0 and emits `done`. A capture failure or a live session that
failed while finishing makes the exit status non-zero; `done` is still emitted
first, carrying whatever the run produced.

**The first stop applies to every reason, not only to signals**, and that has a
cost worth knowing: a controlling process that writes `q`, waits, and then sends
SIGTERM as a fallback will kill the tool outright instead of receiving `done`.
The contract is therefore: after `q`, wait for the process to exit; escalate to a
signal only when you mean to abort. The alternative - keeping signals ignored
after a tidy stop - means a `q` that runs into a stuck engine cannot be escaped
at all, which is the worse failure.

One consequence: a second signal can land mid-write to the `--log` file, so its
last line may be truncated. The log is append-only JSONL, so a reader loses at
most that line.

## Devices

`--device` takes a UID, an exact name, or an unambiguous part of a name.
Matching is layered and stops at the first layer that finds anything; a
substring matching two devices is an error naming both rather than a silent
pick, because the two are often "MacBook Air Microphone" and "MacBook Air
Microphone (2)" on a machine with a dock, and recording from the wrong one is
invisible until the transcript comes back empty.

`--list-devices` prints what is available. It answers without touching an engine
or opening the microphone, so it works where CoreAudio does not - inside a
command sandbox the list is simply empty.

The device is selected before the node's format is read, because the format
belongs to the device.

## Permission

macOS grants microphone access to the **responsible process**, not to this
binary. Run from a terminal, it is the terminal that gets asked and the terminal
that appears in System Settings > Privacy & Security > Microphone. Launched by
Speech.app, it is the app - which is why the app must carry
`NSMicrophoneUsageDescription`.

Permission is requested before any model is loaded, so a refusal costs a message
rather than a gigabyte of weights.

## Dropped and unreadable audio

The queue between the tap and the pump holds 64 buffers, about five seconds.
Deep enough to ride out a model hiccup, shallow enough that a session which has
genuinely stalled drops audio rather than growing a queue nobody will ever hear.
Drops are counted and reported in a `capture_overrun` warning: dropped buffers
are missing words, and a transcript with a hole in it must not be handed over as
if it were complete. The warning is suppressed when the run ended in a failure,
because in that case the pump had stopped draining and every remaining buffer was
"dropped" for a reason `done` already carries.

A session can also drop audio of its own. The Apple session hands buffers to
`SpeechAnalyzer` through a bounded stream for the same reason the tap-to-pump hop
is bounded: `feed` yields and returns without waiting, so a stalled analyzer
would otherwise grow a queue of retained `AVAudioPCMBuffer`s at 230 MB an hour.
What it drops is reported as `session_overrun`.

A buffer that cannot be copied at all **ends the run**, with the device's format
in the message. It used to be recorded and reported at exit, which meant a person
could speak into a live-looking session for ten minutes and only find out why
nothing appeared when they gave up. Copies go through the raw `AudioBufferList`
rather than through `floatChannelData` and its siblings, so every PCM layout
works - including the packed 24-bit integers some USB interfaces and virtual
drivers present, for which all three typed accessors return nil.

## The `ggml` rows

transcribe.cpp's streaming shape is different from Apple's, and the difference
drives the whole mapping. There is no result callback and no utterance boundary:
there is one growing hypothesis split into `committed`, which is append-only, and
`tentative`, the volatile suffix. Every `feed` returns the split plus how much
audio has been committed.

`tentative` maps onto `segment.partial` exactly. Nothing maps onto
`segment.final`, because the library never says "that was an utterance", so this
engine has to decide. Measured on `parakeet-unified-en-0.6b`, commits arrive
about once a second in 8 to 20 character increments, and `tentative` is empty
throughout - so a full stop is almost always in the *middle* of what just
arrived. Commits therefore accumulate and a segment closes at each complete
sentence inside the pending text, at a 15-second backstop, or at the end of the
stream. Sentence end times are interpolated by character fraction across the
committed span, which is an estimate and is named as one in the code. **Stage
4.3's voice activity detection replaces all of this**: utterance boundaries
belong to the audio, not to the text.

Two of the seven ggml families have a streaming decoder, and which two matters:

| row | streams | note |
| --- | --- | --- |
| `parakeet-unified-en-0.6b` | yes | English only |
| `nemotron-3.5-asr-streaming-0.6b` | yes | lost to Apple in all three languages in spike 2 |
| every other ggml row | no | including `parakeet-tdt-0.6b-v3`, the fast multilingual one |

So live mode on this engine is currently either an English-only model or the
weakest multilingual row in the catalog. The `fluid` rows are where multilingual
live has to come from.

**One measured trap.** `nemotron-3.5-asr-streaming-0.6b` accepts the parakeet
stream extension, and with the library's default right-context it finalizes
cleanly, reports `state == .finished` and `lastStatus == nil`, commits every
millisecond of audio, and returns an empty string - a live session that looks
like it is working in front of a silent room. Measured 2026-09-05: only
`attContextRight: 0` produces a transcript; 1, 2, 4 and 8 throw; 13 and the
default silently produce nothing. The value is pinned in
`GGMLEngine.streamExtension(for:)` with the table.

## The `fluid` rows

`fluid.parakeet-v3` streams through `SlidingWindowAsrManager`, and it is the row
live mode needed: 25 languages including Polish, where the Apple rows have no
Polish at all and the one `ggml` streaming row that does scored nearly twice its
error rate (see the live measurements below).

It is a third streaming shape again, and the shape is not the one the manager's
name suggests. It runs the *offline* encoder over overlapping windows rather
than a cache-aware streaming one - FluidAudio's own documentation says so, which
is why it deliberately does not conform to that library's `StreamingAsrManager`
protocol.

**The first version of this mapping was wrong in three ways**, all of them
because the library's behavior was inferred from utterances shorter than one
window. The corrected reading, taken from the v0.15.6 source and confirmed by
measurement:

- **A window is decoded once `chunk + right` seconds have arrived - 13 s with
  this config - and once every `chunk` (11 s) after that.** Nothing at all is
  emitted before the first one.
- **Each window's tokens are deduplicated against everything decoded so far, and
  the update carries only the new text.** Updates are non-overlapping,
  append-only pieces of one transcript, and no piece is ever revised.
- **`isConfirmed` is not about the update carrying it.** It says the *previous*
  piece has been promoted out of the manager's volatile slot. Treating an
  unconfirmed update as provisional means waiting for a correction that is never
  sent.

So every update becomes a `segment.final`, and **this row emits no partials at
all**. On a 50-second utterance it produced five finals, the first at 13.2 s.
That is the row's real character: it buys languages, not responsiveness. The
`ggml` rows put a partial on screen in 1.4 to 3.2 seconds and run a tenth of a
second behind the speaker; this one shows nothing for thirteen seconds and then
a paragraph.

Three specific traps in the library, each of which was a defect in the first
version and is measured in the second:

- **`finish()` returns the WHOLE transcript**, rebuilt from every accumulated
  token - not a remainder. Emitting its return value as a trailing segment
  duplicated the entire session: on a 50-second utterance that scored WER 105%
  against a transcript that is otherwise 4.2%.
- **`finish()` does not close the update stream; only `cancel()` does.** Without
  a `cancel()` after it the reader parks forever and the join waits out its full
  five seconds on every single run. Measured: 5.11 s of shutdown, against 0.11 s
  once fixed. Buffered updates survive the cancel, so nothing is lost by it.
- **`volatileTranscript` is assigned the same string the update carries**, so
  polling it can never learn anything the update stream has not already
  delivered. The first version polled it and published the previous segment's
  text under the next segment's id.

`transcriptionUpdates` is a computed property that builds a fresh `AsyncStream`
and overwrites the manager's continuation on **every** read. Reading it twice
orphans the first stream silently. It is read exactly once, and before
`startStreaming`, since a yielded update goes nowhere until it has been read.

Custom vocabulary is refused for live rather than ignored: the batch path boosts
a finished transcript with a second CTC model, and there is no equivalent inside
the sliding window.

## Measuring it: `eval --live`

```
speech eval --model fluid.parakeet-v3@int8 --manifest corpus.tsv --live \
    --language en-US --report out/
```

The same manifest, the same scorer and the same report as a batch `eval`, with
the audio played to a live session in real time instead of handed over whole. A
row's samples are decoded, cut into 64 ms buffers and released on a wall clock,
so the engine sees them the way a microphone would deliver them. Everything
downstream is the production path: the same `LivePump`, the same `LiveSession`,
the same bounded capture queue that drops buffers when the engine falls behind.

That last part is deliberate. A row where the engine could not keep up loses
audio here exactly as it would from a microphone, and the report says how many
buffers and which rows. A WER measured over dropped audio is a fact about the
machine, not about the model, and it must never be quoted as the second thing.

What it adds over a batch score:

- **Time to first partial.** How long the screen stays empty after you speak.
- **Final lag.** How far behind the audio the committed text runs.
- **The wait after you stop.** Time inside the session's flush.
- **Trailing words lost.** Reference words the transcript never reached,
  counted from the end.

The last one is why this exists. A streaming session that stops transcribing
before the speaker stops produces a transcript that tracks the reference and
then simply ends, with no error anywhere - and plain WER buries that among the
substitutions, scoring a transcript missing its last six words the same as one
missing six words scattered through the middle. They are not the same failure
and they are not fixed in the same place. The number is computed as a
free-end-gap alignment: the hypothesis is aligned against every prefix of the
reference, the best-fitting prefix wins, ties go to the longest, and what is
left over is the loss. A wrong last word is therefore a substitution, not a
loss.

Two things this harness does not simulate: a file has no room noise, no
automatic gain control and no device resampling, so a WER from here is a floor
rather than a promise. And `--pace` exists for smoke tests only - at anything
other than 1x the latencies describe no session anyone could have, which is why
the value is warned about on the terminal and stamped into the report.

The device resampling is worth one more sentence, because it is the part of a
real microphone this harness comes closest to reaching and still misses. `eval
--live` feeds the project's canonical 16 kHz mono, and both resamplers on the
path - `LivePump`'s and FluidAudio's own - recognize that format and pass it
through untouched. A microphone at 48 kHz does not: every 64 ms buffer is
converted, and on the `fluid` rows, which ask for no particular format and
resample internally, that conversion happens inside the engine on a converter
built per buffer. So the numbers below are taken on the one path where the
per-buffer conversion cost is zero. It is a small cost, but it is not the cost a
microphone pays, and nothing in this table sees it.

### The first sweep of every row

Every live row, six FLEURS utterances each, on an M5. **Six rows is 124
reference words: this table ranks nothing.** It is here because the shape of the
latency column is a property of each engine's design rather than of the sample,
and that shape is the thing worth knowing before choosing a default.

| row | lang | WER | first partial | lag med/worst | tail |
| --- | --- | --- | --- | --- | --- |
| `ggml.nemotron-3.5-asr-streaming-0.6b@q8_0` | en-US | 0.81% | 1.44 s | 0.05 / 0.09 s | 0.04 s |
| `fluid.parakeet-v3@int8` | en-US | 4.03% | none | 0.83 / 2.31 s | 0.16 s |
| `fluid.parakeet-v3@int4` | en-US | 5.65% | none | 1.01 / 2.22 s | 0.15 s |
| `ggml.parakeet-unified-en-0.6b@q8_0` | en-US | 6.45% | 3.23 s | 0.10 / 0.15 s | 0.10 s |
| `apple.dictation` | en-US | 7.26% | 1.82 s | 1.32 / 2.36 s | 0.07 s |
| `apple.transcriber` | en-US | 9.68% | 4.00 s | 1.16 / 1.36 s | 0.13 s |
| `fluid.parakeet-v3@int8` | pl-PL | 18.26% | none | 0.64 / 1.70 s | 0.18 s |
| `fluid.parakeet-v3@int4` | pl-PL | 23.48% | none | 0.72 / 1.64 s | 0.14 s |
| `ggml.nemotron-3.5-asr-streaming-0.6b@q8_0` | pl-PL | 31.30% | 1.45 s | 0.07 / 0.08 s | 0.04 s |

No row dropped a buffer and no row lost a trailing word, so every WER above is
a score over the whole audio.

Two things in it are worth more than the ranking. **Polish is why
`fluid.parakeet-v3` exists**: Apple has no Polish at all, and the only other
multilingual live row scored nearly twice its error. And **`first partial:
none` is the price**: that row publishes nothing until a window closes, which
on these nine-second utterances means nothing until the very end and on a long
one means nothing for thirteen seconds.

## What is not here yet

- **VAD-driven segmentation** (plan step 4.3). Utterance boundaries currently
  come from the draft engine's own finals, or from the sentence rule above.
  Silero VAD marking speech start and end - which would give every engine the
  same boundaries, and give refinement a span chosen for the audio rather than
  for the model - is still to come.
- **Live sessions for the remaining `fluid` rows** (the rest of plan step 4.2).
  `fluid.parakeet-unified` and `fluid.nemotron-multilingual` still report
  `unavailable` with a reason; both have a streaming manager, and each is shaped
  differently again from the sliding window.
