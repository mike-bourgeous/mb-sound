# mb-term's Ruby layers (RubyVT, Cells) against its C ones (NativeVT,
# NativeCells), offline (CPU time on one thread, no terminal): VT feed
# throughput, VT#draw into each grid, and changed-cell frame encoding at
# three screen sizes, for three stacks: all Ruby, the Ruby VT with the C
# grid (mb-term before term-2's C VT), and all C.  The stacks alternate
# within every round (the order rotates each round) and the tables show
# medians, so load from other processes hits them alike.
#
#     ruby bench/term_bench.rb [ROUNDS]          # plain Ruby
#     ruby --yjit bench/term_bench.rb [ROUNDS]   # with YJIT (mb-sound's bin/ scripts use it)
#
# Inputs: bench/fixtures/pry_session.bin (a real Pry session's output,
# recorded by bench/capture_pry.rb: Reline's per-key redraws, colored
# results), an `ls -la --color` style burst, and full-screen redraws (a
# cursor move per row, truecolor runs: a TUI repainting).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mb/term'

abort 'fast_term is not compiled (rake compile)' unless defined?(MB::Term::NativeCells) && defined?(MB::Term::NativeVT)

ROUNDS = Integer(ARGV[0] || 7)
CLOCK = Process::CLOCK_THREAD_CPUTIME_ID

def cpu
  Process.clock_gettime(CLOCK)
end

