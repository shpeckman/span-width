# tools/gen_tables.cr
require "http/client"
require "option_parser"
require "bit_array"

# Generates src/span_width/tables.cr from Unicode Character Database files.
#
#   crystal run tools/gen_tables.cr -- [--version 17.0.0] [--out PATH] [--dir DIR]
#
# Without --dir the UCD files are downloaded from unicode.org. With --dir
# they are read from DIR instead (expects EastAsianWidth.txt,
# DerivedGeneralCategory.txt and emoji-data.txt in that directory).
#
# The generated tables are committed to the repo, so shard users never
# need network access; regenerate them deliberately when moving to a new
# Unicode version.
module GenTables
  extend self

  MAX_CP = 0x10FFFF

  def run
    version  = "17.0.0"
    out_path = "src/span_width/tables.cr"
    dir : String? = nil

    OptionParser.parse do |parser|
      parser.banner = "Usage: crystal run tools/gen_tables.cr -- [options]"
      parser.on("--version VERSION", "UCD version (default: #{version})") { |v| version = v }
      parser.on("--out PATH", "output file (default: #{out_path})") { |v| out_path = v }
      parser.on("--dir DIR", "read UCD files from DIR instead of downloading") { |v| dir = v }
      parser.on("-h", "--help", "show this help") { puts parser; exit }
    end

    eaw, dgc, emoji = load_sources(version, dir)

    zero       = BitArray.new(MAX_CP + 1)
    wide       = BitArray.new(MAX_CP + 1)
    emoji_yes  = BitArray.new(MAX_CP + 1)
    emoji_pres = BitArray.new(MAX_CP + 1)

    parse_ranges(eaw) do |first, last, prop|
      next unless prop == "W" || prop == "F"
      fill(wide, first, last)
    end

    parse_ranges(dgc) do |first, last, prop|
      next unless prop == "Mn" || prop == "Me"
      fill(zero, first, last)
    end

    parse_ranges(emoji) do |first, last, prop|
      case prop
      when "Emoji"              then fill(emoji_yes, first, last)
      when "Emoji_Presentation" then fill(emoji_pres, first, last)
      end
    end

    # Explicit zero-width additions on top of general categories Mn/Me.
    {
      {0x200B_u32,  0x200D_u32},   # ZWSP, ZWNJ, ZWJ
      {0x2060_u32,  0x2060_u32},   # word joiner
      {0xFEFF_u32,  0xFEFF_u32},   # BOM / zero-width no-break space
      {0x1160_u32,  0x11FF_u32},   # Hangul jamo medial vowels & final consonants
      {0xD7B0_u32,  0xD7FF_u32},   # Hangul jamo extended-B (vowels/finals)
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

    # Flat two-level lookup: WIDTH_PAGES[WIDTH_INDEX[cp >> 8] * 256 + cp & 0xFF].
    # Identical 256-scalar pages are deduplicated.
    widths = Bytes.new(MAX_CP + 1, 1_u8)
    (MAX_CP + 1).times do |cp|
      widths[cp] = 0_u8 if zero[cp]
      widths[cp] = 2_u8 if wide[cp]
    end
    unique_pages = [] of Bytes
    index        = [] of Int32
    ((MAX_CP + 1) // 256).times do |page|
      bytes = widths[page * 256, 256]
      if found = unique_pages.index { |u| u == bytes }
        index << found
      else
        unique_pages << bytes
        index << unique_pages.size - 1
      end
    end
    raise "more than 256 unique pages; widen WIDTH_INDEX to UInt16" if unique_pages.size > 256

    write(out_path, version, ranges(zero), ranges(wide), ranges(vs16), index, unique_pages)
  end

  def load_sources(version : String, dir : String?) : {String, String, String}
    if d = dir
      STDERR << "reading UCD files from " << d << '\n'
      {File.read(File.join(d, "EastAsianWidth.txt")),
       File.read(File.join(d, "DerivedGeneralCategory.txt")),
       File.read(File.join(d, "emoji-data.txt"))}
    else
      base = "https://www.unicode.org/Public/#{version}/"
      {fetch(base + "ucd/EastAsianWidth.txt"),
       fetch(base + "ucd/extracted/DerivedGeneralCategory.txt"),
       fetch(base + "ucd/emoji/emoji-data.txt")}
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

  def parse_ranges(text : String, & : UInt32, UInt32, String ->) : Nil
    text.each_line do |line|
      body = line.split('#', 2)[0]
      next if body.strip.empty?
      fields = body.split(';')
      next if fields.size < 2
      prop  = fields[1].strip
      range = fields[0].strip
      if range.includes?("..")
        lo, hi = range.split("..", 2)
        yield lo.strip.to_u32(16), hi.strip.to_u32(16), prop
      else
        cp = range.to_u32(16)
        yield cp, cp, prop
      end
    end
  end

  def fill(bits : BitArray, first : UInt32, last : UInt32) : Nil
    cp   = first.to_i
    stop = last.to_i
    while cp <= stop
      bits[cp] = true
      cp += 1
    end
  end

  def ranges(bits : BitArray) : Array({UInt32, UInt32})
    result = [] of {UInt32, UInt32}
    cp     = 0
    max    = bits.size
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

  def write(path : String, version : String, zero, wide, vs16, index : Array(Int32), pages : Array(Bytes)) : Nil
    File.open(path, "w") do |io|
      io << "# GENERATED FILE — do not edit by hand.\n"
      io << "# Unicode " << version << ". Regenerate with:\n"
      io << "#   crystal run tools/gen_tables.cr -- --version " << version << '\n'
      io << "# Sources: EastAsianWidth.txt, DerivedGeneralCategory.txt, emoji-data.txt\n\n"
      io << "module SpanWidth\n"
      io << "  # Two-level per-scalar width table (0, 1 or 2 cells):\n"
      io << "  #   WIDTH_PAGES[WIDTH_INDEX[cp >> 8] * 256 + (cp & 0xFF)]\n"
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
      io << "\n  # Narrow emoji bases: rendered 2 cells wide when followed by U+FE0F.\n"
      emit_ranges io, "VS16_WIDE", vs16
      io << "end\n"
    end
    STDERR.puts "wrote #{path}: " \
                "ZERO=#{zero.size} ranges, WIDE=#{wide.size} ranges, VS16_WIDE=#{vs16.size} ranges, " \
                "#{pages.size} unique width pages"
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
