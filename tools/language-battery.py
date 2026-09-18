#!/usr/bin/env python3
"""Score every model that claims a language against that language's test split:
FLEURS, or LibriSpeech for English (`librispeech-test-clean`, `librispeech-test-other`).

This is the general form of the one-off matrices that produced spikes 1, 2 and
4B (Private/spike-*-runs/run.sh), which each hard-coded their models and the
three languages the project started with. Here the model list is derived from
`speech catalog --json` - every transcriber row whose loaded model claims the
language - so adding a language is naming it, and adding a model to the catalog
puts it in the matrix without editing anything.

Languages are named by tag - `es`, `es-ES`, `pt-BR`, `zh` - and resolved to the
FLEURS directory holding them, so nobody has to know that Spanish is filed under
es_419 or Mandarin under cmn_hans_cn. Those directory names still work where a
script already uses them. `--list` prints every one of them. The intended use is an
unattended run over hours or days:

    # what would run, how big the downloads are, how long it will take
    tools/language-battery.py --plan cs uk ru

    # do it, keeping the Mac awake, with a log to read afterwards. Audio is
    # fetched as needed with or without --download, which is about model weights
    # (--no-fetch is what declines the audio).
    tools/language-battery.py --caffeinate --download cs uk ru 2>&1 | tee battery.log

It is resumable at the cell. A cell that has a summary.json and no failure
marker is skipped, a cell that failed is remembered and skipped too
(--retry-failed to try it again), and a cell interrupted with ^C is left with no
marker at all, so stopping and restarting the next day costs only the cell that
was in flight.

Each macOS version measures into a directory of its own:
Private/language-battery/macos-26.6.2, Private/live-battery/macos-26.6.2. Apple's
two engines are part of the operating system, so the same row on a newer macOS is
a different measurement, and resuming would otherwise skip it as done - or a
fresh run would mix two systems in one table. A directory named with --out that
already holds cells from another macOS version is refused for the same reason.
tools/battery-report.py reads every version's directory.

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

LibriSpeech is the second corpus, English-only. `librispeech-test-clean` and
`librispeech-test-other` name its splits the way a FLEURS directory names a
language, and each scores every model that claims English - the splits are
kept apart because test-other is the harder one and a joint number would hide
that. tools/fetch-librispeech.sh downloads a split from openslr.org/12 into
$SPEECH_CORPUS_DIR/LibriSpeech and writes the manifest the cells read; a run
calls it on demand when the manifest is missing, as it does fetch-fleurs.sh.

Live mode, --live, measures `speech eval --live` instead: each row's audio is
played to a live session at the speed it was spoken, so a cell costs the length
of its audio whatever the model's speed, and only rows that can stream are
selected. It belongs with `librispeech-continuous-test-clean` (and -test-other):
minute-long passages of one reader, joined from consecutive utterances of a
chapter by tools/make-continuous-corpus.py, which a run calls on demand. Single
sentences are the easy case for a live session - one boundary to find, and the
audio ends where the speaker does - and on continuous speech the Parakeet
Unified latency tiers ranked differently.

LibriSpeech is English, so every other language's continuous corpus comes from
FLEURS instead: `fleurs-continuous-de_de`, or `continuous-de`, which resolves by
the same rules a plain language name does. FLEURS is not a reading - its rows
are unrelated sentences, each recorded by several speakers in consecutive rows -
so a passage there is consecutive distinct sentences in changing voices. It is
the weaker corpus of the two for that reason, and it is still the one that
answers the question the English corpus answers: what a row does with a minute
of speech that has no cut edges in it. `continuous-en` builds one from FLEURS
English as well; it is not what English is published on, because the LibriSpeech
corpus beside it is a real reading. Live cells and their table go to
Private/live-battery and add the live measurements: the medians of time to first
partial, final lag and finish time, trailing words lost and dropped buffers. The
three fluid.nemotron-multilingual chunk tiers report no language list, so they
still need --wildcard.

This is a Python program rather than a shell script because the work is: reading
JSON, joining two tables, resolving language tags and formatting a report. The
shell parts - the run loop and the subprocess calls - are the smaller half.
"""

import argparse
import datetime
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
import wave

# External tools by absolute path: this may run under a restricted PATH.
CURL = "/usr/bin/curl"
CAFFEINATE = "/usr/bin/caffeinate"
# Set across the --caffeinate re-exec so the child does not do it again.
CAFFEINATED = "SPEECH_BATTERY_CAFFEINATED"

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
FETCH_FLEURS = os.path.join(REPO, "tools", "fetch-fleurs.sh")
FETCH_LIBRISPEECH = os.path.join(REPO, "tools", "fetch-librispeech.sh")
FLEURS_TREE = "https://huggingface.co/api/datasets/google/fleurs/tree/main/data"

# Every directory under that tree, as of the 2022 release. FLEURS is a published,
# frozen dataset - 102 languages, unchanged since - so this is baked in rather
# than fetched: it lets a language tag be resolved to a directory offline and
# instantly, which is the difference between `--plan es` working on a plane and
# not. It is only a lookup table. A name that is not in it but looks like a
# FLEURS directory is still passed through untouched, so a future release that
# adds a language needs no edit here to be usable.
FLEURS_DIRECTORIES = [
    "af_za", "am_et", "ar_eg", "as_in", "ast_es", "az_az", "be_by", "bg_bg",
    "bn_in", "bs_ba", "ca_es", "ceb_ph", "ckb_iq", "cmn_hans_cn", "cs_cz",
    "cy_gb", "da_dk", "de_de", "el_gr", "en_us", "es_419", "et_ee", "fa_ir",
    "ff_sn", "fi_fi", "fil_ph", "fr_fr", "ga_ie", "gl_es", "gu_in", "ha_ng",
    "he_il", "hi_in", "hr_hr", "hu_hu", "hy_am", "id_id", "ig_ng", "is_is",
    "it_it", "ja_jp", "jv_id", "ka_ge", "kam_ke", "kea_cv", "kk_kz", "km_kh",
    "kn_in", "ko_kr", "ky_kg", "lb_lu", "lg_ug", "ln_cd", "lo_la", "lt_lt",
    "luo_ke", "lv_lv", "mi_nz", "mk_mk", "ml_in", "mn_mn", "mr_in", "ms_my",
    "mt_mt", "my_mm", "nb_no", "ne_np", "nl_nl", "nso_za", "ny_mw", "oc_fr",
    "om_et", "or_in", "pa_in", "pl_pl", "ps_af", "pt_br", "ro_ro", "ru_ru",
    "sd_in", "sk_sk", "sl_si", "sn_zw", "so_so", "sr_rs", "sv_se", "sw_ke",
    "ta_in", "te_in", "tg_tj", "th_th", "tr_tr", "uk_ua", "umb_ao", "ur_pk",
    "uz_uz", "vi_vn", "wo_sn", "xh_za", "yo_ng", "yue_hant_hk", "zu_za",
]

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

