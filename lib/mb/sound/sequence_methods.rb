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

      # Returns a Seq of +items+ (see #seq) with every unset step +step+
      # long (a note division, default 16, or Rational whole notes), played
      # like a TB-303's sequencer (Sequence::Seq#acid: half-step gates,
      # accents `!A1` at +accent:+ velocity, other notes at +normal:+, slides
      # `~A1` overlapping the next note).  Tie (T) holds a note one more
      # step, Rest (R) is a rest, and `.up`/`.dn` move a note an octave.
      #
      #     bass = acid(A1, !A1, ~A2, A1, R, C2, !A1, T, ~D2, E2, A1.up, R).loop
      def acid(*items, step: 16, seed: 0, **options)
        seq(*items, seed: seed).len(step).acid(**options)
      end

      # Note marks an #events row may give in its trailing Hash.
      EVENT_MARKS = [:probability, :accented, :slid, :condition, :fill_mark, :pitch, :flam].freeze

      # Returns a Sequence::Clip of explicit events, one Array per event:
      # [start, length, value, velocity], plus a Hash of note marks
      # (probability:, accented:, slid:, condition: [n, from], fill_mark:
      # [:fill or :nofill, name], pitch: semitones, flam: true or seconds) when it has any.  Starts and lengths are
      # whole notes (exact Rationals); values are note numbers (or any
      # number, or a Pitch).  This is how graph documents and #to_ruby
      # write clips that have no recipe (a recorded or captured clip,
      # Clip.new in a script); seq and grid read better for writing by
      # hand.  +performed: true+ marks velocities as played (see
      # Sequence::Clip#performed?).
      #
      #     events([0r, 1r/8, 57, 0.75], [1r/4, 1r/8, 60, 1.0, { accented: true }], length: 1r/2, loop: true)
      def events(*rows, length: nil, loop: false, seed: 0, align: :timeline, performed: false)
        list = rows.map { |row|
          raise ArgumentError, "Event rows are Arrays [start, length, value, velocity, { marks }] (got #{row.inspect})" unless row.is_a?(Array) && row.length.between?(4, 5)
          start, len, value, velocity, marks = row
          [start, len].each { |t|
            raise ArgumentError, "Event starts and lengths are whole notes (got #{t.inspect})" unless t.is_a?(Numeric) && t.real? && !t.is_a?(Float)
          }
          raise ArgumentError, "Event lengths can't be negative (got #{len})" if len < 0
          raise ArgumentError, "Event values are numbers or Pitches (got #{value.inspect})" unless (value.is_a?(Numeric) && value.real?) || value.is_a?(Pitch)
          raise ArgumentError, "Event velocities are numbers from 0 to 1 (got #{velocity.inspect})" unless velocity.is_a?(Numeric) && velocity.real?
          marks ||= {}
          raise ArgumentError, "Event marks are a Hash (got #{marks.inspect})" unless marks.is_a?(Hash)
          unknown = marks.keys - EVENT_MARKS
          raise ArgumentError, "Unknown event marks #{unknown.map(&:inspect).join(', ')} (#{EVENT_MARKS.join(', ')})" unless unknown.empty?
          Sequence::Event.new(start: start.to_r, length: len.to_r, value: value, velocity: velocity, **marks)
        }
        length = length.whole_notes if length.is_a?(Sequence::Duration)
        Sequence::Clip.new(list, length: length&.to_r, loop: loop, seed: seed, align: align, performed: performed)
      end

      # Returns a MB::Sound::Scale (see Scale.new and Scale.[]): a name such
      # as :minor or :dorian (Scale.names), or an Array of offsets in
      # semitones, with a +root+ (a Note, note number, or name like :a).
      # A pure value: without a +root+, the root is the session key's root
      # (see KeyMethods#key) as it is now, and bare `scale` is the session
      # key's Scale.
      #
      #     scale(:minor, :a)[2]          # => C5 (degree 0 is A4)
      #     scale(:dorian, D3).chord(0)   # => [50, 53, 57]
      #     key :d; scale(:dorian)        # D dorian
      #     scale                         # the session key's scale
      def scale(intervals = nil, root = nil)
        session_key = Session.existing&.then { |s| s.transport.key(s.now) } || Sequence.current_transport.key
        return session_key.scale if intervals.nil? && root.nil?
        Scale[intervals, root.nil? && !intervals.is_a?(Scale) ? session_key.root : root]
      end

      # Returns a Euclidean rhythm (Sequence::Generators.euclid_pattern):
      # +hits+ notes spread as evenly as possible over +steps+ steps of
      # +:step+ (a note division like 16, a Duration, or Rational whole
      # notes), as a Seq of +note+ (the GM kick by default, like #grid) and
      # rests, moved +:rotate+ steps later.  Loop it, mark it, or use it as
      # a melody's rhythm like any Seq.
      #
      #     euclid(3, 8).loop                   # x..x..x. kicks
      #     euclid(5, 16, D2, rotate: 2).loop   # a bass rhythm
      #     melody(scale(:minor, :a), rhythm: euclid(7, 16))
      def euclid(hits, steps, note = Sequence::Grid::GM_DRUMS[:kick], step: 16, rotate: 0, velocity: nil)
        pattern = Sequence::Generators.euclid_pattern(hits, steps, rotate: rotate)
        items = pattern.map { |hit|
          next nil unless hit
          s = Sequence::Seq.step(note)
          velocity ? Sequence::Seq::Step.new(**s.to_h.merge(velocity: velocity.to_f)) : s
        }
        Sequence::Seq.new(items).len(step)
      end

      # Returns a random melody in +scale+ (a Scale, or anything
      # Scale.[] takes; chromatic by default): +count+ notes of +:step+
      # (a note division, Duration, or Rational whole notes), or the
      # rhythm of +:rhythm+ (a Clip whose notes get new pitches, keeping
      # their timing and velocities).  The line walks the scale from degree
      # +:start+, moving at most +:leap+ degrees per note within +:range+
      # (Notes or note numbers; an octave either side of the root by
      # default), preferring small steps and degrees with high +:weights+
      # (per degree; by default the root, third, and fifth); +:rest+ is
      # the chance of a rest per note.  Choices come from +:seed+ (by
      # default drawn from MB::Sound's root seed, so scripts repeat; it is
      # the clip's #seed).  With +vary: true+ a looping melody picks new
      # notes in every cycle, repeatably from the seed and the cycle (a
      # generator clip, see Sequence::Clip.generate).
      #
      # +scale+ may also be a probability scale (Generative::Weights,
      # Harmony, Field, or Harmony#over; see GenerativeMethods): the line
      # then walks the notes with weight, +:leap+ of them at most per note,
      # by their weights (a blurred scale plays its "wrong" notes now and
      # then), reading the field where each note starts (a Harmony's key
      # and chord changes steer it), from the strongest note nearest
      # +:start+ (a note; the middle of the range by default).  +:range+
      # spreads Weights and Harmonies (C3..C5 by default); +:weights+ is
      # for Scales only.  Draws come from counter-based Dice.
      #
      #     melody(scale(:minor_pentatonic, :a), 8, seed: 3).loop
      #     melody(scale(:dorian, D3), rhythm: euclid(5, 8, D3), leap: 2).loop
      #     melody(scale(:major, :c), 16, vary: true).loop   # new every bar
      #     melody(scale(:dorian, :d).weights.blur(0.2), 8, range: A3..A5, vary: true).loop
      def melody(scale = nil, count = 8, step: 16, rhythm: nil, start: nil, leap: 3, range: nil, weights: nil, rest: 0, seed: nil, vary: false)
        probability = [Generative::Weights, Generative::Harmony, Generative::Field, Generative::FieldTimeline].any? { |c| scale.is_a?(c) }
        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        raise ArgumentError, "Melody rest must be from 0 to 1 (got #{rest.inspect})" unless rest.is_a?(Numeric) && rest.between?(0, 1)
        raise ArgumentError, "Melody leap must be a positive Integer (got #{leap.inspect})" unless leap.is_a?(Integer) && leap > 0

        slots = if rhythm
                  Sequence::Clip.from(rhythm).events
                else
                  len = Sequence::Duration.whole_notes(step)
                  Array.new(count) { |i| Sequence::Event.new(start: len * i, length: len, value: 0, velocity: Sequence::Clip::DEFAULT_VELOCITY) }
                end
        length = rhythm ? Sequence::Clip.from(rhythm).length : Sequence::Duration.whole_notes(step) * count
        reach = MB::M.max(length * 2, slots.map(&:end_time).max || 0)

        if probability
          raise ArgumentError, 'Melody weights: are per scale degree; a probability scale carries its own weights' if weights
          if range && (scale.is_a?(Generative::Field) || scale.is_a?(Generative::FieldTimeline))
            raise ArgumentError, 'A Field has its own range; leave out range: (or pass the Weights or Harmony)'
          end
          field = Generative.field(scale, range: range || Generative::DEFAULT_RANGE)
          notes = Generative.notes_of(field)
          raise ArgumentError, 'The melody\'s field has no notes' if notes.empty?
          start = start.nil? ? (notes.first + notes.last) / 2 : Scale.root_number(start)
          walk = Generative::Melody.new(field, slots, length: length, leap: leap, rest: rest, start: start)
          gen = Sequence::Clip.generate(length, values: notes, seed: seed, name: "melody(seed: #{seed})", reach: reach, loop: false) { |cycle, dice| walk.events(cycle, dice) }
          return vary ? gen : Sequence::Clip.new(gen.events, length: length, seed: seed)
        end

        scale = Scale[scale]
        start ||= 0
        range ||= (scale.root - 12)..(scale.root + 12)
        lo = Scale.root_number(range.begin)
        hi = Scale.root_number(range.end)
        raise ArgumentError, "A melody range needs room (got #{range})" unless hi >= lo

        make = ->(s) {
          notes = Sequence::Generators.melody_notes(scale, slots.length, rng: Random.new(s), range: [lo, hi], weights: weights, leap: leap, rest: rest, start: start)
          slots.zip(notes).filter_map { |slot, n| n && slot.with(value: n) }
        }

        clip = Sequence::Clip.new(make.(seed), length: length, seed: seed)
        return clip unless vary

        # A generator clip: each cycle draws from its own seed (the same
        # notes as before the generative layer; the clip's own events stay
        # the seed's melody)
        Sequence::Clip.generate(length, values: scale.notes(lo..hi), seed: seed, name: "melody(seed: #{seed})", reach: reach, loop: false, events: clip.events) { |cycle, _dice|
          make.(Sequence::Clip.cycle_seed(seed, cycle))
        }
      end

      # Unattached MIDI transforms (MIDI::Transform::Spec) for
      # Sequence::Clip#bake and MIDI::Stream#through, chainable like the
      # stream methods of the same names (see MIDI::Stream#echo, #arp,
      # #strum, #chord):
      #
      #     riff.loop.bake(echo(3.n16, 3, pitch: 7.st, velocity: 0.6))
      #     bg :keys, midi.through(arp(:up, 16).echo(3.n16, 2)).synth { |v| ... }
      def echo(*args, **kwargs, &block)
        MIDI::Transform::Spec.new.echo(*args, **kwargs, &block)
      end

      # An unattached arpeggiator (see #echo and MIDI::Stream#arp).
      def arp(*args, **kwargs)
        MIDI::Transform::Spec.new.arp(*args, **kwargs)
      end

      # An unattached strum (see #echo and MIDI::Stream#strum).
      def strum(*args, **kwargs)
        MIDI::Transform::Spec.new.strum(*args, **kwargs)
      end

      # An unattached chord transform (see #echo and MIDI::Stream#chord),
      # or, given a chord name and +root:+, a chord value
      # (Generative::Chord) whose #weights is a probability scale layer:
      #
      #     riff.bake(chord(0, 7, 15))                       # the transform (pitch steps)
      #     midi.through(chord(:min7))                       # the transform (a chord name)
      #     key.blur(0.15) + chord(:min7, root: :d).weights * 1.5   # a chord layer
      #     chord(:maj7, root: F3, inversion: 1).notes       # => [A3, C4, E4, F4]
      #
      # (The transform takes +root:+ only with scale steps, so a chord name
      # with +root:+ is always the value.)
      def chord(*args, **kwargs)
        if Generative::Chord.value_call?(args, kwargs)
          return Generative::Chord.new(args[0], **kwargs).with_recipe(nil, :chord, args, kwargs)
        end

        MIDI::Transform::Spec.new.chord(*args, **kwargs)
      end

      # Returns a one-step rest with its length unset (e.g. `rest.n8`).
      def rest
        Sequence::Seq.new([nil])
      end

      # Returns a control signal that tweens through +values+, one per
      # +step+, along +curve+ (a MB::Sound::Curve name such as :smoothstep
      # (default), :elastic, :bounce, :squiggle, :steps, :back, a Curve, or a
      # Proc): automation for a cutoff, a detune, a mix, ... following the
      # session's tempo and timeline.  +step+ is the time between two
      # keyframes, not the length of the whole tween: a length (e.g.
      # `1.bar`, `2.beats`, `3.n16`; a plain number counts bars) or an
      # Array of lengths, one per value (cycling), so N values take N steps
      # per loop (N - 1 to reach the last one).  Values are keyframes: each is the
      # output at the start of its step, and the step tweens to the next
      # value (arriving as the next step starts, or after +time+ and then
      # holding).  The last value holds, or with +loop: true+ (default)
      # tweens back to the first over the last step; repeat a value to hold
      # it.  +overshoot:+ and +cycles:+ go to a named curve.
      #
      # A looping tween follows the timeline like any looping clip: launched
      # partway through it (e.g. at bar 2 of a 2-bar tween), it plays the
      # step the timeline is in, from wherever that step would be (since
      # 2026-10-11; it used to hold the first keyframe for the launch bar).
      # +align: :launch+ counts its cycles from the launch instead, so it
      # starts at its first keyframe wherever it is launched.
      #
      # Pitches (`300.hz`, Notes) tween in octaves and give Hz, so cutoffs
      # move evenly in pitch and overshoots stay above 0 Hz; plain numbers
      # tween linearly; +log:+ true or false overrides; mixing Pitches and
      # numbers raises.  Built on a Clip (Sequence::Clip#tween), so clips of
      # values tween the same way.
      #
      #     # 300 -> 3000 Hz during bar 1, 3000 -> 800 during bar 2, back to 300 during bar 3
      #     # (three bars per loop: the length is per step)
      #     bg :pad, 110.hz.saw.filter(:lowpass, cutoff: tween([300.hz, 3000.hz, 800.hz], 1.bar, curve: :elastic), quality: 4) * 0.3
      #     tween([0, 1, 0.3], 1.bar, curve: :bounce, loop: false)    # a bouncing mix knob, then 0.3
      #     tween([0, 12, 12, 7], 2.beats, curve: :steps, cycles: 4)  # stepped automation, holding 12 for a step
      #     tween([200, 1000], 1.bar, align: :launch)  # from 200 wherever it launches
      #     # 2 bars per step: up for 2 bars, down for 2 (5000 Hz after 2
      #     # bars, back at 100 Hz after 4), then 2 bars from 100 to 100
      #     # (the loop back to the first keyframe): 6 bars per loop
      #     tween([100.hz, 5000.hz, 100.hz], 2.bars)
      #     tween([100.hz, 5000.hz], 2.bars)   # up and down in 4 bars
      def tween(values, step = 1.bar, curve: :smoothstep, time: nil, overshoot: nil, cycles: nil, log: nil, loop: true, align: :timeline)
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
        Sequence::Clip.new(events, length: start, loop: loop, align: align).tween(time, curve: curve, overshoot: overshoot, cycles: cycles, log: log)
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

      # Moves the background playback timeline (see PlaybackMethods#bg) to
      # +target+ at a launch point (+on:+, +in:+, +at:+; see LaunchPoint;
      # now by default), through the Session's change queue, so it lands on
      # an exact frame, is journaled and undoable (undo goes back to where
      # the timeline was), and replays exactly from takes (see
      # Session#seek).  Sounds already playing jump with it.  Returns the
      # journal entry.
      #
      # +target+ is a bar number counting from 1 (fractions are allowed,
      # e.g. 2.5; through the meter map, see Sequence::Transport#meter), a
      # section or label of the song form playing (see FormMethods#flow;
      # the form plays on from there, see Form::Playback#seek_now), or a
      # marker (see FormMethods#marker and #markers).
      #
      #     seek 17                 # bar 17, now
      #     seek :top, on: :bar     # the form's label :top at the next bar line
      #     seek :drop, in: 2.beats
      def seek(target, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        session_command(nil, label: "seek #{target.inspect}", kind: :seek) { |session, time|
          session.seek(target, at: point, start_time: point.given? ? nil : time)
        }
      end

      # Moves the background playback timeline back to the start right
      # away (a reset, not a journaled seek; see #seek).  Returns the
      # transport.  (Named rewind because bin/sound.rb uses Pry's reset
      # command.)
      def rewind
        transport.seek(0)
      end

      # Sets the tempo in quarter notes per minute, or returns it if
      # +beats_per_minute+ is nil.  Clips that are already playing change
      # speed right away.  Inside a scheduled block (see ScheduleMethods), the
      # change happens at the block's scheduled time instead.  A script's
      # --bpm option scales the tempos a song sets (see
      # Sequence::Transport#override_bpm).  In a scheduled block, the rest of
      # the block reads the queued tempo (`bpm` returns it, and Durations,
      # #bounce, etc. count at it; see Sequence.current_transport).
      def bpm(beats_per_minute = nil)
        context = MB::Sound::Session.context
        beats_per_minute = transport.scaled_bpm(beats_per_minute) if beats_per_minute
        if beats_per_minute && context&.[](:batch)
          session, time = context[:session], context[:time]
          context[:batch] << -> { session.change_tempo(beats_per_minute, time: time) }
          context[:pending_bpm] = beats_per_minute
          return beats_per_minute
        end

        transport.bpm = beats_per_minute if beats_per_minute
        context&.[](:pending_bpm) || transport.bpm
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
