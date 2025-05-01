RSpec.describe(MB::Sound::Filter::Delay) do
  let(:shortbuf) {
    MB::Sound::Filter::Delay.new(delay: 5, sample_rate: 1, buffer_size: 10)
  }

  let(:midbuf) {
    MB::Sound::Filter::Delay.new(delay: 10, sample_rate: 1, buffer_size: 171)
  }

  describe '#initialize' do
    it 'can calculate delay in samples based on sample rate' do
      d = MB::Sound::Filter::Delay.new(delay: 0.75, sample_rate: 4, buffer_size: 17)
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

        it 'can trigger buffer growth without error' do
          shortbuf.delay = 5
          shortbuf.reset_delay

          # This should wrap around the write pointer but not the read pointer
          expect(shortbuf.process(Numo::SFloat.zeros(11))).to eq(Numo::SFloat.zeros(11))
          expect(shortbuf.write_offset).to be < shortbuf.read_offset

          shortbuf.delay = 25
          shortbuf.reset_delay
          shortbuf.process(Numo::SFloat.zeros(1))

          expect(shortbuf.write_offset).to be < shortbuf.read_offset
          expect((shortbuf.write_offset - shortbuf.read_offset) % shortbuf.buffer_size).to eq(25)
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
end
