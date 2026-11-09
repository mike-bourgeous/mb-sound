module MB
  module Sound
    module GraphNode
      # Chebyshev waveshaping (effects-2): a transfer curve that is a sum of
      # Chebyshev polynomials, sum(a_n T_n(x)).  Since T_n(cos t) = cos(n t),
      # a full-scale sine through T_n comes out as its nth harmonic, so the
      # amounts a_n are the harmonics a full-scale sine gets: a waveshaper
      # drawn by its spectrum.  Quieter inputs get fewer of the high
      # harmonics (T_n of a small x is mostly its low-order terms), so the
      # shaper brightens as it is driven, like an amplifier.
      #
      # Built on GraphNode#ease (CurveShaper): the sum is one polynomial
      # Curve (closed form, so first-order antiderivative antialiasing
      # integrates it exactly; the output is half a sample late, as every
      # antialiased shaper's), inputs beyond -1..1 held at the ends.  The
      # curve is shifted so silence stays silent (sum(a_n T_n(0)) taken
      # off), and with even harmonics, whose squares carry DC, a DC blocker
      # (#hp1 at DC_CUTOFF) follows.
      #
      # Presets are the :chebyshev family of the library (`L.fx.chebyshev`).
      module Chebyshev
        extend MB::Sound::Presettable

        # The highest harmonic (CurveShaper integrates polynomials of up to
        # 16 coefficients in closed form).
        MAX_HARMONIC = 15

        # The DC blocker's cutoff in Hz (with even harmonics).
        DC_CUTOFF = 5.0

        # The settings GraphNode#chebyshev takes (besides amounts).
        KEYS = [*(1..MAX_HARMONIC).map { |n| :"h#{n}" }, :drive].freeze

        preset_family :chebyshev, kind: :effect, label: 'chebyshev preset', keys: KEYS,
          about: 'Chebyshev waveshapers (harmonics by amount): sig.chebyshev(:triode)',
          apply: ->(name, input, **options) { input.chebyshev(name, **options) },
          code: ->(e) { "sig.chebyshev(#{e.name.inspect})" }

        param :drive, 1.0, range: 0.0..8.0, description: 'Input gain before the curve (1: a full-scale sine gets exactly the amounts)'

        preset :triode, h1: 1.0, h2: 0.3, h3: 0.08, drive: 1.0,
          tags: %i[warm even subtle], about: 'Mostly second harmonic with a little third: a warm, even-order glow'
        preset :pentode, h1: 1.0, h3: 0.3, h5: 0.12, drive: 1.0,
          tags: %i[odd gritty], about: 'Odd harmonics (third and fifth): edgier, more like a clipped amplifier'
        preset :octaver, h1: 0.4, h2: 1.0, drive: 1.0,
          tags: %i[octave synth], about: 'The second harmonic over the fundamental: a full-scale sine an octave up'
        preset :drawbar, h1: 1.0, h2: 0.6, h3: 0.4, h4: 0.3, h6: 0.2, h8: 0.15, drive: 1.0,
          tags: %i[organ bright], about: 'Organ-like harmonics 1-4, 6, and 8 from a sine'
        preset :reed, h1: 1.0, h3: 0.5, h5: 0.3, h7: 0.2, h9: 0.1, drive: 1.0,
          tags: %i[hollow odd], about: 'Falling odd harmonics: a hollow, reedy tone from a sine'

        # The default preset (GraphNode#chebyshev without amounts).
        DEFAULT_PRESET = :triode

        # Builds the shaper on +input+ from a preset name (Symbol), amounts
        # (numbers from the fundamental up), or +h1:+ ... +h15:+ keywords;
        # +drive+ scales the input first.  See DistortionMethods#chebyshev.
        def self.build(input, amounts, drive: nil, antialias: true, **harmonics)
          bad = harmonics.keys - KEYS
          unless bad.empty?
            guess = DidYouMean::SpellChecker.new(dictionary: KEYS + %i[antialias]).correct(bad[0]).first
            raise ArgumentError, "chebyshev: unknown option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{guess ? " (did you mean #{guess.inspect}?)" : ''}"
          end

          s = {}
          if amounts.length == 1 && (amounts[0].is_a?(Symbol) || amounts[0].is_a?(String))
            s = preset_settings(amounts[0].to_sym)
          elsif amounts.empty? && harmonics.empty?
            s = preset_settings(DEFAULT_PRESET)
          else
            raise ArgumentError, "chebyshev: at most #{MAX_HARMONIC} amounts (got #{amounts.length})" if amounts.length > MAX_HARMONIC
            amounts.each_with_index { |a, i| s[:"h#{i + 1}"] = a }
          end
          s = s.merge(harmonics)
          s[:drive] = drive unless drive.nil?

          a = Array.new(MAX_HARMONIC + 1, 0.0)
          (1..MAX_HARMONIC).each do |n|
            v = GraphNode.build_setting(s[:"h#{n}"])
            next if v.nil?
            raise ArgumentError, "chebyshev h#{n}: is a number (got #{v.inspect})" unless v.is_a?(Numeric) && v.real?
            a[n] = v.to_f
          end
          raise ArgumentError, 'chebyshev: give at least one nonzero harmonic amount' if a.all?(&:zero?)

          d = s.fetch(:drive, 1.0)
          d = GraphNode.build_setting(d) unless d.respond_to?(:sample)
          d = Decibels.gain_of(d, 'chebyshev drive', above_one: false) if d.is_a?(Decibels)
          unless d.respond_to?(:sample) || (d.is_a?(Numeric) && d.real? && d >= 0)
            raise ArgumentError, "chebyshev drive: is a gain of at least 0 (a number, Decibels, or a node; got #{d.inspect})"
          end

          x = d.is_a?(Numeric) && d == 1 ? input : input * d
          out = x.ease(curve(a), in: -1.0..1.0, out: -1.0..1.0, antialias: antialias)
          a.each_with_index.any? { |v, n| n.even? && v != 0 } ? out.hp1(DC_CUTOFF) : out
        end

        # The Curve on 0..1 (the input's -1..1) whose output range -1..1
        # gives sum(a_n T_n(x)) - sum(a_n T_n(0)) for +a+ (amounts by
        # harmonic, a[0] unused): a polynomial in closed form.
        def self.curve(a)
          p = shifted(a)
          # the curve's 0..1 values are (g(2u - 1) + 1) / 2
          q = substitute(p)
          coeffs = q.map { |c| c / 2.0 }
          coeffs[0] += 0.5
          label = a.each_with_index.filter_map { |v, n| v != 0 ? "h#{n} #{MB::M.sigfigs(v, 3)}" : nil }.join(', ')
          MB::Sound::Curve.new(:"chebyshev(#{label})", kind: :in_out, form: [:poly, coeffs],
            generic: ->(u, _m) { v = 0.0; (coeffs.length - 1).downto(0) { |k| v = v * u + coeffs[k] }; v })
        end

        # Monomial coefficients (x^0 up) of sum(a_n T_n(x)) - sum(a_n T_n(0)).
        def self.shifted(a)
          poly = Array.new(a.length, 0.0)
          t_prev = [1.0]
          t = [0.0, 1.0]
          (1...a.length).each do |n|
            t.each_with_index { |c, k| poly[k] += a[n] * c } if a[n] != 0
            nxt = Array.new(t.length + 1, 0.0)
            t.each_with_index { |c, k| nxt[k + 1] += 2.0 * c }
            t_prev.each_with_index { |c, k| nxt[k] -= c }
            t_prev = t
            t = nxt
          end
          poly[0] = 0.0 # (the T_n(0) terms: silence stays silent)
          poly.pop while poly.length > 1 && poly[-1] == 0
          poly
        end

        # Coefficients in u of the polynomial +p+ (in x) at x = 2u - 1.
        def self.substitute(p)
          out = Array.new(p.length, 0.0)
          p.each_with_index do |c, k|
            next if c == 0
            # (2u - 1)^k = sum C(k, j) (2u)^j (-1)^(k - j)
            (0..k).each do |j|
              out[j] += c * binomial(k, j) * (2.0**j) * ((k - j).even? ? 1.0 : -1.0)
            end
          end
          out
        end

        def self.binomial(n, k)
          (1..k).reduce(1) { |r, i| r * (n - k + i) / i }
        end
        private_class_method :binomial
      end
    end
  end
end