# LibriSpeech splits this battery knows, as found under
# $SPEECH_CORPUS_DIR/LibriSpeech. test-other is read from the same books by
# less clear speakers, so the two are ranked apart, never pooled.
LIBRISPEECH_SPLITS = ("test-clean", "test-other")
# The battery id for a split. It reads as a language in the table because the
# table is keyed by language, and it sorts nowhere near a FLEURS directory.
LIBRISPEECH_PREFIX = "librispeech-"
# LibriSpeech is English-only, so every split is scored with this tag.
LIBRISPEECH_TAG = "en-US"
# What one LibriSpeech split holds, for planning one whose audio is not on
# disk yet. Measured here: test-clean 2620 rows and 5.4h, test-other 2939 rows
# and 5.3h. A plan over a missing split is an estimate either way; this keeps
# it from vanishing from the total the way an unlisted split would.
LIBRISPEECH_SPLIT_ROWS = 2800
LIBRISPEECH_SPLIT_SECONDS = int(5.4 * 3600)

# The continuous-speech corpora tools/make-continuous-corpus.py builds, named
# after the split each is joined from: `librispeech-continuous-<split>`, English
# like its source, and `fleurs-continuous-<directory>` for every other language.
# The size is the builder's default, the same for both, for planning one not
# built yet: 20 passages, each closed by the utterance that crosses a minute,
# which came to 21.6 minutes from test-clean.
CONTINUOUS_PREFIX = "librispeech-continuous-"
CONTINUOUS_FLEURS_PREFIX = "fleurs-continuous-"
MAKE_CONTINUOUS = os.path.join(REPO, "tools", "make-continuous-corpus.py")
CONTINUOUS_ROWS = 20
CONTINUOUS_SECONDS = 22 * 60

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
# A live cell adds what only a live run measures: the medians of the three
# latencies, and the two ways a session loses words without an error. Its rtfx
# describes the playback clock, not the model, and is kept only so the two
# tables share their first columns.
LIVE_TABLE_COLUMNS = TABLE_COLUMNS + ["first_partial_s", "final_lag_s", "finish_s",
                                      "trailing_words_lost", "dropped_buffers"]


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


def librispeech_split(name):
    """The LibriSpeech split a battery name asks for, or None.

    `librispeech-test-clean` is the canonical spelling; `test-clean`,
    `ls-test-clean` and the `_`- and `/`-separated forms mean the same, so a
    hand-typed run does not fail on the prefix. Anything else - in particular
    every FLEURS directory - is not one.
    """
    wanted = name.strip().lower().replace("_", "-").replace("/", "-")
    for prefix in (LIBRISPEECH_PREFIX, "ls-"):
        if wanted.startswith(prefix):
            wanted = wanted[len(prefix):]
            break
    if wanted in LIBRISPEECH_SPLITS:
        return wanted
    return None


def librispeech_id(split):
    """The battery id for a LibriSpeech split: what the table is keyed by."""
    return LIBRISPEECH_PREFIX + split


def is_librispeech(fleurs_dir):
    """Whether a resolved battery id names a LibriSpeech split, not FLEURS."""
    return librispeech_split(fleurs_dir) is not None


def continuous_split(name):
    """The LibriSpeech split a continuous-corpus name is built from, or None.

    `librispeech-continuous-test-clean` is the canonical spelling, and
    `continuous-test-clean` means the same. librispeech_split does not match
    either, because what follows its prefix is not a split name.
    """
    wanted = name.strip().lower().replace("_", "-").replace("/", "-")
    if wanted.startswith(LIBRISPEECH_PREFIX):
        wanted = wanted[len(LIBRISPEECH_PREFIX):]
    if not wanted.startswith("continuous-"):
        return None
    split = wanted[len("continuous-"):]
    return split if split in LIBRISPEECH_SPLITS else None


def continuous_id(split):
    """The battery id for the continuous corpus built from a LibriSpeech split."""
    return CONTINUOUS_PREFIX + split


def is_continuous_librispeech(fleurs_dir):
    """Whether a resolved battery id names a continuous corpus of LibriSpeech."""
    return continuous_split(fleurs_dir) is not None


def continuous_remainder(name):
    """What follows a continuous-corpus prefix, or None if there is none.

    `fleurs-continuous-de_de` -> `de_de`, `continuous-de` -> `de`. The caller
    resolves the remainder as a language in its own right; this only strips.
    Call it after continuous_split, which claims the LibriSpeech spellings.
    """
    wanted = name.strip()
    for prefix in (CONTINUOUS_FLEURS_PREFIX, "continuous-"):
        if wanted.lower().replace("_", "-").startswith(prefix):
            return wanted[len(prefix):]
    return None


def continuous_fleurs_id(fleurs_dir):
    """The battery id for the continuous corpus built from a FLEURS directory."""
    return CONTINUOUS_FLEURS_PREFIX + fleurs_dir


def continuous_fleurs_dir(fleurs_dir):
    """The FLEURS directory a continuous-FLEURS id is built from, or None."""
    if not fleurs_dir.startswith(CONTINUOUS_FLEURS_PREFIX):
        return None
    return fleurs_dir[len(CONTINUOUS_FLEURS_PREFIX):] or None


def is_continuous_fleurs(fleurs_dir):
    """Whether a resolved battery id names a continuous corpus of FLEURS."""
    return continuous_fleurs_dir(fleurs_dir) is not None


