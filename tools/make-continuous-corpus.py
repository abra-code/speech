#!/usr/bin/env python3
"""Build a corpus of continuous speech from a LibriSpeech split.

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
order, with a short silence where the corpus cut, rebuilds the reading: this
program writes one passage per chapter, each about a minute long, from a
different speaker each time, with the references joined the same way.

    tools/make-continuous-corpus.py                       # 20 passages from test-clean
    tools/make-continuous-corpus.py --split test-other --passages 30 --seconds 90

The output is $SPEECH_CORPUS_DIR/LibriSpeech/continuous-<split>/, holding
passage-NN.wav files and a manifest.tsv in the format `speech eval` reads. The
audio comes from `speech decode`, which is what every engine would receive
anyway, and is written as 16 kHz mono 16-bit PCM. It is deterministic: chapters
are taken in sorted order, so two machines building the same arguments get the
same passages. An existing corpus is left alone unless --force is given.

This does NOT fetch LibriSpeech; tools/fetch-librispeech.sh does.
"""

import argparse
import array
import os
import struct
import subprocess
import sys
import tempfile
import wave

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SAMPLE_RATE = 16000
LANGUAGE = "en-US"

WAVE_FORMAT_PCM = 1
WAVE_FORMAT_IEEE_FLOAT = 3
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


def die(message, status=1):
    print("make-continuous-corpus: %s" % message, file=sys.stderr)
    sys.exit(status)


def read_manifest(path):
    """(audio path, reference) rows in manifest order."""
    rows = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 2 or not fields[0]:
                    continue
                rows.append((fields[0], fields[1]))
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
    for audio, reference in rows:
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


def build(options):
    source_dir = os.path.join(options.corpus_dir, "LibriSpeech", options.split)
    manifest = os.path.join(source_dir, "manifest.tsv")
    if not os.path.isfile(manifest):
        die("no %s - fetch the split first: tools/fetch-librispeech.sh %s" % (manifest, options.split))

    out_dir = os.path.join(options.corpus_dir, "LibriSpeech", "continuous-" + options.split)
    out_manifest = os.path.join(out_dir, "manifest.tsv")
    if os.path.isfile(out_manifest) and not options.force:
        print("%s already exists; --force rebuilds it" % out_manifest)
        return 0
    os.makedirs(out_dir, exist_ok=True)

    gap = array.array("h", bytes(2 * int(SAMPLE_RATE * options.gap)))
    target_frames = int(SAMPLE_RATE * options.seconds)
    lines = []
    speakers_used = set()
    total_frames = 0

    with tempfile.TemporaryDirectory(prefix="continuous-corpus-") as scratch:
        for speaker, chapter, utterances in chapters(read_manifest(manifest)):
            if len(lines) >= options.passages:
                break
            # One passage per speaker as well as per chapter: twenty minutes of
            # three voices would measure those three voices.
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

            number = len(lines) + 1
            name = "passage-%02d.wav" % number
            final = os.path.join(out_dir, name)
            write_pcm16(final, passage)

            total_frames += len(passage)
            speakers_used.add(speaker)
            lines.append("%s\t%s\t%s" % (final, " ".join(texts), LANGUAGE))
            print("%s  %5.1f s  %d utterances  speaker %s chapter %s"
                  % (name, len(passage) / SAMPLE_RATE, len(texts), speaker, chapter))

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


def main(argv):
    parser = argparse.ArgumentParser(
        prog=os.path.basename(argv[0]),
        description="Join consecutive LibriSpeech utterances into passages of continuous speech.")
    parser.add_argument("--split", default="test-clean", choices=("test-clean", "test-other"),
                        help="the LibriSpeech split to read (default test-clean)")
    parser.add_argument("--passages", type=positive_int, default=20,
                        help="how many passages, one per chapter and speaker (default 20)")
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
