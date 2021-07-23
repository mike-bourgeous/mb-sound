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
      input = Numo::SFloat.zeros(20)
      input[0] = 1

      expected = Numo::SFloat.zeros(20)
      expected[5] = 1

      expect(shortbuf.process(input)).to eq(expected)
      expect(input).not_to eq(expected)
    end

    it 'can process an oversized buffer in-place' do
      input = Numo::SFloat.zeros(20).inplace!
      input[0] = 1

      expected = Numo::SFloat.zeros(20)
      expected[5] = 1

      expect(shortbuf.process(input).object_id).to eq(input.object_id)
      expect(input).to eq(expected)
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
