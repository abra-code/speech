#!/bin/sh
# language-battery.sh - score every model that claims a language against that
# language's FLEURS test split, for as many languages as you ask for.
#
# This is the general form of the one-off matrices that produced spikes 1, 2 and
# 4B (Private/spike-*-runs/run.sh), which each hard-coded their models and the
# three languages the project started with. Here the model list is derived from
# `speech catalog --json` - every transcriber row whose loaded model claims the
# language - so adding a language is naming it, and adding a model to the
# catalog puts it in the matrix without editing anything.
#
# The intended use is an unattended run over hours or days:
#
#   # what would run, how big the downloads are, how long it will take
#   tools/language-battery.sh --plan cs_cz uk_ua ru_ru
#
#   # do it, keeping the Mac awake, with a log to read afterwards
#   tools/language-battery.sh --caffeinate --download cs_cz uk_ua ru_ru 2>&1 | tee battery.log
#
# It is resumable at the cell. A cell whose summary.json exists is skipped, and
# a cell that failed is remembered and skipped too (--retry-failed to try it
# again), so interrupting it with ^C and restarting the next day costs only the
# cell that was in flight.
#
# --- usage ---
# Usage:
#   tools/language-battery.sh [options] <fleurs-dir>...
#
# <fleurs-dir> is a directory name from the FLEURS dataset: pl_pl, cs_cz,
# uk_ua, pt_br, cmn_hans_cn. `--list` prints all 102 with the number of models
# that claim each.
#
# Options:
#   --list                 List FLEURS languages and how many models claim each, then exit
#   --plan                 Print the matrix, the missing downloads and a time estimate; run nothing
#   --out <dir>            Where cells and summaries.tsv go (default Private/language-battery)
#   --models "<id>..."     Run exactly these catalog ids instead of selecting by language
#   --engines "<name>..."  Restrict the selection to these engines (apple fluid ggml mlx)
#   --exclude "<prefix>..." Drop rows whose id starts with any of these: a whole id,
#                          a family (ggml.qwen3-asr) or a whole engine (mlx)
#   --wildcard             Also run rows that report no language list at all - today
#                          the three fluid.nemotron-multilingual rows. Read the
#                          warning below before believing a number one produces.
#   --limit <n>            Score the first n rows of each split only
#   --download             Download missing model weights before running
#   --skip-missing         Skip rows that are not installed instead of stopping
#   --retry-failed         Retry cells that failed on an earlier run
#   --no-fetch             Do not download corpora; fail if a split is absent
#   --caffeinate           Re-exec under `caffeinate -i` so the Mac does not sleep
#                          mid-run. Must be the first argument.
#   --speech <path>        The binary to measure (default ./build/speech)
#
# Environment:
#   SPEECH_CORPUS_DIR      Where FLEURS lives (default ~/Corpora), same as fetch-fleurs.sh
#   SPEECH_MODELS_DIR      Where model weights live, read by `speech` itself
# --- end usage ---
#
# A warning about --wildcard. The three fluid.nemotron-multilingual rows report
# no language list - their real one is inside the download - so they are excluded
# unless you ask for them. When you do,
# nothing checks that the model has ever seen the language: a Nemotron row asked
# for Xhosa here returned 102% WER rather than an error, and Canary given no
# language hint translates to English rather than refusing. A wildcard cell that
# comes back with a bad score has not necessarily measured anything - it may
# only have transcribed into the wrong language - so read the transcript in the
# cell directory before drawing a conclusion from it.
#
# What it does NOT do: rank anything. It writes WER, CER, RTFx and peak memory
# per cell and prints them in a table. Which model to offer a user is Speech.app's
# decision, made from measurements taken on the user's own machine - see
# docs/catalog.md.

set -u

# Resolved before the cd, because --caffeinate re-execs this file by name and
# "$0" is usually relative to the directory the user was standing in.
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
invoked_from="$PWD"
cd "$(dirname "$self")/.."

# A relative --out or --speech means "relative to where I typed it", which stops
# being the current directory the moment this script cd's to the repository root.
absolute() {
    case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$invoked_from/$1" ;;
    esac
}

SPEECH=./build/speech
OUT=Private/language-battery
CORPUS_DIR="${SPEECH_CORPUS_DIR:-$HOME/Corpora}"   # made absolute below
LIMIT=""
MODELS=""
ENGINES=""
EXCLUDE=""
WILDCARD=0
DOWNLOAD=0
SKIP_MISSING=0
RETRY_FAILED=0
FETCH=1
PLAN=0
LIST=0

# Between the two sentinels below, so editing the header cannot silently
# truncate --help the way a hard-coded line range did.
# Under `set -u`, "$2" for an option given without a value aborts with a shell
# internal error naming a variable the user never typed.
need_value() {
    [ "$1" -ge 2 ] || { echo "$2 needs a value" >&2; exit 2; }
}

