require 'base64'
T = File.expand_path('..', __dir__)
D = ENV['RUNS'] || File.join(T, 'runs')
truth = File.read("#{T}/truth/answers.txt")
bass = truth.lines[1, 12].map { |l| l.split.map(&:to_i) }
sax = truth[/sax notes: (\d+)  lowest (\d+)  highest (\d+)/] && [$1, $2, $3].map(&:to_i)
orig = File.binread("#{T}/truth/demo.mid").bytes
exp = File.binread("#{T}/truth/expected_bass_up2.mid").bytes

decode = {
  'hex' => ->(s) { s.lines.flat_map { |l| l.split[1..] || [] }.map { |x| x.to_i(16) } },
  'braille' => ->(s) { s.delete("\n\r").each_char.map { |c| c.ord - 0x2800 } },
  'emoji' => ->(s) { s.delete("\n\r").each_char.map { |c| c.ord - 0x1F300 } },
  'base64' => ->(s) { Base64.decode64(s).bytes },
}
outs = { 'hex' => 'output.hex.txt', 'braille' => 'output.braille.txt', 'emoji' => 'output.emoji.txt',
         'base64' => 'output.b64.txt', 'events' => 'output.csv', 'notes' => 'output.notes.txt' }
texp = { 'events' => 'events/demo.csv', 'notes' => 'notes/demo.notes.txt' }

outs.each do |enc, of|
  puts "== #{enc}"
  a = "#{D}/#{enc}/answers.txt"
  if File.exist?(a)
    s = File.read(a)
    t1 = (s[/TASK1\n(.*?)TASK2/m, 1] || '').lines.map { |l| l.scan(/-?\d+/).map(&:to_i) }.reject(&:empty?)
    fields = 0; full = 0
    bass.each_with_index { |g, i| r = t1[i] || []; m = g.zip(r).count { |x, y| x == y }; fields += m; full += 1 if m == 4 }
    t2 = s[/notes=(\d+)\s+lowest=(\d+)\s+highest=(\d+)/] ? [$1, $2, $3].map(&:to_i) : []
    puts "  task1: #{full}/12 notes fully right, #{fields}/48 fields"
    puts "  task2: #{sax.zip(t2).count { |x, y| x == y }}/3 (got #{t2.inspect}, want #{sax.inspect})"
  else
    puts '  no answers file'
  end
  o = "#{D}/#{enc}/#{of}"
  unless File.exist?(o) then puts '  task3: no output'; next end
  if decode[enc]
    got = decode[enc].(File.read(o)) rescue (puts "  task3: decode error #{$!}"; next)
    n = [got.size, exp.size].min
    need = (0...exp.size).select { |i| exp[i] != orig[i] }
    right = need.count { |i| got[i] == exp[i] }
    collateral = (0...n).count { |i| exp[i] == orig[i] && got[i] != orig[i] }
    puts "  task3: len #{got.size} (want #{exp.size}), exact=#{got == exp}, needed changes made #{right}/#{need.size}, collateral byte changes #{collateral}, first mismatch @#{(0...n).find { |i| got[i] != exp[i] }.inspect}"
  else
    e = File.read("#{T}/truth/expected/#{texp[enc]}").lines.map(&:strip)
    g = File.read(o).lines.map(&:strip).reject(&:empty?)
    ol = File.read("#{D}/#{texp[enc]}").lines.map(&:strip)
    need = (0...e.size).select { |i| e[i] != ol[i] }
    right = need.count { |i| g[i] == e[i] }
    bad = (0...[e.size, g.size].min).count { |i| e[i] == ol[i] && g[i] != e[i] }
    puts "  task3: lines #{g.size} (want #{e.size}), exact=#{g == e}, needed changes #{right}/#{need.size}, collateral line diffs #{bad}"
  end
end
