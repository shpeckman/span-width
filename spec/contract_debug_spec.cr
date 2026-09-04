# spec/contract_debug_spec.cr
require "./spec_helper"

# Contract validation is compiled in only with `-Dspan_width_debug`.
# This spec is empty in normal builds; run
#   crystal spec -Dspan_width_debug
# to exercise it.
{% if flag?(:span_width_debug) %}
  describe "span-width contract validation (-Dspan_width_debug)" do
    it "raises on C0 control bytes" do
      expect_raises(ArgumentError, /control byte/) { SpanWidth.measure("a\tb") }
      expect_raises(ArgumentError, /control byte/) { SpanWidth.measure("line\n") }
    end

    it "raises on DEL" do
      expect_raises(ArgumentError, /control byte/) { SpanWidth.measure("a\u{7F}b") }
    end

    it "raises on C1 control characters" do
      expect_raises(ArgumentError, /control character/) { SpanWidth.measure("a\u{85}b") }
    end

    it "accepts clean text" do
      SpanWidth.measure("Hello, 世界! 👋").should eq 15
    end
  end
{% end %}
