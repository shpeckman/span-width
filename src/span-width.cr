# src/span-width.cr
require "./span-width/tables"

# span-width measures the terminal cell width of clean text spans.
#
# Contract: spans are valid UTF-8 text containing no ANSI escape sequences
# and no control characters (C0, DEL, C1). Under that contract `measure`
# performs no validation and never fails. Compile with `-Dspan_width_debug`
# during development to validate the contract and raise on violations.
#
# Width model (wcwidth-compatible — what most terminals assume):
#   * East Asian Wide/Fullwidth                      -> 2 cells
#   * combining marks (Mn/Me), ZWSP/ZWNJ/ZWJ, word joiner, BOM,
#     Hangul jamo vowels & final consonants, emoji skin-tone modifiers,
#     variation selectors, tag characters            -> 0 cells
#   * a scalar joined to an emoji by U+200D (ZWJ) adds no cells (👨‍👩‍👧‍👦 = 2)
#   * a narrow emoji base followed by U+FE0F (VS16)  -> 2 cells (❤️ = 2)
#   * everything else                                -> 1 cell
#
# All measurement is allocation-free: spans are read in place and never
# copied, so the same `String`/`Slice` you hand in is what streams out.
module SpanWidth
  VERSION = "0.3.0"

  extend self

  # Property bits packed into the WIDTH_PAGES bytes (see tables.cr).
  private WIDTH_EXTPICT_BIT = 0x20_u8
  private WIDTH_VS16_BIT    = 0x40_u8
  private WIDTH_EMOJI_BIT   = 0x80_u8

  # Width of `span` in terminal cells.
  def measure(span : String) : Int32
    measure(span.to_slice)
  end

  # Width of a raw UTF-8 byte span in terminal cells.
  def measure(bytes : Slice(UInt8)) : Int32
    {% if flag?(:span_width_debug) %}
      validate_contract!(bytes)
    {% end %}

    width = 0
    i = 0
    size = bytes.size
    ptr = bytes.to_unsafe
    joined = false     # previous scalar was U+200D (ZWJ) following an emoji
    prev_emoji = false # last width-contributing scalar was a pictographic emoji
    prev_zwj = false   # previous scalar was U+200D (a doubled ZWJ breaks the run)

    while i < size
      # Fast path: consume eight ASCII bytes at a time.
      swar_start = i
      while i + 8 <= size
        word = (ptr + i).as(UInt64*).value
        break if (word & 0x8080_8080_8080_8080_u64) != 0
        width += 8
        i += 8
      end
      # The word-gobbling above consumes plain ASCII only, so any pending
      # ZWJ join ends here and the last scalar seen is narrow. It also
      # cannot see a VS16 widening the last ASCII byte of the final word
      # it consumed ("Score: 1️⃣"); correct for both.
      if i > swar_start
        joined = false
        prev_emoji = false
        prev_zwj = false
        if i < size && ptr[i] == 0xEF_u8 && vs16_follows?(ptr, i, size) &&
           in_ranges?(ptr[i - 1].to_u32, VS16_WIDE)
          width += 1
        end
      end
      break if i >= size

      if ptr[i] < 0x80_u8
        # VS16 widens the ASCII emoji bases ('#', '*', digits) to 2 cells.
        # The first byte of U+FE0F is 0xEF, so this check short-circuits
        # on virtually every ASCII character. No ASCII scalar is
        # Extended_Pictographic, so none of them can head a ZWJ sequence.
        if vs16_follows?(ptr, i + 1, size) && in_ranges?(ptr[i].to_u32, VS16_WIDE)
          width += 2
        else
          width += 1
        end
        prev_emoji = false
        i += 1
        joined = false
        prev_zwj = false
      else
        cp, len = decode(ptr, i)
        if cp == 0x200D_u32
          # ZWJ only joins emoji sequences ("👨‍👩‍👧‍👦"); after anything else
          # it is just a zero-width format character. A doubled ZWJ breaks
          # the run (GB11 allows only Extend* between the pictographs).
          joined = prev_emoji && !prev_zwj
          prev_zwj = true
        else
          entry = char_width_entry(cp)
          # Swallow the ZWJ-joined scalar only when it is itself pictographic
          # (GB11's right-hand side is Extended_Pictographic): regional
          # indicators are not, and a ZWJ followed by a non-emoji scalar
          # must not hide what follows.
          emoji_join = joined && (entry & WIDTH_EXTPICT_BIT) != 0
          # A ZWJ whose successor is not pictographic is a failed join:
          # the emoji run is over even if the successor is zero-width.
          zwj_failed = joined && !emoji_join
          joined = false
          prev_zwj = false
          unless emoji_join
            w = (entry & 0x3_u8).to_i
            vs16_widened = w == 1 && (entry & WIDTH_VS16_BIT) != 0 &&
                           vs16_follows?(ptr, i + len, size)
            w = 2 if vs16_widened
            width += w
            if w == 0
              # Zero-width scalars that cannot appear inside an emoji ZWJ
              # run (GB4-ish format characters, Hangul jamo vowels/finals)
              # end any pending join; combining marks, variation selectors
              # and skin tones let it continue (GB11: ExtPict Extend* ZWJ).
              if zwj_failed || cp == 0x200B_u32 || cp == 0x2060_u32 || cp == 0xFEFF_u32 ||
                 (0x1160_u32 <= cp <= 0x11FF_u32) || (0xD7B0_u32 <= cp <= 0xD7FF_u32)
                prev_emoji = false
              end
            elsif vs16_widened
              # A VS16-widened base heads a ZWJ sequence only when it is
              # pictographic (❤️ is; digits, '#' and '*' are not).
              prev_emoji = (entry & WIDTH_EXTPICT_BIT) != 0
            else
              # Only a real emoji (2 cells via Emoji_Presentation) arms the
              # ZWJ join — plain wide scalars like CJK ideographs do not.
              prev_emoji = w == 2 && (entry & WIDTH_EMOJI_BIT) != 0
            end
          end
        end
        i += len
      end
    end
    width
  end

  # Width of a single scalar value in terminal cells.
  #
  # Context-free by nature: a lone `Char` cannot express ZWJ joins or a
  # following VS16, so `width('❤')` is 1 while `measure("❤️")` is 2.
  def width(char : Char) : Int32
    char_width(char.ord.to_u32)
  end

  # Streams `spans`, yielding each span together with its width. Zero-copy:
  # the yielded span is the same object that went in.
  def each(spans : Enumerable(String), & : String, Int32 ->) : Nil
    spans.each { |span| yield span, measure(span) }
  end

  # Lazy streaming: maps a span iterator to `{span, width}` tuples.
  def each(spans : Iterator(String)) : Iterator({String, Int32})
    spans.map { |span| {span, measure(span)} }
  end

  # Lazy streaming over any iterable of spans (Array, Set, ...).
  def each(spans : Iterable(String)) : Iterator({String, Int32})
    each(spans.each)
  end

  # Streams the lines of `io`, yielding each line together with its width.
  def each_line(io : IO, & : String, Int32 ->) : Nil
    while line = io.gets(chomp: true)
      yield line, measure(line)
    end
  end

  # --- internals ---------------------------------------------------------

  # Decodes the scalar starting at offset `i`. Input is valid UTF-8 by
  # contract, so no validation is performed.
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

  # Per-scalar width via a two-level table: one page-slot lookup, one page
  # lookup, no branching. Valid for every scalar (control characters are
  # excluded by contract and never reach here).
  @[AlwaysInline]
  private def char_width(cp : UInt32) : Int32
    (char_width_entry(cp) & 0x3_u8).to_i
  end

  # The raw packed table byte for a scalar: cell width in bits 0-1, plus
  # emoji property bits (see tables.cr). ASCII is handled on the byte fast
  # path and never carries property bits; everything else comes from the
  # tables (© and ® at U+00A9/U+00AE already carry emoji bits).
  @[AlwaysInline]
  private def char_width_entry(cp : UInt32) : UInt8
    return 1_u8 if cp < 0x80
    WIDTH_PAGES.unsafe_fetch(
      (WIDTH_INDEX.unsafe_fetch((cp >> 8).to_i).to_i << 8) + (cp & 0xFF).to_i
    )
  end

  # True if the bytes at offset `i` start U+FE0F (variation selector-16).
  @[AlwaysInline]
  private def vs16_follows?(ptr : UInt8*, i : Int32, size : Int32) : Bool
    i + 3 <= size &&
      ptr[i] == 0xEF_u8 && ptr[i + 1] == 0xB8_u8 && ptr[i + 2] == 0x8F_u8
  end

  private def in_ranges?(cp : UInt32, table : Slice(UInt32)) : Bool
    lo = 0
    hi = (table.size >> 1) - 1
    while lo <= hi
      mid = (lo + hi) >> 1
      if cp < table.unsafe_fetch(mid * 2)
        hi = mid - 1
      elsif cp > table.unsafe_fetch(mid * 2 + 1)
        lo = mid + 1
      else
        return true
      end
    end
    false
  end

  # Development-time contract validation; only reachable when compiled
  # with `-Dspan_width_debug`, and eliminated entirely otherwise.
  private def validate_contract!(bytes : Slice(UInt8)) : Nil
    ptr = bytes.to_unsafe
    i = 0
    size = bytes.size
    while i < size
      b = ptr[i]
      if b < 0x20_u8 || b == 0x7F_u8
        raise ArgumentError.new "span-width contract violated: control byte 0x#{b.to_s(16, precision: 2, upcase: true)} at offset #{i}"
      elsif b < 0x80_u8
        i += 1
      else
        cp, len = decode(ptr, i)
        if 0x80_u32 <= cp <= 0x9F_u32
          raise ArgumentError.new "span-width contract violated: control character U+#{cp.to_s(16, precision: 4, upcase: true)} at offset #{i}"
        end
        i += len
      end
    end
  end
end
