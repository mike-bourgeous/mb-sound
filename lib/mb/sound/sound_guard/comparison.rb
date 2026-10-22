module MB
  module Sound
    module SoundGuard
      # Perceptual distances between an approved Fingerprint and a new one
      # (design/notes/sound_guards.md), each against a threshold calibrated
      # on changes known to be inaudible (buffer sizes, noise 80 dB down)
      # and audible (a 1 dB gain change, lp4's tuning change, a 10% filter
      # cutoff move).  A render passes when every distance is within its
      # threshold.
      #
      # Distances:
      # +loudness+ - |integrated LUFS difference| (LU).
      # +true_peak+ - |true peak difference| (dB).
      # +loudness_curve+ - 95th percentile |momentary loudness difference|
      #                    where either is within 40 LU of the loudest (LU).
      # +spectrum+ - RMS difference of the whole render's mel spectrum, its
      #              mean (the level) removed, over bands within 60 dB of the
      #              loudest (dB): lasting timbre changes.
      # +spectral+ - The same per segment, averaged over segments within 40
      #              dB of the loudest (dB): timbre changes over time.
      # +centroid+ - |spectral centroid difference| (cents).
      # +envelope+ - 95th percentile |frame energy difference|, its median
      #              (the level) removed, where either is within 50 dB of the
      #              loudest frame (dB): attacks, gates, timing.
      # +onsets+ - The larger share of strong onsets (strength >= 2) in either
      #            render without an onset in the other within 30 ms.
      # +width+ - The largest side/mid difference overall and per band, each
      #           floored at -40 dB (dB).
      # +duration+ - |length difference| (seconds).
      class Comparison
        # Thresholds (calibrated 2026-10-22, guards-1; see sound_guards.md).
        THRESHOLDS = {
          loudness: 0.3,
          true_peak: 0.6,
          loudness_curve: 0.75,
          spectrum: 0.35,
          spectral: 1.5,
          centroid: 25.0,
          envelope: 1.5,
          onsets: 0.15,
          width: 1.0,
          duration: 0.05,
        }.freeze

        # Units for reports.
        UNITS = {
          loudness: 'LU', true_peak: 'dB', loudness_curve: 'LU', spectrum: 'dB', spectral: 'dB',
          centroid: 'cents', envelope: 'dB', onsets: '', width: 'dB', duration: 's',
        }.freeze

        ONSET_STRONG = 2.0
        ONSET_WINDOW = 0.03
        WIDTH_FLOOR = -40.0

        attr_reader :approved, :candidate, :distances, :thresholds

        def initialize(approved, candidate, thresholds: THRESHOLDS)
          @approved = approved
          @candidate = candidate
          @thresholds = THRESHOLDS.merge(thresholds)
          @distances = compute
        end

        # Distance names over their thresholds, worst first (by ratio).
        def failures
          @distances.select { |k, v| v > @thresholds[k] }.sort_by { |k, v| -v / @thresholds[k] }.map(&:first)
        end

        def pass?
          failures.empty?
        end

        # The largest distance / threshold ratio (1 is the threshold).
        def worst_ratio
          @distances.map { |k, v| v / @thresholds[k] }.max
        end

        def to_h
          @distances.to_h { |k, v| [k, { value: v.round(4), threshold: @thresholds[k], pass: v <= @thresholds[k] }] }
        end

        # One line per distance.
        def to_s
          @distances.map { |k, v|
            t = @thresholds[k]
            format('  %-15s %9.3f %-5s (limit %g)%s', k, v, UNITS[k], t, v > t ? '  FAIL' : '')
          }.join("\n")
        end

        private

        def compute
          a = @approved
          b = @candidate
          {
            loudness: (a[:loudness][:integrated] - b[:loudness][:integrated]).abs,
            true_peak: (a[:loudness][:true_peak] - b[:loudness][:true_peak]).abs,
            loudness_curve: loudness_curve(a[:momentary], b[:momentary]),
            spectrum: shape_rms(a[:mel_mean], b[:mel_mean], 60.0),
            spectral: spectral(a, b),
            centroid: centroid(a[:centroid], b[:centroid]),
            envelope: envelope(a[:envelope], b[:envelope]),
            onsets: onsets(a[:onsets], b[:onsets]),
            width: width(a[:stereo], b[:stereo]),
            duration: (a[:duration] - b[:duration]).abs,
          }
        end

        def percentile(values, p)
          return 0.0 if values.empty?
          s = values.sort
          s[((s.length - 1) * p).round]
        end

        def loudness_curve(x, y)
          n = [x.length, y.length].min
          return 0.0 if n == 0
          top = [x.max, y.max].max
          d = (0...n).filter_map { |i| (x[i] - y[i]).abs if [x[i], y[i]].max > top - 40 }
          percentile(d, 0.95)
        end

        # RMS of b - a over bands where either is within +range+ dB of the
        # louder spectrum's top, after removing the mean difference.
        def shape_rms(x, y, range)
          top = [x.max, y.max].max
          d = x.each_index.filter_map { |i| y[i] - x[i] if [x[i], y[i]].max > top - range }
          return 0.0 if d.empty?
          m = d.sum / d.length
          Math.sqrt(d.sum { |v| (v - m)**2 } / d.length)
        end

        def spectral(a, b)
          xs = a[:mel]
          ys = b[:mel]
          n = [xs.length, ys.length].min
          return 0.0 if n == 0
          top = [a[:segment_db].max, b[:segment_db].max].max
          vals = (0...n).filter_map { |i|
            next unless [a[:segment_db][i], b[:segment_db][i]].max > top - 40
            shape_rms(xs[i], ys[i], 50.0)
          }
          vals.empty? ? 0.0 : vals.sum / vals.length
        end

        def centroid(x, y)
          return 0.0 if x <= 0 && y <= 0
          return Float::INFINITY if x <= 0 || y <= 0
          (1200 * Math.log2(y / x)).abs
        end

        def envelope(x, y)
          n = [x.length, y.length].min
          return 0.0 if n == 0
          top = [x.max, y.max].max
          d = (0...n).filter_map { |i| y[i] - x[i] if [x[i], y[i]].max > top - 50 }
          return 0.0 if d.empty?
          med = percentile(d, 0.5)
          percentile(d.map { |v| (v - med).abs }, 0.95)
        end

        def onsets(x, y)
          [unmatched(x, y), unmatched(y, x)].max
        end

        # Share of strong onsets in +x+ with no onset of +y+ near them.
        def unmatched(x, y)
          strong = x.select { |_t, s| s >= ONSET_STRONG }
          return 0.0 if strong.empty?
          times = y.map(&:first)
          missing = strong.count { |t, _s| times.none? { |u| (u - t).abs <= ONSET_WINDOW } }
          missing.to_f / strong.length
        end

        def width(x, y)
          return 0.0 if x.nil? && y.nil?
          return Float::INFINITY if x.nil? || y.nil?
          f = ->(v) { [v, WIDTH_FLOOR].max }
          ([[x[:width], y[:width]]] + x[:band_width].zip(y[:band_width])).map { |p, q| (f.(p) - f.(q)).abs }.max
        end
      end
    end
  end
end
