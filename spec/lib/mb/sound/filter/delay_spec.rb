RSpec.describe(MB::Sound::Filter::Delay) do
  let(:shortbuf) {
    MB::Sound::Filter::Delay.new(delay: 5, rate: 1, buffer_size: 10)
  }

  let(:midbuf) {
    MB::Sound::Filter::Delay.new(delay: 10, rate: 1, buffer_size: 171)
  }

  describe '#initialize' do
    it 'can calculate delay in samples based on sample rate' do
      d = MB::Sound::Filter::Delay.new(delay: 0.75, rate: 4, buffer_size: 17)
      expect(d.delay_samples).to eq(3)
    end
  end

  it 'smooths the delay when smoothing is enabled' do
    shortbuf.delay = 0
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[0,0,0,1,3,4,6,7,9])

    # Using 10 instead of 9 in input to ensure that the 9 in the output is from the previous buffer
    shortbuf.delay = 5
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,10,13,17])).to eq(Numo::SFloat[9,1,1,2,2,3,3,4,4,5,6])
  end

  it 'does not smooth the delay when smoothing is disabled' do
    shortbuf.delay = 0
    shortbuf.smoothing = false
    expect(shortbuf.process(Numo::SFloat[1,2,3,4,5,6,7,8,9])).to eq(Numo::SFloat[1,2,3,4,5,6,7,8,9])
  end

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
