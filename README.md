# span-width

Terminal cell-width measurement for clean text spans. Single purpose:
stream text spans in, get `{span, width}` out — where width is the number
of terminal cells the span occupies.

Zero dependencies, zero allocations, wcwidth-compatible. Built for TUI
renderers that already know their input is plain text.

Optional grapheme-cluster segmentation (UAX #29) is available via a
separate opt-in require — see *Grapheme clusters* below.

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
| a scalar joined to an emoji by U+200D (ZWJ)        | +0 — `👨‍👩‍👧‍👦` = 2 |
| narrow emoji base followed by U+FE0F (VS16)        | 2 — `❤️` = 2 |
| regional indicators                                | 1 each — flags = 2 |
| everything else                                    | 1     |

Tables are generated from the Unicode Character Database (**Unicode
17.0.0**) and committed; see *Regenerating the tables* below.

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

## Grapheme clusters

Scalar mode answers "how many cells is this span?". For terminals that
measure per grapheme cluster (kitty, foot, WezTerm) — or for cursor
movement, wrapping, and truncation that must never split a cluster — load
the opt-in grapheme module:

```crystal
require "span-width/grapheme"

alias Grapheme = SpanWidth::Grapheme

# segment one span — clusters are zero-copy Slice(UInt8) views into it
Grapheme.each("a👨‍👩‍👧‍👦日") do |cluster|
  # cluster => Slice(UInt8)
end

# width of one cluster (same documented width model as scalar mode)
Grapheme.measure("👨‍👩‍👧‍👦") # => 2

# segment + measure in one pass
Grapheme.measure_each("a👨‍👩‍👧‍👦日") do |cluster, width|
  # => ("a", 1), ("👨‍👩‍👧‍👦", 2), ("日", 2)
end

# streaming over spans — span boundaries are hard cluster boundaries
Grapheme.measure_each(spans) do |cluster, width|
  # ...
end
```

* Extended grapheme clusters per UAX #29 (Unicode 17.0.0): GB9a/GB9b
  (spacing marks, prepend), GB9c (Indic conjuncts — `क्‍ष` is one
  cluster), GB11 (emoji ZWJ sequences), GB12/13 (regional-indicator
  pairs). GB3 (CR × LF) is unreachable under the input contract.
* Verified against the full contract-valid subset of the official UCD
  `GraphemeBreakTest.txt` (555/555 tests).
* Cluster slices are views into the span — valid only while the span is
  alive. Use `String.new(cluster)` if you need an owning string.
* The grapheme tables are a separately generated file
  (`src/span-width/grapheme_tables.cr`); nothing here is compiled into
  your binary unless you require `span-width/grapheme`.

## Performance

Measured with `crystal run --release bench/bench.cr` (x86-64, indicative —
run it on your own hardware):

| corpus        | scalar mode     | grapheme mode (segment + measure) |
| ------------- | --------------- | --------------------------------- |
| ASCII         | ~6.8 GiB/s      | ~60 MiB/s (per-cluster callback)  |
| Latin-1       | ~350 MiB/s      | ~65 MiB/s                         |
| CJK           | ~460 MiB/s      | ~130 MiB/s                        |
| Hangul        | ~380 MiB/s      | ~110 MiB/s                        |
| emoji-heavy   | ~430 MiB/s      | ~100 MiB/s                        |
| mixed         | ~500 MiB/s      | ~85 MiB/s                         |
| short spans   | 14–42 ns/call, **0 B allocated** |                 |

Scalar mode: an 8-bytes-at-a-time ASCII fast path (SWAR), a two-level page
table (≈32 KB, cache-resident) giving O(1) branch-free per-scalar width for
everything else, and no allocations anywhere — spans are read in place and
the same objects stream out. Grapheme mode adds a UAX #29 state machine on
the same table infrastructure; its cost is dominated by the per-cluster
callback, which is inherent to segmentation.

## Regenerating the tables and fixtures

Tables are committed, so shard users need no network. To move to a newer
Unicode release:

```sh
# regenerates src/span-width/tables.cr AND src/span-width/grapheme_tables.cr
crystal run tools/gen_tables.cr -- --version 17.0.0
# or from local UCD files:
crystal run tools/gen_tables.cr -- --dir /path/to/ucd/files

# refreshes the grapheme spec fixture (contract-valid GraphemeBreakTest subset)
crystal run tools/gen_grapheme_tests.cr -- --version 17.0.0
```

## Development

```sh
crystal spec                        # unit + table-boundary + full-range consistency
                                    # + GraphemeBreakTest suite
crystal spec -Dspan_width_debug     # also exercise contract validation
crystal run --release bench/bench.cr
crystal run --release bench/grapheme_bench.cr

# cross-check all 1.1M scalar widths against Python's unicodedata
# (mismatches = codepoints whose data changed between the two UCD versions)
crystal run tools/dump_widths.cr -- widths.tsv
python3 tools/verify.py widths.tsv
```

## License

MIT — see LICENSE.
