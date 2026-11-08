module MB
  module Sound
    module BarStats
      # A broadcast loudness report, as video editors and `ffmpeg -af
      # ebur128=peak=true` print it: integrated loudness (BS.1770-4
      # gating) with its relative gate, loudness range (EBU Tech 3342)
      # with its low and high ends, maximum true peak (dBTP), maximum
      # momentary and short-term loudness, PLR (true peak minus integrated
      # loudness), and pass/fail against delivery targets (Loudness.target
      # names or numbers; TARGETS by default: EBU R 128, ATSC A/85, and
      # streaming at -14 LUFS / -1 dBTP).  Measured by Loudness::Analyzer
      # (MB::Sound.loudness) at the file's own sample rate.
      #
      #     b = BarStats::Broadcast.of('song.flac')
      #     b.integrated            # => -14.2
      #     b.check(:ebu_r128)      # => #<Check EBU R 128: fail (...)>
      #     puts b
      class Broadcast
        # Delivery targets checked by default (Loudness::TARGETS names).
        TARGETS = %i[ebu_r128 atsc_a85 spotify].freeze

        # Loudness tolerance (LU) for targets that publish none (streaming
        # services normalize instead; within 1 LU means no turn-down to
        # speak of).
        DEFAULT_TOLERANCE = 1.0

        # One target's verdict: +target+ (a Loudness::Target), +pass+,
        # +loudness_off+ (LU over the target, negative under), +peak_over+
        # (dB over the true-peak ceiling, nil without one), and +reasons+
        # (Strings; empty when it passes).
        Check = Data.define(:target, :pass, :loudness_off, :peak_over, :reasons) do
          def to_s
            "#{target.name}: #{pass ? 'pass' : "fail (#{reasons.join('; ')})"}"
          end

          def inspect = "#<Check #{self}>"
        end

        FIELDS = %i[integrated threshold range range_low range_high true_peak sample_peak momentary_max short_term_max plr seconds].freeze

        attr_reader(*FIELDS)

        # The Checks against each target.
        attr_reader :checks

        # A report of a file (read at its own sample rate) or a
        # Loudness::Result.
        def self.of(source, targets: TARGETS)
          result = source.is_a?(Loudness::Result) ? source : MB::Sound.loudness(source)
          new(**from_result(result), targets: targets)
        end

        # The Broadcast fields of a Loudness::Result.
        def self.from_result(r)
          {
            integrated: r.integrated, threshold: r.relative_threshold, range: r.range, range_low: r.range_low, range_high: r.range_high,
            true_peak: r.true_peak, sample_peak: r.sample_peak, momentary_max: r.momentary_max, short_term_max: r.short_term_max,
            plr: r.true_peak && r.integrated.finite? ? r.true_peak - r.integrated : nil, seconds: r.duration,
          }
        end

        # Fields by name (FIELDS, numbers rounded to 0.01) and +targets+.
        def initialize(targets: TARGETS, **fields)
          FIELDS.each { |f| instance_variable_set(:"@#{f}", fields[f].is_a?(Float) && fields[f].finite? ? fields[f].round(2) : fields[f]) }
          @checks = targets.map { |t| check(t) }.freeze
        end

        # The Check against +target+ (a Loudness.target name, number, or
        # Target).
        def check(target)
          t = Loudness.target(target)
          tolerance = t.tolerance || DEFAULT_TOLERANCE
          off = @integrated&.finite? ? (@integrated - t.lufs).round(2) : nil
          over = t.true_peak && @true_peak ? (@true_peak - t.true_peak).round(2) : nil
          reasons = []
          reasons << 'silent' if off.nil?
          reasons << format('%.1f LU %s %.1f LUFS (tolerance %.1f)', off.abs, off > 0 ? 'over' : 'under', t.lufs, tolerance) if off && off.abs > tolerance
          reasons << format('true peak %.1f dBTP over %.1f', @true_peak, t.true_peak) if over && over > 0
          Check.new(target: t, pass: reasons.empty?, loudness_off: off, peak_over: over, reasons: reasons.freeze)
        end

        # True if every Check passes.
        def pass? = @checks.all?(&:pass)

        # The fields as a Hash, with the targets' verdicts ({ key => true or
        # false }).
        def to_h
          FIELDS.to_h { |f| [f, send(f)] }.merge(targets: @checks.to_h { |c| [c.target.key || c.target.lufs, c.pass] })
        end

        def to_s
          f = ->(v) { v.nil? ? 'n/a' : v.finite? ? format('%.1f', v) : '-inf' }
          lines = [
            "Integrated   #{f.(@integrated).rjust(7)} LUFS  (relative gate #{f.(@threshold)} LUFS)",
            "Range (LRA)  #{f.(@range).rjust(7)} LU    (#{f.(@range_low)} to #{f.(@range_high)} LUFS)",
            "True peak    #{f.(@true_peak).rjust(7)} dBTP  (sample peak #{f.(@sample_peak)} dBFS)",
            "Momentary    #{f.(@momentary_max).rjust(7)} LUFS max",
            "Short-term   #{f.(@short_term_max).rjust(7)} LUFS max",
            "PLR          #{f.(@plr).rjust(7)} LU",
          ]
          (lines + @checks.map { |c| "  #{c}" }).join("\n")
        end

        def inspect
          "#<BarStats::Broadcast #{format('%.1f', @integrated || -Float::INFINITY)} LUFS, LRA #{@range}, #{@true_peak} dBTP>"
        end
      end
    end
  end
end
