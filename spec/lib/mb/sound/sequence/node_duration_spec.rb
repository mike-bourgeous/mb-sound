# Counted musical lengths (reese-params-2, 2026-11-07): `lfo_bars.bars` is
# a tempo LFO rate that follows a param or knob while playing.
RSpec.describe(MB::Sound::Sequence::NodeDuration, :aggregate_failures) do
  after { MB::Sound.rewind; MB::Sound.bpm 120 }

  def grab(node, total, buffer)
    out = []
    (total.to_f / buffer).ceil.times { out << node.sample(buffer).dup }
    SpecBuffers.join(out)[0...total]
  end

  it 'plays exactly like the Duration while the count holds still, at Rational and Float tempos' do
    [120, 173.5].each do |bpm|
      MB::Sound.bpm bpm
      [2, 1.5, 0.25].each do |b|
        expect(grab(b.to_f.constant.bars.lfo, 9600, 800)).to eq(grab(b.bars.lfo, 9600, 800)), "#{b} bars at #{bpm} BPM"
      end
    end
  end

  it 'follows a moving count with the same samples at any buffer size' do
    sweep = -> { MB::Sound.tween([2.0, 0.5, 4.0], 1.bar, loop: false).bars.lfo }
    ref = grab(sweep.(), 48000 * 3, 800)
    expect(grab(sweep.(), 48000 * 3, 367)).to eq(ref)
    expect(grab(sweep.(), 48000 * 3, 64)).to eq(ref)
    expect(ref).not_to eq(grab(2.bars.lfo, 48000 * 3, 800))
  end

  it 'changes its cycle with no phase jump' do
    c = 2.0.constant
    lfo = c.bars.lfo
    before = grab(lfo, 24_000, 800)
    c.constant = 0.5
    after = grab(lfo, 24_000, 800)
    x = SpecBuffers.join([before, after])
    steps = (x[1..] - x[0...-1]).abs
    slope = 2 * Math::PI / (0.5 * 2 * 48000) # (the fastest a sine of the new cycle moves per sample)
    expect(steps[23_000...25_000].max).to be < slope * 1.01
    expect(steps[25_000..].max).to be > slope * 0.9 # (four times as fast)
  end

  it 'refuses counts that are not nodes' do
    expect { described_class.new(2, 1.bar, :bars) }.to raise_error(ArgumentError, /graph node/)
  end

  it 'keeps the param in saved graphs: a voice LFO rate and a tempo pitch, turned by a param override' do
    text = <<~DOC
      graph 9, name: "bars_test", kind: :synth
      inputs midi: :notes
      param :rate, (0.25..16.0).at(2.0), description: "Bars per cycle"

      synth(midi, voices: 1) { |v|
        v.hz.saw * rate.bars.hz.lfo.at(0..1) * v.lfo(rate.bars, depth: 0.5)
      }
    DOC
    clip = -> { MB::Sound.seq(MB::Sound::F2).n1.loop }
    saved = MB::Sound::GraphIO.dump(MB::Sound::GraphIO.load(text, inputs: { midi: clip.() }))
    expect(saved).to include('v.hz.saw * rate.bars.hz.lfo.at(0..1) * v.lfo(rate.bars, depth: 0.5)')
    expect(saved).to include('param :rate, (0.25..16.0).at(2.0)')

    one = MB::Sound::GraphIO.load(saved, inputs: { midi: clip.() }, params: { rate: 1 })
    written = MB::Sound::GraphIO.load(text.gsub('rate.bars', '1.bar'), inputs: { midi: clip.() })
    expect(grab(one, 14_400, 800)).to eq(grab(written, 14_400, 800))
  end
end
