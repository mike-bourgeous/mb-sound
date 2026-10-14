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

  describe '.const_missing' do
    it 'makes Notes from note names' do
      expect(MB::Sound::C4).to be_a(MB::Sound::Note)
      expect(MB::Sound::C4.number).to eq(60)
      expect(MB::Sound::Fs3.number).to eq(54)
      expect(MB::Sound::Bb2.number).to eq(46)
      expect(MB::Sound.const_missing(:'A4+12.5').detuned_number).to eq(69.125)
    end

    # fixes-12: a typo'd constant in a song script said "Invalid note name
    # format TV_BARS" (the NameError's cause)
    it 'raises a plain NameError with suggestions for names that are not notes' do
      error = nil
      begin
        MB::Sound::SPEED_OF_SOND
      rescue NameError => e
        error = e
      end

      expect(error).to be_a(NameError)
      expect(error.name).to eq(:SPEED_OF_SOND)
      expect(error.cause).to be_nil
      expect(error.detailed_message(highlight: false)).to include('Did you mean?').and include('MB::Sound::SPEED_OF_SOUND')
      expect(error.full_message(highlight: false)).not_to match(/note name/i)
    end

    it 'raises NameError for names shaped almost like notes' do
      # (not TV_BARS itself: bin/songs/tunnel_vision.rb defines it, and
      # tunnel_vision_spec loads it into the same process in some orders)
      [:H4, :C10, :Cx4, :TV_BARZ, :Q3].each do |name|
        expect { MB::Sound.const_get(name) }.to raise_error(NameError) { |e| expect(e.cause).to be_nil }
      end
    end
  end
end
