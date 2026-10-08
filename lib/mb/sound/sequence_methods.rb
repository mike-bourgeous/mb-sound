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

      # Loudness falls for #bounce_hits' +:decay+ option, as the velocity
      # multiplier for hit i given the elasticity e.
      BOUNCE_DECAYS = {
        speed: ->(e, i) { e**i },          # impact speed (physical)
        gentle: ->(e, i) { e**(i * 0.5) }, # square root of the speed
        none: ->(_e, _i) { 1.0 },
      }.freeze

      # Returns a Clip of hits timed like a bouncing ball (a geometric
      # accelerando): dropped at the start, each bounce +elasticity+ (the
      # restitution, 0 < e < 1) times as long as the one before, so the hits
      # crowd together and converge exactly on +length+ (e.g. `2.bars`: a
      # ball dropped on a bar line settles onto the bar line two bars later,
      # back on the grid).  Hit i is at length × (1 - e^i).  +count+ hits at
      # most; hits closer than +min_gap+ (whole notes) to the previous one
      # are dropped.  With +reverse: true+ the hits accelerate apart instead
      # (a buzz that slows into single hits, soft to loud, rising if
      # +:pitch+ falls).  The clip is +length+ long and doesn't loop (add
      # `.loop`, or `.loop(align: :launch)` to drop the ball wherever it is
      # launched); its hit times match the contact points of Curve.bounce.
      #
      # Velocities start at +velocity+ and fall by +:decay+, separately
      # from the timing, so loudness, pitch, or brightness mapped from
      # `v.velocity` fall with each bounce:
      # - :gentle (default) - e^(i/2), half the fall in dB, so every
      #   bounce stays audible.
      # - :speed - e^i, the impact speed: physical, but low elasticities
      #   fade within a few hits (the default until 2026-10-08).
      # - :none - every hit at +velocity+.
      # - A number d - d^i (e.g. 0.85 per hit whatever the elasticity).
      # - A Curve or Curve name (e.g. :quad_out) - velocity × (1 -
      #   curve(i / (count - 1))): the fall over the hits, reaching 0 on
      #   the last.
      # - A Proc - called with the hit index i and the hit's position as a
      #   fraction of +length+ (0...1), returning the velocity multiplier.
      #
      # +note+ is the first hit's value; +:pitch+ moves later hits by
      # semitones: a number or Interval per hit (e.g. -1 drops a semitone
      # each bounce), or a Proc called like +:decay+'s returning the offset.
      #
      #     ball = bounce_hits(2.bars, count: 16, elasticity: 0.75, note: C2)
      #     bg :ball, ball.loop(align: :launch).synth(voices: 2) { |v| (v.hz.transpose(v.velocity * 12).sine * v.amp_env(0.001, 0.2, 0, 0.1)) }
      #     bounce_hits(1.bar, count: 40, elasticity: 0.92)            # settles into a buzz
      #     bounce_hits(1.bar, reverse: true)                          # accelerating apart
      #     bounce_hits(1.bar, elasticity: 0.5, decay: :speed)         # physical: a dead ball fades fast
      #     bounce_hits(1.bar, count: 20, decay: 0.9)                  # 0.9 per hit, whatever the elasticity
      #     bounce_hits(2.bars, count: 8, note: E3, pitch: -1)         # a tom dropping a semitone per bounce
      def bounce_hits(length = 1.bar, count: 12, elasticity: 0.7, velocity: 1.0, decay: :gentle, note: 60, pitch: nil, reverse: false, min_gap: 1/1024r)
        e = elasticity.to_f
        raise ArgumentError, "Bounce elasticity must be between 0 and 1, exclusive (got #{elasticity.inspect})" unless e > 0 && e < 1
        count = Integer(count)
        raise ArgumentError, "A bounce needs at least one hit (got #{count})" if count < 1

        len = length.is_a?(Numeric) ? Sequence::Duration.rational(length) * transport.bar_length : Sequence::Duration.whole_notes(length)
        fall = bounce_decay(decay, e, count)
        shift = bounce_pitch(pitch)
        er = Sequence::Duration.rational(e)
        hits = []
        count.times do |i|
          t = len * (1 - er**i)
          break if hits.any? && t - hits.last[0] < min_gap
          frac = (t / len).to_f
          value = shift ? Sequence.transpose_value(note, shift.(i, frac)) : note
          hits << [t, velocity.to_f * fall.(i, frac), value]
        end
        if reverse
          last = hits.last[0]
          hits = hits.reverse.map { |t, v, n| [last - t, v, n] }
        end

        events = hits.each_with_index.map { |(t, v, n), i|
          nxt = hits[i + 1]&.first || len
          Sequence::Event.new(start: t, length: [(nxt - t) / 2, 1/32r].min, value: n, velocity: v.clamp(0.0, 1.0))
        }
        Sequence::Clip.new(events, length: len)
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

      private

      # The velocity multiplier for #bounce_hits' +:decay+, as a lambda of
      # the hit index and position fraction.
      def bounce_decay(decay, e, count)
        case decay
        when Proc
          decay.arity == 1 ? ->(i, _f) { decay.(i).to_f } : ->(i, f) { decay.(i, f).to_f }
        when Numeric
          d = decay.to_f
          raise ArgumentError, "A bounce decay factor must be between 0 and 1 (got #{decay})" unless d >= 0 && d <= 1
          ->(i, _f) { d**i }
        when Symbol, Curve
          if decay.is_a?(Symbol) && BOUNCE_DECAYS.key?(decay)
            fn = BOUNCE_DECAYS[decay]
            return ->(i, _f) { fn.(e, i) }
          end

          curve = begin
            Curve[decay]
          rescue ArgumentError, KeyError
            raise ArgumentError, "Unknown bounce decay #{decay.inspect} (use #{BOUNCE_DECAYS.keys.map(&:inspect).join(', ')}, a factor, a Curve, or a Proc)"
          end
          ->(i, _f) { 1.0 - curve.(count > 1 ? i.to_f / (count - 1) : 0.0) }
        else
          raise ArgumentError, "Unknown bounce decay #{decay.inspect} (use #{BOUNCE_DECAYS.keys.map(&:inspect).join(', ')}, a factor, a Curve, or a Proc)"
        end
      end

      # The semitone offset for #bounce_hits' +:pitch+ as a lambda of the
      # hit index and position fraction, or nil.
      def bounce_pitch(pitch)
        case pitch
        when nil then nil
        when Proc
          pitch.arity == 1 ? ->(i, _f) { pitch.(i) } : ->(i, f) { pitch.(i, f) }
        else
          step = MB::Sound::Interval.semitones(pitch)
          step == 0 ? nil : ->(i, _f) { step * i }
        end
      end
    end
  end
end
