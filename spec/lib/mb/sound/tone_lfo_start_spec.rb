# Where each LFO shape starts (2026-11-21, the maintainer's take: a ramp
# LFO reads its middle value on the downbeat and jumps on beat 3; decided:
# document with_phase/drumramp, no default change).  The table lives in
# design/notes/oscillators.md ("LFO start phase"); this renders each row's
# shape for one cycle and compares, so the documentation can't drift.
RSpec.describe(MB::Sound::Tone, :aggregate_failures) do
  let(:rate) { 48000 }

  # [expression, starts at, then, top at, bottom at, jump at] from the note.
  def self.table_rows
    text = File.read(File.expand_path('../../../../design/notes/oscillators.md', __dir__))
    body = text[/<!-- lfo-start-table -->\n(.*?)<!-- \/lfo-start-table -->/m, 1] or raise 'no LFO start table in oscillators.md'
    body.lines.drop(2).map { |l| l.split('|').map(&:strip).reject(&:empty?) }
  end

  # A cycle's phase from the table ("1/4", "0", "-").
  def frac(text) = text == '-' ? nil : Rational(text).to_f

  # One cycle of 1.hz.lfo followed by the chain written in the table's
  # first column (`saw`, `saw.with_phase(0.5)`).
  def render(expr)
    node = 1.hz.lfo
    expr.scan(/(\w+)(?:\(([-\d.]+)\))?/) { |m, a| node = a ? node.public_send(m, a.to_f) : node.public_send(m) }
    Numo::SFloat.cast(Array.new(rate / 800) { node.sample(800).to_a }.flatten)
  end

  rows = table_rows

  it 'has the table' do
    expect(rows.length).to be >= 6
    expect(rows.map(&:first)).to include('`saw` (`ramp`, `asaw`)', '`drumramp`', '`sine` (`.lfo`\'s default)')
  end

  rows.each do |shape, start, dir, top, bottom, jump|
    expr = shape[/`([^`]+)`/, 1]
    it "#{expr} starts at #{start}, #{dir}, as the table says" do
      v = render(expr)
      expect(v[0]).to be_within(1e-3).of(Float(start))
      d = v[1] - v[0]
      expect(dir).to eq(d > 1e-6 ? 'rising' : (d < -1e-6 ? 'falling' : 'flat'))
      # (an extreme at the cycle's end shows up as the last sample; a
      # parabola's rounded bottom is flat to float32 for a few samples)
      at = ->(i) { i == rate - 1 ? 1.0 : i.to_f / rate }
      expect(at.(v.max_index)).to be_within(1e-3).of(frac(top))
      expect(at.(v.min_index)).to be_within(1e-3).of(frac(bottom))
      steps = (v[1..] - v[0...-1]).abs
      if frac(jump).nil?
        expect(steps.max).to be < 0.01
      elsif frac(jump) >= 1.0
        expect(steps.max).to be < 0.01 # (the jump is at the next cycle's start)
        expect(v[-1]).to be > 0.99
      else
        expect(steps.max).to be > 1.9
        expect((steps.max_index + 1).to_f / rate).to be_within(2.0 / rate).of(frac(jump))
      end
    end
  end

  it 'aliases in the saw row (ramp, asaw) start and jump the same' do
    saw = render('saw')
    expect(render('ramp')).to eq(saw)
    expect((render('asaw') - saw).abs.max).to be < 1e-3
    expect(render('drumramp')).to eq(render('saw.with_phase(0.5)'))
  end

  it 'starts a bar-synced saw in the middle on the downbeat and jumps on beat 3; drumramp jumps on the downbeat (his 1.bar.lfo.ramp.at(150..2000))' do
    n = 2 * rate # (a bar at the specs' 120 bpm)
    cyc = ->(node) { Numo::SFloat.cast(Array.new(n / 800) { node.sample(800).to_a }.flatten) }
    ramp = cyc.(1.bar.lfo.ramp.at(150..2000))
    expect(ramp[0]).to be_within(0.1).of(1075)
    expect((ramp[1..] - ramp[0...-1]).abs.max_index + 1).to be_within(1).of(n / 2)
    drum = cyc.(1.bar.lfo.drumramp.at(150..2000))
    expect(drum[0]).to be_within(0.1).of(150)
    expect(drum[-1]).to be_within(0.1).of(2000)
    expect((drum[1..] - drum[0...-1]).abs.max).to be < 1
  ensure
    MB::Sound.rewind
  end

  it 'says so on the method pages (help :lfo, :drumramp, :with_phase, :saw) and in help :tones' do
    page = ->(name) { MB::Sound.help(name).to_s.gsub(/\s+/, ' ') }
    expect(page.(:lfo)).to include('drumramp (= saw.with_phase(0.5))', 'jumps from top to bottom at 1/2')
    expect(page.(:drumramp)).to include('saw.with_phase(0.5)', 'downbeat')
    expect(page.(:with_phase)).to include('with_phase(0.5)')
    expect(page.(:saw)).to include('#drumramp starts at')
    expect(page.(:tones)).to include('1.bar.lfo.drumramp')
  end
end
