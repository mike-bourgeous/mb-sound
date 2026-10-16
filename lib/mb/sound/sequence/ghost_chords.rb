module MB
  module Sound
    module Sequence
      # Implied harmony for clips (sound-design-1, 2026-10-11): #ghost_chords
      # moves a repeated melody's notes onto the tones of a chord
      # progression that never plays, so the hook keeps its rhythm and
      # contour while each bar implies a different chord (the "ghost
      # chords" trick from the maintainer's melody reference: write the
      # hook from a chord's tones, then nudge notes per bar to the nearest
      # tones of a silent i-iv-VII-VI; the bass can stay on the root).
      class Clip
        # How #ghost_chords breaks ties between two chord tones equally far
        # from a note.
        GHOST_TIES = [:contour, :down, :up].freeze

        # Returns a clip whose notes are moved to the nearest tones of a
        # silent chord progression, one chord per +per+ (a Duration such as
        # 1.bar or 2.beats, or whole notes; default one bar at the current
        # transport's meter), cycling through +chords+.  Rhythm, velocities,
        # and marks stay; only pitches move, each to the nearest note (any
        # octave) whose pitch class is in that span's chord.
        #
        # Chords are:
        # - scale degrees counted from 1 like Roman numerals (1 = i, 4 = iv,
        #   7 = VII in A minor), built in +scale+ (a Scale, a name like
        #   :minor, or an Array of offsets, with +root+) from every other
        #   scale note: +size+ 3 for triads, 4 for seventh chords;
        # - Arrays of Notes or note numbers, used as given (`[A3, C4, E4]`);
        # - nil (or Rest): no snapping during that span.
        #
        # +harmonic: true+ builds the degree chords from the scale with its
        # minor seventh raised (harmonic minor for :minor): V becomes major
        # and vii diminished with the leading tone, and melody notes snap to
        # the raised seventh where those chords imply it.
        #
        # Ties (a note halfway between two chord tones) follow +tie+:
        # :contour (default) goes the way the original melody moved into the
        # note (up from a lower previous note, down from a higher one or a
        # repeat; the first note of a looping clip compares with its last),
        # :down, or :up.  Notes shorter than +passing+ (a Duration or whole
        # notes; nil, the default, snaps every note) stay as passing notes.
        #
        # A looping clip repeats until the progression fits (the least
        # common multiple of its length and +per+ times the chord count, at
        # most MAX_GHOST_REPEATS copies) and keeps looping, so a one-bar
        # hook over four ghost chords becomes a four-bar loop; a
        # non-looping clip keeps its length, with chords following its
        # timeline.
        #
        #     hook = seq(A3, C4, R, E4, C4, R, A3, B3).n8.loop
        #     hook.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :a))      # Am, Dm, G, F
        #     hook.ghost_chords(1, 4, 5, 1, scale: :minor, root: :a, harmonic: true)  # Am, Dm, E, Am
        #     hook.ghost_chords([A3, C4, E4], [F3, A3, C4], per: 2.bars)   # explicit chords
        def ghost_chords(*chords, per: nil, scale: :minor, root: nil, size: 3, harmonic: false, tie: :contour, passing: nil)
          sc, classes = Clip.ghost_setup(chords, scale: scale, root: root, size: size, harmonic: harmonic, tie: tie)
          span = per.nil? ? Sequence.current_transport.bar_length.to_r : Duration.whole_notes(per)
          short = passing.nil? ? nil : Duration.whole_notes(passing)

          return ghost_generated(classes, sc, span, short, tie) if generated?

          clip = self
          if @loop
            total = Clip.rational_lcm(@length, span * chords.length)
            count = (total / @length).to_i
            raise ArgumentError, "ghost_chords would repeat #{self} #{count} times to fit the progression (most #{MAX_GHOST_REPEATS})" if count > MAX_GHOST_REPEATS
            clip = count > 1 ? repeated(count) : self
          end

          events = clip.events
          numbers = events.map { |e| Clip.ghost_number(e.value) }
          playing = numbers.each_index.select { |i| numbers[i] }

          moved = events.each_with_index.map do |e, i|
            n = numbers[i]
            next e if n.nil? || (short && e.length < short)

            pcs = classes[(e.start / span).floor % classes.length]
            next e if pcs.nil?

            pos = playing.index(i)
            prev = pos > 0 ? numbers[playing[pos - 1]] : (@loop ? numbers[playing.last] : nil)
            up = tie == :up || (tie == :contour && prev && prev < n)
            target = Clip.nearest_tone(n, pcs, sc.period, up)
            target == n ? e : e.with(value: Sequence.transpose_value(e.value, target - n))
          end

          Clip.new(moved, length: clip.length, loop: @loop, seed: @seed, align: @align, variations: clip.equal?(self) ? @variations : [], performed: @performed)
        end

        # Validates #ghost_chords' chords and options (shared with
        # MIDI::Stream#ghost_chords), returning [scale, pitch classes per
        # chord (nil for no chord)].
        def self.ghost_setup(chords, scale:, root:, size:, harmonic:, tie:)
          raise ArgumentError, 'ghost_chords needs at least one chord (scale degrees from 1, note Arrays, or nil)' if chords.empty?
          raise ArgumentError, "Tie must be one of #{GHOST_TIES.map(&:inspect).join(', ')} (got #{tie.inspect})" unless GHOST_TIES.include?(tie)
          raise ArgumentError, "Chord size must be a positive Integer (got #{size.inspect})" unless size.is_a?(Integer) && size > 0

          sc = Scale[scale, root]
          sc = Clip.harmonic_scale(sc) if harmonic
          [sc, chords.map { |c| Clip.ghost_chord_classes(c, sc, size) }]
        end

        # #ghost_chords of a generator clip (maintainer decision 5,
        # 2026-10-16: transforms work per cycle): each cycle's notes snap to
        # the chords of their place in the progression (cycle start plus
        # note start), with ties following the contour from the previous
        # cycle's last note, so the loop keeps its length and generates
        # forever.  Returns the new clip.
        def ghost_generated(classes, sc, span, short, tie)
          original = self
          values = @values && (@values + @values.flat_map { |v|
            n = Clip.ghost_number(v)
            next [] if n.nil?
            classes.compact.flat_map { |pcs|
              [true, false].map { |up| Sequence.transpose_value(v, Clip.nearest_tone(n, pcs, sc.period, up) - n) }
            }
          }).uniq

          map_cycles(values: values) { |events, cycle|
            numbers = events.map { |e| Clip.ghost_number(e.value) }
            # Before the first note: the previous cycle's last note (a
            # loop's first cycle compares with its own last, as for clips)
            prev = if cycle > 0
                     original.events_for(cycle - 1).filter_map { |e| Clip.ghost_number(e.value) }.last
                   elsif @loop
                     numbers.compact.last
                   end
            offset = @length * cycle
            events.each_with_index.map { |e, i|
              n = numbers[i]
              next e if n.nil?
              p = prev
              prev = n
              next e if short && e.length < short

              pcs = classes[((offset + e.start) / span).floor % classes.length]
              next e if pcs.nil?

              up = tie == :up || (tie == :contour && p && p < n)
              target = Clip.nearest_tone(n, pcs, sc.period, up)
              target == n ? e : e.with(value: Sequence.transpose_value(e.value, target - n))
            }
          }
        end
        protected :ghost_generated

        # The most copies #ghost_chords makes of a looping clip.
        MAX_GHOST_REPEATS = 64

        # The pitch classes (0...period, sorted) of +chord+ for
        # #ghost_chords, or nil for no chord.
        def self.ghost_chord_classes(chord, scale, size)
          case chord
          when nil then nil
          when Rest then nil
          when Integer
            raise ArgumentError, "Ghost chord degrees count from 1 like Roman numerals (got #{chord}; 1 is the tonic chord)" unless chord >= 1
            scale.chord(chord - 1, size).map { |n| n % scale.period }.uniq.sort
          when Array
            raise ArgumentError, 'A ghost chord Array needs at least one note' if chord.empty?
            chord.map { |n|
              v = ghost_number(n)
              raise ArgumentError, "Ghost chord notes are Notes or note numbers (got #{n.inspect})" if v.nil?
              v % scale.period
            }.uniq.sort
          else
            raise ArgumentError, "A ghost chord is a scale degree from 1, an Array of notes, or nil (got #{chord.inspect})"
          end
        end

        # The note number of an event value (a Note, Pitch, or number), or
        # nil for values that aren't pitches (e.g. drum names).
        def self.ghost_number(value)
          case value
          when Numeric then value
          when Pitch then value.respond_to?(:detuned_number) ? value.detuned_number : value.number
          else value.respond_to?(:number) ? value.number : nil
          end
        end

        # The note nearest +n+ whose pitch class (mod +period+) is in +pcs+;
        # between two equally near, the upper one if +up+, else the lower.
        def self.nearest_tone(n, pcs, period, up)
          best = nil
          pcs.each do |pc|
            below = n - (n - pc) % period
            [below, below + period].each do |c|
              d = (c - n).abs
              if best.nil? || d < best[0] || (d == best[0] && (up ? c > best[1] : c < best[1]))
                best = [d, c]
              end
            end
          end
          t = best[1]
          t.is_a?(Rational) || t.is_a?(Float) ? (t == t.round ? t.round : t) : t
        end

        # +scale+ with its minor seventh (10 semitones) raised to a major
        # seventh, e.g. natural to harmonic minor (#ghost_chords' +harmonic+).
        def self.harmonic_scale(scale)
          offsets = scale.offsets
          raise ArgumentError, "harmonic: true raises a scale's minor seventh, but #{scale} has none" unless offsets.include?(10) && !offsets.include?(11)
          Scale.new(offsets.map { |o| o == 10 ? 11 : o }, root: scale.root, period: scale.period)
        end

        # The least common multiple of two positive Rationals.
        def self.rational_lcm(a, b)
          a = a.to_r
          b = b.to_r
          Rational(a.numerator.lcm(b.numerator), a.denominator.gcd(b.denominator))
        end

        track_derivations(:ghost_chords)
      end
    end
  end
end
