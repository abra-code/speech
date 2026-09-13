#!/usr/bin/env python3
"""Turn a language-battery directory into the published benchmark documents.

tools/language-battery.py writes one directory per cell - a model against a
corpus - each with a summary.json. That is the measurement. This is the
report: it reads every cell, ranks the models by accuracy within each corpus,
and writes docs/benchmarks/ - an index, a page per corpus and one TSV holding
every field of every cell.

Two reasons it is a program rather than a hand-written page. A battery is
rerun whenever a model, a dependency or a corpus changes, and prose edited by
hand drifts from the numbers beside it. And these figures belong to one
machine: someone running the battery on an M1 has a different report to write,
not a table to patch, and that is the one this produces for them.

It ranks by error rate only. RTFx and peak memory ride along in every table
because the cost of a top spot is part of reading it, but they are not ranked:
which model to offer a user is Speech.app's decision, made from measurements
taken on the user's own machine (docs/catalog.md).

    tools/battery-report.py                     # Private/language-battery -> docs/benchmarks
    tools/battery-report.py --battery DIR --out DIR
    tools/battery-report.py --check             # is the checked-in report current?

What it cannot recover: summary.json records the machine, the OS and the date
of every cell, but not the versions of the tool and the three engine
dependencies that produced it. Those are read here from the `speech` build in
this tree, which is right when the report is generated from the tree that ran
the battery and wrong otherwise. The documents say so where they print them.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import textwrap

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DEFAULT_BATTERY = os.path.join(REPO, "Private", "language-battery")
DEFAULT_OUT = os.path.join(REPO, "docs", "benchmarks")
DEFAULT_SPEECH = os.path.join(REPO, "build", "speech")
# The helper's pins. It reports them over the wire in its hello, but nothing
# stores them in a summary, so they are read from the source of truth the main
# test suite already pins to project.yml (`helperPinsMatchTheProject`).
HELPER_VERSION = os.path.join(REPO, "Helpers", "speech-mlx", "Sources",
                              "speech-mlx", "Version.swift")

# The corpora this report knows how to introduce, in the order they are
# published. A corpus not listed still appears in the TSV and in its family's
# page under its own id, because a battery that measured something new should
# not have it silently dropped from the report.
FLEURS = "fleurs"
LIBRISPEECH = "librispeech"

CORPORA = {
    "en_us": (FLEURS, "English (en_US)", "en"),
    "de_de": (FLEURS, "German (de_DE)", "de"),
    "es_419": (FLEURS, "Spanish (es_419, Latin America)", "es"),
    "fr_fr": (FLEURS, "French (fr_FR)", "fr"),
    "pl_pl": (FLEURS, "Polish (pl_PL)", "pl"),
    "cmn_hans_cn": (FLEURS, "Mandarin Chinese (cmn_hans_cn)", "zh"),
    "librispeech-test-clean": (LIBRISPEECH, "test-clean", "en"),
    "librispeech-test-other": (LIBRISPEECH, "test-other", "en"),
}

# Same set as the battery's: languages whose orthography puts no space between
# words, where the whitespace-tokenized WER is not a word error rate and CER is
# the comparable figure. Kept here rather than imported because the two tools
# are run separately and a report should not fail because a battery moved.
UNSPACED = {"zh", "cmn", "yue", "ja", "th", "km", "lo", "my", "bo"}

TSV_COLUMNS = [
    "model", "corpus", "language", "resolved_locales", "rows", "skipped",
    "wer_pct", "cer_pct", "rtfx", "audio_seconds", "wall_seconds",
    "load_seconds", "peak_memory_bytes", "peak_footprint_bytes",
    "peak_neural_bytes", "reference_words", "reference_characters",
    "substitutions", "deletions", "insertions", "character_errors", "date",
]


def die(message, status=1):
    print("%s: %s" % (os.path.basename(sys.argv[0]), message), file=sys.stderr)
    sys.exit(status)


def warn(message):
    print("%s: warning: %s" % (os.path.basename(sys.argv[0]), message), file=sys.stderr)


def human_bytes(size):
    """Decimal units, because that is what `speech eval --report` prints.

    A cell's own report.md calls 412,582,776 bytes 413 MB, and a published
    table that called the same measurement 394 MB would read as a second
    measurement rather than a second rendering of the first.
    """
    value = float(size)
    for unit in ("B", "KB", "MB"):
        if value < 1000:
            return "%.0f %s" % (value, unit)
        value /= 1000.0
    return "%.2f GB" % value


def human_hours(seconds):
    if seconds < 3600:
        return "%.0f min" % (seconds / 60)
    return "%.1f h" % (seconds / 3600)


def is_unspaced(corpus, cell):
    tag = CORPORA.get(corpus, (None, None, ""))[2] or cell.get("language", "")
    return tag.split("-")[0].lower() in UNSPACED


# ---------------------------------------------------------------------------
# Reading the battery
# ---------------------------------------------------------------------------

def read_cells(battery_dir):
    """Every finished cell, as (model, corpus, limit, summary).

    The model and the corpus come from the cell's own row.tsv rather than from
    its directory name: the name is a slug with the punctuation flattened, and
    a model id cannot be recovered from it. A cell missing either file is one
    that failed or was interrupted, and is skipped in silence - the battery
    already reported it.
    """
    cells = []
    try:
        names = sorted(os.listdir(battery_dir))
    except OSError as error:
        die("cannot read %s: %s" % (battery_dir, error))
    for name in names:
        cell_dir = os.path.join(battery_dir, name)
        if not os.path.isdir(cell_dir):
            continue
        try:
            with open(os.path.join(cell_dir, "row.tsv"), encoding="utf-8") as handle:
                fields = handle.readline().rstrip("\n").split("\t")
            with open(os.path.join(cell_dir, "summary.json"), encoding="utf-8") as handle:
                summary = json.load(handle)
        except (OSError, ValueError):
            continue
        # A summary that parses to anything but an object is as unusable as
        # one that does not parse; `speech eval` never writes one, and the
        # report should skip it rather than fall over in the ranking.
        if len(fields) < 3 or not isinstance(summary, dict):
            continue
        cells.append({
            "model": fields[0], "corpus": fields[1], "limit": fields[2],
            "cell": name, "summary": summary,
        })
    return cells


def partial_limits(cells):
    """Cells scored over part of a split, which do not belong in a ranking.

    A WER over 20 rows and a WER over 758 are not comparable figures, so a
    screening pass is dropped from the documents and named in the index
    instead of quietly sitting in a table beside full runs.
    """
    return sorted({c["limit"] for c in cells if c["limit"] != "all"})


def by_corpus(cells):
    groups = {}
    for cell in cells:
        if cell["limit"] != "all":
            continue
        groups.setdefault(cell["corpus"], []).append(cell)
    return groups


def rank(cells_in_corpus, corpus):
    """Most accurate first, by CER where a WER would not be a word error rate.

    Ties break on the model id, and on the score as the table prints it rather
    than as it is stored: two rows shown as 5.50% are a tie to every reader of
    the page, and ordering them by the digits underneath would be an ordering
    nothing on the page explains. Throughput is deliberately not a tie-break -
    it is not ranked anywhere in this report.
    """
    metric = "cer" if cells_in_corpus and is_unspaced(
        corpus, cells_in_corpus[0]["summary"]) else "wer"

    def key(cell):
        return (round(cell["summary"].get(metric, 1.0) * 100, 2), cell["model"])

    return sorted(cells_in_corpus, key=key), metric


# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

def one_value(cells, field, render=str):
    """The value of a field every cell agrees on, or every value it does not.

    A battery spread over two machines is a real thing to report, not an error
    to hide behind the first value read.
    """
    values = sorted({str(c["summary"].get(field, "")) for c in cells})
    return " / ".join(render(v) for v in values)


def read_catalog(speech_path):
    """`speech catalog --json`, read once for the versions and the coverage.

    It carries the same environment block that heads docs/models.catalog.tsv,
    which is the project's existing answer to "what produced this file", and
    the language list of every row. A missing or unrunnable binary is not
    fatal: the report is about cells on disk. It is said on stderr, though,
    because the documents then lose their version rows and their "not
    measured" table, and a --check against a report that has them fails for a
    reason nothing else shows.
    """
    try:
        result = subprocess.run([speech_path, "catalog", "--json"],
                                capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as error:
        warn("cannot run %s: %s" % (speech_path, error))
        return {}
    if result.returncode != 0:
        warn("%s catalog --json exited %d: %s"
             % (speech_path, result.returncode, result.stderr.strip()))
        return {}
    try:
        document = json.loads(result.stdout)
    except ValueError as error:
        warn("%s catalog --json is not JSON: %s" % (speech_path, error))
        return {}
    if not isinstance(document, dict):
        warn("%s catalog --json is not a JSON object" % speech_path)
        return {}
    return document


def environment(catalog):
    """The tool and dependency versions, from the build in this tree."""
    block = dict(catalog.get("environment") or {})
    try:
        with open(HELPER_VERSION, encoding="utf-8") as handle:
            source = handle.read()
        for label, name in (("mlx-audio-swift", "mlxAudio"), ("mlx-swift", "mlxSwift")):
            found = re.search(r'%s\s*=\s*"([^"]+)"' % name, source)
            if found:
                block[label] = found.group(1)
    except OSError:
        pass
    return block


def provenance(cells, catalog):
    dates = sorted(c["summary"].get("date", "") for c in cells if c["summary"].get("date"))
    return {
        "machine": one_value(cells, "machine"),
        "os": one_value(cells, "os"),
        "memory": one_value(cells, "physical_memory_bytes", lambda v: (
            "%.2f GB" % (int(v) / 1e9)) if v.isdigit() else v),
        "first": dates[0][:10] if dates else "unknown",
        "last": dates[-1][:10] if dates else "unknown",
        "cells": len(cells),
        "environment": environment(catalog),
    }


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

BANNER = (
    "<!-- Generated by tools/battery-report.py from a language-battery\n"
    "     directory. Do not edit by hand: the next battery run overwrites it. -->\n")


def paragraph(text, width=79):
    """Wrap computed prose the way the hand-written constants are wrapped.

    A paragraph assembled from the data would otherwise come out as one very
    long line beside paragraphs wrapped at 79 columns, and - the reason that
    matters for a checked-in generated document - a battery that moves one
    number would rewrite the whole paragraph as a single changed line instead
    of the line the number is on. Model ids carry hyphens and are longer than
    a column of slack, so neither hyphens nor long words are break points.
    """
    return "\n\n".join(
        textwrap.fill(block, width=width, break_long_words=False,
                      break_on_hyphens=False)
        for block in text.split("\n\n"))


def table(rows):
    """A markdown table from a header row and body rows, already stringified."""
    lines = ["| " + " | ".join(rows[0]) + " |",
             "| " + " | ".join("---" for _ in rows[0]) + " |"]
    for row in rows[1:]:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def accuracy_table(ranked, metric):
    header = ["#", "Model", "WER", "CER", "RTFx", "Peak memory"]
    rows = [header]
    for position, cell in enumerate(ranked, start=1):
        summary = cell["summary"]
        wer = "%.2f%%" % (summary.get("wer", 0) * 100)
        cer = "%.2f%%" % (summary.get("cer", 0) * 100)
        if metric == "cer":
            wer = "(%s)" % wer
        rows.append([
            str(position), "`%s`" % cell["model"], wer, cer,
            "%.1fx" % summary.get("rtfx", 0),
            human_bytes(summary.get("peak_memory_bytes", 0)),
        ])
    return table(rows)


def corpus_facts(cells_in_corpus):
    # The fullest cell describes the split. A cell that skipped a row reports
    # that many fewer rows, seconds and words, and the first cell in directory
    # order is as likely to be that one as any.
    summary = max(cells_in_corpus, key=lambda c: c["summary"].get("rows", 0))["summary"]
    return {
        "rows": summary.get("rows", 0),
        "audio": summary.get("audio_seconds", 0),
        "words": summary.get("reference_words", 0),
        "models": len(cells_in_corpus),
    }


def corpus_section(corpus, cells_in_corpus, title):
    ranked, metric = rank(cells_in_corpus, corpus)
    facts = corpus_facts(cells_in_corpus)
    text = ["## %s" % title, ""]
    text.append("%d models, %d rows, %s of audio, %s reference words." % (
        facts["models"], facts["rows"], human_hours(facts["audio"]),
        "{:,}".format(facts["words"])))
    if metric == "cer":
        text += ["", paragraph(
            "Ranked by CER, the character error rate. The references put a "
            "space between every character while the models write natural "
            "text, so the whitespace-tokenized WER in brackets is not a word "
            "error rate and nothing should be read into its ordering.")]
    skipped = sum(c["summary"].get("skipped", 0) for c in cells_in_corpus)
    if skipped:
        text += ["", paragraph(
            "%d row%s could not be scored in one cell or another and %s left "
            "out of that cell's totals." % (
                skipped, "" if skipped == 1 else "s",
                "was" if skipped == 1 else "were"))]
    text += ["", accuracy_table(ranked, metric), ""]
    return "\n".join(text)


# ---------------------------------------------------------------------------
# The documents
# ---------------------------------------------------------------------------

def spread_paragraph(groups):
    """Why there are eight tables and not one recommendation, from the data.

    Written from the tables rather than asserted beside them: the sentence
    that makes the point in one battery is false in the next one, and a
    generated document has no business carrying a claim it did not check.
    """
    winners = {}
    for corpus in groups:
        ranked, _ = rank(groups[corpus], corpus)
        winners.setdefault(ranked[0]["model"], []).append(corpus)
    if len(winners) == 1:
        return ("One model takes every corpus in this battery, which is worth "
                "reading twice before believing: it usually means the corpora "
                "are more alike than the languages they are in.")
    lines = ["%d corpora, %d different models on top." % (len(groups), len(winners))]
    best = max(winners.values(), key=len)
    if len(best) > 1:
        model = [m for m, c in winners.items() if c is best][0]
        others = len(winners) - 1
        lines.append("`%s` takes %d, and the remaining %d go to %d other row%s."
                     % (model, len(best), len(groups) - len(best), others,
                        "" if others == 1 else "s"))
    # The sharpest version of the point: a model that tops one English corpus
    # and sits well down the table on the other.
    for a, b in (("librispeech-test-clean", "en_us"), ("en_us", "librispeech-test-clean")):
        if a not in groups or b not in groups:
            continue
        top = rank(groups[a], a)[0][0]["model"]
        elsewhere = [c["model"] for c in rank(groups[b], b)[0]]
        if top in elsewhere and elsewhere.index(top) >= 5:
            lines.append("Both English corpora are read speech, and `%s` is "
                         "first on %s and %d%s of %d on %s - which is a fact "
                         "about how alike a model's training data and a test "
                         "set are, not a tie-break." % (
                             top, a, elsewhere.index(top) + 1,
                             ordinal_suffix(elsewhere.index(top) + 1),
                             len(elsewhere), b))
            break
    lines.append("That spread is why all of them are published instead of a "
                 "recommendation.")
    return " ".join(lines)


def ordinal_suffix(number):
    if 10 <= number % 100 <= 20:
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(number % 10, "th")


INDEX_HEAD = """# Benchmarks

