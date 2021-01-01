RSpec.describe MB::Sound::Filter::FirstOrder do
  context 'lowpass1p' do
    it 'produces the expected coefficients for x=0.9' do
      fc = -Math.log(0.9) / (2.0 * Math::PI) * 48000
      filter = MB::Sound::Filter::FirstOrder.new(:lowpass1p, 48000, fc)
      expect(filter.coefficients.map { |c| c.round(5) }).to eq([0.1, 0.0, 0.0, -0.9, 0.0])
    end

    it 'produces the expected response for 500/48k' do
      filter = MB::Sound::Filter::FirstOrder.new(:lowpass1p, 48000, 500)
      expect(filter.response(0).abs.round(5)).to eq(1)
      expect(filter.response(Math::PI).abs.round(5)).to be < 0.1
    end
  end

  context 'highpass1p' do
    it 'produces the expected coefficients for x=0.9' do
      fc = -Math.log(0.9) / (2.0 * Math::PI) * 48000
      filter = MB::Sound::Filter::FirstOrder.new(:highpass1p, 48000, fc)
      expect(filter.coefficients.map { |c| c.round(5) }).to eq([0.95, -0.95, 0.0, -0.9, 0.0])
    end

    it 'produces the expected response for 500/48k' do
      filter = MB::Sound::Filter::FirstOrder.new(:highpass1p, 48000, 500)
      expect(filter.response(0).abs.round(5)).to be < 0.1
      expect(filter.response(Math::PI).abs.round(5)).to eq(1)
    end
  end

  context 'lowpass' do
    it 'has a response of 0.707 at the cutoff frequency' do
      f = MB::Sound::Filter::FirstOrder.new(:lowpass, 48000, 2000)
      expect(MB::Sound::M.sigfigs(f.response(2.0 * Math::PI * 2000 / 48000).abs, 6)).to eq(MB::Sound::M.sigfigs(0.5 ** 0.5, 6))

      f = MB::Sound::Filter::FirstOrder.new(:lowpass, 48000, 6000)
      expect(MB::Sound::M.sigfigs(f.response(2.0 * Math::PI * 6000 / 48000).abs, 6)).to eq(MB::Sound::M.sigfigs(0.5 ** 0.5, 6))
    end
  end

  context 'highpass' do
    it 'has a response of 0.707 at the cutoff frequency' do
      f = MB::Sound::Filter::FirstOrder.new(:highpass, 48000, 2000)
      expect(MB::Sound::M.sigfigs(f.response(2.0 * Math::PI * 2000 / 48000).abs, 6)).to eq(MB::Sound::M.sigfigs(0.5 ** 0.5, 6))

      f = MB::Sound::Filter::FirstOrder.new(:highpass, 48000, 6000)
      expect(MB::Sound::M.sigfigs(f.response(2.0 * Math::PI * 6000 / 48000).abs, 6)).to eq(MB::Sound::M.sigfigs(0.5 ** 0.5, 6))
    end
  end
end
