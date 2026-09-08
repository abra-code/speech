#!/usr/bin/env python3
"""Score every model that claims a language against that language's FLEURS split.

This is the general form of the one-off matrices that produced spikes 1, 2 and
4B (Private/spike-*-runs/run.sh), which each hard-coded their models and the
three languages the project started with. Here the model list is derived from
`speech catalog --json` - every transcriber row whose loaded model claims the
language - so adding a language is naming it, and adding a model to the catalog
puts it in the matrix without editing anything.

The intended use is an unattended run over hours or days:

    # what would run, how big the downloads are, how long it will take
    tools/language-battery.py --plan cs_cz uk_ua ru_ru

    # do it, keeping the Mac awake, with a log to read afterwards
    tools/language-battery.py --caffeinate --download cs_cz uk_ua ru_ru 2>&1 | tee battery.log

It is resumable at the cell. A cell that has a summary.json and no failure
marker is skipped, a cell that failed is remembered and skipped too
(--retry-failed to try it again), and a cell interrupted with ^C is left with no
marker at all, so stopping and restarting the next day costs only the cell that
was in flight.

A warning about --wildcard. The three fluid.nemotron-multilingual rows report no
language list - their real one is inside the download - so they are excluded
unless you ask for them. When you do, nothing checks that the model has ever
seen the language: a Nemotron row asked for Xhosa here returned 102% WER rather
than an error, and Canary given no language hint translates to English rather
than refusing. A wildcard cell that comes back with a bad score has not
necessarily measured anything - it may only have transcribed into the wrong
language - so read the transcript in the cell directory before drawing a
conclusion from it.

What this does NOT do: rank anything. It writes WER, CER, RTFx and peak memory
per cell and prints them in a table. Which model to offer a user is Speech.app's
decision, made from measurements taken on the user's own machine - see
docs/catalog.md.

This is a Python program rather than a shell script because the work is: reading
JSON, joining two tables, resolving language tags and formatting a report. The
shell parts - the run loop and the subprocess calls - are the smaller half.
"""

import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time

# External tools by absolute path: this may run under a restricted PATH.
CURL = "/usr/bin/curl"
CAFFEINATE = "/usr/bin/caffeinate"
# Set across the --caffeinate re-exec so the child does not do it again.
CAFFEINATED = "SPEECH_BATTERY_CAFFEINATED"

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
FETCH_FLEURS = os.path.join(REPO, "tools", "fetch-fleurs.sh")
FLEURS_TREE = "https://huggingface.co/api/datasets/google/fleurs/tree/main/data"

# FLEURS names its directories <language>_<region>, sometimes with a script in
# between (cmn_hans_cn, yue_hant_hk). The catalog spells languages the way the
# models do, so the script subtag is dropped and exactly one name needs a real
# override: FLEURS uses ISO 639-3 for Mandarin where every model in the catalog
# says 'zh'.
LANGUAGE_OVERRIDES = {"cmn": "zh"}

# Spellings that mean the same language to different models, most acceptable
# first. Whisper uses the older codes where the rest of the catalog uses the
# current ones, so without these it silently drops out of a Javanese, Filipino
# or Norwegian run - and for Javanese the three Whisper rows are the only ones in
# the catalog that can do the language at all.
#
# This is the part tools/fetch-fleurs.sh cannot have: its manifest column is one
# value for every row, so it stops at the tag and says so in a comment.
#
# The order is the point, and `nn` is the reason these are lists rather than
# sets. Whisper lists Norwegian Bokmal as `no` and Nynorsk as `nn`, and those are
# two written standards, not two spellings of one: forcing a Nynorsk decode
# against FLEURS' Bokmal references would score the writing system, not the
# recognizer. So `nn` is not an alias of `nb` at all, and where a language does
# have several acceptable spellings the first one that a row offers wins.
LANGUAGE_ALIASES = {
    "jv": ["jw"],       # Javanese
    "jw": ["jv"],
    "fil": ["tl"],      # Filipino / Tagalog
    "tl": ["fil"],
    "nb": ["no"],       # Norwegian Bokmal; deliberately not nn
    "no": ["nb"],
    "zh": ["cmn"],      # Mandarin: FLEURS says cmn
    "cmn": ["zh"],
    "he": ["iw"],       # Hebrew, the older code
    "iw": ["he"],
    "id": ["in"],       # Indonesian, the older code
    "in": ["id"],
}

# What one FLEURS test split holds, for planning a language whose audio has not
# been downloaded yet. The three measured here are en_us 1.8h, pl_pl 2.1h and
# de_de 3.2h, so this is their middle rather than a floor: a plan that says four
# hours and takes six is worse than one that says six and takes four.
FLEURS_SPLIT_SECONDS = int(2.5 * 3600)
# and how many rows that is, so --limit can be scaled against a split that has
# not been downloaded yet. Measured: 647, 758 and 862.
FLEURS_SPLIT_ROWS = 750

# The RTFx to assume for a model this machine has never timed. Deliberately
# pessimistic: the slowest row measured here so far is about 5x.
UNMEASURED_RTFX = 5

# Languages whose orthography does not put spaces between words. The scorer
# tokenizes on whitespace, so a WER for one of these is not a word error rate:
# the whole utterance is one token and the number lands near 0 or near 100 with
# nothing in between. CER is the comparable figure there, and it is why the
# summary marks these rather than printing a WER that looks like the others.
# U+200B is a word separator in Thai, Khmer, Lao and Burmese, which the scorer
# already preserves - but the corpus references do not reliably carry it.
UNSPACED = {"zh", "cmn", "yue", "ja", "th", "km", "lo", "my", "bo"}

