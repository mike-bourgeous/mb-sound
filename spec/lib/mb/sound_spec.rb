require 'fileutils'

RSpec.describe MB::Sound do
  describe '.apply_filter' do
    it 'reduces the amplitude of high frequencies more than low frequencies in lowpass mode' do
      low = MB::Sound.apply_filter(123.hz.at(0.1), frequency: 1000, quality: 0.5)
      low_gain = low[0].abs.max / 0.1

      high = MB::Sound.apply_filter(15000.hz.at(0.1), frequency: 1000, quality: 0.5)
      high_gain = high[0].abs.max / 0.1

      expect(low_gain).to be > high_gain
      expect(low_gain).to be > -1.db
      expect(high_gain).to be < -30.db
    end
  end

  describe 'adsr' do
    it 'creates an envelope' do
      expect(MB::Sound.adsr()).to be_a(MB::Sound::ADSREnvelope)
    end

    it 'applies given envelope parameters' do
      env = MB::Sound.adsr(0.1, 0.2, 0.3, 0.4)
      expect(env).to be_a(MB::Sound::ADSREnvelope)
      expect(env.attack_time).to eq(0.1)
      expect(env.decay_time).to eq(0.2)
      expect(env.sustain_level).to eq(0.3)
      expect(env.release_time).to eq(0.4)
    end
  end
end