def is_continuous(fleurs_dir):
    """Whether a resolved battery id names a continuous-speech corpus, either kind.

    The two share everything about how a corpus is stored and measured - built
    passages of 16-bit PCM, sized from their own headers, built on demand - and
    differ only in the source they are joined from and the language they score
    as. Callers that care about the shared part ask this; the two that care
    about the difference ask the specific one.
    """
    return is_continuous_librispeech(fleurs_dir) or is_continuous_fleurs(fleurs_dir)


def corpus_tag(fleurs_dir):
    """The language tag a battery id is scored with.

    FLEURS ids go through tag_for; LibriSpeech is English-only, so its splits
    all score as en-US. One function so rows_for, the planners, the runner and
    the summary cannot disagree about which.
    """
    if is_librispeech(fleurs_dir) or is_continuous_librispeech(fleurs_dir):
        return LIBRISPEECH_TAG
    source = continuous_fleurs_dir(fleurs_dir)
    if source is not None:
        return tag_for(source)
    return tag_for(fleurs_dir)


def script_of(name):
    """The script subtag in a tag or a directory name, lowercased, or ''.

    'zh-Hant' -> 'hant', 'cmn_hans_cn' -> 'hans', 'pl_pl' -> ''. A script is the
    only 4-letter alphabetic subtag BCP-47 allows in the language's own part of
    a tag, and FLEURS spells it the same way in the two directory names that
    carry one. A single-character subtag opens an extension or a private-use
    sequence (-u-, -t-, -x-), whose payload may be four letters without being a
    script, so the scan stops there rather than reading 'zh-CN-x-test' as Test.
    """
    parts = name.replace("_", "-").lower().split("-")
    for part in parts[1:]:
        if len(part) == 1:
            break
        if len(part) == 4 and part.isalpha():
            return part
    return ""


def region_of(name):
    """The region subtag in a tag or a directory name, lowercased, or ''.

    The same shape rule tag_for() applies in the other direction: two letters or
    three digits, and it is the last such subtag before any extension.
    """
    region = ""
    for part in name.replace("_", "-").lower().split("-")[1:]:
        if len(part) == 1:
            break
        if (len(part) == 2 and part.isalpha()) or (len(part) == 3 and part.isdigit()):
            region = part
    return region


def note_for(name, wanted, directory):
    """The line to print when the split chosen is not the one asked for, or None.

    Silence is the answer when the only difference is a region the dataset added
    to a bare tag: 'pl' -> pl_pl surprises nobody, and a note on every language
    of every run is noise that trains people to skip the ones that matter. The
    header printed for each language already names the directory and its tag.

    That justification covers a region and stops there. tag_for() never emits a
    script, so a script that was asked for and not honored is invisible in the
    header, and it is the difference that matters most: Latin against Cyrillic
    references measures the writing system rather than the recognizer.

    A note is earned when something the request actually stated was not honored:
    the language is filed under a different code (zh -> cmn_hans_cn, tl ->
    fil_ph, no -> nb_no), a region was asked for and is not the one that exists
    (es-ES -> es_419), or the split turns out to carry a script the request did
    not mention (cmn -> cmn_hans_cn).
    """
    tag = tag_for(directory)
    want_region = region_of(wanted)
    want_script = script_of(wanted)
    dir_script = script_of(directory)

    changed = (primary(directory) != primary(wanted)
               or (want_region and want_region != region_of(tag))
               or (dir_script and not want_script)
               or (want_script and not dir_script))
    if not changed:
        return None

    note = ("%s: FLEURS files this language as %s (%s); using it"
            % (name.strip(), directory, tag))
    if want_script and not dir_script:
        # Nothing in the directory name says which script the references use, so
        # this cannot be called a contradiction the way zh-Hant can - only flagged.
        note += ("\n      the %s script was asked for and this split does not "
                 "say which it uses" % want_script.capitalize())
    return note


