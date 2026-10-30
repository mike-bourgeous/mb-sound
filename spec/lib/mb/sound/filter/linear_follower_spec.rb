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
    it 'runs in C exactly as its Ruby mirror' do
      [Numo::SFloat, Numo::DFloat].each do |type|
        [[2000, 1500, false], [nil, 900, true], [3000, nil, false], [nil, nil, true], [0, 0, false]].each do |rise, fall, abs|
          data = type.new(3000).rand(-1, 1)
          data[100] = -0.0
          data[200...400] = 0.5
          data[1000...1100] = Float::NAN if type == Numo::DFloat
          c = MB::Sound::Filter::LinearFollower.new(sample_rate: 48000, max_rise: rise, max_fall: fall, absolute: abs)
          r = MB::Sound::Filter::LinearFollower.new(sample_rate: 48000, max_rise: rise, max_fall: fall, absolute: abs)
          c.reset(0.25)
          r.reset(0.25)
          a = SpecBuffers.join([0...7, 7...800, 800...3000].map { |range| c.process(data[range].dup) })
          b = SpecBuffers.join([0...7, 7...800, 800...3000].map { |range| r.process_ruby(data[range].dup) })
          expect(a.class).to eq(type)
          expect(a.to_binary).to eq(b.to_binary), "#{type} #{rise.inspect} #{fall.inspect} #{abs}"
          expect(c.peek.to_s).to eq(r.peek.to_s)
        end
      end
    end

    it 'processes in place only inplace data, and leaves frozen data alone' do
      lf = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: 1, max_fall: 1)
      d = Numo::SFloat[0, 1, 1]
      out = lf.process(d)
      expect(out).not_to equal(d)
      expect(d).to eq(Numo::SFloat[0, 1, 1])

      d2 = Numo::SFloat[1, 1, 1].inplace
      expect(lf.process(d2)).to equal(d2)

      f = Numo::SFloat[3, 3].freeze
      expect(lf.process(f).frozen?).to eq(false)
    end

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

  describe '#sample_rate=' do
    let(:lf) { MB::Sound::Filter::LinearFollower.new(sample_rate: 1, max_rise: 1, max_fall: 2) }
    it 'keeps the rates per second, so rates per sample shrink at higher sample rates' do
      lf.sample_rate = 2
      expect(lf.sample_rate).to eq(2)
      expect(lf.max_rise).to be_within(1e-6).of(0.5)
      expect(lf.max_fall).to be_within(1e-6).of(1)
    end

    it 'is aliased to at_rate' do
      expect(lf.at_rate(0.5)).to equal(lf)
      expect(lf.sample_rate).to eq(0.5)
      expect(lf.max_rise).to be_within(1e-6).of(2)
      expect(lf.max_fall).to be_within(1e-6).of(4)
    end

    it 'allows unlimited directions' do
      f = MB::Sound::Filter::LinearFollower.new(sample_rate: 10, max_rise: nil, max_fall: 1)
      f.sample_rate = 20
      expect(f.max_rise).to eq(nil)
      expect(f.max_fall).to be_within(1e-6).of(0.05)
    end

    it 'takes the same time to rise in an oversampled graph' do
      [1, 2, 4].each do |os|
        node = 1.constant.clip_rate(2).oversample(os)
        out = node.sample(4800)
        expect(out[-1]).to be_within(1e-3).of(0.2)
      end
    end
  end
end