TABLE_COLUMNS = ["model", "language", "limit", "rows",
                 "wer", "cer", "rtfx", "peak_memory", "load_s"]


class Interrupted(Exception):
    """The user stopped the run. Not a verdict on the cell that was running."""


def _raise_keyboard_interrupt(signum, frame):
    raise KeyboardInterrupt


# ---------------------------------------------------------------------------
# Language tags
# ---------------------------------------------------------------------------

def tag_for(fleurs_dir):
    """'pl_pl' -> 'pl-PL', 'cmn_hans_cn' -> 'zh-CN', 'es_419' -> 'es-419'.

    The same derivation as `language_tag()` in tools/fetch-fleurs.sh, which
    writes it into the manifest's language column. Nothing enforces that the two
    agree, and they have to: `Evaluator` reads a manifest row's own language in
    preference to --language, so a stale copy of this rule wins silently for any
    caller that does not strip the column the way this program does. Change one,
    change the other.

    The region is kept because some models resolve regional variants and the
    others ignore it: the ggml Nemotron rows list 'pl-PL' and 'pt-BR' and reject
    a bare subtag, while Canary, Qwen3-ASR and Whisper are the other way round.
    """
    parts = fleurs_dir.split("_")
    language = LANGUAGE_OVERRIDES.get(parts[0], parts[0])
    region = ""
    if len(parts) > 1:
        last = parts[-1]
        # A 4-letter part is a script (Hans, Hant); drop it. A 2-letter or
        # 3-digit part is a region.
        if len(last) == 2 and last.isalpha():
            region = last.upper()
        elif len(last) == 3 and last.isdigit():
            region = last
    return language + ("-" + region if region else "")


def primary(tag):
    return tag.replace("_", "-").split("-")[0].lower()


def match_tag(wanted, supported):
    """The language tag THIS row understands, or None if it has no such language.

    Mirrors `Language.match` in the tool, which prefers an exact tag, then a bare
    primary subtag, then a regional variant of the same language, and hands back
    the list's own string rather than the caller's. Two things are added here.

    It knows the alias lists, so a Javanese run finds Whisper's `jw`. And it
    prefers the more specific of the two tags when both name the same language: a
    row listing `pl` is handed `pl-PL`, because `Language.match` inside the
    engine will resolve that down again, while a row listing `pl-PL` needs the
    region and a row listing `jw` needs its own spelling instead.
    """
    want = primary(wanted)

    for candidate in supported:
        if candidate.lower() == wanted.lower():
            return candidate                       # exact: pt-BR against pt-BR
    for candidate in supported:
        if primary(candidate) == want and candidate.lower() == want:
            return wanted                          # bare pl, hand back pl-PL
    for candidate in supported:
        if primary(candidate) == want:
            return candidate                       # a regional variant: pt-PT
    for alias in LANGUAGE_ALIASES.get(want, []):
        for candidate in supported:
            if primary(candidate) == alias:
                return candidate                   # an alias: jw for jv
    return None


# ---------------------------------------------------------------------------
# The catalog
# ---------------------------------------------------------------------------

def load_catalog(speech):
    """`speech catalog --json`, read once.

    It is the only thing that knows which rows exist, which languages each loaded
    model claims (spelled the model's way), and what is already on disk. Asking
    it per language would load every engine per language.
    """
    try:
        done = subprocess.run([speech, "catalog", "--json"],
                              stdin=subprocess.DEVNULL,
                              capture_output=True, text=True)
    except OSError as error:
        die("could not run %s: %s" % (speech, error))
    if done.returncode != 0:
        sys.stderr.write(done.stderr)
        die("`%s catalog --json` failed (exit %d)" % (speech, done.returncode))
    try:
        return json.loads(done.stdout)
    except ValueError as error:
        die("could not parse the catalog from %s: %s" % (speech, error))


def rows_for(catalog, fleurs_dir, engines, exclude, wildcard):
    """Every transcriber row whose loaded model claims this language.

    Returns (row, tag) pairs, where the tag is the spelling THAT row understands.
    A single tag for the whole language would hand Whisper `jv` where it only
    knows `jw`, and the run would warn once on stderr and then transcribe into
    the wrong language.

    A row's language list is what the engine reported when the model loaded, not
    a published claim, which is why this is read from the catalog rather than
    from a table here.
    """
    want = tag_for(fleurs_dir)
    chosen = []
    for row in catalog["rows"]:
        if row.get("role") != "transcriber" or not row.get("available", True):
            continue
        rid = row["id"]
        if engines and row.get("engine") not in engines:
            continue
        if any(rid.startswith(prefix) for prefix in exclude):
            continue
        languages = row.get("languages") or []
        if not languages or languages == ["*"]:
            # '*' is "the engine reported no list", not "every language works".
            # See the warning in the module docstring. Only a caller asking for
            # such a row explicitly should get it, and it is handed the corpus
            # tag because there is nothing else to go on.
            if wildcard:
                chosen.append((row, want))
            continue
        tag = match_tag(want, languages)
        if tag is not None:
            chosen.append((row, tag))
    return chosen


