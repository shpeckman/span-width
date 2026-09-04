# tools/gen_tables.cr
require "http/client"
require "option_parser"
require "bit_array"

# Generates the shard's lookup tables from Unicode Character Database files:
#
#   src/span-width/tables.cr          (scalar cell widths)
#   src/span-width/grapheme_tables.cr (grapheme cluster break properties)
#
#   crystal run tools/gen_tables.cr -- [--version 17.0.0] [--dir DIR]
#                                       [--out PATH] [--grapheme-out PATH]
#
# Without --dir the UCD files are downloaded from unicode.org. With --dir
# they are read from DIR instead (expects EastAsianWidth.txt,
# DerivedGeneralCategory.txt, emoji-data.txt, GraphemeBreakProperty.txt).
#
# The generated tables are committed to the repo, so shard users never
# need network access; regenerate them deliberately when moving to a new
# Unicode version.
module GenTables
  extend self

  MAX_CP = 0x10FFFF

  # Grapheme_Cluster_Break classes, packed into the low nibble of the
  # grapheme table bytes. Must match the GCB_* constants in
  # src/span-width/grapheme.cr.
  GCB_VALUES = {
    "Other" => 0_u8, "CR" => 1_u8, "LF" => 2_u8, "Control" => 3_u8,
    "Extend" => 4_u8, "ZWJ" => 5_u8, "Regional_Indicator" => 6_u8,
    "Prepend" => 7_u8, "SpacingMark" => 8_u8, "L" => 9_u8, "V" => 10_u8,
    "T" => 11_u8, "LV" => 12_u8, "LVT" => 13_u8,
  }
  EXTPICT_BIT = 0x10_u8

  # Indic_Conjunct_Break classes, packed into bits 5-6 of the grapheme
  # table bytes. Must match the INCB_* constants in src/span-width/grapheme.cr.
  INCB_VALUES = {"None" => 0_u8, "Consonant" => 1_u8, "Linker" => 2_u8, "Extend" => 3_u8}
  INCB_SHIFT  = 5

  def run
    version = "17.0.0"
    out_path = "src/span-width/tables.cr"
    grapheme_out = "src/span-width/grapheme_tables.cr"
    dir : String? = nil

    OptionParser.parse do |parser|
      parser.banner = "Usage: crystal run tools/gen_tables.cr -- [options]"
      parser.on("--version VERSION", "UCD version (default: #{version})") { |v| version = v }
      parser.on("--out PATH", "width tables output (default: #{out_path})") { |v| out_path = v }
      parser.on("--grapheme-out PATH", "grapheme tables output (default: #{grapheme_out})") { |v| grapheme_out = v }
      parser.on("--dir DIR", "read UCD files from DIR instead of downloading") { |v| dir = v }
      parser.on("-h", "--help", "show this help") { puts parser; exit }
    end

    eaw, dgc, emoji, gbp, dcp = load_sources(version, dir)

    zero = BitArray.new(MAX_CP + 1)
    wide = BitArray.new(MAX_CP + 1)
    emoji_yes = BitArray.new(MAX_CP + 1)
    emoji_pres = BitArray.new(MAX_CP + 1)
    extpict = BitArray.new(MAX_CP + 1)

    parse_ranges(eaw) do |first, last, fields|
      prop = fields[1]
      next unless prop == "W" || prop == "F"
      fill(wide, first, last)
    end

    parse_ranges(dgc) do |first, last, fields|
      prop = fields[1]
      next unless prop == "Mn" || prop == "Me"
      fill(zero, first, last)
    end

    parse_ranges(emoji) do |first, last, fields|
      case fields[1]
      when "Emoji"                 then fill(emoji_yes, first, last)
      when "Emoji_Presentation"    then fill(emoji_pres, first, last)
      when "Extended_Pictographic" then fill(extpict, first, last)
      end
    end

    # Explicit zero-width additions on top of general categories Mn/Me.
    {
      {0x200B_u32, 0x200D_u32},   # ZWSP, ZWNJ, ZWJ
      {0x2060_u32, 0x2060_u32},   # word joiner
      {0xFEFF_u32, 0xFEFF_u32},   # BOM / zero-width no-break space
      {0x1160_u32, 0x11FF_u32},   # Hangul jamo medial vowels & final consonants
      {0xD7B0_u32, 0xD7FF_u32},   # Hangul jamo extended-B (vowels/finals)
      {0x1F3FB_u32, 0x1F3FF_u32}, # emoji skin-tone modifiers
      {0xE0001_u32, 0xE007F_u32}, # tag characters
    }.each { |(first, last)| fill(zero, first, last) }

    # Zero takes precedence over wide; keep the tables disjoint.
    (MAX_CP + 1).times { |cp| wide[cp] = false if zero[cp] }

    # Narrow emoji bases that become 2 cells wide when followed by U+FE0F.
    vs16 = BitArray.new(MAX_CP + 1)
    (MAX_CP + 1).times do |cp|
      vs16[cp] = true if emoji_yes[cp] && !emoji_pres[cp] && !wide[cp] && !zero[cp]
    end

    # Flat per-scalar width table. Low 2 bits: cell width (0, 1 or 2).
    # Bit 7: Emoji_Presentation=Yes (width-2 emoji that can head a ZWJ
    # sequence). Bit 6: narrow emoji base widened by U+FE0F. Bit 5:
    # Extended_Pictographic (GB11 join target). The runtime never does
    # range searches in its hot path — everything is in the page byte.
    widths = Bytes.new(MAX_CP + 1, 1_u8)
    (MAX_CP + 1).times do |cp|
      widths[cp] = 0_u8 if zero[cp]
      widths[cp] = 2_u8 if wide[cp]
      widths[cp] |= 0x80_u8 if emoji_pres[cp]
      widths[cp] |= 0x40_u8 if vs16[cp]
      widths[cp] |= 0x20_u8 if extpict[cp]
    end
    width_index, width_pages = two_level(widths)

    write_widths(out_path, version, ranges(zero), ranges(wide), ranges(emoji_pres), ranges(extpict), ranges(vs16), width_index, width_pages)

    # --- grapheme cluster break tables -----------------------------------

    gcb = Bytes.new(MAX_CP + 1, GCB_VALUES["Other"])
    parse_ranges(gbp) do |first, last, fields|
      if value = GCB_VALUES[fields[1]]?
        fill_bytes(gcb, first, last, value)
      end
    end
    (MAX_CP + 1).times { |cp| gcb[cp] |= EXTPICT_BIT if extpict[cp] }

    # Indic_Conjunct_Break (GB9c) — from DerivedCoreProperties.txt, where
    # InCB appears as a three-field derived property: cp ; InCB ; value.
    incb = Bytes.new(MAX_CP + 1, INCB_VALUES["None"])
    parse_ranges(dcp) do |first, last, fields|
      next unless fields.size >= 3 && fields[1] == "InCB"
      if value = INCB_VALUES[fields[2]]?
        fill_bytes(incb, first, last, value)
      end
    end
    (MAX_CP + 1).times { |cp| gcb[cp] |= incb[cp] << INCB_SHIFT }
    gcb_index, gcb_pages = two_level(gcb)

    write_grapheme(grapheme_out, version, gcb_index, gcb_pages)
  end

  # Splits a flat per-scalar byte array into 256-scalar pages,
  # deduplicates the pages, and returns {page_index, unique_pages}.
  def two_level(flat : Bytes) : {Array(Int32), Array(Bytes)}
    unique_pages = [] of Bytes
    index = [] of Int32
    ((MAX_CP + 1) // 256).times do |page|
      bytes = flat[page * 256, 256]
      if found = unique_pages.index { |u| u == bytes }
        index << found
      else
        unique_pages << bytes
        index << unique_pages.size - 1
      end
    end
    raise "more than 256 unique pages; widen the index table to UInt16" if unique_pages.size > 256
    {index, unique_pages}
  end

  def load_sources(version : String, dir : String?) : {String, String, String, String, String}
    if d = dir
      STDERR << "reading UCD files from " << d << '\n'
      {File.read(File.join(d, "EastAsianWidth.txt")),
       File.read(File.join(d, "DerivedGeneralCategory.txt")),
       File.read(File.join(d, "emoji-data.txt")),
       File.read(File.join(d, "GraphemeBreakProperty.txt")),
       File.read(File.join(d, "DerivedCoreProperties.txt"))}
    else
      base = "https://www.unicode.org/Public/#{version}/"
      {fetch(base + "ucd/EastAsianWidth.txt"),
       fetch(base + "ucd/extracted/DerivedGeneralCategory.txt"),
       fetch(base + "ucd/emoji/emoji-data.txt"),
       fetch(base + "ucd/auxiliary/GraphemeBreakProperty.txt"),
       fetch(base + "ucd/DerivedCoreProperties.txt")}
    end
  end

  def fetch(url : String) : String
    STDERR << "  GET " << url << '\n'
    HTTP::Client.get(url) do |response|
      unless response.success?
        raise "GET #{url} failed: HTTP #{response.status_code}"
      end
      response.body_io.gets_to_end
    end
  end

  def parse_ranges(text : String, & : UInt32, UInt32, Array(String) ->) : Nil
    text.each_line do |line|
      body = line.split('#', 2)[0]
      next if body.strip.empty?
      fields = body.split(';').map(&.strip)
      next if fields.size < 2
      range = fields[0]
      if range.includes?("..")
        lo, hi = range.split("..", 2)
        yield lo.to_u32(16), hi.to_u32(16), fields
      else
        cp = range.to_u32(16)
        yield cp, cp, fields
      end
    end
  end

  def fill(bits : BitArray, first : UInt32, last : UInt32) : Nil
    cp = first.to_i
    stop = last.to_i
    while cp <= stop
      bits[cp] = true
      cp += 1
    end
  end

  def fill_bytes(bytes : Bytes, first : UInt32, last : UInt32, value : UInt8) : Nil
    cp = first.to_i
    stop = last.to_i
    while cp <= stop
      bytes[cp] = value
      cp += 1
    end
  end

  def ranges(bits : BitArray) : Array({UInt32, UInt32})
    result = [] of {UInt32, UInt32}
    cp = 0
    max = bits.size
    while cp < max
      if bits[cp]
        first = cp
        cp += 1
        while cp < max && bits[cp]
          cp += 1
        end
        result << {first.to_u32, (cp - 1).to_u32}
      else
        cp += 1
      end
    end
    result
  end

  def write_widths(path : String, version : String, zero, wide, emoji_pres_ranges, extpict_ranges, vs16, index : Array(Int32), pages : Array(Bytes)) : Nil
    File.open(path, "w") do |io|
      io << "# GENERATED FILE — do not edit by hand.\n"
      io << "# Unicode " << version << ". Regenerate with:\n"
      io << "#   crystal run tools/gen_tables.cr -- --version " << version << '\n'
      io << "# Sources: EastAsianWidth.txt, DerivedGeneralCategory.txt, emoji-data.txt\n\n"
      io << "module SpanWidth\n"
      io << "  # Two-level per-scalar width table:\n"
      io << "  #   WIDTH_PAGES[WIDTH_INDEX[cp >> 8] * 256 + (cp & 0xFF)]\n"
      io << "  # Packed byte: bits 0-1 = cell width (0/1/2), bit 5 = Extended_Pictographic,\n"
      io << "  # bit 6 = narrow emoji base widened by U+FE0F, bit 7 = Emoji_Presentation.\n"
      io << "  # " << pages.size << " unique 256-scalar pages, " << index.size << " page slots.\n"
      emit_scalars io, "WIDTH_INDEX", index
      io << '\n'
      flat = [] of Int32
      pages.each { |page| page.each { |b| flat << b.to_i32 } }
      emit_scalars io, "WIDTH_PAGES", flat
      io << "\n  # Zero-cell scalars: Mn/Me, ZWSP/ZWNJ/ZWJ, word joiner, BOM, Hangul jamo\n"
      io << "  # vowels & finals, emoji skin-tone modifiers, tag characters.\n"
      emit_ranges io, "ZERO", zero
      io << "\n  # Two-cell scalars: East Asian Wide & Fullwidth (includes emoji\n"
      io << "  # with Emoji_Presentation=Yes).\n"
      emit_ranges io, "WIDE", wide
      io << "\n  # Emoji_Presentation=Yes scalars: rendered 2 cells wide; a ZWJ\n"
      io << "  # directly after one can start an emoji sequence (GB11).\n"
      emit_ranges io, "EMOJI", emoji_pres_ranges
      io << "\n  # Extended_Pictographic scalars: the set a ZWJ can join into an\n"
      io << "  # emoji sequence (GB11) — plain CJK and regional indicators are\n"
      io << "  # wide/emoji but NOT pictographic, so they never join.\n"
      emit_ranges io, "EXTPICT", extpict_ranges
      io << "\n  # Narrow emoji bases: rendered 2 cells wide when followed by U+FE0F.\n"
      emit_ranges io, "VS16_WIDE", vs16
      io << "end\n"
    end
    STDERR.puts "wrote #{path}: " \
                "ZERO=#{zero.size} ranges, WIDE=#{wide.size} ranges, EMOJI=#{emoji_pres_ranges.size} ranges, " \
                "EXTPICT=#{extpict_ranges.size} ranges, VS16_WIDE=#{vs16.size} ranges, #{pages.size} unique width pages"
  end

  def write_grapheme(path : String, version : String, index : Array(Int32), pages : Array(Bytes)) : Nil
    File.open(path, "w") do |io|
      io << "# GENERATED FILE — do not edit by hand.\n"
      io << "# Unicode " << version << ". Regenerate with:\n"
      io << "#   crystal run tools/gen_tables.cr -- --version " << version << '\n'
      io << "# Sources: GraphemeBreakProperty.txt, emoji-data.txt, DerivedCoreProperties.txt\n"
      io << "# Packed per-scalar byte: low nibble = Grapheme_Cluster_Break class, bit 4 =\n"
      io << "# Extended_Pictographic, bits 5-6 = Indic_Conjunct_Break (see grapheme.cr).\n\n"
      io << "module SpanWidth::Grapheme\n"
      io << "  # GRAPHEME_PAGES[GRAPHEME_INDEX[cp >> 8] * 256 + (cp & 0xFF)]\n"
      io << "  # " << pages.size << " unique 256-scalar pages, " << index.size << " page slots.\n"
      emit_scalars io, "GRAPHEME_INDEX", index
      io << '\n'
      flat = [] of Int32
      pages.each { |page| page.each { |b| flat << b.to_i32 } }
      emit_scalars io, "GRAPHEME_PAGES", flat
      io << "end\n"
    end
    STDERR.puts "wrote #{path}: #{pages.size} unique grapheme pages"
  end

  def emit_scalars(io : IO, name : String, values : Array(Int32)) : Nil
    io << "  " << name << " = Slice(UInt8).literal(\n"
    values.each_slice(16) do |group|
      io << "    "
      group.each { |v| io << v << "_u8, " }
      io << '\n'
    end
    io << "  )\n"
  end

  def emit_ranges(io : IO, name : String, table : Array({UInt32, UInt32})) : Nil
    io << "  " << name << " = Slice(UInt32).literal(\n"
    table.each_slice(4) do |group|
      io << "    "
      group.each do |(first, last)|
        io << "0x" << first.to_s(16, precision: 4, upcase: true) << "_u32, "
        io << "0x" << last.to_s(16, precision: 4, upcase: true) << "_u32, "
      end
      io << '\n'
    end
    io << "  )\n"
  end
end

GenTables.run
