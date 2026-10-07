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
      def self.range(energies)
        _, _, gated = gate(energies, relative: LRA_RELATIVE_GATE)
        return [0.0, -Float::INFINITY, -Float::INFINITY] if gated.empty?

        sorted = gated.sort.to_a.map { |e| lufs(e) }
        low, high = LRA_PERCENTILES.map { |p| percentile(sorted, p) }
        [high - low, low, high]
      end

      # Linearly interpolated percentile +p+ (0..1) of a sorted Array.
      def self.percentile(sorted, p)
        pos = (sorted.length - 1) * p
        i = pos.floor
        return sorted[i] if i + 1 >= sorted.length
        sorted[i] + (sorted[i + 1] - sorted[i]) * (pos - i)
      end

      # Streaming true-peak meter for one channel: 4x oversampling with the
      # 48-tap polyphase FIR of BS.1770-4 Annex 2, then the absolute
      # maximum.  The same filter is used at every sample rate (its passband
      # scales with the rate).  Floats need none of the annex's 12.04 dB
      # headroom attenuation.
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

        TAPS = PHASES[0].length
        HISTORY = TAPS - 1

        # The largest oversampled absolute value so far (linear), not
        # counting the filter's tail after the last input.
        attr_reader :oversampled_peak

        # The largest absolute input sample so far (linear).
        attr_reader :sample_peak

        def initialize
          @history = Numo::DFloat.zeros(HISTORY)
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
          @oversampled_peak = [@oversampled_peak, Loudness::TruePeak.oversampled_max(ext, x.length)].max
          @history = ext[-HISTORY..].dup
          self
        end

        # The true peak (linear): the larger of the oversampled peak
        # (including the filter's tail after the last input, as if silence
        # followed) and the sample peak, as libebur128 reports it.
        def peak
          tail = @history.concatenate(Numo::DFloat.zeros(HISTORY))
          [@oversampled_peak, @sample_peak, Loudness::TruePeak.oversampled_max(tail, HISTORY)].max
        end

        # Largest absolute value of the 4x oversampled signal for +n+ samples,
        # given +ext+ (a contiguous Numo::DFloat) with HISTORY earlier
        # samples before them.  Runs in C (MB::Sound::FastLoudness), about
        # 25x faster than the Ruby mirror.
        def self.oversampled_max(ext, n)
          MB::Sound::FastLoudness.true_peak(ext, n)
        end

        # Exact Ruby mirror of FastLoudness.true_peak (specs compare them):
        # each phase is y[i] = sum(h[k] * x[i - k]), summed in order of k.
        def self.oversampled_max_ruby(ext, n)
          max = 0.0
          return max if n == 0

          y = Numo::DFloat.zeros(n)
          PHASES.each do |h|
            y.fill(0)
            h.each_with_index do |c, k|
              y.inplace + ext[(HISTORY - k)...(HISTORY - k + n)] * c
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
        # +:true_peak+ - false to skip true-peak measurement (it is about
        #                half the analysis time).
        def initialize(channels:, sample_rate: 48000, weights: nil, true_peak: true)
          raise ArgumentError, "Channel count must be positive (got #{channels.inspect})" unless channels.is_a?(Integer) && channels > 0
          raise ArgumentError, "Sample rate must be positive (got #{sample_rate.inspect})" unless sample_rate.is_a?(Numeric) && sample_rate > 0

          @channels = channels
          @sample_rate = sample_rate.to_f
          @weights = (weights || Loudness.default_weights(channels)).map(&:to_f).freeze
          raise ArgumentError, "Got #{@weights.length} weights for #{channels} channels" unless @weights.length == channels

          @filters = Array.new(channels) { Loudness.k_weighting(@sample_rate) }
          @true_peaks = true_peak ? Array.new(channels) { TruePeak.new } : nil

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

        # Gated integrated loudness (LUFS) so far.
        def integrated
          Loudness.gate(block_energies(MOMENTARY_SEGMENTS, STEP_SEGMENTS))[0]
        end
        alias lufs integrated

        # Loudness range (LU) so far.
        def range
          Loudness.range(block_energies(SHORT_TERM_SEGMENTS, STEP_SEGMENTS))[0]
        end
        alias lra range

        # True peak in dBTP over every channel so far (nil without true
        # peak measurement).
        def true_peak
          @true_peaks && @true_peaks.map(&:peak).max.to_db
        end

        # Returns a Result with every measurement.
        def result
          mom = block_energies(MOMENTARY_SEGMENTS, STEP_SEGMENTS)
          st = block_energies(SHORT_TERM_SEGMENTS, STEP_SEGMENTS)
          integrated, threshold, _ = Loudness.gate(mom)
          lra, low, high = Loudness.range(st)

          # Maxima from windows every 10 ms, so bursts between 100 ms steps
          # count fully.
          mom_max = block_energies(MOMENTARY_SEGMENTS, 1)
          st_max = block_energies(SHORT_TERM_SEGMENTS, 1)

          Result.new(
            integrated: integrated,
            relative_threshold: threshold,
            momentary: to_lufs(mom),
            short_term: to_lufs(st),
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

        # Mean squares of every complete window of +segments+ segments,
        # starting every +hop+ segments from the start.
        def block_energies(segments, hop)
          return Numo::DFloat[] if @segment_sums.length < segments

          cs = Numo::DFloat.zeros(@segment_sums.length + 1)
          cs[1..] = Numo::DFloat.cast(@segment_sums).cumsum
          cl = Numo::DFloat.zeros(@segment_lengths.length + 1)
          cl[1..] = Numo::DFloat.cast(@segment_lengths).cumsum

          starts = Numo::Int64.new((@segment_sums.length - segments) / hop + 1).seq * hop
          ends = starts + segments
          (cs[ends] - cs[starts]) / (cl[ends] - cl[starts])
        end

        # Converts mean squares to LUFS (-Infinity for silence).
        def to_lufs(energies)
          return Numo::DFloat[] if energies.empty?
          Numo::NMath.log10(energies) * 10.0 + OFFSET
        end
      end

      # Every measurement of one Analyzer (see MB::Sound.loudness).  Loudness
      # values are LUFS (-Infinity for silence or audio shorter than the
      # window), the range is in LU, peaks are dBTP/dBFS.
      #
      # +momentary+ and +short_term+ are Numo::DFloat series with one value
      # every 100 ms, the first at 400 ms or 3 s (each value covers the
      # window ending there).
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
