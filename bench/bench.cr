# bench/bench.cr
require "../src/span-width"
require "benchmark"

# Throughput benchmark. Run with:
#   crystal run --release bench/bench.cr

CORPORA = {
  "ascii"  => "The quick brown fox jumps over the lazy dog. " * 64,
  "latin1" => "L'élève française: déjà vu — naïve café, œuvre d'art. " * 48,
  "cjk"    => "こんにちは世界、これはレンダリングのテストです。" * 64,
  "hangul" => "한국어 텍스트 렌더링 성능 측정입니다. " * 48,
  "emoji"  => "👨‍👩‍👧‍👦 family 👍🏽 yes ❤️ love 🇺🇸 flag ✈️ go " * 32,
  "mixed"  => "ERROR 世界: ユーザー 'alice' が 42 件の 💥 を検出 (100%) " * 32,
}

puts "span-width #{SpanWidth::VERSION} — throughput (higher is better)"
puts

CORPORA.each do |name, text|
  10.times { SpanWidth.measure(text) } # warmup
  bytes = 0_i64
  start = Time.instant
  loop do
    SpanWidth.measure(text)
    bytes += text.bytesize
    break if Time.instant - start >= 1.second
  end
  secs = (Time.instant - start).total_seconds
  printf "%-8s %8.0f MiB/s  (%5d B span -> %4d cells)\n",
    name, bytes / secs / 1_048_576.0, text.bytesize, SpanWidth.measure(text)
end

puts
puts "per-span overhead (renderer reality: many small spans)"
puts

Benchmark.ips do |x|
  x.report("short ascii span (11 B)") { SpanWidth.measure("hello world") }
  x.report("short cjk span (9 B)") { SpanWidth.measure("こんにち") }
  x.report("short emoji span (25 B)") { SpanWidth.measure("👨‍👩‍👧‍👦") }
end
