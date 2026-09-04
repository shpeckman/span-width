# Makefile
# Makefile — span-width shard
#
#   make setup          first-time setup: regenerate tables + fixture, run specs
#   make spec           run the test suite
#   make spec-debug     run the suite with contract validation (-Dspan_width_debug)
#   make bench          run both throughput benchmarks (release build)
#   make verify         cross-check all scalar widths against Python unicodedata
#   make gen-tables     regenerate the lookup tables from the UCD
#   make gen-tests      regenerate the GraphemeBreakTest fixture from the UCD
#   make docs           generate API docs into docs/
#   make format         format sources (verify only: make format-check)
#   make clean          remove generated artifacts
#   make clean-full     also remove shards artifacts and built binaries

CRYSTAL         ?= crystal
PYTHON          ?= python3
UNICODE_VERSION ?= 17.0.0

SOURCES := $(wildcard src/span-width.cr src/span-width/*.cr)

.PHONY: all setup spec spec-debug bench bench-width bench-grapheme verify \
        gen-tables gen-tests docs format format-check clean clean-full clean-generated

all: setup

# First-time setup after a fresh clone: the generated tables and fixture
# are not committed, so regenerate them from the UCD before running specs.
# Downloads from unicode.org.
setup: gen-tables gen-tests spec

# NOTE: run from the project root — the grapheme spec reads
# spec/fixtures/GraphemeBreakTest.txt via a relative path.
spec:
	$(CRYSTAL) spec

# spec/contract_debug_spec.cr is empty unless compiled with this flag.
spec-debug:
	$(CRYSTAL) spec -Dspan_width_debug

bench: bench-width bench-grapheme

bench-width:
	$(CRYSTAL) run --release bench/bench.cr

bench-grapheme:
	$(CRYSTAL) run --release bench/grapheme_bench.cr

# Cross-checks the generated width tables against an independent
# implementation. Mismatches are EXPECTED and must be eyeballed: Python
# usually ships an older UCD than UNICODE_VERSION (see tools/verify.py).
widths.tsv: $(SOURCES) tools/dump_widths.cr
	$(CRYSTAL) run tools/dump_widths.cr -- $@

verify: widths.tsv
	$(PYTHON) tools/verify.py widths.tsv

# Regenerating downloads from unicode.org; review and commit the results.
gen-tables:
	$(CRYSTAL) run tools/gen_tables.cr -- --version $(UNICODE_VERSION)

gen-tests:
	$(CRYSTAL) run tools/gen_grapheme_tests.cr -- --version $(UNICODE_VERSION)

docs:
	$(CRYSTAL) docs

format:
	$(CRYSTAL) tool format src spec bench tools

format-check:
	$(CRYSTAL) tool format --check src spec bench tools

clean:
	rm -f widths.tsv
	rm -rf docs

# Everything clean removes, plus shards artifacts and any locally built
# binaries. The generated tables and fixtures (regenerate with make setup)
# are deliberately NOT removed.
clean-full: clean
	rm -rf lib bin .shards
	rm -f shard.lock

clean-generated: clean-full
	rm -f src/span-width/grapheme_tables.cr src/span-width/tables.cr spec/fixtures/GraphemeBreakTest.txt
