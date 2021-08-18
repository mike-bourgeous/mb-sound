RSpec.describe(MB::Sound::MIDI::Manager) do
  let (:midi_file) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid') }
  let (:manager) { MB::Sound::MIDI::Manager.new(jack: nil, input: midi_file) }

  it 'can be constructed with a MIDIFile' do
    expect { manager }.not_to raise_error
  end

  describe '#update' do
    it 'does not raise an error' do
      expect { manager.update }.not_to raise_error
    end

    pending 'calls subscribed parameter callbacks'
  end
end
