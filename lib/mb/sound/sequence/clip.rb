module MB
  module Sound
    module Sequence
      # A finite list of Events with a length, optionally looping forever.
      # Clips are immutable; every transformation returns a new Clip.
      #
      # Times and lengths are Rational numbers of whole notes (see Duration).
      # Clips are usually built with MB::Sound#seq or MB::Sound#grid rather
      # than created directly.
      #
      # Playback into a node graph uses the output methods (#trigger, #gate,
      # #velocity, #number, #hz, #tone, and #env), which create ClipNodes that
      # read the clip in sync with a Transport.
      #
      # Example (bin/sound.rb):
      #     riff = seq(C3, Ds3, G3, As3).n8 | seq(G3.n4, rest.n4)
      #     play riff.loop.tone.ramp.at(1) * riff.loop.env(0.005, 0.1, 0.5, 0.1)
      class Clip
        include Enumerable

        # Velocity for events that don't specify one (roughly MIDI velocity 96).
        DEFAULT_VELOCITY = 0.75

        # Velocity for accented events (e.g. 'X' in a Grid).
        ACCENT_VELOCITY = 1.0

        # The Events in this clip, sorted by start time.
        attr_reader :events

        # The length of the clip in whole notes.  This is the loop length for
        # a looping clip.
        attr_reader :length

        # The random seed used to decide whether events with a +probability+
        # play in each loop cycle.
        attr_reader :seed

        # Converts +obj+ to a Clip: Clips are returned as-is, Notes, Numerics,
        # and nil (a rest) become one-step Seqs.
        def self.from(obj)
          obj.is_a?(Clip) ? obj : Seq.new([obj])
        end

        # Creates a clip from a list of Events.  The +:length+ defaults to the
        # end of the last event.
        def initialize(events, length: nil, loop: false, seed: 0)
          @events = events.sort_by(&:start).freeze
          @length = (length || @events.map(&:end_time).max || 0).to_r
          @loop = !!loop
          @seed = Integer(seed)

          raise ArgumentError, 'A looping clip must have a positive length' if @loop && @length <= 0

          # How many loop cycles an event can span, for finding note-off events
          # that belong to earlier cycles.
          max_end = @events.map(&:end_time).max || 0
          @lookback = @length > 0 ? (max_end / @length).ceil : 0
        end

        # Yields each Event.
        def each(&block)
          @events.each(&block)
        end

        # Returns true if this clip repeats forever.
        def looping?
          @loop
        end

        # Returns a copy of this clip that repeats forever.  Pass a +:seed+ to
        # change which probabilistic events play in each cycle.
        def loop(seed: @seed)
          self.class.base_new(@events, length: @length, loop: true, seed: seed)
        end

        # Returns a non-looping clip that plays this clip followed by +other+
        # (a Clip, Note, Numeric, or nil for a quarter rest).
        def |(other)
          other = Clip.from(other)
          shifted = other.events.map { |e| e.with(start: e.start + @length) }
          Clip.new(@events + shifted, length: @length + other.length, seed: @seed)
        end

        # Returns a non-looping clip that plays this clip and +other+ at the
        # same time.  The length is the longer of the two.
        def &(other)
          other = Clip.from(other)
          Clip.new(@events + other.events, length: MB::M.max(@length, other.length), seed: @seed)
        end

        # Returns a clip that plays this clip +count+ times in a row.
        def repeat(count)
          raise ArgumentError, "Repeat count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
          Clip.new(
            Array.new(count) { |c| @events.map { |e| e.with(start: e.start + c * @length) } }.flatten,
            length: @length * count,
            seed: @seed
          )
        end
        alias * repeat

        # Returns a clip that repeats this clip until it fills +span+ (an
        # Integer note division or Rational whole notes), cutting the last
        # repetition short if needed.
        #
        # Example:
        #     C4.n32.fill(4)   # eight 32nd notes filling a quarter note
        def fill(span)
          span = Duration.whole_notes(span)
          raise ArgumentError, 'Cannot fill with an empty clip' if @length <= 0

          repeat((span / @length).ceil).truncate(span)
        end

        # Returns a clip with events after +span+ removed and events that
        # cross +span+ shortened to end there.
        def truncate(span)
          span = Duration.whole_notes(span)
          events = @events.select { |e| e.start < span }.map { |e|
            e.end_time > span ? e.with(length: span - e.start) : e
          }
          Clip.new(events, length: span, loop: @loop, seed: @seed)
        end

        # Splits every event into repeated hits of length +sub+ (an Integer
        # note division or Rational whole notes), keeping the original event
        # lengths.  The last hit of each event is shortened if needed.  Like
        # #ratchet, this applies to every note in the clip, and ordering
        # with #legato matters in the same way.
        #
        # +:velocity+ may be a Range to ramp velocity from the first hit to
        # the last (e.g. 0.3..1.0 for a crescendo).
        #
        # Examples:
        #     C4.n4.roll(32)   # eight 32nd notes filling a quarter note
        #     bass.roll(16)    # re-strike every note of bass on each 16th
        def roll(sub, velocity: nil)
          sub = Duration.whole_notes(sub)
          subdivide(velocity) { |e|
            starts = []
            t = 0r
            while t < e.length
              starts << [t, MB::M.min(sub, e.length - t)]
              t += sub
            end
            starts
          }
        end

        # Splits every event into +count+ equal hits, so each note is struck
        # +count+ times within its original length while the rhythm of the
        # clip stays the same.  See #roll for +:velocity+, and for splitting
        # by hit length instead of count.
        #
        # This applies to every note in the clip, so it can double up a whole
        # sequence.  Set step lengths first: on a Seq, ratchet resolves unset
        # lengths to quarter notes and returns a plain Clip.
        #
        # Ordering with #legato matters: legato before ratchet squeezes all
        # the hits into the shortened note, while legato after ratchet
        # shortens each hit, leaving a gap after every hit.
        #
        # Examples:
        #     C4.n4.ratchet(3)           # a quarter note triplet
        #     bass.stretch(4).ratchet(4) # half notes, each struck four times
        #     bass.ratchet(2).legato(0.5)  # every note doubled, each hit staccato
        def ratchet(count, velocity: nil)
          raise ArgumentError, "Ratchet count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
          subdivide(velocity) { |e|
            hit = e.length / count
            Array.new(count) { |i| [hit * i, hit] }
          }
        end

        # Returns a clip with all times and lengths multiplied by +factor+.
        def stretch(factor)
          factor = factor.to_r
          raise ArgumentError, 'Stretch factor must be positive' unless factor > 0
          map_clip(length: @length * factor) { |e| e.with(start: e.start * factor, length: e.length * factor) }
        end

        # Dotted rhythm: stretches the clip by 3/2.
        def d
          stretch(Duration::DOTTED)
        end
        alias dotted d

        # Double-dotted rhythm: stretches the clip by 7/4.
        def dd
          stretch(Duration::DOUBLE_DOTTED)
        end
        alias double_dotted dd

        # Triplet rhythm: stretches the clip by 2/3.
        def t
          stretch(Duration::TRIPLET)
        end
        alias triplet t

        # Returns a clip where every note sounds for +fraction+ of its length,
        # leaving the rest of each step silent (or overlapping the next note
        # if +fraction+ is more than 1).  Note start times don't change.
        #
        # Example:
        #     seq(C4, E4, G4).n8.legato(0.85)   # a little breathing room
        def legato(fraction)
          fraction = Clip.check_legato(fraction)
          map_clip { |e| e.with(length: e.length * fraction) }
        end

        # Short notes: legato(0.5).
        def staccato
          legato(1/2r)
        end

        # Validates a #legato fraction and returns it as a Rational.
        def self.check_legato(fraction)
          raise ArgumentError, "Legato must be a positive number (got #{fraction.inspect})" unless fraction.is_a?(Numeric) && fraction.finite? && fraction > 0
          fraction.is_a?(Float) ? fraction.rationalize(Rational(1, 10_000)) : fraction.to_r
        end

        # Returns a clip with every event's value shifted by +semitones+.
        def transpose(semitones)
          map_clip { |e| e.with(value: e.value + semitones) }
        end

        # Returns a clip with every event's velocity set to +velocity+ (0..1).
        def vel(velocity)
          map_clip { |e| e.with(velocity: velocity.to_f) }
        end

        # Returns note-on and note-off edges between +from+ (inclusive) and +to+
        # (exclusive) whole notes from the start of playback, as an Array of
        # [time, :on/:off, event, cycle] sorted by time.  Note-offs sort before
        # note-ons at the same time so repeated notes retrigger.
        #
        # Used by ClipNode.
        def edges(from, to)
          return [] if @length <= 0 && @events.empty?

          if @loop
            first = MB::M.max((from / @length).floor - @lookback, 0)
            last = (to / @length).floor
          else
            first = last = 0
          end

          out = []
          (first..last).each do |cycle|
            offset = cycle * @length
            @events.each_with_index do |e, idx|
              next unless plays?(e, cycle, idx)

              on = offset + e.start
              off = on + e.length
              out << [on, :on, e, cycle] if on >= from && on < to
              out << [off, :off, e, cycle] if off >= from && off < to
            end
          end

          out.sort_by { |time, type, _e, _c| [time, type == :off ? 0 : 1] }
        end

        # Returns the event that most recently started at or before +position+
        # whole notes (wrapping around for looping clips), or nil if none has.
        # Used to set held values when playback jumps.  Probability is
        # ignored.
        def event_at(position)
          return nil if @events.empty? || position < 0

          phase = @loop ? position % @length : position
          @events.reverse_each.find { |e| e.start <= phase } || (@loop ? @events.last : nil)
        end

        # Returns true if the event at +index+ plays in the given loop
        # +cycle+.  Events with a probability are decided by a random number
        # generator seeded from the clip's seed, the cycle, and the index, so
        # the same cycle always plays the same events.
        def plays?(event, cycle, index)
          return true if event.probability.nil? || event.probability >= 1
          Random.new((@seed * 1_000_003 + cycle) * 1_000_003 + index).rand < event.probability
        end

        # Creates a graph node that outputs a single-sample impulse at the
        # start of each event, scaled from velocity to +:range+.  Useful for
        # pinging filters or driving other trigger-based nodes.
        def trigger(range: 0.0..1.0, transport: nil)
          ClipNode::Trigger.new(self, range: range, transport: transport)
        end

        # Creates a graph node that outputs 1.0 while any event is playing and
        # 0.0 otherwise.
        def gate(transport: nil)
          ClipNode::Gate.new(self, transport: transport)
        end

        # Creates a graph node that outputs the velocity of the most recent
        # event, scaled to +:range+.
        def velocity(range: 0.0..1.0, transport: nil)
          ClipNode::Velocity.new(self, range: range, transport: transport)
        end

        # Creates a graph node that outputs the value (e.g. MIDI note number)
        # of the most recent event, starting with the first event's value.
        def number(transport: nil)
          ClipNode::Number.new(self, transport: transport)
        end
        alias value number

        # Creates a graph node that outputs the frequency in Hz of the most
        # recent event's note number.
        def hz(transport: nil)
          number(transport: transport).freq
        end
        alias frequency hz

        # Creates an oscillator (a Tone) whose frequency follows this clip's
        # notes.  Chain a wave type, e.g. `clip.tone.ramp`.
        def tone(transport: nil)
          hz(transport: transport).tone
        end

        # Creates an ADSR envelope node that triggers at the start of each
        # event and releases at its end.  Envelope peak follows velocity,
        # scaled to +:velocity+.  Times are in seconds.
        def env(attack = 0.005, decay = 0.1, sustain = 0.5, release = 0.1, velocity: 0.5..1.0, transport: nil)
          ClipNode::Envelope.new(
            self,
            attack: attack, decay: decay, sustain: sustain, release: release,
            velocity: velocity, transport: transport
          )
        end

        def to_s
          "#{self.class.name.rpartition('::').last}(#{Duration.format(@length)}#{' loop' if @loop}: #{@events.map(&:to_s).join(', ')})"
        end

        def inspect
          "#<#{to_s}>"
        end

        # Creates a plain Clip, even from a subclass like Seq.
        def self.base_new(*args, **kwargs)
          Clip.new(*args, **kwargs)
        end

        protected

        # Returns a Clip with each event transformed by the block.
        def map_clip(length: @length)
          Clip.new(@events.map { |e| yield e }, length: length, loop: @loop, seed: @seed)
        end

        private

        # Used by #roll and #ratchet.  The block returns [offset, length]
        # pairs for the hits of each event.
        def subdivide(velocity)
          map_events = @events.flat_map { |e|
            hits = yield e
            hits.map.with_index { |(offset, length), idx|
              v = e.velocity
              if velocity.is_a?(Range)
                frac = hits.length > 1 ? idx.to_f / (hits.length - 1) : 1.0
                v = velocity.begin + (velocity.end - velocity.begin) * frac
              elsif velocity
                v = velocity.to_f
              end

              e.with(start: e.start + offset, length: length, velocity: v)
            }
          }

          Clip.new(map_events, length: @length, loop: @loop, seed: @seed)
        end
      end
    end
  end
end
