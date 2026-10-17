# The one table (ux-1 item 32).
RSpec.describe(MB::Sound::Table, :aggregate_failures) do
  def plain(t) = t.to_s(color: false)

  it 'sizes columns to their cells, right-aligns numbers on the decimal point, left-aligns text' do
    t = described_class.new([[1, 'a', 2.5], [10, 'bbb', -0.25], [nil, 'c', 100]], header: %w[n name value])
    expect(plain(t).lines.map(&:rstrip)).to eq([
      ' n │ name │  value',
      '───┼──────┼───────',
      ' 1 │ a    │   2.5',
      '10 │ bbb  │  -0.25',
      '   │ c    │ 100',
    ])
  end

  it 'reads a Hash as columns, prints rules between rows, nil as "nil", and ASCII glyphs' do
    allow(MB::Sound::UI).to receive(:glyphs).and_return(:ascii)
    t = described_class.new({ x: [1, 2], y: [nil, 4] }, separate_rows: true, show_nil: true, title: 'T')
    expect(plain(t).lines.map(&:rstrip)).to eq(['T', 'x | y', '--+----', '1 | nil', '--+----', '2 |   4'])
  end

  it 'colors from the UI theme only for terminals without NO_COLOR, and drops escapes given in cells' do
    t = described_class.new([["\e[1mbold\e[0m", 1]], header: ["\e[33mh\e[0m", 'v'])
    expect(plain(t)).not_to include("\e[")
    expect(t.to_s(color: true)).to include("\e[")
    expect(described_class.color?(StringIO.new)).to eq(false)
    expect { t.print(StringIO.new) }.not_to raise_error
  end

  it 'is what the console table prints' do
    expect { MB::Sound.table({ 'sin' => ->(x) { Math.sin(x) } }, range: 0..1, steps: 3) }.to output(/#\s+│ sin\n.*\n\s*0\s+│ 0\n\s*0\.5 │ 0\.479426\n\s*1\s+│ 0\.841471/).to_stdout
  end
end
