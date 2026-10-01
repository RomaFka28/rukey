#!/usr/bin/env python3
"""Compare firing rules on the REAL corpora, prefix by prefix, on a FREQUENCY-ordered
sample.

The first version of this script sampled the first 1000 words alphabetically, which is a
biased sample: it over-represents rare short words. This version restores frequency order,
because a false positive on a rare junk word does not hurt a user nearly as much as a
false positive on a word they type all day.

Rule A (whole-word):  fire only if the re-decoded prefix is itself a dictionary word.
                      Reacts at the END of the wrong word, never before.
Rule B (prefix-tree): fire if the re-decoded prefix is a prefix of some dictionary word.
                      Reacts mid-word, which is what the user asked for.

Layout tables are ground truth from keycode_probe on this machine.
"""

import unicodedata

US = {0:'a',1:'s',2:'d',3:'f',4:'h',5:'g',6:'z',7:'x',8:'c',9:'v',11:'b',12:'q',
      13:'w',14:'e',15:'r',16:'y',17:'t',31:'o',32:'u',34:'i',35:'p',37:'l',
      38:'j',40:'k',45:'n',46:'m'}
RU = {0:'ф',1:'ы',2:'в',3:'а',4:'р',5:'п',6:'я',7:'ч',8:'с',9:'м',11:'и',12:'й',
      13:'ц',14:'у',15:'к',16:'н',17:'е',31:'щ',32:'г',34:'ш',35:'з',37:'д',
      38:'о',40:'л',45:'т',46:'ь',30:'ъ',33:'х',39:'э',41:'ж',42:'ё',43:'б',47:'ю'}
TABLES = {"ru": RU, "en": US}
KC = {}
for k, c in US.items(): KC[c] = k
for k, c in RU.items(): KC[c] = k

ALPHABET = {
    "ru": set("абвгдежзийклмнопрстуфхцчшщъыьэюя"),
    "en": set("abcdefghijklmnopqrstuvwxyz"),
}


def script_of(w):
    cyr = any('CYRILLIC' in unicodedata.name(c, '') for c in w)
    lat = any(c.isascii() and c.isalpha() for c in w)
    if cyr and lat: return 'MIXED'
    if cyr: return 'CYR'
    if lat: return 'LAT'
    return 'OTHER'


def load_frequency(path, lang):
    """Reproduce build_dict.py's filtering, keeping frequency order."""
    want = {'ru': 'CYR', 'en': 'LAT'}[lang]
    allowed = ALPHABET[lang]
    out, seen = [], set()
    with open(path, encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split(' ')
            if len(parts) < 2: continue
            w, freq = parts[0], int(parts[1])
            if not w.isalpha() or script_of(w) != want: continue
            folded = w.lower().replace('ё', 'е')
            if not set(folded) <= allowed or len(folded) < 2: continue
            if folded in seen: continue
            seen.add(folded)
            out.append((folded, freq))
    return out


def reencode(word, dst):
    out = []
    for c in word:
        k = KC.get(c)
        if k is None or k not in dst: return None
        out.append(dst[k])
    return ''.join(out)


def build_prefixes(words):
    out = set()
    for w in words:
        for i in range(1, len(w)):
            out.add(w[:i])
    return out


def replay(word, cur, other, cur_words, other_words, other_prefixes, rule, L):
    """Type one keystroke at a time; return the prefix that first fires, or None."""
    buf = ''
    for ch in word:
        buf += ch
        if len(buf) < L: continue
        if buf in cur_words: continue          # correct in the current language
        alt = reencode(buf, TABLES[other])
        if alt is None: continue
        hit = alt in other_words if rule == 'A' else (
            alt in other_words or alt in other_prefixes)
        if hit:
            return buf, alt
    return None


def replay_timing(word, cur, other, cur_words, other_words, other_prefixes, rule, L):
    """Like replay(), but also reports WHERE it fired and whether that was mid-word.

    'mid-word' means it fired before the last character, which is the whole point of the
    project: the user wants the fix to land while they are still typing.
    Returns (fired, length_at_fire, word_length, is_midword, buffer, alt) or None.
    """
    buf = ''
    for ch in word:
        buf += ch
        if len(buf) < L: continue
        if buf in cur_words: continue          # correct in the current language
        alt = reencode(buf, TABLES[other])
        if alt is None: continue
        hit = alt in other_words if rule == 'A' else (
            alt in other_words or alt in other_prefixes)
        if hit:
            return (buf, len(buf), len(word), len(buf) < len(word), alt)
    return None


def summarize(timings, label, N):
    if not timings:
        print(f"  {label}: no fires")
        return
    mid = sum(1 for t in timings if t[3])
    pos = sum(t[1] for t in timings) / len(timings)
    print(f"  {label}: fires={len(timings)}  mid-word={mid} ({100*mid/len(timings):.0f}%)  "
          f"avg keystroke={pos:.1f}")


def main():
    N = 1000
    ru_freq = load_frequency('tools/cache/ru_50k.txt', 'ru')
    en_freq = load_frequency('tools/cache/en_50k.txt', 'en')
    ru_words = {w for w, _ in ru_freq}
    en_words = {w for w, _ in en_freq}
    P = {'ru': build_prefixes(ru_words), 'en': build_prefixes(en_words)}

    ru_sample = [w for w, _ in ru_freq][:N]
    en_sample = [w for w, _ in en_freq][:N]
    print(f"corpora: ru={len(ru_words)} en={len(en_words)}")
    print(f"top-{N} by frequency: ru={len(ru_sample)} en={len(en_sample)}")
    print(f"  ru head: {' '.join(ru_sample[:12])}")
    print(f"  en head: {' '.join(en_sample[:12])}\n")

    for rule in ('A', 'B'):
        name = 'A whole-word  ' if rule == 'A' else 'B prefix-tree'
        print(f"=== rule {name} ===")
        for L in (3, 4, 5):
            fp_ru = [r for r in (replay(w, 'ru', 'en', ru_words, en_words, P['en'], rule, L)
                                 for w in ru_sample) if r]
            fp_en = [r for r in (replay(w, 'en', 'ru', en_words, ru_words, P['ru'], rule, L)
                                 for w in en_sample) if r]
            det_en = sum(1 for w in en_sample
                         if replay(w, 'ru', 'en', ru_words, en_words, P['en'], rule, L))
            det_ru = sum(1 for w in ru_sample
                         if replay(w, 'en', 'ru', en_words, ru_words, P['ru'], rule, L))
            print(f"  L={L}: FP ru={len(fp_ru):4d}/{N} ({100*len(fp_ru)/N:5.2f}%)  "
                  f"FP en={len(fp_en):4d}/{N} ({100*len(fp_en)/N:5.2f}%)  "
                  f"detect en-on-ru={100*det_en/N:5.1f}%  ru-on-en={100*det_ru/N:5.1f}%")
            if fp_ru:
                uniq = sorted({f"{b}->{a}" for b, a in fp_ru})
                print(f"        ru FP ({len(uniq)} unique): {' '.join(uniq[:12])}")

            # When does it fire on genuinely-wrong input, and is that mid-word?
            # This is the number the user actually feels.
            good = [replay_timing(w, 'ru', 'en', ru_words, en_words, P['en'], rule, L)
                    for w in en_sample]
            good = [g for g in good if g]
            summarize(good, f"corrected (en typed on ru) n={len(good)}", N)
        print()


if __name__ == '__main__':
    main()