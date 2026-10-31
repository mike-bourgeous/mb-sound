# The one range mapping (knobs-1): knobs, controllers, params, ramps,
# crossfades, gestures, and velocity peaks map positions through
# Param::Scale, so the same range answers alike everywhere.
RSpec.describe(MB::Sound::Param::Scale, :aggregate_failures) do
  let(:exp) { described_class.new(lo: 150.0, hi: 8000.0, curve: :exp) }
  let(:lin) { described_class.new(lo: -2.0, hi: 6.0, curve: :linear) }

  it 'maps positions to values and back on exp and linear spans' do
    expect(exp.value(0.0)).to eq(150.0)
    expect(exp.value(1.0)).to eq(8000.0) # (the pow form lands on the end)
    expect(exp.value(0.5)).to be_within(1e-9).of(Math.sqrt(150.0 * 8000.0))
    expect(exp.position(exp.value(0.3))).to be_within(1e-12).of(0.3)
    expect(lin.value(0.25)).to eq(0.0)
    expect(lin.position(4.0)).to eq(0.75)
    expect(lin.value(1.5)).to eq(10.0) # (outside 0..1: outside the span)

    # Floats and DFloats give the same numbers
    pos = Numo::DFloat[0.0, 0.1, 0.37, 0.5, 0.99, 1.0]
    [exp, lin].each do |s|
      expect(s.value(pos).to_a).to eq(pos.to_a.map { |p| s.value(p) })
      expect(s.position(s.value(pos)).to_a).to eq(s.value(pos).to_a.map { |v| s.position(v) })
    end
  end

  it 'refuses exp spans touching 0, and maps falling spans' do
    expect { described_class.new(lo: 0.0, hi: 1.0, curve: :exp) }.to raise_error(ArgumentError, /include or cross 0/)
    down = described_class.new(lo: 1.0, hi: 0.125, curve: :exp)
    expect(down.value(1 / 3.0)).to be_within(1e-12).of(0.5)
  end

  it 'gives ramps the knob_ramp kernel\'s terms, and #between their values' do
    k, a, b = exp.ramp_terms(300.0, 2400.0)
    r = Math.log(8000.0 / 150.0)
    p0 = Math.log(300.0 / 150.0) / r
    p1 = Math.log(2400.0 / 150.0) / r
    expect([k, a, b]).to eq([r * (p1 - p0), Math.log(150.0), p0 * r])
    expect(exp.between(300.0, 2400.0, 0.25)).to eq(Math.exp(0.25 * k + a + b))
    expect(exp.between(300.0, 2400.0, 1.0)).to be_within(1e-9).of(2400.0)
    expect(lin.ramp_terms(1.0, 3.0)).to eq([2.0, 1.0, 0.0])
    expect(lin.between(1.0, 3.0, 0.25)).to eq(1.5)

    # The C kernel computes the same values
    out = Numo::SFloat.zeros(8)
    MB::Sound::FastArithmetic.knob_ramp(out, 0, 8, 0, 8, 0, true, k, a, b, 2400.0)
    expect(out.to_a).to eq((1..8).map { |j| j == 8 ? 2400.0 : exp.between(300.0, 2400.0, j / 8.0) }.map { |v| Numo::SFloat[v][0] })
  end

  it 'shifts numbers and nodes by positions (Knob#mod)' do
    expect(exp.shift(300.0, 1.0, 0.25)).to be_within(1e-9).of(exp.value(exp.position(300.0) + 0.25))
    expect(lin.shift(1.0, -1.0, 0.5)).to eq(-3.0)
    node = exp.shift(300.0.constant, 0.5.constant, 0.5)
    expect(node.sample(4).to_a.map { |v| v.round(3) }).to all(eq(exp.shift(300.0, 0.5, 0.5).round(3)))
  end

  # The property the one mapping exists for (the maintainer's rule:
  # knobs consistent across settings and nodes): over seeded random spans,
  # a Param, a knob spec, a MIDI controller spec, and a velocity range on
  # the same span and curve give the same values at the same positions.
  it 'answers alike through every declaration form (seeded sweep)' do
    rng = Random.new(20261030)
    40.times do
      curve = rng.rand < 0.5 ? :exp : :linear
      lo = curve == :exp ? 10**rng.rand(-2.0..2.0) : rng.rand(-100.0..100.0)
      hi = curve == :exp ? lo * 10**rng.rand(0.3..3.0) : lo + rng.rand(0.1..500.0)
      param = MB::Sound::Param.declare(:x, (lo..hi).at(lo), curve: curve)
      spec = MB::Sound::GraphNode::Knob::Spec.new(name: :x, default: (lo..hi).at(lo), curve: curve)
      cc = MB::Sound::MIDI::ControlSpec.new(number: 1, range: lo..hi, curve: curve)
      raw = rng.rand(0..127)
      pos = raw / 127.0
      want = described_class.value(pos, lo, hi, curve)
      expect(param.value(pos)).to eq(want), "#{lo}..#{hi} #{curve}"
      expect(spec.value(pos)).to eq(want)
      expect(cc.value(raw)).to eq(want)
      expect(MB::Sound::Envelope.velocity_peak(pos, lo, hi, curve == :exp)).to eq(want)
      v = spec.value(rng.rand)
      expect([param.position(v), cc.position(v)]).to all(eq(spec.position(v)))
    end
  end

  # (session-2: level knobs' gain taper, the maintainer's "dB curve")
  it 'maps the :fader taper: 0 dB mid-travel on 0..4, silence at the bottom, through every declaration form' do
    f = described_class.new(lo: 0.0, hi: 4.0, curve: :fader)
    expect(f).to be_fader
    expect([0.0, 0.25, 0.5, 1.0].map { |p| f.value(p) }).to eq([0.0, 0.25, 1.0, 4.0])
    expect([0.0, 0.25, 1.0, 4.0].map { |v| f.position(v) }).to eq([0.0, 0.25, 0.5, 1.0])
    expect(f.value(-0.5)).to eq(-1.0) # (outside the range: odd, so positions stay monotonic)
    expect(f.position(-1.0)).to eq(-0.5)
    expect(f.value(Numo::DFloat[0.25, 0.5]).to_a).to eq([0.25, 1.0])
    expect(f.position(Numo::DFloat[0.25, 1.0]).to_a).to eq([0.25, 0.5])
    # ramps and crossfades move evenly in position
    k, a, b = f.ramp_terms(1.0, 0.0)
    expect([k, a, b]).to eq([-0.5, 0.5, 0.0])
    expect(f.between(1.0, 0.0, 0.5)).to eq(0.25)
    expect(f.shift(1.0, 0.25, 2)).to eq(4.0)

    param = MB::Sound::Param.declare(:x, (0.0..4.0).at(1.0), curve: :fader)
    spec = MB::Sound::GraphNode::Knob::Spec.new(name: :x, default: (0.0..4.0).at(1.0), curve: :fader)
    cc = MB::Sound::MIDI::ControlSpec.new(number: 1, range: 0.0..4.0, curve: :fader)
    [0, 31, 64, 100, 127].each do |raw|
      want = f.value(raw / 127.0)
      expect([param.value(raw / 127.0), spec.value(raw / 127.0), cc.value(raw)]).to all(eq(want))
    end
    expect([param.position(2.0), cc.position(2.0)]).to all(eq(spec.position(2.0)))
    expect(spec.to_ruby).to eq('knob :x, (0.0..4.0).at(1.0), curve: :fader')
  end
end
