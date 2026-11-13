module MB
  module Sound
    module GraphNode
      # A formant filter: five resonant bandpass sections in parallel
      # (Filter::SVF :bandpass, each at a formant's frequency, bandwidth, and
      # level), so a bright source takes on a sung vowel's resonances.  The
      # vowel may morph between any number of vowels by a +morph+ value or
      # node (0..1 across the list, clamped, like a wavetable scan),
      # formants may shift by semitones (+shift+, a number, Interval, or
      # node, e.g. key tracking from a note number) keeping their Q, and
      # +width+ scales every bandwidth (smaller is more resonant and
      # whistly; a number or node).
      #
      # Vowels are Symbols from VOWELS (:a, :e, :i, :o, :u) in the given
      # +voice+ (VOICES: :soprano, :alto, :countertenor, :tenor, :bass), or
      # custom Arrays of five [Hz, dB, bandwidth Hz] triples.  Morphing
      # interpolates each formant's frequency and bandwidth on a log scale
      # and its level in dB.
      #
      # With +normalize+ (default) every vowel is scaled so that a signal
      # with equal power per octave from 100 Hz to 10 kHz (pink noise, about
      # a saw's harmonics' trend smoothed over octaves) keeps its power, and
      # the level follows the width (power scales with bandwidth), so
      # vowels and widths can be swapped without level jumps.  Without it
      # the table's levels play as given (F1 at 0 dB peak gain, so the
      # output is much quieter than the input).
      #
      # A FilterBank of five :bandpass bands whose settings come from the
      # bank's morph tables (MB::Sound::FastFilter.filter_bank, exact Ruby
      # mirror FilterBank.process_ruby; filterbank-1 moved the old
      # FastFilter.formant loop into the bank kernel, the same operations):
      # settings are recomputed only on samples where morph, shift, or width
      # change, and the output is the same at any buffer size.  Ends when
      # the input or any parameter node ends.  A plan op (Plan::Op::FilterBank)
      # since filterbank-1 (a plan boundary before).
      #
      # Examples (bin/sound.rb):
      #     play 110.hz.saw.formant(:a)
      #     play 110.hz.saw.formant(:a, :e, :i, :o, :u, morph: 0.2.hz.lfo.at(0..1))
      #     play 110.hz.pulse(0.1).formant(:o, :a, morph: 2.hz.lfo.at(0..1), voice: :soprano, width: 0.5)
      class Formant < FilterBank
        # (FilterBank's traits: its sections' state carries by snapshot)

        # Formant tables from the Csound manual's "Formant Values" appendix
        # (https://csound.com/docs/manual/MiscFormants.html; the same tables
        # as SuperCollider's FormantTable): per voice and vowel, five
        # formants as [frequency Hz, level dB, bandwidth Hz].
        VOICES = {
          soprano: {
            a: [[800, 0, 80], [1150, -6, 90], [2900, -32, 120], [3900, -20, 130], [4950, -50, 140]],
            e: [[350, 0, 60], [2000, -20, 100], [2800, -15, 120], [3600, -40, 150], [4950, -56, 200]],
            i: [[270, 0, 60], [2140, -12, 90], [2950, -26, 100], [3900, -26, 120], [4950, -44, 120]],
            o: [[450, 0, 40], [800, -11, 80], [2830, -22, 100], [3800, -22, 120], [4950, -50, 120]],
            u: [[325, 0, 50], [700, -16, 60], [2700, -35, 170], [3800, -40, 180], [4950, -60, 200]],
          },
          alto: {
            a: [[800, 0, 80], [1150, -4, 90], [2800, -20, 120], [3500, -36, 130], [4950, -60, 140]],
            e: [[400, 0, 60], [1600, -24, 80], [2700, -30, 120], [3300, -35, 150], [4950, -60, 200]],
            i: [[350, 0, 50], [1700, -20, 100], [2700, -30, 120], [3700, -36, 150], [4950, -60, 200]],
            o: [[450, 0, 70], [800, -9, 80], [2830, -16, 100], [3500, -28, 130], [4950, -55, 135]],
            u: [[325, 0, 50], [700, -12, 60], [2530, -30, 170], [3500, -40, 180], [4950, -64, 200]],
          },
          countertenor: {
            a: [[660, 0, 80], [1120, -6, 90], [2750, -23, 120], [3000, -24, 130], [3350, -38, 140]],
            e: [[440, 0, 70], [1800, -14, 80], [2700, -18, 100], [3000, -20, 120], [3300, -20, 120]],
            i: [[270, 0, 40], [1850, -24, 90], [2900, -24, 100], [3350, -36, 120], [3590, -36, 120]],
            o: [[430, 0, 40], [820, -10, 80], [2700, -26, 100], [3000, -22, 120], [3300, -34, 120]],
            u: [[370, 0, 40], [630, -20, 60], [2750, -23, 100], [3000, -30, 120], [3400, -34, 120]],
          },
          tenor: {
            a: [[650, 0, 80], [1080, -6, 90], [2650, -7, 120], [2900, -8, 130], [3250, -22, 140]],
            e: [[400, 0, 70], [1700, -14, 80], [2600, -12, 100], [3200, -14, 120], [3580, -20, 120]],
            i: [[290, 0, 40], [1870, -15, 90], [2800, -18, 100], [3250, -20, 120], [3540, -30, 120]],
            o: [[400, 0, 70], [800, -10, 80], [2600, -12, 100], [2800, -12, 130], [3000, -26, 135]],
            u: [[350, 0, 40], [600, -20, 60], [2700, -17, 100], [2900, -14, 120], [3300, -26, 120]],
          },
          bass: {
            a: [[600, 0, 60], [1040, -7, 70], [2250, -9, 110], [2450, -9, 120], [2750, -20, 130]],
            e: [[400, 0, 40], [1620, -12, 80], [2400, -9, 100], [2800, -12, 120], [3100, -18, 120]],
            i: [[250, 0, 60], [1750, -30, 90], [2600, -16, 100], [3050, -22, 120], [3340, -28, 120]],
            o: [[400, 0, 40], [750, -11, 80], [2400, -21, 100], [2600, -20, 120], [2900, -40, 120]],
            u: [[350, 0, 40], [600, -20, 80], [2400, -32, 100], [2675, -28, 120], [2950, -36, 120]],
          },
        }.transform_values { |v| v.transform_values { |f| f.map(&:freeze).freeze }.freeze }.freeze

        # The vowel names.
        VOWELS = VOICES[:bass].keys.freeze

        # The default voice.
        DEFAULT_VOICE = :tenor

        # The normalization's reference band (Hz) and resolution (points,
        # log-spaced: equal weight per octave).
        NORMALIZE_RANGE = 100.0..10000.0
        NORMALIZE_POINTS = 240

        # ln(10) / 20, for dB levels as natural logs.
        DB_LOG = Math.log(10) / 20

        # The number of formant sections (bandpasses).
        SECTIONS = 5

        # The narrowest width (bandwidth scale), as in the kernel.
        MIN_WIDTH = 0.01

        # The vowels as given (Symbols or custom formant Arrays).
        attr_reader :vowels

        # The voice for Symbol vowels.
        attr_reader :voice

        # The morph position (a Float or a node), 0..1 across the vowels.
        attr_reader :morph

        # The formant shift in semitones (a Float or a node).
        attr_reader :shift

        # The formants of each vowel after normalization: an Array (one per
        # vowel) of five [Hz, dB, bandwidth Hz] triples.
        attr_reader :table

        # Creates a formant filter on +input+ (see the class description).
        def initialize(input, vowels: [:a], voice: DEFAULT_VOICE, morph: 0, shift: 0, width: 1, normalize: true, sample_rate: nil)
          raise ArgumentError, "Formant input must be a graph node (got #{input.inspect})" unless input.respond_to?(:sample)
          raise ArgumentError, "Unknown voice #{voice.inspect} (#{VOICES.keys.map(&:inspect).join(', ')})" unless VOICES.include?(voice)
          vowels = Array(vowels) if vowels.is_a?(Symbol)
          raise ArgumentError, 'Give at least one vowel' if vowels.empty?

          rate = (sample_rate || input.sample_rate).to_f
          @vowels = vowels.freeze
          @voice = voice
          @formant_normalize = !!normalize
          shift = shift.to_semitones if shift.is_a?(MB::Sound::Interval)
          morph = param(morph, 'morph')
          shift = param(shift, 'shift')
          width = param(width, 'width')
          raise ArgumentError, "Formant width must be positive (got #{width})" if width.is_a?(Float) && !(width > 0)

          raw = vowels.map { |v| vowel_formants(v) }
          @table = raw.map { |f| @formant_normalize ? normalized(f, rate) : f }.freeze

          # The bank's morph tables: natural logs of each vowel's section
          # frequencies, qualities, and linear gains
          logs = @table.flat_map { |f| f.map { |hz, _, _| Math.log(hz) } } +
                 @table.flat_map { |f| f.map { |hz, _, bw| Math.log(hz.to_f / bw) } } +
                 @table.flat_map { |f| f.map { |_, db, _| db * DB_LOG } }
          bands = Array.new(SECTIONS) { { type: :bandpass, frequency: 1000.0 } } # (frequencies and widths from the tables)

          super(input, bands: bands, normalize: @formant_normalize ? :width_law : false, sample_rate: rate,
                       morph: { logs: logs, position: morph, shift: shift, scale: width })

          # The morph position, shift, and width as Floats or the bank's
          # sampler branches
          @morph = branch_of(morph)
          @shift = branch_of(shift)
          @width = branch_of(width)
          @node_type_name = 'Formant'
        end

        # Whether vowels are level-normalized (see the class description).
        def normalize
          @formant_normalize
        end

        def sources
          s = { input: @input }
          s[:morph] = @morph unless @morph.is_a?(Float)
          s[:shift] = @shift unless @shift.is_a?(Float)
          s[:width] = @width unless @width.is_a?(Float)
          s
        end

        def to_s
          names = @vowels.map { |v| v.is_a?(Symbol) ? v.to_s : 'custom' }.join('>')
          "Formant #{names} (#{@voice})"
        end

        # The combined response (complex, a DComplex) at +freqs+ Hz of
        # five formants given as [Hz, dB, bandwidth Hz] triples, at this
        # node's sample rate (or +rate+).
        def response(formants, freqs, rate = @sample_rate)
          omega = Numo::DFloat.cast(freqs) * (2 * Math::PI / rate)
          formants.sum(Numo::DComplex.zeros(omega.length)) do |f, db, bw|
            Filter::SVF.new(:bandpass, rate, f, quality: f.to_f / bw, db_gain: db).response(omega)
          end
        end

        private

        # A setting as a Float, or the node itself (the bank takes its
        # sampler branch).
        def param(value, name)
          return value.to_f if value.is_a?(Numeric) && !value.is_a?(Complex)
          return value if value.respond_to?(:sample)
          raise ArgumentError, "Formant #{name} must be a number or a node (got #{value.inspect})"
        end

        # A setting's Float, or the sampler branch the bank reads for it.
        def branch_of(value)
          value.is_a?(Float) ? value : @signals[@signal_index.fetch(value)]
        end

        # The five [Hz, dB, bandwidth] triples of vowel +v+.
        def vowel_formants(v)
          case v
          when Symbol
            VOICES[@voice].fetch(v) do
              raise ArgumentError, "Unknown vowel #{v.inspect} (#{VOWELS.map(&:inspect).join(', ')}, or five [Hz, dB, bandwidth] triples)"
            end
          when Array
            unless v.length == 5 && v.all? { |f| f.is_a?(Array) && f.length == 3 && f.all? { |e| e.is_a?(Numeric) } && f[0] > 0 && f[2] > 0 }
              raise ArgumentError, "A custom vowel is five [Hz, dB, bandwidth Hz] triples (got #{v.inspect})"
            end
            v.map { |f| [f[0].to_f, Decibels.db_of(f[1], 'formant level'), f[2].to_f] }
          else
            raise ArgumentError, "Vowels are Symbols (#{VOWELS.map(&:inspect).join(', ')}) or five [Hz, dB, bandwidth] triples (got #{v.inspect})"
          end
        end

        # +formants+ with every level raised so the vowel's mean power gain
        # over NORMALIZE_RANGE (log-spaced, so equal weight per octave) is 1.
        def normalized(formants, rate)
          lo = Math.log(NORMALIZE_RANGE.begin)
          hi = Math.log(NORMALIZE_RANGE.end)
          freqs = Numo::NMath.exp(Numo::DFloat.linspace(lo, hi, NORMALIZE_POINTS))
          power = (response(formants, freqs, rate).abs ** 2).mean
          offset = -10 * Math.log10(power)
          formants.map { |f, db, bw| [f, db + offset, bw] }
        end
      end

    end
  end
end
