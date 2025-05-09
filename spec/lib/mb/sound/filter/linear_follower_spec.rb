RSpec.describe(MB::Sound::Filter::LinearFollower) do
  describe '#initialize' do
    it 'calculates a per-sample rate from the per-second rates' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 100, max_rise: 1, max_fall: 1, absolute: false)
      expect(lf.max_rise).to eq(0.01)
      expect(lf.max_fall).to eq(0.01)
      expect(lf.absolute).to eq(false)
      expect(lf.sample_rate).to eq(100)

      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: 0.5, max_fall: 0.5, absolute: true)
      expect(lf.max_rise).to eq(0.05)
      expect(lf.max_fall).to eq(0.05)
      expect(lf.absolute).to eq(true)
      expect(lf.sample_rate).to eq(10)
    end

    it 'allows rise and fall rates to be nil' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: nil, max_fall: nil)
      expect(lf.max_rise).to eq(nil)
      expect(lf.max_fall).to eq(nil)
    end
  end

  describe '#process' do
    it 'does not limit rise when max_rise is nil' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: nil, max_fall: 1)
      data = Numo::SFloat[0, 100, 0, 0, 0, 0, 0, 0, 0, 0]
      expected = Numo::SFloat[0, 100, 99.9, 99.8, 99.7, 99.6, 99.5, 99.4, 99.3, 99.2]

      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end

    it 'does not limit fall when max_fall is nil' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: 10, max_fall: nil)
      data = Numo::SFloat[0, 100, 100, 100, 0, 0, 0, 0, -150, 0]
      expected = Numo::SFloat[0, 1, 2, 3, 0, 0, 0, 0, -150, -149]

      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end

    it 'limits both rise and fall when both are set' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: 50, max_fall: 50)
      data = Numo::SFloat[0, 100, 100, 100, 0, 0, 0, 0, -150, 0]
      expected = Numo::SFloat[0, 5, 10, 15, 10, 5, 0, 0, -5, 0]

      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end

    it 'limits neither rise nor fall when both are nil' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: 50, max_fall: 50)
      data = Numo::SFloat[0, 100, 100, 100, 0, 0, 0, 0, -150, 0]
      expected = Numo::SFloat[0, 5, 10, 15, 10, 5, 0, 0, -5, 0]

      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end

    it 'uses the absolute value if #absolute is true' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 1, max_rise: 5, max_fall: 5, absolute: true)
      data = Numo::SFloat[0, 100, 100, 100, -120, -120, 0, 0, -150, 0]
      expected = Numo::SFloat[0, 5, 10, 15, 20, 25, 20, 15, 20, 15]

      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end
  end

  describe '#reset' do
    it 'sets the filters output value directly' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 1, max_rise: 1, max_fall: 2)
      data = Numo::SFloat[0, 0, 0, 0, 100]
      expected = Numo::SFloat[48, 46, 44, 42, 43]

      lf.reset(50)
      expect(MB::M.round(lf.process(data), 6)).to eq(expected)
    end
  end
end