def explicit_rows(catalog, model_ids, fleurs_dir):
    """--models named these by hand.

    They still need their install state and download size looked up, or the run
    fails one cell at a time with exit 3 instead of saying up front what is
    missing.
    """
    known = {row["id"]: row for row in catalog["rows"]}
    want = tag_for(fleurs_dir)
    chosen = []
    for rid in model_ids:
        row = known.get(rid)
        if row is None:
            die("no catalog row called '%s'" % rid, status=2)
        languages = row.get("languages") or []
        tag = match_tag(want, languages) if languages and languages != ["*"] else None
        chosen.append((row, tag or want))
    return chosen


# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------

def audio_seconds(corpus_dir, fleurs_dir):
    """Exact total from FLEURS' own sample counts; (0.0, 0) when absent.

    Column 6 of test.tsv is num_samples at 16 kHz, and it matches the
    audio_seconds `speech eval` reports to the second, so the time estimate does
    not have to guess at an average utterance length.
    """
    path = os.path.join(corpus_dir, "fleurs", fleurs_dir, "test.tsv")
    total, rows = 0, 0
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) >= 6 and fields[5].isdigit():
                    total += int(fields[5])
                    rows += 1
    except OSError:
        return 0.0, 0
    return total / 16000.0, rows


def count_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


def fetch_split(corpus_dir, fleurs_dir):
    """tools/fetch-fleurs.sh, with its output left on the terminal."""
    environment = dict(os.environ, SPEECH_CORPUS_DIR=corpus_dir)
    try:
        done = subprocess.run([FETCH_FLEURS, fleurs_dir],
                              stdin=subprocess.DEVNULL, env=environment)
    except OSError as error:
        print("!! could not run %s: %s" % (FETCH_FLEURS, error))
        return False
    return done.returncode == 0


def usable_manifest(corpus_dir, fleurs_dir, allow_fetch):
    """The manifest for a split, fetching or repairing it if that is allowed.

    Returns its path, or None if this language cannot be measured.

    The row-count check runs on every language on every run, not only after a
    fetch. fetch-fleurs.sh writes its manifest with a plain redirect, so an
    interrupted awk leaves a short but non-empty file - and non-empty is exactly
    what a bare existence test accepts, forever after. Checking only after a
    fetch would never see the case this exists for.
    """
    split = os.path.join(corpus_dir, "fleurs", fleurs_dir)
    manifest = os.path.join(split, "manifest.tsv")

    if not (os.path.exists(manifest) and os.path.getsize(manifest) > 0):
        if not allow_fetch:
            print("!! no manifest at %s and --no-fetch was given; skipping %s"
                  % (manifest, fleurs_dir))
            return None
        print("-- fetching the %s split (a few hundred MB)" % fleurs_dir)
        if not fetch_split(corpus_dir, fleurs_dir):
            print("!! could not fetch %s; skipping it" % fleurs_dir)
            return None

    want = count_lines(os.path.join(split, "test.tsv"))
    have = count_lines(manifest)
    if want > 0 and have < want // 2:
        print("!! %s has %d manifest rows for %d audio rows." % (fleurs_dir, have, want))
        if not allow_fetch:
            print("   Rerun tools/fetch-fleurs.sh %s. Skipping it." % fleurs_dir)
            return None
        print("-- rewriting the manifest")
        if not fetch_split(corpus_dir, fleurs_dir):
            print("!! could not repair %s; skipping it" % fleurs_dir)
            return None
        have = count_lines(manifest)
        if have < want // 2:
            print("!! still %d of %d rows; delete %s and refetch. Skipping it."
                  % (have, want, split))
            return None
    return manifest


def strip_language_column(manifest, out_dir, fleurs_dir):
    """A two-column copy of the manifest, so --language governs the run.

    `speech eval --language` is a fallback for rows that do not name a language,
    and fetch-fleurs.sh names one on every row - so the per-row tag computed here
    would never reach the engine. Two columns, and the tag this program chose
    wins. It also means the result does not depend on which version of
    fetch-fleurs.sh produced the corpus.
    """
    stripped = os.path.join(out_dir, "manifest-%s.tsv" % fleurs_dir)
    scratch = "%s.part.%d" % (stripped, os.getpid())
    try:
        with open(manifest, encoding="utf-8", errors="replace") as source, \
                open(scratch, "w", encoding="utf-8") as target:
            rows = 0
            for line in source:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 2:
                    continue
                target.write("%s\t%s\n" % (fields[0], fields[1]))
                rows += 1
        if rows == 0:
            raise ValueError("no rows with a path and a reference")
        os.replace(scratch, stripped)
    except (OSError, ValueError) as error:
        remove(scratch)
        print("!! could not read %s (%s); skipping %s" % (manifest, error, fleurs_dir))
        return None
    return stripped


# ---------------------------------------------------------------------------
# Time estimates
# ---------------------------------------------------------------------------

