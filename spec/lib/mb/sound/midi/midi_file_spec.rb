RSpec.describe(MB::Sound::MIDI::MIDIFile) do
  let(:clock) { MB::Sound::MIDI::MIDIFile::ConstantClock.new }
  let(:seq) { MB::Sound::MIDI::MIDIFile.new('spec/test_data/midi.mid', clock: clock) }

  it 'can be constructed and can load a MIDI file' do
    expect { seq }.not_to raise_error
    expect(seq.empty?).to eq(false)
  end

  describe '#duration' do
    it 'returns the timestamp of the final event' do
      expect(seq.duration.round(3)).to eq(6.857)
    end
  end

  describe '#seek' do
    it 'can seek to the end of the file' do
      expect(seq.index).to eq(0)
      expect(seq.empty?).to eq(false)

      seq.seek(60000)

      expect(seq.empty?).to eq(true)
      expect(seq.index).to be > 0
      expect(seq.index).to eq(seq.count)
    end

    it 'can seek to a specific time within the file' do
      seq.seek(4.25)
      expect(seq.index).to eq(24)
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

  pending '#read'
end
