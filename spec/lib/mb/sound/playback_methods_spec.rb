RSpec.describe(MB::Sound::PlaybackMethods) do
  before(:each) do
    ENV['OUTPUT_TYPE'] = 'null'
  end
  
  after(:each) do
    ENV.delete('OUTPUT_TYPE')
  end

  describe '#play' do
    it 'can play a sound file' do
      expect(Kernel).to receive(:sleep).at_least(10).times
      expect_any_instance_of(MB::Sound::NullOutput).to receive(:write).at_least(10).times.and_call_original
      expect(MB::Sound).to receive(:puts).with(/Playing/)

      MB::Sound.play('sounds/synth0.flac', plot: false)
    end

    pending 'can play a Tone'
    pending 'can play a Numo::NArray'
    pending 'can play an array of sounds for separate channels'
  end
end