def resolve_language(name):
    """A language tag as anyone would write it -> the FLEURS directory holding it.

    'es', 'es-ES', 'es_ES', 'es_419' and 'es-419' all arrive at es_419, because
    that is the only Spanish split FLEURS ships. Returns (fleurs_dir, note),
    where note is a line worth printing when the answer is not literally what
    was asked for, or (None, complaint) when nothing should be run.

    Callers should not have to know that Spanish is filed under es_419, that
    Mandarin is cmn_hans_cn, or that the Portuguese is Brazilian. FLEURS carries
    exactly one split per language, so a bare primary subtag is never ambiguous
    - checked against every name in the table - and a region that does not match
    is not an error either: asking for es-ES can only mean the Spanish that
    exists. It is dropped with a note rather than silently, because it changes
    what gets measured and the reference text is not in the dialect asked for.

    A script subtag is not treated that way. Dropping -Hant to score against
    Simplified references would measure the writing system rather than the
    recognizer, which is the same objection the nb/nn comment above makes, so a
    script that provably contradicts the split is refused instead.
    """
    wanted = name.strip().replace("_", "-").lower()
    if not wanted:
        return None, "empty language name"
    # The continuous corpora first, then LibriSpeech, then FLEURS: none of
    # these names is a FLEURS directory, and each must not fall through to the
    # "does not name a language" refusal.
    split = continuous_split(name)
    if split is not None:
        canonical = continuous_id(split)
        if name.strip().lower().replace("_", "-") == canonical:
            return canonical, None
        return canonical, ("%s: continuous speech built from LibriSpeech %s; scoring it as "
                           "%s in English (%s)" % (name.strip(), split, canonical, LIBRISPEECH_TAG))
    # Then the continuous corpora of FLEURS, which is every language but English.
    # The remainder is resolved as a language in its own right, so
    # `fleurs-continuous-de_de`, `continuous-de` and `continuous-de-DE` all
    # arrive at the same corpus by the same rules as the plain split does.
    remainder = continuous_remainder(name)
    if remainder is not None:
        directory, complaint = resolve_language(remainder)
        if directory is None:
            return None, complaint
        if is_librispeech(directory):
            # LibriSpeech's continuous corpus has its own spelling, which
            # continuous_split claims above; this is a spelling of it that the
            # FLEURS branch caught instead, so name the one that works.
            return None, ("'%s' names a LibriSpeech split, whose continuous corpus is %s."
                          % (name.strip(), continuous_id(librispeech_split(directory))))
        if is_continuous(directory):
            return None, ("'%s' asks for a continuous corpus of a corpus that is already "
                          "one. Name the split it is built from." % name.strip())
        canonical = continuous_fleurs_id(directory)
        if name.strip().lower().replace("_", "-") == canonical.replace("_", "-"):
            return canonical, None
        return canonical, ("%s: continuous speech built from FLEURS %s; scoring it as %s "
                           "in %s" % (name.strip(), directory, canonical, tag_for(directory)))
    # LibriSpeech before FLEURS: `test-clean` is not a FLEURS directory and
    # must not fall through to the "does not name a language" refusal.
    split = librispeech_split(name)
    if split is not None:
        canonical = librispeech_id(split)
        if name.strip().lower().replace("_", "-") == canonical:
            return canonical, None
        return canonical, ("%s: a LibriSpeech split; scoring it as %s in English (%s)"
                           % (name.strip(), canonical, LIBRISPEECH_TAG))
    # A tag is subtags joined by separators and nothing else. The check is a
    # shape test rather than a blocklist because the value becomes a path
    # component under --out and the corpus directory, and because anything
    # looser lets a name with a space through as its first subtag alone:
    # 'es-419 es-ES' would otherwise resolve, quietly, to Spanish.
    if not re.match(r"^[a-z0-9]+(-[a-z0-9]+)*$", wanted):
        return None, ("'%s' is not a language name. A tag is letters and digits in "
                      "groups separated by '-' or '_':\nes, es-419, pt-BR, cmn_hans_cn."
                      % name)

    # An actual directory name wins outright: it is the dataset's own spelling.
    for directory in FLEURS_DIRECTORIES:
        if directory == wanted.replace("-", "_"):
            return directory, None

    # Then the tag each directory is known by, region and all: pt-BR, es-419.
    # This still earns a note: 'zh-CN' is the tag for a directory called
    # cmn_hans_cn, and nothing about the answer is guessable from the request.
    for directory in FLEURS_DIRECTORIES:
        if tag_for(directory).lower() == wanted:
            return directory, note_for(name, wanted, directory)

    # Then the language alone. Aliases are consulted so the older codes people
    # still type - iw, in, jw, tl - land on the same split as the current ones.
    want = primary(wanted)
    # An extlang names the language more precisely than the primary does, and
    # BCP-47 puts it second: 'zh-yue' is Cantonese, which FLEURS holds separately
    # from Mandarin, so matching on 'zh' alone would score the wrong language.
    parts = wanted.split("-")
    if len(parts) > 1 and len(parts[1]) == 3 and parts[1].isalpha():
        if any(primary(d) == parts[1] for d in FLEURS_DIRECTORIES):
            want = parts[1]
    candidates = [want] + LANGUAGE_ALIASES.get(want, [])
    matches = []
    for candidate in candidates:
        for directory in FLEURS_DIRECTORIES:
            if directory in matches:
                continue
            if primary(tag_for(directory)) == candidate or primary(directory) == candidate:
                matches.append(directory)
    if len(matches) > 1:
        # Cannot happen against today's table; if a later release ships two
        # splits for one language, say so rather than picking one by list order.
        return None, ("'%s' is ambiguous - FLEURS has %s. Name the one you want."
                      % (name, " and ".join(matches)))
    if matches:
        directory = matches[0]
        want_script = script_of(wanted)
        dir_script = script_of(directory)
        if want_script and dir_script and want_script != dir_script:
            return None, ("'%s' asks for the %s script, and FLEURS' split for this "
                          "language is %s (%s).\nThe references are in the other "
                          "orthography, so a score against them would measure the\n"
                          "writing system rather than the recognizer."
                          % (name, want_script.capitalize(), directory,
                             dir_script.capitalize()))
        return directory, note_for(name, wanted, directory)

    # Nothing in the table knows this language. An underscore is the dataset's
    # own separator, so spelling it that way is taken as naming a directory
    # literally - the escape hatch for a FLEURS release newer than the table.
    # A tag spelling is refused instead, so that a language the table rejects on
    # purpose, nn, is refused in every tag spelling. nn_NO still reaches the
    # hatch, which is harmless: there is no such split to fetch, so it cannot be
    # scored against the Bokmal references the refusal exists to keep it away
    # from.
    if "_" in name:
        directory = wanted.replace("-", "_")
        return directory, ("'%s' is not a FLEURS directory this program knows; "
                           "trying it anyway" % directory)

    return None, ("'%s' does not name a language in FLEURS. It takes a language tag "
                  "(es, es-419, pt-BR, zh) or a\ndirectory name (es_419). Run --list "
                  "for all %d." % (name, len(FLEURS_DIRECTORIES)))


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


def rows_for(catalog, fleurs_dir, engines, exclude, wildcard, live=False):
    """Every transcriber row whose loaded model claims this language.

    Returns (row, tag) pairs, where the tag is the spelling THAT row understands.
    A single tag for the whole language would hand Whisper `jv` where it only
    knows `jw`, and the run would warn once on stderr and then transcribe into
    the wrong language.

    A row's language list is what the engine reported when the model loaded, not
    a published claim, which is why this is read from the catalog rather than
    from a table here.
    """
    want = corpus_tag(fleurs_dir)
    chosen = []
    for row in catalog["rows"]:
        if row.get("role") != "transcriber" or not row.get("available", True):
            continue
        # --live measures the live path, which a batch-only row does not have;
        # `speech eval --live` would refuse it cell by cell.
        if live and "live" not in (row.get("modes") or []):
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
    want = corpus_tag(fleurs_dir)
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
    if is_continuous(fleurs_dir):
        return continuous_audio(corpus_dir, fleurs_dir)
    if is_librispeech(fleurs_dir):
        return librispeech_audio(corpus_dir, fleurs_dir)
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


