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
speech stream --model fluid.parakeet-unified@stream-640 --segment vad
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
| the detector | `SpeechFluid/SileroVad.swift` | under `--segment vad`, where the room goes quiet |
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

## Where an utterance ends

Every row here decides that differently, and by default none of them decides it
from the audio: Apple's analyzer finalizes on its own schedule, the sliding
window finalizes when a window closes, and the two shapes that hand over a
growing transcript are cut by `StreamSegmentAccumulator` at what looks like the
end of a sentence, timed by interpolating a character position into a commit
span. So the same recording is cut differently by every row, the times are
estimates, and `--refine` re-transcribes a span the model chose.

`--segment vad` replaces that with `fluid.silero-vad`, which has to be
downloaded first. The detector watches the same canonical audio the refinement
buffer sees, reports where speech starts and stops, and the session cuts there.

**It is an observer and never on the path to the engine.** The audio the draft
engine gets is untouched, so a detector that is wrong, slow or absent changes
where a transcript is cut and can never change what it says. Measured on the
53.7-second fixture, the hypothesis is byte-identical between `--segment engine`
and `--segment vad` on all four Parakeet Unified streaming tiers, and WER with
it: 7.21%, 19.82%, 11.71% and 25.23% either way.

What changes is the shape. On that fixture the spans stop covering the silence:
45.0 seconds of span over 53.7 seconds of audio against 51.2 with the sentence
rule, and each segment ends exactly at a measured pause rather than 1 to 2
seconds past it.

Three rules are worth knowing before using it.

**A cut needs a word clock to land where the audio said.** The cut fires on the
first commit whose watermark passes the boundary - and on a real pause, that is
the commit carrying the *next* utterance's first words. The two `fluid`
streaming families answer "which of these words were spoken before this moment"
from their own token timings, so their cut lands between the two words the
boundary falls between. The `ggml` rows get no word timings on a live stream, so
their cut takes the text as it stands, minus its last word: a boundary there is
a better time than a sentence guess, but the words around it can be a decode
step out of place.

**Sentence-final punctuation is decoded late.** The RNN-T decoder emits `.`
once it has evidence the sentence ended, which is at or after the next
utterance's onset, and the word grouping glues a piece carrying no
word-boundary marker onto the word before it. So `certainty.` starts at 9.84 s
and ends at 13.20 on a pause that began around 10.2, while a word carrying no
punctuation ends 80 ms after its last piece was decoded. Words are therefore selected by
where they *start*, and a segment cut at a boundary takes its end from the
boundary rather than from that word. Selecting on the end instead cut every
segment about three seconds early, with each sentence's own ending leading the
next segment.

**A pause shorter than 0.75 s is not a boundary**, and one longer than that ends
an utterance whatever the speaker meant. That is Silero's `minSilenceDuration`,
and it is why the fixture above comes back one segment shorter on every tier
than the sentence rule: two of its six sentences are separated by less than
that and are published together. The
15-second backstop still applies, because the streaming detector never splits a
long span of speech on its own.

Rows whose segmentation belongs to the model - the two Apple rows and
`fluid.parakeet-v3` - ignore boundaries, and say so with a `segment_ignored`
warning rather than accepting the flag and doing nothing with it.

The detector costs about a thousandth of real time - 0.36 s of compute for 470 s
of audio. Its memory cost is not measurable here: the model is 1.1 MB on disk,
and peak memory across paired runs of the same row moves by several megabytes in
both directions, which is larger than the thing being measured. It runs after
the session has been fed rather than before, so it cannot delay the draft engine
by a buffer it could have had already.

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

Two of the seven built-in ggml families have a streaming decoder (Granite Speech, added later, has none), and which two matters:

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
default silently produce nothing. The value is the model's `stream` setting in
`catalog/ggml.json`, with the table in its note; `GGMLEngine.streamExtension(for:)`
keeps the same value as the fallback for a model added without one.

## The `fluid` rows

Three families of them stream. Two answer the same question - a language Apple
does not have - differently enough that both are worth keeping. The third is
English only and is here for a different reason: it is the only row whose
latency is a dial the caller turns.

### `fluid.parakeet-v3`, the row with the most languages

It streams through `SlidingWindowAsrManager`, and it was the first row to give
live mode a language Apple does not have: 25 of them including Polish, where the
Apple rows have no Polish at all and the one `ggml` streaming row that does
scored nearly twice its error rate (see the live measurements below).

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

### `fluid.nemotron-multilingual`, the row that answers the same question faster

The second `fluid` row to stream is the one whose manager was built for it. Its
encoder carries its own cache forward chunk by chunk, so unlike the sliding
window it decodes each piece of audio once, and unlike the sliding window it
does not need thirteen seconds of it before it says anything. What it needs is
one chunk, and the chunk is the row's variant: **`@2240`, `@1120` and `@560` are
the same weights with a different latency**, and they are the row's only real
choice.

Measured here, six FLEURS rows a language, on an M5:

