RSpec.describe(MB::Sound::GraphNode::ChannelMixer::Position, :aggregate_failures) do
  # Gains for a position, as [left, right] Complex numbers
  def gains(x, y, law: :equal_power)
    described_class.new(1.constant, x: x, y: y, law: law).gains.map(&:first)
  end

  # Phase difference (right relative to left) in degrees
  def phase_deg(l, r)
    (Math.atan2((r * l.conj).imag, (r * l.conj).real) * 180 / Math::PI).round(6)
  end

  describe 'levels from x' do
    it 'puts the source fully in one channel at the ends' do
      expect(gains(-1, 1).map(&:abs).map { |v| v.round(12) }).to eq([1, 0])
      expect(gains(1, 1).map(&:abs).map { |v| v.round(12) }).to eq([0, 1])
    end

    it 'keeps constant power with the default equal-power law' do
      [-1, -0.5, 0, 0.3, 1].each do |x|
        [-1, 0, 1].each do |y|
          expect(gains(x, y).sum { |g| g.abs**2 }).to be_within(1e-12).of(1)
        end
      end
      expect(gains(0, 1).map(&:abs)).to all(be_within(1e-12).of(0.5**0.5))
    end

    it 'supports the -4.5 dB and linear laws (ComplexPan used -4.5 dB)' do
      expect(gains(0, 0, law: :minus_4_5db).map(&:abs)).to all(be_within(1e-12).of(0.5**0.75))
      expect(gains(0, 0, law: :linear).map(&:abs)).to all(be_within(1e-12).of(0.5))
      expect(gains(-0.5, 1, law: :linear).map(&:abs).map { |v| v.round(12) }).to eq([0.75, 0.25])
    end
  end

  describe 'phase from y' do
    it 'puts the channels in phase at the front, 90 degrees apart at the side, and opposite at the rear' do
      expect(phase_deg(*gains(0, 1))).to eq(0)
      expect(phase_deg(*gains(0, 0.5))).to eq(45)
      expect(phase_deg(*gains(0, 0))).to eq(90)
      expect(phase_deg(*gains(0, -1)).abs).to eq(180)
      expect(described_class.phase(0)).to be_within(1e-12).of(Math::PI / 2)
    end

    it 'splits the phase evenly between the channels' do
      l, r = gains(0, 0)
      expect(phase_deg(1, l)).to eq(-45)
      expect(phase_deg(1, r)).to eq(45)
    end
  end

  it 'turns a real input into real Lt/Rt with the right phase difference' do
    # Sample the outputs in turn, as a Session does (each output sampled
    # again starts a new frame)
    outs = 1000.hz.sine.place(x: 0, y: 0).outputs
    bufs = Array.new(6) { outs.map { |o| o.sample(800).dup } }
    l, r = bufs.transpose.map { |b| b.reduce(:concatenate) }
    expect(l).to be_a(Numo::SFloat)

    # Compare the analytic signals of the outputs after the Hilbert filter settles
    la = MB::Sound.analytic_signal(l[2400..])
    ra = MB::Sound.analytic_signal(r[2400..])
    cross = (ra * la.conj).sum
    expect(Math.atan2(cross.imag, cross.real) * 180 / Math::PI).to be_within(2).of(90)
    expect(l[2400..].abs.max).to be_within(0.03).of(0.5**0.5)
  end

  it 'keeps complex inputs complex' do
    l, r = 1000.hz.complex_sine.place(x: 0.5, y: -1).outputs.map { |o| o.sample(800) }
    expect(l).to be_a(Numo::SComplex)
    gl, gr = gains(0.5, -1)
    expected = 1000.hz.complex_sine.sample(800)
    expect(l).to all_be_within(1e-5).of_array(expected * gl)
    expect(r).to all_be_within(1e-5).of_array(expected * gr)
  end

  it 'reads x and y from graph nodes' do
    x = MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, 0, 1]])
    y = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 0, -1]])
    pos = described_class.new(1.constant, x: x, y: y)
    pos.outputs.each { |o| o.sample(3) }
    gl, gr = pos.gains.map(&:first)
    expect(gl.abs.to_a.map { |v| v.round(6) }).to eq([1, 0.707107, 0])
    expect(phase_deg(gl[1], gr[1])).to be_within(1e-4).of(90)
    expect(pos.params.keys).to eq([:x, :y])
  end

  it 'is available as #place and #position, for single-channel nodes' do
    expect(100.hz.place(x: 0.5)).to be_a(MB::Sound::GraphNode::Channels)
    expect(100.hz.position(y: -1).outputs[0].original_source).to be_a(described_class)
    expect { MB::Sound.stereo(1.constant, 2.constant).place }.to raise_error(ArgumentError, /single-channel/)
    expect { 100.hz.place(x: 2) }.to raise_error(ArgumentError, /-1..1/)
  end
end
