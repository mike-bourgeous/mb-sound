RSpec.describe(MB::Sound::MIDI::Parameter) do
  it 'can be constructed with a control change event' do
    MB::Sound::MIDI::Parameter.new(message: MIDIMessage::ControlChange.new(-1, 1, 0))
  end

  it 'can be constructed with a note-on event' do
    MB::Sound::MIDI::Parameter.new(message: 440.hz.to_midi)
  end

  it 'can be constructed with a note-off event' do
    MB::Sound::MIDI::Parameter.new(message: MIDIMessage::NoteOff.new(5, 3, 1))
  end

  it 'can be constructed with a pitch bend event' do
    MB::Sound::MIDI::Parameter.new(message: MIDIMessage::PitchBend.new(-1, 0))
  end

  it 'can be constructed with a channel aftertouch event' do
    MB::Sound::MIDI::Parameter.new(message: MIDIMessage::ChannelAftertouch.new(-1, 0))
  end

  it 'can be constructed with a polyphonic aftertouch event' do
    MB::Sound::MIDI::Parameter.new(message: MIDIMessage::PolyphonicAftertouch.new(-1, 0, 0))
  end
end
