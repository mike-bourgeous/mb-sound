module MB
  module Sound
    module MIDI
      # A Source that plays a MIDI file: every track's channel and sysex
      # events, merged and converted to Events once (meta events like tempo
      # and track names are left out).  Reading is free of clocks and side
      # effects, so restarting, seeking, and looping just move a number
      # (the old clock-driven MIDIFile#read made reuse tricky, GH #67).
      #
      # The file is parsed by MIDIFile (midilib).  Pulse times are turned
      # into seconds by a tempo map (+:tempo_map+, anything with
      # #seconds(pulses) returning Rational seconds).  The default,
      # ConstantTempo, uses the file's first tempo like MIDIFile does; a
      # reader for tempo changes can be added later as another tempo map.
      #
      # Examples:
      #     src = MB::Sound::MIDI::FileSource.new('spec/test_data/midi.mid')
      #     src.read(0, 1)       # events in the first second
      #     src.seek(10)         # continue from 10 s into the file
      #     MB::Sound::MIDI::FileSource.new('song.mid', loop: true)
      class FileSource
        include Source

        # A tempo map for files with one tempo: a fixed number of seconds per
        # pulse (MIDI tick).
        class ConstantTempo
          # The default tempo of MIDI files without a tempo event: 120 BPM.
          DEFAULT_MICROSECONDS_PER_QUARTER = 500_000

          # Seconds per pulse (a Rational).
          attr_reader :seconds_per_pulse

          # Uses the first tempo event of the first track of a midilib
          # Sequence (as midilib and MIDIFile do), or 120 BPM.
          def self.from_sequence(seq)
            tempo = seq.tracks.first&.events&.detect { |e| e.is_a?(::MIDI::Tempo) }
            new(microseconds_per_quarter: tempo&.tempo || DEFAULT_MICROSECONDS_PER_QUARTER, ppqn: seq.ppqn)
          end

          def initialize(microseconds_per_quarter:, ppqn:)
            @seconds_per_pulse = Rational(microseconds_per_quarter, 1_000_000 * ppqn)
          end

          # Converts a pulse count from the start of the file to Rational
          # seconds.
          def seconds(pulses)
            pulses * @seconds_per_pulse
          end
        end

        # The MIDIFile that was read.
        attr_reader :midi_file

        # The file's Events in content time (seconds from the start of the
        # file), sorted by time.
        attr_reader :events

        # The length of the file in content seconds: the time of its last
        # event of any kind (usually an end-of-track meta event).  Looping
        # files loop at this length.
        attr_reader :duration

        # +file+ is a filename or a MIDIFile.  If +:loop+ is true, the file
        # repeats every #duration seconds (it must have a nonzero duration).
        def initialize(file, loop: false, tempo_map: nil)
          @midi_file = file.is_a?(MIDIFile) ? file : MIDIFile.new(file)
          seq = @midi_file.seq
          @tempo_map = tempo_map || ConstantTempo.from_sequence(seq)
          @loop = !!loop
          @offset = 0r

          @events = @midi_file.events.each_with_index.filter_map { |e, idx|
            next if e.is_a?(::MIDI::MetaEvent)
            t = @tempo_map.seconds(e.time_from_start)
            Event.parse_all(e.data_as_bytes, time: t).map { |ev| [ev, idx] }
          }.flatten(1).sort_by { |ev, idx| [ev.time, idx] }.map(&:first).freeze

          last_pulse = seq.tracks.filter_map { |t| t.events.last&.time_from_start }.max || 0
          @duration = @tempo_map.seconds(last_pulse)
          @content_end = @events.empty? ? 0r : @events.last.time

          raise ArgumentError, "Cannot loop a MIDI file with no length (#{@midi_file.filename})" if @loop && @duration <= 0

          @node_type_name = "MIDI File #{File.basename(@midi_file.filename.to_s)}"
        end

        # True if the file repeats forever.
        def looping?
          @loop
        end

        # The current position in content seconds (from the start of the
        # file, counting loops).
        def content_position
          position - @offset
        end

        # True once the last event has been read (never for looping files).
        def ended?
          !@loop && position > music_end
        end

        # The stream time of the last event (nil for looping files).
        def music_end
          @loop ? nil : (@music_end ||= @offset + @content_end)
        end

        # The file's first note-on (see Source#first_note).
        def first_note
          @events.find(&:note_on?)
        end

        # The file's notes, each with its start, key release, and pedal
        # release (sustain, sostenuto) times, sorted by start time (see
        # MIDI::NoteList), from one pass of the file (no loops).  Reads a
        # copy, so this source's position doesn't change.  Notes held down
        # at the end end at #duration.  Used by bin/midi/midi_roll.rb.
        def notes
          @notes ||= NoteList.notes(FileSource.new(@midi_file, tempo_map: @tempo_map), end_time: @duration).each(&:freeze).freeze
        end

        # The minimum, median, and maximum note number of #notes (only those
        # on 0-based +:channel+ if given), or 64 for each without notes; e.g.
        # for the initial scroll position of a piano roll.
        def note_stats(channel: nil)
          NoteList.stats(notes, channel: channel)
        end

        private

        def seek_to(time)
          @offset = position - time
          @music_end = nil
        end

        def read_events(from, to)
          c0 = from - @offset
          c1 = to - @offset
          return in_range(c0, c1, @offset) unless @loop

          out = []
          first = (c0 / @duration).floor
          last = (c1 / @duration).ceil - 1
          (first..last).each do |cycle|
            base = cycle * @duration
            out.concat(in_range(c0 - base, c1 - base, @offset + base))
          end
          out
        end

        # Events with content times in [c0, c1), moved to stream time by
        # +shift+.
        def in_range(c0, c1, shift)
          start = @events.bsearch_index { |e| e.time >= c0 } || @events.length
          out = []
          idx = start
          while idx < @events.length && @events[idx].time < c1
            e = @events[idx]
            out << e.at(e.time + shift)
            idx += 1
          end
          out
        end
      end
    end
  end
end
