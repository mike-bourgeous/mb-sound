module MB
  module Sound
    class Wavetable
      # The named tables (Wavetable[:saw], ...; see Wavetable.register).
      # The classic shapes (saw/ramp, square, triangle, basic, pulses) are
      # the exact Fourier series of the naive Tone shapes, band-limited per
      # level, so they match the PolyBLEP Tone#ramp etc. in RMS, harmonic
      # level, and phase, while their peaks differ: the natural Gibbs
      # overshoot reaches about 1.18 on the saw and square (user's choice,
      # 2026-10-06: the exact series over the sigma taper, accepting
      # different peaks into nonlinear effects; the taper option was removed
      # 2026-10-08, preferring the bright top octave).  Organ is scaled to a
      # peak near 1.
      module Library
        HARMONICS = 1023

        module_function

        # A table from +amplitudes+ (and +phases+) scaled to a peak of 1.
        def peak_normalized(amplitudes, phases = nil, **options)
          t = Wavetable.from_harmonics(amplitudes, phases, **options)
          peak = t.frames.abs.max
          return t if peak == 0

          scale = ->(rows) { rows.is_a?(Array) && rows[0].is_a?(Array) ? rows.map { |r| r.map { |a| a / peak } } : rows.map { |a| a / peak } }
          Wavetable.from_harmonics(scale.(amplitudes), phases, **options)
        end

        # Fourier amplitudes of a ramp (rising from 0 at phase 0).
        def saw(h = HARMONICS)
          Array.new(h) { |i| n = i + 1; (n.odd? ? 2.0 : -2.0) / (Math::PI * n) }
        end

        def square(h = HARMONICS)
          Array.new(h) { |i| n = i + 1; n.odd? ? 4.0 / (Math::PI * n) : 0.0 }
        end

        def triangle(h = HARMONICS)
          Array.new(h) { |i| n = i + 1; n.odd? ? (((n - 1) / 2).even? ? 8.0 : -8.0) / (Math::PI**2 * n**2) : 0.0 }
        end

        # [amplitudes, phases] of a pulse of +width+ with its DC removed.
        def pulse(width, h = HARMONICS)
          amps = Array.new(h) { |i| n = i + 1; 4.0 / (Math::PI * n) * Math.sin(Math::PI * n * width) }
          phases = Array.new(h) { |i| n = i + 1; Math::PI / 2 - Math::PI * n * width }
          [amps, phases]
        end
      end

      register(:sine) { from_harmonics([1.0]) }
      register(:saw) { from_harmonics(Library.saw) }
      register(:ramp) { named(:saw) }
      register(:square) { from_harmonics(Library.square) }
      register(:triangle) { from_harmonics(Library.triangle) }

      # Drawbar organ: 8', 4', 2 2/3', 2', 1 3/5', 1 1/3', 1' (harmonics 1,
      # 2, 3, 4, 5, 6, 8) at 8 8 6 6 0 4 0 4 (out of 8).
      register(:organ) {
        bars = { 1 => 8, 2 => 8, 3 => 6, 4 => 6, 6 => 4, 8 => 4 }
        amps = Array.new(8) { |i| bars.fetch(i + 1, 0) / 8.0 }
        Library.peak_normalized(amps)
      }

      # Four classic shapes to scan through: sine, triangle, square, saw.
      register(:basic) {
        h = Library::HARMONICS
        sine = [1.0] + Array.new(h - 1, 0.0)
        from_harmonics([sine, Library.triangle, Library.square, Library.saw])
      }

      # Sixteen pulses from 50% (square) to 3% wide.
      register(:pulses) {
        frames = Array.new(16) { |i| Library.pulse(0.5 - i * (0.47 / 15)) }
        from_harmonics(frames.map(&:first), frames.map(&:last))
      }
    end
  end
end