One battery of measurements: models from the catalog, each scored against the
test split of a language it claims. The tables rank models by error rate
within one corpus. They do not rank the catalog: the winner changes with the
language, changes again with the corpus, and is rarely the row you would
choose once memory and throughput are part of the question.

Four figures appear in every table. **WER** (word error rate) and **CER**
(character error rate) are how much of the reference text a model got wrong,
counted in whole words and in single characters: lower is better and 0% is a
perfect transcript. **RTFx** (real-time factor) is how many seconds of audio a
model transcribes per second of waiting, so 10x turns an hour of recording into
six minutes and anything above 1x is quicker than listening to it. **Peak
memory** is the most memory the run ever needed at once. Accuracy and speed
pull against each other here, and the tables are sorted on accuracy alone.

**These numbers came off one Mac.** RTFx and load time do not travel to
another one at all, and peak memory only partly. WER and CER mostly do - the
same weights over the same audio make the same mistakes - with two exceptions
worth knowing: the two Apple rows are the operating system's assets and move
with its version, and the arithmetic of a CoreML row - one that runs on Apple's
own inference framework, which is every `fluid.*` model here - belongs to the
generation of Neural Engine that ran it. Read the accuracy as close to a
property of the model and the speed as a property of this machine.
"""

INDEX_READING = """## How to read a table