usage() {
    sed -n '/^# --- usage ---/,/^# --- end usage ---/p' "$self" \
        | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

# Before the parse loop, so the re-exec carries every other argument with it.
# -i is idle sleep only: the lid still works, and caffeinate is made the parent
# of this script rather than a background process it would have to remember to
# kill.
case "${1:-}" in
--caffeinate)
    shift
    exec caffeinate -i "$self" "$@"
    ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
    --list) LIST=1; shift ;;
    --plan) PLAN=1; shift ;;
    --out) need_value $# "--out"; OUT="$(absolute "$2")"; shift 2 ;;
    --models) need_value $# "--models"; MODELS="$2"; shift 2 ;;
    --engines) need_value $# "--engines"; ENGINES="$2"; shift 2 ;;
    --exclude) need_value $# "--exclude"; EXCLUDE="$2"; shift 2 ;;
    --wildcard) WILDCARD=1; shift ;;
    --limit) need_value $# "--limit"; LIMIT="$2"; shift 2 ;;
    --download) DOWNLOAD=1; shift ;;
    --skip-missing) SKIP_MISSING=1; shift ;;
    --retry-failed) RETRY_FAILED=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    --speech) need_value $# "--speech"; SPEECH="$(absolute "$2")"; shift 2 ;;
    --caffeinate)
        # Handled before this loop, where it can still see every argument. By
        # the time it reaches here the options to its left have already been
        # parsed into variables that the re-exec would throw away, so this is an
        # error rather than a second chance: silently turning
        # "--limit 20 --caffeinate" into a full multi-day run is the worst way
        # to learn about argument order.
        echo "--caffeinate has to be the first argument" >&2
        exit 2
        ;;
    --help | -h) usage; exit 0 ;;
    -*) echo "unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *) break ;;
    esac
done

# After the parse loop, so it covers the environment default as well as an
# explicit value, and before the first use, which is after the cd to the repo.
CORPUS_DIR="$(absolute "$CORPUS_DIR")"

if [ -n "$LIMIT" ]; then
    # 0 passes a digits-only test and is then rejected by `speech eval`, which
    # would mark every cell in the battery as failed.
    case "$LIMIT" in
    *[!0-9]*) echo "--limit takes a whole number of rows, not '$LIMIT'" >&2; exit 2 ;;
    esac
    if [ "$LIMIT" -lt 1 ]; then
        echo "--limit has to be at least 1" >&2
        exit 2
    fi
fi

# The output path travels to Python as one space-joined field of a list of RTFx
# sources. Rejecting a space up front is honest; quietly producing wrong time
# estimates for the rest of the run is not.
case "$OUT" in
*[[:space:]]*) echo "--out must not contain whitespace: '$OUT'" >&2; exit 2 ;;
esac

if [ ! -x "$SPEECH" ]; then
    echo "no binary at $SPEECH - run ./build.sh first, or pass --speech <path>" >&2
    exit 2
fi

command -v python3 > /dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

# The catalog is read once. It is the only thing that knows which rows exist,
# which languages each loaded model claims (spelled the model's way), and what
# is already on disk, and asking it 40 times would load every engine 40 times.
CATALOG="$(mktemp "${TMPDIR:-/tmp}/speech-catalog.XXXXXX")" || {
    echo "could not create a temporary file in ${TMPDIR:-/tmp}" >&2
    exit 1
}
# EXIT alone would clean up after a ^C as well, but a trap on INT that does not
# exit is worse than no trap: sh runs the handler and RESUMES the loop, so one
# ^C deletes the catalog and then keeps running cells for hours against a file
# that is gone. The signal handler's job is to end the run.
trap 'rm -f "$CATALOG" "$CATALOG.err" "$CATALOG.tree" "$CATALOG.selection" "$CATALOG.locale" \
    "$OUT/summaries.tsv.part.$$" "$OUT"/manifest-*.tsv.part.$$' EXIT
trap 'echo; echo "interrupted" >&2; exit 130' INT TERM
if ! "$SPEECH" catalog --json > "$CATALOG" 2> "$CATALOG.err"; then
    echo "speech catalog --json failed:" >&2
    cat "$CATALOG.err" >&2
    rm -f "$CATALOG.err"
    exit 1
fi
rm -f "$CATALOG.err"

# ---------------------------------------------------------------------------
# The Python side. Three jobs that want structured data: turning a FLEURS
# directory name into a language tag, choosing the rows for a language, and
# estimating how long a cell will take from whatever measurements already exist.
# ---------------------------------------------------------------------------

