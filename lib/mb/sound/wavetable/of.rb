module MB
  module Sound
    class Wavetable
      class << self
        # A scan table built from a list of frame sources, one frame each
        # (several for tables with several frames), in order, so
        # `pitch.wavetable(t, scan: x)` morphs through them (omnibus9,
        # 2026-10-18; the console's WavetableMethods#wavetable_of, which
        # prints itself back as Ruby).  Sources:
        # - a Symbol (or String) naming a library table (Wavetable.names),
        #   e.g. :sine, :saw; every frame of a scan table such as :basic
        # - an Array of numbers: harmonic amplitudes (first for harmonic 1),
        #   as for .from_harmonics
        # - a Proc or Method of the phase in cycles (0...1) returning a
        #   sample, called once per sample of a +size+-sample cycle
        # - a cycle-mode Wavetable (its frames)
        # - a Numo::NArray: one cycle (1D, any length) or one per row (2D)
        #
        # Frames keep at most (+size+ - 1) / 2 harmonics, are lined up in
        # time (+align+, as .from_samples does), and are band-limited per
        # level like every table.  +normalize+: :peak (the default) removes
        # each frame's DC and scales it to a peak of 1; :loudness scales
        # every frame to the library saw's perceived loudness (see
        # Loudness), so a scan keeps its level; nil keeps the sources'
        # levels.  +mips+, +interpolation+, +name+ as for .from_harmonics.
        #
        #     t = Wavetable.of(:sine, :saw, [1, 0.5, 0.33], ->(p) { Math.sin(2 * Math::PI * p) ** 3 })
        #     220.hz.wavetable(t, scan: 0.2.hz.lfo.at(0..1))
        def of(*sources, size: 2048, normalize: :peak, align: true, mips: :default, interpolation: nil, name: nil)
          raise ArgumentError, 'Wavetable.of needs at least one frame source (a table name, harmonic amplitudes, a function of phase, a table, or samples)' if sources.empty?
          unless size.is_a?(Integer) && size >= 8
            raise ArgumentError, "Wavetable.of size: is the samples per cycle, an Integer of at least 8 (got #{size.inspect})"
          end
          unless [:peak, :loudness, nil, false].include?(normalize)
            raise ArgumentError, "Wavetable.of normalize: is :peak, :loudness, or nil (got #{normalize.inspect})"
          end

          rows = sources.each_with_index.flat_map { |s, i| source_spectra(s, size, i) }
          harmonics = [rows.map { |r| r.length - 1 }.max, (size - 1) / 2].min
          spectra = Numo::DComplex.zeros(rows.length, harmonics + 1)
          rows.each_with_index do |r, i|
            n = [r.length, harmonics + 1].min
            spectra[i, 0...n] = r[0...n]
          end
          spectra = Builder.align(spectra) if align && rows.length > 1

          if normalize == :peak
            spectra[true, 0] = 0
            peaks = Builder.synthesize(spectra, size).abs.max(axis: 1)
            rows.length.times do |i|
              spectra[i, true] = spectra[i, true] / peaks[i] if peaks[i] > 0
            end
          end

          new(spectra: spectra, size: size, mips: mips, interpolation: interpolation, normalize: normalize == :loudness ? :loudness : nil, name: name)
        end

        private

        # The spectra rows (DComplex, column 0 the DC) of source +s+ (see
        # .of), the +index+-th.
        def source_spectra(s, size, index)
          case s
          when Symbol, String
            table_spectra(self[s], s)
          when KeyMap
            raise ArgumentError, "Wavetable.of source #{index + 1}: a KeyMap holds several tables; give one of them"
          when Wavetable
            table_spectra(s, s)
          when Array
            unless !s.empty? && s.all? { |a| a.is_a?(Numeric) && a.real? }
              raise ArgumentError, "Wavetable.of source #{index + 1}: an Array is harmonic amplitudes (numbers, first for harmonic 1), got #{s.inspect[0, 60]}"
            end
            rows_of(Builder.spectra_from_harmonics(s))
          when Proc, Method
            cycle = Numo::DFloat.cast(Array.new(size) { |k| Float(s.call(k.to_f / size)) })
            rows_of(Builder.spectra_from_frames(cycle))
          when Numo::NArray
            raise ArgumentError, "Wavetable.of source #{index + 1}: samples are one cycle (1D) or one per row (2D)" unless [1, 2].include?(s.ndim)
            raise ArgumentError, "Wavetable.of source #{index + 1}: complex samples aren't supported" if s.is_a?(Numo::SComplex) || s.is_a?(Numo::DComplex)
            rows_of(Builder.spectra_from_frames(Numo::DFloat.cast(s)))
          else
            raise ArgumentError,
              "Wavetable.of source #{index + 1} (#{s.class}): give a table name (#{names.first(4).map(&:inspect).join(', ')}, ...), " \
              'harmonic amplitudes ([1, 0.5, 0.33]), a function of phase (->(p) { ... }), a Wavetable, or samples (a Numo::NArray)'
          end
        end

        def table_spectra(t, what)
          raise ArgumentError, "Wavetable.of: #{what.inspect} is a sample-mode table (give cycle tables)" unless t.mode == :cycle
          raise ArgumentError, "Wavetable.of: #{what.inspect} is a complex table (give real tables)" if t.complex?
          rows_of(t.cycle_spectra)
        end

        def rows_of(spectra)
          Array.new(spectra.shape[0]) { |r| spectra[r, true].dup }
        end
      end

      # Cycle mode: the harmonic spectra of the frames (see
      # Builder.spectra_from_frames), for Wavetable.of.
      def cycle_spectra
        @spectra || Builder.spectra_from_frames(frames)
      end
    end
  end
end