def flac_seconds(path):
    """Duration of a FLAC file from its STREAMINFO header, or None.

    The first metadata block of a LibriSpeech file is STREAMINFO, which
    carries the sample rate and total sample count. Reading 42 bytes beats
    decoding 7 seconds of audio, and --plan scans thousands of files.
    """
    try:
        with open(path, "rb") as handle:
            head = handle.read(42)
    except OSError:
        return None
    if len(head) < 42 or head[0:4] != b"fLaC":
        return None
    if head[4] & 0x7f != 0:
        return None
    rate = int.from_bytes(head[18:21], "big") >> 4
    total = int.from_bytes(head[21:26], "big") & 0xfffffffff
    if not rate or not total:
        return None
    return total / rate


def librispeech_audio(corpus_dir, fleurs_dir):
    """Exact total over the manifest's own FLAC files; (0.0, 0) when absent.

    LibriSpeech ships no sample-count column, so the durations come from the
    headers instead. Only files the manifest actually scores are counted, and
    one unreadable header is skipped rather than zeroing the whole split.
    """
    split = librispeech_split(fleurs_dir)
    manifest = os.path.join(corpus_dir, "LibriSpeech", split, "manifest.tsv")
    try:
        with open(manifest, encoding="utf-8", errors="replace") as handle:
            paths = [line.split("\t")[0] for line in handle if line.strip()]
    except OSError:
        return 0.0, 0
    total, rows = 0.0, 0
    for path in paths:
        seconds = flac_seconds(path)
        if seconds is None:
            continue
        total += seconds
        rows += 1
    return total, rows


def fetch_librispeech(corpus_dir, fleurs_dir):
    """tools/fetch-librispeech.sh, with its output left on the terminal."""
    environment = dict(os.environ, SPEECH_CORPUS_DIR=corpus_dir)
    try:
        done = subprocess.run([FETCH_LIBRISPEECH, librispeech_split(fleurs_dir)],
                              stdin=subprocess.DEVNULL, env=environment)
    except OSError as error:
        print("!! could not run %s: %s" % (FETCH_LIBRISPEECH, error))
        return False
    return done.returncode == 0


def usable_librispeech_manifest(corpus_dir, fleurs_dir, allow_fetch):
    """The manifest for a LibriSpeech split, fetching it if that is allowed.

    Returns its path, or None if this split cannot be measured. There is no
    test.tsv to repair against, so a non-empty manifest is accepted as is:
    the fetcher joins .trans.txt entries to matching .flac files and refuses
    to publish an empty one itself. It downloads the audio only when the split
    directory is absent, so on a split already on disk it just builds the
    manifest.
    """
    split = librispeech_split(fleurs_dir)
    manifest = os.path.join(corpus_dir, "LibriSpeech", split, "manifest.tsv")

    if not (os.path.exists(manifest) and os.path.getsize(manifest) > 0):
        if not allow_fetch:
            print("!! no manifest at %s and --no-fetch was given; skipping %s"
                  % (manifest, fleurs_dir))
            return None
        print("-- fetching %s with tools/fetch-librispeech.sh" % fleurs_dir)
        if not fetch_librispeech(corpus_dir, fleurs_dir):
            print("!! could not fetch %s; skipping it" % fleurs_dir)
            return None
        if not (os.path.exists(manifest) and os.path.getsize(manifest) > 0):
            print("!! still no manifest at %s; skipping %s" % (manifest, fleurs_dir))
            return None
    return manifest


def continuous_manifest_path(corpus_dir, fleurs_dir):
    """Where the builder writes a continuous corpus: beside the split it joined."""
    source = continuous_fleurs_dir(fleurs_dir)
    if source is not None:
        return os.path.join(corpus_dir, "fleurs", "continuous-" + source, "manifest.tsv")
    return os.path.join(corpus_dir, "LibriSpeech", "continuous-" + continuous_split(fleurs_dir),
                        "manifest.tsv")


def continuous_audio(corpus_dir, fleurs_dir):
    """Exact total over a continuous corpus's passages; (0.0, 0) when absent.

    The builder writes 16-bit PCM, which the wave module reads, so the length is
    each header's frame count rather than an estimate.
    """
    try:
        with open(continuous_manifest_path(corpus_dir, fleurs_dir),
                  encoding="utf-8", errors="replace") as handle:
            paths = [line.split("\t")[0] for line in handle if line.strip()]
    except OSError:
        return 0.0, 0
    total, rows = 0.0, 0
    for path in paths:
        try:
            with wave.open(path, "rb") as reader:
                total += reader.getnframes() / float(reader.getframerate())
                rows += 1
        except (OSError, EOFError, wave.Error):
            continue
    return total, rows


def usable_continuous_manifest(corpus_dir, fleurs_dir, allow_fetch):
    """The manifest for a continuous-speech corpus, building it if that is allowed.

    Building needs the split it is made from - a LibriSpeech split for the
    English corpus, a FLEURS directory for every other language - which is
    fetched the usual way first. What is built is the builder's default corpus,
    20 passages of about a minute: of one reader each from LibriSpeech, of
    consecutive distinct sentences from FLEURS, which has no readings in it. A
    different size is made by running tools/make-continuous-corpus.py directly,
    and is then read as it is. The builder decodes with this repository's
    build/speech; decoding does not differ between builds, so a run with
    --speech elsewhere still gets the same passages.

    Building is not fetching: with the split already on disk it downloads
    nothing, so --no-fetch still builds, and declines only the download of a
    split that is absent.
    """
    manifest = continuous_manifest_path(corpus_dir, fleurs_dir)
    if os.path.exists(manifest) and os.path.getsize(manifest) > 0:
        return manifest
    source = continuous_fleurs_dir(fleurs_dir)
    if source is None:
        source = continuous_split(fleurs_dir)
        if usable_librispeech_manifest(corpus_dir, librispeech_id(source), allow_fetch) is None:
            return None
    elif usable_manifest(corpus_dir, source, allow_fetch) is None:
        return None
    print("-- building %s with tools/make-continuous-corpus.py" % fleurs_dir)
    environment = dict(os.environ, SPEECH_CORPUS_DIR=corpus_dir)
    try:
        done = subprocess.run([sys.executable, MAKE_CONTINUOUS, "--split", source],
                              stdin=subprocess.DEVNULL, env=environment)
    except OSError as error:
        print("!! could not run %s: %s" % (MAKE_CONTINUOUS, error))
        return None
    if done.returncode != 0 or not (os.path.exists(manifest) and os.path.getsize(manifest) > 0):
        print("!! could not build %s; skipping it" % fleurs_dir)
        return None
    return manifest


