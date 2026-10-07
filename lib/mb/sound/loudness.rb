module MB
  module Sound
    # ITU-R BS.1770-4 loudness measurement: K-weighting, gated integrated
    # loudness (LUFS), momentary (400 ms) and short-term (3 s) loudness,
    # loudness range (LRA, EBU Tech 3342), and true peak (dBTP, 4x
    # oversampled per BS.1770-4 Annex 2).
    #
    # Most code uses MB::Sound.loudness (AnalysisMethods) for whole files or
    # arrays, or GraphNode#loudness_meter for a live meter.  Both run an
    # Analyzer, which takes audio in buffers of any size and keeps only 10 ms
    # energy sums (and the true peak), so an hour of audio takes a few MB.
    #
    # Channel order: weights default by channel count (see .default_weights),
    # assuming ffmpeg/SMPTE order (L R C LFE Ls Rs, then Lb Rb for 7.1).
    # Pass +weights:+ for other layouts.  Mono files get weight 1, as the
    # standard says, so a mono file reads 3 LU lower than the same signal on
    # both channels of a stereo file (pass +weights: [2.0]+ for "dual mono",
    # like ffmpeg's ebur128=dualmono=true).
    module Loudness
      # The constant in BS.1770's loudness formula (cancels the K-weighting
      # gain of +0.691 dB at 997 Hz).
      OFFSET = -0.691

      # Absolute gate for integrated loudness and LRA, in LUFS.
      ABSOLUTE_GATE = -70.0

      # Relative gate for integrated loudness, in LU below the absolutely
      # gated loudness (BS.1770-4).
      RELATIVE_GATE = -10.0

      # Relative gate for the loudness range, in LU (EBU Tech 3342).
      LRA_RELATIVE_GATE = -20.0

      # Percentiles of the gated short-term loudness that bound the loudness
      # range (EBU Tech 3342).
      LRA_PERCENTILES = [0.10, 0.95].freeze

      # Length in seconds of the energy sums the Analyzer keeps (10 ms), so
      # momentary and short-term maxima are found to 10 ms even for bursts
      # that start between 100 ms steps (EBU Tech 3341's burst cases).
      SEGMENT = 0.01

      # Step between gating blocks and reported momentary/short-term values,
      # in segments (100 ms: the 75% overlap of 400 ms gating blocks, and
      # the 10 Hz rate EBU Tech 3341 asks for).
      STEP_SEGMENTS = 10

      # Momentary window (and gating block) length in segments (400 ms).
      MOMENTARY_SEGMENTS = 40

      # Short-term window length in segments (3 s).
      SHORT_TERM_SEGMENTS = 300

      # Silence after the end for the loudness range, in segments (1.5 s,
      # EBU Tech 3342's file-based rule).
      LRA_TAIL_SEGMENTS = 150

      # Channel weight of surround channels (BS.1770: 1.41, +1.5 dB).
      SURROUND_WEIGHT = 1.41

      # Analog prototype of the K-weighting high shelf (stage 1): center
      # frequency, gain in dB, quality, and the band gain exponent.  These
      # reproduce BS.1770's published 48 kHz coefficients to about 1e-9 and
      # give the same response at other sample rates (the design libebur128
      # uses).
      SHELF_FREQUENCY = 1681.974450955533
      SHELF_GAIN_DB = 3.999843853973347
      SHELF_QUALITY = 0.7071752369554196
      SHELF_BAND_EXPONENT = 0.4996667741545416

      # Analog prototype of the RLB high-pass (stage 2).
      HIGHPASS_FREQUENCY = 38.13547087602444
      HIGHPASS_QUALITY = 0.5003270373238773

      # Returns the two K-weighting stages for +sample_rate+ as new
      # Filter::Biquads: [high shelf, RLB high-pass].
      def self.k_weighting(sample_rate)
        k = Math.tan(Math::PI * SHELF_FREQUENCY / sample_rate)
        vh = 10.0 ** (SHELF_GAIN_DB / 20.0)
        vb = vh ** SHELF_BAND_EXPONENT
        q = SHELF_QUALITY
        a0 = 1.0 + k / q + k * k
        shelf = Filter::Biquad.new(
          (vh + vb * k / q + k * k) / a0,
          2.0 * (k * k - vh) / a0,
          (vh - vb * k / q + k * k) / a0,
          2.0 * (k * k - 1.0) / a0,
          (1.0 - k / q + k * k) / a0,
          sample_rate: sample_rate
        )

        k = Math.tan(Math::PI * HIGHPASS_FREQUENCY / sample_rate)
        q = HIGHPASS_QUALITY
        a0 = 1.0 + k / q + k * k
        highpass = Filter::Biquad.new(
          1.0, -2.0, 1.0,
          2.0 * (k * k - 1.0) / a0,
          (1.0 - k / q + k * k) / a0,
          sample_rate: sample_rate
        )

        [shelf, highpass]
      end

      # A loudness target for normalization and reports: integrated
      # loudness in LUFS (LKFS), the maximum true peak in dBTP, the
      # tolerance in LU (nil if none is published), notes, where the numbers
      # come from, and whether they were checked against the publisher's
      # own document (+verified+ false means "reported, unverified").
      Target = Data.define(:key, :name, :lufs, :true_peak, :tolerance, :notes, :source, :verified) do
        def to_s
          tp = true_peak ? format(', %.1f dBTP', true_peak) : ''
          "#{name} (#{format('%.1f', lufs)} LUFS#{tp}#{verified ? '' : '; reported, unverified'})"
        end
      end

      # Loudness targets by name (see Target and Loudness.target).  Checked
      # 2026-10-07; streaming services change their practices, so re-check
      # the sources before relying on them.
      TARGETS = {
        ebu_r128: Target.new(
          key: :ebu_r128, name: 'EBU R 128', lufs: -23.0, true_peak: -1.0, tolerance: 0.5,
          notes: 'Broadcast programme loudness; +/-1.0 LU where the target is not practically achievable (e.g. live).  True peak is the production maximum.',
          source: 'EBU R 128-2023 (V5, November 2023), recommends h) and m); https://tech.ebu.ch/docs/r/r128.pdf, read 2026-10-07',
          verified: true
        ),
        atsc_a85: Target.new(
          key: :atsc_a85, name: 'ATSC A/85', lufs: -24.0, true_peak: -2.0, tolerance: 2.0,
          notes: 'US television (LKFS = LUFS), content delivered without metadata; true peak tolerance +/-0.5 dB.',
          source: 'ATSC A/85:2026-07 (8 July 2026), section 6; https://www.atsc.org/wp-content/uploads/2026/07/A85-2026-07.pdf, read 2026-10-07',
          verified: true
        ),
        spotify: Target.new(
          key: :spotify, name: 'Spotify', lufs: -14.0, true_peak: -1.0, tolerance: nil,
          notes: 'Normal mode.  Loud mode -11 LUFS, quiet mode -19 LUFS (see :spotify_loud, :spotify_quiet); masters louder than -14 LUFS should keep true peaks below -2 dBTP.  Measured per ITU-R BS.1770.',
          source: 'Spotify for Artists, "Loudness normalization", https://support.spotify.com/us/artists/article/loudness-normalization/, read 2026-10-07',
          verified: true
        ),
        spotify_loud: Target.new(
          key: :spotify_loud, name: 'Spotify (loud)', lufs: -11.0, true_peak: -2.0, tolerance: nil,
          notes: 'Spotify loud mode (premium listeners; Spotify applies a limiter).  -2 dBTP per Spotify\'s advice for masters louder than -14 LUFS.',
          source: 'Spotify for Artists, "Loudness normalization", https://support.spotify.com/us/artists/article/loudness-normalization/, read 2026-10-07',
          verified: true
        ),
        spotify_quiet: Target.new(
          key: :spotify_quiet, name: 'Spotify (quiet)', lufs: -19.0, true_peak: -1.0, tolerance: nil,
          notes: 'Spotify quiet mode.',
          source: 'Spotify for Artists, "Loudness normalization", https://support.spotify.com/us/artists/article/loudness-normalization/, read 2026-10-07',
          verified: true
        ),
        apple_music: Target.new(
          key: :apple_music, name: 'Apple Music', lufs: -16.0, true_peak: -1.0, tolerance: nil,
          notes: 'Sound Check.  The -16 LUFS level is reported, unverified (Apple publishes no number); the -1 dBTP ceiling is Apple\'s advice to "leave at least 1 dB of headroom" for 4x oversampling.',
          source: 'Apple Digital Masters technology brief (April 2021), https://www.apple.com/apple-music/apple-digital-masters/docs/apple-digital-masters.pdf, read 2026-10-07 (headroom only); -16 LUFS from third-party guides',
          verified: false
        ),
        youtube: Target.new(
          key: :youtube, name: 'YouTube', lufs: -14.0, true_peak: -1.0, tolerance: nil,
          notes: 'Reported, unverified: YouTube publishes no target; third-party measurements report about -14 LUFS, turned down only.',
          source: 'No official document found (2026-10-07); third-party mastering guides',
          verified: false
        ),
        amazon_music: Target.new(
          key: :amazon_music, name: 'Amazon Music', lufs: -14.0, true_peak: -2.0, tolerance: nil,
          notes: 'Reported, unverified: about -14 LUFS (turned down only) with -2 dBTP.',
          source: 'No official document found (2026-10-07); third-party mastering guides',
          verified: false
        ),
        soundcloud: Target.new(
          key: :soundcloud, name: 'SoundCloud', lufs: -14.0, true_peak: -1.0, tolerance: nil,
          notes: 'Reported, unverified: -14 LUFS up and down, below -1 dBTP (-2 dBTP for masters louder than -14 LUFS), attributed to SoundCloud\'s help center.',
          source: 'help.soundcloud.com article 360053660014 (returned HTTP 403 on 2026-10-07; numbers from search snippets)',
          verified: false
        ),
      }.freeze

      # Other names for TARGETS keys.
      TARGET_ALIASES = {
        ebu: :ebu_r128, r128: :ebu_r128, atsc: :atsc_a85, a85: :atsc_a85,
        apple: :apple_music, amazon: :amazon_music,
      }.freeze

      # True peak ceiling for numeric targets (dBTP), as EBU R 128.
      DEFAULT_TRUE_PEAK = -1.0

      # Returns a Target for a TARGETS name or alias (Symbol or String), a
      # number of LUFS (with a DEFAULT_TRUE_PEAK ceiling), a numeric String,
      # or a Target.
      def self.target(spec)
        case spec
        when Target
          spec
        when Numeric
          Target.new(key: nil, name: format('%g LUFS', spec), lufs: spec.to_f, true_peak: DEFAULT_TRUE_PEAK, tolerance: nil, notes: 'Custom target', source: nil, verified: true)
        when String, Symbol
          str = spec.to_s.strip
          return target(Float(str)) if str.match?(/\A[-+]?\d/)
          key = str.downcase.tr('-', '_').to_sym
          key = TARGET_ALIASES.fetch(key, key)
          TARGETS.fetch(key) {
            raise ArgumentError, "Unknown loudness target #{spec.inspect} (use a number of LUFS or one of #{(TARGETS.keys + TARGET_ALIASES.keys).join(', ')})"
          }
        else
          raise ArgumentError, "Loudness targets are numbers of LUFS or names (got #{spec.inspect})"
        end
      end

      # Applies gain to the audio file at +path+ so its integrated loudness
      # reaches +target+ (see .target), writing +output+ (default: +path+
      # itself, replaced through a temporary file in the same directory).
      # The file is measured and rewritten at its own sample rate (FLAC
      # comes back 24-bit).  Only gain is applied, never limiting.
      #
      # +:peak+ chooses what happens when the gain would put the true peak
      # above the target's ceiling: :warn (default) keeps the loudness target
      # and warns, :reduce lowers the gain to the ceiling (missing the
      # loudness target, with a warning), :ignore says nothing.
      #
      # Returns a Hash with :gain (dB), :before (the Result before),
      # :lufs and :true_peak (after), and :target.  Silent files are left
      # alone (gain nil).
      def self.normalize_file(path, target, output: nil, peak: :warn, true_peak: true, overwrite: true)
        raise ArgumentError, "peak: must be :warn, :reduce, or :ignore (got #{peak.inspect})" unless [:warn, :reduce, :ignore].include?(peak)

        target = self.target(target)
        output ||= path
        before = MB::Sound.loudness(path, true_peak: true_peak)
        gain = before.gain_to(target.lufs)
        info = { target: target, before: before, gain: gain, lufs: before.integrated, true_peak: before.true_peak }
        if gain.nil?
          warn "#{path}: silent, not normalized" unless peak == :ignore
          return info
        end

        ceiling = target.true_peak
        if ceiling && before.true_peak && before.true_peak + gain > ceiling
          if peak == :reduce
            reduced = ceiling - before.true_peak
            warn format('%s: gain reduced from %+.1f to %+.1f dB to keep the true peak at %.1f dBTP (%.1f LUFS instead of %.1f)',
              path, gain, reduced, ceiling, before.integrated + reduced, target.lufs)
            gain = reduced
          elsif peak == :warn
            warn format('%s: true peak %.1f dBTP after %+.1f dB is above %s\'s %.1f dBTP%s; no limiter is applied',
              path, before.true_peak + gain, gain, target.name, ceiling, before.true_peak + gain > 0 ? ' (clips in integer formats)' : '')
          end
        end

        if !overwrite && File.exist?(output) && File.expand_path(output) != File.expand_path(path)
          raise ArgumentError, "#{output} exists"
        end

        input = FFMPEGInput.new(path)
        rate = input.sample_rate
        input.close
        factor = 10.0 ** (gain / 20.0)
        data = MB::Sound.read(path, sample_rate: nil).map { |c| c * factor }

        tmp = File.join(File.dirname(output), ".#{File.basename(output, '.*')}.normalizing.#{Process.pid}#{File.extname(output)}")
        begin
          MB::Sound.write(tmp, data, sample_rate: rate, overwrite: true)
          File.rename(tmp, output)
        ensure
          File.unlink(tmp) if File.exist?(tmp)
        end

        info.merge(gain: gain, lufs: before.integrated + gain, true_peak: before.true_peak && before.true_peak + gain)
      end

      # Returns the K-weighting gain in dB at +frequency+ Hz for
      # +sample_rate+ (both stages).
      def self.k_weighting_db(frequency, sample_rate: 48000)
        omega = 2.0 * Math::PI * frequency / sample_rate
        k_weighting(sample_rate).sum { |f| 20.0 * Math.log10(f.response(omega).abs) }
      end

      # Default channel weights for +channels+ channels, in ffmpeg/SMPTE
      # order: 1-3 channels (mono, L R, L R C) weigh 1.0; 4 is quad (L R Ls
      # Rs); 5 is L R C Ls Rs; 6 is 5.1 (L R C LFE Ls Rs, LFE excluded); 8 is
      # 7.1 (L R C LFE Lb Rb Ls Rs).  Other counts weigh every channel 1.0.
      def self.default_weights(channels)
        s = SURROUND_WEIGHT
        case channels
        when 4 then [1.0, 1.0, s, s]
        when 5 then [1.0, 1.0, 1.0, s, s]
        when 6 then [1.0, 1.0, 1.0, 0.0, s, s]
        when 8 then [1.0, 1.0, 1.0, 0.0, s, s, s, s]
        else [1.0] * channels
        end
      end

      # Converts a weighted mean square to loudness in LUFS (-Infinity for
      # silence).
      def self.lufs(energy)
        energy > 0 ? OFFSET + 10.0 * Math.log10(energy) : -Float::INFINITY
      end

      # Converts loudness in LUFS back to a weighted mean square.
      def self.energy(lufs)
        10.0 ** ((lufs - OFFSET) / 10.0)
      end

      # Returns the gated loudness of block +energies+ (a Numo::DFloat of
      # weighted mean squares), gated at ABSOLUTE_GATE and then +relative+ LU
      # below the absolutely gated loudness.  Returns [loudness, relative
      # threshold, the energies that passed both gates].
      def self.gate(energies, relative: RELATIVE_GATE)
        none = [-Float::INFINITY, -Float::INFINITY, Numo::DFloat[]]
        return none if energies.empty?

        abs = energies[energies.gt(energy(ABSOLUTE_GATE))]
        return none if abs.empty?

        threshold = lufs(abs.mean) + relative
        rel = abs[abs.gt(energy(threshold))]
        return [-Float::INFINITY, threshold, rel] if rel.empty?

        [lufs(rel.mean), threshold, rel]
      end

      # Returns the loudness range in LU of short-term +energies+ (EBU Tech
      # 3342), with the low and high percentiles: [range, low, high].
      #
      # This follows the MATLAB definition in EBU Tech 3342 (November 2023,
      # section 5) literally: short-term loudness values (LUFS) at or above
      # -70 LUFS (>=) are kept; their power mean minus 20 LU is the relative
      # threshold, again inclusive (>=); the kept values are sorted and the
      # percentiles are the values at 1-based positions round((n - 1) *
      # 10 / 100 + 1) and round((n - 1) * 95 / 100 + 1), with MATLAB's
      # round (halves away from zero, as Ruby's Float#round).  No
      # interpolation.  (BS.1770's integrated gating uses > instead; see
      # .gate.)  Analyzer#result adds Tech 3342's 1.5 s of silence after the
      # end.
      def self.range(energies)
        none = [0.0, -Float::INFINITY, -Float::INFINITY]
        return none if energies.empty?

        stl = energies.to_a.map { |e| lufs(e) }
        abs_gated = stl.select { |l| l >= ABSOLUTE_GATE }
        return none if abs_gated.empty?

        integrated = 10.0 * Math.log10(abs_gated.sum { |l| 10.0 ** (l / 10.0) } / abs_gated.length)
        sorted = abs_gated.select { |l| l >= integrated + LRA_RELATIVE_GATE }.sort
        return none if sorted.empty?

        low, high = LRA_PERCENTILES.map { |p| percentile(sorted, p) }
        [high - low, low, high]
      end

      # Percentile +p+ (0..1) of a sorted Array by EBU Tech 3342's rule: the
      # element at 0-based index round((n - 1) * p), rounding halves up.
      def self.percentile(sorted, p)
        sorted[((sorted.length - 1) * (p * 100).round / 100.0).round]
      end

      # Streaming true-peak meter for one channel: oversampling with a
      # polyphase interpolation filter, then the absolute maximum.  The same
      # filter is used at every sample rate (its passband scales with the
      # rate).  Floats need none of BS.1770's 12.04 dB headroom attenuation.
      #
      # Filters (+filter:+, see FILTERS):
      # - :annex2 (default): the 4x, 12-taps-per-phase example filter of
      #   BS.1770-4 Annex 2.  Reads steady sines within about -0.33..+0.17 dB
      #   from 5 to 21 kHz at 48 kHz (EBU Tech 3341 allows +0.2/-0.4 dB).
      # - :accurate: 4x with 32 taps per phase (Kaiser-windowed sinc, beta 9,
      #   cutoff 0.95 of Nyquist, each phase normalized to unity DC gain).
      #   Within about 0.05 dB to 19 kHz and 0.2 dB at 20 kHz (plus the 4x
      #   grid's own -0.17 dB worst case near fs/4), closer to ffmpeg's
      #   ebur128 on bright material; about 2.5x the cost.
      class TruePeak
        # The four 12-tap phases of BS.1770-4 Annex 2's interpolation filter.
        PHASES = [
          [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
           0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
          [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
           0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
          [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
           0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
          [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
           0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
        ].map(&:freeze).freeze

        # Zeroth-order modified Bessel function of the first kind (for the
        # Kaiser window).
        def self.bessel_i0(x)
          x = x.to_f
          sum = 1.0
          term = 1.0
          (1..50).each do |k|
            term *= (x / (2 * k)) ** 2
            sum += term
          end
          sum
        end

        # Designs a 4x polyphase Kaiser-windowed sinc interpolator with
        # +taps+ taps per phase, each phase scaled to unity DC gain.
        def self.kaiser_phases(taps: 32, beta: 9.0, cutoff: 0.95)
          n = taps * 4
          c = (n - 1) / 2.0
          h = Array.new(n) { |i|
            x = (i - c) / 4.0
            s = x == 0 ? 1.0 : Math.sin(Math::PI * x * cutoff) / (Math::PI * x * cutoff)
            w = bessel_i0(beta * Math.sqrt([1 - ((i - c) / c) ** 2, 0].max)) / bessel_i0(beta)
            s * w
          }
          Array.new(4) { |p|
            phase = Array.new(taps) { |k| h[k * 4 + p] }
            sum = phase.sum
            phase.map { |v| v / sum }.freeze
          }.freeze
        end

        # Interpolation filters by name (Arrays of phases of taps).
        FILTERS = {
          annex2: PHASES,
          accurate: kaiser_phases,
        }.freeze

        # Coefficient matrices for the C kernel.
        MATRICES = FILTERS.transform_values { |ph| Numo::DFloat.cast(ph).freeze }.freeze

        # The filter name.
        attr_reader :filter

        # The largest oversampled absolute value so far (linear), not
        # counting the filter's tail after the last input.
        attr_reader :oversampled_peak

        # The largest absolute input sample so far (linear).
        attr_reader :sample_peak

        def initialize(filter: :annex2)
          raise ArgumentError, "Unknown true-peak filter #{filter.inspect} (use #{FILTERS.keys.map(&:inspect).join(' or ')})" unless FILTERS.include?(filter)

          @filter = filter
          @phases = MATRICES[filter]
          @history_length = FILTERS[filter][0].length - 1
          @history = Numo::DFloat.zeros(@history_length)
          @oversampled_peak = 0.0
          @sample_peak = 0.0
        end

        # Adds +samples+ (a Numo::NArray or Array) to the meter.  Returns self.
        def process(samples)
          x = Numo::DFloat.cast(samples)
          return self if x.empty?
          x = x.dup.not_inplace! if x.inplace?

          @sample_peak = [@sample_peak, x.abs.max].max
          ext = @history.concatenate(x)
          @oversampled_peak = [@oversampled_peak, Loudness::TruePeak.oversampled_max(ext, x.length, @phases)].max
          @history = ext[-@history_length..].dup
          self
        end

        # The true peak (linear): the larger of the oversampled peak
        # (including the filter's tail after the last input, as if silence
        # followed) and the sample peak, as libebur128 reports it.
        def peak
          tail = @history.concatenate(Numo::DFloat.zeros(@history_length))
          [@oversampled_peak, @sample_peak, Loudness::TruePeak.oversampled_max(tail, @history_length, @phases)].max
        end

        # Largest absolute value of the oversampled signal for +n+ samples,
        # given +ext+ (a contiguous Numo::DFloat) with (taps - 1) earlier
        # samples before them and +phases+ (a [phases, taps] Numo::DFloat;
        # default Annex 2).  Runs in C (MB::Sound::FastLoudness), about 25x
        # faster than the Ruby mirror.
        def self.oversampled_max(ext, n, phases = MATRICES[:annex2])
          MB::Sound::FastLoudness.true_peak(ext, n, phases)
        end

        # Exact Ruby mirror of FastLoudness.true_peak (specs compare them):
        # each phase is y[i] = sum(h[k] * x[i - k]), summed in order of k.
        def self.oversampled_max_ruby(ext, n, phases = MATRICES[:annex2])
          max = 0.0
          return max if n == 0

          history = phases.shape[1] - 1
          y = Numo::DFloat.zeros(n)
          phases.to_a.each do |h|
            y.fill(0)
            h.each_with_index do |c, k|
              y.inplace + ext[(history - k)...(history - k + n)] * c
            end
            m = y.abs.max
            max = m if m > max
          end
          max
        end
      end

      # Streaming loudness analysis of any number of channels: feed buffers
      # with #process, read live values (#momentary, #short_term,
      # #integrated) at any time, and get every measurement with #result.
      class Analyzer
        attr_reader :channels, :sample_rate, :weights

        # Total samples (per channel) processed so far.
        attr_reader :samples

        # +:channels+ - the channel count.
        # +:sample_rate+ - the sample rate in Hz.
        # +:weights+ - channel weights (default: Loudness.default_weights).
        # +:true_peak+ - the true-peak filter (:annex2, the default for true,
        #                or :accurate; see TruePeak), or false to skip
        #                true-peak measurement (about half the analysis
        #                time with :annex2).
        def initialize(channels:, sample_rate: 48000, weights: nil, true_peak: true)
          raise ArgumentError, "Channel count must be positive (got #{channels.inspect})" unless channels.is_a?(Integer) && channels > 0
          raise ArgumentError, "Sample rate must be positive (got #{sample_rate.inspect})" unless sample_rate.is_a?(Numeric) && sample_rate > 0

          @channels = channels
          @sample_rate = sample_rate.to_f
          @weights = (weights || Loudness.default_weights(channels)).map(&:to_f).freeze
          raise ArgumentError, "Got #{@weights.length} weights for #{channels} channels" unless @weights.length == channels

          @filters = Array.new(channels) { Loudness.k_weighting(@sample_rate) }
          filter = true_peak == true ? :annex2 : true_peak
          @true_peaks = filter ? Array.new(channels) { TruePeak.new(filter: filter) } : nil

          @samples = 0
          @segment_sums = []
          @segment_lengths = []
          @segment_sum = 0.0
          @next_boundary = boundary(1)
        end

        # Adds one buffer per channel (an Array of Numo::NArrays or Arrays of
        # the same length; a single NArray for one channel).  Returns self.
        def process(buffers)
          buffers = [buffers] if @channels == 1 && !buffers.is_a?(Array)
          buffers = [buffers] if @channels == 1 && buffers.is_a?(Array) && buffers[0].is_a?(Numeric)
          raise ArgumentError, "Expected #{@channels} channel buffers, got #{buffers.length}" unless buffers.length == @channels

          n = buffers.map(&:length).min
          return self if n == 0

          z = nil
          buffers.each_with_index do |buf, c|
            # Numo methods write into in-place arrays, so work on a copy
            x = Numo::DFloat.cast(buf)
            x = x.dup.not_inplace! if x.inplace?
            x = x[0...n] if x.length > n
            @true_peaks[c].process(x) if @true_peaks
            next if @weights[c] == 0

            # The Biquad kernel works in place on in-place arrays and copies
            # others, so the first stage copies and the second reuses it.
            shelf, highpass = @filters[c]
            y = shelf.process(x).inplace!
            highpass.process(y)
            sq = y * y
            sq * @weights[c] if @weights[c] != 1
            sq.not_inplace!
            if z
              z.inplace + sq
            else
              z = sq
            end
          end

          accumulate(z, n)
          self
        end

        # Momentary loudness (LUFS) of the last 400 ms of complete 10 ms
        # segments (silence before the start).
        def momentary
          Loudness.lufs(window_energy(MOMENTARY_SEGMENTS))
        end
        alias m momentary

        # Short-term loudness (LUFS) of the last 3 s of complete segments.
        def short_term
          Loudness.lufs(window_energy(SHORT_TERM_SEGMENTS))
        end
        alias s short_term

        # Gated integrated loudness (LUFS) so far (see #result).
        def integrated
          integrated_gate[0]
        end
        alias lufs integrated

        # Loudness range (LU) so far, as if followed by 1.5 s of silence
        # (see #result).
        def range
          Loudness.range(lra_energies)[0]
        end
        alias lra range

        # True peak in dBTP over every channel so far (nil without true
        # peak measurement).
        def true_peak
          @true_peaks && @true_peaks.map(&:peak).max.to_db
        end

        # Returns a Result with every measurement.
        #
        # Windows before the start are padded with silence, as a meter reset
        # at the start sees them (and as ffmpeg's ebur128 does), so every
        # measurement has a value however short the audio is:
        # - momentary and short-term series: one value every 100 ms from
        #   0.1 s, each over the 400 ms or 3 s ending there;
        # - maxima: over windows ending every 10 ms (and at the last sample),
        #   so bursts between 100 ms steps count fully;
        # - integrated: BS.1770's gating over complete 400 ms blocks every
        #   100 ms from the start; audio shorter than one block is measured
        #   as one block padded with silence to 400 ms (then gated at -70);
        # - range: EBU Tech 3342 over short-term values every 100 ms of the
        #   signal followed by 1.5 s of silence (Tech 3342: "For file-based
        #   measurements, the signal should be followed by at least 1.5 s
        #   of silence (corresponding to the latency of the loudness
        #   analysis-window)"), i.e. 3 s windows ending from 3 s to 1.5 s
        #   after the end.  Tech 3342 says nothing about windows that start
        #   before the signal, so none are added there (the most literal
        #   reading; the latency remark could also suggest centered windows
        #   with 1.5 s of silence before the start, which it doesn't state).
        #   Audio shorter than 1.5 s has no complete window and a range of
        #   0.
        def result
          integrated, threshold, _ = integrated_gate
          lra, low, high = Loudness.range(lra_energies)

          mom_max = windows(MOMENTARY_SEGMENTS, 1, partial: true)
          st_max = windows(SHORT_TERM_SEGMENTS, 1, partial: true)

          Result.new(
            integrated: integrated,
            relative_threshold: threshold,
            momentary: to_lufs(windows(MOMENTARY_SEGMENTS, STEP_SEGMENTS)),
            short_term: to_lufs(windows(SHORT_TERM_SEGMENTS, STEP_SEGMENTS)),
            momentary_max: mom_max.empty? ? -Float::INFINITY : Loudness.lufs(mom_max.max),
            short_term_max: st_max.empty? ? -Float::INFINITY : Loudness.lufs(st_max.max),
            range: lra,
            range_low: low,
            range_high: high,
            true_peak: @true_peaks && @true_peaks.map(&:peak).max.to_db,
            true_peaks: @true_peaks && @true_peaks.map { |t| t.peak.to_db },
            sample_peak: @true_peaks && @true_peaks.map(&:sample_peak).max.to_db,
            duration: @samples / @sample_rate,
            sample_rate: @sample_rate,
            channels: @channels,
            weights: @weights
          )
        end

        private

        # The sample index where 10 ms segment +k+ ends (rounded, so rates
        # not divisible by 100 get segments that differ by one sample).
        def boundary(k)
          (k * @sample_rate * SEGMENT).round
        end

        # Adds the weighted squares +z+ (length +n+; nil when every channel
        # weighs 0) to the 10 ms segment sums.
        def accumulate(z, n)
          pos = 0
          while pos < n
            take = [@next_boundary - @samples, n - pos].min
            @segment_sum += z[pos...(pos + take)].sum if z
            @samples += take
            pos += take

            if @samples == @next_boundary
              @segment_lengths << @next_boundary - boundary(@segment_sums.length)
              @segment_sums << @segment_sum
              @segment_sum = 0.0
              @next_boundary = boundary(@segment_sums.length + 1)
            end
          end
        end

        # Mean square of the last +segments+ complete segments, with silence
        # before the start.
        def window_energy(segments)
          @segment_sums.last(segments).sum / (segments * @sample_rate * SEGMENT)
        end

        # BS.1770 gating of complete 400 ms blocks every 100 ms (no padding),
        # or of one block padded with silence for audio shorter than 400 ms.
        # Returns [loudness, relative threshold, gated energies].
        def integrated_gate
          blocks = windows(MOMENTARY_SEGMENTS, STEP_SEGMENTS, lead: false)
          if blocks.empty? && @samples > 0
            blocks = Numo::DFloat[(@segment_sums.sum + @segment_sum) / (@sample_rate * SEGMENT * MOMENTARY_SEGMENTS)]
          end
          Loudness.gate(blocks)
        end

        # Short-term energies for the loudness range (see #result).
        def lra_energies
          windows(SHORT_TERM_SEGMENTS, STEP_SEGMENTS, lead: false, partial: true, trail: LRA_TAIL_SEGMENTS)
        end

        # Mean squares of windows of +segments+ segments starting every
        # +hop+ segments.  With +lead+, silence before the start fills the
        # first windows, so they end every +hop+ segments from the start.
        # +partial+ includes the incomplete last segment, and +trail+ adds
        # that many segments of silence after the end.
        def windows(segments, hop, lead: true, partial: false, trail: 0)
          sums = @segment_sums
          lengths = @segment_lengths
          if partial && @samples > boundary(@segment_sums.length)
            sums = sums + [@segment_sum]
            lengths = lengths + [@samples - boundary(@segment_sums.length)]
          end
          return Numo::DFloat[] if sums.empty?

          nominal = @sample_rate * SEGMENT
          pad = lead ? segments - hop : 0
          sums = [0.0] * pad + sums + [0.0] * trail
          lengths = [nominal] * pad + lengths + [nominal] * trail
          return Numo::DFloat[] if sums.length < segments

          cs = Numo::DFloat.zeros(sums.length + 1)
          cs[1..] = Numo::DFloat.cast(sums).cumsum
          cl = Numo::DFloat.zeros(lengths.length + 1)
          cl[1..] = Numo::DFloat.cast(lengths).cumsum

          starts = Numo::Int64.new((sums.length - segments) / hop + 1).seq * hop
          ends = starts + segments
          (cs[ends] - cs[starts]) / (cl[ends] - cl[starts])
        end

        # Converts mean squares to LUFS (-Infinity for silence).
        def to_lufs(energies)
          return Numo::DFloat[] if energies.empty?
          Numo::NMath.log10(energies) * 10.0 + OFFSET
        end
      end

      # Every measurement of one Analyzer (see MB::Sound.loudness and
      # Analyzer#result).  Loudness values are LUFS (-Infinity for silence),
      # the range is in LU, peaks are dBTP/dBFS.
      #
      # +momentary+ and +short_term+ are Numo::DFloat series with one value
      # every 100 ms; value i covers the 400 ms or 3 s window ending at
      # (i + 1) * 0.1 s, with silence before the start.
      Result = Data.define(
        :integrated, :relative_threshold,
        :momentary, :short_term, :momentary_max, :short_term_max,
        :range, :range_low, :range_high,
        :true_peak, :true_peaks, :sample_peak,
        :duration, :sample_rate, :channels, :weights
      ) do
        alias_method :lufs, :integrated
        alias_method :lra, :range
        alias_method :loudness_range, :range
        alias_method :m_max, :momentary_max
        alias_method :s_max, :short_term_max

        # Gain in dB that brings the integrated loudness to +target+ LUFS
        # (nil for silence).
        def gain_to(target)
          integrated.finite? ? target - integrated : nil
        end

        # A Hash of the measurements (Floats rounded to 0.01; -Infinity as
        # nil, for JSON).  Series are left out unless +series+ is true.
        def to_h(series: false)
          fix = ->(v) { v.is_a?(Float) ? (v.finite? ? v.round(2) : nil) : v }
          h = super()
          h.delete(:momentary) unless series
          h.delete(:short_term) unless series
          h.transform_values { |v|
            case v
            when Numo::NArray then v.to_a.map(&fix)
            when Array then v.map(&fix)
            else fix.(v)
            end
          }
        end

        def to_s
          format(
            '%.1f LUFS integrated, %.1f LUFS short-term max, %.1f LUFS momentary max, %.1f LU range, %s dBTP',
            integrated, short_term_max, momentary_max, range, true_peak ? format('%.1f', true_peak) : 'n/a'
          )
        end
      end
    end
  end
end