| row | lang | live WER | batch WER | first partial | partial every | lag med/worst | tail |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `fluid.nemotron-multilingual@2240` | en-US | 2.42% | 2.42% | 2.31 s | 2.24 s | 1.40 / 2.14 s | 0.06 s |
| `fluid.nemotron-multilingual@1120` | en-US | 4.03% | 4.03% | 2.29 s | 1.12 s | 1.38 / 2.12 s | 0.04 s |
| `fluid.nemotron-multilingual@2240` | pl-PL | 22.61% | 22.61% | 2.31 s | 2.24 s | 0.09 / 1.36 s | 0.06 s |
| `fluid.nemotron-multilingual@1120` | pl-PL | 22.61% | 22.61% | 2.29 s | 1.12 s | 0.61 / 1.34 s | 0.04 s |

Three things in that table are worth reading carefully.

**Live WER equals batch WER, to the digit, in all four.** The transcripts are not
merely as good - they are byte-identical, checked row by row. This row decodes
chunk-aligned windows in a fixed order whether the audio arrives all at once or
in real time, so streaming it costs nothing at all. That is also the strongest
statement available that the mapping here adds no artifact of its own: the text
comes from the library's own tokenizer on both paths.

**"First partial" is not the latency of the tier.** Both tiers show about 2.3 s,
which for `@2240` is its first chunk and for `@1120` is its *second* - the first
lands inside the moment of silence every FLEURS row opens with, and silence
decodes to no text and therefore to no partial. The column that separates the
tiers is the cadence: `@1120` produced 9 partials on a 12.6 s row where `@2240`
produced 5. Time to first partial mixes the model's chunk with the speaker's
first breath, and on this row the second one dominates.

**The finer tier is not free.** English doubled its error rate from 2.42% to
4.03% for half the wait; Polish did not move at all. Six rows rank nothing, but
the direction is the one the model card would predict, and the dial is real.

Against the other `fluid` row: this one puts text on screen every one to two
seconds where `fluid.parakeet-v3` shows nothing for thirteen, and on the Polish
sample it scored 22.61% against that row's 18.26%. Neither margin is a ranking
on six rows. Both rows exist for the same reason - languages Apple does not have
- and they answer it differently enough that the catalog should keep both until
a real run says otherwise.

Two limits of this row worth knowing before choosing it.

**In the scripts that do not separate words, a "word" is a tokenizer artifact.**
Word timings here come from grouping tokens on the SentencePiece word-boundary
marker, and the mark is much rarer in those vocabularies: of this model's 13087
pieces, 206 CJK pieces carry it against 6704 that do not, 157 Hangul against
1885, and 48 kana against 169. So a Japanese or Chinese "word" in a
`segment.final` is a run of characters between two marked pieces rather than
anything a reader would call a word, and where a whole segment contains no
marked piece it gets no word timings at all and falls back to the accumulator's
estimated span. The text and the segmentation are unaffected either way, and the
timings that are there are real - the detokenizer renders each mark as a space,
so the words line up with the text exactly as they do in English.

Read the word list in those languages as "where the tokenizer changed its mind",
not as words. Stage 4.3's VAD is what will give those rows boundaries taken from
the audio.

**One live session at a time, per engine.** This row's session shares the
manager the engine already loaded rather than building a second one - that
sharing is the reason live mode here costs no extra 660 MB - so two concurrent
sessions from one engine, or a `transcribe()` call during a session, would reset
each other's decoder state. Nothing in the CLI can do either: the verbs are
sequential and `--refine` refuses the draft engine's own id. It is a contract an
embedded caller has to keep, not a guard the engine enforces.

The traps in this manager are the same family as the sliding window's, and one
is identical: **`finish()` returns the whole transcript, not a remainder**. That
is now the third manager in this library to work that way, so it is a property
of the library rather than an accident of one class, and a session that appends
its return value duplicates everything it has already published.
`getPartialTranscript()` is likewise the whole transcript rather than a delta,
which is why the session polls it only when a chunk was actually consumed rather
than on every 64 ms buffer.

### `fluid.parakeet-unified@stream-*`, the row with a latency dial

The third `fluid` family to stream, and the only row in the catalog whose
responsiveness is a choice rather than a property. Its encoder re-runs over a
`[left | chunk | right]` window whose chunked-attention mask was baked in at
conversion time, so each of the four published contexts is a different download
and a different row - see the engines document for the tier table. English only.

**The tier has two independent knobs and they do different things.** The chunk
sets how often text appears; the look-ahead sets how long each piece waits. That
is visible in the two tiers that share a chunk: `@stream-1120` and `@stream-640`
are both seven encoder frames of new audio per step and produce partials at the
same rate, and they differ by half a second in how long the first one takes.
Compare the Nemotron row, where the two are locked together and the tier is a
single number.

Measured here, the first six FLEURS en_us rows, on an M5:

