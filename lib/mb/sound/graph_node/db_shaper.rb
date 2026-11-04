module MB
  module Sound
    module GraphNode
      # A waveshaper whose transfer curve is drawn on a dB-in / dB-out scale
      # (after Sonic Foundry's DirectX Distortion): each sample x becomes
      #
      #     y = sign(x) * 10^(T(20 log10 |x|) / 20)
      #
      # where T is a Dynamics::Transfer built from compander-style points
      # (GraphNode#shape_db; Dynamics::Transfer.points with outputs free to
      # fall, so curves may fold back), straight lines between the points by
      # default (:linear) or monotone cubics (:cubic), with vertical steps
      # where two points share an input (the second point's output at the
      # step and above; the antiderivative only bends there, so the ADAA
      # integral stays exact across it).  Negative samples go
      # through +negative+ (another Transfer), or through the positive curve
      # mirrored (nil, odd symmetry).  Zero stays zero.
      #
      # Above the last point the curve continues its last segment, so inputs
      # over full scale keep following it (no clamp: add #clip after it for
      # a ceiling).  Below the first point (+below+):
      # - :line (default, as the compander does) continues the first
      #   segment's line; its slope must be above 0 (else quiet input would
      #   come out louder, and silence as noise)
      # - :unity continues from the first point with slope 1 (a fixed gain)
      # - :silence gives 0 (a per-sample gate: crossover distortion)
      #
      # +mix+ (0..1) blends the shaped signal with the input, phase-aligned
      # in the antialiased version too (it scales the shaper's departure
      # from the input inside the ADAA).
      #
      # Antialiasing (+antialias+ true, the default) is the curve shapers'
      # (FastClip.shape_curve, CurveShaper): first-order ADAA of the curve's
      # excess over the input plus a half-sample allpass on the input, so
      # the output is half a sample late with a flat level.  A straight
      # line in dB is a power law (f(u) = f0 (u / u0)^p), so the curve
      # integrates in closed form (the kernel's dB form, rows of [u0, f0,
      # p, c0]): exact at every level, no table and no input range.  Cubic
      # segments are cut into dB-linear chords within CHORD_DB of the cubic
      # for the antialiased version.  The plain version (+antialias+ false,
      # GraphNode#ashape_db) evaluates T itself (FastClip.shape_db, mirror
      # .plain_ruby), exact, for control signals.
      class DbShaper
        include GraphNode
        include SampleRateHelper
        # (its antialiasing state moves to a rebuilt shaper: #carry_adopt)
        node_traits memory: :short, carry: :adopt

        extend MB::Sound::Presettable

        # The ways below the first point (see the class description).
        BELOW = %i[line unity silence].freeze

        # Settings a preset may give (GraphNode#shape_db's keywords).
        KEYS = %i[points negative interpolation below mix].freeze

        # Largest dB distance of the antialiased version's chords from a
        # cubic segment.
        CHORD_DB = 0.01

        # The most chords per cubic segment.
        MAX_CHORDS = 4096

        # Exponents this close to -1 integrate as a logarithm (the C
        # kernel's DB_LOG_Q).
        LOG_Q = 1e-9

        # The kernel's map (identity in and out, natural) and edge mode
        # (:none: the dB form holds for every input).
        MAP = Numo::DFloat[0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0].freeze
        EDGES = CurveShaper::EDGES[:none]

        preset_family :shape_db, kind: :effect, label: 'shape_db preset', keys: KEYS,
          about: 'dB-domain waveshapers (transfer curves in dB): sig.shape_db(:fuzz)',
          apply: ->(name, input, **options) { input.shape_db(name, **options) },
          code: ->(e) { "sig.shape_db(#{e.name.inspect})" }

        param :mix, 1.0, range: 0.0..1.0, description: 'Shaped share (0 dry, 1 all shaped; phase-aligned)'
        param :interpolation, :linear, range: %i[linear cubic], description: 'Lines between points in dB, or monotone cubics'
        param :below, :line, range: BELOW, description: 'Below the first point: continue its line, unity slope, or silence'

        # Generic curves (never the maintainer's plugin settings).
        preset :soft_knee, points: { -84.db => -84.db, -24.db => -24.db, -12.db => -14.db, 0.db => -9.db }.freeze, interpolation: :cubic,
          tags: %i[gentle saturation warm], about: 'Unity up to -24 dB, then a soft knee leveling off near -9 dB'
        preset :fuzz, points: { -84.db => -60.db, -48.db => -18.db, -24.db => -9.db, 0.db => -6.db }.freeze,
          tags: %i[fuzz loud dirty], about: 'Quiet parts raised by up to 30 dB, peaks held near -6 dB: a dense fuzz'
        preset :fold_back, points: { -84.db => -84.db, -12.db => -6.db, 0.db => -24.db }.freeze,
          tags: %i[harsh fold aggressive], about: 'Rises to -6 dB at -12 dB in, then folds back down to -24 dB at full scale'
        preset :gate, points: { -84.db => -120.db, -40.db => -100.db, -30.db => -30.db, 0.db => 0.db }.freeze,
          tags: %i[gate crossover sputter], about: 'Unity above -30 dB, almost nothing below -40 dB: a per-sample gate (crossover grit)'
        preset :asymmetric, points: { -84.db => -84.db, -20.db => -20.db, 0.db => -6.db }.freeze,
          negative: { -84.db => -84.db, -30.db => -30.db, -12.db => -14.db, 0.db => -14.db }.freeze,
          tags: %i[even warm tube], about: 'A soft top half and a flat-topped bottom half: even harmonics'

        # The positive and negative Dynamics::Transfer curves (negative nil
        # when mirrored).
        attr_reader :positive, :negative

        # How the curves continue below their first points (see BELOW).
        attr_reader :below

        # The shaped share (0..1).
        attr_reader :mix

        # True if antialiased.
        attr_reader :antialias

        # Shapes +source+ through Dynamics::Transfer +positive+ (and
        # +negative+ for negative samples, or nil to mirror the positive
        # curve), continuing below the first points by +below+, mixed by
        # +mix+ (see the class description).
        def initialize(source, positive:, negative: nil, below: :line, mix: 1.0, antialias: true)
          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          [positive, negative].compact.each do |t|
            raise ArgumentError, "dB shaper curves are Dynamics::Transfers (got #{t.class})" unless t.is_a?(Dynamics::Transfer)
          end
          raise ArgumentError, "below must be one of #{BELOW.inspect} (got #{below.inspect})" unless BELOW.include?(below)
          raise ArgumentError, "mix must be a number from 0 to 1 (got #{mix.inspect})" unless mix.is_a?(Numeric) && (0..1).cover?(mix)

          @positive = positive
          @negative = negative
          @below = below
          @mix = mix.to_f
          @antialias = !!antialias

          pos = DbShaper.half(positive, below)
          neg = negative && DbShaper.half(negative, below)
          @pos_table = pos[:table]
          @neg_table = neg && neg[:table]
          @pos_floor = pos[:floor]
          @neg_floor = neg ? neg[:floor] : pos[:floor]
          rows = pos[:rows] + (neg ? neg[:rows] : [])
          @rows = [@mix, pos[:rows].length.to_f / 4, neg ? neg[:rows].length.to_f / 4 : 0.0, *rows].freeze
          @coeffs = @antialias ? Numo::DFloat.cast(@rows).freeze : nil

          @state = [0.0, 0.0, 0.0, 0]
          @buf = nil
          @steady_in = FrozenView::Key.new # (see FrozenView)
          @steady_out = nil
          @node_type_name = "#{'a' unless @antialias}shape_db"
        end

        def sources
          { input: @source }
        end

        # Session::Carry's adoption (NodeTraits' +carry+ :adopt): true if
        # shaper +old+ antialiases alike (its state fits; the curve may
        # differ).
        def carry_fits?(old)
          old.class == self.class && old.instance_variable_get(:@antialias) == @antialias
        end

        # Takes over shaper +old+'s antialiasing state (the previous input
        # and the allpass).
        def carry_adopt(old)
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@state].freeze

        def sample(count)
          data = @source.sample(count)
          return nil if data.nil?
          raise ArgumentError, 'dB shapers take real signals' if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)

          @buf = Numo::SFloat.zeros(data.length) if @buf.nil? || @buf.length != data.length
          @buf[0..] = data unless MB::Sound::Kernels.copy(@buf, data)

          unless @antialias
            # A steady input (the same frozen buffer again with the same
            # generation; see FrozenView) gives the same output, as in
            # CurveShaper
            if @steady_in.match?(data)
              return @steady_out if @steady_out

              plain_in_place(@buf)
              return @steady_out = @buf.dup.freeze
            end
            @steady_in.set(data)
            @steady_out = nil

            return plain_in_place(@buf)
          end

          Kernels.shape_curve(@buf.inplace!, CurveShaper::FORMS[:db], @coeffs, nil, nil, nil, MAP, EDGES, false, @state).not_inplace!
        end

        # The plain (exact) shaper of +buf+, in place.
        def plain_in_place(buf)
          Kernels.shape_db(buf.inplace!, @pos_table, @neg_table, @mix, @pos_floor, @neg_floor).not_inplace!
        end

        # The plain (exact) shaper of +data+ (a new SFloat).
        def plain(data)
          plain_in_place(Numo::SFloat.cast(data).dup)
        end

        def to_s
          "#{super} -- #{@node_type_name}(#{@positive}#{", negative #{@negative}" if @negative}, below #{@below}#{", mix #{@mix}" if @mix != 1})"
        end

        # Builds the shaper of GraphNode#shape_db on +input+: +points+ (a
        # preset name, nil for :soft_knee, or compander-style points plus
        # keyword points +more+) with the other settings over the preset's.
        # A first segment that can't continue below (:line with a slope at
        # most 0) goes through MB::Sound.live_error (live mode: :unity).
        def self.build(input, points, more, negative: nil, interpolation: nil, below: nil, mix: nil, antialias: true)
          bad = more.keys.reject { |k| k.is_a?(Numeric) }
          raise ArgumentError, "Unknown shape_db options: #{bad.map(&:inspect).join(', ')}#{Library.suggest(bad[0], KEYS + [:antialias])}" unless bad.empty?

          settings = {}
          if points.is_a?(Symbol) || (points.nil? && more.empty?)
            settings = preset_settings(points || :soft_knee)
            points = settings[:points]
          end
          negative = settings.fetch(:negative, :mirror) if negative.nil?
          interpolation ||= settings.fetch(:interpolation, :linear)
          below ||= settings.fetch(:below, :line)
          mix = settings.fetch(:mix, 1.0) if mix.nil?
          mix = GraphNode.build_setting(mix) # (a param or knob is read once while building)
          raise ArgumentError, "negative must be :mirror or points (got #{negative.inspect})" if negative.is_a?(Symbol) && negative != :mirror
          raise ArgumentError, "below must be one of #{BELOW.inspect} (got #{below.inspect})" unless BELOW.include?(below)

          pos = transfer(points, more, interpolation)
          neg = negative == :mirror ? nil : transfer(negative, {}, interpolation)
          if below == :line
            problem = [pos, neg].compact.lazy.map { |t| below_problem(t) }.find(&:itself)
            if problem
              MB::Sound.live_error(ArgumentError.new(problem))
              below = :unity
            end
          end

          new(input, positive: pos, negative: neg, below: below, mix: mix, antialias: antialias)
        end

        # A Dynamics::Transfer from compander-style +points+ and keyword
        # points +more+ (DynamicsMethods.point_rows), outputs free to fall.
        def self.transfer(points, more, interpolation)
          rows = DynamicsMethods.point_rows(points, more, 'shape_db')
          t = Dynamics::Transfer.points(rows, interpolation: interpolation, monotonic: false, steps: true)
          Dynamics::Transfer.new(t.segments, description: t.description.sub(/\Acompand /, ''))
        end

        # Why +transfer+ can't continue its first segment's line below its
        # first point (a slope at most 0), or nil.
        def self.below_problem(transfer)
          x0, _, slope = transfer.segments[0]
          return nil if slope > 0
          "the shape_db curve below its first point (#{fmt(x0)} dB) falls or stays flat (slope #{fmt(slope)}), " \
            'so quiet input would come out louder; give below: :unity or :silence, or a lower point'
        end

        # The plain shaper's segment table, floor, and the antialiased
        # version's power-law rows for one half's Dynamics::Transfer
        # +transfer+ with +below+ ({ table:, floor:, rows: }, rows flat).
        def self.half(transfer, below)
          segs = transfer.segments.dup
          x0, y0, = segs[0]
          problem = below == :line && below_problem(transfer)
          raise ArgumentError, problem if problem
          segs[0] = [x0, y0, 1.0, 0.0, 0.0].freeze if below == :unity
          {
            table: Numo::DFloat.cast(segs.flatten).freeze,
            floor: below == :silence ? x0.to_f : -Float::INFINITY,
            rows: power_rows(segs, below == :silence).flatten,
          }
        end

        # Rows [u0, f0, p, c0] of the dB form (see the class description)
        # for transfer segments +segs+ (the first is the line below the
        # first point; +silent+ zeroes it).  Linear segments map to one row
        # each; cubic ones to chords within CHORD_DB.
        def self.power_rows(segs, silent)
          pieces = []
          segs.each_with_index do |s, i|
            if (s[3] == 0 && s[4] == 0) || i == segs.length - 1
              pieces << [s[0], s[1], s[2]]
              next
            end

            x1 = segs[i + 1][0]
            h = x1 - s[0]
            curv = [(2 * s[3]).abs, (2 * s[3] + 6 * s[4] * h).abs].max
            n = (h * Math.sqrt(curv / (8 * CHORD_DB))).ceil.clamp(1, MAX_CHORDS)
            n.times do |k|
              xa = s[0] + h * k / n
              xb = k == n - 1 ? x1 : s[0] + h * (k + 1) / n
              ya = Dynamics::Transfer.evaluate([s], xa)
              yb = Dynamics::Transfer.evaluate([s], xb)
              pieces << [xa, ya, (yb - ya) / (xb - xa)]
            end
          end

          rows = []
          pieces.each_with_index do |(x, y, p), k|
            u0 = 10.0 ** (x / 20.0)
            if k == 0
              rows << (silent ? [u0, 0.0, 1.0, 0.0] : [u0, 10.0 ** (y / 20.0), p, 10.0 ** (y / 20.0) * u0 / (p + 1.0)])
            else
              rows << [u0, 10.0 ** (y / 20.0), p, half_integral_row(rows[-1], u0)]
            end
          end
          rows
        end

        # The integral from 0 to +u+ of one row's power law (the C
        # db_half_integral for a known row).
        def self.half_integral_row(r, u)
          q = r[2] + 1.0
          v = u / r[0]
          return r[3] + r[1] * r[0] * Math.log(v) if q.abs < LOG_Q
          r[3] + r[1] * r[0] * (v**q - 1.0) / q
        end

        # The row of +rows+ (a flat Array from +start+, +n+ rows) for
        # magnitude +u+ (the C db_row): its index in rows.
        def self.row_index(rows, start, n, u)
          lo = 0
          hi = n - 1
          while lo < hi
            mid = (lo + hi + 1) / 2
            if rows[start + mid * 4] <= u
              lo = mid
            else
              hi = mid - 1
            end
          end
          start + lo * 4
        end

        # Ruby mirror of the C db_f: the dB form at signed +x+ for the flat
        # coefficient Array +c+ ([mix, positive rows, negative rows, rows...]).
        def self.form_f(c, x)
          neg = x < 0 && c[2] > 0
          start = neg ? 3 + c[1].to_i * 4 : 3
          n = neg ? c[2].to_i : c[1].to_i
          u = x.abs
          f = if u > 0
                j = row_index(c, start, n, u)
                c[j + 1] * (u / c[j])**c[j + 2]
              else
                0.0
              end
          f = -f if x < 0
          c[0] == 1.0 ? f : x + c[0] * (f - x)
        end

        # Ruby mirror of the C db_integral.
        def self.form_integral(c, x)
          neg = x < 0 && c[2] > 0
          start = neg ? 3 + c[1].to_i * 4 : 3
          n = neg ? c[2].to_i : c[1].to_i
          u = x.abs
          big_f = if u > 0
                    j = row_index(c, start, n, u)
                    half_integral_row(c[j, 4], u)
                  else
                    0.0
                  end
          return big_f if c[0] == 1.0
          half = 0.5 * x * x
          half + c[0] * (big_f - half)
        end

        # Ruby mirror of MB::Sound::FastClip.shape_db (the same arguments,
        # the result written in place like the C kernel).
        def self.shape_db_ruby(buf, positive, negative, mix, floor_positive, floor_negative)
          pos = positive.to_a.each_slice(5).to_a
          neg = negative ? negative.to_a.each_slice(5).to_a : pos
          m = mix.to_f
          out = Numo::SFloat.cast(buf.to_a.map { |s|
            x = s.to_f
            y = 0.0
            if x != 0
              is_neg = x < 0
              l = 20.0 * Math.log10(x.abs)
              unless l < (is_neg ? floor_negative : floor_positive)
                y = 10.0**(Dynamics::Transfer.evaluate(is_neg ? neg : pos, l) / 20.0)
                y = -y if is_neg
              end
            end
            m == 1.0 ? y : x + m * (y - x)
          })
          Kernels.inplace_result(buf, out)
        end

        def self.fmt(v)
          v == v.round ? v.round.to_s : MB::M.sigfigs(v, 4).to_s
        end
        private_class_method :fmt
      end

      Kernels.register :shape_db, c: FastClip.method(:shape_db), ruby: DbShaper.method(:shape_db_ruby),
        about: 'the exact dB-domain waveshaper (DbShaper with antialias off)'
    end
  end
end
