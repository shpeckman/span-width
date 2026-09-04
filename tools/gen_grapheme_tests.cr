# tools/gen_grapheme_tests.cr
require "http/client"
require "option_parser"

# Fetches the official UCD GraphemeBreakTest.txt and writes the subset of
# tests that are valid under the span-width input contract (no C0/C1/DEL
# control bytes) to spec/fixtures/GraphemeBreakTest.txt, keeping the
# original line format (÷ = break, × = no break, hex codepoints).
#
#   crystal run tools/gen_grapheme_tests.cr -- [--version 17.0.0] [--out PATH]

version  = "17.0.0"
out_path = "spec/fixtures/GraphemeBreakTest.txt"

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run tools/gen_grapheme_tests.cr -- [options]"
  parser.on("--version VERSION", "UCD version (default: #{version})") { |v| version = v }
  parser.on("--out PATH", "output file (default: #{out_path})") { |v| out_path = v }
  parser.on("-h", "--help", "show this help") { puts parser; exit }
end

url = "https://www.unicode.org/Public/#{version}/ucd/auxiliary/GraphemeBreakTest.txt"
STDERR << "  GET " << url << '\n'
body = HTTP::Client.get(url) do |response|
  unless response.success?
    raise "GET #{url} failed: HTTP #{response.status_code}"
  end
  response.body_io.gets_to_end
end

kept    = 0
skipped = 0
Dir.mkdir_p(File.dirname(out_path))
File.open(out_path, "w") do |file|
  file << "# GraphemeBreakTest.txt subset — Unicode " << version << "\n"
  file << "# Only tests valid under the span-width input contract (no C0/C1/DEL\n"
  file << "# control bytes) are kept. Regenerate: crystal run tools/gen_grapheme_tests.cr\n"
  body.each_line do |line|
    next unless line.starts_with?('÷')
    tokens = line.split('#', 2)[0].split
    cps    = tokens.select { |t| t.matches?(/\A[0-9A-Fa-f]+\z/) }.map(&.to_u32(16))
    if cps.any? { |cp| cp < 0x20_u32 || (0x7F_u32..0x9F_u32).covers?(cp) }
      skipped += 1
    else
      file << line << '\n'
      kept += 1
    end
  end
end

STDERR.puts "wrote #{out_path}: kept #{kept} tests, skipped #{skipped} (control bytes)"
