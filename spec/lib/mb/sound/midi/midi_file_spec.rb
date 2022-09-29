RSpec.describe(MB::Sound::MIDI::MIDIFile) do
  let(:seq) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid') }

  it 'can be constructed' do
    expect { seq }.not_to raise_error
    expect(seq.empty?).to eq(false)
  end

  describe '#duration' do
    it 'returns the timestamp of the final event' do
      expect(seq.duration.round(3)).to eq(6.857)
    end
  end

  describe '#seek' do
    it 'changes the index' do
      expect(seq.index).to eq(0)
      expect(seq.empty?).to eq(false)

      seq.seek(60000)

      expect(seq.empty?).to eq(true)
      expect(seq.index).to be > 0
    end
  end
end