def usable_manifest(corpus_dir, fleurs_dir, allow_fetch):
    """The manifest for a split, fetching or repairing it if that is allowed.

    Returns its path, or None if this language cannot be measured.

    The row-count check runs on every language on every run, not only after a
    fetch. fetch-fleurs.sh writes its manifest with a plain redirect, so an
    interrupted awk leaves a short but non-empty file - and non-empty is exactly
    what a bare existence test accepts, forever after. Checking only after a
    fetch would never see the case this exists for.
    """
    if is_continuous(fleurs_dir):
        return usable_continuous_manifest(corpus_dir, fleurs_dir, allow_fetch)
    if is_librispeech(fleurs_dir):
        return usable_librispeech_manifest(corpus_dir, fleurs_dir, allow_fetch)
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


def rtfx_sources(out_dir, live=False):
    """Anything on this machine that has ever recorded an RTFx.

    This battery's own results first, then every macOS version's battery of the
    same kind - the first run after an update starts an empty directory, and the
    machine's speed did not change with the system - then the stage spikes, as
    directories so the per-cell summary.json files count too. Live cells and
    batch cells are never mixed: a live cell plays its audio at the speed it was
    spoken, so its RTFx is about 1x whatever the model.
    """
    root = battery_root(live)
    roots = [root] if os.path.isdir(root) else []
    inside = os.path.abspath(out_dir).startswith(os.path.join(root, ""))
    sources = ([] if inside else [out_dir]) + roots
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

def write_row(cell_dir, model, fleurs_dir, limit, live=False):
    """One measured cell as one line of the table.

    Called after a cell runs, and again for a cell that is already done but has
    no row - see rebuild_summaries for why that matters.

    A live row adds the `live` object `speech eval --live` writes into
    summary.json. A latency the run could not observe - no partials at all, as
    fluid.parakeet-v3 never emits them - is "-" rather than a zero, which would
    read as instant.
    """
    summary_path = os.path.join(cell_dir, "summary.json")
    try:
        with open(summary_path, encoding="utf-8") as handle:
            summary = json.load(handle)
        fields = [
            model, fleurs_dir, str(limit) if limit else "all",
            str(summary.get("rows")),
            "%.2f" % (summary.get("wer", 0) * 100),
            "%.2f" % (summary.get("cer", 0) * 100),
            "%.1f" % summary.get("rtfx", 0),
            str(summary.get("peak_memory_bytes", 0)),
            "%.1f" % summary.get("load_seconds", 0),
        ]
        if live:
            measured = summary.get("live")
            if not isinstance(measured, dict):
                raise ValueError("a live cell's summary.json has no live object")

            def seconds(key):
                value = measured.get(key)
                return "-" if value is None else "%.2f" % value

            fields += [
                seconds("median_first_partial_seconds"),
                seconds("median_final_lag_seconds"),
                seconds("median_finish_seconds"),
                str(measured.get("trailing_words_lost", "-")),
                str(measured.get("dropped_buffers", "-")),
            ]
        line = "\t".join(fields)
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


def rebuild_summaries(out_dir, live=False):
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
            handle.write("\t".join(LIVE_TABLE_COLUMNS if live else TABLE_COLUMNS) + "\n")
            for row in rows:
                handle.write(row + "\n")
        os.replace(scratch, log)
    except OSError as error:
        remove(scratch)
        print("!! could not write %s: %s" % (log, error), file=sys.stderr)


def summarize(out_dir, live=False):
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
        unspaced = primary(corpus_tag(language)) in UNSPACED
        print()
        print("== %s%s%s" % (
            language,
            "" if limit == "all" else "   [first %s rows only]" % limit,
            "   [no spaces between words: read cer%, the wer% is not one]" if unspaced else ""))
        if live:
            print("%-45s %6s %7s %7s %9s %7s %7s %5s %6s" % (
                "model", "rows", "wer%", "cer%", "partial", "lag", "finish", "lost", "drops"))
        else:
            print("%-45s %6s %7s %7s %8s %10s" % ("model", "rows", "wer%", "cer%", "rtfx", "peak"))
        metric = "cer" if unspaced else "wer"

        def score(fields):
            try:
                return float(column(fields, metric))
            except ValueError:
                return float("inf")

        for fields in sorted(groups[(language, limit)], key=score):
            if live:
                print("%-45s %6s %7s %7s %9s %7s %7s %5s %6s" % (
                    column(fields, "model"), column(fields, "rows"),
                    column(fields, "wer"), column(fields, "cer"),
                    column(fields, "first_partial_s"), column(fields, "final_lag_s"),
                    column(fields, "finish_s"), column(fields, "trailing_words_lost"),
                    column(fields, "dropped_buffers")))
                continue
            peak = column(fields, "peak_memory")
            print("%-45s %6s %7s %7s %8s %10s" % (
                column(fields, "model"), column(fields, "rows"),
                column(fields, "wer"), column(fields, "cer"), column(fields, "rtfx"),
                human_bytes(int(peak)) if peak.isdigit() else peak))


# ---------------------------------------------------------------------------
# One cell
# ---------------------------------------------------------------------------

def cell_slug(model, fleurs_dir, limit, live=False):
    slug = re.sub(r"[./@]", "_", model) + "__" + fleurs_dir
    return slug + ("__n%d" % limit if limit else "") + ("__live" if live else "")