helper() {
    python3 - "$@" <<'PY'
import json, os, sys

# FLEURS names its directories <language>_<region>, sometimes with a script in
# between (cmn_hans_cn, yue_hant_hk). The catalog spells languages the way the
# models do, so the script subtag is dropped and exactly one name needs a real
# override: FLEURS uses ISO 639-3 for Mandarin where every model in the catalog
# says 'zh'.
LANGUAGE_OVERRIDES = {"cmn": "zh"}

# Spellings that mean the same language to different models, most acceptable
# first. This is the part tools/fetch-fleurs.sh cannot have: its manifest column
# is one value for every row, so it stops at `tag_for` and says so in a comment. Whisper uses the older ISO 639-1 codes where the rest of the catalog
# uses the current ones, so without these it silently drops out of a Javanese,
# Filipino or Norwegian run - and for Javanese it is the ONLY row in the whole
# catalog that can do the language at all.
#
# The order is the point, and `nn` is the reason it is a list rather than a set.
# Whisper lists Norwegian Bokmal as `no` and Nynorsk as `nn`, and those are two
# written standards, not two spellings of one: forcing a Nynorsk decode against
# FLEURS' Bokmal references would score the writing system, not the recognizer.
# So `nn` is not an alias of `nb` at all, and where a language does have several
# acceptable spellings the first one that a row offers wins.
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


def tag_for(fleurs_dir):
    """'pl_pl' -> 'pl-PL', 'cmn_hans_cn' -> 'zh-CN', 'es_419' -> 'es-419'.

    The same derivation as `language_tag()` in tools/fetch-fleurs.sh, which
    writes it into the manifest's language column. Nothing enforces that the two
    agree, and they have to: `Evaluator` reads a manifest row's own language in
    preference to --language, so a stale copy of this rule wins silently for any
    caller that does not strip the column the way this script does. Change one,
    change the other.

    The region is kept because some models resolve regional variants and the
    others ignore it: the ggml Nemotron rows list 'pl-PL' and 'pt-BR' and reject
    a bare subtag, while Canary, Qwen3-ASR and Whisper are the other way round.
    `Language.match` inside the tool resolves either onto the model's own
    spelling, so handing it the most specific tag we have is always safe and is
    sometimes the difference between pt-BR and pt-PT.
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
    prefers the more specific of the two tags when both name the same language:
    a row listing `pl` is handed `pl-PL`, because `Language.match` inside the
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


def rows_for(catalog, fleurs_dir, engines, exclude, wildcard):
    """Every transcriber row whose loaded model claims this language.

    A row's language list is what the engine reported when the model loaded, not
    a published claim, which is why this is read from the catalog rather than
    from a table here. '*' means the engine reported no list at all - true of
    the three fluid.nemotron-multilingual rows, whose real list is inside the
    download - so those are opt-in rather than assumed to cover everything.
    """
    want = tag_for(fleurs_dir)
    chosen = []
    for row in catalog["rows"]:
        if row.get("role") != "transcriber":
            continue
        if not row.get("available", True):
            continue
        rid = row["id"]
        if engines and row.get("engine") not in engines:
            continue
        if any(rid.startswith(e) for e in exclude):
            continue
        languages = row.get("languages") or []
        if not languages or languages == ["*"]:
            # '*' is "the engine reported no list", not "every language works".
            # See the warning at the top of this file. Only a caller asking for
            # such a row explicitly should get it, and it is handed the corpus
            # tag because there is nothing else to go on.
            if wildcard:
                chosen.append((row, want))
            continue
        tag = match_tag(want, languages)
        if tag is not None:
            chosen.append((row, tag))
    return chosen


def audio_seconds(corpus_dir, fleurs_dir):
    """Exact total from FLEURS' own sample counts; 0 when the split is absent.

    Column 6 of test.tsv is num_samples at 16 kHz, and it matches the
    audio_seconds `speech eval` reports to the second, so the time estimate does
    not have to guess at an average utterance length.
    """
    path = os.path.join(corpus_dir, "fleurs", fleurs_dir, "test.tsv")
    if not os.path.exists(path):
        return 0.0, 0
    total, rows = 0, 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 6 and fields[5].isdigit():
                total += int(fields[5])
                rows += 1
    return total / 16000.0, rows


def known_rtfx(paths):
    """Median measured RTFx per model, from every measurement on this machine.

    RTFx is a property of this machine and this model, not of the language, so a
    figure measured on German predicts the German-sized cost of Ukrainian well
    enough to answer "is this an afternoon or a weekend". Rows this machine has
    never run fall back to a deliberately pessimistic default.

    Both shapes are read: a summaries.tsv written by one of these matrices, and
    the summary.json `speech eval --report` drops in each cell directory. The
    second matters because spike 1 never wrote a TSV, so without it every
    `fluid` row would read as unmeasured.
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
        if not os.path.exists(path):
            continue
        # By header, not by position: this battery's table carries a `limit`
        # column that the spike matrices do not, so rtfx is field 5 in one and
        # field 6 in the other. A file with neither header is read as the older
        # layout, which is what those matrices wrote.
        with open(path, encoding="utf-8", errors="replace") as handle:
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
    return {k: sorted(v)[len(v) // 2] for k, v in seen.items()}


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.0f %s" % (n, unit) if unit != "GB" else "%.1f GB" % n
        n /= 1024.0


def human_time(seconds):
    if seconds < 90:
        return "%.0fs" % seconds
    if seconds < 5400:
        return "%.0fm" % (seconds / 60)
    return "%.1fh" % (seconds / 3600)


command = sys.argv[1]
catalog = json.load(open(sys.argv[2], encoding="utf-8"))

if command == "tag":
    print(tag_for(sys.argv[3]))

elif command == "select":
    fleurs_dir, engines, exclude, wildcard = sys.argv[3], sys.argv[4].split(), sys.argv[5].split(), sys.argv[6] == "1"
    for row, tag in rows_for(catalog, fleurs_dir, engines, exclude, wildcard):
        # id, installed, size_bytes, and the language tag THIS row understands.
        # The fourth field is the point: a single tag for the whole language
        # would hand Whisper `jv` where it only knows `jw`, and the run would
        # warn once on stderr and then transcribe into the wrong language.
        print("\t".join([row["id"], "1" if row.get("installed") else "0",
                         str(row.get("size_bytes") or 0), tag]))

elif command == "explicit":
    # --models named these by hand. They still need their install state and
    # download size looked up, or the run fails one cell at a time with exit 3
    # instead of saying up front what is missing.
    known = {row["id"]: row for row in catalog["rows"]}
    want = tag_for(sys.argv[4])
    for rid in sys.argv[3].split():
        row = known.get(rid)
        if row is None:
            print("no catalog row called '%s'" % rid, file=sys.stderr)
            sys.exit(2)
        languages = row.get("languages") or []
        tag = match_tag(want, languages) if languages and languages != ["*"] else want
        print("\t".join([rid, "1" if row.get("installed") else "0",
                         str(row.get("size_bytes") or 0), tag or want]))

elif command == "list":
    # Every FLEURS language with the number of catalog rows that claim it. The
    # answer to "which languages can this build even be measured on".
    corpus_dir, tree_path = sys.argv[3], sys.argv[4]
    if os.path.getsize(tree_path) if os.path.exists(tree_path) else 0:
        tree = json.load(open(tree_path, encoding="utf-8"))
        names = sorted(e["path"].rsplit("/", 1)[-1] for e in tree if e["type"] == "directory")
    else:
        # Offline, or Hugging Face is down. Falling back to what is already
        # downloaded is worth more than an error: it is the set the machine can
        # actually run today.
        root = os.path.join(corpus_dir, "fleurs")
        names = sorted(os.listdir(root)) if os.path.isdir(root) else []
        if not names:
            print("could not reach the FLEURS listing and no split is downloaded yet",
                  file=sys.stderr)
            sys.exit(1)
        print("(offline: showing only the splits already in %s)" % root)
    print("%-14s %-7s %-9s %-22s %s" % ("fleurs", "tag", "models", "engines", "corpus"))
    for name in names:
        rows = [row for row, _ in rows_for(catalog, name, [], [], False)]
        installed = sum(1 for r in rows if r.get("installed"))
        seconds, count = audio_seconds(corpus_dir, name)
        engines = sorted({r["engine"] for r in rows})
        print("%-14s %-7s %-9s %-22s %s" % (
            name, tag_for(name),
            "%d/%d" % (installed, len(rows)) if rows else "-",
            " ".join(engines) if engines else "(none claims it)",
            "%d rows, %s" % (count, human_time(seconds)) if count else "not fetched"))

elif command == "plan":
    corpus_dir, fleurs_dirs = sys.argv[3], sys.argv[4].split()
    engines, exclude, wildcard, limit = sys.argv[5].split(), sys.argv[6].split(), sys.argv[7] == "1", sys.argv[8]
    rtfx = known_rtfx(sys.argv[9].split())
    total_seconds, missing, cells, guessed = 0.0, {}, 0, False
    for fleurs_dir in fleurs_dirs:
        seconds, rows = audio_seconds(corpus_dir, fleurs_dir)
        known_size = rows > 0
        if not known_size:
            # A split that is not on disk yet still has to appear in the total,
            # or the headline number is short by however many languages have not
            # been downloaded - the exact case --plan exists to answer.
            seconds, rows, guessed = FLEURS_SPLIT_SECONDS, FLEURS_SPLIT_ROWS, True
        if limit:
            # The limit takes the first n rows, so scale by the row fraction
            # rather than assuming every utterance is the mean length. This has
            # to apply to the estimated splits too: without it, --plan --limit 20
            # over a dozen new languages reports days for something that takes
            # under an hour.
            seconds = seconds * min(int(limit), rows) / rows
        chosen = [row for row, _ in rows_for(catalog, fleurs_dir, engines, exclude, wildcard)]
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
                  " (try --wildcard for the fluid.nemotron rows)")
        print()
    footer = ""
    if guessed:
        each = FLEURS_SPLIT_SECONDS
        if limit:
            each = each * min(int(limit), FLEURS_SPLIT_ROWS) / FLEURS_SPLIT_ROWS
        footer = " (splits not yet fetched counted at %s each)" % human_time(each)
    print("%d cells, about %s of compute%s" % (cells, human_time(total_seconds), footer))
    if missing:
        print("%d model%s to download, %s:" % (
            len(missing), "" if len(missing) == 1 else "s", human_bytes(sum(missing.values()))))
        for rid, size in sorted(missing.items()):
            print("   %-45s %s" % (rid, human_bytes(size)))

elif command == "summarize":
    # The results, grouped by language and by row limit, most accurate first
    # inside a group. Sorting a finished measurement table is reading it, not
    # ranking the catalog: these numbers are this machine, this month, this
    # corpus. A screening pass and a full pass are separate groups because a WER
    # over 20 rows and one over 758 are not comparable figures.
    path = sys.argv[3]
    if not os.path.exists(path):
        sys.exit(0)
    columns, groups = None, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        fields = line.rstrip("\n").split("\t")
        if fields and fields[0] == "model":
            columns = {name: i for i, name in enumerate(fields)}
            continue
        if columns is None or len(fields) < len(columns):
            continue
        groups.setdefault((fields[columns["language"]], fields[columns["limit"]]), []).append(fields)

    def column(fields, name):
        return fields[columns[name]]

    if not groups:
        print()
        print("no rows in %s - every cell either failed or was skipped." % path)
    for language, limit in sorted(groups):
        unspaced = primary(tag_for(language)) in UNSPACED
        print()
        print("== %s%s%s" % (
            language,
            "" if limit == "all" else "   [first %s rows only]" % limit,
            "   [no spaces between words: read cer%, the wer% is not one]" if unspaced else ""))
        print("%-45s %6s %7s %7s %8s %10s" % ("model", "rows", "wer%", "cer%", "rtfx", "peak"))
        metric = "cer" if unspaced else "wer"
        for fields in sorted(groups[(language, limit)], key=lambda f: float(column(f, metric))):
            peak = column(fields, "peak_memory")
            print("%-45s %6s %7s %7s %8s %10s" % (
                column(fields, "model"), column(fields, "rows"),
                column(fields, "wer"), column(fields, "cer"), column(fields, "rtfx"),
                human_bytes(int(peak)) if peak.isdigit() else peak))
PY
}

if [ "$LIST" -eq 1 ]; then
    # curl, not Python: fetch-fleurs.sh already depends on it, and a stock
    # python3 on macOS frequently has no CA bundle, which turns --list into an
    # SSL error for a file curl fetches without complaint. An empty file means
    # offline, which the helper handles.
    TREE="$CATALOG.tree"
    curl -fsSL --max-time 30 \
        "https://huggingface.co/api/datasets/google/fleurs/tree/main/data" \
        -o "$TREE" 2> /dev/null || : > "$TREE"
    helper list "$CATALOG" "$CORPUS_DIR" "$TREE"
    status=$?
    rm -f "$TREE"
    exit $status
fi

if [ $# -eq 0 ]; then
    echo "no languages given" >&2
    echo >&2
    usage >&2
    exit 2
fi

LANGS="$*"

# Reject a name that is not a FLEURS directory before spending an hour on it.
# The check is offline: a name that is not <lang>_<region> is a typo whatever
# the dataset holds, and the network check belongs to --list.
for fleurs_dir in $LANGS; do
    case "$fleurs_dir" in
    *_*) ;;
    *)
        echo "'$fleurs_dir' is not a FLEURS directory name - they look like pl_pl, cs_cz, pt_br." >&2
        echo "Run 'tools/language-battery.sh --list' for the full set." >&2
        exit 2
        ;;
    esac
