RSpec.describe(MB::Sound::GraphNode::Wavetable, aggregate_failures: true) do
  let(:w) { MB::Sound::Wavetable }
  let(:table) { w.from_samples(Numo::SFloat[1, -2, 3, -4], mips: false) }

  def phases(*values)
    MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(values)])
  end

  describe '#initialize' do
    it 'accepts anything Wavetable.[] accepts' do
      expect(phases(0).table_lookup(:saw).table).to equal(w[:saw])
      expect(phases(0).table_lookup('spec/test_data/short_wavetable.flac').table.frame_count).to eq(3)
      expect(phases(0).table_lookup([0, 1, 0, -1]).table.size).to eq(4)
    end

    it 'rejects sample-mode tables' do
      t = w.from_samples(Numo::SFloat.zeros(100), mode: :sample, root: 100)
      expect { phases(0).table_lookup(t) }.to raise_error(ArgumentError, /sample-mode/)
    end

    it 'rejects bad options' do
      expect { phases(0).table_lookup(:saw, wrap: :fold) }.to raise_error(ArgumentError, /Wrapping/)
      expect { phases(0).table_lookup(:saw, interpolation: :magic) }.to raise_error(ArgumentError, /interpolation/)
      expect { phases(0).table_lookup(:saw, scan: 'x') }.to raise_error(ArgumentError, /Scan/)
    end
  end

  describe '#sample' do
    it 'reads one cycle of the table over phases 0...1 (no lost column)' do
      node = phases(0, 0.25, 0.5, 0.75, 0.125).table_lookup(table, interpolation: :linear)
      expect(node.sample(5)).to eq(Numo::SFloat[1, -2, 3, -4, -0.5])
    end

    it 'wraps phases outside 0...1 by default' do
      node = phases(1, 1.25, -0.25, 2.5).table_lookup(table, interpolation: :none)
      expect(node.sample(4)).to eq(Numo::SFloat[1, -2, -4, 3])
    end

    {
      bounce: [3, -2, -2, 3, -4],
      clamp: [1, 1, 1, 1, -4],
      zero: [0, 0, 0, 0, -4],
    }.each do |mode, expected|
      it "can #{mode} phases outside 0...1" do
        node = phases(1.5, 1.75, -0.25, -0.5, 0.75).table_lookup(table, interpolation: :none, wrap: mode)
        expect(node.sample(5)).to eq(Numo::SFloat.cast(expected))
      end
    end

    it 'can choose the wrapping mode with a node' do
      node = phases(1.5, 1.5).table_lookup(table, interpolation: :none, wrap: 0.6.constant)
      expect(node.sample(2)).to eq(Numo::SFloat[1, 1])
    end

    it 'scans across frames' do
      t = w.from_samples([[1, 1, 1, 1], [3, 3, 3, 3]], mips: false, align: false)
      expect(phases(0.1, 0.2).table_lookup(t, scan: 0.5).sample(2)).to all_be_within(1e-6).of_array([2, 2])
      expect(phases(0.1, 0.2).table_lookup(t, scan: phases(0, 1)).sample(2)).to all_be_within(1e-6).of_array([1, 3])
    end

    it 'scans 0..1 with a Tone that has no amplitude' do
      scan = 1.hz.triangle
      100.hz.phasor.table_lookup(:basic, scan: scan)
      expect(scan.range).to eq(0.0..1.0)
    end

    it 'ends when the phase ends' do
      node = phases(0, 0.5).table_lookup(table)
      expect(node.sample(4).length).to eq(2)
      expect(node.sample(4)).to be_nil
    end

    it 'outputs SComplex for a complex table' do
      t = w.from_harmonics([1], complex: true)
      out = phases(0, 0.25).table_lookup(t).sample(2)
      expect(out).to be_a(Numo::SComplex)
      expect(out[1].real).to be_within(1e-4).of(1)
      expect(out[0].imag).to be_within(1e-4).of(-1)
    end

    it 'picks levels from the increment port of a phasor' do
      a = 3000.hz.phasor.wavetable(:saw).sample(800)
      b = 3000.hz.wavetable(:saw).sample(800)
      expect(a).to all_be_within(1e-4).of_array(b)

      # Without increments it reads the brightest level, which aliases
      c = (3000.hz.phasor * 1).table_lookup(:saw).sample(800)
      expect((c - b).abs.max).to be > 0.01
    end

    it 'does not change a shared phase buffer', :check_shared do
      ph = 100.hz.phasor
      lookup = ph.table_lookup(:saw)
      other = ph * 1
      reference = 100.hz.phasor

      3.times do
        lookup.sample(800)
        expect(other.sample(800)).to eq(reference.sample(800))
      end
    end
  end

  describe '#sources' do
    it 'lists the phase, scan, increment, and wrap nodes' do
      node = 100.hz.phasor.table_lookup(:basic, scan: 0.5.constant, wrap: 0.constant)
      expect(node.sources.keys).to eq([:phase, :scan, :increment, :wrap])
    end
  end
end
