#!/usr/bin/env python3
"""Build the word lists RukeyDetector uses.

Source: hermitdave/FrequencyWords (OpenSubtitles 2018), space-delimited `word count`.

The one thing this script must never get wrong: filtering must be SYMMETRIC. The raw
Russian list carries 819 Latin entries (`the`, `to`, `it`, `of`, `in`, `me`, `no`, ...),
123 of them two characters long. An asymmetric filter leaves English junk in the Russian
dictionary, and that junk becomes a false trigger: the tool reads it as a valid Russian
word and converts text the user typed correctly.

Usage:
    tools/build_dict.py [--cache DIR] [--out DIR] [--words N]

Outputs Resources/dict/{en,ru}.txt, one lowercase word per line, newline-separated.
"""

import argparse
import os
import sys
import unicodedata

SOURCES = {
    "ru": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt",
    "en": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
}

# The alphabet each language is ALLOWED to contain. Anything else is contamination.
# Latin text in the Russian list is English debris, not Russian words.
REQUIRED_SCRIPT = {"ru": "CYR", "en": "LAT"}

# The 33-letter Russian alphabet, and plain ASCII for English.
#
# Restricting to the real alphabet is stricter than a script check and catches junk that
# passes isalpha(): the subtitle corpus contains entries like "ƒа", where ƒ is Latin
# script but not a letter any layout can type. Such words are inert for the detector (no
# key code produces ƒ, so reencode() returns nil) but they do not belong in the artifact.
ALPHABET = {
    "ru": set("абвгдежзийклмнопрстуфхцчшщъыьэюя"),
    "en": set("abcdefghijklmnopqrstuvwxyz"),
}


def script_of(word):
    """Return CYR, LAT, MIXED or OTHER for a word."""
    has_cyr = any("CYRILLIC" in unicodedata.name(c, "") for c in word)
    has_lat = any(c.isascii() and c.isalpha() for c in word)
    if has_cyr and has_lat:
        return "MIXED"
    if has_cyr:
        return "CYR"
    if has_lat:
        return "LAT"
    return "OTHER"


def fetch(url, cache_dir):
    """Download to cache and return the path. Cached copies are reused."""
    os.makedirs(cache_dir, exist_ok=True)
    name = url.rsplit("/", 1)[-1]
    path = os.path.join(cache_dir, name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    import urllib.request

    print(f"  downloading {name} ...", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)
    return path


def load(path):
    """Parse the space-delimited `word count` format into [(word, freq)]."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            # Split on space, not tab: the format is space-delimited and awk -F'\t'
            # silently reports zero entries on this file.
            parts = line.rstrip("\n").split(" ")
            if len(parts) >= 2 and parts[0]:
                try:
                    out.append((parts[0], int(parts[1])))
                except ValueError:
                    continue
    return out


def build(lang, path, max_words, min_length=2):
    """Filter one language's raw list down to a clean, sorted word list."""
    want = REQUIRED_SCRIPT[lang]
    allowed = ALPHABET[lang]
    raw = load(path)
    kept, seen = [], set()
    stats = {"raw": len(raw), "script": 0, "alpha": 0, "nonalpha": 0, "short": 0, "dup": 0}

    for word, freq in raw:
        if not word.isalpha():
            stats["nonalpha"] += 1
            continue
        # The contamination gate. Symmetric by construction: each language has exactly
        # one allowed script, so neither can be left holding the other's debris.
        if script_of(word) != want:
            stats["script"] += 1
            continue
        folded = word.lower().replace("ё", "е").replace("Ё", "Е")
        # Real alphabet only. Rejects isalpha() pass-through like "ƒа", whose ƒ is Latin
        # script but not a letter any layout can produce.
        if not set(folded) <= allowed:
            stats["alpha"] += 1
            continue
        if len(folded) < min_length:
            stats["short"] += 1
            continue
        if folded in seen:
            stats["dup"] += 1
            continue
        seen.add(folded)
        kept.append((folded, freq))

    # Frequency order, so the top-N cut keeps the words a user actually types.
    kept.sort(key=lambda p: -p[1])
    if max_words and len(kept) > max_words:
        kept = kept[:max_words]
    kept.sort()

    print(f"  {lang}: raw={stats['raw']} dropped(wrong_script)={stats['script']} "
          f"dropped(not_in_alphabet)={stats['alpha']} dropped(nonalpha)={stats['nonalpha']} "
          f"dropped(short)={stats['short']} dropped(dup)={stats['dup']} kept={len(kept)}")
    return [w for w, _ in kept]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default="tools/cache")
    ap.add_argument("--out", default="Resources/dict")
    ap.add_argument("--words", type=int, default=0, help="cap per language (0 = all)")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for lang, url in SOURCES.items():
        path = fetch(url, args.cache)
        words = build(lang, path, args.words)
        dest = os.path.join(args.out, f"{lang}.txt")
        with open(dest, "w", encoding="utf-8") as f:
            f.write("\n".join(words) + "\n")
        print(f"  wrote {dest} ({len(words)} words)")


if __name__ == "__main__":
    main()