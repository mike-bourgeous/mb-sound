module MB
  module Sound
    class Wavetable
      # The named tables (Wavetable[:saw], ...; see Wavetable.register).
      # The classic shapes (saw/ramp, square, triangle) are the exact
      # Fourier series of the naive Tone shapes, band-limited per level, so
      # they match the PolyBLEP Tone#ramp etc. in RMS, harmonic level, and
      # phase, while their peaks differ: the natural Gibbs overshoot reaches
      # about 1.18 on the saw and square (user's choice, 2026-10-06: the
      # exact series over the sigma taper, accepting different peaks into
      # nonlinear effects; the taper option was removed 2026-10-08,
      # preferring the bright top octave), as is :basic, a scan through them
      # at their natural levels.  The other tables (organ, pulses,
      # basic_norm) are normalized by perceived loudness (normalize:
      # :loudness, see Loudness; 2026-10-08): every frame as loud as the saw,
      # so scans and table changes keep their level (organ was scaled to a
      # peak of 1, and the pulses' frames spread 7.3 dB).
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

        # [amplitudes, phases] of a pulse of +width+ with its DC removed (the
        # phases as radians Phases: pi / 2 - pi n width).
        def pulse(width, h = HARMONICS)
          amps = Array.new(h) { |i| n = i + 1; 4.0 / (Math::PI * n) * Math.sin(Math::PI * n * width) }
          phases = Array.new(h) { |i| n = i + 1; Phase.radians(Math::PI / 2 - Math::PI * n * width) }
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
        from_harmonics(amps, normalize: :loudness)
      }

      # Four classic shapes to scan through: sine, triangle, square, saw,
      # each its exact series (natural levels: the square 4.4 dB louder
      # than the saw, the triangle 0.9 dB quieter).
      register(:basic) {
        h = Library::HARMONICS
        sine = [1.0] + Array.new(h - 1, 0.0)
        from_harmonics([sine, Library.triangle, Library.square, Library.saw])
      }

      # :basic with every frame as loud as the saw (normalize: :loudness), so
      # a scan keeps its level.  Named for what it is, basic normalized: it
      # sorts next to :basic in Wavetable.names and echoes the normalize:
      # option.
      register(:basic_norm) {
        h = Library::HARMONICS
        sine = [1.0] + Array.new(h - 1, 0.0)
        from_harmonics([sine, Library.triangle, Library.square, Library.saw], normalize: :loudness)
      }

      # Sixteen pulses from 50% (square) to 3% wide (each as loud as the
      # saw).
      register(:pulses) {
        frames = Array.new(16) { |i| Library.pulse(0.5 - i * (0.47 / 15)) }
        from_harmonics(frames.map(&:first), frames.map(&:last), normalize: :loudness)
      }
    end
  end
end
