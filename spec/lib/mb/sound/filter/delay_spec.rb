RSpec.describe(MB::Sound::Filter::Delay, :aggregate_failures) do
  # Linear interpolation, so smoothing glides give round numbers
  let(:shortbuf) {
    MB::Sound::Filter::Delay.new(delay: 5, sample_rate: 1, delay_buffer_size: 10, interpolation: :linear)
  }

  let(:midbuf) {
    MB::Sound::Filter::Delay.new(delay: 10, sample_rate: 1, delay_buffer_size: 171, interpolation: :linear)
  }

  describe '#initialize' do
    it 'can calculate delay in samples based on sample rate' do
      d = MB::Sound::Filter::Delay.new(delay: 0.75, sample_rate: 4, delay_buffer_size: 17)
      expect(d.delay_samples).to eq(3)
    end
  end

  it 'can be created by DSL methods' do
    expect(100.hz.delay(seconds: 0.01).base_filter).to be_a(MB::Sound::Filter::Delay)
    expect(100.hz.delay(samples: 5).base_filter).to be_a(MB::Sound::Filter::Delay)
  end

  it 'smooths the delay when smoothing is enabled' do
    shortbuf.delay = 0
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[0,0,0,1,2.5,4,5.5,7,8.5])

    # Using 13 instead of 9 in input to ensure that the 9 in the output is from the previous buffer
    shortbuf.delay = 5
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,13,17,24])).to eq(Numo::SFloat[9,5,1,1.5,2,2.5,3,3.5,4,5,6])
  end

  describe '#smoothing=' do
    it 'can change the delay smoothing rate' do
      shortbuf.smoothing = 0.25

      shortbuf.delay = 0
      expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[0,0,0,0,1.25,2.5,3.75,5,6.25])

      shortbuf.delay = 5
      expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,13,17,24])).to eq(Numo::SFloat[7,7.75,8.5,7,1,1.75,2.5,3.25,4,5,6])
    end

    it 'accepts a filter directly' do
      shortbuf.smoothing = MB::Sound::Filter::LinearFollower.new(sample_rate: 1, max_rise: 1, max_fall: 1)
      shortbuf.delay = 0
      expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[0,0,1,3,5,6,7,8,9])
    end
  end

  it 'does not smooth the delay when smoothing is disabled' do
    shortbuf.delay = 0
    shortbuf.smoothing = false
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[1,2,3,4,5,6,7,8,9])
  end

  describe 'min_, max_, and last_delay_samples' do
    it 'returns the correct range of values from a delay buffer' do
      n = 100.hz.delay(samples: 81.hz.triangle.at(10..20), smoothing: false)
      n.sample(1000)
      d = n.base_filter
      expect(d.min_delay_samples.round(1)).to eq(10)
      expect(d.max_delay_samples.round(1)).to eq(20)
      expect(d.last_delay_samples.round(1)).to be_between(11, 19)
    end
  end

  pending '#buffer'

  [false, true].each do |smoothing|
    context "when smoothing is #{smoothing}" do
      before(:each) do
        shortbuf.smoothing = smoothing
        midbuf.smoothing = smoothing
      end

      describe '#delay=' do
        it 'can change the delay' do
          shortbuf.delay = 0
          shortbuf.reset_delay
          expect(shortbuf.process(Numo::SFloat[1,2,3])).to eq(Numo::SFloat[1,2,3])
          shortbuf.delay = 3
          shortbuf.reset_delay
          expect(shortbuf.process(Numo::SFloat[4,5,6])).to eq(Numo::SFloat[1,2,3])
          expect(shortbuf.process(Numo::SFloat[-2,1,2])).to eq(Numo::SFloat[4,5,6])
          expect(shortbuf.process(Numo::SFloat.zeros(5))).to eq(Numo::SFloat[-2,1,2,0,0])
        end

        it 'keeps stored audio when a longer delay grows the buffer' do
          ramp = Numo::SFloat.new(40).seq + 1
          shortbuf.delay = 5
          shortbuf.reset_delay
          expect(shortbuf.process(ramp[0...20])).to eq(MB::M.shr(ramp[0...20], 5))

          # The 10-sample buffer grew for the 20-sample block, keeping all
          # of it, so a longer delay reads samples written before growing
          shortbuf.delay = 15
          shortbuf.reset_delay
          expect(shortbuf.process(ramp[20...30])).to eq(ramp[5...15])
          expect(shortbuf.delay_buffer_size).to be >= 25
        end

        it 'accepts a sample source/graph node' do
          data = Numo::SFloat[1,2,3,4,5,6,7,8]

          delay_source = 0.5.hz.square.at_rate(1).at(1..2)
          expect(delay_source).to receive(:sample).with(8).and_call_original

          shortbuf.delay = delay_source

          result = shortbuf.process(data)
          expect(result.length).to eq(8)
          expect(result).not_to eq(Numo::SFloat.zeros(8))
          expect(result).not_to eq(data)
        end
      end

      describe '#process' do
        it 'returns the original input if the delay is zero' do
          midbuf.delay_samples = 0
          midbuf.reset
          expect(midbuf.process(Numo::SFloat[1,2,3])).to eq(Numo::SFloat[1,2,3])
        end

        it 'can process an oversized buffer in smaller chunks with a non-inplace input' do
          input = Numo::SFloat.zeros(20).rand(-1, 1)
          expected = MB::M.shr(input, 5)

          expect(shortbuf.process(input)).to eq(expected)
          expect(input).not_to eq(expected)
        end

        it 'can process an oversized buffer in-place' do
          input = Numo::SFloat.zeros(20).rand(-1, 1).inplace!
          expected = MB::M.shr(input, 5)

          result = shortbuf.process(input)
          expect(result).to eq(expected)
          expect(input).to eq(expected)
          expect(result.object_id).to eq(input.object_id)
        end

        it 'can process relatively prime lengths with wraparound' do
          input = Numo::SFloat.zeros(128).rand(-1, 1)
          expected = MB::M.ror(input, 10)

          expect(midbuf.process(input)).to eq(MB::M.shr(input, 10))
          expect(midbuf.process(input)).to eq(expected)
          expect(midbuf.process(input)).to eq(expected)
          expect(midbuf.process(input)).to eq(expected)
          expect(midbuf.process(input)).to eq(expected)
          expect(midbuf.process(Numo::SFloat.zeros(128))).to eq(MB::M.shl(input, 118))
        end
      end
    end
  end

  describe '#sample_rate=' do
    it 'can change sample rate' do
      a = 2.hz.at(1..2)
      b = 10.hz.lowpass
      c = MB::Sound::Filter::Delay.new(delay: a, smoothing: b)

      c.sample_rate = 5432

      expect(a.sample_rate).to eq(5432)
      expect(b.sample_rate).to eq(5432)
      expect(c.sample_rate).to eq(5432)
    end

    # A ramp input reads back as the delay in seconds: t - output
    def glide(delay, os, smoothing:)
      sig = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(48000).seq / 48000.0]).with_buffer(800).resample(mode: :libsamplerate_fastest)
      node = sig.delay(seconds: delay, smoothing: smoothing, interpolation: :linear).oversample(os)
      out = Numo::SFloat.zeros(0).concatenate(*Array.new(30) { node.sample(800).dup })
      Numo::SFloat.new(out.length).seq / 48000.0 - out
    end

    it 'keeps the smoothing rate in seconds per second when oversampled' do
      [1, 2, 4].each do |os|
        jump = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(48000).fill(0.03).tap { |d| d[0...4800] = 0.01 }])
          .with_buffer(800).resample(mode: :libsamplerate_fastest)

        # 0.1 s/s smoothing glides 0.02 s in 0.2 s
        d = glide(jump, os, smoothing: 0.1)
        expect(d[4800 + 4800]).to be_within(2e-4).of(0.02), "at #{os}x"
        expect(d[4800 + 9600 + 480]).to be_within(2e-4).of(0.03), "at #{os}x"
      end
    end

    it 'starts a numeric delay at its time when oversampled' do
      [1, 2, 4].each do |os|
        d = glide(0.02, os, smoothing: 0.01)
        expect(d[2400..4800].to_a).to all(be_within(2e-4).of(0.02)), "at #{os}x"
      end
    end
  end

  describe 'interpolation' do
    it 'defaults to band-limited sinc' do
      expect(MB::Sound::Filter::Delay.new.interpolation).to eq(:sinc)
      expect(100.hz.delay(0.01).base_filter.interpolation).to eq(:sinc)
      expect(100.hz.delay(0.01, interpolation: :cubic).base_filter.interpolation).to eq(:cubic)
      expect { MB::Sound::Filter::Delay.new(interpolation: :fancy) }.to raise_error(ArgumentError, /interpolation/)
    end

    MB::Sound::DelayLine::INTERPOLATION.each_key do |mode|
      it "reads whole-sample delays exactly, including jumps (#{mode})" do
        d = MB::Sound::Filter::Delay.new(delay: 0, sample_rate: 1, smoothing: false, interpolation: mode)
        expect(d.process(Numo::SFloat[1, 2, 3])).to eq(Numo::SFloat[1, 2, 3])
        d.delay = 3
        expect(d.process(Numo::SFloat[4, 5, 6])).to eq(Numo::SFloat[1, 2, 3])
        expect(d.process(Numo::SFloat[-2, 1, 2])).to eq(Numo::SFloat[4, 5, 6])
      end
    end
  end

  describe 'wet, dry, and feedback' do
    let(:impulse) { Numo::SFloat.zeros(12).tap { |d| d[0] = 1 } }

    it 'applies dry and wet levels on every path' do
      [
        { smoothing: false },
        { smoothing: true },
        { smoothing: false, feedback: 0.5 },
      ].each do |opts|
        d = MB::Sound::Filter::Delay.new(delay: 4, sample_rate: 1, delay_buffer_size: 20, wet: 0.5, dry: 0.25, **opts)
        out = d.process(impulse.dup).to_a
        expect(out[0]).to eq(0.25), opts.inspect
        expect(out[4]).to eq(0.5), opts.inspect
        expect(out[8]).to eq(opts[:feedback] ? 0.25 : 0), opts.inspect
      end
    end

    it 'feeds back the delayed signal' do
      d = MB::Sound::Filter::Delay.new(delay: 4, sample_rate: 1, delay_buffer_size: 20, smoothing: false, feedback: -0.5)
      expect(d.process(impulse).to_a).to eq([0, 0, 0, 0, 1, 0, 0, 0, -0.5, 0, 0, 0])
    end

    it 'reads feedback, wet, and dry from graph nodes' do
      fb = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 0, 0]], sample_rate: 1)
      wet = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(12) * 2], sample_rate: 1)
      dry = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(12).seq / 10], sample_rate: 1)
      d = MB::Sound::Filter::Delay.new(delay: 4, sample_rate: 1, delay_buffer_size: 20, smoothing: false, feedback: fb, wet: wet, dry: dry)

      expect(d.sources.keys).to include(:feedback, :wet, :dry)
      # The echo at 4 is fed back at 0.5 (the gain at sample 4), so it
      # repeats at 8; wet doubles both, and dry is 0 at the impulse
      expect(d.process(impulse).to_a).to eq([0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0])
    end

    it 'ends when a level node ends' do
      wet = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(5)], sample_rate: 1)
      d = MB::Sound::Filter::Delay.new(delay: 1, sample_rate: 1, smoothing: false, wet: wet)
      expect(d.process(impulse).length).to eq(5)
      expect(d.process(impulse)).to eq(nil)
    end

    it 'follows a graph DSL LFO for feedback' do
      graph = 100.hz.delay(0.01, feedback: 0.2.hz.lfo.at(0.2..0.8), dry: 1)
      expect(graph.graph).to include(an_instance_of(MB::Sound::Tone).and(have_attributes(frequency: 0.2)))
      expect(graph.sample(4800).abs.max).to be > 0.5
    end
  end
end
