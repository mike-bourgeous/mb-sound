module MB
  module Sound
    module Analysis
      # How far one sound is from another (lower is closer), as round 3 of
      # the voice-match study measured it, term by term:
      #
      # - +spectral+: round 2's loss (multi-resolution log-magnitude
      #   distance, spectral convergence, and a 5 ms envelope): per STFT
      #   size the mean |dB difference| of magnitudes floored 60 dB under
      #   the target's peak bin (+lsd+) and ||gY - X|| / ||X|| (+sc+), plus
      #   the mean |dB difference| of 5 ms RMS envelopes where the target is
      #   within 50 dB of its peak (+env+), with g the least-squares gain
      #   at 1024 points: lsd / 6 + sc + env / 6.  Sizes 256, 1024, 4096
      #   (hop a quarter) for sounds up to 0.6 s, 1024 and 4096 (hop a half)
      #   for longer ones; both sounds high-passed at 20 Hz and faded over
      #   their last 5 ms; bins up to the target's band.
      # - +modulation+: ModulationSpectrum#distance (dB) over the target's
      #   octave bands.
      # - +attack+: Attack.distance over the first 50 ms.
      #
      # +total+ is L3 = spectral + 2 x modulation + 0.3 x attack (WEIGHTS),
      # the distance that ranked the maintainer's Bench picks first 15
      # times in 24 (chance 7.5, p 0.001; round 2's loss alone 9, the
      # modulation term alone 14, the attack term alone 12).  The terms,
      # not the exact weights, carry it: four weightings tried all gave
      # 13-15, and the first one (5, 1) made fits trade 5-8 dB of timbre
      # for modulation and attack, so the spectral part leads.  The
      # labeled set was small and its picks not blind: treat the agreement
      # as a direction and re-test with Preferences on new verdicts.
      #
      # Before measuring, both sounds' onsets move to sample Signal::ONSET,
      # they are cut to the shorter one's length, and the candidate's RMS
      # is matched to the target's (every term is level-free).  +timbre+
      # is the Bench's old number: the 4096-point magnitude residual in dB
      # (0 dB nothing in common, -20 dB a tenth).
      #
      #     c = Analysis::Comparison.new('original.wav', fit)
      #     c.total        # => 1.88
      #     c.terms        # => { spectral: 1.2, modulation: 0.21, attack: 0.85 }
      #     c.spectral_parts   # => { lsd:, sc:, env: }
      class Comparison
        # L3's weights.
        WEIGHTS = { spectral: 1.0, modulation: 2.0, attack: 0.3 }.freeze

        # The terms, in order.
        TERMS = WEIGHTS.keys.freeze

        SIZES = [256, 1024, 4096].freeze
        LONG_SIZES = [1024, 4096].freeze
        LONG_SECONDS = 0.6
        FLOOR_DB = -60.0
        ENV_HOP = 240
        ENV_RANGE = 50.0
        FADE = 0.005
        LOWCUT = 20.0

        # The two sounds as measured (aligned, cut to one length, the
        # candidate at the target's RMS), and the target's band (Hz).
        attr_reader :target, :candidate, :band

        # The terms (Floats) and their weights.
        attr_reader :spectral, :modulation, :attack, :weights

        # The spectral term's parts: { lsd: (dB), sc:, env: (dB) }.
        attr_reader :spectral_parts

        # The 4096-point magnitude residual (dB).
        attr_reader :timbre

        # Compares +candidate+ with +target+ (anything Signal.from takes).
        # +weights:+ replaces L3's (missing terms weigh 0).
        def initialize(target, candidate, weights: WEIGHTS)
          x = Signal.from(target).aligned
          y = Signal.from(candidate).aligned
          n = [x.length, y.length].min
          raise ArgumentError, 'Both sounds need at least 1024 samples after their onsets' if n < 1024
          # (the target's side is kept with its Signal, so comparing many
          # candidates with one target, as refine does, measures it once)
          @target = x.memo([:comparison_cut, n]) { Signal.new(x.data[0...n], name: x.name) }
          yd = y.data[0...n]
          ry = Math.sqrt((yd**2).mean)
          yd = yd * (@target.rms / ry) if ry > 0
          @candidate = Signal.new(yd, name: y.name)
          @band = @target.band
          @weights = WEIGHTS.keys.to_h { |k| [k, (weights[k] || 0).to_f] }.freeze
          @spectral_parts, @timbre = spectral_loss(@target, @candidate)
          @spectral = @spectral_parts[:total]
          @spectral_parts = @spectral_parts.except(:total).freeze
          @modulation = @target.memo([:modulation_spectrum, @band]) { ModulationSpectrum.new(@target, band: @band) }.distance(ModulationSpectrum.new(@candidate, band: @band))
          @attack = Attack.distance(@target, @candidate)
        end

        # { spectral:, modulation:, attack: }.
        def terms = { spectral: @spectral, modulation: @modulation, attack: @attack }

        # The weighted sum of the terms (L3 with the default weights).
        def total = TERMS.sum { |k| @weights[k] * terms[k] }

        # A term (:spectral, :modulation, :attack), :total, or :timbre.
        def [](key)
          case key
          when :total then total
          when :timbre then @timbre
          else terms.fetch(key) { raise ArgumentError, "No term #{key.inspect} (#{(TERMS + %i[total timbre]).join(', ')})" }
          end
        end

        def to_h = terms.merge(total: total, timbre: @timbre, spectral_parts: @spectral_parts)

        def to_s
          w = ->(k) { @weights[k] == 1 ? '' : "#{RubyValue.to_ruby(@weights[k])} x " }
          "L3 #{format('%.3f', total)} = spectral #{format('%.3f', @spectral)} " \
            "(lsd #{format('%.1f', @spectral_parts[:lsd])} dB, sc #{format('%.2f', @spectral_parts[:sc])}, env #{format('%.1f', @spectral_parts[:env])} dB) " \
            "+ #{w.(:modulation)}modulation #{format('%.3f', @modulation)} + #{w.(:attack)}attack #{format('%.3f', @attack)}; " \
            "timbre #{format('%.1f', @timbre)} dB"
        end

        def inspect
          names = [@target.name, @candidate.name].compact
          "#<#{self.class.name.sub('MB::Sound::', '')}#{names.length == 2 ? " #{names[1].inspect} vs #{names[0].inspect}" : ''} #{self}>"
        end

        private

        # The shaping both sounds get before the spectral term: 20 Hz
        # high-pass, a raised-cosine fade over the last 5 ms.
        def shape(d)
          out = DSP.brickwall(d, Signal::RATE, nil, low: LOWCUT)
          fade = (FADE * Signal::RATE).round
          if out.length > fade
            ramp = 0.5 + 0.5 * Numo::NMath.cos(Math::PI * (Numo::DFloat.new(fade).seq + 1) / fade)
            out[(out.length - fade)..] = out[(out.length - fade)..] * ramp
          end
          Signal.new(out)
        end

        def spectral_loss(x, y)
          long = x.seconds > LONG_SECONDS
          sizes = long ? LONG_SIZES : SIZES
          div = long ? 2 : 4
          xs = x.memo(:comparison_shaped) { shape(x.data) }
          ys = shape(y.data)
          mags = SIZES.to_h { |n|
            bins = [(@band * n / Signal::RATE).floor + 1, n / 2 + 1].min
            [n, [xs.stft(n, n / div)[true, 0...bins], ys.stft(n, n / div)[true, 0...bins]]]
          }
          gain = ->(n) {
            xm, ym = mags[n]
            den = (ym**2).sum
            den > 0 ? (xm * ym).sum / den : 1.0
          }
          g = gain.(1024)
          lsd = []
          sc = []
          sizes.each do |n|
            xm, ym = mags[n]
            floor = xm.max * 10**(FLOOR_DB / 20)
            floor = 1e-12 if floor <= 0
            norm = Math.sqrt((xm**2).sum)
            m = ym * g
            lsd << (Numo::NMath.log10(m + floor) * 20 - Numo::NMath.log10(xm + floor) * 20).abs.mean
            sc << (norm > 0 ? Math.sqrt(((m - xm)**2).sum) / norm : 0.0)
          end
          ex = xs.envelope_db(ENV_HOP)
          ey = Signal.new(ys.data * g).envelope_db(ENV_HOP)
          mask = ex.gt(ex.max - ENV_RANGE)
          env = mask.count_true > 0 ? (ex - ey).abs[mask].mean : 0.0
          lsd_m = lsd.sum / lsd.length
          sc_m = sc.sum / sc.length

          xm, ym = mags[4096]
          g4 = gain.(4096)
          norm = Math.sqrt((xm**2).sum)
          r = norm > 0 ? Math.sqrt(((ym * g4 - xm)**2).sum) / norm : 0.0
          [{ total: lsd_m / 6 + sc_m + env / 6, lsd: lsd_m, sc: sc_m, env: env }, 20 * Math.log10([r, 1e-9].max)]
        end
      end

      # Candidates ranked by their distance from a target (Analysis.rank),
      # closest first: an Enumerable of Entry(label, comparison, score).
      class Ranking
        include Enumerable

        Entry = Data.define(:label, :comparison, :score) do
          def to_s = "#{label}: #{format('%.3f', score)}"
        end

        # What the ranking sorts by (a term, :total, :timbre).
        attr_reader :by

        def initialize(entries, by:)
          @entries = entries.sort_by.with_index { |e, i| [e.score, i] }.freeze
          @by = by
        end

        def each(&block) = @entries.each(&block)

        def [](i) = @entries[i]

        def size = @entries.size
        alias length size

        # The labels, closest first.
        def labels = @entries.map(&:label)

        # A table: rank, label, the score, then every term.
        def to_s
          w = [@entries.map { |e| e.label.to_s.length }.max || 0, 5].max
          head = format("%-4s %-#{w}s %9s %9s %9s %9s %8s", '#', 'label', @by, 'spectral', 'modul.', 'attack', 'timbre')
          rows = @entries.each_with_index.map { |e, i|
            c = e.comparison
            format("%-4d %-#{w}s %9.3f %9.3f %9.3f %9.3f %8.1f", i + 1, e.label, e.score, c.spectral, c.modulation, c.attack, c.timbre)
          }
          [head, *rows].join("\n")
        end

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} by #{@by}: #{@entries.first(3).map(&:to_s).join(', ')}#{@entries.size > 3 ? ', ...' : ''}>"
      end
    end
  end
end
