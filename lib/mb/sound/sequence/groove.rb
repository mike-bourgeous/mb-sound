module MB
  module Sound
    module Sequence
      # A feel template (midi-import-1, 2026-10-28; the maintainer's
      # meaning (b) of "use its rhythm as a rhythm template"): how a played
      # clip sits against a grid, step by step: the mean timing offset of
      # its notes from each grid step (whole notes; negative is early) and
      # their mean velocity relative to the clip's mean, over the clip's
      # length (one cycle of steps).  Clip#groove with no template measures
      # one; `other.groove(template, amount:)` moves other notes onto the
      # template's grid positions plus its offsets (Feel.groove_target, the
      # quantize core) and scales their velocities, +amount+ of the way;
      # MIDI::Stream#groove delays live notes the same way.
      #
      #     feel = midi_clip('dnb take.mid', bars: 1).groove     # 16ths
      #     feel                                   # prints each step's offset and level
      #     beat.groove(feel, amount: 0.7)         # 70% of the feel
      #     riff.groove(feel, velocity: 0)         # timing only
      #     midi.groove(feel)                      # live notes (only delays)
      #
      # Steps without notes keep notes where they are (offset 0, level 1).
      # Grooves are values (their parts frozen) printing as `clip.groove` through
      # recipes, else as `groove_template(16, offsets: [...], levels: [...])`.
      class Groove
        # The grid step (whole notes).
        attr_reader :grid

        # Mean offsets from each step (Rational whole notes), one per step
        # of the template's cycle.
        attr_reader :offsets

        # Mean velocity of each step relative to the clip's mean (1.0 for
        # steps without notes).
        attr_reader :levels

        # Notes measured on each step.
        attr_reader :counts

        # Measures +clip+ (its first cycle) against a +grid+ (a note
        # division, default 16, or a Duration; +triplets: true+ for the
        # triplet grid of that division).
        def self.from_clip(clip, grid: Feel::GRID, triplets: false)
          raise ArgumentError, "A groove comes from a clip (got #{clip.class})" unless clip.is_a?(Clip)
          step = Groove.check_grid(grid, triplets)
          raise ArgumentError, 'A groove needs a clip with a length' unless clip.length > 0
          n = (clip.length / step).ceil
          raise ArgumentError, "A groove's cycle is at most 4096 steps (#{n} at #{Duration.format(step)})" if n > 4096
          sums = Array.new(n, 0r)
          vels = Array.new(n, 0.0)
          counts = Array.new(n, 0)
          events = clip.events_for(0)
          events.each do |e|
            target = Feel.quantize_step(e.start, step)
            i = (target / step).to_i % n
            sums[i] += e.start - target
            vels[i] += e.velocity
            counts[i] += 1
          end
          mean = events.empty? ? 1.0 : events.sum(&:velocity) / events.length
          offsets = sums.each_with_index.map { |s, i| counts[i] > 0 ? s / counts[i] : 0r }
          levels = vels.each_with_index.map { |v, i| counts[i] > 0 && mean > 0 ? v / counts[i] / mean : 1.0 }
          new(step, offsets, levels, counts: counts)
        end

        # The grid step for +grid+ (a division or Duration) and +triplets+.
        def self.check_grid(grid, triplets)
          step = Duration.whole_notes(grid)
          raise ArgumentError, "A groove's grid is a positive note division or length (got #{grid.inspect})" unless step.is_a?(Rational) && step > 0
          triplets ? step * 2/3r : step
        end

        def initialize(grid, offsets, levels = nil, counts: nil)
          @grid = Duration.whole_notes(grid)
          raise ArgumentError, 'A groove needs at least one step' if offsets.empty?
          levels ||= Array.new(offsets.length, 1.0)
          raise ArgumentError, 'A groove has one level per offset' unless levels.length == offsets.length
          @offsets = offsets.map { |o|
            raise ArgumentError, "Groove offsets are exact whole notes within half a step (got #{o.inspect})" unless o.is_a?(Numeric) && o.real? && !o.is_a?(Float) && o.abs <= @grid / 2
            o.to_r
          }.freeze
          @levels = levels.map { |l|
            raise ArgumentError, "Groove levels are positive numbers (got #{l.inspect})" unless l.is_a?(Numeric) && l.real? && l > 0
            l.to_f
          }.freeze
          @counts = (counts || Array.new(offsets.length, 0)).freeze
          @graph_recipe = nil # (not frozen: recipes remember the call that made it)
        end

        # Steps per cycle.
        def steps
          @offsets.length
        end

        # The length of one cycle (whole notes).
        def length
          @grid * steps
        end

        # [target, step index] for a note at +position+ (see
        # Feel.groove_target).
        def target(position, direction: :nearest)
          Feel.groove_target(position, @grid, @offsets, direction: direction)
        end

        # A clip with +clip+'s notes moved +amount+ of the way to the
        # template's positions (the nearest step plus its offset) and their
        # velocities scaled +velocity+ of the way to its levels (by default
        # the same as +amount+).  Lengths stay; loops wrap.
        def apply(clip, amount: 1, velocity: nil)
          Feel.check_fraction('Groove amount', amount)
          velocity = amount if velocity.nil?
          Feel.check_fraction('Groove velocity', velocity)
          amount = Duration.rational(amount)
          loop = clip.looping?
          len = clip.length
          clip.send(:map_clip) { |e|
            t, i = target(e.start)
            start = e.start + (t - e.start) * amount
            start = loop && len > 0 ? start % len : MB::M.max(start, 0r)
            e.with(start: start, velocity: Groove.level(e.velocity, @levels[i], velocity))
          }
        end

        # +v+ scaled +amount+ of the way to +level+ (1/127..1).
        def self.level(v, level, amount)
          return v if amount == 0 || level == 1.0
          MB::M.clamp(v * (1 + (level - 1) * amount), 1 / 127.0, 1.0)
        end

        def ==(other)
          other.is_a?(Groove) && other.grid == @grid && other.offsets == @offsets && other.levels == @levels
        end
        alias eql? ==

        def hash
          [@grid, @offsets, @levels].hash
        end

        # Each step's offset (percent of a step, + late) and level, e.g.
        # "groove(n16, 16 steps: +0% 1.10, -12% 0.84, ...)".
        def to_s
          label = (1 / @grid).denominator == 1 ? "n#{(1 / @grid).to_i}" : Duration.format(@grid)
          body = @offsets.each_with_index.map { |o, i|
            next '.' if @counts[i] == 0 && o == 0 && @levels[i] == 1.0
            pct = (o / @grid * 100).to_f.round
            "#{pct >= 0 ? '+' : ''}#{pct}% #{format('%.2f', @levels[i])}"
          }
          "groove(#{label}, #{steps} steps: #{body.join(', ')})"
        end

        def inspect
          "#<#{self}>"
        end

        # The `groove_template(...)` text making this groove.
        def to_ruby
          w = GraphNode::Recipe::RubyWriter.new(nil)
          div = (1 / @grid)
          grid = div.denominator == 1 ? div.to_i.to_s : w.literal(@grid)
          "groove_template(#{grid}, offsets: [#{@offsets.map { |o| w.literal(o) }.join(', ')}], levels: [#{@levels.map { |l| w.literal(l) }.join(', ')}])"
        end
      end

      class Clip
        # With no template: this clip's feel as a Groove (see Groove.from_clip;
        # +grid:+ a division, 16 by default, +triplets: true+).  With one (a
        # Groove, or a Clip to measure at +grid:+): a clip with this clip's
        # notes moved onto the template's grid positions plus its offsets
        # and their velocities scaled toward its levels, +amount+ of the way
        # (+velocity:+ for the velocities alone; see Groove#apply).
        #
        #     feel = take.groove
        #     beat.groove(feel, amount: 0.6)
        def groove(template = nil, amount: 1, velocity: nil, grid: Feel::GRID, triplets: false)
          return Groove.from_clip(self, grid: grid, triplets: triplets) if template.nil?
          template = Groove.from_clip(template, grid: grid, triplets: triplets) if template.is_a?(Clip)
          raise ArgumentError, "groove takes a Groove or a Clip to take one from (got #{template.class})" unless template.is_a?(Groove)
          template.apply(self, amount: amount, velocity: velocity)
        end
      end
    end
  end
end

module MB
  module Sound
    module Sequence
      class Kit
        # A Kit with every row moved onto a feel template (see Clip#groove;
        # a Groove, or a Clip to measure one from).
        #
        #     beat.groove(take.groove, amount: 0.7)
        def groove(template, amount: 1, velocity: nil, grid: Feel::GRID, triplets: false)
          template = Groove.from_clip(template, grid: grid, triplets: triplets) if template.is_a?(Clip)
          Kit.new(@rows.transform_values { |c| c.groove(template, amount: amount, velocity: velocity) })
        end
      end
    end
  end
end
