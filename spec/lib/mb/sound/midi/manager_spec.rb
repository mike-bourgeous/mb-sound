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

  describe '#cc_names' do
    it 'returns an empty Hash if there are no CC parameters' do
      expect(manager.cc_names).to eq({})
    end

    it 'returns expected names for CC parameters, omitting nil descriptions' do
      manager.on_cc(1, description: 'Mod') { }
      manager.on_cc(1) { }
      manager.on_cc(1, description: 'Wheel') { }
      manager.on_cc(2) { }
      manager.on_cc(3, description: 'Three') { }

      expect(manager.cc_names).to eq({
        1 => 'Mod; Wheel',
        3 => 'Three',
      })
    end

    it 'returns expected names for CC thresholds, omitting nil descriptions' do
      manager.on_cc_threshold(1, 75) { }
      manager.on_cc_threshold(1, 76, description: 'Seventy Six') { }
      manager.on_cc_threshold(2, 77)
      manager.on_cc_threshold(3, 78, description: 'Nil at end') { }
      manager.on_cc_threshold(3, 68) { }
      manager.on_cc_threshold(4, 52, description: 'Nil in middle') { }
      manager.on_cc_threshold(4, 53) { }
      manager.on_cc_threshold(4, 54, description: 'No problem') { }

      expect(manager.cc_names).to eq({
        1 => 'Seventy Six',
        3 => 'Nil at end',
        4 => 'Nil in middle; No problem',
      })
    end

    it 'returns expected names for a mix of CC parameters and thresholds' do
      manager.on_cc_threshold(1, 75) { }
      manager.on_cc_threshold(1, 76, description: 'Seventy Six') { }
      manager.on_cc_threshold(2, 77)
      manager.on_cc_threshold(3, 78, description: 'Nil at end') { }
      manager.on_cc_threshold(3, 68) { }
      manager.on_cc_threshold(4, 52, description: 'Nil in middle') { }
      manager.on_cc_threshold(4, 53) { }
      manager.on_cc_threshold(4, 54, description: 'No problem') { }
      manager.on_cc_threshold(5, 55, description: 'Five threshold') { }
      manager.on_cc_threshold(6, 56) { }
      manager.on_cc_threshold(76, 23, description: 'Threshold 76') { }

      manager.on_cc(1, description: 'Mod') { }
      manager.on_cc(1) { }
      manager.on_cc(1, description: 'Wheel') { }
      manager.on_cc(2, description: 'Two') { }
      manager.on_cc(3, description: 'Three') { }
      manager.on_cc(3) { }
      manager.on_cc(5) { }
      manager.on_cc(6) { }
      manager.on_cc(75) { }
      manager.on_cc(75, description: 'Seventy five') { }

      expect(manager.cc_names).to eq({
        1 => 'Mod; Wheel; Seventy Six', # both CC and CC threshold
        2 => 'Two', # both but threshold is nil
        3 => 'Three; Nil at end', # both with some nils
        4 => 'Nil in middle; No problem', # only CC threshold
        5 => 'Five threshold', # both but param is nil
        # 6 omitted because both are nil
        75 => 'Seventy five',
        76 => 'Threshold 76',
      })
    end
  end
end
