module MB
  module Sound
    module GraphNode
      # Amplitude modulation: #tremolo (aliases #trem, #amplitude_modulation),
      # a Tremolo node driven by a library LFO (a Tone made with Tone#lfo, a
      # tempo-synced Duration#lfo, or a Tone reading a drawn Wavetable), with
      # dry/wet through BlendMethods#blend.  Handles channels itself (each
      # channel's LFO is offset by +stereo_phase:+), so it isn't run per
      # channel (ChannelDispatch::EXCLUDED).  Included in GraphNode and
      # Channels.
      module TremoloMethods
        # Named LFO shapes (Notes::LFO_SHAPES, the per-voice LFO's names:
        # :sine, :triangle, :saw (rising), :square, :random (sample and
        # hold), with their aliases).
        def self.shapes
          MB::Sound::Notes::LFO_SHAPES
        end

        # Samples per cycle of a drawn shape's wavetable (a multiple of 1000,
        # so points at thousandths of a cycle, Sony Amplitude Modulation's
        # resolution, and the default seam's ends land on table samples).
        DRAWN_SIZE = 16000

        # The seam (fraction of a cycle) that `seam: true` gives: the width
        # of Sony Amplitude Modulation's "blend graph edges" (5% before the
        # end of the cycle to 5% after its start).  Its blend is the :jump
        # seam mode (measured, the .acd study 2026-11-11); the :line mode
        # matches it only for a sawtooth (straight through the wrap).
        DEFAULT_SEAM = 0.1

        # Ways #tremolo's +:seam+ blends the wrap (+:seam_mode+): :line
        # draws a straight line across the seam whatever the shape does
        # there, :jump takes out only the jump between the shape's end and
        # start, spread over the seam, keeping the shape's own lines.
        SEAM_MODES = %i[line jump].freeze

        # Wavetables of drawn shapes, by [points, seam] (see .drawn_table).
        @drawn = {}
        @drawn_lock = Mutex.new

        # Most drawn tables kept (the oldest goes first).
        DRAWN_KEPT = 64

        # Tremolo: swings this signal's level down by +depth:+ along an LFO.
        # The level moves between unity and the trough +rate+ times a second,
        # along +shape+ (amplitude modulation).
        #
        # +rate+ - Hz (a number, a Pitch like `5.hz`, or a node of Hz), or
        #          a musical length (`1.n8`, `2.bars`, `lfo_bars.bars`): one
        #          cycle per length, following the tempo and locked to the
        #          timeline (Duration#lfo), or a Length per cycle
        #          (`0.25.seconds`); read by ModulationLfo.rate_tone, as the
        #          phaser's, flanger's, and rotary's rates are.
        # +:depth+ - How far down the trough goes, read like a ducking
        #            amount: -12.db or 12.db is 12 dB down, a bare number
        #            the trough's linear gain (0.25 = 12 dB down, 0 = a full
        #            cut), `(-Float::INFINITY).db` a full cut too; or a node of the
        #            trough's linear gain.  Default 12 dB.
        # +:shape+ - :sine (default), :triangle (:tri), :saw (rising;
        #            :ramp), :square (:sqr), :random (:noise, :sh; a value
        #            held each cycle), or a drawn shape: an Array of [x, y]
        #            points, x the position in the cycle (0..1, rising; two
        #            points at one x make a jump) and y the level (-1 the
        #            trough, 1 unity), joined by straight lines (in dB with
        #            `law: :db`) and wrapping from the last point to the
        #            first (see .drawn_table).
        # +:phase+ - Starting phase in cycles (or a Phase); a tempo LFO keeps
        #            that offset from the timeline.  Every shape is at its
        #            middle rising at phase 0, as in Notes#lfo, except drawn
        #            shapes, which start at x = 0.
        # +:stereo_phase+ - The right channel's LFO leads the left's by this
        #            many cycles (0.5: one side up while the other is down,
        #            an auto-panner).  A mono input becomes a stereo bundle
        #            when it is nonzero; with more channels, channel k of N
        #            leads by k / (N - 1) of it.
        # +:seam+ - Drawn shapes only: blends the end of the cycle into its
        #            start over this fraction of a cycle (true for 0.1), so
        #            a jump at the wrap doesn't click; how is +:seam_mode+.
        # +:seam_mode+ - :line (default): a straight line across the seam,
        #            from the shape's value seam / 2 before the end to its
        #            value seam / 2 after the start, whatever it does in
        #            between (a trough at the wrap is cut off).  :jump: only
        #            the jump between the shape's last and first values is
        #            taken out, half of it ramped in over each side of the
        #            seam, so the shape keeps its own lines and a shape whose
        #            ends meet plays as drawn.  :jump is what Sony Amplitude
        #            Modulation's "blend graph edges" does; the two agree only
        #            for a sawtooth (straight through the wrap).
        # +:law+ - :db (default; the gain moves evenly in dB, stopping at
        #            +:floor+, -80 dB, for deeper troughs) or :linear (evenly
        #            in amplitude, the classic tremolo).  See Tremolo.
        # +:smooth+ - Smooths the LFO over this length (GraphNode#smooth;
        #            e.g. `5.ms` to soften a square's clicks); nil (default)
        #            keeps exact edges.
        # +:mix+ - 1 (default) all tremolo, 0 dry, between them a linear
        #            crossfade through #blend (a number, knob name, or node).
        # +:seed+ - For the :random shape (default: drawn from MB::Sound.seed).
        #
        # Returns the Tremolo node (a Channels bundle for several channels).
        #
        # Examples (bin/sound.rb):
        #     play 220.hz.saw.at(-12.db).tremolo(5, depth: 12.db)
        #     play 220.hz.saw.at(-12.db).tremolo(1.n8, shape: :square, depth: 0, law: :linear, smooth: 3.ms)
        #     play 110.hz.saw.at(-12.db).trem(1.n16, shape: [[0, 1], [0.25, -1], [1, -1]])   # a gate on each 16th
        #     play 110.hz.saw.at(-12.db).trem(1.n8, shape: [[0, -1], [0.5, 1], [1, 0]], seam: true, seam_mode: :jump)   # the jump at the wrap smoothed out
        #     play keys.tremolo(1.bar, stereo_phase: 0.5, depth: 24.db, shape: :triangle)   # auto-pan
        def tremolo(rate = 5.0, depth: 12.db, shape: :sine, phase: 0, stereo_phase: 0, seam: nil, seam_mode: :line, law: :db,
                    floor: Tremolo::DEFAULT_FLOOR.db, smooth: nil, mix: 1, seed: nil)
          amount = mix == 1 ? nil : BlendMethods.amount(mix)
          # (build-time settings: a graph document's params become their numbers)
          phase = GraphNode.build_setting(phase)
          stereo_phase = GraphNode.build_setting(stereo_phase)
          seam = GraphNode.build_setting(seam)
          drawn = TremoloMethods.drawn?(shape)
          shape = shape.map { |p| p.is_a?(Array) ? p.map { |v| GraphNode.build_setting(v) } : p } if drawn
          wave = drawn ? nil : TremoloMethods.shapes.fetch(shape) {
            raise ArgumentError, "tremolo shape: is one of #{TremoloMethods.shapes.keys.map(&:inspect).join(', ')} or an Array of [x, y] points (got #{shape.inspect})"
          }
          raise ArgumentError, 'tremolo seam: is for drawn shapes (an Array of [x, y] points)' if seam && !drawn
          unless SEAM_MODES.include?(seam_mode)
            raise ArgumentError, "tremolo seam_mode: is #{SEAM_MODES.map(&:inspect).join(' or ')} (got #{seam_mode.inspect})"
          end
          table = drawn ? TremoloMethods.drawn_table(shape, seam: seam, mode: seam_mode) : nil
          phase = Phase.cycles(phase)
          raise ArgumentError, "tremolo phase: must be a number of cycles or a Phase (got #{phase.inspect})" unless phase.is_a?(Numeric)
          stereo_phase = Phase.cycles(stereo_phase)
          raise ArgumentError, "tremolo stereo_phase: must be a number of cycles or a Phase (got #{stereo_phase.inspect})" unless stereo_phase.is_a?(Numeric)
          TremoloMethods.check_rate(rate)
          raise ArgumentError, "tremolo law: is #{Tremolo::LAWS.map(&:inspect).join(' or ')} (got #{law.inspect})" unless Tremolo::LAWS.include?(law)
          seed = MB::Sound.next_seed if wave == :noise && seed.nil?

          build = lambda do |src|
            inputs = src.outputs
            inputs = [inputs[0], inputs[0]] if inputs.length == 1 && stereo_phase != 0
            count = inputs.length
            # (one LFO per distinct phase, shared by channels through Tees)
            lfos = {}
            outs = inputs.each_with_index.map do |input, k|
              offset = count == 1 ? 0 : stereo_phase * k / (count - 1).to_f
              mod = (lfos[offset] ||= TremoloMethods.lfo(rate, wave, table, phase + offset, smooth, seed, input.sample_rate))
              Tremolo.new(input, mod, depth: depth, law: law, floor: floor)
            end
            outs.length == 1 ? outs[0] : Channels.new(outs)
          end

          amount ? blend(amount) { |s| build.(s) } : build.(self)
        end
        alias trem tremolo
        alias amplitude_modulation tremolo

        # True if +shape+ is a drawn shape (an Array of points).
        def self.drawn?(shape)
          shape.is_a?(Array)
        end

        # Raises unless +rate+ is a rate #tremolo takes.
        def self.check_rate(rate)
          ok = case rate
               when Numeric then rate.real? && rate.finite? && rate >= 0
               when Sequence::Duration, Sequence::NodeDuration, Pitch then true
               when Length then rate.to_seconds > 0 # (a period, as for every modulation effect: ModulationLfo)
               else rate.respond_to?(:sample)
               end
          raise ArgumentError, "tremolo rate is Hz (a number, Pitch, or node), a musical length like 1.n8, or a Length per cycle (got #{rate.inspect})" unless ok
        end

        # The LFO for #tremolo: a Tone in -1..1 at +rate+ playing +wave+ (a
        # Tone waveform, :noise for sample and hold) or +table+ (a drawn
        # Wavetable), starting at +phase+ cycles, smoothed over +smooth+.
        def self.lfo(rate, wave, table, phase, smooth, seed, sample_rate)
          # (the rate read as every modulation effect reads it)
          tone = ModulationLfo.rate_tone(rate, sample_rate: sample_rate, what: 'tremolo')
          tone = if table
                   tone.wavetable(table)
                 else
                   case wave
                   when :sine then tone
                   when :noise then tone.asquare
                   else tone.public_send(wave)
                   end
                 end
          tone.with_phase(phase % 1) unless phase == 0
          mod = wave == :noise ? tone.sample_hold(range: -1.0..1.0, seed: seed) : tone
          smooth ? mod.smooth(smooth) : mod
        end

        # The value of drawn shape +points+ (see #tremolo's +:shape+) at
        # +x+ cycles (any number; the shape repeats every cycle): the
        # straight line between the points around +x+, wrapping from the
        # last point to the first.  At two points sharing an x (a jump),
        # +side+ :right (default) gives the value after the jump, :left the
        # one before.  Exactly at a cycle's start a shape whose first and
        # last values differ jumps too (x = 0 and x = 1 are one place).
        def self.drawn_value(points, x, side: :right)
          pts = points
          x -= x.floor
          # the points around one cycle, with the last point a cycle before
          # and the first a cycle after
          ext = [[pts[-1][0] - 1, pts[-1][1]], *pts, [pts[0][0] + 1, pts[0][1]]]
          if side == :right
            i = ext.rindex { |(px, _)| px <= x }
          else
            i = ext.index { |(px, _)| px >= x }
            i = i.nil? ? ext.length - 1 : i
            return ext[i][1] if ext[i][0] == x
            i -= 1
          end
          x0, y0 = ext[i]
          x1, y1 = ext[i + 1]
          return y0 if x1 == x0
          y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        end

        # The value of drawn shape +points+ at +x+ with the seam blended
        # over +seam+ cycles (see #tremolo's +:seam+ and +:seam_mode+):
        # within seam / 2 of the cycle's start, with +mode+ :line the
        # straight line from the shape's value at 1 - seam / 2 to its value
        # at seam / 2; with :jump the shape's value plus a ramp taking out
        # the jump J between its last value (just before x = 1) and its
        # first (at x = 0): -J (x - (1 - h)) / seam before the wrap and
        # J (h - x) / seam after it (h = seam / 2), within -1..1.
        def self.seamed_value(points, x, seam, side: :right, mode: :line)
          return drawn_value(points, x, side: side) if seam.nil? || seam == 0

          h = seam / 2.0
          x -= x.floor
          return drawn_value(points, x, side: side) if x >= h && x <= 1 - h

          if mode == :jump
            jump = end_value(points) - drawn_value(points, 0.0, side: :right)
            ramp = x < h ? jump * (h - x) / seam : -jump * (x - (1 - h)) / seam
            return (drawn_value(points, x, side: side) + ramp).clamp(-1.0, 1.0)
          end

          a = drawn_value(points, 1 - h, side: :left)
          b = drawn_value(points, h, side: :right)
          t = x < h ? x + h : x - (1 - h)
          a + (b - a) * t / seam
        end

        # The value of drawn shape +points+ just before the end of the cycle
        # (x = 1 approached from below): the first point at x = 1, or the
        # wrapping line from the last point toward the first's next cycle.
        def self.end_value(points)
          at_end = points.find { |(px, _)| px >= 1.0 }
          return at_end[1] if at_end
          x0, y0 = points[-1]
          x1 = points[0][0] + 1
          y1 = points[0][1]
          x1 == x0 ? y0 : y0 + (y1 - y0) * (1.0 - x0) / (x1 - x0)
        end

        # Checks drawn shape +points+ and returns them as frozen [x, y]
        # Float pairs.
        def self.check_points(points)
          raise ArgumentError, 'A drawn tremolo shape needs at least one [x, y] point' if points.empty?

          pts = points.map do |p|
            unless p.is_a?(Array) && p.length == 2 && p.all? { |v| v.is_a?(Numeric) && v.real? && v.finite? }
              raise ArgumentError, "A drawn tremolo shape is [x, y] points of numbers (got #{p.inspect})"
            end
            x, y = p.map(&:to_f)
            raise ArgumentError, "Drawn tremolo points have x from 0 to 1 (a position in the cycle; got #{x})" unless x >= 0 && x <= 1
            raise ArgumentError, "Drawn tremolo points have y from -1 (the trough) to 1 (unity; got #{y})" unless y >= -1 && y <= 1
            [x, y].freeze
          end
          pts.each_cons(2) do |(a, _), (b, _)|
            raise ArgumentError, "Drawn tremolo points go left to right (x #{b} after #{a})" if b < a
          end
          pts.freeze
        end

        # The cycle Wavetable of drawn shape +points+ (see #tremolo's
        # +:shape+ and +:seam+): DRAWN_SIZE samples of the shape (the value
        # after any jump), unfiltered (no levels) and read with linear
        # interpolation, so the lines stay straight and a jump takes one
        # table step (1/16000 of a cycle).  Kept per shape, seam, and seam
        # +mode+ (SEAM_MODES).
        def self.drawn_table(points, seam: nil, mode: :line)
          pts = check_points(points)
          seam = DEFAULT_SEAM if seam == true
          seam = nil if seam == false || seam == 0
          unless seam.nil? || (seam.is_a?(Numeric) && seam.real? && seam > 0 && seam <= 1)
            raise ArgumentError, "tremolo seam: is a fraction of a cycle (0..1), true for #{DEFAULT_SEAM}, or nil (got #{seam.inspect})"
          end
          seam = seam&.to_f
          raise ArgumentError, "tremolo seam_mode: is #{SEAM_MODES.map(&:inspect).join(' or ')} (got #{mode.inspect})" unless SEAM_MODES.include?(mode)
          mode = :line if seam.nil? # (no seam, one table)
          key = [pts, seam, mode].freeze
          @drawn_lock.synchronize do
            if (t = @drawn.delete(key))
              return @drawn[key] = t
            end
          end

          n = DRAWN_SIZE
          data = Numo::SFloat.cast(Array.new(n) { |i| seamed_value(pts, i / n.to_f, seam, mode: mode) })
          table = MB::Sound::Wavetable.from_samples(data, mips: false, interpolation: :linear, align: false, name: 'tremolo shape')

          @drawn_lock.synchronize do
            @drawn.delete(@drawn.keys.first) while @drawn.length >= DRAWN_KEPT
            @drawn[key] = table
          end
        end
      end
    end
  end
end
