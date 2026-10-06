RSpec.describe(MB::Sound::GraphNode::Ports) do
  def nonzero(data)
    data.to_a.each_with_index.reject { |v, _| v == 0 }.map { |v, i| [v.round(6), i] }
  end

  describe 'Tone#wraps on a phasor' do
    it 'marks the first sample after each wrap with 1 - d' do
      # 1001.3 Hz at 48 kHz: the first wrap is (47 * inc + inc - 1) / inc
      # samples before sample 48
      inc = 1001.3 / 48000
      d = (48 * inc - 1) / inc
      wraps = 1001.3.hz.phasor.wraps
      first = nonzero(wraps.sample(100)).first
      expect(first[1]).to eq(48)
      expect(first[0]).to be_within(1e-5).of(1 - d)
    end

    it 'gives 1 for a wrap exactly on a sample, including across buffers' do
      wraps = 1000.hz.phasor.wraps
      expect(nonzero(wraps.sample(48))).to eq([])
      expect(nonzero(wraps.sample(48))).to eq([[1.0, 0]])
    end

    it 'is negative when the phase moves backward' do
      wraps = -1001.3.hz.phasor(phase: 0.5).wraps
      values = nonzero(wraps.sample(200)).map(&:first)
      expect(values).not_to be_empty
      expect(values).to all(be_between(-1, 0))
    end

    it 'gives 1 after a phase jump' do
      phasor = 100.hz.phasor
      wraps = phasor.wraps
      wraps.sample(100)
      phasor.sync_cycles(0.3)
      expect(wraps.sample(10)[0]).to eq(1)
    end
  end

  it 'gives the increment per sample' do
    expect(480.hz.phasor.increment.sample(10)).to all_be_within(1e-7).of_array(Numo::SFloat.new(10).fill(0.01))
  end

  describe 'frames' do
    it 'gives the main output and its ports the same frame in either order' do
      a = 333.hz.phasor
      b = 333.hz.phasor
      aw = a.wraps
      bw = b.wraps

      3.times do
        main_a = a.sample(500).dup
        port_a = aw.sample(500).dup
        port_b = bw.sample(500).dup
        main_b = b.sample(500).dup
        expect(main_a).to eq(main_b)
        expect(port_a).to eq(port_b)
      end
    end

    it 'advances a node read only through a port' do
      m = 220.hz.sine
      counts = Array.new(3) { m.wraps.sample(4800).to_a.count { |v| v != 0 } }
      expect(counts).to all(be_within(1).of(22))
    end

    it 'raises if readers use different buffer sizes' do
      ph = 100.hz.phasor
      w = ph.wraps
      ph.sample(100)
      expect { w.sample(50) }.to raise_error(ArgumentError, /same buffer size/)
    end

    it 'leaves nodes without ports unchanged' do
      expect(100.hz.phasor.ports).to eq({})
      expect(321.hz.ramp.sample(800)).to eq(321.hz.ramp.sample(800))
    end
  end

  describe 'Tone ports' do
    it 'gives sync pulses from the phase, not the phase modulation' do
      plain = 1001.3.hz.ramp.wraps.sample(200)
      modulated = 1001.3.hz.ramp.pm(50.hz.at(2)).wraps.sample(200)
      expect(modulated).to eq(plain)
    end

    it 'keeps the tone output unchanged' do
      t = 777.hz.square
      t.wraps
      expect(t.sample(800)).to eq(777.hz.square.sample(800))
    end
  end

  describe 'introspection' do
    it 'lists declared ports with descriptions' do
      info = 100.hz.phasor.port_info
      expect(info.map { |i| i[:name] }).to eq([:wraps, :increment])
      expect(info.map { |i| i[:description] }).to all(be_a(String))
      expect(100.hz.ramp.port_info.map { |i| i[:name] }).to eq([:wraps, :increment])
    end

    it 'lists ports in use' do
      t = 100.hz.ramp
      t.wraps
      expect(t.ports.keys).to eq([:wraps])
    end

    it 'names a port after its node' do
      ph = 100.hz.phasor.named('Master')
      expect(ph.wraps.graph_node_name).to eq('Master.wraps')
    end

    it 'raises for an unknown port' do
      expect { 100.hz.phasor.port(:nope) }.to raise_error(ArgumentError, /no port/)
    end

    it 'lists inputs' do
      expect(100.hz.ramp.inputs.keys).to include(:frequency)
    end
  end
end
