RSpec.describe(MB::Sound::Length, :aggregate_failures) do
  describe 'Numeric methods' do
    it 'make lengths in samples, seconds, and milliseconds' do
      expect(5.samples).to be_a(MB::Sound::Length::Samples).and have_attributes(value: 5)
      expect(4.seconds).to be_a(MB::Sound::Length::Seconds).and have_attributes(value: 4)
      expect(1.second.value).to eq(1)
      expect(250.ms.value).to eq(0.25)
      expect(2.milliseconds.value).to eq(0.002)
    end
  end

  describe 'GraphNode methods' do
    it 'mark a node as samples or seconds' do
      lfo = 2.hz.lfo
      expect(lfo.samples.node).to equal(lfo)
      expect(lfo.samples).not_to be_fixed
      expect(lfo.seconds).to be_a(MB::Sound::Length::Seconds)
    end
  end

  describe 'arithmetic and comparison' do
    it 'works within a unit' do
      expect(5.samples + 2.samples).to eq(7.samples)
      expect(5.samples - 2.samples).to eq(3.samples)
      expect(3.samples * 2).to eq(6.samples)
      expect(2 * 3.samples).to eq(6.samples)
      expect(6.samples / 2).to eq(3.samples)
      expect(6.samples / 2.samples).to eq(3)
      expect(1.second).to be > 250.ms
      expect(2.5.samples.round).to eq(3.samples)
    end

    it 'refuses to mix units without a rate or tempo' do
      expect { 5.samples + 1.second }.to raise_error(ArgumentError, /Samples/)
      expect { 5.samples + 1.n16 }.to raise_error(ArgumentError, /Samples/)
      expect { lfo = 2.hz.lfo; lfo.samples + 1.samples }.to raise_error(ArgumentError, /graph node/)
    end

    it 'describes itself' do
      expect(5.samples.to_s).to eq('5.0 samples')
      expect(1.samples.to_s).to eq('1.0 sample')
      expect(0.25.seconds.to_s).to eq('0.25 s')
    end
  end

  describe 'conversions' do
    let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

    it 'converts every length to seconds, samples, and whole notes' do
      expect(MB::Sound::Length.seconds(96.samples, sample_rate: 48000)).to eq(0.002)
      expect(MB::Sound::Length.seconds(0.5, sample_rate: 48000)).to eq(0.5)
      expect(MB::Sound::Length.seconds(1.n4, transport: transport)).to eq(0.5)
      expect(MB::Sound::Length.samples(0.5.seconds, sample_rate: 96000)).to eq(48000)
      expect(MB::Sound::Length.samples(10.samples, sample_rate: 96000)).to eq(10)
      expect(MB::Sound::Length.samples(1.n4, sample_rate: 48000, transport: transport)).to eq(24000)
      expect(0.5.seconds.to_whole_notes(transport: transport)).to eq(1/4r)
      expect(24000.samples.to_whole_notes(sample_rate: 48000, transport: transport)).to eq(1/4r)
      expect(1.n8.to_whole_notes).to eq(1/8r)
    end

    it 'refuses graph nodes where a fixed length is needed' do
      expect { MB::Sound::Length.seconds(2.hz.lfo.seconds) }.to raise_error(ArgumentError, /graph node/)
      expect { MB::Sound::Length.seconds(2.hz.lfo) }.to raise_error(ArgumentError, /length of time/)
    end

    it 'snaps lengths within a billionth of a whole sample' do
      expect(MB::Sound::Length.snap(0.1 * 48000)).to eq(4800)
      expect(MB::Sound::Length.snap(4800.4)).to eq(4800.4)
    end
  end

  describe MB::Sound::Length::Source do
    it 'converts fixed lengths at the sample rate when read' do
      src = described_class.new(5.samples)
      expect(src.samples(4, 48000)).to eq(5)
      expect(src.samples(4, 96000)).to eq(5)

      src = described_class.new(0.01)
      expect(src.samples(4, 48000)).to eq(480)
      expect(src.samples(4, 96000)).to eq(960)
      expect(described_class.new(10.ms).unit).to eq(:seconds)
    end

    it 'converts node lengths per sample' do
      seconds = described_class.new(MB::Sound::ArrayInput.new(data: [Numo::SFloat[0.001, 0.002]]))
      expect(seconds.samples(2, 48000)).to all_be_within(1e-4).of_array([48, 96])
      samples = described_class.new(MB::Sound::ArrayInput.new(data: [Numo::SFloat[3, 4]]).samples)
      expect(samples.samples(2, 96000).to_a).to eq([3, 4])
      expect(samples).to be_node
    end

    it 'follows the tempo for Durations' do
      src = described_class.new(1.n4)
      expect(src.tempo_node).to be_a(MB::Sound::Sequence::TempoNode)
      expect(src.max_samples(48000)).to be > 24000
    end
  end
end
