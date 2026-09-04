# span-width

Terminal cell-width measurement for clean text spans. Single purpose:
stream text spans in, get `{span, width}` out — where width is the number
of terminal cells the span occupies.

Zero dependencies, zero allocations, wcwidth-compatible. Built for TUI
renderers that already know their input is plain text.

## The contract

Input spans are **valid UTF-8 text with no ANSI escape sequences and no
control characters** (C0, DEL, C1). Because the caller guarantees this:

* `measure` never validates, never returns `-1`, never raises;
* the hot path skips every check real `wcwidth` has to do for control bytes.

Compile with `-Dspan_width_debug` during development to validate the
contract and raise `ArgumentError` on violations. The validation code is
eliminated entirely in normal builds.

## Width model

What most terminals (xterm, tmux, alacritty, iTerm2) assume — glibc-style
`wcwidth` plus pragmatic emoji handling:

| scalars                                            | cells |
| -------------------------------------------------- | ----- |
| East Asian Wide / Fullwidth (incl. most emoji)     | 2     |
| combining marks (Mn/Me), ZWSP/ZWNJ/ZWJ, word joiner, BOM, Hangul jamo vowels & finals, skin-tone modifiers, variation selectors, tag chars | 0 |
| a scalar joined by U+200D (ZWJ)                    | +0 — `👨‍👩‍👧‍👦` = 2 |
| narrow emoji base followed by U+FE0F (VS16)        | 2 — `❤️` = 2 |
| regional indicators                                | 1 each — flags = 2 |
| everything else                                    | 1     |

Tables are generated from the Unicode Character Database (**Unicode
17.0.0**) and committed; see *Regenerating the tables* below.

> **Caveat:** kitty/foot/WezTerm do full grapheme-cluster widths. If you
> target those terminals and need exactness for exotic sequences, feed
> grapheme-cluster-aligned spans — measurement cost stays the same.

## Usage

```yaml
# shard.yml
dependencies:
  span-width:
    github: you/span-width
```

```crystal
require "span-width"

# one span
SpanWidth.measure("Hello, 世界! 👋") # => 15
SpanWidth.measure("👨‍👩‍👧‍👦")           # => 2
SpanWidth.width('日')                # => 2 (single scalar)

# streaming: block form
SpanWidth.each(["foo", "日本語", "héllo"]) do |span, width|
  # span => String, width => Int32
end

# streaming: lazy iterator, zero-copy (spans are never duplicated)
SpanWidth.each(spans) # => Iterator({String, Int32})

# line-oriented input
SpanWidth.each_line(STDIN) do |line, width|
  # ...
end
```

## Performance

Measured with `crystal run --release bench/bench.cr` (x86-64, indicative —
run it on your own hardware):

| corpus        | throughput      |
| ------------- | --------------- |
| ASCII         | ~6.8 GiB/s      |
| Latin-1       | ~347 MiB/s      |
| CJK           | ~484 MiB/s      |
| Hangul        | ~443 MiB/s      |
| emoji-heavy   | ~425 MiB/s      |
| mixed         | ~519 MiB/s      |
| short spans   | 14–41 ns/call, **0 B allocated** |

How: an 8-bytes-at-a-time ASCII fast path (SWAR), a two-level page table
(≈32 KB, cache-resident) giving O(1) branch-free per-scalar width for
everything else, and no allocations anywhere — spans are read in place and
the same objects stream out.

## Regenerating the tables

Tables are committed, so shard users need no network. To move to a newer
Unicode release:

```sh
crystal run tools/gen_tables.cr -- --version 17.0.0
# or from local UCD files:
crystal run tools/gen_tables.cr -- --dir /path/to/ucd/files
```

## Development

```sh
crystal spec                        # unit + table-boundary + full-range consistency specs
crystal spec -Dspan_width_debug     # also exercise contract validation
crystal run --release bench/bench.cr

# cross-check all 1.1M scalar widths against Python's unicodedata
# (mismatches = codepoints whose data changed between the two UCD versions)
crystal run tools/dump_widths.cr -- widths.tsv
python3 tools/verify.py widths.tsv
```

## License

MIT — see LICENSE.
