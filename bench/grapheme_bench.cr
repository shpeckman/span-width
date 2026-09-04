# bench/grapheme_bench.cr
require "../src/span-width/grapheme"

# Grapheme segmentation + cluster-width benchmark. Run with:
#   crystal run --release bench/grapheme_bench.cr

alias Grapheme = SpanWidth::Grapheme

CORPORA = {
  "ascii"  => "The quick brown fox jumps over the lazy dog. " * 64,
  "latin1" => "L'élève française: déjà vu — naïve café, œuvre d'art. " * 48,
  "cjk"    => "こんにちは世界、これはレンダリングのテストです。" * 64,
  "hangul" => "한국어 텍스트 렌더링 성능 측정입니다. " * 48,
  "emoji"  => "👨‍👩‍👧‍👦 family 👍🏽 yes ❤️ love 🇺🇸 flag ✈️ go " * 32,
  "mixed"  => "ERROR 世界: ユーザー 'alice' が 42 件の 💥 を検出 (100%) " * 32,
}

puts "span-width #{SpanWidth::VERSION} grapheme mode — segment + measure (higher is better)"
puts

CORPORA.each do |name, text|
  sink = 0
  10.times { Grapheme.measure_each(text) { |_, w| sink &+= w } } # warmup
  bytes = 0_i64
  start = Time.instant
  loop do
    Grapheme.measure_each(text) { |_, w| sink &+= w }
    bytes += text.bytesize
    break if Time.instant - start >= 1.second
  end
  secs     = (Time.instant - start).total_seconds
  clusters = 0
  Grapheme.each(text) { |_| clusters += 1 }
  printf "%-8s %8.0f MiB/s  (%5d B span -> %4d clusters)\n",
    name, bytes / secs / 1_048_576.0, text.bytesize, clusters
end
