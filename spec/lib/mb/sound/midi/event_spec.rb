RSpec.describe(MB::Sound::MIDI::Event) do
  describe '.parse' do
    it 'parses a note-on with normalized velocity and keeps the raw values' do
      e = MB::Sound::MIDI::Event.parse("\x93\x3c\x7f", time: 1.5)
      expect(e.type).to eq(:note_on)
      expect(e.channel).to eq(3)
      expect(e.note).to eq(60)
      expect(e.velocity).to eq(1.0)
      expect(e.value).to eq(1.0)
      expect(e.raw).to eq(127)
      expect(e.bytes).to eq("\x93\x3c\x7f".b)
      expect(e.bytes).to be_frozen
      expect(e.time).to eq(3/2r)
      expect(e.time).to be_a(Rational)
    end

    it 'turns a note-on with velocity 0 into a note-off with release velocity 64' do
      e = MB::Sound::MIDI::Event.parse([0x90, 60, 0])
      expect(e.type).to eq(:note_off)
      expect(e.raw).to eq(64)
      expect(e.velocity).to eq(64 / 127.0)
      expect(e.bytes).to eq([0x90, 60, 0].pack('C*'))
    end

    it 'parses a note-off with its release velocity' do
      e = MB::Sound::MIDI::Event.parse([0x81, 61, 10])
      expect(e).to have_attributes(type: :note_off, channel: 1, note: 61, raw: 10)
      expect(e.velocity).to be_within(1e-12).of(10 / 127.0)
    end

    it 'parses control changes to 0..1' do
      e = MB::Sound::MIDI::Event.parse([0xb5, 1, 127])
      expect(e).to have_attributes(type: :cc, channel: 5, note: 1, index: 1, value: 1.0, raw: 127, velocity: nil)
      expect(MB::Sound::MIDI::Event.parse([0xb0, 7, 0]).value).to eq(0)
      expect(e.cc?).to eq(true)
      expect(e.cc?(1)).to eq(true)
      expect(e.cc?(2)).to eq(false)
    end

    it 'parses pitch bend to -1..1 with 8192 at the center' do
      bend = ->(raw) { MB::Sound::MIDI::Event.parse([0xe2, raw & 0x7f, raw >> 7]) }
      expect(bend.(8192).value).to eq(0)
      expect(bend.(0).value).to eq(-1)
      expect(bend.(16383).value).to eq(1)
      expect(bend.(4096).value).to eq(-0.5)
      expect(bend.(16383)).to have_attributes(type: :bend, channel: 2, raw: 16383, note: nil)
    end

    it 'parses pressure and program changes' do
      expect(MB::Sound::MIDI::Event.parse([0xd1, 127])).to have_attributes(type: :channel_pressure, channel: 1, value: 1.0, raw: 127)
      expect(MB::Sound::MIDI::Event.parse([0xa1, 60, 0])).to have_attributes(type: :poly_pressure, note: 60, value: 0.0, raw: 0)
      expect(MB::Sound::MIDI::Event.parse([0xc4, 12])).to have_attributes(type: :program, channel: 4, value: 12, raw: 12)
    end

    it 'keeps channel mode messages as CCs with helpers' do
      sound_off, reset, notes_off, omni = [120, 121, 123, 125].map { |cc| MB::Sound::MIDI::Event.parse([0xb0, cc, 0]) }
      expect([sound_off, reset, notes_off, omni].map(&:type).uniq).to eq([:cc])
      expect(sound_off.all_sound_off?).to eq(true)
      expect(sound_off.all_notes_off?).to eq(false)
      expect(reset.reset_controllers?).to eq(true)
      expect(notes_off.all_notes_off?).to eq(true)
      expect(omni.all_notes_off?).to eq(true)
      expect(notes_off.channel_mode?).to eq(true)
      expect(MB::Sound::MIDI::Event.parse([0xb0, 64, 127]).channel_mode?).to eq(false)
    end

    it 'returns nil for an incomplete message' do
      expect(MB::Sound::MIDI::Event.parse([0x90, 60])).to eq(nil)
    end
  end

  describe '.parse_all' do
    it 'follows running status' do
      events = MB::Sound::MIDI::Event.parse_all([0x90, 60, 100, 64, 100, 60, 0], time: 2)
      expect(events.map(&:type)).to eq([:note_on, :note_on, :note_off])
      expect(events.map(&:note)).to eq([60, 64, 60])
      expect(events.map(&:time).uniq).to eq([2r])
    end

    it 'parses realtime messages inside other messages and sysex' do
      events = MB::Sound::MIDI::Event.parse_all([0x90, 60, 0xf8, 100, 0xf0, 1, 2, 3, 0xf7, 0xc0, 5])
      expect(events.map(&:type)).to eq([:system, :note_on, :sysex, :program])
      expect(events[0].raw).to eq(0xf8)
      expect(events[1].note).to eq(60)
      expect(events[2].bytes).to eq([0xf0, 1, 2, 3, 0xf7].pack('C*'))
      expect(events[2].channel).to eq(nil)
    end

    it 'skips stray data bytes' do
      expect(MB::Sound::MIDI::Event.parse_all([1, 2, 0x80, 1, 2]).map(&:type)).to eq([:note_off])
    end
  end

  describe 'builders' do
    it 'makes note-ons that keep the exact velocity and have MIDI bytes' do
      e = MB::Sound::MIDI::Event.note_on(60, 0.75, channel: 2, time: 1/4r)
      expect(e).to have_attributes(type: :note_on, channel: 2, note: 60, velocity: 0.75, raw: 95, time: 1/4r)
      expect(e.bytes).to eq([0x92, 60, 95].pack('C*'))
    end

    it 'never gives a note-on a raw velocity of 0' do
      expect(MB::Sound::MIDI::Event.note_on(60, 0).raw).to eq(1)
    end

    it 'leaves out bytes for notes that are not MIDI note numbers' do
      expect(MB::Sound::MIDI::Event.note_on(60.5).bytes).to eq(nil)
      expect(MB::Sound::MIDI::Event.note_on(128).bytes).to eq(nil)
      expect(MB::Sound::MIDI::Event.note_on(MB::Sound::Pitch.new(440)).bytes).to eq(nil)
    end

    it 'round-trips CCs and bends through bytes' do
      cc = MB::Sound::MIDI::Event.cc(74, 1.0, channel: 3)
      expect(MB::Sound::MIDI::Event.parse(cc.bytes)).to eq(cc)

      [-1.0, 0.0, 1.0].each do |v|
        b = MB::Sound::MIDI::Event.bend(v, channel: 1)
        expect(MB::Sound::MIDI::Event.parse(b.bytes)).to eq(b)
      end
    end
  end

  describe '#bend_semitones' do
    it 'uses the default range of 2 semitones' do
      expect(MB::Sound::MIDI::Event.bend(0.5).bend_semitones).to eq(1.0)
    end

    it 'uses the bend range of the event' do
      expect(MB::Sound::MIDI::Event.bend(-1.0).with(bend_range: 12).bend_semitones).to eq(-12.0)
    end

    it 'is nil for other events' do
      expect(MB::Sound::MIDI::Event.note_on(60).bend_semitones).to eq(nil)
    end
  end

  it 'is immutable' do
    e = MB::Sound::MIDI::Event.note_on(60)
    expect(e).to be_frozen
    expect(e.with_note(62).note).to eq(62)
    expect(e.note).to eq(60)
  end

  it 'rebuilds bytes when the velocity changes' do
    e = MB::Sound::MIDI::Event.note_on(60, 1.0).with_velocity(0.5)
    expect(e.velocity).to eq(0.5)
    expect(e.raw).to eq(64)
    expect(e.bytes).to eq([0x90, 60, 64].pack('C*'))
  end

  it 'describes itself' do
    expect(MB::Sound::MIDI::Event.note_on(60, 0.5, time: 1).to_s).to eq('note_on/ch0 60 v0.5 @1.0s')
  end
end
