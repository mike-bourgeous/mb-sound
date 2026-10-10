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
      # A clip is a MIDI source (#stream, a MIDI::ClipSource that follows a
      # Transport's timeline).  Playback into a node graph uses the output
      # methods (#trigger, #gate, #velocity, #number, #hz/#tone, #freq,
      # #env, ...), which are nodes of a mono MB::Sound::Notes on the clip's
      # stream (#notes); #synth plays it polyphonically.
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

        # The clip this clip was made from by a transform like #transpose,
        # #legato, or #loop, or nil.  Session#swap uses
        # this to rebuild derived clips (e.g. a transposed layer) from a
        # replacement clip (see #rederive).
        attr_reader :source

        # Transforms whose results remember their #source (see
        # .track_derivations).
        DERIVATIONS = [
          :loop, :|, :&, :repeat, :*, :fill, :truncate, :roll, :ratchet, :stretch,
          :d, :dotted, :dd, :double_dotted, :t, :triplet,
          :legato, :staccato, :transpose, :vel,
          :reverse, :retrograde, :permute, :shuffle, :rotate,
        ].freeze

        # Wraps the named transform methods of this class so the clips they
        # return remember the clip and transform they came from (see #source
        # and #rederive).
        def self.track_derivations(*names)
          prepend(Module.new {
            names.each do |name|
              define_method(name) do |*args, **kwargs, &block|
                super(*args, **kwargs, &block).tap { |c|
                  c.derive_from(self, name, args, kwargs, block) if c.is_a?(Clip) && !c.equal?(self)
                }
              end
            end
          })
        end

        # Converts +obj+ to a Clip: Clips are returned as-is, Notes, Numerics,
        # and nil (a rest) become one-step Seqs.
        def self.from(obj)
          obj.is_a?(Clip) ? obj : Seq.new([obj])
        end

        # Where a looping clip's cycles are counted from (see #loop).
        ALIGNMENTS = [:timeline, :launch].freeze

        # How a looping clip lines up with the timeline: :timeline (cycles
        # counted from the start of the timeline) or :launch (cycles counted
        # from where it was launched).  See #loop.
        attr_reader :align

        # Per-cycle changes of a looping clip (see #variations): a +name+
        # for display and a +block+ called with (events, cycle, clip) that
        # returns the events for that cycle.  Starts are relative to the
        # cycle and may lie up to one clip length outside it: a negative
        # start plays at the end of the previous cycle (e.g. a downbeat
        # humanized early), a start past the length in the next one.
        Variation = Data.define(:name, :block)

        # Creates a clip from a list of Events.  The +:length+ defaults to the
        # end of the last event.  +:align+ only matters for looping clips
        # (see #loop).  +:variations+ are Variations applied per loop cycle
        # (see #variations).
        def initialize(events, length: nil, loop: false, seed: 0, align: :timeline, variations: [])
          @events = events.sort_by(&:start).freeze
          max_end = @events.map(&:end_time).max || 0
          @length = (length || max_end).to_r
          @loop = !!loop
          @seed = Integer(seed)
          @align = align
          @variations = variations.freeze
          @cycle_cache = {}

          raise ArgumentError, 'A looping clip must have a positive length' if @loop && @length <= 0
          raise ArgumentError, "Clip alignment must be one of #{ALIGNMENTS.map(&:inspect).join(', ')} (got #{align.inspect})" unless ALIGNMENTS.include?(align)

          # How many loop cycles an event can span, for finding note-off events
          # that belong to earlier cycles (one more with variations, which
          # may move events within their cycle).
          @lookback = @length > 0 ? (max_end / @length).ceil + (@variations.empty? ? 0 : 1) : 0
          # And how many later cycles can start early (variations may move
          # events up to a cycle before their own, see Variation).
          @lookahead = @variations.empty? ? 0 : 1
        end

        # Changes applied anew in every loop cycle (Variations), e.g. from
        # `permute(vary: true)` or `humanize(..., vary: true)`, so a loop
        # plays a different version each cycle, repeatably from the clip's
        # seed and the cycle number.  Transforms that map events (#transpose,
        # #legato, ...) keep them, applied after their own change; clips made
        # from several clips (#|, #&) play cycle 0's version.
        attr_reader :variations

        # The events of loop +cycle+ (0 for the first): #events with every
        # Variation applied (just #events without variations).
        def events_for(cycle)
          return @events if @variations.empty?

          cached = @cycle_cache[cycle]
          return cached if cached

          @cycle_cache.shift if @cycle_cache.length >= 8
          list = @variations.reduce(@events) { |evs, v| v.block.call(evs, cycle, self) }
          @cycle_cache[cycle] = list.sort_by(&:start).freeze
        end

        # Yields each Event.
        def each(&block)
          @events.each(&block)
        end

        # Returns true if this clip repeats forever.
        def looping?
          @loop
        end

        # Returns true if this clip loops from where it was launched rather
        # than in phase with the timeline (see #loop).
        def launch_aligned?
          @loop && @align == :launch
        end

        # Returns a copy of this clip that repeats forever.  Pass a +:seed+ to
        # change which probabilistic events play in each cycle.
        #
        # +:align+ says where the loop's cycles are counted from when it
        # plays in a node graph (MIDI::ClipSource):
        #
        # :timeline (default) - in phase with the transport's timeline, so
        #   loops launched at different times stay in sync, and a 3-beat
        #   loop launched on bar 2 starts a beat into its cycle.
        # :launch - from the moment the graph launches (or the swap that
        #   brings the clip in), so the loop always starts at its beginning.
        #   The anchor stays put when the timeline jumps: a seek or rewind
        #   keeps the loop in the same phase relative to its launch point
        #   (before the launch point it plays the cycles that would lead up
        #   to it), and only a new launch (#bg, #resume) or swap moves it.
        #   Same as rotating a :timeline loop by its launch position (see
        #   #rotate).
        #
        #     bg :ball, bounce_hits(3.beats).loop(align: :launch).synth { |v| ... }
        def loop(seed: @seed, align: @align)
          Clip.new(@events, length: @length, loop: true, seed: seed, align: align, variations: @variations)
        end

        # Returns a non-looping clip that plays this clip followed by +other+
        # (a Clip, Note, Numeric, or nil for a quarter rest).
        def |(other)
          other = Clip.from(other)
          shifted = other.first_cycle_events.map { |e| e.with(start: e.start + @length) }
          Clip.new(first_cycle_events + shifted, length: @length + other.length, seed: @seed)
        end

        # Returns a non-looping clip that plays this clip and +other+ at the
        # same time.  The length is the longer of the two.
        def &(other)
          other = Clip.from(other)
          Clip.new(first_cycle_events + other.first_cycle_events, length: MB::M.max(@length, other.length), seed: @seed)
        end

        # The events of cycle 0 (see #events_for) with early starts (see
        # Variation) at 0, as cycle 0 plays them.  Used where a clip's
        # first cycle becomes a non-looping clip (#|, #&).
        def first_cycle_events
          list = events_for(0)
          return list unless list.any? { |e| e.start < 0 }
          list.map { |e| e.start < 0 ? e.with(start: 0r) : e }
        end
        protected :first_cycle_events

        # Returns a non-looping clip that plays this clip +count+ times in a
        # row.  Repeating a looping clip warns, since the result is finite;
        # call #loop on the result to keep it looping.
        def repeat(count)
          warn "repeat makes a finite clip, so #{self} will stop looping; call .loop on the result to keep looping" if @loop
          repeated(count)
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
          with_events(events, length: span)
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
        # Slid notes (Seq::Step#slide, `~C4`) keep their overlap.
        #
        # Example:
        #     seq(C4, E4, G4).n8.legato(0.85)   # a little breathing room
        def legato(fraction)
          fraction = Clip.check_legato(fraction)
          map_clip { |e| e.slid ? e : e.with(length: e.length * fraction) }
        end

        # Short notes: legato(0.5).
        def staccato
          legato(1/2r)
        end

        # Validates a #legato fraction and returns it as a Rational.
        def self.check_legato(fraction)
          raise ArgumentError, "Legato must be a positive number (got #{fraction.inspect})" unless fraction.is_a?(Numeric) && fraction.finite? && fraction > 0
          Duration.rational(fraction)
        end

        # Returns +order+ if it is a permutation of 0...+count+ (raising an
        # error if not), or a random permutation from +seed+ if +order+ is
        # nil.  Used by #permute.
        def self.check_permutation(order, count, seed)
          return (0...count).to_a.shuffle(random: Random.new(seed)) if order.nil?

          unless order.is_a?(Array) && order.sort == (0...count).to_a
            raise ArgumentError, "Order must be an Array of the indices 0 to #{count - 1}, each once (got #{order.inspect})"
          end
          order
        end

        # Returns a clip with every event's value shifted by +semitones+.
        def transpose(semitones)
          map_clip { |e| e.with(value: Sequence.transpose_value(e.value, semitones)) }
        end

        # Returns a clip that plays this clip backward: each event ends where
        # it used to start, measured from the end of the clip, so the rhythm
        # is mirrored too (a rest at the end moves to the start).  Also
        # available as #retrograde.
        #
        #     seq(C4, E4, G4.n4).n8.reverse   # G4 (quarter), E4, C4
        def reverse
          map_clip { |e| e.with(start: MB::M.max(@length - e.end_time, 0r)) }
        end
        alias retrograde reverse

        # Returns a clip with the same rhythm but its notes (values,
        # velocities, and probabilities) moved to other events.  Also
        # available as #shuffle.
        #
        # Pass an Array with the index of the note to play at each event
        # (in start order), e.g. [2, 0, 1], or nothing to shuffle randomly.
        # Random orders are repeatable: they come from +:seed+, which
        # defaults to the clip's seed, so pass different seeds to try other
        # orders.
        #
        #     seq(C4, E4, G4, B4).n8.permute([3, 2, 0, 1])   # B4, G4, C4, E4
        #     seq(C4, E4, G4, B4).n8.permute(seed: 3)
        #
        # With +vary: true+, a looping clip plays a new random order in
        # every cycle, repeatable from +:seed+ and the cycle number (see
        # #variations): `riff.loop.permute(vary: true)`.
        def permute(order = nil, seed: @seed, vary: false)
          if vary
            raise ArgumentError, 'permute(vary: true) picks its own orders; leave out the order' if order
            seed = Integer(seed)
            return with_events(@events, variations: @variations + [Variation.new(name: "permute(seed: #{seed})", block: ->(events, cycle, _clip) {
              Clip.permuted(events, Clip.check_permutation(nil, events.length, Clip.cycle_seed(seed, cycle)))
            })])
          end

          order = Clip.check_permutation(order, @events.length, seed)
          with_events(Clip.permuted(@events, order))
        end

        # Returns +events+ with their notes (values, velocities,
        # probabilities, conditions) moved by +order+ (see #permute).
        def self.permuted(events, order)
          events.each_with_index.map { |slot, idx|
            note = events[order[idx]]
            slot.with(value: note.value, velocity: note.velocity, probability: note.probability, condition: note.condition)
          }
        end

        # A seed for loop +cycle+ of something seeded with +seed+ (used by
        # per-cycle Variations).
        def self.cycle_seed(seed, cycle)
          ((seed * 1_000_003 + cycle) * 999_983) & ((1 << 62) - 1)
        end
        alias shuffle permute

        # Returns a clip with its events moved +amount+ later (a Duration, or
        # a Numeric number of whole notes, which may be negative to move
        # earlier), wrapping around the clip's length, which stays the same.
        # Events pushed past the end start again from the beginning, so a
        # looping clip plays the same cycle starting at a different point.
        #
        #     seq(C4, E4, G4, B4).n4.rotate(1.beat)        # B4, C4, E4, G4
        #     seq(C4, E4, G4, B4).n4.rotate(-1/4r)         # E4, G4, B4, C4
        #     ball.loop.rotate(2.bars)                     # a loop that starts on bar 3 (from 1)
        def rotate(amount)
          raise ArgumentError, 'Cannot rotate a clip without a length' if @length <= 0

          shift = amount.is_a?(Duration) ? amount.whole_notes : Duration.rational(amount)
          shift %= @length
          return with_events(@events) if shift == 0

          map_clip { |e| e.with(start: (e.start + shift) % @length) }
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
        # Events of a loop's variations may start before their cycle (see
        # Variation, e.g. a downbeat humanized early): they play at the end
        # of the previous cycle, so each plays exactly once in continuous
        # playback.  Cycle 0 has no previous cycle, so its early notes play
        # at 0.  When +:early+ is true (the first read after a launch, seek,
        # or swap, from MIDI::ClipSource), notes of cycles starting at or
        # after +from+ whose early start is before +from+ play at +from+
        # instead of being lost (a downbeat humanized early still sounds
        # when a loop is launched on it).
        #
        # Used by MIDI::ClipSource.
        def edges(from, to, early: false)
          return [] if @length <= 0 && @events.empty?

          if @loop
            first = MB::M.max((from / @length).floor - @lookback, 0)
            last = (to / @length).floor + @lookahead
          else
            first = last = 0
          end

          out = []
          (first..last).each do |cycle|
            offset = cycle * @length
            events_for(cycle).each_with_index do |e, idx|
              next unless plays?(e, cycle, idx)

              on = offset + e.start
              off = on + e.length
              if on < offset
                # An early note of this cycle
                if cycle == 0
                  next if off <= 0
                  on = 0r
                elsif early && offset >= from && on < from && off > from
                  on = from
                end
              end
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
          events = @loop ? events_for((position / @length).floor) : @events
          events.reverse_each.find { |e| e.start <= phase } || (@loop ? events.last : nil)
        end

        # Returns true if the event at +index+ plays in the given loop
        # +cycle+.  Events with a probability are decided by a random number
        # generator seeded from the clip's seed, the cycle, and the index, so
        # the same cycle always plays the same events.
        def plays?(event, cycle, index)
          if (cond = event.condition)
            n, from = cond
            return false if cycle < from - 1 || (cycle - (from - 1)) % n != 0
          end

          return true if event.probability.nil? || event.probability >= 1
          Random.new((@seed * 1_000_003 + cycle) * 1_000_003 + index).rand < event.probability
        end

        # Validates a probability (0..1) for #chance and Seq::Step#chance.
        def self.check_probability(p)
          raise ArgumentError, "A probability is a number from 0 to 1 (got #{p.inspect})" unless p.is_a?(Numeric) && p >= 0 && p <= 1
          p
        end

        # Validates a cycle condition for #every and Seq::Step#every,
        # returning [n, from].
        def self.check_condition(n, from)
          raise ArgumentError, "every needs a positive Integer (got #{n.inspect})" unless n.is_a?(Integer) && n > 0
          raise ArgumentError, "every's from: is a cycle from 1 (got #{from.inspect})" unless from.is_a?(Integer) && from > 0
          [n, from].freeze
        end

        # Returns a MIDI::Stream playing this clip: a new MIDI::ClipSource
        # (each clip event becomes a note-on and a note-off on +:channel+)
        # at the tempo of +:transport+ (the session's by default).  A clip is
        # just a MIDI source, so anything that reads streams plays clips:
        # Notes (#notes and the output methods below), MB::Sound::Synth
        # (#synth), and MIDI transforms (`clip.stream.transpose(12)`).
        #
        # Each call makes a new source, since a source follows the timeline
        # of the graph that plays it (see Sequence::TimelineNode): a clip can
        # play in several players at once, each in its own place.
        def stream(channel: 0, transport: nil)
          MIDI::Stream.new(MIDI::ClipSource.new(self, channel: channel, transport: transport))
        end

        # Returns a MB::Sound::Notes on a new #stream of this clip: the mono
        # (last-note priority) signal DSL also used for MIDI and synth voices
        # (v.gate, v.trigger, v.number, v.hz, v.env, ...).  The output
        # methods below each make their own Notes; call this once to share
        # one between several nodes (clips have no pedals, so it skips the
        # sustain pedal transform; see Notes.new):
        #
        #     n = bass.notes
        #     play n.hz.saw * n.amp_env(0.003, 0.15, 0.6, 0.08)
        def notes(transport: nil)
          MB::Sound::Notes.new(stream(transport: transport), sustain: false)
        end

        # A single-sample impulse at the start of each event, valued at its
        # velocity (0..1; a Notes::Trigger).  Useful for pinging filters or
        # resetting other trigger-based nodes.
        def trigger(transport: nil)
          notes(transport: transport).trigger
        end

        # 1.0 while any event is playing and 0.0 otherwise (a Notes::Gate).
        def gate(transport: nil)
          notes(transport: transport).gate
        end

        # The velocity of the most recent event (0..1 scaled to +:range+).
        def velocity(range: 0.0..1.0, transport: nil)
          v = notes(transport: transport).velocity
          range == (0.0..1.0) ? v : v * (range.end - range.begin).to_f + range.begin.to_f
        end

        # The value (e.g. MIDI note number) of the most recent event,
        # starting with the first event's value (a Notes::Number).
        def number(transport: nil)
          notes(transport: transport).number
        end
        alias value number

        # A control signal that tweens between the clip's values along a
        # +curve+ from the tweening library (MB::Sound::Curve; a name like
        # :elastic, :bounce, :squiggle, :steps, a Curve, or a Proc), e.g.
        # automation for a cutoff, a detune, or a mix.  Each event is a
        # keyframe: the output is the event's value at its start and tweens
        # to the next event's value, arriving as the next event starts (or
        # after +time+, then holding; a Duration follows the tempo; also
        # seconds, Lengths, or a node of seconds).  The last value holds,
        # or with a looping clip tweens back to the first over the last
        # step.  Repeat a value to hold it for a step.  Events starting
        # together count once (the last one).  +overshoot:+ and +cycles:+
        # go to a named curve.  A Notes::Glide underneath; see also
        # MB::Sound.tween.
        #
        # Values (see .tween_values): plain numbers tween linearly.
        # Pitches (`300.hz`, Notes like A4) tween in octaves and the output
        # is in Hz, so frequencies and cutoffs move evenly in pitch and
        # overshoots stay above 0 Hz.  +log:+ overrides: true tweens plain
        # (positive) numbers in octaves, false tweens Pitches linearly in
        # Hz.  Mixing Pitches and plain numbers raises (say which you mean
        # with `.hz` or plain numbers).  Seqs store Notes as note numbers,
        # so `seq(A3, A4).tween` tweens note numbers (in semitones).
        #
        #     cutoff = seq(300.hz, 3000.hz, 900.hz, 1800.hz).n2.loop.tween(curve: :elastic)
        #     bg :pad, 110.hz.saw.filter(:lowpass, cutoff: cutoff, quality: 3) * 0.3
        #     seq(0, 12, 12, 0).n2.tween(1.n8, curve: :bounce)    # bounce to each value in an eighth
        def tween(time = nil, curve: :smoothstep, overshoot: nil, cycles: nil, log: nil, transport: nil)
          keys = @events.group_by(&:start).sort_by(&:first).map { |start, es| [start, es.last.value] }
          raise ArgumentError, 'A tween needs at least one value' if keys.empty?

          values, log = Clip.tween_values(keys.map(&:last), log)
          values = values.map { |v| Math.log2(v) } if log

          # Keyframes as a glide clip: at each start, glide to the next value
          # (around the loop if looping), from the first value
          starts = keys.map(&:first)
          n = starts.length
          gaps = starts.each_with_index.map { |st, i| i + 1 < n ? starts[i + 1] - st : (@loop ? @length - st + starts[0] : nil) }
          events = (@loop ? n : [n - 1, 1].max).times.map { |i|
            target = n == 1 ? values[0] : values[(i + 1) % n]
            gap = gaps[i] || [@length - starts[i], 1/64r].max
            Event.new(start: starts[i], length: gap, value: target, velocity: DEFAULT_VELOCITY)
          }
          glide_clip = Clip.new(events, length: @length, loop: @loop, seed: @seed, align: @align)

          notes = glide_clip.notes(transport: transport)
          name = "tween #{Curve.from(curve, **{ overshoot: overshoot, cycles: cycles }.compact)}"
          g = Notes::Glide.new(
            notes.note_stream, time: glide_clip.send(:tween_time, time, transport), from: values[0],
            shape: curve, overshoot: overshoot, cycles: cycles, notes: notes
          ).named(name)
          log ? (2 ** g).named("#{name} (octaves)") : g
        end

        # Checks tween +values+ and resolves +log+ (nil: automatic) for
        # Clip#tween: returns [Floats, log].  Pitches become frequencies in
        # Hz and tween in octaves unless +log+ is false; plain numbers tween
        # linearly unless +log+ is true.  Mixed Pitches and numbers raise.
        def self.tween_values(values, log)
          pitches = values.count { |v| v.is_a?(MB::Sound::Pitch) }
          if pitches > 0 && pitches < values.length
            raise ArgumentError, "Tween values mix Pitches and plain numbers (#{values.map(&:to_s).join(', ')}); use Pitches (e.g. 300.hz) or numbers throughout"
          end
          unless pitches > 0 || values.all?(Numeric)
            raise ArgumentError, "Tween values must be numbers or Pitches (got #{values.inspect})"
          end

          log = pitches > 0 if log.nil?
          floats = values.map { |v| v.is_a?(MB::Sound::Pitch) ? v.frequency.to_f : v.to_f }
          raise ArgumentError, "Tweens in octaves need positive values (got #{floats.inspect})" if log && !floats.all?(&:positive?)
          [floats, !!log]
        end

        # A Pitch following this clip's notes (a Notes::NotePitch, like
        # `v.hz` in a synth voice): chain a wave type (`clip.hz.ramp`,
        # `clip.tone.square.at(0.5)`) or `.transpose(7)`.  Its oscillators
        # reset their phase at each note (key sync) unless they are #free.
        # Used directly as a signal, it plays a sine, like any Pitch.
        def hz(transport: nil)
          notes(transport: transport).hz
        end
        alias tone hz
        alias pitch hz

        # A node giving the frequency in Hz of the most recent event's note
        # (a Notes::Frequency), for arithmetic.  See also #period.
        def freq(transport: nil)
          notes(transport: transport).freq
        end
        alias frequency freq

        # Creates a graph node that outputs the period in seconds (one cycle,
        # 1 / #freq) of the most recent event's note, e.g. for a delay that
        # resonates at each note's pitch.  Use `smoothing: false` so the
        # delay jumps to each new note instead of gliding.
        #
        # Example (bin/sound.rb), a comb resonator plucked by noise bursts:
        #     notes = seq(A2, E3, C3).n4.loop
        #     excite = noise.at(1) * notes.env(0, 0.004, 0, 0.001)
        #     bg :string, excite.delay(notes.period, feedback: 0.98, dry: 1, wet: 1, smoothing: false) * 0.3
        #
        # The delay's feedback is a plain gain, so this rings brightly like
        # a comb filter rather than a damped Karplus-Strong string.
        def period(transport: nil)
          1 / freq(transport: transport)
        end

        # An envelope (a Notes::NoteEnvelope, an MB::Sound::Envelope) that
        # starts at each event and releases at its end, with the
        # EnvelopeMethods#env preset: positional attack, decay, sustain, and
        # release (5 ms, 0.2 s, 0.7, 0.3 s by default), :analog curves,
        # velocity sensitivity 0.5..1, and any Envelope option (+:curve+,
        # +:sensitivity+, +:velocity_scale+, +:legato+, +:hold+, ...).
        #
        # Overlapping events play mono, like a synth voice: each event
        # retriggers the envelope from its current level, and it releases
        # when no event is playing.  GM2 time scaling (CC 72/73/75) is off,
        # since clips carry no controllers (+gm: true+ turns it on).
        #
        #     bass.env(0.003, 0.15, 0.6, 0.08, curve: :snappy)
        #     hats.env(0, 0.03, 0, 0.02, sensitivity: 0.2..1)
        def env(attack = nil, decay = nil, sustain = nil, release = nil, gm: false, transport: nil, **options)
          notes(transport: transport).env(attack, decay, sustain, release, gm: gm, **options)
        end
        alias envelope env

        # An amplitude envelope (see #env and EnvelopeMethods#amp_env).
        def amp_env(attack = nil, decay = nil, sustain = nil, release = nil, gm: false, transport: nil, **options)
          notes(transport: transport).amp_env(attack, decay, sustain, release, gm: gm, **options)
        end
        alias amp_envelope amp_env

        # An FM index envelope (see #env and EnvelopeMethods#fm_env).
        def fm_env(attack = nil, decay = nil, sustain = nil, release = nil, gm: false, transport: nil, **options)
          notes(transport: transport).fm_env(attack, decay, sustain, release, gm: gm, **options)
        end
        alias fm_envelope fm_env

        # A filter cutoff multiplier envelope (see #env and
        # EnvelopeMethods#filter_env).
        def filter_env(attack = nil, decay = nil, sustain = nil, release = nil, gm: false, transport: nil, **options)
          notes(transport: transport).filter_env(attack, decay, sustain, release, gm: gm, **options)
        end
        alias filt_env filter_env
        alias filter_envelope filter_env

        # A polyphonic MB::Sound::Synth playing this clip: the block builds
        # one voice from a Notes (+v+, as in synth scripts) and its lane
        # index, and a MIDI::Allocator gives each note to a free voice at
        # runtime (stealing the oldest released voice when all +:voices+
        # are busy), so a note's release can ring on one voice while the
        # next note starts on another.  +options+ go to Synth.new (+:spares+,
        # +:steal+, +:mono+, +:seed+, ...); +:tail+ is 0, so a non-looping
        # clip's synth ends when its last voice goes quiet.
        #
        # Returns the Synth, or a Channels bundle of its outputs if voices
        # return several channels (e.g. stereo pairs).
        #
        # Example (bin/sound.rb):
        #     chords = seq(A2, F2, C3, G2).n1.legato(0.95).loop
        #     bg :pad, chords.synth(voices: 3) { |v|
        #       (v.hz.ramp.at(1) + v.hz.transpose(7).ramp.at(0.7)) * v.env(0.6, 1.0, 0.8, 2.5) * 0.3
        #     }
        def synth(voices: 2, **options, &block)
          raise ArgumentError, 'Pass a block that builds a graph for one voice' unless block

          s = MB::Sound::Synth.new(self, voices: voices, **{ tail: 0 }.merge(options), &block)
          s.outputs.length > 1 ? GraphNode::Channels.new(s.outputs) : s
        end

        # Returns this clip, the clip it was made from (see #source), that
        # clip's source, and so on.
        def lineage
          list = [self]
          list << list.last.source while list.last.source
          list
        end

        # Applies the transform that made this clip from its #source to
        # +clip+ instead, e.g. returning clip.transpose(12) for a clip made
        # with transpose(12).  Raises an error for clips without a source.
        def rederive(clip)
          raise ArgumentError, "#{self} wasn't made from another clip" unless @derivation
          name, args, kwargs, block = @derivation
          clip.public_send(name, *args, **kwargs, &block)
        end

        def to_s
          vary = @variations.empty? ? '' : " varying #{@variations.map(&:name).join(', ')}"
          "#{self.class.name.rpartition('::').last}(#{Duration.format(@length)}#{' loop' if @loop}#{' from launch' if launch_aligned?}#{vary}: #{@events.map(&:to_s).join(', ')})"
        end

        def inspect
          "#<#{to_s}>"
        end

        protected

        # Records that this clip was made by calling +name+ on +source+ with
        # +args+ and +kwargs+ (see #source).  Returns self.
        def derive_from(source, name, args, kwargs, block = nil)
          @source = source
          @derivation = [name, args.freeze, kwargs.freeze, block].freeze
          self
        end

        # Returns a Clip with the given +events+ that keeps this clip's
        # looping and seed.
        def with_events(events, length: @length, variations: @variations)
          Clip.new(events, length: length, loop: @loop, seed: @seed, align: @align, variations: variations)
        end

        # Returns a Clip with each event transformed by the block.
        def map_clip(length: @length)
          with_events(@events.map { |e| yield e }, length: length)
        end

        private

        # The glide time for #tween: +time+ as given (a Duration becomes a
        # tempo-following TempoNode), or by default each event's distance to
        # the next start, in seconds at the current tempo.
        def tween_time(time, transport)
          case time
          when Duration then TempoNode.new(time, mode: :seconds, transport: transport)
          when nil
            gaps = step_gaps
            raise ArgumentError, 'A tween needs events, or an explicit time' if gaps.empty?
            if gaps.values.uniq.length == 1
              TempoNode.new(Duration.new(gaps.values.first), mode: :seconds, transport: transport)
            else
              # Each event's gap as a value, read when the event starts
              gap_clip = Clip.new(@events.map { |e| e.with(value: gaps.fetch(e.start, gaps.values.last).to_f) }, length: @length, loop: @loop, seed: @seed, align: @align)
              gap_clip.number(transport: transport) * TempoNode.new(Duration.new(1r), mode: :seconds, transport: transport)
            end
          else time
          end
        end

        # The distance (whole notes) from each distinct event start to the
        # next one (around the loop for looping clips; the last event's
        # length otherwise), as a Hash of start => gap.
        def step_gaps
          starts = @events.map(&:start).uniq.sort
          return {} if starts.empty?

          starts.each_with_index.to_h { |st, i|
            nxt = starts[i + 1]
            gap = if nxt
                    nxt - st
                  elsif @loop
                    @length - st + starts.first
                  else
                    @events.select { |e| e.start == st }.map(&:length).max
                  end
            [st, gap]
          }.select { |_, g| g > 0 }
        end

        # Returns a non-looping clip that plays this clip +count+ times in a
        # row, without #repeat's warning for looping clips.
        def repeated(count)
          raise ArgumentError, "Repeat count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
          # Variations and cycle conditions unroll: copy c plays cycle c's
          # version (probabilities stay, decided per copy as before)
          Clip.new(
            Array.new(count) { |c|
              events_for(c).select { |e| e.condition.nil? || plays?(e.with(probability: nil), c, 0) }
                .map { |e| e.with(start: MB::M.max(e.start + c * @length, 0r), condition: nil) }
            }.flatten,
            length: @length * count,
            seed: @seed
          )
        end

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

          with_events(map_events)
        end

        track_derivations(*DERIVATIONS)
      end
    end
  end
end
