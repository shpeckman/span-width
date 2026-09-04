# src/span-width/grapheme.cr
require "../span-width"
require "./grapheme_tables"

# Opt-in grapheme cluster segmentation (UAX #29, Unicode 17.0.0), layered
# on the span-width engine. Load it explicitly:
#
#   require "span-width/grapheme"
#
# Scalar mode answers "how many cells is this span?". Grapheme mode answers
# "where are the cluster boundaries?" — needed by renderers targeting
# terminals that measure per grapheme cluster (kitty, foot, WezTerm), and
# by any code that must not split a cluster (cursor movement, wrapping,
# truncation, damage regions).
#
# The same input contract applies: valid UTF-8, no ANSI escapes, no C0/C1
# control characters. GB3 (CR × LF) is unreachable under that contract.
# These are *extended* grapheme clusters, including GB9a/GB9b (spacing
# marks, prepend) and GB9c (Indic conjuncts: "क्‍ष" is one cluster).
#
# Clusters are yielded as zero-copy `Slice(UInt8)` views into the original
# span — valid only while that span is alive. Use `String.new(cluster)` if
# you need an owning string. Cluster widths use the same documented model
# as the scalar engine (`SpanWidth.measure` of the cluster bytes).
module SpanWidth::Grapheme
  extend self

  # Grapheme_Cluster_Break classes — the low nibble of the packed table
  # byte. Must match GCB_VALUES in tools/gen_tables.cr.
  private GCB_OTHER   =  0_u8
  private GCB_CR      =  1_u8
  private GCB_LF      =  2_u8
  private GCB_CONTROL =  3_u8
  private GCB_EXTEND  =  4_u8
  private GCB_ZWJ     =  5_u8
  private GCB_RI      =  6_u8
  private GCB_PREPEND =  7_u8
  private GCB_SPACING =  8_u8
  private GCB_L       =  9_u8
  private GCB_V       = 10_u8
  private GCB_T       = 11_u8
  private GCB_LV      = 12_u8
  private GCB_LVT     = 13_u8

  private EXTPICT_BIT = 0x10_u8

  # Indic_Conjunct_Break classes — bits 5-6 of the packed table byte.
  # Must match INCB_VALUES in tools/gen_tables.cr.
  private INCB_NONE      = 0_u8
  private INCB_CONSONANT = 1_u8
  private INCB_LINKER    = 2_u8
  private INCB_EXTEND    = 3_u8
  private INCB_SHIFT     =    5

  # Segments `span` into grapheme clusters, yielding each cluster as a
  # zero-copy byte-slice view into the span.
  def each(span : String, & : Slice(UInt8) ->) : Nil
    each(span.to_slice) { |cluster| yield cluster }
  end

  # Segments a raw UTF-8 byte span into grapheme clusters.
  def each(bytes : Slice(UInt8), & : Slice(UInt8) ->) : Nil
    size = bytes.size
    return if size == 0
    ptr = bytes.to_unsafe

    cp, len = decode(ptr, 0)
    prev_gcb, ep, incb = classify(cp)
    ri_count      = prev_gcb == GCB_RI ? 1 : 0
    ext_run       = ep      # inside an "Extended_Pictographic Extend*" run
    zwj_armed     = false # ExtPict Extend* ZWJ seen, GB11 may apply
    incb_state    = incb == INCB_CONSONANT ? 1 : 0
    cluster_start = 0
    i             = len

    while i < size
      cp, len = decode(ptr, i)
      gcb, ep, incb = classify(cp)

      if boundary?(prev_gcb, gcb, ep, ri_count, zwj_armed, incb, incb_state)
        yield bytes[cluster_start, i - cluster_start]
        cluster_start = i
        ri_count      = 0
        ext_run       = false
        zwj_armed     = false
        incb_state    = 0
      end

      # Fold the current scalar into the cluster state.
      if gcb == GCB_RI
        ri_count += 1
      else
        ri_count = 0
      end
      if ep
        ext_run   = true
        zwj_armed = false
      elsif gcb == GCB_EXTEND
        # ExtPict Extend* — the run continues
      elsif gcb == GCB_ZWJ && ext_run
        zwj_armed = true
        ext_run   = false
      else
        ext_run   = false
        zwj_armed = false
      end
      # GB9c conjunct state: 0 = no qualifying prefix, 1 = consonant seen,
      # 2 = consonant + at least one linker (only linkers/extends between).
      case incb
      when INCB_CONSONANT then incb_state = 1
      when INCB_LINKER    then incb_state = 2 if incb_state >= 1
      when INCB_EXTEND    then # consonant/linker run continues
      else                     incb_state = 0
      end

      prev_gcb = gcb
      i += len
    end

    yield bytes[cluster_start, size - cluster_start]
  end

  # Width of a single grapheme cluster in terminal cells — the same
  # documented model as scalar mode (`SpanWidth.measure` of the cluster).
  def measure(cluster : String) : Int32
    SpanWidth.measure(cluster)
  end

  def measure(cluster : Slice(UInt8)) : Int32
    SpanWidth.measure(cluster)
  end

  # Segments `span` and measures each cluster in one pass.
  def measure_each(span : String, & : Slice(UInt8), Int32 ->) : Nil
    each(span) { |cluster| yield cluster, SpanWidth.measure(cluster) }
  end

  def measure_each(bytes : Slice(UInt8), & : Slice(UInt8), Int32 ->) : Nil
    each(bytes) { |cluster| yield cluster, SpanWidth.measure(cluster) }
  end

  # Streams `spans`, segmenting each into clusters and yielding every
  # cluster with its width. Span boundaries are hard cluster boundaries —
  # a cluster never spans two input spans.
  def measure_each(spans : Enumerable(String), & : Slice(UInt8), Int32 ->) : Nil
    spans.each do |span|
      measure_each(span) { |cluster, width| yield cluster, width }
    end
  end

  # --- internals ---------------------------------------------------------

  # UAX #29 extended grapheme cluster boundary rules, in priority order.
  @[AlwaysInline]
  private def boundary?(prev_gcb : UInt8, gcb : UInt8, ep : Bool, ri_count : Int32, zwj_armed : Bool, incb : UInt8, incb_state : Int32) : Bool
    # Fast path: a plain scalar after a plain scalar always breaks (GB999).
    # prev_gcb == Other implies ri_count == 0 and zwj_armed == false.
    return true if prev_gcb == GCB_OTHER && gcb == GCB_OTHER && !ep && incb != INCB_CONSONANT
    # GB4, GB5: break around controls. CR/LF cannot occur per the input
    # contract; GCB Control covers format characters (ZWSP, ...) that can.
    return true if prev_gcb == GCB_CR || prev_gcb == GCB_LF || prev_gcb == GCB_CONTROL
    return true if gcb == GCB_CR || gcb == GCB_LF || gcb == GCB_CONTROL
    # GB6-GB8: Hangul syllable sequences.
    return false if prev_gcb == GCB_L && {GCB_L, GCB_V, GCB_LV, GCB_LVT}.includes?(gcb)
    return false if {GCB_LV, GCB_V}.includes?(prev_gcb) && {GCB_V, GCB_T}.includes?(gcb)
    return false if {GCB_LVT, GCB_T}.includes?(prev_gcb) && gcb == GCB_T
    # GB9, GB9a, GB9b.
    return false if gcb == GCB_EXTEND || gcb == GCB_ZWJ
    return false if gcb == GCB_SPACING
    return false if prev_gcb == GCB_PREPEND
    # GB9c: Consonant [Extend|Linker]* Linker [Extend|Linker]* × Consonant.
    return false if incb == INCB_CONSONANT && incb_state == 2
    # GB11: ExtPict Extend* ZWJ × ExtPict.
    return false if ep && zwj_armed
    # GB12/GB13: regional indicators pair up.
    return false if gcb == GCB_RI && prev_gcb == GCB_RI && ri_count.odd?
    # GB999.
    true
  end

  # GCB class, Extended_Pictographic flag and Indic_Conjunct_Break class
  # for a scalar. ASCII scalars are always (Other, false, None) — skip
  # the table lookup entirely.
  @[AlwaysInline]
  private def classify(cp : UInt32) : {UInt8, Bool, UInt8}
    return {GCB_OTHER, false, INCB_NONE} if cp < 0x80
    packed = GRAPHEME_PAGES.unsafe_fetch(
      (GRAPHEME_INDEX.unsafe_fetch((cp >> 8).to_i).to_i << 8) + (cp & 0xFF).to_i
    )
    {packed & 0x0F_u8, (packed & EXTPICT_BIT) != 0, (packed >> INCB_SHIFT) & 0x3_u8}
  end

  # Same decoder as the scalar engine (duplicated so this module stays a
  # self-contained opt-in). Input is valid UTF-8 by contract.
  @[AlwaysInline]
  private def decode(ptr : UInt8*, i : Int32) : {UInt32, Int32}
    b0 = ptr[i].to_u32
    if b0 < 0x80
      {b0, 1}
    elsif b0 < 0xE0
      {((b0 & 0x1F) << 6) |
        (ptr[i + 1].to_u32 & 0x3F), 2}
    elsif b0 < 0xF0
      {((b0 & 0x0F) << 12) |
        ((ptr[i + 1].to_u32 & 0x3F) << 6) |
        (ptr[i + 2].to_u32 & 0x3F), 3}
    else
      {((b0 & 0x07) << 18) |
        ((ptr[i + 1].to_u32 & 0x3F) << 12) |
        ((ptr[i + 2].to_u32 & 0x3F) << 6) |
        (ptr[i + 3].to_u32 & 0x3F), 4}
    end
  end
end