def run_cell(options, model, fleurs_dir, tag, manifest):
    """Measure one model against one language.

    Raises only Interrupted. Everything else - an unreadable marker, a full
    disk, a malformed report - fails this one cell and lets the battery go on,
    because the alternative is a traceback four hours into a multi-day run.
    """
    slug = cell_slug(model, fleurs_dir, options.limit, options.live)
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
            if write_row(cell_dir, model, fleurs_dir, options.limit, options.live):
                rebuild_summaries(options.out, options.live)
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
    if options.live:
        command += ["--live"]

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
    if write_row(cell_dir, model, fleurs_dir, options.limit, options.live):
        rebuild_summaries(options.out, options.live)


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
    """Every FLEURS language and LibriSpeech split, with the rows that claim each."""
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
    else:
        # This is the one place the live listing and the baked table are both in
        # hand, so it is the only place that can notice the table going stale.
        # A language missing from the table resolves only by its directory name,
        # which is exactly the confusing case: --list would show it while a tag
        # for it came back "does not name a language in FLEURS".
        added = [name for name in names if name not in FLEURS_DIRECTORIES]
        if added:
            print("(FLEURS has %d split(s) this program's table does not list: %s.\n"
                  " They are reachable by directory name; add them to "
                  "FLEURS_DIRECTORIES to name them by tag.)"
                  % (len(added), " ".join(added)))

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

    print()
    print("%-22s %-7s %-9s %-22s %s" % ("librispeech", "tag", "models", "engines", "corpus"))
    for split in LIBRISPEECH_SPLITS:
        name = librispeech_id(split)
        rows = [row for row, _ in rows_for(catalog, name, [], [], False)]
        installed = sum(1 for row in rows if row.get("installed"))
        seconds, count = audio_seconds(options.corpus_dir, name)
        engines = sorted({row.get("engine", "?") for row in rows})
        if count:
            corpus = "%d rows, %s" % (count, human_time(seconds))
        elif os.path.isdir(os.path.join(options.corpus_dir, "LibriSpeech", split)):
            corpus = "no manifest - run tools/fetch-librispeech.sh %s" % split
        else:
            corpus = "not fetched"
        print("%-22s %-7s %-9s %-22s %s" % (
            name, LIBRISPEECH_TAG,
            "%d/%d" % (installed, len(rows)) if rows else "-",
            " ".join(engines) if engines else "(none claims it)",
            corpus))
    return 0


def command_plan(options, catalog):
    rtfx = known_rtfx(rtfx_sources(options.out, options.live))
    total_seconds, missing, cells = 0.0, {}, 0
    guessed_fleurs, guessed_librispeech, guessed_continuous = False, False, False

    for fleurs_dir in options.languages:
        seconds, rows = audio_seconds(options.corpus_dir, fleurs_dir)
        known_size = rows > 0
        if not known_size:
            # A split that is not on disk yet still has to appear in the total,
            # or the headline number is short by however many languages have not
            # been downloaded - the exact case --plan exists to answer. Each
            # corpus counts at its own middle: a 5.4h LibriSpeech guess at a
            # 2.5h FLEURS size would be wrong by half a day across two splits.
            if is_continuous(fleurs_dir):
                seconds, rows = CONTINUOUS_SECONDS, CONTINUOUS_ROWS
                guessed_continuous = True
            elif is_librispeech(fleurs_dir):
                seconds, rows = LIBRISPEECH_SPLIT_SECONDS, LIBRISPEECH_SPLIT_ROWS
                guessed_librispeech = True
            else:
                seconds, rows = FLEURS_SPLIT_SECONDS, FLEURS_SPLIT_ROWS
                guessed_fleurs = True
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
                                                 options.exclude, options.wildcard, options.live)]
        print("== %s (%s)  %s of audio%s" % (
            fleurs_dir, corpus_tag(fleurs_dir), human_time(seconds),
            "" if known_size else " (estimated; the split is not on disk yet)"))
        for row in chosen:
            cells += 1
            if options.live:
                # A live cell plays its audio at the speed it was spoken, so it
                # costs the audio's length however fast the model is.
                speed = None
                estimate = seconds
            else:
                speed = rtfx.get(row["id"])
                estimate = seconds / (speed if speed else UNMEASURED_RTFX)
            if not row.get("installed") and (row.get("size_bytes") or 0):
                missing[row["id"]] = row["size_bytes"]
            print("   %-45s %-14s %s%s" % (
                row["id"],
                "installed" if row.get("installed") else "NOT INSTALLED",
                human_time(estimate),
                "" if speed or options.live else "  (never measured here; assuming %dx)" % UNMEASURED_RTFX))
            total_seconds += estimate
        if not chosen:
            print("   no model in this build claims this language"
                  " (try --wildcard for the rows that report no language list)")
        print()

    footer = ""
    if guessed_fleurs:
        each = FLEURS_SPLIT_SECONDS
        if options.limit:
            each = each * min(options.limit, FLEURS_SPLIT_ROWS) / FLEURS_SPLIT_ROWS
        footer += " (unfetched FLEURS splits counted at %s each)" % human_time(each)
    if guessed_librispeech:
        each = LIBRISPEECH_SPLIT_SECONDS
        if options.limit:
            each = each * min(options.limit, LIBRISPEECH_SPLIT_ROWS) / LIBRISPEECH_SPLIT_ROWS
        footer += " (unfetched LibriSpeech splits counted at %s each)" % human_time(each)
    if guessed_continuous:
        footer += " (unbuilt continuous corpora counted at %s each)" % human_time(CONTINUOUS_SECONDS)
    print("%d cells, about %s of %s%s" % (cells, human_time(total_seconds),
                                          "real-time playback" if options.live else "compute", footer))
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


def battery_root(live):
    """The directory holding one battery per macOS version."""
    return os.path.join(REPO, "Private", "live-battery" if live else "language-battery")


def macos_version():
    """This Mac's macOS version, spelled the way `speech eval` records it.

    speech writes major.minor.patch from ProcessInfo, so 27.0 is 27.0.0 in every
    summary.json; platform gives 27.0. Padding here keeps the directory name and
    the comparison with a cell's own record the same string.
    """
    parts = (platform.mac_ver()[0] or "unknown").split(".")
    while len(parts) < 3 and parts[0] != "unknown":
        parts.append("0")
    return ".".join(parts)


def other_macos(out_dir, current):
    """The macOS version of a finished cell in out_dir that is not this one, or None."""
    try:
        names = sorted(os.listdir(out_dir))
    except OSError:
        return None
    for name in names:
        try:
            with open(os.path.join(out_dir, name, "summary.json"), encoding="utf-8") as handle:
                recorded = json.load(handle).get("os")
        except (OSError, ValueError, AttributeError):
            continue
        if recorded and recorded != current:
            return recorded
    return None


