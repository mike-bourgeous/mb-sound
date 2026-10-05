RSpec.describe(MB::Sound::MIDI::NoteList) do
  let(:ev) { MB::Sound::MIDI::Event }

  def notes(*events, end_time: 2)
    described_class.notes(MIDIListSource.new(events), end_time: end_time).map { |n|
      n.values_at(:channel, :number, :on_velocity, :off_velocity, :on_time, :off_time, :sustain_time)
    }
  end

  it 'pairs notes, with a pedal release time later than the key release' do
    expect(notes(ev.cc_raw(64, 127), ev.note_on(60, 100 / 127.0, time: 1/10r), ev.note_off(60, 0, time: 2/10r), ev.cc_raw(64, 0, time: 4/10r))).to eq([
      [0, 60, 100, 0, 0.1, 0.2, 0.4],
    ])
  end

  it 'ends a note when its key is struck again, also under the pedal' do
    expect(notes(ev.note_on(60, 1.0), ev.note_on(60, 1.0, time: 1/10r), ev.note_off(60, time: 2/10r), ev.note_off(60, time: 3/10r))).to eq([
      [0, 60, 127, 127, 0.0, 0.1, 0.1], [0, 60, 127, 64, 0.1, 0.2, 0.2],
    ])
    expect(notes(ev.cc_raw(64, 127), ev.note_on(60, 1.0), ev.note_off(60, 0, time: 1/10r), ev.note_on(60, 1.0, time: 2/10r), ev.note_off(60, 0, time: 3/10r), ev.cc_raw(64, 0, time: 5/10r))).to eq([
      [0, 60, 127, 0, 0.0, 0.1, 0.2], [0, 60, 127, 0, 0.2, 0.3, 0.5],
    ])
  end

  it 'holds notes with sostenuto, keeps raw velocities under the soft pedal, and keeps channels apart' do
    expect(notes(
      ev.cc_raw(67, 127), ev.note_on(60, 1.0), ev.cc_raw(66, 127, time: 1/10r), ev.note_off(60, 0, time: 2/10r),
      ev.note_on(62, 1.0, channel: 1, time: 2/10r), ev.note_off(62, 0, channel: 1, time: 3/10r), ev.cc_raw(66, 0, time: 4/10r)
    )).to eq([[0, 60, 127, 0, 0.0, 0.2, 0.4], [1, 62, 127, 0, 0.2, 0.3, 0.3]])
  end

  it 'ends notes held down at the end at end_time, and pedal-held ones at the last event' do
    expect(notes(ev.note_on(60, 1.0), end_time: 3)).to eq([[0, 60, 127, 127, 0.0, 3.0, 3.0]])
    expect(notes(ev.cc_raw(64, 127), ev.note_on(60, 1.0), ev.note_off(60, 0, time: 1/10r), ev.cc_raw(7, 100, time: 1/2r))).to eq([
      [0, 60, 127, 0, 0.0, 0.1, 0.5],
    ])
  end

  it 'gives min/median/max stats of notes or numbers' do
    expect(described_class.stats([])).to eq([64, 64, 64])
    expect(described_class.stats([3, 1, 2])).to eq([1, 2, 3])
    expect(described_class.stats([{ number: 5, channel: 0 }, { number: 9, channel: 1 }], channel: 1)).to eq([9, 9, 9])
  end
end
