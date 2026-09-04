# spec/grapheme_spec.cr
require "./spec_helper"
require "../src/span-width/grapheme"

alias Grapheme = SpanWidth::Grapheme

private def clusters_of(span : String) : Array(String)
  clusters = [] of String
  Grapheme.each(span) { |c| clusters << String.new(c) }
  clusters
end

describe SpanWidth::Grapheme do
  describe ".each" do
    it "segments ASCII into single-character clusters" do
      clusters_of("abc").should eq ["a", "b", "c"]
    end

    it "returns nothing for empty spans" do
      clusters_of("").should be_empty
    end

    it "keeps combining marks with their base" do
      clusters_of("éx").should eq ["é", "x"]
      clusters_of("ə̴̥̆!").should eq ["ə̴̥̆", "!"]
    end

    it "keeps ZWJ emoji sequences together" do
      clusters_of("👨‍👩‍👧‍👦").should eq ["👨‍👩‍👧‍👦"]
      clusters_of("a👩‍💻b").should eq ["a", "👩‍💻", "b"]
    end

    it "keeps skin-tone-modified emoji together" do
      clusters_of("👍🏽").should eq ["👍🏽"]
    end

    it "keeps VS16 sequences together" do
      clusters_of("\u{2764}\u{FE0F}").should eq ["\u{2764}\u{FE0F}"]
      clusters_of("1\u{FE0F}\u{20E3}").should eq ["1\u{FE0F}\u{20E3}"]
    end

    it "pairs regional indicators, breaks between pairs" do
      clusters_of("🇺🇸🇨🇦").should eq ["🇺🇸", "🇨🇦"]
      clusters_of("🇦🇧🇨").should eq ["🇦🇧", "🇨"]
    end

    it "keeps Hangul jamo syllables together" do
      clusters_of("학").should eq ["학"]
      clusters_of("학교").should eq ["학", "교"]
    end

    it "keeps Indic conjuncts together (GB9c)" do
      clusters_of("क्‍ष").should eq ["क्‍ष"] # consonant + virama + ZWJ + consonant
      clusters_of("क्त").should eq ["क्त"]   # consonant + virama + consonant
      clusters_of("कत").should eq ["क", "त"] # no linker: no conjunct
      clusters_of("aक्तb").should eq ["a", "क्त", "b"]
    end

    it "breaks around zero-width format characters" do
      clusters_of("AB").should eq ["A", "", "B"]
    end

    it "yields zero-copy views into the span" do
      span  = "日本語"
      bytes = span.to_slice
      Grapheme.each(span) do |cluster|
        offset = cluster.to_unsafe - bytes.to_unsafe
        offset.should be >= 0
        offset.should be < bytes.size
      end
    end
  end

  describe ".measure" do
    it "measures clusters with the scalar width model" do
      Grapheme.measure("👨‍👩‍👧‍👦").should eq 2
      Grapheme.measure("👍🏽").should eq 2
      Grapheme.measure("🇺🇸").should eq 2
      Grapheme.measure("\u{2764}\u{FE0F}").should eq 2
      Grapheme.measure("1\u{FE0F}\u{20E3}").should eq 2
      Grapheme.measure("학").should eq 2
      Grapheme.measure("é").should eq 1
      Grapheme.measure("日").should eq 2
    end
  end

  describe ".measure_each" do
    it "segments and measures one span in a single pass" do
      collected = [] of {String, Int32}
      Grapheme.measure_each("a👨‍👩‍👧‍👦日") { |c, w| collected << {String.new(c), w} }
      collected.should eq [{"a", 1}, {"👨‍👩‍👧‍👦", 2}, {"日", 2}]
    end

    it "streams over spans, treating span boundaries as hard breaks" do
      collected = [] of {String, Int32}
      Grapheme.measure_each(["👨", "‍👩"]) { |c, w| collected << {String.new(c), w} }
      # the ZWJ belongs to the second span, and a span-initial ZWJ joins
      # nothing (GB11 needs an ExtPict before it), so no cross-span join
      collected.should eq [{"👨", 2}, {"‍", 0}, {"👩", 2}]
    end
  end

  # The contract-valid subset of the official UCD GraphemeBreakTest suite,
  # committed at spec/fixtures/GraphemeBreakTest.txt. Run from the project
  # root: crystal spec
  it "passes the UCD GraphemeBreakTest suite (contract-valid subset)" do
    tests    = 0
    failures = [] of String

    File.each_line("spec/fixtures/GraphemeBreakTest.txt") do |line|
      next unless line.starts_with?('÷')
      tokens = line.split('#', 2)[0].split

      cps           = [] of UInt32
      break_before  = [] of Bool
      pending_break = true
      tokens.each do |token|
        case token
        when "÷" then pending_break = true
        when "×" then pending_break = false
        else
          cps << token.to_u32(16)
          break_before << pending_break
        end
      end

      expected = [] of String
      current  = [] of UInt32
      cps.each_with_index do |cp, k|
        if k > 0 && break_before[k]
          expected << String.build { |io| current.each { |c| io << c.chr } }
          current = [] of UInt32
        end
        current << cp
      end
      expected << String.build { |io| current.each { |c| io << c.chr } } unless current.empty?

      actual = clusters_of(String.build { |io| cps.each { |cp| io << cp.chr } })

      unless actual == expected
        failures << line
      end
      tests += 1
    end

    if failures.any?
      fail "#{failures.size}/#{tests} GraphemeBreakTest failures, first:\n#{failures.first}"
    end
    tests.should be > 500 # sanity: the fixture actually ran
  end
end