def command_run(options, catalog):
    current = macos_version()
    recorded = other_macos(options.out, current)
    if recorded:
        print("!! %s holds cells measured on macOS %s, and this Mac runs macOS %s."
              % (options.out, recorded, current), file=sys.stderr)
        print("   A battery keeps to one macOS version, so that a newer system's cells never",
              file=sys.stderr)
        print("   stand in for an older one's. Leave out --out to measure into %s."
              % os.path.join(battery_root(options.live), "macos-" + current), file=sys.stderr)
        return 1
    os.makedirs(options.out, exist_ok=True)

    print("battery: %s" % " ".join(options.languages))
    print("output:  %s" % options.out)
    print("binary:  %s (%s)" % (options.speech, speech_version(options.speech)))
    print()

    for fleurs_dir in options.languages:
        tag = corpus_tag(fleurs_dir)
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
                                 options.exclude, options.wildcard, options.live)
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
    rebuild_summaries(options.out, options.live)
    summarize(options.out, options.live)
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
                    "language's test split: FLEURS, or LibriSpeech for English.",
        epilog="Languages are positional arguments, one or more of them, each a\n"
               "language tag: es, es-ES, pt-BR, zh. FLEURS' own directory names\n"
               "(es_419, cmn_hans_cn) work too. FLEURS ships one split per\n"
               "language, so a bare tag is never ambiguous and a region it does\n"
               "not have is resolved to the one it does, with a note. --list\n"
               "prints them all, with how many models claim each and which\n"
               "engines.\n"
               "\n"
               "librispeech-test-clean and librispeech-test-other name the two\n"
               "LibriSpeech splits instead: English-only, ranked apart, with\n"
               "test-other the harder one. `test-clean` and `ls-test-clean`\n"
               "mean the same. A split that is not on disk is downloaded from\n"
               "openslr.org/12 (about 350 MB each) by tools/fetch-librispeech.sh.\n"
               "\n"
               "examples:\n"
               "  # every language, how many models claim it, whether it is downloaded\n"
               "  tools/language-battery.py --list\n"
               "  # what a Spanish run would cost, in cells, hours and gigabytes\n"
               "  tools/language-battery.py --plan es\n"
               "  # what the clean LibriSpeech split would cost\n"
               "  tools/language-battery.py --plan librispeech-test-clean\n"
               "  # run it on all 4 engines. Audio is fetched as needed either way;\n"
               "  # --download is what also pulls the model weights that are missing\n"
               "  tools/language-battery.py --caffeinate --download es 2>&1 | tee battery-es.log\n"
               "  # a quicker look: two engines, two languages, 50 utterances each\n"
               "  tools/language-battery.py --engines \"apple mlx\" --limit 50 es pt\n"
               "\n"
               "SPEECH_CORPUS_DIR  where the corpora live (default ~/Corpora)\n"
               "SPEECH_MODELS_DIR  where model weights live, read by `speech` itself")

    parser.add_argument("languages", nargs="*", metavar="language",
                        help="one or more language tags (es, pt-BR, zh), FLEURS "
                             "directory names (es_419), or LibriSpeech splits "
                             "(librispeech-test-clean); every model that claims the "
                             "language is scored against its test split. "
                             "--list to see them all")
    parser.add_argument("--list", action="store_true",
                        help="list FLEURS languages and LibriSpeech splits with how "
                             "many models claim each, then exit")
    parser.add_argument("--plan", action="store_true",
                        help="print the matrix, the missing downloads and a time estimate; run nothing")
    parser.add_argument("--out", metavar="DIR",
                        help="where cells and summaries.tsv go (default "
                             "Private/language-battery/macos-<this macOS version>)")
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
    parser.add_argument("--live", action="store_true",
                        help="measure the live path (speech eval --live) on the rows that can "
                             "stream, playing the audio at the speed it was spoken; cells go to "
                             "Private/live-battery/macos-<this macOS version>. Meant for "
                             "librispeech-continuous-test-clean")
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
    # Live cells get a directory of their own: their table has more columns, and
    # a live cell and a batch cell for the same row and corpus are different
    # measurements that must never share a summaries.tsv.
    options.out = (os.path.abspath(options.out) if options.out
                   else os.path.join(battery_root(options.live), "macos-" + macos_version()))
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

    # The languages are settled first, because none of it needs the binary or the
    # catalog: resolution is offline, against the baked table. Ordering this
    # after the --speech check would answer a bare invocation with "no binary at
    # build/speech", which tells someone who does not yet know how to name a
    # language nothing about how to name one. It sits after the --caffeinate
    # re-exec so that the notes below are printed once, by the child, rather
    # than by both halves of the exec.
    if not options.list:
        if not options.languages:
            parser.print_usage(sys.stderr)
            die("no languages given. A language is a positional argument, written as a\n"
                "language tag - es, es-ES, pt-BR, zh - as a FLEURS directory name, or as\n"
                "a LibriSpeech split:\n"
                "\n"
                "    tools/language-battery.py --plan es\n"
                "    tools/language-battery.py --plan librispeech-test-clean\n"
                "\n"
                "--list prints all %d languages, --help the rest of the options."
                % len(FLEURS_DIRECTORIES), status=2)

        resolved = []
        announced = []
        for name in options.languages:
            directory, note = resolve_language(name)
            if directory is None:
                die(note, status=2)
            # The note belongs to the name, the run belongs to the directory. In
            # `es-419 es-ES` the second name is the one with something to say and
            # the first is the one that claims the slot, so notes are printed
            # before the duplicate is dropped, and de-duplicated on their own text.
            if note and note not in announced:
                print("note: %s" % note, file=sys.stderr)
                announced.append(note)
            if directory in resolved:
                continue                # `es es-419` is one run, not two
            resolved.append(directory)
        options.languages = resolved

    if not os.access(options.speech, os.X_OK):
        die("no binary at %s - run ./build.sh first, or pass --speech <path>"
            % options.speech, status=2)

    catalog = load_catalog(options.speech)

    if options.list:
        return command_list(options, catalog)

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