def median(a)
  s = a.sort
  s.length.odd? ? s[s.length / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2.0
end

# Runs +block+ +n+ times; CPU seconds per run.
def per_run(n)
  GC.start
  t = cpu
  n.times { yield }
  (cpu - t) / n
end

rng = Random.new(1)
names = %w[lib bin spec ext gems design README.md Gemfile Rakefile .rspec sound.rb fast_ui.c vt.rb notes]
colors = ["\e[01;34m", "\e[01;32m", "\e[0m", "\e[01;36m", "\e[00m"]
LS = Array.new(20_000) { |i|
  c = colors[rng.rand(colors.length)]
  format("%s %2d mike staff %8d Oct %2d %02d:%02d %s%s\e[0m\r\n", %w[drwxr-xr-x -rw-r--r-- -rwxr-xr-x][rng.rand(3)], rng.rand(1..9), rng.rand(100_000_000), rng.rand(1..31), rng.rand(24), rng.rand(60), c, "#{names[rng.rand(names.length)]}_#{i}")
}.join.b.freeze
PRY = (File.binread(File.join(__dir__, 'fixtures', 'pry_session.bin')) * 50).freeze

# Full-screen repaints of a 80x236 screen, 20 frames
REDRAW = Array.new(20) { |f|
  out = +"\e[?2026h"
  80.times do |row|
    out << "\e[#{row + 1};1H"
    col = 0
    while col < 236
      n = [rng.rand(4..30), 236 - col].min
      out << "\e[38;2;#{rng.rand(256)};#{rng.rand(256)};#{rng.rand(256)}m" << ('▁▂▃▄▅▆▇█ab'[rng.rand(10)] * n)
      col += n
    end
  end
  out << "\e[0m\e[?2026l"
}.join.b.freeze

SIZES = [[80, 24], [120, 40], [236, 80]].freeze
# [grid class, VT class] per stack
IMPLS = {
  ruby: [MB::Term::Cells, MB::Term::RubyVT],
  mixed: [MB::Term::NativeCells, MB::Term::RubyVT],
  c: [MB::Term::NativeCells, MB::Term::NativeVT],
}.freeze
VTS = { ruby: MB::Term::RubyVT, c: MB::Term::NativeVT }.freeze

def rotated(h, round)
  a = h.to_a
  a.rotate(round % a.length)
end

results = Hash.new { |h, k| h[k] = [] }

# VT feed, Ruby and C, in 4 KB pieces like ReplHost's reader
feeds = { 'Pry transcript' => PRY, 'ls -la burst' => LS, 'full-screen redraws 236x80' => REDRAW }
feeds.each do |name, bytes|
  ROUNDS.times do |round|
    rotated(VTS, round).each do |impl, vtk|
      rows, cols = name.include?('236x80') ? [80, 236] : [40, 120]
      vt = vtk.new(rows, cols)
      GC.start
      t = cpu
      i = 0
      while i < bytes.bytesize
        vt.feed(bytes.byteslice(i, 4096))
        i += 4096
      end
      results[[:feed, name, impl]] << (cpu - t)
    end
  end
end

# Screens to encode: a VT holding the end of the ls burst (colored names)
# drawn into a grid, the same after one more line scrolled in, and after a
# few typed characters.
def screens(klass, vtk, w, h)
  vt = vtk.new(h, w)
  vt.feed(LS.byteslice(0, 400_000))
  vt.feed("\e[1;32m[1] pry(main)>\e[0m ")
  a = klass.new(w, h)
  vt.draw(a, 0, 0, w, h)
  typed = klass.new(w, h)
  typed.copy_from(a)
  vt.feed('abc')
  vt.draw(typed, 0, 0, w, h)
  scrolled = klass.new(w, h)
  scrolled.copy_from(typed)
  vt.feed("\r\n=> \e[1;34m3\e[0m\r\n")
  vt.draw(scrolled, 0, 0, w, h)
  [vt, a, typed, scrolled]
end

ROUNDS.times do |round|
  SIZES.each do |w, h|
    rotated(IMPLS, round).each do |impl, (klass, vtk)|
      vt, a, typed, scrolled = screens(klass, vtk, w, h)
      n = w * h > 10_000 ? 20 : 60
      results[[:frame_full, w, h, impl]] << per_run(n) { a.frame(nil, :truecolor) }
      results[[:frame_typed, w, h, impl]] << per_run(n * 10) { typed.frame(a, :truecolor) }
      results[[:frame_scroll, w, h, impl]] << per_run(n) { scrolled.frame(typed, :truecolor) }
      results[[:lines, w, h, impl]] << per_run(n) { a.lines(:truecolor) }
      g = klass.new(w, h)
      results[[:draw, w, h, impl]] << per_run(n) { vt.invalidate; vt.draw(g, 0, 0, w, h) }
      # One REPL refresh: a line arrives, the VT draws the changed rows, the
      # frame is encoded, the grid becomes the previous frame
      prev = klass.new(w, h)
      cur = klass.new(w, h)
      vt.draw(cur, 0, 0, w, h)
      prev.copy_from(cur)
      k = 0
      results[[:refresh, w, h, impl]] << per_run(n) {
        vt.feed("line #{k += 1} \e[32mok\e[0m\r\n")
        vt.draw(cur, 0, 0, w, h)
        cur.frame(prev, :truecolor)
        prev.copy_from(cur)
      }
      results[[:bytes_full, w, h]] = [a.frame(nil, :truecolor).bytesize]
      results[[:bytes_typed, w, h]] = [typed.frame(a, :truecolor).bytesize]
      results[[:bytes_scroll, w, h]] = [scrolled.frame(typed, :truecolor).bytesize]
    end
  end
end

yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts "mb-term bench: Ruby #{RUBY_VERSION}#{yjit ? ' +YJIT' : ''}, #{ROUNDS} rounds (medians), CPU time"
puts
puts '| VT feed | bytes | Ruby ms | Ruby MB/s | C ms | C MB/s | Ruby / C |'
puts '|---|---|---|---|---|---|---|'
feeds.each do |name, bytes|
  r = median(results[[:feed, name, :ruby]])
  c = median(results[[:feed, name, :c]])
  puts format('| %s | %d | %.1f | %.1f | %.2f | %.1f | %.0fx |', name, bytes.bytesize, r * 1000, bytes.bytesize / r / 1e6, c * 1000, bytes.bytesize / c / 1e6, r / c)
end
puts
puts '| per call, µs | size | Ruby | Ruby VT, C grid | C | Ruby / C | Ruby VT, C grid / C | bytes |'
puts '|---|---|---|---|---|---|---|---|'
labels = {
  frame_full: 'frame, every cell', frame_typed: 'frame, 3 cells typed', frame_scroll: 'frame, one line scrolled in',
  lines: 'lines (truecolor)', draw: 'VT#draw, every row', refresh: 'REPL refresh (feed + draw + frame + copy)',
}
labels.each do |key, label|
  SIZES.each do |w, h|
    r = median(results[[key, w, h, :ruby]]) * 1e6
    m = median(results[[key, w, h, :mixed]]) * 1e6
    c = median(results[[key, w, h, :c]]) * 1e6
    bytes = results[[{ frame_full: :bytes_full, frame_typed: :bytes_typed, frame_scroll: :bytes_scroll }[key], w, h]]&.first
    puts format('| %s | %dx%d | %.1f | %.1f | %.1f | %.1fx | %.1fx | %s |', label, w, h, r, m, c, r / c, m / c, bytes || '')
  end
end
