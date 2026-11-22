module MB
  module Sound
    module MIDI
      # The one place where MIDI channel and program numbers cross between
      # what people type and see (1-based: channel 1 to 16, program 1 to
      # 128, as synths, sequencers, and General MIDI tables count them) and
      # what MIDI::Event and the wire hold (0-based: the status byte's low
      # nibble 0 to 15, program change data 0 to 127).
      #
      # Every user-facing argument (`stream.channel(10)`, `cc(1, channel:
      # 2)`, `midi_clip(path, channel: 3)`, `rec ..., channel: 1`,
      # `C4.to_midi(channel: 1)`, `midi_out(..., channel: 1, program: 12)`)
      # goes through .of (or .set_of for filters), and every display or
      # printed value through .show; 0 (or 17) raises with a hint.
      # MIDI::Event fields (Event#channel, Event.note_on(channel:), ...)
      # and raw byte Arrays stay 0-based: they are the wire's numbers.
      #
      # Graph documents before format 16 (GraphIO::FORMATS
      # :midi_one_based) wrote 0-based channels; the loader shifts them
      # (GraphIO::Loader).  Takes saved before it replay their console
      # lines inside .zero_based (Take::Replay, +midi_one_based:+).
      module Channel
        # The user-facing channel numbers.
        RANGE = 1..16

        # The hint added when someone types channel 0.
        HINT = 'channels count from 1, as on synths and sequencers: channel 1 is the first (drums are channel 10)'

        class << self
          # The 0-based channel (0..15) for the 1-based channel +user+
          # (1..16).  Raises ArgumentError for anything else, with a hint
          # for 0.  +what+ names the argument in the message.  A nil +user+
          # gives +default+ (an internal channel; methods whose channel
          # has a default take nil for it, so .zero_based never shifts a
          # default).
          def of(user, what: 'channel', default: :none)
            if user.nil? && default != :none
              return default
            end
            if zero_based?
              raise ArgumentError, "MIDI #{what}s in this old take are 0 to 15 (got #{user.inspect})" unless user.is_a?(Integer) && user.between?(0, 15)
              return user
            end
            unless user.is_a?(Integer) && RANGE.cover?(user)
              hint = user == 0 ? " (#{HINT})" : ''
              raise ArgumentError, "MIDI #{what}s are 1 to 16 (got #{user.inspect})#{hint}"
            end
            user - 1
          end

          # Like .of, but nil stays nil (any channel).
          def of_optional(user, what: 'channel')
            of(user, what: what, default: nil)
          end

          # The 0-based channels for a channel filter: an Integer, an Array
          # of them, or a Range (1-based; 1..16 inclusive or exclusive).
          # Returns the same shape with 0-based numbers.
          def set_of(user, what: 'channel')
            case user
            when Integer then of(user, what: what)
            when Array then user.map { |c| of(c, what: what) }
            when Range
              raise ArgumentError, "MIDI #{what} ranges need both ends (got #{user.inspect})" if user.begin.nil? || user.end.nil?
              last = user.exclude_end? ? user.end - 1 : user.end
              of(user.begin, what: what)..of(last, what: what)
            else
              raise ArgumentError, "MIDI #{what}s are 1 to 16, an Array of them, or a Range (got #{user.inspect})"
            end
          end

          # The 1-based channel to show or print for the 0-based +internal+
          # channel (nil stays nil).
          def show(internal)
            internal.nil? ? nil : internal + 1
          end

          # Like .show for a filter's 0-based Integer, Array, or Range.
          def show_set(internal)
            case internal
            when Integer then show(internal)
            when Array then internal.map { |c| show(c) }
            when Range then show(internal.begin)..show(internal.end)
            else internal
            end
          end

          # Runs the block with channel arguments read 0-based, as they were
          # written before 1-based channels (graph documents before format
          # 16 are shifted by the loader instead; this is for replaying old
          # takes' console lines, Take::Replay).  Per thread.
          def zero_based
            old = Thread.current[:mb_sound_midi_zero_based]
            Thread.current[:mb_sound_midi_zero_based] = true
            yield
          ensure
            Thread.current[:mb_sound_midi_zero_based] = old
          end

          # True inside .zero_based.
          def zero_based?
            !!Thread.current[:mb_sound_midi_zero_based]
          end
        end
      end

      # Program numbers as people count them (1 to 128, as on most synth
      # displays and in the General MIDI table) and as program change
      # messages carry them (0 to 127).  SoundFont preset numbers are not
      # converted: `sf2(path, preset: [bank, preset])` names the numbers in
      # the file, which SoundFont editors show from 0.
      module Program
        # The user-facing program numbers.
        RANGE = 1..128

        class << self
          # The 0-based program (0..127) for the 1-based +user+ (1..128).
          def of(user)
            if Channel.zero_based?
              raise ArgumentError, "MIDI programs in this old take are 0 to 127 (got #{user.inspect})" unless user.is_a?(Integer) && user.between?(0, 127)
              return user
            end
            unless user.is_a?(Integer) && RANGE.cover?(user)
              hint = user == 0 ? ' (programs count from 1, as on most synth displays and the General MIDI table: program 1 is the first)' : ''
              raise ArgumentError, "MIDI programs are 1 to 128 (got #{user.inspect})#{hint}"
            end
            user - 1
          end

          # The 1-based program to show for the 0-based +internal+ one.
          def show(internal)
            internal.nil? ? nil : internal + 1
          end
        end
      end
    end
  end
end
