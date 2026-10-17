module MB
  module Sound
    module SQ80
      # Original wave tables in the spirit of the SQ-80's waves, built from
      # the manual's descriptions (nothing from its ROM).  Each is built
      # once and cached.  SQ80::Voice picks them by name (see .[]), along
      # with any library table (Wavetable.names).
      module Waves
        # The SQ-80-flavored tables: name => what it is.
        NAMES = {
          formant: 'a FORMT-like vowel: a 1/h spectrum lifted around 750 Hz and 1.4 kHz, one table per 8-semitone key zone (Wavetable::KeyMap), so the formants stay put as the pitch moves',
          synth3: 'SYNTH 3-style equal-level harmonics 1, 2, 3, 5, 7, 11, 13, 17, 19, 23',
          prime: 'PRIME-style equal-level odd harmonics 1, 3, 5, 7, 11',
        }.freeze

        module_function

        # The table (a Wavetable or KeyMap) named +name+: one of NAMES, or a
        # library table (Wavetable[name]); a Wavetable or KeyMap passes
        # through.
        def [](name)
          case name
          when Wavetable, Wavetable::KeyMap then name
          when :formant then formant
          when :synth3 then synth3
          when :prime then prime
          when Symbol, String
            n = name.to_sym
            unless Wavetable.names.include?(n)
              raise ArgumentError, "No SQ-80 wave or wavetable named #{name.inspect}#{GraphIO.suggest(n, NAMES.keys + Wavetable.names)}"
            end
            Wavetable[n]
          else
            raise ArgumentError, "SQ-80 waves are names (#{NAMES.keys.map(&:inspect).join(', ')}, or Wavetable.names), Wavetables, or KeyMaps (got #{name.inspect})"
          end
        end

        # The names of every wave .[] takes.
        def names
          NAMES.keys + Wavetable.names
        end

        # A table of equal-level +harmonics+ (the SQ-80's SYNTH and PRIME
        # waves), scaled to a peak of 1.
        def equal(harmonics)
          amps = Array.new(harmonics.max, 0.0)
          harmonics.each { |h| amps[h - 1] = 1.0 }
          Wavetable::Library.peak_normalized(amps)
        end

        def synth3
          @synth3 ||= equal([1, 2, 3, 5, 7, 11, 13, 17, 19, 23])
        end

        def prime
          @prime ||= equal([1, 3, 5, 7, 11])
        end

        # A formant wave per 8-semitone zone (like the SQ-80's FORMT and
        # VOICE multisamples): a 1/h spectrum lifted around fixed formants
        # at 750 Hz and 1.4 kHz for each zone's center note, so the vowel
        # stays put as the pitch moves.
        def formant
          @formant ||= Wavetable::KeyMap.zones(
            Array.new(11) { |i|
              f0 = 440.0 * 2 ** ((24 + 8 * i + 4 - 69) / 12.0)
              count = [(18000 / f0).floor, 256].min
              amps = Array.new(count) { |k|
                f = f0 * (k + 1)
                peak = 1.0 * Math.exp(-((f - 750) / 220.0)**2) + 0.6 * Math.exp(-((f - 1400) / 300.0)**2)
                (0.25 + 3 * peak) / (k + 1)
              }
              Wavetable::Library.peak_normalized(amps)
            },
            from: 24, size: 8
          )
        end
      end
    end
  end
end