| row | live WER | batch WER | first partial | partial every | lag med/worst | tail |
| --- | --- | --- | --- | --- | --- | --- |
| `@stream-2080` | 6.45% | 6.45% | 3.19 s | 1.47 s | 1.15 / 2.59 s | 0.05 s |
| `@stream-1120` | 6.45% | 6.45% | 2.28 s | 0.82 s | 1.16 / 2.60 s | 0.03 s |
| `@stream-640` | 7.26% | 7.26% | 1.83 s | 0.80 s | 1.15 / 2.51 s | 0.03 s |
| `@stream-320` | 8.06% | 8.06% | 1.64 s | 0.38 s | 0.24 / 2.62 s | 0.03 s |

**Live WER equals batch WER, and the transcripts are byte-identical**, row by
row, on all four tiers - checked by diffing the `--json` hypotheses rather than
by comparing percentages. That is the same result the Nemotron row gives and for
the same reason: the window schedule is driven by how much audio has arrived,
not by how it arrived, so streaming costs nothing at all.

That covers the text and not the word timings, which a hypothesis diff cannot
see. Those were checked separately, against the real model: eight minutes at the
0.32 s tier, 1262 polls, 968 words, live word timings identical to a whole-file
run in text, start and end.

**Unlike the Nemotron row, time to first partial does separate these tiers**,
and the tier accounts for most of the gap: subtract each tier's
chunk-plus-look-ahead from its first-partial time and the four leftovers are
1.11, 1.16, 1.19 and 1.32 s, roughly the silence every FLEURS row opens with
plus one decode. Not all of it - those four are not equal, they rise by 0.21 s
as the tier gets faster, which is the direction the faster tiers' higher
per-second encoder cost would push them. The Nemotron tiers hid the effect
entirely because their first chunk lands inside the silence; here the shortest
tier's does too, and it still shows, because the tiers are far enough apart.

Over 647 rows rather than six, the batch WER of the four is 5.07%, 5.40%, 6.80%
and 7.24%, against 4.90% for the offline encoder of the same checkpoint. The
look-ahead is what costs accuracy: `@stream-640` and `@stream-1120` feed the
same audio per step and differ only in future context, and that is worth 1.4
points.

**On continuous speech, none of these numbers holds.** Six distinct sentences
concatenated into one 53.7 s utterance, 109 reference words:

| row | WER | words | finals | max final lag |
| --- | --- | --- | --- | --- |
| `@stream-2080` | 7.21% | 109 | 6 | 2.01 s |
| `@stream-1120` | 19.82% | 93 | 5 | 7.25 s |
| `@stream-640` | 11.71% | 108 | 6 | 0.81 s |
| `@stream-320` | 25.23% | 91 | 5 | 6.70 s |

Live and batch are still byte-identical in all four, so this is the encoder and
not the live path. What happened is specific rather than gradual: `@stream-1120`
and `@stream-320` dropped one whole sentence - the same one in both - and the
16 words it was made of are most of the difference. One sentence out of six is
not a rate, and six sentences do not rank four tiers; what this does establish
is that the per-row figures above, where every row is a single 12 s sentence,
say nothing about a minute of continuous speech. The 200-row run and a
long-form corpus are what settle it.

The max-lag column is worth reading separately, because it is not the encoder's
latency at all. A final is published when the sentence rule finds a boundary, so
a dropped sentence means a missed boundary and text held for seven seconds. On
single-sentence rows the lag is about one chunk; on continuous speech it is
whatever the segmentation does. That is the argument for stage 4.3's VAD in one
number.

**One live session at a time, per engine**, the same contract the Nemotron row
carries and for the same reason: the session shares the manager the engine
already loaded, so live mode costs no second 609 MB and no second ANE compile,
and two concurrent sessions would reset each other's decoder state and window
position. Nothing in the CLI can do it; an embedded caller has to keep it.

The library trap here is the same one, for the fourth time: **`finish()` returns
the whole transcript, not a remainder.** There is a second one specific to this
manager - `consumeTokenTimings()` *drains* rather than reads, so the back-fill
that gives each token a real duration stops at the poll boundary and the session
has to carry it across. See `StreamingTokenTimings`.

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

- **A corpus where VAD segmentation can be judged.** `--segment vad` is measured
  above on six read sentences with clean punctuation, which is the case the
  sentence rule was already good at - it produces the same words there and
  tighter spans. The case it exists for is dictation: continuous speech with no
  punctuation to guess from, where the sentence rule produces nothing until the
  15-second backstop. Nothing in this project measures that yet.
- **The `ggml` rows cut without a word clock.** Their boundary is measured but
  the text at it is a decode step out of place, because transcribe.cpp reports
  no word timings for a live stream. Either a timing source there or a
  character-level estimate against the commit watermark would close it.
- **A run long enough to choose a tier.** Every live row here has been measured
  on six utterances, which is enough to prove the plumbing and not enough to
  rank anything. The Parakeet Unified tiers make that concrete: on six
  single-sentence rows they look 1.6 points apart, and on one 54-second
  utterance they are 18 points apart in a different order. Plan step 4.5's
  200-row grid is the open item, and this row adds a second one - a corpus of
  continuous speech, because every FLEURS row is one sentence and no measurement
  taken on them says anything about dictation.
