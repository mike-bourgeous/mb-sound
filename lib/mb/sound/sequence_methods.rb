module MB
  module Sound
    # Methods included in MB::Sound for building musical sequences.  See
    # MB::Sound::Sequence.
    module SequenceMethods
      # Returns a Sequence::Seq that plays the given +items+ one after
      # another.  Items may be Notes (C4), note lengths (C4.n8), numbers (MIDI
      # note numbers or other values), nil or #rest for a rest, or other
      # clips.  Steps without a length can be given one all at once:
      #
      #     seq(C4, E4, G4.n4).n8     # two eighth notes and a quarter note
      #     seq(C4.n8.d, E4.n16, rest.n4, seq(G4, A4).n16 * 2)
      def seq(*items, seed: 0)
        Sequence::Seq.new(items, seed: seed)
      end

      # Returns a one-step rest with its length unset (e.g. `rest.n8`).
      def rest
        Sequence::Seq.new([nil])
      end

      # Returns a control signal that tweens through +values+, one per
      # +step+, along +curve+ (a MB::Sound::Curve name such as :smoothstep
      # (default), :elastic, :bounce, :squiggle, :steps, :back, a Curve, or a
      # Proc): automation for a cutoff, a detune, a mix, ... following the
      # session's tempo and timeline.  +step+ is a length (e.g. `1.bar`,
      # `2.beats`, `3.n16`; a plain number counts bars) or an Array of
      # lengths, one per value (cycling).  Values are keyframes: each is the
      # output at the start of its step, and the step tweens to the next
      # value (arriving as the next step starts, or after +time+ and then
      # holding).  The last value holds, or with +loop: true+ (default)
      # tweens back to the first over the last step; repeat a value to hold
      # it.  +overshoot:+ and +cycles:+ go to a named curve.
      #
      # Pitches (`300.hz`, Notes) tween in octaves and give Hz, so cutoffs
      # move evenly in pitch and overshoots stay above 0 Hz; plain numbers
      # tween linearly; +log:+ true or false overrides; mixing Pitches and
      # numbers raises.  Built on a Clip (Sequence::Clip#tween), so clips of
      # values tween the same way.
      #
      #     # 300 -> 3000 Hz during bar 1, 3000 -> 800 during bar 2, back to 300 during bar 3
      #     bg :pad, 110.hz.saw.filter(:lowpass, cutoff: tween([300.hz, 3000.hz, 800.hz], 1.bar, curve: :elastic), quality: 4) * 0.3
      #     tween([0, 1, 0.3], 1.bar, curve: :bounce, loop: false)    # a bouncing mix knob, then 0.3
      #     tween([0, 12, 12, 7], 2.beats, curve: :steps, cycles: 4)  # stepped automation, holding 12 for a step
      def tween(values, step = 1.bar, curve: :smoothstep, time: nil, overshoot: nil, cycles: nil, log: nil, loop: true)
        values = Array(values)
        raise ArgumentError, 'A tween needs at least one value' if values.empty?
        Sequence::Clip.tween_values(values, log) # checks the values early

        steps = Array(step).map { |s|
          s.is_a?(Numeric) ? Sequence::Duration.rational(s) * transport.bar_length : Sequence::Duration.whole_notes(s)
        }
        start = 0r
        events = values.each_with_index.map { |v, i|
          len = steps[i % steps.length]
          e = Sequence::Event.new(start: start, length: len, value: v, velocity: Sequence::Clip::DEFAULT_VELOCITY)
          start += len
          e
        }
        Sequence::Clip.new(events, length: start, loop: loop).tween(time, curve: curve, overshoot: overshoot, cycles: cycles, log: log)
      end

      # Parses step-sequencer strings with steps of 1/+division+ whole notes
      # (an Integer note division or Rational whole notes).  One character is
      # one step: x = hit, X = accent, 1-9 = velocity, ? = 50% chance, . =
      # rest, and | or space are ignored.  See Sequence::Grid::SYMBOLS.
      #
      # With a single String, returns a Seq.  With named rows, returns a
      # Sequence::Kit whose rows are Seqs; names are General MIDI drum names
      # (Sequence::Grid::GM_DRUMS), Notes, or numbers, unless given in +:map+.
      #
      #     grid(16, 'x...x...')
      #     grid(16, kick: 'x...x...x...x.x.', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.xX')
      def grid(division, pattern = nil, value: Sequence::Grid::GM_DRUMS[:kick], map: {}, seed: 0, **rows)
        if pattern
          raise ArgumentError, 'Pass either a single pattern or named rows, not both' if rows.any?
          Sequence::Grid.parse(division, pattern, value: value, seed: seed)
        else
          raise ArgumentError, 'Pass a pattern String or named rows' if rows.empty?
          Sequence::Kit.new(rows.to_h { |name, pat|
            [name, Sequence::Grid.parse(division, pat, value: Sequence::Grid.row_value(name, map), seed: seed)]
          })
        end
      end

      # Returns the Sequence::Transport that sets the tempo for clips played
      # in node graphs: the default transport, or the rendering session's
      # transport inside a PlaybackMethods#render block.
      def transport
        MB::Sound::Session.context&.[](:session)&.transport || Sequence.transport
      end

      # Moves the background playback timeline (see PlaybackMethods#bg) to the
      # start of +bar+, counting from 1 (fractions are allowed, e.g. 2.5).
      # Sounds already playing jump there on their next buffer.  Returns the
      # transport.
      def seek(bar)
        raise ArgumentError, "Bar must be a number of at least 1 (got #{bar.inspect})" unless bar.is_a?(Numeric) && bar >= 1
        transport.seek((bar.to_r - 1) * transport.bar_length)
      end

      # Moves the background playback timeline back to the start (see #seek).
      # (Named rewind because bin/sound.rb uses Pry's reset command.)
      def rewind
        seek(1)
      end

      # Sets the tempo in quarter notes per minute, or returns it if
      # +beats_per_minute+ is nil.  Clips that are already playing change
      # speed right away.  Inside a scheduled block (see ScheduleMethods), the
      # change happens at the block's scheduled time instead.  A script's
      # --bpm option scales the tempos a song sets (see
      # Sequence::Transport#override_bpm).
      def bpm(beats_per_minute = nil)
        context = MB::Sound::Session.context
        beats_per_minute = transport.scaled_bpm(beats_per_minute) if beats_per_minute
        if beats_per_minute && context&.[](:batch)
          session, time = context[:session], context[:time]
          context[:batch] << -> { session.change_tempo(beats_per_minute, time: time) }
          return beats_per_minute
        end

        transport.bpm = beats_per_minute if beats_per_minute
        transport.bpm
      end
    end
  end
end
