#!/usr/bin/env python3
"""Build a corpus of continuous speech from a LibriSpeech split or a FLEURS split.

Every row of FLEURS, and every utterance of LibriSpeech, is one sentence or a
little more, cut tight at both ends. That is the easy case for a live session:
it has one boundary to find and ends where the audio ends. The case live mode is
for - someone dictating, a speaker who does not stop - has neither, and the one
measurement of it in this project so far (a 54-second passage of six joined
sentences, docs/live.md) reordered the Parakeet Unified latency tiers entirely:
two of the four dropped a whole sentence there while scoring within a point of
each other on single sentences.

LibriSpeech is read from audiobooks, and the utterances of one chapter are
consecutive stretches of one continuous reading by one person. Joining them in
order, with a short silence where the corpus cut, rebuilds the reading: for a
LibriSpeech split this program writes one passage per chapter, each about a
minute long, from a different speaker each time, with the references joined the
same way.

FLEURS is the only corpus here with the other five languages in it, and it is
not a reading: its rows are unrelated sentences in no document order, each
recorded by several speakers in consecutive rows. A FLEURS passage is therefore
a different artifact - consecutive distinct sentences, one voice per sentence,
joined the same way - and it is built for the same reason: an hour of it has no
cut edges for a live session to lean on. Only the first row of each sentence is
taken, because a language-model decoder writes a sentence it hears twice in a
row once, which scores as deletions that are not the model's.

    tools/make-continuous-corpus.py                       # 20 passages from test-clean
    tools/make-continuous-corpus.py --split test-other --passages 30 --seconds 90
    tools/make-continuous-corpus.py --split de_de         # 20 passages of German

The output is $SPEECH_CORPUS_DIR/LibriSpeech/continuous-<split>/ or
$SPEECH_CORPUS_DIR/fleurs/continuous-<directory>/, holding passage-NN.wav files
and a manifest.tsv in the format `speech eval` reads. The audio comes from
`speech decode`, which is what every engine would receive anyway, and is written
as 16 kHz mono 16-bit PCM. It is deterministic: chapters, and FLEURS rows, are
taken in a fixed order, so two machines building the same arguments get the same
passages. An existing corpus is left alone unless --force is given.

This does NOT fetch either corpus; tools/fetch-librispeech.sh and
tools/fetch-fleurs.sh do.
"""

import argparse
import array
import os
import re
import struct
import subprocess
import sys
import tempfile
import wave

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SAMPLE_RATE = 16000
LIBRISPEECH_LANGUAGE = "en-US"
LIBRISPEECH_SPLITS = ("test-clean", "test-other")

WAVE_FORMAT_PCM = 1
WAVE_FORMAT_IEEE_FLOAT = 3
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


def die(message, status=1):
    print("make-continuous-corpus: %s" % message, file=sys.stderr)
    sys.exit(status)


def read_manifest(path):
    """(audio path, reference, language) rows in manifest order.

    The language column is optional in the format `speech eval` reads; a row
    without one gets "", and the caller supplies the corpus's own tag.
    """
    rows = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 2 or not fields[0]:
                    continue
                rows.append((fields[0], fields[1], fields[2] if len(fields) > 2 else ""))
    except OSError as error:
        die("cannot read %s: %s" % (path, error))
    return rows


def chapters(rows):
    """Utterances grouped by chapter, each group in reading order.

    A LibriSpeech file is <speaker>/<chapter>/<speaker>-<chapter>-<nnnn>.flac,
    and the four-digit number is the utterance's place in the chapter, so sorting
    by file name within a chapter directory is the order it was read in.
    """
    groups = {}
    for audio, reference, _ in rows:
        chapter_dir = os.path.dirname(audio)
        speaker = os.path.basename(os.path.dirname(chapter_dir))
        groups.setdefault((speaker, os.path.basename(chapter_dir)), []).append((audio, reference))
    for key in groups:
        groups[key].sort(key=lambda row: os.path.basename(row[0]))
    return [(key[0], key[1], groups[key]) for key in sorted(groups)]


