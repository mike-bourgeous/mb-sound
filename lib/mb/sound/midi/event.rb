module MB
  module Sound
    module MIDI
      # One MIDI event as an immutable value, created once where events enter
      # the program (a Source; see Source, FileSource, and ClipSource) and
      # passed unchanged through Streams and their transforms.  Part of the
      # new pull-based MIDI layer (Event, Source, Stream) that will replace
      # Manager and the MidiDsl callbacks.
      #
      # Fields:
      # - +type+: :note_on, :note_off, :poly_pressure, :cc, :program,
      #   :channel_pressure, :bend, :sysex, or :system for MIDI messages, or
      #   :choke or :glide for events that only exist inside the program (see
      #   .choke and .glide; they have no bytes).  A note-on with
      #   velocity 0 becomes a :note_off (with the conventional release
      #   velocity of 64).  Channel mode messages (CC 120-127) stay :cc; see
      #   #all_sound_off?, #reset_controllers?, and #all_notes_off?.
      # - +channel+: 0 to 15 (0-based, like Manager's +:channel+), or nil for
      #   system messages.
      # - +note+ (alias #index): the note number for notes and poly
      #   pressure, the controller number for CCs, else nil.  Usually an
      #   Integer, but clip sources and #transpose may give other Numerics or
      #   a Pitch.
      # - +value+: the main value, normalized: velocity 0..1 for notes, 0..1
      #   for CCs and pressure, -1..1 for pitch bend (center 8192; down to
      #   -1 at 0 and up to +1 at 16383), and the program number (an
      #   Integer) for program changes.
      # - +velocity+: 0..1 for note events (the same as +value+), else nil.
      # - +raw+: the raw data value (velocity, CC, or pressure 0..127, bend
      #   0..16383, program 0..127).
      # - +bytes+: the raw message as a frozen binary String, or nil if the
      #   event can't be represented as MIDI bytes (e.g. a note transposed
      #   by 50 cents).
      # - +time+: Rational seconds since the start of the Stream it came
      #   from.  Readers turn it into a sample index at their own rate.
      # - +bend_range+: for :bend events, the bend range in semitones in
      #   effect for the event's channel (set by Stream from RPN 0 and
      #   Stream#bend_range; see #bend_semitones).
      # - +legato+: true for a note-on that continues a phrase although the
      #   stream it is in has no other note held (e.g. a mono voice whose
      #   previous note was ended by an allocator at the same time), so
      #   legato-only glides and similar behavior still apply.  False by
      #   default.  Not sent as MIDI.
      #
      # Examples:
      #     Event.parse("\x90\x3c\x40")          # note_on C4 (60), velocity 64/127
      #     Event.note_on(60, 0.5, channel: 9)   # normalized velocity
      #     Event.bend(-1.0).bend_semitones      # => -2.0
      #     Event.choke(60)                      # silence a voice quickly
      #     Event.glide(48)                      # next note glides from C3
      class Event < Data.define(:type, :channel, :note, :value, :velocity, :raw, :bytes, :time, :bend_range, :legato)
        # The pitch bend range in semitones when nothing else sets it.
        DEFAULT_BEND_RANGE = 2

        # The release velocity given to note-on messages with velocity 0,
        # which mean note-off (the MIDI 1.0 specification's convention).
        DEFAULT_RELEASE = 64

        # Event types for messages with a channel, indexed by the status
        # byte's upper nibble minus 8.
        CHANNEL_TYPES = [:note_off, :note_on, :poly_pressure, :cc, :program, :channel_pressure, :bend].freeze

        # The status nibble for each channel message type.
        STATUS = {
          note_off: 0x80, note_on: 0x90, poly_pressure: 0xa0, cc: 0xb0,
          program: 0xc0, channel_pressure: 0xd0, bend: 0xe0,
        }.freeze

        # The number of data bytes after the status byte for each channel
        # message type.
        DATA_BYTES = {
          note_off: 2, note_on: 2, poly_pressure: 2, cc: 2,
          program: 1, channel_pressure: 1, bend: 2,
        }.freeze

        # The number of data bytes after each system common status byte
        # (0xf1 to 0xf6; sysex and realtime messages are handled separately).
        SYSTEM_DATA_BYTES = { 0xf1 => 1, 0xf2 => 2, 0xf3 => 1, 0xf6 => 0 }.freeze

        def initialize(type:, time: 0r, channel: nil, note: nil, value: nil, velocity: nil, raw: nil, bytes: nil, bend_range: nil, legato: false)
          bytes = bytes.pack('C*') if bytes.is_a?(Array)
          bytes = bytes.b.freeze if bytes && !(bytes.frozen? && bytes.encoding == Encoding::BINARY)
          super(
            type: type, channel: channel, note: note, value: value, velocity: velocity, raw: raw, bytes: bytes,
            time: time.to_r, bend_range: bend_range, legato: !!legato
          )
        end

        # Parses one complete MIDI message (a String or Array of bytes) at
        # +time+ seconds.  Returns nil for an incomplete message.  See
        # .parse_all for several messages or running status.
        def self.parse(bytes, time: 0r)
          parse_all(bytes, time: time).first
        end

        # Parses every message in +bytes+ (a String or Array of bytes), all
        # at +time+ seconds, following running status.  Incomplete messages
        # and stray data bytes are skipped.
        def self.parse_all(bytes, time: 0r)
          data = bytes.is_a?(String) ? bytes.bytes : bytes.to_a
          events = []
          running = nil
          idx = 0

          while idx < data.length
            b = data[idx]

            if b >= 0xf8
              # Realtime messages may appear anywhere, even inside other messages
              events << new(type: :system, raw: b, value: b, bytes: [b], time: time)
              idx += 1
              next
            end

            if b == 0xf0
              stop = (idx + 1...data.length).find { |i| data[i] == 0xf7 }
              stop = stop ? stop + 1 : data.length
              events << new(type: :sysex, bytes: data[idx...stop], time: time)
              running = nil
              idx = stop
              next
            end

            if b >= 0xf0
              count = SYSTEM_DATA_BYTES[b] || 0
              msg = data[idx, count + 1]
              events << new(type: :system, raw: b, value: b, bytes: msg, time: time) if msg.length == count + 1
              running = nil
              idx += count + 1
              next
            end

            if b >= 0x80
              running = b
              idx += 1
            elsif running.nil?
              idx += 1 # stray data byte
              next
            end

            count = DATA_BYTES[CHANNEL_TYPES[(running >> 4) - 8]]
            args = []
            while args.length < count && idx < data.length
              b = data[idx]
              if b >= 0xf8
                events << new(type: :system, raw: b, value: b, bytes: [b], time: time)
              elsif b >= 0x80
                break # incomplete message interrupted by another status byte
              else
                args << b
              end
              idx += 1
            end

            events << channel_message(running, args, time) if args.length == count
          end

          events
        end

        # Builds an Event from a channel message's status byte and data bytes.
        def self.channel_message(status, args, time)
          type = CHANNEL_TYPES[(status >> 4) - 8]
          channel = status & 0x0f
          bytes = [status, *args]

          case type
          when :note_on, :note_off
            note, vel = args
            if type == :note_on && vel == 0
              type = :note_off
              vel = DEFAULT_RELEASE
            end
            v = vel / 127.0
            new(type: type, channel: channel, note: note, value: v, velocity: v, raw: vel, bytes: bytes, time: time)

          when :poly_pressure, :cc
            new(type: type, channel: channel, note: args[0], value: args[1] / 127.0, raw: args[1], bytes: bytes, time: time)

          when :program
            new(type: type, channel: channel, value: args[0], raw: args[0], bytes: bytes, time: time)

          when :channel_pressure
            new(type: type, channel: channel, value: args[0] / 127.0, raw: args[0], bytes: bytes, time: time)

          when :bend
            raw = args[0] | (args[1] << 7)
            new(type: type, channel: channel, value: bend_value(raw), raw: raw, bytes: bytes, time: time)
          end
        end
        private_class_method :channel_message

        # Converts a raw 14-bit bend value to -1..1 (see the class
        # description).
        def self.bend_value(raw)
          raw < 8192 ? (raw - 8192) / 8192.0 : (raw - 8192) / 8191.0
        end

        # Converts a bend value from -1..1 to 0..16383.
        def self.bend_raw(value)
          value = MB::M.clamp(value.to_f, -1.0, 1.0)
          (value < 0 ? 8192 + value * 8192 : 8192 + value * 8191).round
        end

        # Converts a normalized 0..1 value to 0..127.
        def self.raw7(value)
          MB::M.clamp((value.to_f * 127).round, 0, 127)
        end

        # Returns MIDI bytes for a note event, or nil if +note+ isn't an
        # Integer from 0 to 127.
        def self.note_bytes(type, channel, note, raw)
          return nil unless note.is_a?(Integer) && note.between?(0, 127) && channel.between?(0, 15)
          [STATUS[type] | channel, note, raw]
        end

        # A note-on event.  +velocity+ is 0..1 and is kept as given (not
        # rounded to a MIDI value); the raw velocity is at least 1, since 0
        # would mean note-off.  See the class description for +:legato+.
        def self.note_on(note, velocity = 1.0, channel: 0, time: 0r, legato: false)
          raw = MB::M.max(raw7(velocity), 1)
          new(
            type: :note_on, channel: channel, note: note, value: velocity.to_f, velocity: velocity.to_f,
            raw: raw, bytes: note_bytes(:note_on, channel, note, raw), time: time, legato: legato
          )
        end

        # A note-off event; +velocity+ (0..1) is the release velocity.
        def self.note_off(note, velocity = DEFAULT_RELEASE / 127.0, channel: 0, time: 0r)
          raw = raw7(velocity)
          new(
            type: :note_off, channel: channel, note: note, value: velocity.to_f, velocity: velocity.to_f,
            raw: raw, bytes: note_bytes(:note_off, channel, note, raw), time: time
          )
        end

        # A control change; +value+ is 0..1.
        def self.cc(index, value, channel: 0, time: 0r)
          raw = raw7(value)
          new(type: :cc, channel: channel, note: index, value: value.to_f, raw: raw, bytes: [0xb0 | channel, index, raw], time: time)
        end

        # A control change from a raw 0..127 value.
        def self.cc_raw(index, raw, channel: 0, time: 0r)
          parse([0xb0 | channel, index, raw], time: time)
        end

        # A pitch bend; +value+ is -1..1.
        def self.bend(value, channel: 0, time: 0r)
          raw = bend_raw(value)
          new(type: :bend, channel: channel, value: value.to_f, raw: raw, bytes: [0xe0 | channel, raw & 0x7f, raw >> 7], time: time)
        end

        # A choke: silences the notes of a voice quickly (a 3 ms release in
        # Envelope; see MB::Sound::Notes#choke), e.g. when an allocator
        # steals the voice.  +note+ may name the note being choked, or be
        # nil.  Not a MIDI message (no bytes).
        def self.choke(note, channel: 0, time: 0r)
          new(type: :choke, channel: channel, note: note, time: time)
        end

        # A glide: the next note-on glides to its pitch from +note+ (a note
        # number) instead of from the current pitch, in pitches that glide
        # (see MB::Sound::Notes::NotePitch#glide), like MIDI CC 84
        # (portamento control).  An allocator sends these to idle voices for
        # polyphonic glide.  Not a MIDI message (no bytes).
        def self.glide(note, channel: 0, time: 0r)
          new(type: :glide, channel: channel, note: note, time: time)
        end

        # A program change (+program+ 0..127).
        def self.program(program, channel: 0, time: 0r)
          parse([0xc0 | channel, program], time: time)
        end

        # Channel pressure (aftertouch); +value+ is 0..1.
        def self.channel_pressure(value, channel: 0, time: 0r)
          raw = raw7(value)
          new(type: :channel_pressure, channel: channel, value: value.to_f, raw: raw, bytes: [0xd0 | channel, raw], time: time)
        end

        # Polyphonic (per-note) pressure; +value+ is 0..1.
        def self.poly_pressure(note, value, channel: 0, time: 0r)
          raw = raw7(value)
          new(
            type: :poly_pressure, channel: channel, note: note, value: value.to_f, raw: raw,
            bytes: note_bytes(:poly_pressure, channel, note, raw), time: time
          )
        end

        # The note or controller number (an alias of +note+ that reads better
        # for CCs).
        def index
          note
        end

        def note_on?
          type == :note_on
        end

        def note_off?
          type == :note_off
        end

        # True for note-on and note-off events.
        def note?
          type == :note_on || type == :note_off
        end

        # True for control changes, or for control change +index+ if given.
        def cc?(index = nil)
          type == :cc && (index.nil? || note == index)
        end

        def bend?
          type == :bend
        end

        # True for :choke events (see .choke).
        def choke?
          type == :choke
        end

        # True for :glide events (see .glide).
        def glide?
          type == :glide
        end

        # True for a note-on marked as legato (see the class description).
        def legato?
          legato
        end

        # True for channel mode messages (CC 120 to 127).
        def channel_mode?
          type == :cc && note >= 120
        end

        # CC 120: silence every sound on the channel at once.
        def all_sound_off?
          cc?(120)
        end

        # CC 121: reset controllers (pedals, bend, pressure) to their
        # defaults.
        def reset_controllers?
          cc?(121)
        end

        # CC 123 (all notes off), or 124 to 127 (omni and mono/poly mode
        # changes), which also turn all notes off per the MIDI specification.
        def all_notes_off?
          type == :cc && note >= 123
        end

        # The pitch bend in semitones (+value+ times the #bend_range in effect
        # for the channel), or nil if this isn't a bend event.
        def bend_semitones
          return nil unless type == :bend
          value * (bend_range || DEFAULT_BEND_RANGE)
        end

        # Returns a copy of this event at +time+ seconds.
        def at(time)
          with(time: time)
        end

        # Returns a note event with its note number changed to +note+,
        # rebuilding the bytes (nil if +note+ can't be sent as MIDI).
        def with_note(note)
          b = (note? || type == :poly_pressure) ? Event.note_bytes(type, channel, note, raw) : bytes
          with(note: note, bytes: b)
        end

        # Returns a note-on event with its velocity changed to +velocity+
        # (0..1), rebuilding the raw velocity and bytes.
        def with_velocity(velocity)
          raw = Event.raw7(velocity)
          raw = MB::M.max(raw, 1) if type == :note_on
          with(velocity: velocity.to_f, value: velocity.to_f, raw: raw, bytes: Event.note_bytes(type, channel, note, raw))
        end

        def to_s
          t = MB::M.sigfigs(time.to_f, 6)
          desc = case type
                 when :note_on, :note_off then "#{note} v#{MB::M.sigfigs(velocity, 3)}#{' legato' if legato}"
                 when :cc, :poly_pressure then "#{note}=#{MB::M.sigfigs(value, 3)}"
                 when :bend then "#{MB::M.sigfigs(value, 4)}#{" (#{MB::M.sigfigs(bend_semitones, 4)} st)" if bend_range}"
                 when :sysex then "#{bytes.bytesize} bytes"
                 when :choke, :glide then note.to_s
                 else value.inspect
                 end
          "#{type}#{"/ch#{channel}" if channel} #{desc} @#{t}s"
        end
      end
    end
  end
end
