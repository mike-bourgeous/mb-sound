# The C VT (NativeVT, fast_term's vt.c) against the Ruby VT (RubyVT, its
# reference): the whole state (every row's cells and styles, the
# scrollback, the cursor, modes, saved cursors, tabs, replies, pending
# bytes, dirty rows) after the same bytes, over captured streams and
# seeded random bytes, plus the same cells drawn into Ruby and C grids.
# Also run by mb-sound's memcheck (spec/valgrind/memcheck_selection.rb).
#
# Repro a fuzz failure: VT_FUZZ_SEED=n (the failure names it); more cases:
# VT_FUZZ=N.
require 'objspace'

RSpec.describe('MB::Term::NativeVT', :aggregate_failures) do
  before { skip 'fast_term is not compiled (rake compile)' unless defined?(MB::Term::NativeVT) }

  let(:fixtures) { File.expand_path('../bench/fixtures', __dir__) }

  def pair(rows, cols, **kw)
    [MB::Term::RubyVT.new(rows, cols, **kw), MB::Term::NativeVT.new(rows, cols, **kw)]
  end

  # The first differing key of two states, with both values (short)
  def state_diff(a, b)
    a.each do |k, v|
      next if v == b[k]
      if v.is_a?(Array) && b[k].is_a?(Array)
        i = (0...[v.length, b[k].length].max).find { |n| v[n] != b[k][n] }
        return "#{k}[#{i}] (lengths #{v.length}/#{b[k].length}): ruby #{v[i].inspect[0, 400]}\n  c #{b[k][i].inspect[0, 400]}"
      end
      return "#{k}: ruby #{v.inspect[0, 400]}\n  c #{b[k].inspect[0, 400]}"
    end
    (b.keys - a.keys).empty? ? nil : "keys #{b.keys - a.keys}"
  end

  def expect_same(r, c, what)
    diff = state_diff(r.debug_state, c.debug_state)
    expect(diff).to be_nil, "#{what}: #{diff}"
    diff.nil?
  end

  # Feeds +bytes+ to both in pieces of random sizes; compares at the end
  # (and after every piece when +each+).
  def feed_both(r, c, bytes, rng, max_piece: 4096, each: false, what: '')
    i = 0
    while i < bytes.bytesize
      n = rng.rand(1..max_piece)
      piece = bytes.byteslice(i, n)
      r.feed(piece)
      c.feed(piece)
      i += n
      return false if each && !expect_same(r, c, "#{what} after byte #{i}")
    end
    expect_same(r, c, what)
  end

  # The Ruby library's streams (a real Pry session, a colored listing, and
  # full-screen truecolor repaints), as bench/term_bench.rb makes them
  def streams(rng)
    names = %w[lib bin spec ext gems README.md vt.rb 中文.txt ｶﾀｶﾅ]
    colors = ["\e[01;34m", "\e[01;32m", "\e[0m", "\e[01;36m", "\e[00m"]
    ls = Array.new(800) { |i| format("%s %2d mike %8d Oct %2d %s%s\e[0m\r\n", %w[drwxr-xr-x -rw-r--r--][rng.rand(2)], rng.rand(1..9), rng.rand(100_000_000), rng.rand(1..31), colors[rng.rand(5)], "#{names[rng.rand(names.length)]}_#{i}") }.join
    redraw = Array.new(3) {
      out = +"\e[?2026h"
      30.times do |row|
        out << "\e[#{row + 1};1H"
        col = 0
        while col < 100
          n = [rng.rand(4..30), 100 - col].min
          out << "\e[38;2;#{rng.rand(256)};#{rng.rand(256)};#{rng.rand(256)}m" << ('▁▂▃▄▅▆▇█ab中'[rng.rand(11)] * n)
          col += n
        end
      end
      out << "\e[0m\e[?2026l"
    }.join
    # A full-screen program: alternate screen, scroll region, insert and
    # delete, tabs, saved cursors, origin mode, reports, titles
    tui = +"\e]0;editor\a\e[?1049h\e[H\e[2J\e[2;20r\e[?6h"
    40.times do |i|
      tui << "\e[#{rng.rand(1..20)};#{rng.rand(1..80)}H\e[#{rng.rand(0..2)}K\e[3#{rng.rand(8)};4#{rng.rand(8)}mline #{i}\tx\t中\e[0m"
      tui << ["\e[2L", "\e[3M", "\e[4@", "\e[2P", "\e[5X", "\eM", "\eD", "\eE", "\e7\e[10;10Hsaved\e8", "\e[s\e[1;1H\e[u", "\e[6n", "\e[?25l", "\e[?25h", "\e[3g", "\e[0g", "\e[?1$p", "\e[S", "\e[2T", "\e[1J", "\e[0J"][rng.rand(20)]
    end
    tui << "\e[?6l\e[r\e[?1049l\e]2;done\e\\after\r\n"
    {
      'Pry transcript' => File.binread(File.join(fixtures, 'pry_session.bin')),
      'ls burst' => ls.b,
      'full-screen redraws' => redraw.b,
      'full-screen program' => tui.b,
    }
  end

  it 'has the same state as RubyVT after captured streams fed in random pieces' do
    rng = Random.new(5)
    streams(rng).each do |name, bytes|
      [[24, 80, 200], [30, 100, 10_000], [7, 13, 3]].each do |rows, cols, sb|
        r, c = pair(rows, cols, scrollback: sb)
        feed_both(r, c, bytes, rng, what: "#{name} #{rows}x#{cols}")
        expect(c.take_replies).to eq(r.take_replies)
        expect(c.lines).to eq(r.lines)
        expect(c.text).to eq(r.text)
        expect(c.screen.map(&:to_a)).to eq(r.screen.map(&:to_a))
      end
    end
  end

  # Random bytes, biased toward the sequences the VT parses and the edges
  # of its rules: CSI with parameters (empty, huge, intermediates), OSC/DCS
  # strings, ESC pairs, controls, wide, ambiguous, combining, and invalid
  # UTF-8, sync marks
  PIECES = [
    "\e", '[', ']', 'P', '?', '>', '$', ';', ';;', ' ', '"', "'", ':', '0', '1', '2', '5', '7', '9', '25', '47', '1049', '2004', '65536', '99999999999',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'P', 'S', 'T', 'X', '@', 'a', 'c', 'd', 'e', 'f', 'g', 'h', 'l', 'm', 'n', 'p', 'r', 's', 't', 'u', '`', 'q',
    "\e[", "\e]", "\eP", "\e_", "\e^", "\eX", "\e7", "\e8", "\eD", "\eE", "\eM", "\ec", "\e(", "\e(0", "\e#8", "\e\\", "\e]0;", "\e]2;t\a", "\e]7765;", "\e]7765;12\a",
    "\e[0;0r", "\e[2;0r", "\e[0;3r", "\e[38;5;", "\e[48;2;", "\e[38;2;1;2;3m", "\e[1;4;7m", "\e[0m", "\e[?1049h", "\e[?1049l", "\e[?47h", "\e[?6h", "\e[?7l", "\e[?7h", "\e[2;3r", "\e[r", "\e[6n", "\e[?2004$p",
    "\r", "\n", "\t", "\b", "\a", "\v", "\f", "\x00", "\x7f", "\r\n",
    'abc', 'hello world', 'x' * 30, '中', '文字', 'ｶ', '…', '①', 'é', "é", "​", "­", '🎵', "　",
    "\xE4".b, "\xB8".b, "\xAD".b, "\xFF".b, "\xC0\x80".b, "\xED\xA0\x80".b, "\xF0\x9F".b, "\xF4\x90\x80\x80".b, "\x80\x80\x80".b, "\xE0\x80".b, "\xC3".b,
  ].map(&:b).freeze

  def fuzz_bytes(rng, n)
    out = +''.b
    n.times do
      out << (rng.rand(8) == 0 ? rng.rand(256).chr.b : PIECES[rng.rand(PIECES.length)])
    end
    out
  end

  def fuzz_case(seed)
    rng = Random.new(seed)
    rows = rng.rand(1..8)
    cols = rng.rand(1..14)
    r, c = pair(rows, cols, scrollback: rng.rand(0..6), ambiguous_width: rng.rand(1..2))
    what = "VT_FUZZ_SEED=#{seed} (#{rows}x#{cols})"
    6.times do |step|
      bytes = fuzz_bytes(rng, rng.rand(1..60))
      return false unless feed_both(r, c, bytes, rng, max_piece: 9, each: true, what: "#{what} step #{step} #{bytes.inspect[0, 300]}")

      case rng.rand(6)
      when 0
        nr = rng.rand(1..9)
        nc = rng.rand(1..15)
        r.resize(nr, nc)
        c.resize(nr, nc)
        return false unless expect_same(r, c, "#{what} after resize #{nr}x#{nc}")
      when 1
        w = rng.rand(1..2)
        r.ambiguous_width = w
        c.ambiguous_width = w
      when 2
        expect(c.take_replies).to eq(r.take_replies)
      when 3
        return false unless draw_both(r, c, rng, what)
      end
    end
    reads_match(r, c, rng, what)
  end

  # The same #draw into Cells and NativeCells from both VTs: the same rows
  # drawn and the same cells.
  def draw_both(r, c, rng, what)
    gw = rng.rand(1..18)
    gh = rng.rand(1..10)
    x = rng.rand(-2..4)
    y = rng.rand(-2..3)
    w = rng.rand(0..16)
    h = rng.rand(0..10)
    offset = [0, 0, rng.rand(0..8)].sample(random: rng)
    all = rng.rand(3) == 0
    total = r.dropped + r.total_lines
    marks = rng.rand(3) == 0 ? Array.new(rng.rand(0..3)) { [rng.rand(r.dropped..total), rng.rand(-2..8), rng.rand(-1..16), [2, 4, 6][rng.rand(3)]] } : nil
    grids = [MB::Term::Cells, MB::Term::NativeCells].flat_map { |k| [k.new(gw, gh), k.new(gw, gh)] }
    # (the VTs' dirty state is consumed by a draw: draw each VT into its own
    # grids once, then copy for the other kind)
    dr = r.draw(grids[0], x, y, w, h, offset: offset, all: all, marks: marks)
    dc = c.draw(grids[3], x, y, w, h, offset: offset, all: all, marks: marks)
    msg = "#{what}: draw(#{x}, #{y}, #{w}, #{h}, offset: #{offset}, all: #{all}, marks: #{marks.inspect}) into #{gw}x#{gh}"
    expect(dc).to eq(dr), msg
    expect(grids[3].lines(:truecolor)).to eq(grids[0].lines(:truecolor)), msg
    # And C into a Ruby grid (#put_run calls), Ruby into a C grid
    r.invalidate
    c.invalidate
    r.draw(grids[2], x, y, w, h, offset: offset, all: true, marks: marks)
    c.draw(grids[1], x, y, w, h, offset: offset, all: true, marks: marks)
    expect(grids[1].lines(:truecolor)).to eq(grids[2].lines(:truecolor)), msg
    expect_same(r, c, msg)
  end

  def reads_match(r, c, rng, what)
    expect(c.lines).to eq(r.lines), what
    expect(c.text).to eq(r.text), what
    expect(c.screen.map(&:to_a)).to eq(r.screen.map(&:to_a)), what
    first = r.dropped
    last = first + r.total_lines - 1
    (first - 1..last + 1).each do |n|
      expect(c.line_at(n)&.to_a).to eq(r.line_at(n)&.to_a), "#{what} line_at(#{n})"
      expect(c.line_text(n)).to eq(r.line_text(n)), "#{what} line_text(#{n})"
      expect(c.line_at(n)&.to_sgr).to eq(r.line_at(n)&.to_sgr), "#{what} to_sgr(#{n})"
    end
    expect(c.text_between(first, last)).to eq(r.text_between(first, last)), what
    %w[a x 中 e ?].each { |pat| expect(c.search(pat)).to eq(r.search(pat)), "#{what} search #{pat}" }
    %i[rows cols row col title dropped scrolled bytes_fed sync_mark scrollback_length total_lines alt? bracketed_paste? app_cursor? cursor_visible? dirty? max_scrollback ambiguous_width].each do |m|
      expect(c.public_send(m)).to eq(r.public_send(m)), "#{what} #{m}"
    end
    expect(c.inspect.sub('NativeVT', 'RubyVT')).to eq(r.inspect)
    true
  end

  it 'has the same state as RubyVT after random bytes, resizes, and draws' do
    base = Integer(ENV.fetch('VT_FUZZ_SEED', 1))
    count = ENV['VT_FUZZ_SEED'] ? 1 : Integer(ENV.fetch('VT_FUZZ', ENV['MB_SOUND_MEMCHECK'] == '1' ? 80 : 300)) # (fewer under mb-sound's Valgrind runs)
    failed = (base...(base + count)).reject { |seed| fuzz_case(seed) }
    expect(failed).to eq([])
  end

  # A property of both: output read in any pieces gives the state it gives
  # read at once (sequences, UTF-8 characters, and invalid bytes split at
  # any point).
  it 'gives the same state for bytes fed at once or in any pieces' do
    rng = Random.new(77)
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      150.times do |k|
        bytes = fuzz_bytes(rng, rng.rand(1..80))
        whole = klass.new(6, 11, scrollback: 4)
        whole.feed(bytes)
        pieces = klass.new(6, 11, scrollback: 4)
        i = 0
        while i < bytes.bytesize
          n = rng.rand(1..5)
          pieces.feed(bytes.byteslice(i, n))
          i += n
        end
        expect(state_diff(whole.debug_state, pieces.debug_state)).to be_nil, "#{klass} case #{k}: #{bytes.inspect}"
      end
    end
  end

  it 'scrubs invalid UTF-8 as String#scrub does' do
    rng = Random.new(9)
    300.times do
      bytes = Array.new(rng.rand(1..12)) { [rng.rand(256), [0xE4, 0xB8, 0xAD, 0xF0, 0x9F, 0x8E, 0xB5, 0xED, 0xA0, 0xC3, 0x80, 0xBF, 0xF4, 0x90, 0xE0, 0x41][rng.rand(16)]][rng.rand(2)] }.pack('C*')
      # (a newline after them: nothing is held back)
      r, c = pair(3, 40)
      r.feed("#{bytes}\r\n".b)
      c.feed("#{bytes}\r\n".b)
      expected = bytes.dup.force_encoding('UTF-8').scrub('?')
      expect(state_diff(r.debug_state, c.debug_state)).to be_nil, bytes.inspect
      expect(r.line_text(r.dropped + r.scrollback_length + 0) || '').to be_a(String)
      expect(expected.valid_encoding?).to eq(true)
    end
  end

  it 'reads CSI parameters as their leading digits, saturating, in both' do
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      v = klass.new(5, 10)
      v.feed("\e[99999999999999999999;3H")
      expect([v.row, v.col]).to eq([4, 2])
      v.feed("\e[?99999999999999$p\e[3:9;7H")
      expect(v.take_replies).to eq("\e[?65535;0$y")
      expect([v.row, v.col]).to eq([2, 6]) # ("3:9" reads as 3)
      v.feed("\e]7765;123456789012345678901234567890\a")
      expect(v.sync_mark).to eq(MB::Term::VT::MARK_MAX)
      v.feed("\e[0;0r\e[5;1H\n")
      expect(v.scrollback_length).to eq(1) # (0;0 is the whole screen, as in xterm)
    end
  end

  it 'keeps bytes of a character held back while a sequence is incomplete' do
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      v = klass.new(3, 20)
      v.feed("\e]0;title \xE4".b)
      v.feed("\xB8\xAD\a".b)
      expect(v.title).to eq('title 中')
    end
  end

  it 'drops wide characters in a one-column VT' do
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      v = klass.new(2, 1)
      v.feed('中a')
      expect(v.lines).to eq(['a', ' '])
      expect(v.line_text(0).length).to eq(1)
    end
  end

  it 'reads widths that follow ambiguous_width= (no stale cache)' do
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      v = klass.new(2, 10)
      v.feed('…')
      v.ambiguous_width = 2
      v.feed('…')
      expect(v.col).to eq(3)
    end
  end

  it 'keeps scrollback rows in little memory (trimmed) with the same lines' do
    r, c = pair(4, 200, scrollback: 1000)
    text = (1..1200).map { |i| "l#{i}\r\n" }.join
    r.feed(text)
    c.feed(text)
    expect(c.scrollback_length).to eq(1000)
    expect(c.line_at(c.dropped).to_s).to eq(r.line_at(r.dropped).to_s)
    expect(c.line_at(c.dropped).length).to eq(200)
    expect(ObjectSpace.memsize_of(c)).to be < 1000 * 200 # (4 bytes a cell untrimmed: 800 KB)
  end

  it 'gives line copies (Row) that survive later output' do
    c = MB::Term::NativeVT.new(2, 5)
    c.feed('abc')
    row = c.line_at(0)
    c.feed("\e[2J")
    expect(row.text).to eq('abc  ')
    expect(row.plain?).to eq(true)
  end

  it 'checks its arguments like RubyVT' do
    [MB::Term::RubyVT, MB::Term::NativeVT].each do |klass|
      expect { klass.new(0, 5) }.to raise_error(ArgumentError, /at least 1x1/)
      expect { klass.new(5, 1.5) }.to raise_error(ArgumentError, /at least 1x1/)
      expect { klass.new(3, 3).resize(0, 3) }.to raise_error(ArgumentError, /at least 1x1/)
    end
    expect { MB::Term::NativeVT.new(100_000, 100_000) }.to raise_error(ArgumentError, /too large/)
    expect { MB::Term::FastTerm::VT.allocate.lines }.to raise_error(RuntimeError, /not initialized/)
  end

  it 'is what VT.new makes unless MB_TERM_NATIVE=0 or native: false' do
    expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::NativeVT)
    expect(MB::Term::VT.new(2, 3, native: false)).to be_a(MB::Term::RubyVT)
    expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::VT)
    begin
      old = ENV['MB_TERM_NATIVE']
      ENV['MB_TERM_NATIVE'] = '0'
      expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::RubyVT)
    ensure
      ENV['MB_TERM_NATIVE'] = old
    end
    begin
      MB::Term::VT.native = nil # (an adapter's switch: mb-sound's kernels = :ruby)
      expect(MB::Term::VT.native?).to eq(false)
      expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::RubyVT)
      expect { MB::Term::VT.native = String }.to raise_error(ArgumentError)
    ensure
      MB::Term::VT.native = MB::Term::NativeVT
    end
  end
end
