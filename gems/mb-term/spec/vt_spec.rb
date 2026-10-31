# Both implementations (RubyVT, and NativeVT when fast_term is compiled;
# vt_native_spec.rb compares their whole states).
[:RubyVT, :NativeVT].each do |impl|
  RSpec.describe("MB::Term::#{impl}", :aggregate_failures) do
    before { skip 'fast_term is not compiled (rake compile)' unless MB::Term.const_defined?(impl) }

    let(:klass) { MB::Term.const_get(impl) }
    let(:vt) { klass.new(5, 10) }
    let(:cells) { MB::Term::Cells }

    def rows(v = vt) = v.lines.map(&:rstrip)
    def scrollback(v) = (v.dropped...(v.dropped + v.scrollback_length)).map { |n| v.line_at(n) }

    it 'uses the same palette-index bit as Cells' do
      expect(MB::Term::VT::INDEXED).to eq(cells::INDEXED)
      expect(MB::Term::VT::UNDERLINE).to eq(cells::UNDERLINE)
      expect(MB::Term::VT::DIM).to eq(cells::DIM)
    end

    it 'writes text, wraps with a pending wrap, and scrolls lines into the scrollback' do
      vt.feed("hello\r\nabcdefghijKL\r\n3\r\n4\r\n5\r\n6")
      expect(rows).to eq(%w[KL 3 4 5 6])
      expect(scrollback(vt).map(&:to_s)).to eq(%w[hello abcdefghij])
      expect(scrollback(vt).last.wrapped).to eq(true)
      expect(vt.text_between(1, 3)).to eq("abcdefghijKL\n3")

      v = klass.new(2, 4)
      v.feed('abcd')
      expect([v.row, v.col]).to eq([0, 3]) # pending wrap: still on the last column
      v.feed("\r")
      expect([v.row, v.col]).to eq([0, 0])
    end

    it 'keeps at most the scrollback limit, with stable absolute line numbers' do
      v = klass.new(2, 5, scrollback: 3)
      10.times { |i| v.feed("#{i}\r\n") }
      expect(scrollback(v).map(&:to_s)).to eq(%w[6 7 8])
      expect(v.dropped).to eq(6)
      expect(v.line_at(6).to_s).to eq('6')
      expect(v.line_at(5)).to be_nil
      expect(v.search('7')).to eq([7, 0, 1])
    end

    it 'completes sequences and UTF-8 characters split across feeds' do
      vt.feed("\e[3")
      vt.feed("1mred\e[0m \xE4".b)
      vt.feed("\xB8\xAD".b)
      expect(rows[0]).to eq('red 中')
      expect(vt.screen[0].fg_at(0)).to eq(MB::Term::VT::INDEXED | 1)
      expect(vt.screen[0].fg_at(3)).to be_nil
    end

    it 'records sync marks (an OSC that draws nothing), split across feeds too' do
      expect(vt.sync_mark).to eq(0)
      vt.feed("ab\e]7765;")
      expect(vt.sync_mark).to eq(0)
      vt.feed("3\acd\e]7765;4\e\\")
      expect(vt.sync_mark).to eq(4)
      expect(rows[0]).to eq('abcd')
      expect(vt.take_replies).to eq('')
    end

    it 'reads SGR colors and attributes' do
      vt.feed("\e[1;4;38;5;200;48;2;1;2;3mA\e[22;24;39;49;7mB\e[0;93;2;3mC")
      r = vt.screen[0]
      expect(r.attr_at(0)).to eq(MB::Term::VT::BOLD | MB::Term::VT::UNDERLINE)
      expect(r.fg_at(0)).to eq(MB::Term::VT::INDEXED | 200)
      expect(r.bg_at(0)).to eq(0x010203)
      expect([r.attr_at(1), r.fg_at(1), r.bg_at(1)]).to eq([MB::Term::VT::REVERSE, nil, nil])
      expect([r.attr_at(2), r.fg_at(2)]).to eq([MB::Term::VT::DIM | MB::Term::VT::ITALIC, MB::Term::VT::INDEXED | 11])
    end

    it 'puts wide characters in two cells and wraps them whole' do
      vt.feed('abcdefghi中')
      expect(rows[0]).to eq('abcdefghi')
      expect(rows[1]).to eq('中')
      expect(vt.screen[1].text[0, 2]).to eq("中\0")
      vt.feed("\e[2;2Hx") # overwriting the right half blanks the left
      expect(rows[1]).to eq(' x')
    end

    it 'moves the cursor, erases, inserts, and deletes' do
      vt.feed("0123456789\e[2;3Hab\e[1;5H\e[K\e[2;1H\e[2@\e[3;1Hxyz\e[1D\e[P")
      expect(rows[0]).to eq('0123')
      expect(rows[1]).to eq('    ab')
      expect(rows[2]).to eq('xy')
      vt.feed("\e[2;1H\e[L")
      expect(rows[1]).to eq('')
      expect(rows[2]).to eq('    ab')
      vt.feed("\e[1;1H\e[M")
      expect(rows[0]).to eq('')
      vt.feed("\e[2J")
      expect(rows).to all(eq(''))
    end

    it 'scrolls inside a scroll region without touching the scrollback' do
      vt.feed("top\r\n1\r\n2\r\n3\r\nbot\e[2;4r\e[4;1H\nnew")
      expect(rows).to eq(['top', '2', '3', 'new', 'bot'])
      expect(vt.scrollback_length).to eq(0)
      vt.feed("\e[2;1H\eM")
      expect(rows).to eq(['top', '', '2', '3', 'bot'])
    end

    it 'answers cursor, status, device, and mode reports' do
      vt.feed("ab\e[6n\e[5n\e[c\e[?2004h\e[?2004$p\e[?1$p")
      expect(vt.take_replies).to eq("\e[1;3R\e[0n\e[?62;22c\e[?2004;1$y\e[?1;2$y")
      expect(vt.take_replies).to eq('')
      expect(vt.bracketed_paste?).to eq(true)
    end

    it 'switches to the alternate screen and back' do
      vt.feed("main\e[?1049h\e[Halt")
      expect(rows[0]).to eq('alt')
      expect(vt.alt?).to eq(true)
      vt.feed("\e[?1049l")
      expect(rows[0]).to eq('main')
      expect([vt.row, vt.col]).to eq([0, 4])
    end

    it 'resizes, moving rows above the cursor to the scrollback when shorter' do
      vt.feed("1\r\n2\r\n3\r\n4\r\n5")
      vt.resize(3, 4)
      expect(rows).to eq(%w[3 4 5])
      expect(scrollback(vt).map(&:to_s)).to eq(%w[1 2])
      vt.resize(4, 12)
      expect(vt.lines.map(&:length)).to all(eq(12))
      expect(vt.cols).to eq(12)
    end

    it 'searches backward and forward, case-insensitively for lowercase text' do
      vt.feed("Alpha\r\nbeta\r\nALPHA beta\r\n")
      expect(vt.search('alpha')).to eq([2, 0, 5])
      expect(vt.search('alpha', from: 2)).to eq([0, 0, 5])
      expect(vt.search('Alpha', from: 0, backward: false)).to be_nil
      expect(vt.search(/b.ta/, from: 0, backward: false)).to eq([1, 0, 4])
    end

    it 'draws only changed rows, the scrolled-back view, and marks, into a grid' do
      vt.feed("\e[31mred\e[0m plain\r\n\e[44mblue\e[0m 中x")
      a = cells.new(12, 5)
      expect(vt.draw(a, 1, 0, 11, 5)).to eq(5)
      expect(a.lines(:none)[1]).to eq(' blue 中x   ')
      expect(a.lines(:ansi16)[0]).to start_with(" \e[31mred\e[0m")
      expect(vt.dirty?).to eq(false)

      vt.feed("\e[1;1Hx")
      expect(vt.draw(a, 1, 0, 11, 5)).to eq(1)

      vt.draw(a, 1, 0, 11, 5, marks: [[0, 0, 2, MB::Term::VT::REVERSE]])
      expect(a.lines(:ansi16)[0]).to start_with(" \e[7mx\e[0m")
    end

    it 'keeps up with long output (10 000 lines)' do
      v = klass.new(40, 120)
      text = (1..10_000).map { |i| "line #{i} \e[32m#{'x' * 60}\e[0m" }.join("\r\n")
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      v.feed(text)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
      expect(v.scrollback_length).to eq(9960)
      expect(v.lines.last.rstrip).to eq("line 10000 #{'x' * 60}")
      expect(elapsed).to be < 2.0 # ~0.15 s on the Mac container
    end
    # ui-api-1 (maintainer, 2026-10-18: `ui :off` lost color: "The history
    # text copied from the panel to the terminal")
    it 'gives a row back as text with SGR for its styles, changing only where the style does' do
      vt = klass.new(3, 40)
      vt.feed("plain \e[1;31mbold red\e[0m mid \e[38;5;208mor\e[48;2;1;2;3mange\e[0m   \r\n")
      vt.feed("no style at all\r\n")
      row = vt.line_at(vt.dropped + vt.scrollback_length)
      expect(row.to_sgr).to eq("plain \e[0;1;31mbold red\e[0m mid \e[0;38;5;208mor\e[0;38;5;208;48;2;1;2;3mange\e[0m")
      expect(row.to_s).to eq('plain bold red mid orange')
      expect(vt.line_at(vt.dropped + vt.scrollback_length + 1).to_sgr).to eq('no style at all')
      # (what the terminal shows from it is the VT's own row again)
      vt2 = klass.new(3, 40)
      vt2.feed(row.to_sgr)
      r2 = vt2.line_at(vt2.dropped + vt2.scrollback_length)
      expect((0...row.length).map { |c| [r2.char(c), r2.fg_at(c), r2.bg_at(c), r2.attr_at(c)] }).to eq((0...row.length).map { |c| [row.char(c), row.fg_at(c), row.bg_at(c), row.attr_at(c)] })
    end

  end
end