def pcm16_from_wav(path):
    """The samples of a 16 kHz mono WAV file as 16-bit integers.

    `speech decode` writes 32-bit float WAV (format tag 3), which Python's `wave`
    module refuses to open, so the RIFF chunks are walked here instead. Integer
    16-bit input is taken as it is; float input is clipped to [-1, 1] and scaled,
    which is the conversion AVFoundation applies in the other direction.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        die("cannot read %s: %s" % (path, error))
    if len(data) < 12 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        die("%s is not a WAV file" % path)

    format_tag = channels = rate = bits = None
    samples = None
    offset = 12
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        size = struct.unpack("<I", data[offset + 4:offset + 8])[0]
        body = data[offset + 8:offset + 8 + size]
        if chunk_id == b"fmt " and len(body) >= 16:
            format_tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if format_tag == WAVE_FORMAT_EXTENSIBLE and len(body) >= 26:
                # The real format is the first two bytes of the subformat GUID.
                format_tag = struct.unpack("<H", body[24:26])[0]
        elif chunk_id == b"data":
            samples = body
        offset += 8 + size + (size & 1)

    if format_tag is None or samples is None:
        die("%s has no fmt or data chunk" % path)
    if rate != SAMPLE_RATE or channels != 1:
        die("%s is %d Hz with %d channel(s); expected %d Hz mono" % (path, rate, channels, SAMPLE_RATE))

    if format_tag == WAVE_FORMAT_PCM and bits == 16:
        pcm = array.array("h")
        pcm.frombytes(samples[:len(samples) - len(samples) % 2])
        if sys.byteorder != "little":
            pcm.byteswap()
        return pcm
    if format_tag == WAVE_FORMAT_IEEE_FLOAT and bits == 32:
        floats = array.array("f")
        floats.frombytes(samples[:len(samples) - len(samples) % 4])
        if sys.byteorder != "little":
            floats.byteswap()
        return array.array("h", (int(max(-1.0, min(1.0, value)) * 32767) for value in floats))
    die("%s uses WAV format %d at %d bits; only 16-bit PCM and 32-bit float are read"
        % (path, format_tag, bits))


def decode(speech, source, scratch_wav):
    """One utterance as 16 kHz mono 16-bit samples, through `speech decode`."""
    done = subprocess.run([speech, "decode", source, "--output", scratch_wav],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if done.returncode != 0:
        die("speech decode failed for %s: %s" % (source, done.stderr.strip()))
    return pcm16_from_wav(scratch_wav)


def write_pcm16(path, samples):
    """A 16 kHz mono 16-bit PCM WAV, written beside its final name and renamed in."""
    partial = path + ".part"
    if sys.byteorder != "little":
        samples = array.array("h", samples)
        samples.byteswap()
    with wave.open(partial, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(SAMPLE_RATE)
        writer.writeframes(samples.tobytes())
    os.replace(partial, path)


def source_for(options):
    """(kind, source manifest, output directory) for the split that was named.

    A LibriSpeech split name is a closed set of two, so anything else is taken
    as a FLEURS directory. The FLEURS reading is not guarded by a table of
    directory names here: tools/language-battery.py resolves language tags to a
    directory and passes that, and a hand-run build of a split this program has
    never heard of should fail on the missing manifest rather than on a list.
    """
    if options.split in LIBRISPEECH_SPLITS:
        return ("librispeech",
                os.path.join(options.corpus_dir, "LibriSpeech", options.split, "manifest.tsv"),
                os.path.join(options.corpus_dir, "LibriSpeech", "continuous-" + options.split))
    return ("fleurs",
            os.path.join(options.corpus_dir, "fleurs", options.split, "manifest.tsv"),
            os.path.join(options.corpus_dir, "fleurs", "continuous-" + options.split))


def librispeech_passages(options, rows, scratch, gap, target_frames):
    """Passages of one reader: (label, language, texts, samples), one at a time.

    One per chapter and one per speaker: twenty minutes of three voices would
    measure those three voices. A generator, so each passage is written as soon
    as it is decoded rather than after the whole corpus is in memory.
    """
    speakers_used = set()
    for speaker, chapter, utterances in chapters(rows):
        if speaker in speakers_used:
            continue

        passage = array.array("h")
        texts = []
        for index, (audio, reference) in enumerate(utterances):
            samples = decode(options.speech, audio, os.path.join(scratch, "utterance-%d.wav" % index))
            if passage:
                passage.extend(gap)
            passage.extend(samples)
            texts.append(reference.strip())
            if len(passage) >= target_frames:
                break
        if len(passage) < target_frames // 2:
            # A chapter too short to make a passage of even half the length
            # would drag the corpus back towards single sentences.
            continue

        speakers_used.add(speaker)
        yield ("speaker %s chapter %s" % (speaker, chapter),
               LIBRISPEECH_LANGUAGE, texts, passage)


def fleurs_passages(options, rows, scratch, gap, target_frames):
    """Passages of consecutive distinct sentences: (label, language, texts, samples).

    FLEURS records each sentence by several speakers in consecutive rows, so only
    the first row of a sentence is taken: a language-model decoder writes a
    sentence it hears twice in a row once, which scores as deletions that are not
    the model's. The rows are in no document order, so a passage is a run of
    unrelated sentences in different voices - which is what this corpus is, and
    what the page that publishes it has to say. What it shares with the
    LibriSpeech one is the property being measured: a minute of speech with no
    cut edge for a live session to find a boundary at.
    """
    seen = set()
    passage = array.array("h")
    texts = []
    language = ""

    for index, (audio, reference, row_language) in enumerate(rows):
        key = reference.strip()
        if key in seen:
            continue
        seen.add(key)

        samples = decode(options.speech, audio, os.path.join(scratch, "utterance-%d.wav" % index))
        if passage:
            passage.extend(gap)
        passage.extend(samples)
        texts.append(key)
        if row_language:
            language = row_language
        if len(passage) >= target_frames:
            yield ("%d sentences" % len(texts), language, texts, passage)
            passage, texts = array.array("h"), []

    # Whatever is left over is a passage only if it is one: the same half-length
    # floor the LibriSpeech side uses, for the same reason.
    if len(passage) >= target_frames // 2:
        yield ("%d sentences" % len(texts), language, texts, passage)


def build(options):
    kind, manifest, out_dir = source_for(options)
    if not os.path.isfile(manifest):
        fetcher = ("tools/fetch-librispeech.sh" if kind == "librispeech"
                   else "tools/fetch-fleurs.sh")
        die("no %s - fetch the split first: %s %s" % (manifest, fetcher, options.split))

    out_manifest = os.path.join(out_dir, "manifest.tsv")
    if os.path.isfile(out_manifest) and not options.force:
        print("%s already exists; --force rebuilds it" % out_manifest)
        return 0
    os.makedirs(out_dir, exist_ok=True)

    gap = array.array("h", bytes(2 * int(SAMPLE_RATE * options.gap)))
    target_frames = int(SAMPLE_RATE * options.seconds)
    collect = librispeech_passages if kind == "librispeech" else fleurs_passages
    lines = []
    total_frames = 0

    with tempfile.TemporaryDirectory(prefix="continuous-corpus-") as scratch:
        for label, language, texts, samples in collect(options, read_manifest(manifest),
                                                       scratch, gap, target_frames):
            name = "passage-%02d.wav" % (len(lines) + 1)
            final = os.path.join(out_dir, name)
            write_pcm16(final, samples)
            total_frames += len(samples)
            lines.append("%s\t%s\t%s" % (final, " ".join(texts), language))
            print("%s  %5.1f s  %d utterances  %s"
                  % (name, len(samples) / SAMPLE_RATE, len(texts), label))
            # Checked after the write, not before the next pull: the generators
            # decode a whole passage before they yield it, so asking for one more
            # only to drop it would decode a chapter for nothing.
            if len(lines) >= options.passages:
                break

    if len(lines) < options.passages:
        print("only %d passage(s) could be built from %s (asked for %d)"
              % (len(lines), options.split, options.passages), file=sys.stderr)
    if not lines:
        die("no passages were built")

    partial = out_manifest + ".part"
    with open(partial, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.replace(partial, out_manifest)
    print("%d passages, %.1f minutes of audio: %s"
          % (len(lines), total_frames / SAMPLE_RATE / 60, out_manifest))
    return 0


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive whole number")
    return number


def positive_float(value):
    number = float(value)
    if not number > 0 or number != number or number == float("inf"):
        raise argparse.ArgumentTypeError("must be a positive number")
    return number


def split_name(value):
    """A LibriSpeech split or a FLEURS directory, checked for shape.

    The value becomes a path component under the corpus directory, so it is held
    to letters, digits, '-' and '_' rather than passed through: 'test-clean',
    'de_de', 'cmn_hans_cn'. Which of the two it names is source_for's decision.
    """
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", value):
        raise argparse.ArgumentTypeError(
            "must be a LibriSpeech split (test-clean, test-other) or a FLEURS "
            "directory (de_de, cmn_hans_cn)")
    return value


def main(argv):
    parser = argparse.ArgumentParser(
        prog=os.path.basename(argv[0]),
        description="Join consecutive utterances into passages of continuous speech.")
    parser.add_argument("--split", default="test-clean", type=split_name,
                        help="the LibriSpeech split (test-clean, test-other) or FLEURS "
                             "directory (de_de) to read (default test-clean)")
    parser.add_argument("--passages", type=positive_int, default=20,
                        help="how many passages (default 20); LibriSpeech takes one per "
                             "chapter and speaker, FLEURS fills each from consecutive sentences")
    parser.add_argument("--seconds", type=positive_float, default=60.0,
                        help="the length a passage grows to before it is closed (default 60)")
    parser.add_argument("--gap", type=positive_float, default=0.3,
                        help="seconds of silence where the corpus cut between utterances (default 0.3)")
    parser.add_argument("--force", action="store_true",
                        help="rebuild an existing corpus")
    parser.add_argument("--speech", default=os.path.join(REPO, "build", "speech"),
                        help="the speech binary whose decoder to use (default build/speech)")
    options = parser.parse_args(argv[1:])
    options.speech = os.path.abspath(options.speech)
    options.corpus_dir = os.path.abspath(
        os.environ.get("SPEECH_CORPUS_DIR") or os.path.join(os.path.expanduser("~"), "Corpora"))
    if not os.access(options.speech, os.X_OK):
        die("no binary at %s - run ./build.sh first, or pass --speech" % options.speech, status=2)
    return build(options)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
