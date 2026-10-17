require "mb/sound" unless defined?(MB::Sound::Filter::FourPole)

module MB
  module Sound
    class Filter
      class FourPole
        # The analysis behind the four-pole's and diode ladder's edge tuning
        # (+tuning: :edge+; see FourPole::Tuning): the analog responses of
        # every output tap, their resonant peaks and -3 dB edges, and the
        # target cutoff scale that FourPole::Tuning's tables interpolate.
        # Slow (numeric searches); loaded only by the table generator
        # (make_tuning.rb) and specs, never at run time.
        #
        # Frequencies are in units of the hardware mapping's cutoff, the
        # frequency where the filter oscillates at the edge of oscillation
        # (lp4: the stages' frequency; the diode ladder: sqrt(10/7) times
        # its stages' frequency).  Loop gains are given as x = k / the loop
        # gain at that edge (4 for lp4, 901/49 for the diode ladder).
        module TuningAnalysis
          # The response of each output tap (one TPT stage's analog
          # prototype h = 1 / (1 + s)), before the loop.
          TAPS = {
            lp4: ->(s) { 1 / (1 + s)**4 },
            lp2: ->(s) { 1 / (1 + s)**2 },
            bp2: ->(s) { 2 * s / (1 + s)**2 },
            bp4: ->(s) { 4 * s**2 / (1 + s)**4 },
            hp2: ->(s) { s**2 / (1 + s)**2 },
            hp4: ->(s) { s**4 / (1 + s)**4 },
          }.freeze

          # Lowpass, bandpass, or highpass (what "passband" and "edge" mean).
          KINDS = { lp4: :lp, lp2: :lp, bp2: :bp, bp4: :bp, hp2: :hp, hp4: :hp, diode: :lp }.freeze

          # The diode ladder's oscillation edge and frequency (stages' units).
          DIODE_EDGE_K = 901.0 / 49
          DIODE_W180 = Math.sqrt(10.0 / 7.0)

          # The -3 dB level (half power).
          HALF_POWER_DB = 10 * Math.log10(0.5)

          # The edge level (dB re the passband) for each edge tuning: :edge
          # the -3 dB point, :edge6 (an experiment, 2026-10-17) -6 dB.
          EDGE_LEVELS = { edge: HALF_POWER_DB, edge6: 20 * Math.log10(0.5) }.freeze

          # The resonant peak's height over the passband (dB) at which the
          # cutoff reaches the peak (see .target).
          PEAK_DB = 6.0

          # The loop gain at the oscillation edge for +mode+.
          def self.edge_k(mode)
            mode == :diode ? DIODE_EDGE_K : 4.0
          end

          # |H(jw)| for +mode+ at loop gain k = +x+ × .edge_k (no
          # compensation; lowpasses relative to DC, highpasses to their
          # high-frequency gain, bandpasses as they are), +w+ in the hardware
          # mapping's units (see the module description).
          def self.magnitude(mode, x, w)
            k = x * edge_k(mode)
            if mode == :diode
              s = Complex(0, w * DIODE_W180)
              d = (((s + 7) * s + 15) * s + 10) * s + 1
              return ((1 + k) / (d + k)).abs
            end

            s = Complex(0, w)
            v = TAPS.fetch(mode).(s) / (1 + k / (1 + s)**4)
            v *= (1 + k) if KINDS[mode] == :lp
            v.abs
          end

          # The response in dB (see .magnitude).
          def self.db(mode, x, w)
            20 * Math.log10(magnitude(mode, x, w))
          end

          # The resonant peak [w, dB over the passband] for +mode+ at +x+, or
          # nil if the response never rises over its passband (bandpasses
          # always have one).
          def self.peak(mode, x)
            f = ->(lw) { db(mode, x, Math.exp(lw)) }
            grid = (-300..300).map { |i| i * 0.02 }
            best = grid.max_by { |lw| f.(lw) }
            lo = best - 0.02
            hi = best + 0.02
            80.times do
              m1 = lo + (hi - lo) * 0.381966
              m2 = hi - (hi - lo) * 0.381966
              f.(m1) > f.(m2) ? hi = m2 : lo = m1
            end
            lw = (lo + hi) / 2
            d = f.(lw)
            return [Math.exp(lw), d] if KINDS[mode] == :bp
            return nil if d <= 1e-9 || best <= grid.first || best >= grid.last

            [Math.exp(lw), d]
          end

          # The -3 dB point (relative to the passband) for +mode+ at +x+: a
          # lowpass's first crossing above its peak (or DC), a highpass's
          # first crossing below its high frequencies.
          def self.edge(mode, x, level = HALF_POWER_DB)
            lp = KINDS.fetch(mode) == :lp
            raise ArgumentError, 'Bandpasses have no edge' if KINDS[mode] == :bp

            if lp
              pk = peak(mode, x)
              w = pk ? pk[0] : 1e-3
              w *= 1.01 while db(mode, x, w * 1.01) > level
              lo = w
              hi = w * 1.01
            else
              w = 1e3
              w /= 1.01 while db(mode, x, w / 1.01) > level
              lo = w / 1.01
              hi = w
            end
            80.times do
              m = Math.sqrt(lo * hi)
              (db(mode, x, m) > level) == lp ? lo = m : hi = m
            end
            Math.sqrt(lo * hi)
          end

          # Smoothstep 3 t² - 2 t³ of +t+ clamped to 0..1.
          def self.smoothstep(t)
            return 0.0 if t <= 0
            return 1.0 if t >= 1
            t * t * (3 - 2 * t)
          end

          # The edge tuning's target: the frequency (hardware units) that
          # the cutoff should mean for +mode+ at +x+.  Bandpasses: the
          # peak.  Without resonance, lowpasses and highpasses: the -3 dB
          # edge (+level+; -6 dB for :edge6).  As the resonant peak grows from 0 to PEAK_DB over the
          # passband the target moves onto it (weight smoothstep(dB /
          # PEAK_DB), linear in frequency), and it is the peak from there
          # up.  Lowpasses follow their edge as the resonance rises (it
          # moves up quickly); highpasses keep the edge they have without
          # resonance (theirs barely moves for hp4 and sits on a shoulder
          # near -3 dB for hp2, where it jumps around).
          def self.target(mode, x, level = HALF_POWER_DB)
            pk = peak(mode, x)
            return pk[0] if KINDS[mode] == :bp

            e = KINDS[mode] == :lp ? edge(mode, x, level) : edge(mode, 0.0, level)
            return e unless pk

            a = smoothstep(pk[1] / PEAK_DB)
            e + a * (pk[0] - e)
          end

          # The cutoff scale m for +mode+ at +x+: the factor by which the
          # filter's frequency is raised above the hardware mapping so that
          # the cutoff is .target (1 / target).
          def self.scale(mode, x, level = HALF_POWER_DB)
            return 1.0 if x >= 1.0
            1.0 / target(mode, x, level)
          end

          # The response of +mode+ at +x+ with the edge tuning at +w+
          # (units of the cutoff), in dB.
          def self.tuned_db(mode, x, w, level = HALF_POWER_DB, m = scale(mode, x, level))
            db(mode, x, w * m)
          end
        end
      end
    end
  end
end
