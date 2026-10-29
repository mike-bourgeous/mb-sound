require 'shellwords'

# The native grid (ext/mb/term/fast_term) against the Ruby Cells: the same
# cells, text, and bytes.  (Moved from mb-sound's fast_ui_spec.rb with the
# C, term-extract-1; mb-sound's memcheck runs this file too.)
RSpec.describe('MB::Term::NativeCells', :aggregate_failures) do
  before { skip 'fast_term is not compiled (rake compile)' unless defined?(MB::Term::NativeCells) }

  let(:cells) { MB::Term::Cells }
  let(:native) { MB::Term::NativeCells }
  let(:modes) { %i[none truecolor ansi256 ansi16] }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../lib/mb/term/fast_term.so', __dir__)
    code = 'GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Term::FastTerm::Grid.new(3, 2).width'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('3'), out
  end

  it 'is the registered native grid unless an adapter registered a subclass' do
    expect(MB::Term::Grid.native <= native).to eq(true)
  end

  it 'checks sizes and arguments' do
    expect { native.new(-1, 2) }.to raise_error(ArgumentError)
    expect { native.new(3, 2).copy_from(native.new(2, 3)) }.to raise_error(ArgumentError)
    expect { native.new(3, 2).frame(native.new(2, 3), :none) }.to raise_error(ArgumentError)
    expect { native.new(3, 2).frame(Object.new, :none) }.to raise_error(TypeError)
    expect(MB::Term::FastTerm::Grid.allocate.lines(0)).to eq([]) # (allocated, not initialized: 0x0)
  end

  # The same random edits on Ruby Cells and NativeCells
  def edit_both(a, b, rng, count)
    colors = [nil, [255, 0, 0], [0, 0, 0], [138, 138, 133], [95, 135, 175], [8, 8, 8], [254, 254, 254], [17, 168, 205], 1, 9, 200]
    chars = [' ', 'a', '⠿', '█', '▀', '│', '🬀', 'µ', '中', '', "\0"]
    count.times do
      x = rng.rand(-2..a.width + 1)
      y = rng.rand(-2..a.height + 1)
      if rng.rand(3) == 0
        str = Array.new(rng.rand(0..12)) { chars.sample(random: rng) }.join
        fg = colors.sample(random: rng)
        bold = rng.rand(2) == 0
        max = [nil, 3].sample(random: rng)
        a.text(x, y, str, fg: fg, bold: bold, max: max)
        b.text(x, y, str, fg: fg, bold: bold, max: max)
      else
        ch = chars.sample(random: rng)
        fg = colors.sample(random: rng)
        bg = colors.sample(random: rng)
        bold = rng.rand(2) == 0
        rev = rng.rand(3) == 0
        a.set(x, y, ch, fg: fg, bg: bg, bold: bold, reverse: rev)
        b.set(x, y, ch, fg: fg, bg: bg, bold: bold, reverse: rev)
      end
    end
  end

  it 'gives the same lines, text, and characters as Cells in every color mode' do
    rng = Random.new(11)
    [[1, 1], [10, 4], [61, 17]].each do |w, h|
      a = cells.new(w, h)
      b = native.new(w, h)
      edit_both(a, b, rng, w * h)
      modes.each do |m|
        expect(b.lines(m)).to eq(a.lines(m)), "#{w}x#{h} #{m}"
        expect(b.to_text(m)).to eq(a.to_text(m))
      end
      expect(b.char(w - 1, h - 1)).to eq(a.char(w - 1, h - 1))
      expect(b.lines(:truecolor).first.encoding).to eq(Encoding::UTF_8)
    end
  end

  it 'writes styled runs (put_run) like Cells, with every attribute, palette indexes, and wide-character halves' do
    rng = Random.new(21)
    a = cells.new(30, 6)
    b = native.new(30, 6)
    pack = MB::Term::Cells.method(:pack)
    colors = [nil, [255, 0, 0], [12, 200, 7], 0, 3, 8, 15, 16, 100, 231, 232, 255].map { |c| pack.(c) }
    60.times do
      str = Array.new(rng.rand(0..9)) { ['x', '中', "\0", 'é', ' '].sample(random: rng) }.join
      x = rng.rand(-3..32)
      y = rng.rand(-1..6)
      args = [x, y, str, colors.sample(random: rng), colors.sample(random: rng), rng.rand(32)]
      a.put_run(*args)
      b.put_run(*args)
    end
    modes.each do |m|
      expect(b.lines(m)).to eq(a.lines(m)), m.to_s
      expect(b.frame(nil, m)).to eq(a.frame(nil, m))
    end
    expect(a.lines(:none).join).not_to include("\0")

    g = native.new(6, 1)
    g.put_run(0, 0, "中\0ab", pack.(1), pack.(200), MB::Term::Cells::UNDERLINE | MB::Term::Cells::DIM)
    expect(g.lines(:none)).to eq(['中ab  '])
    expect(g.char(1, 0)).to eq('')
    expect(g.lines(:truecolor)).to eq(["\e[2;4;31;48;5;200m中ab\e[0m  "])
    expect(g.lines(:ansi16).first).to start_with("\e[2;4;31;")
  end

  it 'blits a smaller grid into a larger one at any offset, clipped, like Cells#blit (ui-fix-3)' do
    rng = Random.new(31)
    [[20, 7, 6, 3], [5, 2, 9, 4], [12, 6, 12, 6]].each do |w, h, sw, sh|
      a = cells.new(w, h)
      b = native.new(w, h)
      edit_both(a, b, rng, w * h)
      sa = cells.new(sw, sh)
      sb = native.new(sw, sh)
      [[0, 0], [w - 2, h - 1], [-3, -1], [-sw, 0], [w, 0], [2, 1], [rng.rand(-4..w), rng.rand(-2..h)]].each do |x, y|
        edit_both(sa, sb, rng, sw * sh)
        expect(a.blit(sa, x, y)).to equal(a)
        expect(b.blit(sb, x, y)).to equal(b)
        modes.each { |m| expect(b.lines(m)).to eq(a.lines(m)), "#{w}x#{h} <- #{sw}x#{sh} at #{x},#{y} #{m}" }
      end
    end
    g = native.new(6, 2)
    s = native.new(2, 1)
    s.text(0, 0, 'ab')
    g.blit(s, 5, 1)
    g.blit(s, -1, 0)
    expect(g.lines(:none)).to eq(['b     ', '     a'])
    expect { cells.new(2, 2).blit(native.new(1, 1), 0, 0) }.to raise_error(ArgumentError)
    expect { native.new(2, 2).blit(cells.new(1, 1), 0, 0) }.to raise_error(TypeError)
  end

  it 'maps every color like ANSI' do
    rng = Random.new(2)
    a = cells.new(64, 4)
    b = native.new(64, 4)
    64.times do |x|
      4.times do |y|
        rgb = Array.new(3) { [0, 1, 7, 8, 9, 94, 95, 96, 114, 115, 116, 255, rng.rand(256)].sample(random: rng) }
        a.set(x, y, 'x', fg: rgb, bg: rgb.reverse)
        b.set(x, y, 'x', fg: rgb, bg: rgb.reverse)
      end
    end
    %i[ansi256 ansi16].each { |m| expect(b.lines(m)).to eq(a.lines(m)) }
  end

  it 'encodes frames (full and changed cells) like Cells#frame' do
    rng = Random.new(4)
    [[1, 1], [12, 5], [60, 16]].each do |w, h|
      a = cells.new(w, h)
      b = native.new(w, h)
      pa = cells.new(w, h)
      pb = native.new(w, h)
      6.times do |k|
        edit_both(a, b, rng, k == 0 ? w * h : rng.rand(w * 2))
        modes.each do |m|
          [[nil, nil], [pa, pb]].each do |prev_a, prev_b|
            [true, false].each do |sync|
              fa = a.frame(prev_a, m, row: 3, col: 7, sync: sync)
              fb = b.frame(prev_b, m, row: 3, col: 7, sync: sync)
              expect(fb).to eq(fa), "#{w}x#{h} frame #{k} #{m} diff=#{!prev_a.nil?} sync=#{sync}"
            end
          end
        end
        pa.copy_from(a)
        pb.copy_from(b)
      end
      expect(b.frame(pb, :truecolor)).to eq("\e[?2026h\e[0m\e[?2026l")
    end
  end

  it 'writes frames without the GVL' do
    g = native.new(20, 3)
    g.text(0, 1, 'hello ⠿ world', fg: [255, 128, 0])
    r, w = IO.pipe
    n = g.write_frame(w, nil, :truecolor, row: 2, col: 1)
    w.close
    bytes = r.read
    expect(n).to eq(bytes.bytesize)
    expect(bytes.force_encoding('UTF-8')).to eq(g.frame(nil, :truecolor, row: 2, col: 1))
  ensure
    r&.close
  end

  it 'waits on a full non-blocking descriptor instead of raising EAGAIN (macOS terminals)' do
    require 'io/nonblock'
    g = native.new(200, 60)
    rng = Random.new(3)
    # A color per cell, so the frame is several pipe buffers long
    60.times do |y|
      200.times do |x|
        g.text(x, y, '⠿⣿⡇'[rng.rand(3)], fg: [rng.rand(256), rng.rand(256), rng.rand(256)])
      end
    end
    expected = g.frame(nil, :truecolor, row: 1, col: 1)
    expect(expected.bytesize).to be > 200_000 # several pipe buffers

    r, w = IO.pipe
    w.nonblock = true
    reader = Thread.new do
      out = +''
      while (chunk = r.read(4096))
        out << chunk
        sleep 0.0005
      end
      out
    end
    n = g.write_frame(w, nil, :truecolor, row: 1, col: 1)
    w.close
    bytes = reader.value
    expect(n).to eq(expected.bytesize)
    expect(bytes.force_encoding('UTF-8')).to eq(expected)
  ensure
    r&.close
  end

end
