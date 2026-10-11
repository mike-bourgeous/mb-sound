require 'fileutils'

RSpec.describe MB::Sound do
  describe 'adsr' do
    it 'creates an envelope' do
      expect(MB::Sound.adsr()).to be_a(MB::Sound::Envelope)
    end

    it 'applies given envelope parameters' do
      env = MB::Sound.adsr(0.1, 0.2, 0.3, 0.4)
      expect(env).to be_a(MB::Sound::Envelope)
      expect(env.attack_time).to eq(0.1)
      expect(env.decay_time).to eq(0.2)
      expect(env.sustain_level).to eq(0.3)
      expect(env.release_time).to eq(0.4)
    end
  end
end
