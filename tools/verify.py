# tools/verify.py
#!/usr/bin/env python3
"""Cross-check span-width's per-scalar widths against an independent
implementation: Python's built-in unicodedata.

Usage:
    crystal run tools/dump_widths.cr -- widths.tsv
    python3 tools/verify.py widths.tsv

The width model replicated here is the shard's documented model:
  * general category Mn/Me                      -> 0
  * explicit zero ranges (ZWSP..ZWJ, WJ, BOM,
    Hangul jamo vowels/finals, skin tones, tags) -> 0
  * East Asian Width W/F                        -> 2
  * everything else                             -> 1

Note: Python ships an older UCD than the shard's pinned version, so
mismatches are expected for codepoints whose data changed between the
two Unicode releases. The script prints mismatches grouped into ranges;
verify they all fall inside blocks added or changed in the newer UCD.
"""
import sys
import unicodedata as ud

EXPLICIT_ZERO = [
    (0x200B, 0x200D),   # ZWSP, ZWNJ, ZWJ
    (0x2060, 0x2060),   # word joiner
    (0xFEFF, 0xFEFF),   # BOM
    (0x1160, 0x11FF),   # Hangul jamo vowels & finals
    (0xD7B0, 0xD7FF),   # Hangul jamo extended-B
    (0x1F3FB, 0x1F3FF), # skin-tone modifiers
    (0xE0001, 0xE007F), # tags
]

def expected(cp):
    ch = chr(cp)
    if ud.category(ch) in ("Mn", "Me"):
        return 0
    if any(first <= cp <= last for first, last in EXPLICIT_ZERO):
        return 0
    return 2 if ud.east_asian_width(ch) in ("W", "F") else 1

def into_ranges(cps):
    """Collapse a sorted list of codepoints into (first, last) ranges."""
    if not cps:
        return []
    ranges = []
    start = prev = cps[0]
    for cp in cps[1:]:
        if cp == prev + 1:
            prev = cp
        else:
            ranges.append((start, prev))
            start = prev = cp
    ranges.append((start, prev))
    return ranges

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "widths.tsv"
    mismatches = []
    checked = 0
    with open(path) as f:
        for line in f:
            cp_s, w_s = line.split()
            cp, got = int(cp_s), int(w_s)
            if got != expected(cp):
                mismatches.append((cp, got, expected(cp)))
            checked += 1

    print(f"unicodedata UCD version: {ud.unidata_version}")
    print(f"checked {checked} scalar values, {len(mismatches)} mismatches")

    if mismatches:
        print("\nmismatch ranges (cp range, shard width, python width):")
        by_kind = {}
        for cp, got, exp in mismatches:
            by_kind.setdefault((got, exp), []).append(cp)
        for (got, exp), cps in sorted(by_kind.items()):
            for first, last in into_ranges(cps):
                print(f"  U+{first:04X}..U+{last:04X}  shard={got}  python={exp}")

if __name__ == "__main__":
    main()
