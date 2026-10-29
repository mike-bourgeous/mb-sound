RSpec.describe(MB::Term::Cells, :aggregate_failures) do
  let(:cells) { described_class }

  it 'packs colors, with palette indexes marked' do
    expect(cells.pack([1, 2, 3])).to eq(0x010203)
    expect(cells.pack(9)).to eq(cells::INDEXED | 9)
    expect(cells.pack(nil)).to be_nil
    expect(cells.unpack(0x010203)).to eq([1, 2, 3])
    expect(cells.color_of(cells::INDEXED | 9)).to eq(9)
    expect(cells.color_of(0x0a0b0c)).to eq([10, 11, 12])
  end

  it 'gives lines with SGR codes in each color mode' do
    c = cells.new(6, 2)
    c.text(0, 0, 'ab', fg: [255, 0, 0], bold: true)
    c.set(3, 1, 'z', bg: 4)
    expect(c.lines(:none)).to eq(['ab    ', '   z  '])
    expect(c.lines(:truecolor)[0]).to eq("\e[1;38;2;255;0;0mab\e[0m    ")
    expect(c.lines(:ansi256)[0]).to eq("\e[1;38;5;196mab\e[0m    ")
    expect(c.lines(:ansi16)[0]).to eq("\e[1;31mab\e[0m    ")
    expect(c.lines(:truecolor)[1]).to eq("   \e[44mz\e[0m  ")
    expect(c.to_text(:none)).to eq("ab    \n   z  ")
  end

  it 'writes runs, wide-character halves, and clips at the edges' do
    c = cells.new(4, 1)
    c.put_run(-1, 0, 'x中' + "\0" + 'yz', nil, nil, cells::REVERSE)
    expect(c.lines(:none)).to eq(['中yz'])
    expect(c.char(1, 0)).to eq('')
    c.put_run(0, 5, 'no', nil, nil, 0) # (off the grid)
    expect(c.lines(:none)).to eq(['中yz'])
  end

  it 'blits a smaller grid at an offset, clipped' do
    big = cells.new(5, 3)
    small = cells.new(3, 2)
    small.text(0, 0, 'abc')
    small.text(0, 1, 'def')
    big.blit(small, 3, 2)
    expect(big.lines(:none)).to eq(['     ', '     ', '   ab'])
    big.blit(small, -1, 0)
    expect(big.lines(:none)[0..1]).to eq(['bc   ', 'ef   '])
  end

  it 'encodes full frames and only the changed cells, with nearby unchanged cells rewritten instead of skipped' do
    a = cells.new(20, 2)
    a.text(0, 0, 'hello')
    full = a.frame(nil, :none, row: 2, col: 3)
    expect(full).to eq("\e[?2026h\e[2;3Hhello               \e[3;3H                    \e[?2026l")

    prev = cells.new(20, 2)
    prev.copy_from(a)
    a.text(0, 0, 'J')
    a.text(3, 0, 'p')
    a.text(15, 1, 'x', fg: [0, 255, 0])
    expect(a.frame(prev, :truecolor, sync: false)).to eq("\e[0m\e[1;1HJelp\e[2;16H\e[38;2;0;255;0mx\e[0m")
    prev.copy_from(a)
    expect(a.frame(prev, :none)).to eq("\e[?2026h\e[?2026l")
  end

  it 'replays its frames through Screen to the same lines' do
    rng = Random.new(5)
    a = cells.new(30, 6)
    prev = cells.new(30, 6)
    screen = MB::Term::Screen.new(6, 30)
    5.times do
      rng.rand(40).times do
        a.text(rng.rand(30), rng.rand(6), %w[a b c ⠿ █][rng.rand(5)], fg: [rng.rand(256), 0, 0], bold: rng.rand(2) == 1)
      end
      screen.feed(a.frame(prev, :truecolor))
      prev.copy_from(a)
      expect(screen.lines(:none)).to eq(a.lines(:none))
      expect(screen.lines(:truecolor)).to eq(a.lines(:truecolor))
    end
  end
end

RSpec.describe(MB::Term::ANSI) do
  it 'maps colors to SGR parameters in each mode' do
    expect(described_class.color([255, 0, 0], :truecolor, false)).to eq('38;2;255;0;0')
    expect(described_class.color([255, 0, 0], :ansi256, true)).to eq('48;5;196')
    expect(described_class.color([255, 0, 0], :ansi16, false)).to eq('31')
    expect(described_class.color(3, :truecolor, false)).to eq('33')
    expect(described_class.color(12, :truecolor, true)).to eq('104')
    expect(described_class.color(208, :ansi256, false)).to eq('38;5;208')
    expect(described_class.color(208, :ansi16, false)).to match(/\A9[0-7]\z|\A3[0-7]\z/)
    expect(described_class.xterm(16)).to eq([0, 0, 0])
    expect(described_class.xterm(255)).to eq([238, 238, 238])
  end
end