**WER and CER are corpus-level**: total edits over total reference units, never
the mean of the per-row rates, which would let a three-word utterance outvote a
fifty-word one.

**Scoring normalizes** to NFC (Unicode Normalization Form C, the composed
spelling of a character that can be written more than one way), lowercases in
the reference language's locale, and replaces punctuation and symbols with
spaces, keeping an apostrophe between two letters. Numbers are not normalized,
which is why the FLEURS tooling takes the spelled-out transcription column.
Full rules in the [Measuring section](../../README.md#measuring) of the README.

**RTFx** is audio seconds per wall second of transcription, excluding decoding
and scoring. It is the right measure for comparing two engines on one machine
and the wrong one for predicting how long a progress bar runs.

**Peak memory** is the process's peak physical footprint plus the model the
Neural Engine is holding for it, both from one read of `TASK_VM_INFO`, the
kernel's own accounting for a running process. Peak RSS (resident set size) is
the figure other tools publish and it is deliberately not here: it counts clean
file-backed pages, and three identical runs of one model measured 1.25 GB,
76 MB and 76 MB while this figure sat at 1.29 GB in all three
([protocol.md](../protocol.md)).

**Load time is not in these tables.** It is in measurements.tsv, the
tab-separated table of every figure behind these pages, but it measures
different things in different cells: a CoreML row that has just been downloaded
pays a first-run Neural Engine compile there, and the same row measured an hour
later does not.

**Every engine was handed byte-identical audio**, decoded once by AVFoundation
and resampled to 16 kHz mono, including the Apple engines, which would happily
have opened the original file themselves. That is what makes a comparison
between two rows of one table mean anything.
"""

INDEX_REPRODUCE = """## Reproducing this

    tools/fetch-fleurs.sh en_us de_de es_419 fr_fr pl_pl cmn_hans_cn
    tools/fetch-librispeech.sh
    tools/language-battery.py --plan en de es fr pl zh librispeech-test-clean librispeech-test-other
    tools/language-battery.py --caffeinate --download en de es fr pl zh \\
        librispeech-test-clean librispeech-test-other
    tools/battery-report.py

The battery is resumable at the cell, which is what makes a multi-day run
survive being interrupted. `--plan` prints the matrix, the downloads and the
hours before any of it starts.

The report is not regenerated by `test.sh`, unlike docs/models.catalog.tsv: it
is derived from a battery directory under `Private/`, which is gitignored and
absent from a fresh clone. It is current as of the run named above.
"""


def index_document(groups, prov, catalog, missing, extra, wildcard, limits, notes):
    text = [BANNER, INDEX_HEAD]
    fleurs_count = sum(1 for c in groups if CORPORA.get(c, (FLEURS, c, ""))[0] == FLEURS)

    text.append("## The machine and the software\n")
    env = prov["environment"]
    rows = [["What", "Value"],
            ["Machine", prov["machine"]],
            ["Memory", prov["memory"]],
            ["macOS", prov["os"]],
            ["Measured", "%s to %s" % (prov["first"], prov["last"])],
            ["Cells", "%d model-corpus pairs" % prov["cells"]]]
    for label, key in (("`speech`", "tool"), ("Apple Speech", "apple-speech"),
                       ("FluidAudio", "fluidaudio"), ("transcribe.cpp", "transcribe.cpp"),
                       ("mlx-audio-swift", "mlx-audio-swift"), ("mlx-swift", "mlx-swift")):
        if key in env:
            rows.append([label, str(env[key])])
    if not env:
        rows.append(["Versions", "unknown: no `speech` build to read them from"])
    text.append(table(rows))
    text.append("")
    text.append(paragraph(
        "The machine, the OS and the date are recorded by each cell. The "
        "version rows are not: `speech eval` does not write them into a "
        "summary, so they are read from the build in this tree and are "
        "correct as long as the report is generated from the tree that "
        "ran the battery.") + "\n")

    text.append("## The corpora\n")
    rows = [["Corpus", "Rows", "Audio", "Reference words", "Models scored"]]
    for corpus in sorted(groups, key=corpus_sort_key):
        facts = corpus_facts(groups[corpus])
        rows.append([corpus, str(facts["rows"]), human_hours(facts["audio"]),
                     "{:,}".format(facts["words"]), str(facts["models"])])
    text.append(table(rows))
    text.append("")
    text.append(paragraph("FLEURS - Few-shot Learning Evaluation of Universal "
                "Representations of Speech, published under the Creative "
                "Commons Attribution 4.0 license - is read speech in 102 "
                "languages; the %d here "
                "are the ones this battery has run so far, and naming another "
                "on the battery's command line is all it takes to add one. "
                "LibriSpeech (same license, openslr.org/12) is read English "
                "audiobooks, split into a clean half and a harder one recorded "
                "from less clear speakers. The two splits are ranked apart and "
                "never pooled." % fleurs_count) + "\n")

    text.append("## The top row of each table\n")
    rows = [["Corpus", "Most accurate", "Score", "RTFx", "Peak memory"]]
    for corpus in sorted(groups, key=corpus_sort_key):
        ranked, metric = rank(groups[corpus], corpus)
        best = ranked[0]["summary"]
        rows.append([
            corpus, "`%s`" % ranked[0]["model"],
            "%.2f%% %s" % (best.get(metric, 0) * 100, metric.upper()),
            "%.1fx" % best.get("rtfx", 0),
            human_bytes(best.get("peak_memory_bytes", 0))])
    text.append(table(rows))
    text.append("")
    text.append(paragraph(spread_paragraph(groups)) + "\n")

    text.append(INDEX_READING)

    text.append("## What is not here\n")
    paragraphs = []
    if not catalog:
        paragraphs.append("Nothing here was checked against the catalog: the "
                          "`speech` build in this tree could not be read when the "
                          "report was generated, so a model absent from a table "
                          "may be one that was not run.")
    if missing:
        paragraphs.append("Catalog rows that claim a language and have no cell in "
                          "it. A model absent from a table is a model that was "
                          "not run, not one that lost:")
        where = {}
        for corpus, models in missing.items():
            for model in models:
                where.setdefault(model, []).append(corpus)
        rows = [["Not measured", "Why", "Corpora it claims and has no cell in"]]
        for model in sorted(where):
            rows.append(["`%s`" % model, notes.get(model, "not run"),
                         ", ".join(sorted(where[model], key=corpus_sort_key))])
        paragraphs.append(table(rows))
    elif catalog:
        paragraphs.append("Every catalog row that claims one of these languages "
                          "has a cell in it.")
    if wildcard:
        paragraphs.append("%s %s in no table. %s no language list at all - the "
                          "real one is inside the download - so the battery runs "
                          "%s only under `--wildcard`, where nothing checks that "
                          "the model has ever heard the language and a bad score "
                          "may mean it transcribed into the wrong one." % (
                              ", ".join("`%s`" % m for m in wildcard),
                              "is" if len(wildcard) == 1 else "are",
                              "It reports" if len(wildcard) == 1 else "They report",
                              "it" if len(wildcard) == 1 else "them"))
    if extra:
        paragraphs.append("Measured but no longer in the catalog: %s. Kept because "
                          "the measurement is what removed it." % ", ".join(
                              "`%s`" % m for m in sorted(extra)))
    if limits:
        paragraphs.append("Cells scored over part of a split (%s) are excluded: a "
                          "WER over a screening pass and a WER over a full split "
                          "are not comparable figures." % ", ".join(limits))
    # Everything in this section is prose except the coverage table, which
    # must not be reflowed.
    text.append("\n\n".join(
        block if block.startswith("|") else paragraph(block)
        for block in paragraphs))
    text.append("")

    text.append(INDEX_REPRODUCE)

    text.append("## The files\n")
    files = [["File", "What is in it"]]
    if fleurs_count:
        files.append(["[fleurs.md](fleurs.md)",
                      "%d FLEURS language%s, one ranking each" % (
                          fleurs_count, "" if fleurs_count == 1 else "s")])
    if has_family(groups, LIBRISPEECH):
        files.append(["[librispeech.md](librispeech.md)",
                      "test-clean, test-other, and how far each model falls "
                      "between them"])
    files.append(["[measurements.tsv](measurements.tsv)",
                  "Every cell, every field, tab separated"])
    text.append(table(files))
    text.append("")
    return "\n".join(text)


FLEURS_HEAD = """# FLEURS

Read speech from the FLEURS test splits (CC-BY-4.0), one ranking per language,
most accurate first. Every row in a table was scored against the whole split.

Read [README.md](README.md) first for the machine these came off, what the
columns mean and what is missing from them.
"""

LIBRISPEECH_HEAD = """# LibriSpeech

Read English audiobooks from the LibriSpeech test splits (CC-BY-4.0,
openslr.org/12), most accurate first. `test-clean` and `test-other` are split
by speaker: the speakers a baseline recognizer transcribed worst went to
test-other, which makes it the harder split by design. They are ranked apart,
because a pooled number would hide exactly the difference they exist to show.

Read [README.md](README.md) first for the machine these came off, what the
columns mean and what is missing from them.
"""


def has_family(groups, family):
    """Whether this battery measured anything in a corpus family.

    A battery over FLEURS alone should not publish a LibriSpeech page that is
    a heading and nothing else, nor an index that links to one.
    """
    return any(CORPORA.get(corpus, (FLEURS, corpus, ""))[0] == family
               for corpus in groups)


def corpus_sort_key(corpus):
    family = CORPORA.get(corpus, (FLEURS, corpus, ""))[0]
    order = list(CORPORA).index(corpus) if corpus in CORPORA else len(CORPORA)
    return (0 if family == FLEURS else 1, order, corpus)


def family_document(groups, family, head):
    text = [BANNER, head]
    for corpus in sorted(groups, key=corpus_sort_key):
        if CORPORA.get(corpus, (FLEURS, corpus, ""))[0] != family:
            continue
        title = CORPORA.get(corpus, (family, corpus, ""))[1]
        text.append(corpus_section(corpus, groups[corpus], title))
    return "\n".join(text)


def degradation_section(groups):
    """How far each model falls from test-clean to test-other.

    A ratio rather than a difference: a row going from 1.4% to 2.9% has lost
    more of what it had than one going from 7.6% to 9.1%, and the difference
    says the opposite.
    """
    clean = {c["model"]: c["summary"] for c in groups.get("librispeech-test-clean", [])}
    other = {c["model"]: c["summary"] for c in groups.get("librispeech-test-other", [])}
    shared = sorted(set(clean) & set(other))
    if not shared:
        return ""
    entries = []
    for model in shared:
        a, b = clean[model].get("wer", 0), other[model].get("wer", 0)
        entries.append((b / a if a else float("inf"), model, a, b))
    entries.sort()
    rows = [["#", "Model", "clean WER", "other WER", "other / clean"]]
    for position, (ratio, model, a, b) in enumerate(entries, start=1):
        rows.append([str(position), "`%s`" % model, "%.2f%%" % (a * 100),
                     "%.2f%%" % (b * 100), "%.2fx" % ratio])
    return "\n".join([
        "## Falling from clean to other", "",
        paragraph(
            "The same %d models, ranked by how much of their accuracy survives "
            "the harder split. This is a different ordering from either table "
            "above: the most accurate model on clean speech is not always the "
            "one that holds up best when the speech gets worse." % len(entries)), "",
        paragraph(
            "Read it beside the clean column rather than on its own. The ratio "
            "is kindest to a model that had little to lose - a row already at "
            "8% on clean speech can double and still be nowhere near the top "
            "of the test-other table."), "",
        table(rows), ""])


# ---------------------------------------------------------------------------
# The TSV
# ---------------------------------------------------------------------------

def tsv_document(cells, prov):
    env = prov["environment"]
    lines = ["# Produced by:",
             "#   tool: %s" % env.get("tool", "unknown"),
             "#   report: tools/battery-report.py",
             "#   machine: %s" % prov["machine"],
             "#   macos: %s" % prov["os"],
             "#   measured: %s to %s" % (prov["first"], prov["last"])]
    for label, key in (("apple-speech", "apple-speech"), ("fluidaudio", "fluidaudio"),
                       ("transcribe.cpp", "transcribe.cpp"),
                       ("mlx-audio-swift", "mlx-audio-swift"), ("mlx-swift", "mlx-swift")):
        if key in env:
            lines.append("#   %s: %s" % (label, env[key]))
    lines += [
        "#",
        "# measurements.tsv - every cell of the battery. One row per model and",
        "# corpus. Generated by tools/battery-report.py; do not edit by hand.",
        "#",
        "# wer_pct and cer_pct are corpus-level percentages: total edits over",
        "# total reference units. rtfx, wall_seconds and load_seconds belong to",
        "# the machine named above and to nothing else. peak_memory_bytes is",
        "# footprint plus Neural Engine and is the figure to compare; there is",
        "# deliberately no peak RSS column (docs/protocol.md says why).",
        "# Substitutions, deletions and insertions are word-level;",
        "# character_errors is the character-level total behind cer_pct.",
        "#",
        "\t".join(TSV_COLUMNS),
    ]
    for cell in sorted(cells, key=lambda c: (corpus_sort_key(c["corpus"]), c["model"])):
        summary = cell["summary"]
        lines.append("\t".join([
            cell["model"], cell["corpus"],
            str(summary.get("language", "-")),
            str(summary.get("resolved_locales", "-")),
            str(summary.get("rows", 0)), str(summary.get("skipped", 0)),
            "%.2f" % (summary.get("wer", 0) * 100),
            "%.2f" % (summary.get("cer", 0) * 100),
            "%.1f" % summary.get("rtfx", 0),
            "%.1f" % summary.get("audio_seconds", 0),
            "%.1f" % summary.get("wall_seconds", 0),
            "%.2f" % summary.get("load_seconds", 0),
            str(summary.get("peak_memory_bytes", 0)),
            str(summary.get("peak_footprint_bytes", "-")),
            str(summary.get("peak_neural_bytes", "-")),
            str(summary.get("reference_words", 0)),
            str(summary.get("reference_characters", 0)),
            str(summary.get("substitutions", 0)),
            str(summary.get("deletions", 0)),
            str(summary.get("insertions", 0)),
            str(summary.get("character_errors", 0)),
            str(summary.get("date", "-")),
        ]))
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------

def coverage(cells, groups, catalog):
    """Which catalog rows claim a corpus's language and have no cell in it.

    A published table that silently omits a model reads as a model that lost.
    This is what turns it back into a model that was not run. A catalog that
    could not be read leaves every set empty rather than guessing; the index
    says so in that case.

    The third set is the rows with no language list, which the battery runs
    only under --wildcard: named so that their absence from every table is
    not read as an omission. The fourth is why a row was not run, where the
    catalog knows - a row nobody downloaded and a row this build cannot run
    are both absent from every table for reasons that are not about accuracy.
    """
    missing, extra, notes = {}, set(), {}
    if not catalog:
        return missing, extra, [], notes
    transcribers = [r for r in catalog.get("rows", []) if r.get("role") == "transcriber"]
    known = {r["id"] for r in transcribers}
    measured_anywhere = {c["model"] for c in cells}
    wildcard = sorted(r["id"] for r in transcribers
                      if (not r.get("languages") or r.get("languages") == ["*"])
                      and r["id"] not in measured_anywhere)
    for corpus, cells_in_corpus in groups.items():
        measured = {c["model"] for c in cells_in_corpus}
        extra |= measured - known
        tag = CORPORA.get(corpus, (None, None, ""))[2]
        if not tag:
            continue
        claims = {r["id"] for r in transcribers
                  if tag in [lang.split("-")[0] for lang in r.get("languages", [])]}
        absent = claims - measured
        if absent:
            missing[corpus] = absent
    for row in transcribers:
        if not row.get("available", True):
            notes[row["id"]] = "not available in this build"
        elif not row.get("installed", True):
            notes[row["id"]] = "weights not downloaded"
    return missing, extra, wildcard, notes


# ---------------------------------------------------------------------------

def write(path, text, check):
    """Write a document, or under --check report whether it would change."""
    try:
        with open(path, encoding="utf-8") as handle:
            current = handle.read()
    except OSError:
        current = None
    if current == text:
        return True
    if check:
        print("stale: %s" % os.path.relpath(path, REPO))
        return False
    scratch = "%s.part.%d" % (path, os.getpid())
    try:
        with open(scratch, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(scratch, path)
    except OSError as error:
        try:
            os.remove(scratch)
        except OSError:
            pass
        die("could not write %s: %s" % (path, error))
    print("wrote %s" % os.path.relpath(path, REPO))
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Turn a language-battery directory into docs/benchmarks.")
    parser.add_argument("--battery", default=DEFAULT_BATTERY,
                        help="the battery directory to read (default %s)"
                             % os.path.relpath(DEFAULT_BATTERY, REPO))
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="where the documents go (default %s)"
                             % os.path.relpath(DEFAULT_OUT, REPO))
    parser.add_argument("--speech", default=DEFAULT_SPEECH,
                        help="the binary to read versions and the catalog from")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; exit 1 if a document is out of date")
    options = parser.parse_args()

    cells = read_cells(options.battery)
    if not cells:
        die("no finished cells in %s - nothing to report." % options.battery)
    groups = by_corpus(cells)
    if not groups:
        die("every cell in %s was scored over part of a split; nothing to rank."
            % options.battery)
    full = [c for c in cells if c["limit"] == "all"]
    catalog = read_catalog(options.speech)
    prov = provenance(full, catalog)
    missing, extra, wildcard, notes = coverage(full, groups, catalog)
    limits = partial_limits(cells)

    if not options.check:
        try:
            os.makedirs(options.out, exist_ok=True)
        except OSError as error:
            die("cannot create %s: %s" % (options.out, error))

    # A section ends in one newline; the blank line that separates the last
    # table from the degradation heading has to be put there.
    degradation = degradation_section(groups)
    documents = [("README.md", index_document(groups, prov, catalog, missing,
                                              extra, wildcard, limits, notes))]
    if has_family(groups, FLEURS):
        documents.append(("fleurs.md", family_document(groups, FLEURS, FLEURS_HEAD)))
    if has_family(groups, LIBRISPEECH):
        documents.append(("librispeech.md",
                          family_document(groups, LIBRISPEECH, LIBRISPEECH_HEAD)
                          + ("\n" + degradation if degradation else "")))
    documents.append(("measurements.tsv", tsv_document(full, prov)))
    current = True
    for name, text in documents:
        if not write(os.path.join(options.out, name), text, options.check):
            current = False
    if options.check and not current:
        die("the checked-in report does not match %s. Run tools/battery-report.py."
            % os.path.relpath(options.battery, REPO), 1)
    if options.check:
        print("docs/benchmarks is current.")


if __name__ == "__main__":
    main()
