RSpec.describe(MB::Sound::MIDI::VoicePool) do
  let(:midi_file) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/all_notes.mid') }
  let(:manager) { MB::Sound::MIDI::Manager.new(jack: nil, input: midi_file) }

  describe '#sample_rate=' do
    it 'passes sample rate through to GraphNode' do
      voices = Array.new(3) { 100.hz.square.filter(:lowpass, cutoff: 500, quality: 5).softclip }

      pool = MB::Sound::MIDI::VoicePool.new(manager, voices)

      pool.sample_rate = 12345

      expect(voices.map(&:sample_rate)).to eq([12345] * 3)
    end

    it 'passes sample rate through to Oscillator' do
      voices = Array.new(3) { 100.hz.square.at(1).oscillator }

      pool = MB::Sound::MIDI::VoicePool.new(manager, voices)

      pool.sample_rate = 12345

      expect(voices.map(&:sample_rate)).to eq([12345] * 3)
    end

    it 'passes sample rate through to MB::Sound::MIDI::Voice' do
      voices = Array.new(3) { MB::Sound::MIDI::Voice.new }

      pool = MB::Sound::MIDI::VoicePool.new(manager, voices)

      pool.sample_rate = 12345

      expect(voices.map(&:sample_rate)).to eq([12345] * 3)
    end
  end

  pending
end
