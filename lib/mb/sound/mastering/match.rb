module MB
  module Sound
    module Mastering
      # Reference mastering (`master :match, reference: 'ref.flac'`;
      # listen-1, 2026-10-30, backlog 2026-10 item 9): a reference track's
      # integrated loudness, true peak, and spectral tilt
      # (Analysis::Spectrum), which the :match preset reaches: its trim
      # brings the mix to the reference's loudness (renders: exactly, as
      # every targeted preset; live: the drive), and a tilt EQ after the
      # trim turns the mix's long-term spectrum toward the reference's
      # slope (renders measure the mix entering the chain in their first
      # pass; see Targeting).
      #
      #     ref = Mastering.reference('their_track.flac')
      #     ref            # => their_track.flac: -9.2 LUFS, -0.3 dBTP, tilt -0.9 dB/oct
      #     render 'mine.flac', bars: 64 { master :match, reference: 'their_track.flac'; song }

      # A measured reference: +name+ (the file's name or a label), +path+
      # (nil for audio given as data), +lufs+ (integrated), +true_peak+
      # (dBTP), +short_term_max+, +range+ (LRA), +tilt+ (dB per octave,
      # Analysis::Spectrum#tilt), +bands+ (third-octave levels re the
      # total, Analysis::Spectrum#bands), and +seconds+.
      Reference = Data.define(:name, :path, :lufs, :true_peak, :short_term_max, :range, :tilt, :bands, :seconds) do
        def to_s
          format('%s: %.1f LUFS, %.1f dBTP, LRA %.1f LU, tilt %+.2f dB/oct', name, lufs, true_peak, range, tilt)
        end

        def inspect
          "#<Mastering::Reference #{self}>"
        end
      end

      # The tilt EQ's high shelves (Hz, an octave apart): each +s dB with
      # the cookbook's maximal slope (quality 0.7071), together a slope of
      # s dB per octave within 0.15 dB from 100 Hz to 10 kHz, shelving off
      # outside (3.5 s dB from 1 kHz at 30 Hz and 20 kHz).  Measured
      # (listen-1): 7 shelves at 125..8000 Hz, quality 0.7071: -0.08..+0.14
      # dB per dB/oct of slope; quality 0.5: -0.33..+0.41; 9 shelves from
      # 62.5 Hz: -0.04..+0.01 (two more filters per channel).
      TILT_SHELVES = [125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0].freeze
      TILT_QUALITY = 0.7071

      # The largest tilt correction a render measures (dB per octave
      # either way; 1.5 dB/oct is +-5 dB at 100 Hz and 10 kHz).
      MAX_TILT = 1.5

      # The default ceiling of :match: the reference's true peak, within
      # these (dBTP).
      MATCH_CEILING = -3.0..-0.5

      class << self
        # A Reference for +source+: a sound file (measured once per path,
        # size, and time), a Sample, audio data (an Array of channels or a
        # Numo array, +name+ to label it), or a Reference (as it is).
        def reference(source, name: nil, sample_rate: 48000)
          case source
          when Reference
            source
          when String
            path = File.expand_path(source)
            stat = File.stat(path)
            id = [path, stat.size, stat.mtime.to_f, sample_rate]
            (@references ||= {})[id] ||= measure_reference(MB::Sound.read(source, sample_rate: sample_rate), name: name || File.basename(source), path: source, sample_rate: sample_rate)
          when Sample
            (@sample_references ||= ObjectSpace::WeakMap.new)[source] ||= begin
              chans = Array.new(source.channel_count) { |c| source.data(c) }
              measure_reference(chans, name: name || source.name || 'sample', path: source.file, sample_rate: source.sample_rate)
            end
          when Array, Numo::NArray
            chans = source.is_a?(Numo::NArray) ? [source] : source
            chans = [chans] if chans[0].is_a?(Numeric)
            measure_reference(chans, name: name || 'audio', path: nil, sample_rate: sample_rate)
          else
            raise ArgumentError, "reference: is a sound file, a Sample, audio (an Array of channels), or a Mastering::Reference (got #{source.class})"
          end
        end

        # Applies a tilt of +db_per_octave+ (see TILT_SHELVES) to +mix+ (a
        # node or bundle), unchanged at 1 kHz.  Returns +mix+ itself for
        # (nearly) no tilt.
        def tilt_eq(mix, db_per_octave, sample_rate: 48000)
          return mix if db_per_octave.abs < 1e-6
          gain = Decibels.new(db_per_octave.to_f)
          # The shelves' gain at 1 kHz, taken back out
          at_1k = TILT_SHELVES.sum { |f|
            20 * Math.log10(Filter::Cookbook.new(:highshelf, sample_rate, f, db_gain: db_per_octave.to_f, quality: TILT_QUALITY).response(2 * Math::PI * 1000 / sample_rate).abs)
          }
          TILT_SHELVES.reduce(mix) { |m, f| m.filter(:highshelf, cutoff: f, quality: TILT_QUALITY, gain: gain) } * Decibels.new(-at_1k)
        end

        # The tilt correction (dB per octave) that turns +mix+ (channels)
        # toward +reference+'s tilt, within MAX_TILT.  Returns [correction,
        # the mix's tilt].
        def tilt_correction(reference, mix, sample_rate: 48000)
          mix_tilt = Analysis::Spectrum.new(mix, sample_rate: sample_rate).tilt
          [(reference.tilt - mix_tilt).clamp(-MAX_TILT, MAX_TILT).round(3), mix_tilt]
        end

        private

        def measure_reference(channels, name:, path:, sample_rate:)
          raise ArgumentError, "The reference #{name} is empty" if channels.empty? || channels[0].size == 0
          a = Loudness::Analyzer.new(channels: channels.length, sample_rate: sample_rate)
          a.process(channels.map { |c| Numo::SFloat.cast(c) })
          r = a.result
          raise ArgumentError, "The reference #{name} is silent (no loudness to match)" unless r.integrated&.finite?
          sp = Analysis::Spectrum.new(channels, sample_rate: sample_rate)
          Reference.new(name: name, path: path, lufs: r.integrated.round(2), true_peak: r.true_peak.round(2),
            short_term_max: r.short_term_max.round(2), range: r.range.round(2), tilt: sp.tilt, bands: sp.bands,
            seconds: (channels[0].size.to_f / sample_rate).round(3))
        end
      end
    end
  end
end
