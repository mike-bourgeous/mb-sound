RSpec.describe(MB::Sound::MIDI::MIDIFile) do
  let(:seq) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid') }

  it 'can be constructed and can load a MIDI file' do
    expect { seq }.not_to raise_error
    expect(seq.empty?).to eq(false)
  end

  describe '#duration' do
    it 'returns the timestamp of the final event' do
      expect(seq.duration.round(3)).to eq(6.857)
    end
  end

  describe '#music_end' do
    it 'returns the time of the last channel event, before trailing meta events' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/c_major.mid')
      notes_end = MB::Sound::MIDI::FileSource.new(m).notes.map { |n| n[:sustain_time] || n[:off_time] }.compact.max

      expect(m.music_end).to be >= notes_end
      expect(m.music_end).to be < m.duration
    end
  end

  describe '#track_note_stats' do
    it 'returns all 64s for a track with no notes' do
      expect(seq.track_note_stats(0)).to eq([64, 64, 64])
    end

    it 'returns note stats for a track with notes' do
      expect(seq.track_note_stats(1)).to eq([68, 75, 80])
    end
  end

  describe '#tracks' do
    it 'describes each track with note stats from its note-ons' do
      t = MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid', merge_tracks: false).tracks
      expect(t.map { |i| i[:index] }).to eq((0...t.length).to_a)
      expect(t[1]).to include(min_note: 68, mid_note: 75, max_note: 80)
      expect(t[1][:num_notes]).to be > 0
    end
  end

  pending '#read'
end