def known_rtfx(paths):
    """Median measured RTFx per model, from every measurement on this machine.

    RTFx is a property of this machine and this model, not of the language, so a
    figure measured on German predicts the German-sized cost of Ukrainian well
    enough to answer "is this an afternoon or a weekend". Rows this machine has
    never run fall back to a deliberately pessimistic default.

    Both shapes are read: a summaries.tsv written by one of these matrices, and
    the summary.json `speech eval --report` drops in each cell directory. The
    second matters because spike 1 never wrote a TSV, so without it every `fluid`
    row would read as unmeasured.
    """
    seen = {}

    def note(model, value):
        if model and value and value > 0:
            seen.setdefault(model, []).append(value)

    for path in paths:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                if "summary.json" not in files:
                    continue
                try:
                    with open(os.path.join(root, "summary.json"), encoding="utf-8") as handle:
                        summary = json.load(handle)
                except (OSError, ValueError):
                    continue
                note(summary.get("model"), summary.get("rtfx"))
            continue
        # By header, not by position: this battery's table carries a `limit`
        # column that the spike matrices do not, so rtfx is field 5 in one and
        # field 6 in the other. A file with neither header is read as the older
        # layout, which is what those matrices wrote.
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            columns = {"model": 0, "rtfx": 5}
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if fields and fields[0] == "model":
                    columns = {name: i for i, name in enumerate(fields)}
                    continue
                if "rtfx" not in columns or len(fields) <= columns["rtfx"]:
                    continue
                try:
                    note(fields[columns["model"]], float(fields[columns["rtfx"]]))
                except ValueError:
                    continue
    return {model: sorted(values)[len(values) // 2] for model, values in seen.items()}


def rtfx_sources(out_dir):
    """Anything on this machine that has ever recorded an RTFx.

    This battery's own results first, then the stage spikes, as directories so
    the per-cell summary.json files count too.
    """
    sources = [out_dir]
    private = os.path.join(REPO, "Private")
    if os.path.isdir(private):
        for name in sorted(os.listdir(private)):
            if name.startswith("spike-") and "-runs" in name:
                sources.append(os.path.join(private, name))
    return sources


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def human_bytes(size):
    value = float(size)
    for unit in ("B", "KB", "MB"):
        if value < 1024:
            return "%.0f %s" % (value, unit)
        value /= 1024.0
    return "%.1f GB" % value


def human_time(seconds):
    if seconds < 90:
        return "%.0fs" % seconds
    if seconds < 5400:
        return "%.0fm" % (seconds / 60)
    return "%.1fh" % (seconds / 3600)


def die(message, status=1):
    print("%s: %s" % (os.path.basename(sys.argv[0]), message), file=sys.stderr)
    sys.exit(status)


def remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# The results table
# ---------------------------------------------------------------------------

def write_row(cell_dir, model, fleurs_dir, limit):
    """One measured cell as one line of the table.

    Called after a cell runs, and again for a cell that is already done but has
    no row - see rebuild_summaries for why that matters.
    """
    summary_path = os.path.join(cell_dir, "summary.json")
    try:
        with open(summary_path, encoding="utf-8") as handle:
            summary = json.load(handle)
        line = "\t".join([
            model, fleurs_dir, str(limit) if limit else "all",
            str(summary.get("rows")),
            "%.2f" % (summary.get("wer", 0) * 100),
            "%.2f" % (summary.get("cer", 0) * 100),
            "%.1f" % summary.get("rtfx", 0),
            str(summary.get("peak_memory_bytes", 0)),
            "%.1f" % summary.get("load_seconds", 0),
        ])
    except (OSError, ValueError, TypeError) as error:
        print("!! could not summarize %s into a table row: %s" % (summary_path, error),
              file=sys.stderr)
        return False
    scratch = os.path.join(cell_dir, "row.tsv.part.%d" % os.getpid())
    try:
        with open(scratch, "w", encoding="utf-8") as handle:
            handle.write(line + "\n")
        os.replace(scratch, os.path.join(cell_dir, "row.tsv"))
    except OSError as error:
        remove(scratch)
        print("!! could not write %s/row.tsv: %s" % (cell_dir, error), file=sys.stderr)
        return False
    return True


def rebuild_summaries(out_dir):
    """summaries.tsv is derived, never appended to.

    Each cell writes its own row.tsv and the table is rebuilt from those after
    every cell, which makes the file idempotent: a row cannot be duplicated by a
    re-run, and one lost to a process killed mid-write comes back by itself.
    Appending is how the spike matrices did it, and it has no way to repair
    anything.

    It will not publish an empty table over a table that has rows in it. That is
    what would happen if --out were pointed at one of the spike directories: no
    cell has a row.tsv, the rebuild finds nothing, and a measurement nobody can
    repeat without re-running it for hours is gone.
    """
    log = os.path.join(out_dir, "summaries.tsv")
    rows = []
    try:
        names = sorted(os.listdir(out_dir))
    except OSError:
        names = []
    for name in names:
        if not os.path.isdir(os.path.join(out_dir, name)):
            continue
        row_path = os.path.join(out_dir, name, "row.tsv")
        try:
            with open(row_path, encoding="utf-8", errors="replace") as handle:
                rows.extend(line.rstrip("\n") for line in handle if line.strip())
        except OSError:
            continue
    rows.sort()

    if not rows and count_lines(log) > 1:
        print("!! refusing to replace %s with an empty table:" % log, file=sys.stderr)
        print("   it has rows and no cell in %s has a row.tsv to rebuild them from."
              % out_dir, file=sys.stderr)
        print("   Move it aside if that is really what you want.", file=sys.stderr)
        return
    scratch = "%s.part.%d" % (log, os.getpid())
    try:
        with open(scratch, "w", encoding="utf-8") as handle:
            handle.write("\t".join(TABLE_COLUMNS) + "\n")
            for row in rows:
                handle.write(row + "\n")
        os.replace(scratch, log)
    except OSError as error:
        remove(scratch)
        print("!! could not write %s: %s" % (log, error), file=sys.stderr)


def summarize(out_dir):
    """The results, grouped by language and by row limit, most accurate first.

    Sorting a finished measurement table is reading it, not ranking the catalog:
    these numbers are this machine, this month, this corpus. A screening pass and
    a full pass are separate groups because a WER over 20 rows and one over 758
    are not comparable figures.
    """
    log = os.path.join(out_dir, "summaries.tsv")
    columns, groups = None, {}
    try:
        handle = open(log, encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if fields and fields[0] == "model":
                columns = {name: i for i, name in enumerate(fields)}
                continue
            if columns is None or len(fields) < len(columns):
                continue
            key = (fields[columns["language"]], fields[columns["limit"]])
            groups.setdefault(key, []).append(fields)

    if not groups:
        print()
        print("no rows in %s - every cell either failed or was skipped." % log)
        return

    def column(fields, name):
        return fields[columns[name]]

    for language, limit in sorted(groups):
        unspaced = primary(tag_for(language)) in UNSPACED
        print()
        print("== %s%s%s" % (
            language,
            "" if limit == "all" else "   [first %s rows only]" % limit,
            "   [no spaces between words: read cer%, the wer% is not one]" if unspaced else ""))
        print("%-45s %6s %7s %7s %8s %10s" % ("model", "rows", "wer%", "cer%", "rtfx", "peak"))
        metric = "cer" if unspaced else "wer"

        def score(fields):
            try:
                return float(column(fields, metric))
            except ValueError:
                return float("inf")

        for fields in sorted(groups[(language, limit)], key=score):
            peak = column(fields, "peak_memory")
            print("%-45s %6s %7s %7s %8s %10s" % (
                column(fields, "model"), column(fields, "rows"),
                column(fields, "wer"), column(fields, "cer"), column(fields, "rtfx"),
                human_bytes(int(peak)) if peak.isdigit() else peak))


# ---------------------------------------------------------------------------
# One cell
# ---------------------------------------------------------------------------

def cell_slug(model, fleurs_dir, limit):
    slug = re.sub(r"[./@]", "_", model) + "__" + fleurs_dir
    return slug + ("__n%d" % limit if limit else "")


def run_cell(options, model, fleurs_dir, tag, manifest):
    """Measure one model against one language.

    Raises only Interrupted. Everything else - an unreadable marker, a full
    disk, a malformed report - fails this one cell and lets the battery go on,
    because the alternative is a traceback four hours into a multi-day run.
    """
    slug = cell_slug(model, fleurs_dir, options.limit)
    cell_dir = os.path.join(options.out, slug)
    failed_marker = os.path.join(cell_dir, "failed")
    summary_path = os.path.join(cell_dir, "summary.json")

    # The failure marker first, and not summary.json first. `speech eval` writes
    # its report before it throws "no rows could be scored" - deliberately,
    # because the skip reasons in the report are the diagnosis - so a cell that
    # scored nothing has both files. Testing summary.json first would record that
    # permanent failure as a completed cell that --retry-failed could not reach.
    if os.path.exists(failed_marker):
        if not options.retry_failed:
            try:
                with open(failed_marker, encoding="utf-8", errors="replace") as handle:
                    why = handle.read().strip()
            except OSError as error:
                why = "unreadable marker: %s" % error
            print("skip %s (failed earlier: %s; --retry-failed to try again)" % (slug, why))
            return
        remove(summary_path)
        remove(os.path.join(cell_dir, "row.tsv"))
    elif os.path.exists(summary_path):
        print("skip %s (done)" % slug)
        # The table is derived from row.tsv, so a done cell that has none - one
        # measured by an older version, or one whose row was deleted - would
        # silently disappear from it. Rebuild the row rather than drop the
        # measurement.
        row_path = os.path.join(cell_dir, "row.tsv")
        if not os.path.exists(row_path) or os.path.getsize(row_path) == 0:
            if write_row(cell_dir, model, fleurs_dir, options.limit):
                rebuild_summaries(options.out)
        return

    print("=== %s / %s  (%s)" % (model, tag, timestamp()))
    try:
        os.makedirs(cell_dir, exist_ok=True)
    except OSError as error:
        print("FAILED %s (could not create the cell directory: %s)" % (slug, error))
        return
    remove(failed_marker)

    command = [options.speech, "eval", "--model", model, "--manifest", manifest,
               "--language", tag, "--report", cell_dir]
    if options.limit:
        command += ["--limit", str(options.limit)]

    started = now()
    try:
        with open(os.path.join(cell_dir, "stdout.txt"), "w") as out, \
                open(os.path.join(cell_dir, "stderr.txt"), "w") as err:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err)
            try:
                status = child.wait()
            except KeyboardInterrupt:
                # Either ^C, which the terminal already delivered to the whole
                # process group, or the SIGTERM handler above, which the child
                # did NOT receive - so end it here rather than orphaning a
                # multi-gigabyte model that would run to completion unwatched.
                child.terminate()
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                remove(summary_path)
                remove(os.path.join(cell_dir, "row.tsv"))
                raise Interrupted(slug)
    except OSError as error:
        write_failure(failed_marker, "could not run: %s" % error)
        print("FAILED %s (%s)" % (slug, error))
        return

    # SIGINT and SIGTERM only. A signal is not a verdict on the cell, but neither
    # is every signal an interruption: -9 is jetsam killing a multi-gigabyte
    # model under memory pressure and -11 is a segfault, both of which are
    # properties of that cell on this machine. Treating those as "the user
    # stopped me" would abort the whole battery on one bad model, and every
    # restart would abort again at the same cell.
    if status in (-signal.SIGINT, -signal.SIGTERM):
        remove(summary_path)
        remove(os.path.join(cell_dir, "row.tsv"))
        raise Interrupted(slug)

    if status != 0:
        write_failure(failed_marker, "%d %s" % (status, timestamp()))
        print("FAILED %s (exit %d, see %s/stderr.txt)" % (slug, status, cell_dir))
        for line in tail(os.path.join(cell_dir, "stderr.txt"), 3):
            print(line)
        return

    print("    %ds: %s" % (now() - started,
                           (tail(os.path.join(cell_dir, "stdout.txt"), 1) or [""])[0]))
    if write_row(cell_dir, model, fleurs_dir, options.limit):
        rebuild_summaries(options.out)


def write_failure(path, text):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    except OSError:
        pass


def tail(path, count):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []
    return lines[-count:]


def timestamp():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def now():
    return int(time.time())


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def fleurs_languages():
    """The dataset's directory listing, or None when it cannot be reached.

    curl rather than urllib: a stock python3 on macOS frequently has no usable CA
    bundle, which would turn --list into an SSL error for a file curl fetches
    without complaint.
    """
    try:
        done = subprocess.run([CURL, "-fsSL", "--max-time", "30", FLEURS_TREE],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError:
        return None
    if done.returncode != 0:
        return None
    try:
        tree = json.loads(done.stdout)
    except ValueError:
        return None
    return sorted(entry["path"].rsplit("/", 1)[-1]
                  for entry in tree if entry.get("type") == "directory")


def command_list(options, catalog):
    """Every FLEURS language with the number of catalog rows that claim it."""
    names = fleurs_languages()
    if names is None:
        # Offline, or Hugging Face is down. Falling back to what is already
        # downloaded is worth more than an error: it is the set the machine can
        # actually run today.
        root = os.path.join(options.corpus_dir, "fleurs")
        names = sorted(os.listdir(root)) if os.path.isdir(root) else []
        if not names:
            die("could not reach the FLEURS listing and no split is downloaded yet")
        print("(offline: showing only the splits already in %s)" % root)

    print("%-14s %-7s %-9s %-22s %s" % ("fleurs", "tag", "models", "engines", "corpus"))
    for name in names:
        rows = [row for row, _ in rows_for(catalog, name, [], [], False)]
        installed = sum(1 for row in rows if row.get("installed"))
        seconds, count = audio_seconds(options.corpus_dir, name)
        engines = sorted({row.get("engine", "?") for row in rows})
        print("%-14s %-7s %-9s %-22s %s" % (
            name, tag_for(name),
            "%d/%d" % (installed, len(rows)) if rows else "-",
            " ".join(engines) if engines else "(none claims it)",
            "%d rows, %s" % (count, human_time(seconds)) if count else "not fetched"))
    return 0


def command_plan(options, catalog):
    rtfx = known_rtfx(rtfx_sources(options.out))
    total_seconds, missing, cells, guessed = 0.0, {}, 0, False

    for fleurs_dir in options.languages:
        seconds, rows = audio_seconds(options.corpus_dir, fleurs_dir)
        known_size = rows > 0
        if not known_size:
            # A split that is not on disk yet still has to appear in the total,
            # or the headline number is short by however many languages have not
            # been downloaded - the exact case --plan exists to answer.
            seconds, rows, guessed = FLEURS_SPLIT_SECONDS, FLEURS_SPLIT_ROWS, True
        if options.limit:
            # The limit takes the first n rows, so scale by the row fraction
            # rather than assuming every utterance is the mean length. This has
            # to apply to the estimated splits too: without it, --plan --limit 20
            # over a dozen new languages reports days for something under an hour.
            seconds = seconds * min(options.limit, rows) / rows

        if options.models:
            chosen = [row for row, _ in explicit_rows(catalog, options.models, fleurs_dir)]
        else:
            chosen = [row for row, _ in rows_for(catalog, fleurs_dir, options.engines,
                                                 options.exclude, options.wildcard)]
        print("== %s (%s)  %s of audio%s" % (
            fleurs_dir, tag_for(fleurs_dir), human_time(seconds),
            "" if known_size else " (estimated; the split is not on disk yet)"))
        for row in chosen:
            cells += 1
            speed = rtfx.get(row["id"])
            estimate = seconds / (speed if speed else UNMEASURED_RTFX)
            if not row.get("installed") and (row.get("size_bytes") or 0):
                missing[row["id"]] = row["size_bytes"]
            print("   %-45s %-14s %s%s" % (
                row["id"],
                "installed" if row.get("installed") else "NOT INSTALLED",
                human_time(estimate),
                "" if speed else "  (never measured here; assuming %dx)" % UNMEASURED_RTFX))
            total_seconds += estimate
        if not chosen:
            print("   no model in this build claims this language"
                  " (try --wildcard for the rows that report no language list)")
        print()

    footer = ""
    if guessed:
        each = FLEURS_SPLIT_SECONDS
        if options.limit:
            each = each * min(options.limit, FLEURS_SPLIT_ROWS) / FLEURS_SPLIT_ROWS
        footer = " (splits not yet fetched counted at %s each)" % human_time(each)
    print("%d cells, about %s of compute%s" % (cells, human_time(total_seconds), footer))
    if missing:
        print("%d model%s to download, %s:" % (
            len(missing), "" if len(missing) == 1 else "s",
            human_bytes(sum(missing.values()))))
        for rid, size in sorted(missing.items()):
            print("   %-45s %s" % (rid, human_bytes(size)))
    return 0


def install_apple_locale(options, tag):
    """Apple's assets are installed by the OS, per locale, not in the model store.

    Doing it once per language means a locale Apple cannot take costs one message
    rather than one failed cell per Apple row.
    """
    print("-- Apple locale %s" % tag)
    try:
        done = subprocess.run([options.speech, "models", "install-locale", tag],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError as error:
        print("   could not run the installer: %s" % error)
        return False
    for line in (done.stdout + done.stderr).splitlines():
        print("   " + line)
    return done.returncode == 0


def resolve_downloads(options, selection):
    """Settle every download before the first cell of a language runs.

    Discovering a missing model four hours in, having already stopped the run, is
    the worst way to learn it - and the reason --plan prints the whole download
    list up front.
    """
    absent = [(row, tag) for row, tag in selection if not row.get("installed")]
    if not absent:
        return selection

    if options.download:
        keep = []
        for row, tag in selection:
            if row.get("installed"):
                keep.append((row, tag))
                continue
            print("-- downloading %s" % row["id"])
            try:
                done = subprocess.run([options.speech, "models", "download", row["id"]],
                                      stdin=subprocess.DEVNULL)
                ok = done.returncode == 0
            except OSError as error:
                print("!! could not run the downloader: %s" % error)
                ok = False
            if ok:
                keep.append((row, tag))
            else:
                print("!! download failed for %s; dropping it" % row["id"])
        return keep

    if options.skip_missing:
        for row, _ in absent:
            print("skip %s (not installed)" % row["id"])
        return [(row, tag) for row, tag in selection if row.get("installed")]

    print("!! not installed:", file=sys.stderr)
    for row, _ in absent:
        print("     %s" % row["id"], file=sys.stderr)
    print("   Re-run with --download, or --skip-missing to measure only what is", file=sys.stderr)
    print("   on disk. '%s --plan %s' prints the sizes."
          % (os.path.basename(sys.argv[0]), " ".join(options.languages)), file=sys.stderr)
    sys.exit(1)


def command_run(options, catalog):
    os.makedirs(options.out, exist_ok=True)

    print("battery: %s" % " ".join(options.languages))
    print("output:  %s" % options.out)
    print("binary:  %s (%s)" % (options.speech, speech_version(options.speech)))
    print()

    for fleurs_dir in options.languages:
        tag = tag_for(fleurs_dir)
        manifest = usable_manifest(options.corpus_dir, fleurs_dir, not options.no_fetch)
        if manifest is None:
            continue
        manifest = strip_language_column(manifest, options.out, fleurs_dir)
        if manifest is None:
            continue

        if options.models:
            selection = explicit_rows(catalog, options.models, fleurs_dir)
        else:
            selection = rows_for(catalog, fleurs_dir, options.engines,
                                 options.exclude, options.wildcard)
        if not selection:
            print("!! no model in this build claims %s; skipping %s" % (tag, fleurs_dir))
            print("   (--wildcard adds the rows that report no language list at all)")
            continue

        if any(row["id"].startswith("apple.") for row, _ in selection):
            if not install_apple_locale(options, tag):
                print("   dropping the apple rows for this language")
                selection = [(row, rtag) for row, rtag in selection
                             if not row["id"].startswith("apple.")]

        selection = resolve_downloads(options, selection)
        if not selection:
            print("!! nothing left to run for %s" % fleurs_dir)
            continue

        print()
        print("#### %s (%s): %d models" % (fleurs_dir, tag, len(selection)))
        for row, row_tag in selection:
            run_cell(options, row["id"], fleurs_dir, row_tag, manifest)

    print()
    print("BATTERY COMPLETE  (%s)" % timestamp())
    rebuild_summaries(options.out)
    summarize(options.out)
    print()
    print("Cells are in %s; the machine-readable table is %s."
          % (options.out, os.path.join(options.out, "summaries.tsv")))
    return 0


def speech_version(speech):
    try:
        done = subprocess.run([speech, "--version"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True)
    except OSError:
        return "unknown"
    return done.stdout.strip().splitlines()[0] if done.stdout.strip() else "unknown"


# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

def words(values):
    """--engines "apple ggml" and --engines apple --engines ggml mean the same."""
    out = []
    for value in values or []:
        out.extend(value.split())
    return out


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1, not %s" % value)
    return number


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        prog=os.path.basename(argv[0]),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Score every model that claims a language against that "
                    "language's FLEURS test split.",
        epilog="A <fleurs-dir> is a directory name from the FLEURS dataset:\n"
               "pl_pl, cs_cz, uk_ua, pt_br, cmn_hans_cn. --list prints all 102\n"
               "with the number of models that claim each.\n\n"
               "SPEECH_CORPUS_DIR  where FLEURS lives (default ~/Corpora)\n"
               "SPEECH_MODELS_DIR  where model weights live, read by `speech` itself")

    parser.add_argument("languages", nargs="*", metavar="fleurs-dir")
    parser.add_argument("--list", action="store_true",
                        help="list FLEURS languages and how many models claim each, then exit")
    parser.add_argument("--plan", action="store_true",
                        help="print the matrix, the missing downloads and a time estimate; run nothing")
    parser.add_argument("--out", metavar="DIR",
                        help="where cells and summaries.tsv go (default Private/language-battery)")
    # One value per flag, repeatable, and each value may itself be a
    # space-separated list. `nargs="+"` would read better but it is greedy: in
    # `--exclude ggml.whisper pl_pl` argparse hands both words to --exclude and
    # the run ends with no languages at all.
    parser.add_argument("--models", action="append", metavar='"ID..."',
                        help="run exactly these catalog ids instead of selecting by language")
    parser.add_argument("--engines", action="append", metavar='"NAME..."',
                        help="restrict the selection to these engines (apple fluid ggml mlx)")
    parser.add_argument("--exclude", action="append", metavar='"PREFIX..."',
                        help="drop rows whose id starts with any of these: a whole id, "
                             "a family (ggml.qwen3-asr) or a whole engine (mlx)")
    parser.add_argument("--wildcard", action="store_true",
                        help="also run rows that report no language list at all - today the "
                             "three fluid.nemotron-multilingual rows. Read the warning at the "
                             "top of this file before believing a number one produces")
    parser.add_argument("--limit", type=positive, metavar="N",
                        help="score the first N rows of each split only")
    parser.add_argument("--download", action="store_true",
                        help="download missing model weights before running")
    parser.add_argument("--skip-missing", action="store_true",
                        help="skip rows that are not installed instead of stopping")
    parser.add_argument("--retry-failed", action="store_true",
                        help="retry cells that failed on an earlier run")
    parser.add_argument("--no-fetch", action="store_true",
                        help="do not download corpora; skip a language whose split is absent")
    parser.add_argument("--caffeinate", action="store_true",
                        help="re-exec under `caffeinate -i` so the Mac does not sleep mid-run")
    parser.add_argument("--speech", metavar="PATH",
                        help="the binary to measure (default build/speech in this repo)")

    options = parser.parse_args(argv[1:])
    options.models = words(options.models)
    options.engines = words(options.engines)
    options.exclude = words(options.exclude)

    # Relative paths mean "relative to where I typed it". Defaults belong to the
    # repository instead, so the program works from any directory.
    options.speech = (os.path.abspath(options.speech) if options.speech
                      else os.path.join(REPO, "build", "speech"))
    options.out = (os.path.abspath(options.out) if options.out
                   else os.path.join(REPO, "Private", "language-battery"))
    options.corpus_dir = os.path.abspath(
        os.environ.get("SPEECH_CORPUS_DIR") or os.path.join(os.path.expanduser("~"), "Corpora"))
    return parser, options


def main(argv):
    # The documented invocation ends in `| tee battery.log`, and a pipe is not a
    # tty, so Python block-buffers stdout by default. Three things go wrong at
    # once: the parent's own lines appear after the child output they introduce,
    # stderr overtakes stdout entirely, and a run killed by a signal loses the
    # whole buffer - a battery SIGTERMed after six lines left a zero-byte log.
    # `sh`'s echo never had any of these, so this is a translation hazard rather
    # than a preference.
    sys.stdout.reconfigure(line_buffering=True)

    # SIGTERM should end the run the way ^C does rather than killing it silently
    # mid-cell. run_cell's KeyboardInterrupt path does the cleanup for both.
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)

    parser, options = parse_arguments(argv)

    if options.caffeinate and not os.environ.get(CAFFEINATED):
        # -i is idle sleep only: the lid still works. caffeinate becomes the
        # parent of this program rather than a background process it would have
        # to remember to kill.
        #
        # The guard is an environment marker and not a filtered argv, because
        # argparse accepts abbreviations: `--caf` sets the flag just as
        # `--caffeinate` does, and an argv filter looking for the full spelling
        # would leave it in place for the re-exec'd child to act on again. Since
        # caffeinate stays alive as the parent of what it runs, that is an
        # unbounded cascade of live processes, not a tail call.
        if not os.access(CAFFEINATE, os.X_OK):
            die("%s is not available" % CAFFEINATE)
        os.execve(CAFFEINATE,
                  [CAFFEINATE, "-i", sys.executable, os.path.realpath(__file__)] + argv[1:],
                  dict(os.environ, **{CAFFEINATED: "1"}))

    if not os.access(options.speech, os.X_OK):
        die("no binary at %s - run ./build.sh first, or pass --speech <path>"
            % options.speech, status=2)

    catalog = load_catalog(options.speech)

    if options.list:
        return command_list(options, catalog)

    if not options.languages:
        parser.print_usage(sys.stderr)
        die("no languages given", status=2)

    # Reject a name that is not a FLEURS directory before spending an hour on it.
    # The check is offline: a name that is not <lang>_<region> is a typo whatever
    # the dataset holds, and the network check belongs to --list.
    for name in options.languages:
        if "_" not in name:
            die("'%s' is not a FLEURS directory name - they look like pl_pl, cs_cz, "
                "pt_br.\nRun --list for the full set." % name, status=2)

    if options.plan:
        return command_plan(options, catalog)
    return command_run(options, catalog)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Interrupted as interrupted:
        print("\ninterrupted during %s; it will be redone on the next run"
              % interrupted, file=sys.stderr)
        sys.exit(130)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
    except BrokenPipeError:
        # `| head` on a 102-line listing.
        os._exit(0)
