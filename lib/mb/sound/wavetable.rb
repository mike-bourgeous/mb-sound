require 'numo/pocketfft'

module MB
  module Sound
    # A wavetable: single-cycle waveforms (frames) to morph between, or a
    # sampled sound with a root note, stored as band-limited levels
    # (mipmaps) so it plays without aliasing at any pitch.  Play one with a
    # Tone (`440.hz.wavetable(table, scan: node)`, see Tone#wavetable), or
    # look one up with any phase signal (`phase.wavetable(table)`, see
    # GraphNode::Wavetable).
    #
    # == Making tables
    #
    #     Wavetable.from_harmonics([1, 0.5, 0.25])       # sine harmonics
    #     Wavetable.from_harmonics([[1], [1, 0.5, 0.33]]) # two frames
    #     Wavetable.from_samples(frames)                  # 2D NArray, a cycle per row
    #     Wavetable.from_function(frames: 8) { |phase, scan| ... }
    #     Wavetable.from_file('sounds/synth0.flac')       # sliced into cycles
    #     Wavetable.from_file('sounds/piano_120hz_b2.flac', mode: :sample, root: B2)
    #     Wavetable[:saw]                                 # the named library
    #     Wavetable['sounds/drums_wavetable.flac']        # a file
    #     Wavetable[array]                                # samples
    #
    # == Modes
    #
    # - :cycle (default): each frame is one period; the tone's phase reads
    #   it, and +scan+ (0..1) morphs linearly across the frames (frame
    #   phases are aligned at build time, so morphs don't comb-filter).
    # - :sample: one sound of any length played at the tone's pitch relative
    #   to its +root+ (Hz, a Pitch, or a Note), with +loop:+ (a Range of
    #   source samples, or of Lengths such as `0.5.seconds`) or as a one-shot
    #   that ends (unless the tone has a reset input, which restarts it).
    #   Several samples across the keyboard: see KeyMap.
    #
    # == Levels (mipmaps)
    #
    # Each level keeps fewer harmonics (cycle mode) or a lower band (sample
    # mode), +mips:+ apart: :half_octave (DEFAULT_MIPS; a ratio of the
    # square root of 2), :octave, :third_octave, any ratio above 1, an Array of harmonic counts (cycle
    # mode), or false for one level from the samples as given (the classic
    # aliasing sound, read with :cubic by default).  Levels are stored
    # OVERSAMPLE (4) times above their highest harmonic, so the
    # default :optimal interpolator (below) is accurate.
    #
    # A tone picks levels by its phase increment per sample (including
    # phase modulation and the fastest part of a phase warp): the brightest
    # level whose highest harmonic stays below #ceiling (the highest
    # frequency that can't alias into the audible band: harmonics above
    # Nyquist fold back above AUDIBLE_LIMIT, 20 kHz), crossfaded linearly
    # (by increment) into the next level over the last LEVEL_FADE octave
    # (a fifth of an octave) before that limit, so brightness doesn't step
    # between levels.  At 48 kHz with half-octave levels, every harmonic
    # below about 19.8 kHz plays at full level at any pitch, and the top
    # harmonic sits between 19.8 and 28 kHz (above 24 kHz only folding
    # back above 20 kHz); with octave levels the band dips to 14 kHz, an
    # audible brightness change as a sweep crosses levels.  A sample plays
    # its own level, unfiltered, up to its root pitch.
    #
    # Synced tones (Tone#sync) read separate sync levels (#sync_levels):
    # every harmonic count up to 8, then a quarter octave apart, with every
    # harmonic below 20 kHz (#sync_ceiling; sync spreads each harmonic's
    # spectrum, so none may fold back from above Nyquist), always
    # crossfading into the next level, so brightness follows the pitch
    # smoothly instead of stepping every octave.
    #
    # == Interpolation
    #
    # +interpolation:+ :none (drop-sample, lo-fi), :linear, :cubic
    # (Catmull-Rom), :optimal, or :sinc.  :optimal (the default for
    # band-limited levels) is Olli Niemitalo's 4-point, 4th-order optimal
    # interpolator for 4x oversampled data ("Polynomial Interpolators for
    # High-Quality Resampling of Oversampled Audio", 2001): 101 dB modified
    # SNR at 4x, against 89 dB for the 4-point 3rd-order design, 66-70 dB
    # for the 2x designs, and 44 dB for cubic Hermite at 4x; 4x
    # oversampling doubles the table memory of 2x but puts interpolation
    # errors below the PolyBLEP oscillators' aliasing.  Its passband
    # droop (11% at the top of a level's band) is undone by storing
    # emphasized levels for it (see Emphasis), which leaves errors about
    # 100 dB down.  :sinc is a 24-tap Kaiser-windowed sinc (see
    # SINC_KERNEL), about 112 dB down, for sample mode at the highest
    # quality (about 6 times the cost of :optimal).
    #
    # == Complex tables
    #
    # With +complex: true+ the levels are analytic (no negative
    # frequencies; the imaginary part is the Hilbert transform of the real
    # part) and tones output SComplex samples.
    #
    # Lookups run in C (MB::Sound::FastWavetable) with exact Ruby mirrors
    # (#oscillate_ruby, #lookup_ruby, #play_ruby).
    class Wavetable
      # Levels are stored this many times above their highest harmonic.
      OVERSAMPLE = 4

      # Extra samples stored before and after each level row (wrapped
      # around in cycle mode), so interpolators read without wrapping.
      GUARD = 16

      # The shortest cycle-mode level, in samples.
      MIN_LENGTH = 32

      # Harmonics may pass Nyquist as long as they fold back above this
      # frequency (Hz); see #ceiling.
      AUDIBLE_LIMIT = 20000.0

      # Levels crossfade into the next over this many octaves of pitch
      # below the #ceiling (where their highest harmonic would alias into
      # the audible band).
      LEVEL_FADE = 0.2

      # Sample-mode levels roll off over this fraction of their band (a
      # raised cosine), so filtering doesn't ring for long.
      SAMPLE_TRANSITION = 0.25

      # Sample mode stops adding levels below this band (Hz).
      MIN_SAMPLE_BAND = 40.0

      # Named level spacings (ratios of bandwidth between levels).
      SPACINGS = {
        octave: 2.0,
        half_octave: Math.sqrt(2.0),
        third_octave: 2.0**(1.0 / 3.0),
      }.freeze

      # The default level spacing (+mips:+) in both modes: half an octave
      # (user's choice, 2026-10-07), so brightness barely changes as a
      # tone's pitch moves across levels.  In a slow saw sweep the 10-20 kHz
      # band dips at most 0.7 dB below the unfiltered saw (octave levels:
      # 2.8 dB) and the brightness (mean harmonic) at most 3.5% (11%); a
      # piano sample swept above its root dips 2.5 dB (5.6 dB).  Twice as
      # many pitches crossfade two levels (40% instead of 20%), so sweeps
      # and FM cost 5-8% more CPU per sample, and a steady pitch inside a
      # crossfade 1.5 times as much (36 instead of 24 ns); levels take
      # 1.5-1.9 times the memory.
      DEFAULT_MIPS = :half_octave

      # Interpolators (see the class description) and their kernel codes.
      INTERPOLATIONS = { none: 0, linear: 1, cubic: 2, optimal: 3, sinc: 4 }.freeze

      # Wrapping modes for phases outside 0...1 in GraphNode::Wavetable.
      WRAP_MODES = [:wrap, :bounce, :clamp, :zero, :shape].freeze

      MODES = [:cycle, :sample].freeze

      # The kernel of the :sinc interpolator: [table, half width, table
      # entries per sample, max rate] as for DelayLine::SINC_KERNEL, from
      # the same builder, but with a Kaiser beta of 12 instead of 6: levels
      # are 4x oversampled, so they need a deep stopband (images 112 dB
      # down) rather than a passband flat to Nyquist (the delay line's
      # kernel leaves images about 65 dB down).
      SINC_KERNEL = [DelayLine.sinc_table(beta: 12).freeze, DelayLine::SINC_HALF, DelayLine::SINC_RESOLUTION, 1.0].freeze

      # The registry of named tables (see .register).
      @registry = {}

      class << self
        # A table of sine harmonics: +amplitudes+ (first for harmonic 1) with
        # +phases+ (radians; nil for all 0, every harmonic a sine starting
        # at 0), each an Array or 1D NArray, or an Array of them for several
        # frames (scanned in order).  Amplitudes are kept exactly (no
        # normalizing), so e.g. the Fourier series of a ramp plays at the
        # same level as Tone#ramp, Gibbs overshoot included (unless +taper+ is
        # :sigma: each level's harmonics are scaled by Lanczos sigma factors,
        # see Builder.taper_gains, so its peaks stay near 1).  +size+ is the
        # length of #frames (and caps the harmonics at size / 2 - 1).  See
        # the class description for +complex+, +mips+, +interpolation+;
        # +align+ lines up frames in time (off by default, since the phases
        # are given).
        def from_harmonics(amplitudes, phases = nil, size: 2048, complex: false, mips: DEFAULT_MIPS, interpolation: nil, align: false, taper: nil, name: nil)
          spectra = Builder.spectra_from_harmonics(amplitudes, phases)
          max = (size - 1) / 2
          spectra = spectra[true, 0..max] if spectra.shape[1] - 1 > max
          spectra = Builder.align(spectra) if align && spectra.shape[0] > 1

          new(spectra: spectra, size: size, complex: complex, mips: mips, interpolation: interpolation, taper: taper, name: name)
        end

        # A table from samples.  In cycle mode (default), +data+ is one
        # cycle per row (a 2D NArray, an Array of rows, or one 1D cycle);
        # +align+ lines frames up in time (see the class description) and
        # +normalize+ removes DC and scales each frame to a peak of 1.  In
        # sample mode, +data+ is the sound (1D; +root+, +loop+, and
        # +sample_rate+ apply).  +harmonics+ limits a cycle table's
        # harmonics (default: all that fit the frame size).
        def from_samples(data, mode: :cycle, complex: false, mips: DEFAULT_MIPS, interpolation: nil, align: true, aligned: false, normalize: false, taper: nil, harmonics: nil, root: nil, loop: nil, sample_rate: 48000, name: nil, source_info: nil)
          data = to_narray(data)

          case mode
          when :cycle
            data = data.reshape(1, data.length) if data.ndim == 1
            raise ArgumentError, 'Cycle frames must be a 1D or 2D NArray' unless data.ndim == 2

            data = data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex) ? Numo::SComplex.cast(data) : Numo::SFloat.cast(data)
            data = Wavetable.normalize(data.dup) if normalize
            new(frames: data, complex: complex, mips: mips, interpolation: interpolation, align: align, aligned: aligned, taper: taper, harmonics: harmonics, name: name, source_info: source_info)

          when :sample
            raise ArgumentError, 'A sample must be a 1D NArray' unless data.ndim == 1
            raise ArgumentError, 'A sample needs a root: (Hz, a Pitch, or a Note)' if root.nil?

            new(mode: :sample, data: data, complex: complex, mips: mips, interpolation: interpolation,
              root: root, loop: loop, sample_rate: sample_rate, name: name, source_info: source_info)

          else
            raise ArgumentError, "Unknown wavetable mode #{mode.inspect} (#{MODES.join(', ')})"
          end
        end

        # A cycle-mode table from a block called for each of +frames+ frames
        # with the phase of each sample in cycles (a DFloat of +size+ values
        # from 0 to just under 1) and the frame's scan position (0..1),
        # returning +size+ samples (an NArray or Array).  Other options as
        # for .from_samples.
        #
        #     Wavetable.from_function(frames: 8) { |ph, s| Numo::NMath.sin(ph * 2 * Math::PI) ** (1 + 8 * s) }
        def from_function(frames: 1, size: 2048, **options)
          phase = Numo::DFloat.new(size).seq / size
          rows = Array.new(frames) { |f|
            row = yield phase, frames > 1 ? f.to_f / (frames - 1) : 0.0
            row = to_narray(row)
            raise ArgumentError, "Frame #{f} has #{row.length} samples instead of #{size}" unless row.length == size
            row
          }

          from_samples(Numo::NArray.concatenate(rows.map { |r| Numo::DFloat.cast(r).reshape(1, size) }), **options)
        end

        # A table from a sound file.  In cycle mode, a file saved by #save,
        # .save_frames, or bin/make_wavetable.rb loads its frames, and any
        # other sound is sliced into +slices+ cycles (see .load_frames).  In
        # sample mode, the sound (mixed to mono) with +root+ (estimated
        # from the sound if nil) and +loop+.  Other options as for
        # .from_samples.
        #
        # Settings saved by #save (see #metadata) are the defaults: the mode,
        # levels, taper, interpolation, name, root, and loop; frames saved
        # aligned aren't aligned again.
        def from_file(path, mode: nil, slices: 10, ratio: 1.0, root: nil, loop: nil, **options)
          path = path.path if path.respond_to?(:path)

          info = {}
          channels = MB::Sound.read(path.to_s, metadata_out: info)
          info = table_metadata(info)
          mode ||= info[:mode]&.to_sym || :cycle
          options[:name] ||= info[:name] || File.basename(path.to_s)
          options[:mips] = parse_saved_spacing(info[:spacing]) if !options.include?(:mips) && info.include?(:spacing)
          options[:taper] = info[:taper].to_sym if !options.include?(:taper) && info[:taper] && info[:taper] != ''
          options[:interpolation] ||= info[:interpolation]&.to_sym
          options[:harmonics] ||= info[:harmonics].to_i if mode == :cycle && info[:harmonics]
          options.delete(:interpolation) if options[:interpolation].nil?

          case mode
          when :cycle
            source = {}
            frames = load_frames(path.to_s, slices: slices, ratio: ratio, metadata_out: source)
            if source[:aligned].to_s == 'true' && !options.include?(:align)
              options[:align] = false
              options[:aligned] = true
            end
            from_samples(frames, source_info: source, **options)

          when :sample
            data = channels.sum / channels.length
            data = data * info[:scale].to_f if info[:scale]
            root ||= info[:root]&.to_f || MB::Sound.freq_estimate(data, sample_rate: 48000)
            loop ||= parse_saved_loop(info[:loop])
            from_samples(data, mode: :sample, root: root, loop: loop, sample_rate: 48000, source_info: info, **options)

          else
            raise ArgumentError, "Unknown wavetable mode #{mode.inspect} (#{MODES.join(', ')})"
          end
        end

        # A table from +source+: a Wavetable (itself), a Symbol (a named
        # table; see .register and .names), a String, Pathname, or File (a
        # sound file; see .from_file), or an Array or NArray (samples; see
        # .from_samples).
        def [](source)
          case source
          when Wavetable
            source
          when Symbol
            named(source)
          when String, File
            from_file(source)
          when Numo::NArray, Array
            from_samples(source)
          else
            return from_file(source.to_s) if defined?(Pathname) && source.is_a?(Pathname)

            raise ArgumentError, "Can't make a wavetable from #{source.inspect}"
          end
        end

        # Level spacing from a saved tag (see #metadata).
        def parse_saved_spacing(v)
          case v
          when nil, '', 'none' then false
          when Numeric then v.to_f
          when /\A[\d.]+\z/ then v.to_f
          else v.to_s.split(',').map(&:to_i)
          end
        end

        # A loop Range from a saved "begin...end" tag.
        def parse_saved_loop(v)
          return nil if v.nil? || v == ''

          a, b = v.to_s.split('...').map(&:to_i)
          a...b
        end

        # Like .[], but passing a KeyMap through (for Tone#wavetable).
        def for(source)
          source.is_a?(KeyMap) ? source : self[source]
        end

        # Adds a named table to the library (see .[]): +table+ (anything
        # .[] accepts), or a block that builds it when first used.
        def register(name, table = nil, &block)
          raise ArgumentError, 'Give a table or a block, not both' if table && block
          raise ArgumentError, 'Give a table or a block' unless table || block

          @registry[name.to_sym] = block || table
          @cache&.delete(name.to_sym)
          name.to_sym
        end

        # The names of the library's tables.
        def names
          @registry.keys.sort
        end

        # The named table +name+ (built and cached on first use).
        def named(name)
          entry = @registry.fetch(name.to_sym) {
            raise ArgumentError, "No wavetable named #{name.inspect} (try #{names.map(&:inspect).join(', ')})"
          }

          @cache ||= {}
          @cache[name.to_sym] ||= begin
            t = entry.respond_to?(:call) ? entry.call : self[entry]
            t.name ||= name.to_s
            t
          end
        end

        private

        def to_narray(data)
          return data if data.is_a?(Numo::NArray)

          if data.is_a?(Array) && data.any? { |r| r.is_a?(Array) || r.is_a?(Numo::NArray) }
            rows = data.map { |r| r.is_a?(Numo::NArray) ? r.to_a : r }
            return (rows.flatten.any?(Complex) ? Numo::DComplex : Numo::DFloat).cast(rows)
          end

          (data.any?(Complex) ? Numo::DComplex : Numo::DFloat).cast(data)
        end
      end

      # One band-limited level: +data+ (a 2D SFloat or SComplex, [frames,
      # count + 2 * GUARD]), +count+ samples (cycle mode: per cycle),
      # +rate+ (stored samples per cycle or per source sample), and the
      # highest +bandwidth+ (harmonics, or cycles per source sample).
      Level = Struct.new(:data, :count, :rate, :bandwidth)

      # :cycle or :sample.
      attr_reader :mode

      # The number of frames (scan positions) in cycle mode; 1 in sample
      # mode.
      attr_reader :frame_count

      # Cycle mode: samples per frame in #frames.  Sample mode: the sound's
      # length in samples.
      attr_reader :size

      # The level spacing (a ratio), an Array of harmonic counts, or nil
      # without levels (see #mipped?).
      attr_reader :spacing

      # The default interpolation (see INTERPOLATIONS).
      attr_reader :interpolation


      # Sample mode: the root frequency in Hz, the loop as a Range of source
      # samples (begin...end; nil for a one-shot), and the sound's sample
      # rate.
      attr_reader :root, :loop, :sample_rate

      # Cycle mode: the harmonic spectra (DComplex [frames, harmonics + 1];
      # see Builder.spectra_from_frames), or nil for unmipped tables.
      attr_reader :spectra

      # The harmonic taper (:sigma) or nil (see .from_harmonics).
      attr_reader :taper

      # True if the frames were aligned in time (see .from_samples).
      def aligned?
        @aligned
      end

      # What the table was made from, as saved by #save and loaded by
      # .from_file (e.g. the detected frequency and note of a sliced sound;
      # see .slice_frames).
      attr_reader :source_info

      # A name for displays (the library name or file name), or nil.
      attr_accessor :name

      # Use the class methods (.from_harmonics, .from_samples, ...).
      def initialize(mode: :cycle, spectra: nil, frames: nil, data: nil, size: nil, complex: false, mips: DEFAULT_MIPS, interpolation: nil, align: false, aligned: false, taper: nil, harmonics: nil, root: nil, loop: nil, sample_rate: 48000, name: nil, source_info: nil)
        raise ArgumentError, "Unknown wavetable mode #{mode.inspect} (#{MODES.join(', ')})" unless MODES.include?(mode)

        @mode = mode
        @complex = !!complex
        @spacing = parse_spacing(mips)
        @taper = taper
        @aligned = !!aligned
        @harmonic_limit = harmonics
        @source_info = (source_info || {}).reject { |k, _| SAVED_KEYS.include?(k) }.freeze
        Builder.taper_gains(taper, 1) if taper # checks it
        @name = name
        @kernel_specs = {}
        @interpolation = interpolation || (@spacing ? :optimal : :cubic)
        raise ArgumentError, "Unknown interpolation #{@interpolation.inspect} (#{INTERPOLATIONS.keys.join(', ')})" unless INTERPOLATIONS.include?(@interpolation)

        if mode == :cycle
          build_cycle(spectra, frames, size, align)
        else
          build_sample(data, root, loop, sample_rate)
        end

        @level_sets = {}
        freeze_contents
        level_set(emphasis?(nil))
      end

      # The band-limited levels (Level structs), brightest first, read by
      # +interpolation+ (default #interpolation; the :optimal interpolator
      # reads levels with its pre-emphasis, see Emphasis; built on first
      # use).
      def levels(interpolation = nil)
        level_set(emphasis?(interpolation))[0]
      end

      # Sample mode with a loop: the loop's levels (one period each, wrapped
      # around), as for #levels.
      def loop_levels(interpolation = nil)
        level_set(emphasis?(interpolation))[1]
      end

      # True for analytic (complex) tables.
      def complex?
        @complex
      end

      # True if the table has band-limited levels (see the class
      # description).
      def mipped?
        !@spacing.nil?
      end

      # True in sample mode without a loop (a one-shot ends).
      def one_shot?
        @mode == :sample && @loop.nil?
      end

      # Cycle mode: the frames as a 2D NArray (a cycle per row, #size
      # samples; resynthesized from the spectra for harmonic tables).  Sample
      # mode: the sound as a 1D NArray.
      def frames
        return @data unless @mode == :cycle

        # Tables made from spectra synthesize their frames on first use (the
        # kernels read the levels; HarmonicTable rebuilds tables often)
        @frames ||= Builder.synthesize(@spectra, @size, complex: @complex, taper: @taper).freeze
      end

      # Cycle mode: the number of harmonics of the brightest level.
      def harmonics
        @spectra ? @spectra.shape[1] - 1 : nil
      end

      # The highest frequency, in cycles per sample at +sample_rate+, that
      # levels may reach: harmonics above Nyquist fold back to 1 minus their
      # frequency, so up to 1 - AUDIBLE_LIMIT / sample_rate they land above
      # AUDIBLE_LIMIT (at least 0.5: Nyquist).
      def ceiling(sample_rate)
        [0.5, 1.0 - AUDIBLE_LIMIT / sample_rate].max
      end

      # The tables and thresholds the C kernels read (see
      # FastWavetable.oscillate), for +sample_rate+ (cached).  An Array of:
      # 0 mode (0 cycle, 1 sample), 1 frames, 2 level datas, 3 level counts,
      # 4 level rates (DFloat), 5 hi and 6 lo thresholds (DFloat: a level is
      # used alone up to lo, then crossfaded into the next until hi, in
      # increments per sample), 7 half means (DFloat per frame; see
      # Builder.half_means), 8 loop datas, 9 loop counts, 10 loop rates, 11
      # loop start, 12 loop end, 13 end (source samples), 14 GUARD, 15 the
      # harmonic spectra for exact derivatives (cycle mode; see
      # #derivative_spectra), 16 the harmonic count of each level, 17 the
      # taper (1 for :sigma, else 0).  With +sync+ (band-limited cycle
      # tables), the levels and thresholds are the sync levels' (see
      # #sync_levels and FastWavetable.sync).
      def kernel_spec(sample_rate, interpolation = nil, sync: false)
        emphasis = emphasis?(interpolation)
        sync = false unless sync && @mode == :cycle && @spacing
        by_rate = @kernel_specs[sample_rate] ||= {}
        by_rate[[emphasis, sync]] ||= begin
          hi, lo = thresholds(sample_rate, sync: sync)
          levels, loop_levels = sync ? [sync_level_set(emphasis), nil] : level_set(emphasis)
          [
            @mode == :cycle ? 0 : 1,
            @frame_count,
            levels.map(&:data).freeze,
            levels.map(&:count).freeze,
            Numo::DFloat.cast(levels.map(&:rate)).freeze,
            hi.freeze, lo.freeze,
            @half_means.freeze,
            loop_levels&.map(&:data)&.freeze,
            loop_levels&.map(&:count)&.freeze,
            loop_levels && Numo::DFloat.cast(loop_levels.map(&:rate)).freeze,
            @loop ? @loop.begin.to_f : 0.0,
            @loop ? @loop.end.to_f : 0.0,
            @mode == :sample ? @size.to_f : 0.0,
            GUARD,
            derivative_spectra,
            @mode == :cycle ? levels.map { |l| l.bandwidth.finite? ? l.bandwidth.to_i : derivative_spectra.shape[1] - 1 }.freeze : nil,
            @taper == :sigma ? 1 : 0,
          ].freeze
        end
      end

      # Cycle mode: the spectra (a contiguous DComplex [frames, harmonics +
      # 1]; from the frames for tables made without them) that the kernels
      # use for exact derivatives of the table (sync events and phase warp
      # corners: the interpolated table has no smooth higher derivatives at
      # its sample points).
      def derivative_spectra
        return nil unless @mode == :cycle

        @derivative_spectra ||= Numo::DComplex.cast(@spectra || Builder.spectra_from_frames(@frames)).dup.freeze
      end

      # [hi, lo] level thresholds (DFloat, increments per sample) for
      # +sample_rate+ (see #kernel_spec and the class description).  With
      # +sync+, for the sync levels: under #sync_ceiling, each level
      # crossfading into the next all the way from the level above's
      # threshold (see #sync_levels).
      def thresholds(sample_rate, sync: false)
        top = sync ? sync_ceiling(sample_rate) : ceiling(sample_rate)
        bw = (sync ? sync_levels : levels).map(&:bandwidth)
        hi = bw.map { |b| b.finite? ? top / b : Float::INFINITY }
        lo = hi.each_with_index.map { |h, k|
          next h if k == hi.length - 1

          below = k > 0 ? hi[k - 1] : 0.0
          sync ? below : [below, h * 2.0**-LEVEL_FADE, h * bw[k + 1] / bw[k]].max
        }
        [Numo::DFloat.cast(hi), Numo::DFloat.cast(lo)]
      end

      # The highest frequency, in cycles per sample at +sample_rate+, of the
      # harmonics of a synced tone's levels: AUDIBLE_LIMIT, at most
      # SYNC_BAND (where the residuals of FastWavetable.sync can still undo
      # the minBLEP's own response).  Sync spreads every harmonic's spectrum,
      # so harmonics may not fold back from above Nyquist as in #ceiling.
      def sync_ceiling(sample_rate)
        [AUDIBLE_LIMIT / sample_rate, SYNC_BAND].min
      end

      # Cycle mode with levels: the levels synced tones read (built on first
      # use, for +interpolation+ as for #levels): every harmonic count up to
      # SYNC_ALL_COUNTS, then SYNC_SPACING apart, so a synced tone's
      # brightness, crossfaded continuously between them, doesn't step as
      # its pitch moves (sync usually runs a tone high, where octave levels
      # have only a few harmonics each).
      def sync_levels(interpolation = nil)
        sync_level_set(emphasis?(interpolation))
      end

      # The sync levels with or without +emphasis+ (see #sync_levels).
      def sync_level_set(emphasis)
        raise ArgumentError, 'Only band-limited cycle tables have sync levels' unless @mode == :cycle && @spacing

        @sync_levels ||= {}
        @sync_levels[emphasis] ||= begin
          counts_for = ->(spacing) { (Builder.level_harmonics(harmonics, spacing) | (1..[SYNC_ALL_COUNTS, harmonics].min).to_a).sort.reverse }
          spacing = SYNC_SPACING
          counts = counts_for.(spacing)
          while counts.length > MAX_LEVELS
            spacing *= 1.1 # very long frames: wider spacing to stay within the kernels' level limit
            counts = counts_for.(spacing)
          end
          datas, lengths, bandwidths = Builder.cycle_levels(@spectra, counts, @complex, emphasis, @taper)
          datas.each_with_index.map { |d, k| d.freeze; Level.new(d, lengths[k], lengths[k].to_f, bandwidths[k]) }.freeze
        end
      end

      # Cycle mode: the value at +phase+ (cycles) and +scan+ (0..1) for a
      # tone moving +increment+ cycles per sample at +sample_rate+, with
      # +interpolation+ (default #interpolation).  Sample mode: +phase+ is
      # the position in source samples and +increment+ the speed.
      def value_at(phase, scan: 0, increment: 0, sample_rate: 48000, interpolation: nil)
        KernelRuby.value(kernel_spec(sample_rate, interpolation), phase.to_f, increment.to_f.abs, scan.to_f, interpolation_code(interpolation))
      end

      # The kernel code of +interpolation+ (nil for #interpolation).
      def interpolation_code(interpolation = nil)
        interpolation ||= @interpolation
        INTERPOLATIONS.fetch(interpolation) {
          raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (#{INTERPOLATIONS.keys.join(', ')})"
        }
      end

      # Cycle mode oscillator kernel in C: fills +out+ (a 1D SFloat, or
      # SComplex for complex tables) at +freq+ (Hz, Numeric or NArray), with
      # the phase accumulator +state+ ([phase in cycles]) advancing by freq *
      # +advance+ per sample, +tstate+ ([position, last phase modulation,
      # primed]), +phase_mod+ (radians), +width+ (phase warp, nil for none),
      # +scan+ (0..1), and output gain and offset; +remove_dc+ removes the
      # warp's DC offset; a nonzero +random_advance+ (cycles per Hz) adds
      # noise to each increment from the generator state +noise+ (see
      # Tone#noise).  See Tone#wavetable.
      def oscillate(out, freq, advance, gain, offset, state, tstate, phase_mod, width, scan, interpolation, sample_rate, remove_dc, random_advance = 0.0, noise = nil)
        MB::Sound::FastWavetable.oscillate(
          out, kernel_spec(sample_rate, interpolation), freq, advance.to_f, gain.to_f, offset.to_f, state, tstate,
          phase_mod, width, scan, interpolation_code(interpolation), !!remove_dc, sinc_kernel(interpolation),
          random_advance.to_f, noise
        )
      end

      # Ruby mirror of #oscillate (the same samples), returning +out+.
      def oscillate_ruby(out, freq, advance, gain, offset, state, tstate, phase_mod, width, scan, interpolation, sample_rate, remove_dc, random_advance = 0.0, noise = nil)
        KernelRuby.oscillate(
          out, kernel_spec(sample_rate, interpolation), freq, advance.to_f, gain.to_f, offset.to_f, state, tstate,
          phase_mod, width, scan, interpolation_code(interpolation), !!remove_dc, random_advance.to_f, noise
        )
      end

      # Hard (or +soft+) synced cycle-mode oscillator in C: like #oscillate,
      # with +sync_state+ and +pulses+ as for FastSynth.oscillate_sync and
      # +ring+ a DFloat of BandLimit::SYNC_TAPS pending corrections (twice
      # that for complex tables).  Unless +band_limit+ is false, the tone
      # reads the sync levels (#sync_levels) and each harmonic gets an exact
      # minimum-phase residual at every sync event (see .sync_residuals and
      # FastWavetable.sync).  See Tone#sync.
      def sync(out, freq, advance, gain, offset, sync_state, ring, pulses, soft, width, scan, interpolation, sample_rate, remove_dc, band_limit = true)
        MB::Sound::FastWavetable.sync(
          out, kernel_spec(sample_rate, interpolation, sync: band_limit), freq, advance.to_f, gain.to_f, offset.to_f, sync_state, ring,
          pulses, !!soft, width, scan, interpolation_code(interpolation), !!remove_dc, Wavetable.sync_residuals,
          BandLimit.minblep_tables[0], BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!band_limit, SYNC_RESIDUAL_LIMIT, sinc_kernel(interpolation)
        )
      end

      # Ruby mirror of #sync.
      def sync_ruby(out, freq, advance, gain, offset, sync_state, ring, pulses, soft, width, scan, interpolation, sample_rate, remove_dc, band_limit = true)
        KernelRuby.sync(
          out, kernel_spec(sample_rate, interpolation, sync: band_limit), freq, advance.to_f, gain.to_f, offset.to_f, sync_state, ring,
          pulses, !!soft, width, scan, interpolation_code(interpolation), !!remove_dc, Wavetable.sync_residuals,
          BandLimit.minblep_tables[0], BandLimit::SYNC_OVERSAMPLE, BandLimit::SYNC_TAPS, !!band_limit, SYNC_RESIDUAL_LIMIT
        )
      end

      # The most levels a table may have (WT_MAX_LEVELS in the kernels).
      MAX_LEVELS = 64

      # Synced tones' levels: every harmonic count up to this one...
      SYNC_ALL_COUNTS = 8

      # ...then this ratio apart (a quarter octave; see #sync_levels).
      SYNC_SPACING = 2.0**0.25

      # The highest harmonic frequency of synced tones' levels in cycles per
      # sample (see #sync_ceiling): the minBLEP passes 0.89 there.
      SYNC_BAND = 0.42

      # Harmonics moving faster than this (cycles per sample; fast phase warp
      # segments) get no exact sync residual, only a minBLEP for their value
      # jump: past it the minBLEP's response H(f) is too small to divide out.
      SYNC_RESIDUAL_LIMIT = 0.45

      # Rows of .sync_residuals (frequencies 0 to 0.5 cycles per sample;
      # FastWavetable.sync reads the nearest row).
      SYNC_RESIDUAL_ROWS = 129

      # The minimum-phase residuals of switching on a complex exponential
      # (FastWavetable.sync): G(f, t) = (sum of h(s) e^(-2 pi i f s) for s
      # < t) / H(f), with h the impulse of BandLimit.minblep_tables' step
      # (its differences at the oversampled points, at their midpoints) and
      # H(f) its whole sum, so G(0, t) is the step and G(f, t) is 1 from
      # BandLimit::SYNC_TAPS samples on.  A contiguous 3D DComplex of
      # [SYNC_RESIDUAL_ROWS frequencies from 0 to 0.5 cycles per sample,
      # SYNC_OVERSAMPLE + 2 fractional offsets p, SYNC_TAPS taps j] for t =
      # p / SYNC_OVERSAMPLE + j, so the taps the kernel reads for an event
      # are contiguous.
      def self.sync_residuals
        @sync_residuals ||= begin
          os = BandLimit::SYNC_OVERSAMPLE
          taps = BandLimit::SYNC_TAPS
          blep, _ = BandLimit.minblep_tables
          step = blep + 1.0
          h = step[1..] - step[0...-1]
          s = (Numo::DFloat.new(h.length).seq + 0.5) / os
          flat = Numo::DComplex.ones(SYNC_RESIDUAL_ROWS, step.length + os + 1)
          SYNC_RESIDUAL_ROWS.times do |r|
            f = r * 0.5 / (SYNC_RESIDUAL_ROWS - 1)
            c = (h * Numo::NMath.exp(s * Complex(0, -2 * Math::PI * f))).cumsum
            flat[r, 0] = 0
            flat[r, 1...step.length] = c / c[-1]
          end
          flat[0, 0...step.length] = step
          flat[true, step.length - 1] = 1.0

          g = Numo::DComplex.zeros(SYNC_RESIDUAL_ROWS, os + 2, taps)
          (os + 2).times do |p|
            g[true, p, true] = flat[true, (p...(p + taps * os)).step(os).to_a]
          end
          g.freeze
        end
      end

      # Phase-driven lookup in C: fills +out+ from +phase+ (cycles, an
      # NArray) with +increments+ (cycles per sample for picking levels: an
      # NArray or number, false for the brightest level, or nil to estimate
      # the speed from the phase changes, holding their peak, with the
      # lookup state +lstate+ ([last phase, primed, peak, hold])), +scan+,
      # and the +wrap+ mode for phases outside 0...1 (see WRAP_MODES; :shape
      # spreads -1..1 across the cycle).  See GraphNode::Wavetable.
      def lookup(out, phase, increments, scan, interpolation, sample_rate, wrap, lstate = nil)
        MB::Sound::FastWavetable.lookup(
          out, kernel_spec(sample_rate, interpolation), phase, increments, scan, interpolation_code(interpolation),
          wrap_code(wrap), sinc_kernel(interpolation), lstate
        )
      end

      # Ruby mirror of #lookup.
      def lookup_ruby(out, phase, increments, scan, interpolation, sample_rate, wrap, lstate = nil)
        KernelRuby.lookup(out, kernel_spec(sample_rate, interpolation), phase, increments, scan, interpolation_code(interpolation), wrap_code(wrap), lstate)
      end

      # Sample mode player in C: fills +out+ at +freq+ (Hz), advancing the
      # phase in +state+ like #oscillate (for ports and resets) and the
      # position in source samples (+tstate+[0]) by freq * +speed+ per
      # sample (see #speed), wrapping in the loop.
      def play(out, freq, advance, speed, gain, offset, state, tstate, interpolation, sample_rate)
        MB::Sound::FastWavetable.play(
          out, kernel_spec(sample_rate, interpolation), freq, advance.to_f, speed.to_f, gain.to_f, offset.to_f, state, tstate,
          interpolation_code(interpolation), sinc_kernel(interpolation)
        )
      end

      # Ruby mirror of #play.
      def play_ruby(out, freq, advance, speed, gain, offset, state, tstate, interpolation, sample_rate)
        KernelRuby.play(
          out, kernel_spec(sample_rate, interpolation), freq, advance.to_f, speed.to_f, gain.to_f, offset.to_f, state, tstate,
          interpolation_code(interpolation)
        )
      end

      # Sample mode: source samples per output sample per Hz at
      # +sample_rate+.
      def speed(sample_rate)
        @sample_rate.to_f / (@root * sample_rate)
      end

      # Saves the frames (cycle mode) or the sound (sample mode) to
      # +filename+ (see .save_frames).
      #
      # Everything derived while making the table is saved as tags (see
      # #metadata), so .from_file makes the same table again: frames saved
      # aligned aren't aligned again, and a tapered table saves its exact
      # series (the taper is applied per level when it loads).  Complex
      # tables save their real parts.
      def save(filename, overwrite: false)
        if @mode == :cycle
          frames = @taper && @spectra ? Builder.synthesize(@spectra, @size, complex: @complex) : self.frames
          frames = frames.real if @complex
          Wavetable.save_frames(filename, frames, overwrite: overwrite, metadata: metadata)
        else
          data, scale = Wavetable.fit_for_file(@complex ? @data.real : @data)
          MB::Sound.write(filename, data, sample_rate: @sample_rate, overwrite: overwrite, metadata: Wavetable.metadata_tags(metadata.merge(scale: scale)))
        end
      end

      # Tags saved by #save that describe the table (others in #source_info
      # are saved too).
      SAVED_KEYS = [:mode, :name, :frames, :period, :size, :aligned, :spacing, :taper, :interpolation, :complex, :root, :loop, :sample_rate, :scale, :harmonics].freeze

      # The table's settings and derived values, as saved by #save (with
      # #source_info): mode, name, frame count, period (cycle mode samples
      # per frame), whether the frames are aligned, level spacing, taper,
      # interpolation, complex, harmonics (cycle mode), and in sample mode
      # the root (Hz), loop
      # ("begin...end" source samples), size, and sample rate.
      def metadata
        spacing = case @spacing
                  when nil then 'none'
                  when Array then @spacing.join(',')
                  else @spacing
                  end
        m = @source_info.merge(
          mode: @mode.to_s, name: @name, frames: @frame_count, aligned: @aligned.to_s, spacing: spacing,
          taper: @taper&.to_s, interpolation: @interpolation.to_s, complex: @complex.to_s
        )
        if @mode == :cycle
          m[:period] = @size
          m[:harmonics] = harmonics
        else
          m.merge!(root: @root, loop: @loop && "#{@loop.begin}...#{@loop.end}", size: @size, sample_rate: @sample_rate)
        end
        m.compact
      end

      def to_s
        desc = @mode == :cycle ? "#{@frame_count} frame#{'s' if @frame_count != 1}" : "#{@size} samples, root #{format('%.2f', @root)} Hz#{@loop ? ", loop #{@loop}" : ''}"
        mips = @spacing ? "#{levels.length} levels" : 'no levels'
        "#{@name || 'Wavetable'} (#{@mode}, #{desc}, #{mips}#{', complex' if @complex})"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      private

      def parse_spacing(mips)
        case mips
        when false, nil, :none
          nil
        when Symbol
          SPACINGS.fetch(mips) { raise ArgumentError, "Unknown level spacing #{mips.inspect} (#{SPACINGS.keys.join(', ')}, a ratio, or false)" }
        when Numeric
          raise ArgumentError, 'Level spacing must be a ratio above 1' unless mips > 1

          mips.to_f
        when Array
          raise ArgumentError, 'Level harmonics must be positive Integers' unless mips.all? { |m| m.is_a?(Integer) && m > 0 }

          mips.sort.reverse.freeze
        else
          raise ArgumentError, "Invalid level spacing #{mips.inspect}"
        end
      end

      def build_cycle(spectra, frames, size, align)
        if spectra.nil?
          raise ArgumentError, 'Give cycle frames or spectra' if frames.nil?

          @frames = frames
          @frames = Numo::SComplex.cast(@frames) if @complex
          size = frames.shape[1]
          spectra = Builder.spectra_from_frames(frames) if @spacing || align || @harmonic_limit
          spectra = spectra[true, 0..@harmonic_limit] if @harmonic_limit && spectra.shape[1] - 1 > @harmonic_limit
          if align && frames.shape[0] > 1
            spectra = Builder.align(spectra)
            @frames = Builder.synthesize(spectra, size, complex: @complex)
            @aligned = true
          end
        else
          @frames = nil # see #frames
        end

        @size = size
        @frame_count = spectra ? spectra.shape[0] : @frames.shape[0]
        @spectra = spectra
        @half_means = spectra ? Builder.half_means(spectra) : half_means_of(@frames)

      end

      # The emphasis of the levels +interpolation+ (nil for #interpolation)
      # reads: the interpolation for those in Emphasis::INTERPOLATORS, else
      # nil (see Emphasis).
      def emphasis?(interpolation)
        interpolation ||= @interpolation
        Emphasis::INTERPOLATORS.include?(interpolation) ? interpolation : nil
      end

      # [levels, loop levels] with or without +emphasis+ (built on first use;
      # see #levels).
      def level_set(emphasis)
        @level_sets[emphasis] ||= begin
          levels, loop_levels = @mode == :cycle ? build_cycle_levels(emphasis) : build_sample_levels(emphasis)
          levels.each { |l| l.data.freeze }
          loop_levels&.each { |l| l.data.freeze }
          [levels.freeze, loop_levels&.freeze].freeze
        end
      end

      def build_cycle_levels(emphasis)
        if @spacing
          datas, counts, bandwidths = Builder.cycle_levels(@spectra, @spacing, @complex, emphasis, @taper)
          levels = datas.each_with_index.map { |d, k| Level.new(d, counts[k], counts[k].to_f, bandwidths[k]) }
        else
          frames = self.frames
          if emphasis
            spectra = @spectra || Builder.spectra_from_frames(@frames)
            frames = Builder.synthesize(spectra, @size, complex: @complex, emphasis: emphasis, taper: @taper)
          end
          levels = [Level.new(Builder.wrap_guard(frames), @size, @size.to_f, Float::INFINITY)]
        end

        [levels, nil]
      end

      # Half means of frames without spectra (see Builder.half_means).
      def half_means_of(frames)
        rows, n = frames.shape
        half = n / 2
        Numo::DFloat.cast(Array.new(rows) { |r|
          row = frames[r, nil]
          row = row.real if row.respond_to?(:real) && !row.is_a?(Numo::SFloat)
          (row[0...half].mean - row[half..].mean) / 2.0
        })
      end

      def build_sample(data, root, loop, sample_rate)
        @data = @complex ? Numo::SComplex.cast(data) : (data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex) ? Numo::SComplex.cast(data) : Numo::SFloat.cast(data))
        @complex ||= @data.is_a?(Numo::SComplex)
        @size = @data.length
        @frame_count = 1
        @sample_rate = sample_rate.to_f
        @root = root.respond_to?(:frequency) ? root.frequency.to_f : root.to_f
        raise ArgumentError, "Root frequency must be positive (got #{root.inspect})" unless @root > 0

        @loop = parse_loop(loop)
        @half_means = Numo::DFloat.zeros(1)
        @spectra = nil

        raise ArgumentError, 'Sample mode levels take a spacing ratio, not harmonic counts' if @spacing.is_a?(Array)
      end

      def build_sample_levels(emphasis)
        if @spacing
          levels, loop_levels = Builder.sample_levels(@data, @spacing, @complex, @loop, @sample_rate, emphasis)
          return [
            levels.map { |l| Level.new(l[:data], l[:count], l[:rate], l[:bandwidth]) },
            loop_levels&.map { |l| Level.new(l[:data], l[:count], l[:rate], l[:bandwidth]) },
          ]
        end

        data = @data
        period = @loop && @data[@loop.begin...@loop.end]
        if emphasis
          # Emphasis by FFT of the whole sound (padded) and of the loop
          pad = data.class.zeros(data.length + 4096)
          pad[0...data.length] = data
          data = Builder.resample_band(pad, 0.5, pad.length + pad.length % 2, @complex, emphasis)
          period = Builder.resample_band(period, 0.5, period.length + period.length % 2, @complex, emphasis)[0...period.length] if period
        end

        valid = @loop ? @loop.begin : @size
        row = data.class.zeros(valid + 2 * GUARD)
        row[GUARD...(GUARD + valid)] = data[0...valid] if valid > 0
        if @loop
          # Continue into the loop past its start
          GUARD.times { |g| row[GUARD + valid + g] = data[@loop.begin + g % (@loop.end - @loop.begin)] }
        end
        levels = [Level.new(row.reshape(1, row.length), valid, 1.0, Float::INFINITY)]
        loop_levels = @loop && [Level.new(Builder.wrap_guard(period.reshape(1, period.length)), period.length, 1.0, Float::INFINITY)]

        [levels, loop_levels]
      end

      # A loop as begin...end in whole source samples (end exclusive), from a
      # Range of sample counts or Lengths.
      def parse_loop(loop)
        return nil if loop.nil? || loop == false
        raise ArgumentError, "Loop must be a Range (got #{loop.inspect})" unless loop.is_a?(Range)

        first = loop_point(loop.begin || 0)
        last = loop.end.nil? ? @size : loop_point(loop.end)
        last += 1 if loop.end && !loop.exclude_end?
        last = @size if last > @size
        raise ArgumentError, "Loop #{loop} must be inside the sample (0...#{@size}) and not empty" unless first >= 0 && last > first

        first...last
      end

      def loop_point(v)
        v = v.to_samples(sample_rate: @sample_rate) if v.respond_to?(:to_samples)
        v.round
      end

      def freeze_contents
        @frames&.freeze
        @data&.freeze
        @spectra&.freeze
        @half_means.freeze
      end

      def wrap_code(wrap)
        WRAP_MODES.index(wrap) || raise(ArgumentError, "Unknown wrapping mode #{wrap.inspect} (#{WRAP_MODES.join(', ')})")
      end

      def sinc_kernel(interpolation)
        (interpolation || @interpolation) == :sinc ? SINC_KERNEL : nil
      end
    end
  end
end

require_relative 'wavetable/builder'
require_relative 'wavetable/tools'
require_relative 'wavetable/kernel_ruby'
require_relative 'wavetable/emphasis'
require_relative 'wavetable/key_map'
require_relative 'wavetable/library'
