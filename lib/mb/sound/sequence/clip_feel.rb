module MB
  module Sound
    module Sequence
      # Feel and chance for clips (the MIDI transforms project, 2026-10-10):
      # humanize, quantize, swing, probability and cycle conditions, and
      # #bake, which runs MIDI stream transforms (echo, arp, strum, ...)
      # offline into a new Clip.  Clips move notes both ways in time (they
      # know their future), unlike live stream transforms, which only delay
      # (user decision 7: humanize and quantize are mainly for clips).
      class Clip
        # The default largest timing offset of #humanize (+/-4 ms).
        HUMANIZE_TIME = MB::Sound::Length::Seconds.new(0.004)

        # Returns a clip with each note moved by a random amount up to
        # +time+ earlier or later (a Length like 4.ms, a Duration like
        # 1.n64, Rational whole notes, or an Integer note division; Lengths
        # are converted at the current tempo) and its velocity changed by
        # up to +:velocity+ (a fraction: 0.1 = 10% softer or louder).  The
        # default, +/-4 ms (HUMANIZE_TIME), stays within a few ms of the
        # grid (user, 2026-10-10: 1/64 was too much; 1/128 is 15.6 ms at
        # 120 BPM).  Random values come from +:seed+ (the clip's seed by
        # default, like #permute), so the same call gives the same feel.
        # Notes of a looping clip wrap around its length; others don't move
        # before 0.
        #
        # +:vary+ (default: true for looping clips; user, 2026-10-10) gives
        # a looping clip new offsets in every cycle (see #variations).  A
        # clip that isn't looping yet is humanized once, so humanize after
        # #loop for a loop that varies (`riff.loop.humanize`); pass
        # +vary: false+ for the same offsets every cycle.
        #
        #     riff.loop.humanize                    # +/-4 ms, new every cycle
        #     riff.humanize(1.n64, velocity: 0.15)
        #     riff.loop.humanize(8.ms, vary: false)
        def humanize(time = HUMANIZE_TIME, velocity: 0, seed: @seed, vary: nil)
          vary = @loop if vary.nil?
          amount = Duration.whole_notes(time)
          raise ArgumentError, "Humanize velocity must be from 0 to 1 (got #{velocity.inspect})" unless velocity.is_a?(Numeric) && velocity.between?(0, 1)
          seed = Integer(seed)
          if vary
            with_events(@events, variations: @variations + [Variation.new(name: "humanize(#{Duration.format(amount)}, seed: #{seed})", block: ->(events, cycle, clip) {
              Clip.humanized(events, amount, velocity.to_f, Clip.cycle_seed(seed, cycle), clip.length)
            })])
          else
            with_events(Clip.humanized(@events, amount, velocity.to_f, seed, @loop ? @length : nil))
          end
        end

        # Returns +events+ moved by up to +amount+ whole notes and with
        # velocities changed by up to +velocity+ (see #humanize).  +wrap+ is
        # the loop length, or nil.
        def self.humanized(events, amount, velocity, seed, wrap)
          rng = Random.new(seed)
          events.map { |e|
            shift = Duration.rational((rng.rand * 2 - 1) * amount.to_f)
            v = rng.rand * 2 - 1
            start = e.start + shift
            start = wrap ? start % wrap : MB::M.max(start, 0r)
            changes = { start: start }
            changes[:velocity] = MB::M.clamp(e.velocity * (1 + v * velocity), 1 / 127.0, 1.0) if velocity > 0 && e.velocity
            e.with(**changes)
          }
        end

        # Returns a clip with notes moved to the nearest step of +grid+ (an
        # Integer note division like 16, a Duration, or Rational whole
        # notes), or +:amount+ (0..1) of the way there.  Lengths stay, unless
        # +:ends+ is true (note ends move to the grid too, at least one step
        # after the start).  Notes of a looping clip wrap around its length.
        #
        #     played.quantize(16)
        #     played.quantize(1.n8.t, amount: 0.6)
        def quantize(grid = 16, amount: 1, ends: false)
          grid = Duration.whole_notes(grid)
          raise ArgumentError, "Quantize amount must be from 0 to 1 (got #{amount.inspect})" unless amount.is_a?(Numeric) && amount.between?(0, 1)
          amount = Duration.rational(amount)

          map_clip { |e|
            start = e.start + ((e.start / grid).round * grid - e.start) * amount
            length = e.length
            if ends
              stop = e.end_time + ((e.end_time / grid).round * grid - e.end_time) * amount
              length = MB::M.max(stop - start, amount == 1 ? grid : 0r)
              length = e.length if length <= 0
            end
            start = @loop ? start % @length : MB::M.max(start, 0r)
            e.with(start: start, length: length)
          }
        end

        # Returns a clip with swing: within each pair of +grid+ steps (an
        # Integer note division like 16, or a Duration), the second step
        # starts at +amount+ of the pair instead of halfway (0.5 is
        # straight, 0.58 a light shuffle, 2/3r a triplet feel).  Times in
        # between are stretched to match, so note starts and ends move
        # smoothly, and lengths follow.
        #
        #     beat.swing(0.6)          # 16th swing
        #     bass.swing(2/3r, 8)      # triplet 8th feel
        def swing(amount = 0.58, grid = 16)
          raise ArgumentError, "Swing must be between 0 and 1 (got #{amount.inspect})" unless amount.is_a?(Numeric) && amount > 0 && amount < 1
          grid = Duration.whole_notes(grid)
          amount = Duration.rational(amount)
          pair = grid * 2
          warp = ->(t) {
            base = (t / pair).floor * pair
            p = (t - base) / grid # 0..2 within the pair
            base + (p <= 1 ? p * amount * 2 : amount * 2 + (p - 1) * (2 - amount * 2)) * grid
          }

          map_clip { |e|
            start = warp.(e.start)
            e.with(start: start, length: MB::M.max(warp.(e.end_time) - start, 0r))
          }
        end

        # Returns a clip whose notes play with probability +p+ (0..1) in
        # each loop cycle (multiplied with any probability they had),
        # decided from the clip's seed, the cycle, and the note (#plays?).
        # Alias #maybe.
        #
        #     hats.chance(0.8)
        def chance(p)
          Clip.check_probability(p)
          map_clip { |e| e.with(probability: (e.probability || 1) * p) }
        end
        alias maybe chance

        # Returns a clip whose notes play only every +n+th loop cycle,
        # starting with cycle +from+ (counting from 1), like Elektron's
        # trig conditions (`every(4, from: 4)` is 4:4, a fill on every
        # fourth bar).  See Seq::Step#every for single steps (`C4.every(2)`).
        def every(n, from: 1)
          cond = Clip.check_condition(n, from)
          map_clip { |e| e.with(condition: cond) }
        end

        # Runs a MIDI stream transform offline and returns the result as a
        # Clip (user decision 8): visible (#to_s, #events), swappable, and
        # usable wherever clips are.  +fx+ is an unattached transform
        # (MB::Sound#echo, #arp, #strum, #chord, or a chain like
        # `echo(1.n8, 3).strum(20.ms)`) or a Proc (or block) taking a
        # MIDI::Stream and returning one.
        #
        # A looping clip bakes into a looping clip of the same length whose
        # cycle is the steady state of the loop played through the
        # transform: echoes from the end of the loop wrap to its start, and
        # notes that ring past the loop point overlap the next cycle, as
        # with any clip.  A non-looping clip keeps everything the transform
        # makes (its length grows to fit the tail).  Lengths in seconds are
        # read at the current tempo (Durations stay exact).  Probabilities,
        # conditions, and variations are played out: a loop bakes +:cycles+
        # cycles (1 by default) into one loop that many cycles long, so
        # pass e.g. `cycles: 4` to keep four different cycles of a loop
        # that varies (#variations) or plays notes by chance.
        #
        # Note: this may change with the library and live-performance work
        # (user, 2026-10-09).
        #
        #     riff.loop.bake(echo(3.n16, 3, pitch: 7.st, velocity: 0.6))
        #     chords.bake { |s| s.strum(1.n32).humanize(5.ms) }
        #     line.loop.permute(vary: true).bake(echo(1.n8, 2), cycles: 4)
        def bake(fx = nil, cycles: 1, &block)
          raise ArgumentError, "Bake cycles must be a positive Integer (got #{cycles.inspect})" unless cycles.is_a?(Integer) && cycles > 0
          fx ||= block
          raise ArgumentError, 'Pass a transform (e.g. echo(1.n8, 3)) or a block taking a MIDI::Stream' unless fx
          apply = fx.respond_to?(:apply) ? fx.method(:apply) : fx

          transport = Transport.new(bpm: Sequence.transport.bpm, bar_length: Sequence.transport.bar_length)
          wnps = transport.whole_notes_per_second

          unless @loop
            notes, = Clip.bake_notes(self, apply, transport)
            events = notes.map { |start, length, value, velocity| Event.new(start: start, length: length, value: value, velocity: velocity) }
            return Clip.new(events, length: [@length, *events.map(&:end_time)].max, seed: @seed)
          end

          # Find how many cycles the transform's tail spans, then play enough
          # cycles before and after the baked one for a steady state
          _, tail = Clip.bake_notes(unrolled(cycles, 0), apply, transport)
          warm = (tail / @length).ceil + 1
          notes, = Clip.bake_notes(unrolled(cycles, warm, warm + cycles + 1), apply, transport)

          # Copies warm...warm + cycles hold cycles 0...cycles, after warm-up
          # copies that play the same cycles in loop order
          from = @length * warm
          to = from + @length * cycles
          events = notes.select { |start, *| start >= from && start < to }.map { |start, length, value, velocity|
            Event.new(start: start - from, length: length, value: value, velocity: velocity)
          }
          Clip.new(events, length: @length * cycles, loop: true, seed: @seed, align: @align)
        end

        # A non-looping clip of +total+ copies of this loop's cycles
        # 0...+cycles+ in loop order, copy +first+ holding cycle 0 (copies
        # before it hold the cycles leading up to it), with probabilities
        # and conditions decided for those cycles.  Used by #bake.
        def unrolled(cycles, first, total = cycles)
          events = (0...total).flat_map { |j|
            cycle = (j - first) % cycles
            events_for(cycle).each_with_index.select { |e, idx| plays?(e, cycle, idx) }.map { |e, _|
              e.with(start: e.start + j * @length, probability: nil, condition: nil)
            }
          }
          Clip.new(events, length: @length * total, seed: @seed)
        end
        protected :unrolled

        # Plays +clip+ (not looping) through +apply+ at +transport+'s tempo
        # and returns [notes, tail]: notes as [start, length, value,
        # velocity] in whole notes, and how far (whole notes) the output
        # ran past the clip's end.  Used by #bake.
        def self.bake_notes(clip, apply, transport)
          wnps = transport.whole_notes_per_second
          stream = MIDI::Stream.new(MIDI::ClipSource.new(clip, transport: transport))
          out = apply.call(stream)
          out = MIDI::Stream.for(out)
          [out, *out.graph].grep(TimelineNode).uniq.each { |n| n.start_at(0r, transport: transport) }
          reader = out.reader

          step = 1/4r # seconds per read
          limit = (clip.length / wnps) + 600
          t = 0r
          open = Hash.new { |h, k| h[k] = [] }
          notes = []
          last = 0r
          until reader.ended? || t > limit
            reader.next(step).each do |e|
              last = e.time if e.note?
              case e.type
              when :note_on then open[[e.channel, e.note]] << e
              when :note_off
                on = open[[e.channel, e.note]].shift
                notes << [on.time * wnps, (e.time - on.time) * wnps, on.note, on.velocity] if on
              end
            end
            t += step
          end
          open.each_value { |list| list.each { |on| notes << [on.time * wnps, (last - on.time) * wnps, on.note, on.velocity] } }

          [notes.sort_by.with_index { |n, i| [n[0], i] }, MB::M.max(last * wnps - clip.length, 0r)]
        end

        DERIVATIONS_FEEL = [:humanize, :quantize, :swing, :chance, :maybe, :every, :bake].freeze
        track_derivations(*DERIVATIONS_FEEL)
      end
    end
  end
end
