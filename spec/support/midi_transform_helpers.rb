# Helpers for MIDI transform and generator specs.
module MIDITransformHelpers
  def ev
    MB::Sound::MIDI::Event
  end

  # A Stream of +events+ (a MIDIListSource).
  def list_stream(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
  end

  # A stream with one note-on at +on+ and its note-off at +off+ seconds.
  def note_stream(note = 60, on: 0r, off: 1/10r, velocity: 1.0)
    list_stream(ev.note_on(note, velocity, time: on), ev.note_off(note, time: off))
  end

  # The Events read from +stream+ in +chunk+-second reads (one read by
  # default) up to +seconds+.
  def read_events(stream, seconds: 10, chunk: nil)
    r = stream.is_a?(MB::Sound::MIDI::Stream::Reader) ? stream : stream.reader
    if chunk
      (seconds / chunk).ceil.times.flat_map { r.next(chunk) }
    else
      r.next(seconds)
    end
  end

  # [type, note, time (Rational seconds), velocity rounded] for every event
  # read (see #read_events).
  def read_all(stream, seconds: 10, chunk: nil)
    summarize(read_events(stream, seconds: seconds, chunk: chunk))
  end

  def summarize(events)
    events.map { |e| [e.type, e.note, e.time, e.velocity&.round(4)] }
  end

  def ons(list)
    list.select { |e| e[0] == :note_on }
  end

  # Checks that the notes of +list+ (summaries or Events) are balanced: with
  # +stack: false+ every key's note-ons and note-offs alternate; with
  # +stack: true+ the count of sounding notes per key never goes below 0.
  # Nothing may be left sounding.
  def expect_balanced(list, stack: false)
    list = summarize(list) if list.first.is_a?(MB::Sound::MIDI::Event)
    sounding = Hash.new(0)
    list.each do |type, note, time, _|
      case type
      when :note_on
        expect(sounding[note]).to eq(0), "note-on #{note} at #{time} while sounding" unless stack
        sounding[note] += 1
      when :note_off
        expect(sounding[note]).to be > 0, "note-off #{note} at #{time} while silent"
        sounding[note] -= 1
      end
    end
    expect(sounding.select { |_, v| v != 0 }.keys).to eq([])
  end
end

RSpec.configure do |c|
  c.include MIDITransformHelpers, :midi_transforms
end