done

# Anything on this machine that has ever recorded an RTFx: this battery's own
# results first, then the stage spikes, as directories so the per-cell
# summary.json files count too.
RTFX_SOURCES="$OUT $(ls -d Private/spike-*-runs* 2> /dev/null | tr '\n' ' ')"

if [ "$PLAN" -eq 1 ]; then
    helper plan "$CATALOG" "$CORPUS_DIR" "$LANGS" "$ENGINES" "$EXCLUDE" "$WILDCARD" \
        "${LIMIT:-}" "$RTFX_SOURCES"
    exit $?
fi

mkdir -p "$OUT"
LOG="$OUT/summaries.tsv"

# summaries.tsv is derived, never appended to. Each cell writes its own row.tsv
# and the table is rebuilt from those after every cell, which makes the file
# idempotent: a row cannot be duplicated by a re-run, and one lost to a process
# killed mid-append comes back by itself. Appending is how the spike matrices
# did it, and it has no way to repair anything.
rebuild_summaries() {
    {
        printf 'model\tlanguage\tlimit\trows\twer\tcer\trtfx\tpeak_memory\tload_s\n'
        cat "$OUT"/*/row.tsv 2> /dev/null | sort
    } > "$LOG.part.$$" || { rm -f "$LOG.part.$$"; return 1; }

    # Never publish an empty table over a table that has rows in it. That is
    # what would happen the first time this version resumed a run started by a
    # version that only appended, or if --out were pointed at one of the spike
    # directories: no cell has a row.tsv, the rebuild finds nothing, and a
    # measurement nobody can repeat without re-running it for hours is gone.
    if [ "$(grep -c . "$LOG.part.$$")" -le 1 ] && [ "$(grep -c . "$LOG" 2> /dev/null || true)" -gt 1 ]; then
        echo "!! refusing to replace $LOG with an empty table:" >&2
        echo "   it has rows and no cell in $OUT has a row.tsv to rebuild them from." >&2
        echo "   Move it aside if that is really what you want." >&2
        rm -f "$LOG.part.$$"
        return 1
    fi
    mv "$LOG.part.$$" "$LOG"
}

# One measured cell as one line of the table. Called after a cell runs, and
# again for a cell that is already done but has no row - see rebuild_summaries.
write_row() {
    row_dir="$1"
    python3 - "$row_dir/summary.json" "$2" "$3" "${LIMIT:-all}" > "$row_dir/row.tsv.part.$$" <<'ROW'
import json, sys
d = json.load(open(sys.argv[1]))
print("\t".join([sys.argv[2], sys.argv[3], sys.argv[4], str(d.get("rows")),
    "%.2f" % (d.get("wer", 0) * 100), "%.2f" % (d.get("cer", 0) * 100),
    "%.1f" % d.get("rtfx", 0), str(d.get("peak_memory_bytes", 0)),
    "%.1f" % d.get("load_seconds", 0)]))
ROW
    # Gated on the exit status: an unreadable summary.json otherwise published a
    # zero-byte row.tsv, which counts as "this cell has been summarized" forever
    # while contributing nothing to the table.
    if [ $? -ne 0 ] || [ ! -s "$row_dir/row.tsv.part.$$" ]; then
        rm -f "$row_dir/row.tsv.part.$$"
        echo "!! could not summarize $row_dir/summary.json into a table row" >&2
        return 1
    fi
    mv "$row_dir/row.tsv.part.$$" "$row_dir/row.tsv"
}

# Remove rows from a selection, by exact id or by engine prefix. The obvious
# `grep -v "^$model<TAB>"` puts a model id into a regular expression, where the
# '.' in "ggml.canary" matches any character; awk compares the id field itself,
# as a string. Both print nothing at all when every row is dropped, which is
# what the empty-selection check downstream expects.
drop_model() {
    printf '%s\n' "$1" | awk -F'\t' -v id="$2" 'NF && $1 != id'
}

drop_engine() {
    printf '%s\n' "$1" | awk -F'\t' -v prefix="$2." 'NF && substr($1, 1, length(prefix)) != prefix'
}

# ---------------------------------------------------------------------------
# One cell: one model against one language's split.
# ---------------------------------------------------------------------------

# Its own names throughout: `sh` has no local variables, and `model`,
# `fleurs_dir`, `tag` and `manifest` are all live in the loops that call this.
cell() {
    cell_model="$1"; cell_lang="$2"; cell_tag="$3"; cell_manifest="$4"
    slug="$(echo "$cell_model" | tr './@' '___')__$cell_lang"
    [ -n "$LIMIT" ] && slug="${slug}__n$LIMIT"
    dir="$OUT/$slug"

    # `failed` first, and not summary.json first. `speech eval` writes its report
    # before it throws "no rows could be scored" - deliberately, because the skip
    # reasons in the report are the diagnosis - so a cell that scored nothing has
    # both files. Testing summary.json first would record that permanent failure
    # as a completed cell that --retry-failed could not even reach.
    if [ -f "$dir/failed" ]; then
        if [ "$RETRY_FAILED" -eq 0 ]; then
            echo "skip $slug (failed earlier: $(cat "$dir/failed"); --retry-failed to try again)"
            return 0
        fi
        rm -f "$dir/summary.json" "$dir/row.tsv"
    elif [ -f "$dir/summary.json" ]; then
        echo "skip $slug (done)"
        # The table is derived from row.tsv, so a done cell that has none - a
        # cell measured by an older version of this script, or one whose row was
        # deleted - would silently disappear from it. Rebuild the row instead of
        # dropping the measurement.
        if [ ! -s "$dir/row.tsv" ] && write_row "$dir" "$cell_model" "$cell_lang"; then
            rebuild_summaries
        fi
        return 0
    fi

    echo "=== $cell_model / $cell_tag  ($(date '+%Y-%m-%d %H:%M:%S'))"
    mkdir -p "$dir"
    rm -f "$dir/failed"
    cell_started=$(date +%s)

    set -- eval --model "$cell_model" --manifest "$cell_manifest" \
        --language "$cell_tag" --report "$dir"
    [ -n "$LIMIT" ] && set -- "$@" --limit "$LIMIT"

    # </dev/null because this runs inside a `while read` whose stdin is the
    # selection file. Batch eval does not read stdin today; the day something
    # does, it would silently eat the rest of the matrix.
    "$SPEECH" "$@" < /dev/null > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    cell_status=$?

    # 130 and 143 only. A signal is not a verdict on the cell, but neither is
    # every signal an interruption: 137 is jetsam killing a multi-gigabyte model
    # under memory pressure and 139 is a segfault, both of which are properties
    # of that cell on this machine. Treating those as "the user stopped me"
    # aborted the entire battery on one bad model, and every restart aborted
    # again at the same cell, so the run could never advance past it.
    #
    # A real terminal ^C usually never reaches here at all: SIGINT goes to the
    # whole process group, so the shell's own INT trap fires once the child dies
    # and exits before this line. This covers a signal sent to the child alone.
    case "$cell_status" in
    130 | 143)
        rm -f "$dir/summary.json" "$dir/row.tsv"
        echo "interrupted during $slug; it will be redone on the next run" >&2
        exit 130
        ;;
    esac
    if [ "$cell_status" -ne 0 ]; then
        echo "$cell_status $(date '+%Y-%m-%d %H:%M:%S')" > "$dir/failed"
        echo "FAILED $slug (exit $cell_status, see $dir/stderr.txt)"
        tail -3 "$dir/stderr.txt"
        return 0
    fi
    echo "    $(($(date +%s) - cell_started))s: $(tail -1 "$dir/stdout.txt")"
    write_row "$dir" "$cell_model" "$cell_lang" && rebuild_summaries
}

# ---------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------

echo "battery: $LANGS"
echo "output:  $OUT"
echo "binary:  $SPEECH ($("$SPEECH" --version 2> /dev/null | head -1))"
echo

for fleurs_dir in $LANGS; do
    tag="$(helper tag "$CATALOG" "$fleurs_dir")" || exit 2
    manifest="$CORPUS_DIR/fleurs/$fleurs_dir/manifest.tsv"

    if [ ! -s "$manifest" ]; then
        if [ "$FETCH" -eq 0 ]; then
            echo "!! no manifest at $manifest and --no-fetch was given; skipping $fleurs_dir"
            continue
        fi
        echo "-- fetching the $fleurs_dir split (a few hundred MB)"
        if ! SPEECH_CORPUS_DIR="$CORPUS_DIR" tools/fetch-fleurs.sh "$fleurs_dir"; then
            echo "!! could not fetch $fleurs_dir; skipping it"
            continue
        fi
    fi

    # Every run, not only the one that just fetched. fetch-fleurs.sh writes its
    # manifest with a plain redirect, so an interrupted awk leaves a short but
    # non-empty file - and a non-empty file is exactly what the test above
    # accepts, forever after. Checking only after a fetch would never see the
    # case this exists for. A short manifest is not an error the script can fix,
    # because fetch-fleurs.sh skips a split whose audio is already unpacked; it
    # rewrites the manifest every time, so the repair is to run it again.
    want="$(grep -c . "$CORPUS_DIR/fleurs/$fleurs_dir/test.tsv" 2> /dev/null || true)"
    have="$(grep -c . "$manifest" 2> /dev/null || true)"
    if [ "${want:-0}" -gt 0 ] && [ "${have:-0}" -lt $((want / 2)) ]; then
        echo "!! $fleurs_dir has ${have:-0} manifest rows for ${want:-0} audio rows."
        if [ "$FETCH" -eq 0 ]; then
            echo "   Rerun tools/fetch-fleurs.sh $fleurs_dir. Skipping it."
            continue
        fi
        echo "-- rewriting the manifest"
        if ! SPEECH_CORPUS_DIR="$CORPUS_DIR" tools/fetch-fleurs.sh "$fleurs_dir"; then
            echo "!! could not repair $fleurs_dir; skipping it"
            continue
        fi
        have="$(grep -c . "$manifest" 2> /dev/null || true)"
        if [ "${have:-0}" -lt $((want / 2)) ]; then
            echo "!! still ${have:-0} of ${want:-0} rows; delete"
            echo "   $CORPUS_DIR/fleurs/$fleurs_dir and refetch. Skipping it."
            continue
        fi
    fi

    # `speech eval --language` is a fallback for rows that do not name a
    # language, and fetch-fleurs.sh names one on every row - so the tag computed
    # above would never reach the engine. It matters: FLEURS writes `cmn` for
    # Mandarin, which no model in the catalog claims, and `speech` warns and then
    # transcribes anyway, producing a cell that exits 0 and holds a
    # wrong-language number. Two columns, and --language governs the run.
    stripped="$OUT/manifest-$fleurs_dir.tsv"
    scratch="$stripped.part.$$"
    mkdir -p "$OUT"
    if ! cut -f1,2 "$manifest" > "$scratch" || [ ! -s "$scratch" ]; then
        echo "!! could not read $manifest; skipping $fleurs_dir"
        rm -f "$scratch"
        continue
    fi
    mv "$scratch" "$stripped"
    manifest="$stripped"

    if [ -n "$MODELS" ]; then
        selection="$(helper explicit "$CATALOG" "$MODELS" "$fleurs_dir")" || exit 2
    else
        selection="$(helper select "$CATALOG" "$fleurs_dir" "$ENGINES" "$EXCLUDE" "$WILDCARD")" || exit 2
    fi

    if [ -z "$selection" ]; then
        echo "!! no model in this build claims $tag; skipping $fleurs_dir"
        echo "   (--wildcard adds the rows that report no language list at all)"
        continue
    fi

    # Apple's assets are installed by the OS, per locale, and are not in the
    # model store. Doing it once per language here means a locale Apple cannot
    # take costs one message rather than one failed cell per Apple row.
    if echo "$selection" | cut -f1 | grep -q '^apple\.'; then
        echo "-- Apple locale $tag"
        "$SPEECH" models install-locale "$tag" < /dev/null > "$CATALOG.locale" 2>&1
        status=$?
        sed 's/^/   /' "$CATALOG.locale"
        if [ "$status" -ne 0 ]; then
            echo "   dropping the apple rows for this language"
            selection="$(drop_engine "$selection" apple)"
        fi
    fi

    # Everything that has to be fetched is settled before the first cell runs.
    # Discovering a missing model four hours in, having already stopped the run,
    # is the worst way to learn it - and the reason --plan prints the whole
    # download list up front.
    absent="$(echo "$selection" | awk -F'\t' '$2 == "0" { print $1 }')"
    if [ -n "$absent" ]; then
        if [ "$DOWNLOAD" -eq 1 ]; then
            for model in $absent; do
                echo "-- downloading $model"
                if ! "$SPEECH" models download "$model" < /dev/null; then
                    echo "!! download failed for $model; dropping it"
                    selection="$(drop_model "$selection" "$model")"
                fi
            done
        elif [ "$SKIP_MISSING" -eq 1 ]; then
            for model in $absent; do
                echo "skip $model (not installed)"
                selection="$(drop_model "$selection" "$model")"
            done
        else
            echo "!! not installed:" >&2
            for model in $absent; do echo "     $model" >&2; done
            echo "   Re-run with --download, or --skip-missing to measure only what is" >&2
            echo "   on disk. 'tools/language-battery.sh --plan $LANGS' prints the sizes." >&2
            exit 1
        fi
    fi

    if [ -z "$selection" ]; then
        echo "!! nothing left to run for $fleurs_dir"
        continue
    fi

    echo
    echo "#### $fleurs_dir ($tag): $(echo "$selection" | grep -c .) models"

    # Through a file rather than a pipe: a `while read` on the right of a pipe
    # runs in a subshell, and every assignment it makes - including the ones that
    # would drop a row from the selection - is discarded at the end of it.
    printf '%s\n' "$selection" > "$CATALOG.selection"
    while IFS="$(printf '\t')" read -r model installed size row_tag; do
        [ -n "$model" ] || continue
        cell "$model" "$fleurs_dir" "${row_tag:-$tag}" "$manifest"
    done < "$CATALOG.selection"
done

echo
echo "BATTERY COMPLETE  ($(date '+%Y-%m-%d %H:%M:%S'))"
rebuild_summaries
helper summarize "$CATALOG" "$LOG"
echo
echo "Cells are in $OUT; the machine-readable table is $LOG."
