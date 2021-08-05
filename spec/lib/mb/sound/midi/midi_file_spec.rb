RSpec.describe(MB::Sound::MIDI::MIDIFile) do
  it 'can be constructed' do
    seq = nil
    expect { seq = MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid') }.not_to raise_error
    expect(seq.empty?).to eq(false)
  end
end
