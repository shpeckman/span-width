# tools/dump_widths.cr
require "../src/span-width"

# Dumps per-scalar widths for the entire Unicode range as TSV:
#   crystal run tools/dump_widths.cr -- [out.tsv]
# Used by tools/verify.py to cross-check against Python's unicodedata.

out_path = ARGV[0]? || "widths.tsv"

File.open(out_path, "w") do |file|
  cp = 0x20
  while cp <= 0x10FFFF
    unless 0xD800 <= cp <= 0xDFFF # surrogates are not scalar values
      file << cp << '\t' << SpanWidth.width(cp.chr) << '\n'
    end
    cp += 1
  end
end

puts "wrote #{out_path}"
