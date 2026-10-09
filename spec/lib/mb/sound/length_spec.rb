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

  describe 'everywhere a length of time is taken' do
    after { MB::Sound.rewind }

    # Total samples a node gives in +buffer+-sized reads until it ends
    def total(node, buffer = 100)
      n = 0
      while (d = node.sample(buffer))
        n += d.length
      end
      n
    end

    it 'until and silence' do
      expect(total(1.constant.until(480.samples))).to eq(480)
      expect(total(1.constant.until(10.ms))).to eq(480)
      expect(total(MB::Sound.silence(480.samples))).to eq(480)
      expect(total(MB::Sound.silence(10.ms))).to eq(480)
      expect(total(MB::Sound.silence(5.samples).tap { |s| s.sample_rate = 96000 })).to eq(5)
      expect(total(MB::Sound.silence(0.01).tap { |s| s.sample_rate = 96000 })).to eq(960)
    end

    it 'envelopes' do
      env = MB::Sound.adsr(20.ms, 480.samples, 0.5, 1.n16)
      expect(env.attack_time).to be_within(1e-12).of(0.02)
      expect(env.decay_time).to be_within(1e-12).of(0.01)
      expect(env.release_time).to be_within(1e-12).of(MB::Sound::Sequence.transport.seconds(1/16r))
    end

    it 'render seconds and bars, write lengths' do
      file = tmp_path('lengths.flac')
      MB::Sound.render(file, 1.constant, seconds: 4800.samples, gain: 1)
      expect(MB::Sound.read(file)[0].length).to eq(4800)
      MB::Sound.render(file, 1.constant, bars: 0.5.seconds, gain: 1, overwrite: true)
      expect(MB::Sound.read(file)[0].length).to eq(24000)
      MB::Sound.write(file, 1.constant, overwrite: true, max_length: 800.samples)
      expect(MB::Sound.read(file)[0].length).to eq(800)
    end

    it 'bar-counted and musical arguments' do
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      expect(MB::Sound::Sequence::Duration.bars(1.second, t.bar_length, transport: t)).to eq(1/2r)
      expect(MB::Sound::Sequence::Duration.whole_notes(0.5.seconds)).to eq(MB::Sound::Sequence.transport.whole_notes_per_second / 2)
    end

    it 'with_buffer, smooth, reverb predelay, and reverb decay' do
      expect(1.constant.with_buffer(1.ms).instance_variable_get(:@upstream_count)).to eq(48)
      expect(1.constant.smooth(60.samples)).to be_a(MB::Sound::GraphNode)
      expect(1.constant.smooth(100.ms)).to be_a(MB::Sound::GraphNode)
      expect { 1.constant.reverb(:hall, predelay: 10.ms).sample(10) }.not_to raise_error
      expect { 1.constant.reverb(decay: 1.second, extra_time: 100.ms).sample(10) }.not_to raise_error
      expect(1.constant.reverb(decay: 1500.ms).parameters[:decay]).to eq(1.5)
    end

    it 'HaasPan delays' do
      expect(MB::Sound::HaasPan.new(delay: -24.samples).left_delay_samples).to eq(24)
      expect(MB::Sound::HaasPan.new(delay: 1.ms).right_delay_samples).to eq(48)
    end
  end
end
