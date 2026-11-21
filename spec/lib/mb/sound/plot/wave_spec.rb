require_relative '../../../../support/allocation_budget'

RSpec.describe(MB::Sound::Plot::Wave, :aggregate_failures) do
  let(:wave) { MB::Sound::Plot::Wave }
  let(:native) { MB::Sound::Plot::Text::NativeCells }

  # Cycles and curves the displays draw: dense (more samples than dot
  # columns), sparse (fewer), edges past the range, NaN gaps, a flat line
  def corpus
    rng = Random.new(3)
    saw = Numo::SFloat.linspace(-1, 1, 437)
    square = Numo::SFloat.cast(Array.new(300) { |i| i < 120 ? 0.9 : -0.9 })
    sine = Numo::SFloat.cast(Array.new(24) { |i| Math.sin(2 * Math::PI * i / 24) })
    noisy = Numo::SFloat.cast(Array.new(5000) { rng.rand(-1.4..1.4) })
    gaps = saw.dup
    gaps[100...130] = Float::NAN
    [saw, square, sine, noisy, gaps, Numo::SFloat.zeros(64), Numo::SFloat[0.5], Numo::SFloat[], Numo::SFloat[Float::INFINITY, -Float::INFINITY, 0.0]]
  end

  def grid_cells(g)
    (0...g.height).map { |y| (0...g.width).map { |x| g.char(x, y) }.join }
  end

  it 'draws exactly what its Ruby mirror draws, C into native cells and the mirror into native cells and Ruby cells' do
    corpus.each_with_index do |data, k|
      [[40, 8, 0, 0], [7, 3, 2, 1], [1, 1, 0, 0], [30, 6, -3, -2], [12, 4, 20, 10]].each do |w, h, x, y|
        [[-1.0, 1.0, -1], [-0.5, 2.0, 5], [1.0, 1.0, 3]].each do |lo, hi, mark|
          a = native.new(24, 12)
          b = native.new(24, 12)
          r = MB::Term::Cells.new(24, 12)
          [a, b, r].each { |g| g.text(0, 0, 'x' * 24) }
          MB::Sound::FastUI.wave(a, data, x, y, w, h, lo, hi, 0x5fafff, mark, 0x808080)
          wave.draw_ruby(b, data, x, y, w, h, lo, hi, 0x5fafff, mark, 0x808080)
          wave.draw_ruby(r, data, x, y, w, h, lo, hi, 0x5fafff, mark, 0x808080)
          where = "case #{k} #{w}x#{h} at #{x},#{y} #{lo}..#{hi} mark #{mark}"
          expect(grid_cells(a)).to eq(grid_cells(b)), where
          expect(a.lines(:truecolor)).to eq(b.lines(:truecolor)), where
          expect(r.lines(:truecolor)).to eq(a.lines(:truecolor)), where
        end
      end
    end
  end

  it 'draws a saw as a rising line with its reset edge, joined column to column' do
    g = native.new(10, 2)
    wave.draw(g, Numo::SFloat.linspace(-1, 1, 200).concatenate(Numo::SFloat.linspace(-1, 1, 200)), x: 0, y: 0, w: 10, h: 2, lo: -1, hi: 1, fg: 0xffffff)
    text = grid_cells(g)
    expect(text.join).not_to include(' ' * 3) # (no gaps: every column has a dot)
    expect(text[1][0]).not_to eq(' ') # starts at the bottom left
    expect(text[0][9]).not_to eq(' ') # ends at the top right
  end

  it 'marks a playhead column where the line is not' do
    g = native.new(8, 2)
    wave.draw(g, Numo::SFloat.zeros(100), x: 0, y: 0, w: 8, h: 2, lo: -1, hi: 1, fg: 0xffffff, mark: 9, mark_fg: 0x808080)
    # (the line is on the lower row: the marker alone above it, in its color)
    expect(g.char(4, 0)).not_to eq(' ')
    expect(g.lines(:truecolor)[0]).to include('128;128;128')
  end

  it 'allocates nothing in C' do
    g = native.new(120, 30)
    data = Numo::SFloat.linspace(-1, 1, 2048)
    3.times { MB::Sound::FastUI.wave(g, data, 0, 0, 120, 30, -1.0, 1.0, 0xffffff, 40, 0x808080) }
    before = GC.stat(:total_allocated_objects)
    100.times { MB::Sound::FastUI.wave(g, data, 0, 0, 120, 30, -1.0, 1.0, 0xffffff, 40, 0x808080) }
    expect(GC.stat(:total_allocated_objects) - before).to be <= 2
  end
end
