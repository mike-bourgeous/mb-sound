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
      notes_end = m.notes.map { |n| n[:sustain_time] || n[:off_time] }.compact.max

      expect(m.music_end).to be >= notes_end
      expect(m.music_end).to be < m.duration
    end
  end

  describe '#find_index' do
    it 'returns the index of the first event at or after a time' do
      expect(seq.find_index(0)).to eq(0)
      expect(seq.find_index(4.25)).to eq(24)
      expect(seq.find_index(60000)).to eq(seq.count)
    end
  end

  describe '#fractional_index' do
    it 'returns index 0 for time 0 on the test MIDI file' do
      expect(seq.fractional_index(0)).to eq(0)
    end

    it 'returns the expected index for a time within the MIDI file' do
      # This depends on the test midi file remaining unchanged
      expect(seq.fractional_index(4.25).round(4)).to eq(23.4792)
    end

    it 'returns the final event index when given the MIDI file duration' do
      expect(seq.fractional_index(seq.duration + 0.000001).round(4)).to eq(seq.count - 1)
    end

    it 'extrapolates by 0.25 indices per second before the start' do
      expect(seq.fractional_index(-5).round(4)).to eq(-1.25)
    end

    it 'extrapolates by 0.25 indices per second after the end' do
      expect(seq.fractional_index(seq.duration + 5).round(4)).to eq(seq.count - 1 + 1.25)
    end

    it 'returns monotonically increasing values when called with regular times' do
      indices = MB::M.array_to_narray(
        (-5.0..7.0).step(0.01).map { |t|
          seq.fractional_index(t)
        }
      )
      expect(indices.diff.min).to be >= 0
      expect(indices.diff.max).to be > 0
    end
  end

  describe '#notes' do
    it 'returns an empty list for a MIDI file with no notes' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/key_signature.mid')
      expect(m.notes.length).to eq(0)
    end

    it 'returns some notes for a MIDI file with notes' do
      expect(seq.notes.length).to be > 0
      expect(seq.notes[0]).to include(:number)
    end

    it 'returns min/mid/max for a MIDI file with all notes once' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/all_notes.mid')
      expect(m.notes.length).to eq(128)
      expect(m.notes[0][:number]).to eq(0)
      expect(m.notes[-1][:number]).to eq(127)
    end

    pending 'returns sustain pedal release times with notes'
  end

  describe '#note_stats' do
    it 'returns 64 for a MIDI file with no notes' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/empty.mid')
      expect(m.note_stats).to eq([64, 64, 64])
    end

    it 'returns min/mid/max for a MIDI file with all notes once' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/all_notes.mid')
      expect(m.note_stats).to eq([0, 64, 127])
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

  pending '#track_notes'
  pending '#tracks'
  pending '#read'
end
