module MB
  module Sound
    module GraphNode
      # Shapes a signal through a tweening curve (MB::Sound::Curve): the
      # input range (default 0..1) is mapped onto the curve's 0..1, and the
      # curve's 0..1 onto the output range (default 0..1).  Created by
      # GraphNode#ease (antialiased) and #aease (plain).  It generalizes the
      # smoothstep: `ease(:smoothstep)` is the smoothstep shaper, and any
      # curve works, e.g. an LFO reshaped into bounces or rhythmic steps, or
      # a sine through an elastic or bouncing transfer curve (a waveshaper).
      #
      # Inputs outside the input range (+edges+):
      # - :clamp (default) - hold the curve's end values
      # - :extend - the formula itself where it holds outside 0..1 (linear,
      #   sine, dB curves), else a line with the curve's slope at that end
      # - :wrap - repeat the curve (a phasor or ramp becomes a sawtooth of
      #   curve shapes)
      # - :mirror - ping-pong (0..1 forward, 1..2 backward, ...)
      # - :none (alias :raw) - the raw formula (plain shapers, or curves
      #   with a closed form when antialiased)
      # With +symmetric+ the curve shapes the magnitude (input range 0..m)
      # and the sign is restored, an odd waveshaper for bipolar audio
      # (output -k..k for an output range 0..k).
      #
      # Antialiasing (+antialias+ true, the default) works like #softclip's
      # (see MB::Sound::Shaper): first-order antiderivative antialiasing of
      # the curve's excess over the straight line from the input range to
      # the output range, plus a half-sample Thiran allpass on that straight
      # line, so the output is delayed by half a sample and its level stays
      # flat.  The edge mode is part of the integrated function, so the
      # kinks of :clamp and the jumps of :wrap and :steps are antialiased
      # too.  Polynomial, cosine, and exponential curves integrate in closed
      # form; the others (elastic, bounce, squiggle, bezier, composed curves,
      # Procs) through a table of the antiderivative (4096 cells, cubic
      # Hermite).  The kernel is MB::Sound::FastClip.shape_curve; .shape_ruby
      # is its exact mirror.  Plain shapers (#aease) apply the curve
      # exactly, for control signals (LFO gates, stepped automation).
      class CurveShaper
        include GraphNode
        include SampleRateHelper

        # Curve sources of the C kernel.
        FORMS = { table: 0, poly: 1, cos: 2, exp: 3 }.freeze

        # Edge modes of the C kernel (see the class description).
        EDGES = { clamp: 0, extend: 1, wrap: 2, mirror: 3, none: 4 }.freeze

        # Inputs closer than this use the curve at their midpoint (as
        # MB::Sound::Shaper::TINY).
        TINY = 1e-6

        # The half-sample Thiran allpass coefficient (MB::Sound::Shaper::ALLPASS).
        ALLPASS = 1.0 / 3.0

        # Curvatures of Curve.db below this use a table instead of the
        # closed form (whose e^(cx) - 1 loses precision).
        EXP_MIN_CURVATURE = 1e-3

        # The MB::Sound::Curve.
        attr_reader :curve

        # The input and output ranges (Ranges of Floats).
        attr_reader :input, :output

        # The edge mode (see the class description).
        attr_reader :edges

        # True for an odd (symmetric) shaper.
        attr_reader :symmetric

        # True if antialiased.
        attr_reader :antialias

        # Shapes +source+ through +curve+ (anything Curve.from takes) from
        # +input+ to +output+ (Ranges; a number n means 0..n) with +edges+
        # (see the class description).
        def initialize(source, curve:, input: 0.0..1.0, output: 0.0..1.0, edges: :clamp, symmetric: false, antialias: true)
          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          @curve = MB::Sound::Curve.from(curve)
          raise ArgumentError, 'A curve shaper needs a curve' if @curve.nil?

          edges = :none if edges == :raw
          raise ArgumentError, "Edges must be one of #{EDGES.keys.inspect} or :raw (got #{edges.inspect})" unless EDGES.include?(edges)
          @edges = edges
          @symmetric = !!symmetric
          @antialias = !!antialias
          @input = CurveShaper.range(input, 'input')
          @output = CurveShaper.range(output, 'output')

          if @symmetric
            @in_lo = 0.0
            m = [@input.begin.abs, @input.end.abs].max
            raise ArgumentError, 'A symmetric curve shaper needs a nonzero input range' if m == 0
            @in_scale = 1.0 / m
            @out_lo = 0.0
            @out_scale = @output.end
          else
            raise ArgumentError, 'The input range must not be empty' if @input.end == @input.begin
            @in_lo = @input.begin
            @in_scale = 1.0 / (@input.end - @input.begin)
            @out_lo = @output.begin
            @out_scale = @output.end - @output.begin
          end

          @params = CurveShaper.kernel_params(@curve, @edges, [@in_lo, @in_scale, @out_lo, @out_scale]) if @antialias
          @state = [0.0, 0.0, 0.0, 0]
          @buf = nil
          @node_type_name = "#{'a' unless @antialias}ease"
        end

        def sources
          { input: @source }
        end

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil?
          raise ArgumentError, 'Curve shapers take real signals' if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          @buf = Numo::SFloat.zeros(data.length) if @buf.nil? || @buf.length != data.length
          unless @antialias
            @buf[0..] = plain(data)
            return @buf
          end

          @buf[0..] = data unless MB::Sound::FastArithmetic.copy(@buf, data)
          p = @params
          MB::Sound::FastClip.shape_curve(@buf.inplace!, p[:form], p[:coeffs], p[:ti], p[:tfl], p[:tfr], p[:map], p[:edges], @symmetric, @state).not_inplace!
        end

        def to_s
          "#{super} -- #{@node_type_name}(#{@curve}, #{@input} -> #{@output}, #{@edges}#{', symmetric' if @symmetric})"
        end

        # The plain (exact) shaper of +data+ (a Numo::DFloat result).
        def plain(data)
          x = (Numo::DFloat.cast(data) - @in_lo) * @in_scale
          if @symmetric
            y = @curve.map_edges(x.abs, @edges)
            neg = x.lt(0)
            y[neg] = -y[neg] if neg.any?
          else
            y = @curve.map_edges(x, @edges)
          end
          y * @out_scale + @out_lo
        end

        # Converts a range argument: a Range, or a number n for 0..n.
        def self.range(r, name)
          r = 0..r if r.is_a?(Numeric)
          raise ArgumentError, "The #{name} range must be a Range or a number (got #{r.inspect})" unless r.is_a?(Range)
          r.begin.to_f..r.end.to_f
        end

        # The arguments for MB::Sound::FastClip.shape_curve: :form, :coeffs,
        # :ti, :tfl, :tfr, :map, and :edges for +curve+ with +edges+ and the
        # input/output +mapping+ [in_lo, in_scale, out_lo, out_scale].
        def self.kernel_params(curve, edges, mapping)
          form = curve.form
          form = nil if form && form[0] == :exp && form[1].abs < EXP_MIN_CURVATURE
          form = nil if form && form[0] == :poly && form[1].length > 16

          if form.nil? && edges == :none
            raise ArgumentError, "Antialiased curve shapers with edges: :none need a closed-form curve (#{curve} has none); use aease or another edge mode"
          end

          params = { edges: EDGES.fetch(edges), ti: nil, tfl: nil, tfr: nil, coeffs: nil }
          case form&.first
          when :poly
            params[:form] = FORMS[:poly]
            params[:coeffs] = Numo::DFloat.cast(form[1]).freeze
          when :cos
            params[:form] = FORMS[:cos]
            params[:coeffs] = Numo::DFloat.cast(form[1..4]).freeze
          when :exp
            c = form[1]
            params[:form] = FORMS[:exp]
            params[:coeffs] = Numo::DFloat[c, 1.0 / (1.0 - Math.exp(c))].freeze
          else
            params[:form] = FORMS[:table]
            params[:ti], params[:tfl], params[:tfr] = curve.integral_table
          end

          natural = curve.natural? && !form.nil?
          s0, s1 = curve.slopes
          map = [*mapping.map(&:to_f), curve.call(0.0), curve.call(1.0), s0, s1, 0.0, natural ? 1.0 : 0.0]
          map[8] = integral(params, 1.0)
          params[:map] = Numo::DFloat.cast(map).freeze
          params
        end

        # Ruby mirror of the C curve_integral (the curve's integral from 0
        # to +x+) for kernel +params+.
        def self.integral(params, x)
          case params[:form]
          when FORMS[:poly]
            c = params[:coeffs]
            v = 0.0
            (c.length - 1).downto(0) { |k| v = v * x + c[k] / (k + 1).to_f }
            v * x
          when FORMS[:cos]
            a, b, w, ph = params[:coeffs].to_a
            a * x + (b / w) * (Math.sin(w * x + ph) - Math.sin(ph))
          when FORMS[:exp]
            c, inv = params[:coeffs].to_a
            (x - (Math.exp(c * x) - 1.0) / c) * inv
          else
            table_eval(params, x, false)
          end
        end

        # Ruby mirror of the C curve_f.
        def self.base_f(params, x)
          case params[:form]
          when FORMS[:poly]
            c = params[:coeffs]
            v = 0.0
            (c.length - 1).downto(0) { |k| v = v * x + c[k] }
            v
          when FORMS[:cos]
            a, b, w, ph = params[:coeffs].to_a
            a + b * Math.cos(w * x + ph)
          when FORMS[:exp]
            c, inv = params[:coeffs].to_a
            (1.0 - Math.exp(c * x)) * inv
          else
            table_eval(params, x, true)
          end
        end

        # The Hermite table interpolation of the C kernel: the integral, or
        # its derivative with +derivative+.
        def self.table_eval(params, x, derivative)
          ti = params[:ti]
          cells = ti.length - 1
          pos = x * cells.to_f
          pos = 0.0 if pos < 0
          pos = cells.to_f if pos > cells.to_f
          j = pos.to_i
          j = cells - 1 if j >= cells
          t = pos - j.to_f
          h = 1.0 / cells.to_f
          if derivative
            d00 = 6.0 * t * t - 6.0 * t
            d10 = 3.0 * t * t - 4.0 * t + 1.0
            d11 = 3.0 * t * t - 2.0 * t
            (d00 * (ti[j] - ti[j + 1])) / h + d10 * params[:tfr][j] + d11 * params[:tfl][j + 1]
          else
            t2 = t * t
            t3 = t2 * t
            h00 = 2.0 * t3 - 3.0 * t2 + 1.0
            h10 = t3 - 2.0 * t2 + t
            h01 = -2.0 * t3 + 3.0 * t2
            h11 = t3 - t2
            h00 * ti[j] + h10 * h * params[:tfr][j] + h01 * ti[j + 1] + h11 * h * params[:tfl][j + 1]
          end
        end

        # Ruby mirror of the C curve_edge_f.
        def self.edge_f(params, u)
          _, _, _, _, f0, f1, s0, s1, _, natural = params[:map].to_a
          case params[:edges]
          when EDGES[:clamp] then u < 0 ? f0 : (u > 1 ? f1 : base_f(params, u))
          when EDGES[:extend]
            return base_f(params, u) if natural != 0
            u < 0 ? f0 + s0 * u : (u > 1 ? f1 + s1 * (u - 1.0) : base_f(params, u))
          when EDGES[:wrap] then base_f(params, u - u.floor.to_f)
          when EDGES[:mirror]
            r = u - 2.0 * (u * 0.5).floor.to_f
            base_f(params, r <= 1.0 ? r : 2.0 - r)
          else base_f(params, u)
          end
        end

        # Ruby mirror of the C curve_edge_integral.
        def self.edge_integral(params, u)
          _, _, _, _, f0, f1, s0, s1, i1, natural = params[:map].to_a
          case params[:edges]
          when EDGES[:clamp]
            return f0 * u if u < 0
            return i1 + f1 * (u - 1.0) if u > 1
            integral(params, u)
          when EDGES[:extend]
            return integral(params, u) if natural != 0
            return f0 * u + 0.5 * s0 * u * u if u < 0
            if u > 1
              d = u - 1.0
              return i1 + f1 * d + 0.5 * s1 * d * d
            end
            integral(params, u)
          when EDGES[:wrap]
            n = u.floor.to_f
            n * i1 + integral(params, u - n)
          when EDGES[:mirror]
            n = (u * 0.5).floor.to_f
            r = u - 2.0 * n
            part = r <= 1.0 ? integral(params, r) : 2.0 * i1 - integral(params, 2.0 - r)
            2.0 * n * i1 + part
          else
            integral(params, u)
          end
        end

        # Ruby mirror of MB::Sound::FastClip.shape_curve: returns +data+
        # through the antialiased curve shaper with kernel +params+ (see
        # .kernel_params), updating +state+ like the C version.
        def self.shape_ruby(data, params, symmetric, state)
          in_lo, in_scale, out_lo, out_scale = params[:map].to_a
          x1, ap_x1, ap_y1, primed = state
          primed = primed != 0

          out = Numo::SFloat.zeros(data.length)
          Numo::SFloat.cast(data).to_a.each_with_index do |s, i|
            x = (s - in_lo) * in_scale
            unless primed
              x1 = ap_x1 = ap_y1 = x
              primed = true
            end

            d = x - x1
            g = if d.abs < TINY
                  mid = 0.5 * (x + x1)
                  e = if symmetric
                        v = edge_f(params, mid.abs)
                        mid < 0 ? -v : v
                      else
                        edge_f(params, mid)
                      end
                  e - mid
                else
                  fa = symmetric ? edge_integral(params, x.abs) : edge_integral(params, x)
                  fb = symmetric ? edge_integral(params, x1.abs) : edge_integral(params, x1)
                  (fa - fb) / d - 0.5 * (x + x1)
                end

            dry = ALLPASS * x + ap_x1 - ALLPASS * ap_y1
            ap_x1 = x
            ap_y1 = dry
            x1 = x

            out[i] = out_lo + out_scale * (dry + g)
          end

          state.replace([x1, ap_x1, ap_y1, 1]) if data.length > 0
          out
        end
      end
    end
  end
end
